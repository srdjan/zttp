//! JSON serialization for the closed set of static IR literals used by
//! compiler schema extraction. Callers keep responsibility for recognizing
//! `JSON.stringify`, parsing raw schema strings, and interpreting the result.

const std = @import("std");
const ir = @import("zts-engine").parser.ir;
const json_utils = @import("zts-base").json_utils;

const IrView = ir.IrView;
const NodeIndex = ir.NodeIndex;

pub const AtomResolver = *const fn (atom_idx: u16, ctx: *const anyopaque) ?[]const u8;

pub const Error = std.mem.Allocator.Error;

const max_serialize_depth: usize = 512;

/// Serialize one static literal from `ir_view`.
///
/// A non-null result is allocated by `allocator` and owned by the caller.
/// Null means the node, or one of its descendants, is not in the supported
/// literal set. No partial output is returned. Name resolution is supplied by
/// the caller because compiler passes have different atom-table fallbacks.
pub fn serialize(
    allocator: std.mem.Allocator,
    ir_view: IrView,
    node_idx: NodeIndex,
    resolve_atom: AtomResolver,
    resolver_ctx: *const anyopaque,
) Error!?[]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();

    const ok = writeNode(ir_view, node_idx, resolve_atom, resolver_ctx, &output.writer, 0) catch |err| switch (err) {
        error.WriteFailed => return error.OutOfMemory,
    };
    if (!ok) {
        return null;
    }
    return try output.toOwnedSlice();
}

fn writeNode(
    ir_view: IrView,
    node_idx: NodeIndex,
    resolve_atom: AtomResolver,
    resolver_ctx: *const anyopaque,
    writer: *std.Io.Writer,
    depth: usize,
) std.Io.Writer.Error!bool {
    if (depth >= max_serialize_depth) return false;
    const tag = ir_view.getTag(node_idx) orelse return false;
    switch (tag) {
        .lit_int => {
            const value = ir_view.getIntValue(node_idx) orelse return false;
            try writer.print("{d}", .{value});
            return true;
        },
        .lit_float => {
            const float_idx = ir_view.getFloatIdx(node_idx) orelse return false;
            const value = ir_view.getFloat(float_idx) orelse return false;
            // `{d}` spells infinity and NaN as `inf` and `nan`, which is not JSON.
            if (!std.math.isFinite(value)) return false;
            try writer.print("{d}", .{value});
            return true;
        },
        .lit_string => {
            const string_idx = ir_view.getStringIdx(node_idx) orelse return false;
            const value = ir_view.getString(string_idx) orelse return false;
            try json_utils.writeJsonString(writer, value);
            return true;
        },
        .lit_bool => {
            const value = ir_view.getBoolValue(node_idx) orelse return false;
            try writer.writeAll(if (value) "true" else "false");
            return true;
        },
        .lit_null => {
            try writer.writeAll("null");
            return true;
        },
        .unary_op => {
            const unary = ir_view.getUnary(node_idx) orelse return false;
            switch (unary.op) {
                .transparent => return writeNode(ir_view, unary.operand, resolve_atom, resolver_ctx, writer, depth + 1),
                .neg => {
                    const operand_tag = ir_view.getTag(unary.operand) orelse return false;
                    if (operand_tag != .lit_int and operand_tag != .lit_float) return false;
                    try writer.writeByte('-');
                    return writeNode(ir_view, unary.operand, resolve_atom, resolver_ctx, writer, depth + 1);
                },
                else => return false,
            }
        },
        .array_literal => {
            const array = ir_view.getArray(node_idx) orelse return false;
            try writer.writeByte('[');
            for (0..array.elements_count) |i| {
                if (i > 0) try writer.writeAll(", ");
                const element = ir_view.getListIndex(array.elements_start, @intCast(i));
                if (!try writeNode(ir_view, element, resolve_atom, resolver_ctx, writer, depth + 1)) return false;
            }
            try writer.writeByte(']');
            return true;
        },
        .object_literal => {
            const object = ir_view.getObject(node_idx) orelse return false;
            try writer.writeByte('{');
            for (0..object.properties_count) |i| {
                const property_idx = ir_view.getListIndex(object.properties_start, @intCast(i));
                if (ir_view.getTag(property_idx) != .object_property) return false;
                const property = ir_view.getProperty(property_idx) orelse return false;
                const key = objectKey(ir_view, property.key, resolve_atom, resolver_ctx) orelse return false;
                // A repeated key is legal in a JS literal and refused by `std.json`. The
                // literal is unreadable here, so the caller treats the schema as dynamic.
                if (keyRepeats(ir_view, object, i, key, resolve_atom, resolver_ctx)) return false;

                if (i > 0) try writer.writeAll(", ");
                try json_utils.writeJsonString(writer, key);
                try writer.writeAll(": ");
                if (!try writeNode(ir_view, property.value, resolve_atom, resolver_ctx, writer, depth + 1)) return false;
            }
            try writer.writeByte('}');
            return true;
        },
        else => return false,
    }
}

