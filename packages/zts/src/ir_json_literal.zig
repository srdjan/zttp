//! JSON serialization for the closed set of static IR literals used by
//! compiler schema extraction. Callers keep responsibility for recognizing
//! `JSON.stringify`, parsing raw schema strings, and interpreting the result.

const std = @import("std");
const ir = @import("zts-engine").parser.ir;
const json_utils = @import("zts-base").json_utils;

const IrView = ir.IrView;
const NodeIndex = ir.NodeIndex;

pub const AtomResolver = *const fn (atom_idx: u16, ctx: *const anyopaque) ?[]const u8;

pub const Error = std.Io.Writer.Error || std.mem.Allocator.Error;

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

    if (!try writeNode(ir_view, node_idx, resolve_atom, resolver_ctx, &output.writer)) {
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
) std.Io.Writer.Error!bool {
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
            if (unary.op != .neg) return false;
            try writer.writeByte('-');
            return writeNode(ir_view, unary.operand, resolve_atom, resolver_ctx, writer);
        },
        .array_literal => {
            const array = ir_view.getArray(node_idx) orelse return false;
            try writer.writeByte('[');
            for (0..array.elements_count) |i| {
                if (i > 0) try writer.writeAll(", ");
                const element = ir_view.getListIndex(array.elements_start, @intCast(i));
                if (!try writeNode(ir_view, element, resolve_atom, resolver_ctx, writer)) return false;
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

                if (i > 0) try writer.writeAll(", ");
                try json_utils.writeJsonString(writer, key);
                try writer.writeAll(": ");
                if (!try writeNode(ir_view, property.value, resolve_atom, resolver_ctx, writer)) return false;
            }
            try writer.writeByte('}');
            return true;
        },
        else => return false,
    }
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
        \\  "float": 2.5,
        \\  negativeInteger: -3,
        \\  negativeFloat: -4.25,
        \\  string: "line\nquote:\" slash:\\ tab:\t",
        \\  boolean: true,
        \\  nothing: null,
        \\  nested: [false, { key: "value" }],
        \\};
    ;

    var parser = try @import("zts-engine").parser.JsParser.init(allocator, source);
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
        "{\"integer\": 1, \"float\": 2.5, \"negativeInteger\": -3, \"negativeFloat\": -4.25, \"string\": \"line\\nquote:\\\" slash:\\\\ tab:\\t\", \"boolean\": true, \"nothing\": null, \"nested\": [false, {\"key\": \"value\"}]}",
        json,
    );
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
        var parser = try @import("zts-engine").parser.JsParser.init(allocator, source);
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
    var parser = try @import("zts-engine").parser.JsParser.init(
        allocator,
        "const value = { key: \"value\" };",
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
    var parser = try @import("zts-engine").parser.JsParser.init(
        allocator,
        "const value = { original: \"value\" };",
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
        .b = @intFromEnum(ir.BindingRef.BindingKind.global),
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
    var parser = try @import("zts-engine").parser.JsParser.init(allocator, source);
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
            const json = serialize(
                failing_allocator,
                ir_view,
                node_idx,
                resolve,
                resolver_ctx,
            ) catch |err| switch (err) {
                error.WriteFailed, error.OutOfMemory => return error.OutOfMemory,
            } orelse return error.ExpectedLiteral;
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