/// True when a property before index `index` of `object` has the key `key`.
fn keyRepeats(
    ir_view: IrView,
    object: ir.Node.ObjectExpr,
    index: usize,
    key: []const u8,
    resolve_atom: AtomResolver,
    resolver_ctx: *const anyopaque,
) bool {
    for (0..index) |earlier| {
        const property_idx = ir_view.getListIndex(object.properties_start, @intCast(earlier));
        const property = ir_view.getProperty(property_idx) orelse continue;
        const earlier_key = objectKey(ir_view, property.key, resolve_atom, resolver_ctx) orelse continue;
        if (std.mem.eql(u8, earlier_key, key)) return true;
    }
    return false;
}

fn objectKey(
    ir_view: IrView,
    node_idx: NodeIndex,
    resolve_atom: AtomResolver,
    resolver_ctx: *const anyopaque,
) ?[]const u8 {
    const tag = ir_view.getTag(node_idx) orelse return null;
    return switch (tag) {
        .lit_string => blk: {
            const string_idx = ir_view.getStringIdx(node_idx) orelse break :blk null;
            break :blk ir_view.getString(string_idx);
        },
        .identifier => blk: {
            const binding = ir_view.getBinding(node_idx) orelse break :blk null;
            break :blk resolve_atom(binding.name_atom, resolver_ctx);
        },
        else => null,
    };
}

test "serialize writes the supported literal language exactly" {
    const allocator = std.testing.allocator;
    const source =
        \\const value = {
        \\  integer: 1,
        \\  float: 2.5,
        \\  negativeInteger: -3,
        \\  negativeFloat: -4.25,
        \\  string: "line\nquote:\" slash:\\ tab:\t",
        \\  boolean: true,
        \\  nothing: null,
        \\  nested: [false, { key: "value" }],
        \\  sibling: { key: "again" },
        \\};
    ;

    var parser = try @import("zts-engine").parser.JsParser.initAdmission(allocator, allocator, source, .compile);
    defer parser.deinit();
    _ = try parser.parse();
    const view = IrView.fromIRStore(&parser.nodes, &parser.constants);

    const Fixture = struct {
        fn initializer(ir_view: IrView) !NodeIndex {
            for (0..ir_view.nodeCount()) |i| {
                const idx: NodeIndex = @intCast(i);
                if (ir_view.getTag(idx) != .var_decl) continue;
                return (ir_view.getVarDecl(idx) orelse continue).init;
            }
            return error.MissingInitializer;
        }

        fn resolve(_: u16, _: *const anyopaque) ?[]const u8 {
            return null;
        }
    };
    const context: u8 = 0;
    const node = try Fixture.initializer(view);
    const json = (try serialize(allocator, view, node, Fixture.resolve, &context)) orelse
        return error.ExpectedLiteral;
    defer allocator.free(json);

    try std.testing.expectEqualStrings(
        "{\"integer\": 1, \"float\": 2.5, \"negativeInteger\": -3, \"negativeFloat\": -4.25, \"string\": \"line\\nquote:\\\" slash:\\\\ tab:\\t\", \"boolean\": true, \"nothing\": null, \"nested\": [false, {\"key\": \"value\"}], \"sibling\": {\"key\": \"again\"}}",
        json,
    );
}

test "serialize forwards a transparent literal wrapper" {
    const allocator = std.testing.allocator;
    var store = ir.IRStore.init(allocator);
    defer store.deinit();
    var constants = ir.ConstantPool.init(allocator);
    defer constants.deinit();
    const loc: ir.SourceLocation = .{ .line = 1, .column = 1, .offset = 0 };
    const operand = try store.addInt(loc, 42);
    const wrapped = try store.addUnary(loc, .{ .op = .transparent, .operand = operand });
    const Fixture = struct {
        fn resolve(_: u16, _: *const anyopaque) ?[]const u8 {
            return null;
        }
    };
    const context: u8 = 0;
    const json = (try serialize(
        allocator,
        IrView.fromIRStore(&store, &constants),
        wrapped,
        Fixture.resolve,
        &context,
    )) orelse return error.ExpectedLiteral;
    defer allocator.free(json);

    try std.testing.expectEqualStrings("42", json);
}

test "serialize refuses unsupported roots and partial literals without publishing bytes" {
    const allocator = std.testing.allocator;
    const sources = [_][]const u8{
        "const value = dynamic;",
        "const value = { type: dynamic };",
        "const value = { ...base, type: \"object\" };",
        "const value = [1, ...items];",
        "const value = { type: makeType() };",
        "const value = undefined;",
        "const value = !true;",
        // A repeated key gives text that `std.json` refuses as a DuplicateField,
        // and a non-finite number gives text that is not JSON at all (U3.4).
        "const value = { type: \"object\", type: \"string\" };",
        "const value = { properties: { a: 1, b: 2, a: 3 } };",
        "const value = [{ k: 1 }, { k: 2, k: 3 }];",
        "const value = { x: 1e999 };",
    };

    const Fixture = struct {
        fn initializer(ir_view: IrView) !NodeIndex {
            for (0..ir_view.nodeCount()) |i| {
                const idx: NodeIndex = @intCast(i);
                if (ir_view.getTag(idx) != .var_decl) continue;
                return (ir_view.getVarDecl(idx) orelse continue).init;
            }
            return error.MissingInitializer;
        }

        fn resolve(_: u16, _: *const anyopaque) ?[]const u8 {
            return null;
        }
    };
    const context: u8 = 0;

    for (sources) |source| {
        var parser = try @import("zts-engine").parser.JsParser.initAdmission(allocator, allocator, source, .compile);
        defer parser.deinit();
        _ = try parser.parse();
        const view = IrView.fromIRStore(&parser.nodes, &parser.constants);
        try std.testing.expect((try serialize(
            allocator,
            view,
            try Fixture.initializer(view),
            Fixture.resolve,
            &context,
        )) == null);
    }
}

test "serialize rejects malformed object properties before decoding their payload" {
    const allocator = std.testing.allocator;
    var parser = try @import("zts-engine").parser.JsParser.initAdmission(
        allocator,
        allocator,
        "const value = { key: \"value\" };",
        .compile,
    );
    defer parser.deinit();
    _ = try parser.parse();
    const view = IrView.fromIRStore(&parser.nodes, &parser.constants);

    const Fixture = struct {
        fn initializer(ir_view: IrView) !NodeIndex {
            for (0..ir_view.nodeCount()) |i| {
                const idx: NodeIndex = @intCast(i);
                if (ir_view.getTag(idx) != .var_decl) continue;
                return (ir_view.getVarDecl(idx) orelse continue).init;
            }
            return error.MissingInitializer;
        }

        fn resolve(_: u16, _: *const anyopaque) ?[]const u8 {
            return null;
        }
    };
    const context: u8 = 0;
    const object_idx = try Fixture.initializer(view);
    const object = view.getObject(object_idx) orelse return error.ExpectedObject;
    const property_idx = view.getListIndex(object.properties_start, 0);
    parser.nodes.tags.items[property_idx] = .lit_null;

    try std.testing.expect((try serialize(
        allocator,
        view,
        object_idx,
        Fixture.resolve,
        &context,
    )) == null);
    try std.testing.expect((try serialize(
        allocator,
        view,
        ir.null_node,
        Fixture.resolve,
        &context,
    )) == null);
}

test "serialize resolves identifier keys through the caller" {
    const allocator = std.testing.allocator;
    var parser = try @import("zts-engine").parser.JsParser.initAdmission(
        allocator,
        allocator,
        "const value = { original: \"value\" };",
        .compile,
    );
    defer parser.deinit();
    _ = try parser.parse();
    const view = IrView.fromIRStore(&parser.nodes, &parser.constants);

    const Fixture = struct {
        const atom: u16 = 41;

        fn initializer(ir_view: IrView) !NodeIndex {
            for (0..ir_view.nodeCount()) |i| {
                const idx: NodeIndex = @intCast(i);
                if (ir_view.getTag(idx) != .var_decl) continue;
                return (ir_view.getVarDecl(idx) orelse continue).init;
            }
            return error.MissingInitializer;
        }

        fn resolve(atom_idx: u16, _: *const anyopaque) ?[]const u8 {
            return if (atom_idx == atom) "resolved" else null;
        }

        fn reject(_: u16, _: *const anyopaque) ?[]const u8 {
            return null;
        }
    };
    const context: u8 = 0;
    const object_idx = try Fixture.initializer(view);
    const object = view.getObject(object_idx) orelse return error.ExpectedObject;
    const property_idx = view.getListIndex(object.properties_start, 0);
    const property = view.getProperty(property_idx) orelse return error.ExpectedProperty;
    parser.nodes.tags.items[property.key] = .identifier;
    parser.nodes.data.items[property.key] = .{
        .a = 0,
        .b = @backingInt(ir.BindingRef.BindingKind.global),
    };
    parser.nodes.binding_name_atoms.items[property.key] = Fixture.atom;

    try std.testing.expect((try serialize(
        allocator,
        view,
        object_idx,
        Fixture.reject,
        &context,
    )) == null);

    const json = (try serialize(allocator, view, object_idx, Fixture.resolve, &context)) orelse
        return error.ExpectedLiteral;
    defer allocator.free(json);
    try std.testing.expectEqualStrings("{\"resolved\": \"value\"}", json);
}

test "serialize releases every allocation when serialization fails" {
    const allocator = std.testing.allocator;
    const source =
        \\const value = {
        \\  type: "object",
        \\  properties: {
        \\    title: { type: "string" },
        \\    count: { type: "number", minimum: -1.5 },
        \\  },
        \\};
    ;
    var parser = try @import("zts-engine").parser.JsParser.initAdmission(allocator, allocator, source, .compile);
    defer parser.deinit();
    _ = try parser.parse();
    const view = IrView.fromIRStore(&parser.nodes, &parser.constants);

    const Fixture = struct {
        fn initializer(ir_view: IrView) !NodeIndex {
            for (0..ir_view.nodeCount()) |i| {
                const idx: NodeIndex = @intCast(i);
                if (ir_view.getTag(idx) != .var_decl) continue;
                return (ir_view.getVarDecl(idx) orelse continue).init;
            }
            return error.MissingInitializer;
        }

        fn resolve(_: u16, _: *const anyopaque) ?[]const u8 {
            return null;
        }

        fn run(
            failing_allocator: std.mem.Allocator,
            ir_view: IrView,
            node_idx: NodeIndex,
            resolver_ctx: *const u8,
        ) !void {
            const json = (try serialize(
                failing_allocator,
                ir_view,
                node_idx,
                resolve,
                resolver_ctx,
            )) orelse return error.ExpectedLiteral;
            defer failing_allocator.free(json);
        }
    };
    const context: u8 = 0;
    try std.testing.checkAllAllocationFailures(
        allocator,
        Fixture.run,
        .{ view, try Fixture.initializer(view), &context },
    );
}

test "serialize refuses negated non-numeric literals and deep nesting" {
    const allocator = std.testing.allocator;
    const Fixture = struct {
        fn resolve(_: u16, _: *const anyopaque) ?[]const u8 {
            return null;
        }
    };
    const context: u8 = 0;

    var store = ir.IRStore.init(allocator);
    defer store.deinit();
    var constants = ir.ConstantPool.init(allocator);
    defer constants.deinit();
    const loc: ir.SourceLocation = .{ .line = 1, .column = 1, .offset = 0 };

    const str_idx = try constants.addString("abc");
    const str_node = try store.addString(loc, str_idx);
    const neg_str = try store.addUnary(loc, .{ .op = .neg, .operand = str_node });
    const bool_node = try store.addBool(loc, true);
    const neg_bool = try store.addUnary(loc, .{ .op = .neg, .operand = bool_node });
    const int_node = try store.addInt(loc, 5);
    const neg_int = try store.addUnary(loc, .{ .op = .neg, .operand = int_node });
    const double_neg = try store.addUnary(loc, .{ .op = .neg, .operand = neg_int });

    // Build a deeply nested chain of transparent wrappers exceeding max_serialize_depth.
    var deep_node = int_node;
    for (0..max_serialize_depth + 1) |_| {
        deep_node = try store.addUnary(loc, .{ .op = .transparent, .operand = deep_node });
    }

    const view = IrView.fromIRStore(&store, &constants);
    try std.testing.expect((try serialize(allocator, view, neg_str, Fixture.resolve, &context)) == null);
    try std.testing.expect((try serialize(allocator, view, neg_bool, Fixture.resolve, &context)) == null);
    try std.testing.expect((try serialize(allocator, view, double_neg, Fixture.resolve, &context)) == null);
    try std.testing.expect((try serialize(allocator, view, deep_node, Fixture.resolve, &context)) == null);
}
