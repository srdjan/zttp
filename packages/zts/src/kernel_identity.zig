//! M3 expression-kernel identity for the repair slices that can be lowered
//! without guessing.
//!
//! The kernel deliberately covers less than the language. It normalizes two
//! semantic forms:
//!
//! - a conditional expression and the exact two-arm boolean `match` emitted by
//!   the canonicalizer both lower to `select(truthy(c), a, b)`;
//! - a closed object literal lowers to an insertion-ordered record after
//!   recursively flattening literal spreads.
//!
//! Calls, assignments, dynamic spreads, duplicate keys, functions, and every
//! statement form are outside this slice. Reaching one is an unsupported
//! verdict, never equivalence. That keeps branch effects and evaluation order
//! outside M3 until the kernel represents them explicitly.

const std = @import("std");
const engine = @import("zts-engine");

const parser_mod = engine.parser;
const object = engine.object;
const AtomTable = engine.atom_table.AtomTable;
const IrView = parser_mod.ir.IrView;
const NodeIndex = parser_mod.ir.NodeIndex;
const NodeTag = parser_mod.ir.NodeTag;
const ConstantPool = parser_mod.ir.ConstantPool;

pub const Side = enum { original, repaired };

pub const Verdict = union(enum) {
    identical,
    differs: []const u8,
    unsupported: Side,
    unparsable: Side,
};

pub const Options = struct {
    max_depth: u32 = 128,
};

pub fn compareExpressions(
    allocator: std.mem.Allocator,
    original: []const u8,
    repaired: []const u8,
    options: Options,
) error{OutOfMemory}!Verdict {
    var atoms = AtomTable.init(allocator);
    defer atoms.deinit();

    var left = Parsed.init(allocator, original, &atoms) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.NoExpression => return .{ .unparsable = .original },
    };
    defer left.deinit();
    var right = Parsed.init(allocator, repaired, &atoms) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.NoExpression => return .{ .unparsable = .repaired },
    };
    defer right.deinit();

    var left_lowerer = Lowerer{
        .allocator = allocator,
        .view = left.view(),
        .constants = &left.parser.constants,
        .atoms = &atoms,
        .max_depth = options.max_depth,
    };
    const left_digest = left_lowerer.digest(left.root) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Unsupported => return .{ .unsupported = .original },
    };

    var right_lowerer = Lowerer{
        .allocator = allocator,
        .view = right.view(),
        .constants = &right.parser.constants,
        .atoms = &atoms,
        .max_depth = options.max_depth,
    };
    const right_digest = right_lowerer.digest(right.root) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Unsupported => return .{ .unsupported = .repaired },
    };

    if (std.mem.eql(u8, &left_digest, &right_digest)) return .identical;
    return .{ .differs = "the expressions lower to different semantic kernel terms" };
}

const Parsed = struct {
    parser: parser_mod.JsParser,
    root: NodeIndex,

    const InitError = error{ OutOfMemory, NoExpression };

    fn init(
        allocator: std.mem.Allocator,
        source: []const u8,
        atoms: *AtomTable,
    ) InitError!Parsed {
        var parser = parser_mod.JsParser.initExpression(
            allocator,
            source,
            .comptime_expression,
        ) catch return error.OutOfMemory;
        errdefer parser.deinit();
        parser.setAtomTable(atoms);
        const root = parser.parseExpressionOnly() catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.NoExpression,
        };
        return .{ .parser = parser, .root = root };
    }

    fn view(self: *Parsed) IrView {
        return IrView.fromIRStore(&self.parser.nodes, &self.parser.constants);
    }

    fn deinit(self: *Parsed) void {
        self.parser.deinit();
    }
};

const LowerError = error{ OutOfMemory, Unsupported };

const Lowerer = struct {
    allocator: std.mem.Allocator,
    view: IrView,
    constants: *const ConstantPool,
    atoms: *AtomTable,
    max_depth: u32,

    fn digest(self: *Lowerer, node: NodeIndex) LowerError![32]u8 {
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        frame(&hasher, "zts-expression-kernel-v1");
        try self.encodeNode(&hasher, node, 0);
        return hasher.finalResult();
    }

    fn encodeNode(
        self: *Lowerer,
        hasher: *std.crypto.hash.sha2.Sha256,
        node: NodeIndex,
        depth: u32,
    ) LowerError!void {
        if (depth > self.max_depth) return error.Unsupported;
        const tag = self.view.getTag(node) orelse return error.Unsupported;

        // Exhaustive with no `else`: a new IR tag must be classified instead
        // of silently entering the equivalence kernel.
        switch (tag) {
            .lit_int => {
                frame(hasher, "int");
                const value = self.view.getIntValue(node) orelse return error.Unsupported;
                var bytes: [8]u8 = undefined;
                std.mem.writeInt(i64, &bytes, @as(i64, value), .big);
                frame(hasher, &bytes);
            },
            .lit_float => {
                frame(hasher, "float");
                const index = self.view.getFloatIdx(node) orelse return error.Unsupported;
                const value = self.constants.getFloat(index) orelse return error.Unsupported;
                var bytes: [8]u8 = undefined;
                std.mem.writeInt(u64, &bytes, @bitCast(value), .big);
                frame(hasher, &bytes);
            },
            .lit_string => {
                frame(hasher, "string");
                const index = self.view.getStringIdx(node) orelse return error.Unsupported;
                frame(hasher, self.constants.getString(index) orelse return error.Unsupported);
            },
            .lit_bool => {
                frame(hasher, "bool");
                frame(hasher, if (self.view.getBoolValue(node) orelse return error.Unsupported) "true" else "false");
            },
            .lit_null => frame(hasher, "null"),
            .lit_undefined => frame(hasher, "undefined"),
            .identifier => {
                frame(hasher, "identifier");
                const binding = self.view.getBinding(node) orelse return error.Unsupported;
                const atom: object.Atom = @enumFromInt(binding.name_atom);
                frame(hasher, self.atoms.getName(atom) orelse return error.Unsupported);
            },
            .binary_op => {
                const binary = self.view.getBinary(node) orelse return error.Unsupported;
                frame(hasher, "binary");
                frame(hasher, @tagName(binary.op));
                try self.encodeNode(hasher, binary.left, depth + 1);
                try self.encodeNode(hasher, binary.right, depth + 1);
            },
            .unary_op => {
                const unary = self.view.getUnary(node) orelse return error.Unsupported;
                frame(hasher, "unary");
                frame(hasher, @tagName(unary.op));
                try self.encodeNode(hasher, unary.operand, depth + 1);
            },
            .ternary => {
                const ternary = self.view.getTernary(node) orelse return error.Unsupported;
                try self.encodeSelect(
                    hasher,
                    ternary.condition,
                    ternary.then_branch,
                    ternary.else_branch,
                    depth,
                );
            },
            .member_access, .optional_chain => {
                const member = self.view.getMember(node) orelse return error.Unsupported;
                frame(hasher, if (member.is_optional) "optional-member" else "member");
                try self.encodeNode(hasher, member.object, depth + 1);
                const atom: object.Atom = @enumFromInt(member.property);
                frame(hasher, self.atoms.getName(atom) orelse return error.Unsupported);
            },
            .computed_access => {
                const member = self.view.getMember(node) orelse return error.Unsupported;
                frame(hasher, "computed-member");
                try self.encodeNode(hasher, member.object, depth + 1);
                try self.encodeNode(hasher, member.computed, depth + 1);
            },
            .array_literal => {
                const array = self.view.getArray(node) orelse return error.Unsupported;
                if (array.has_spread) return error.Unsupported;
                frame(hasher, "array");
                frameCount(hasher, array.elements_count);
                for (0..array.elements_count) |index| {
                    try self.encodeNode(
                        hasher,
                        self.view.getListIndex(array.elements_start, @intCast(index)),
                        depth + 1,
                    );
                }
            },
            .object_literal => try self.encodeClosedObject(hasher, node, depth),
            .match_expr => try self.encodeBooleanMatch(hasher, node, depth),

            // These tags either carry effects/evaluation order the slice does
            // not model or cannot occur as an expression root. Refuse all of
            // them, including a property/spread node reached outside the closed
            // object flattener.
            .call,
            .method_call,
            .assignment,
            .object_property,
            .object_method,
            .object_getter,
            .object_setter,
            .object_spread,
            .function_expr,
            .arrow_function,
            .spread,
            .await_expr,
            .yield_expr,
            .sequence_expr,
            .comma_expr,
            .match_arm,
            .match_pattern,
            .match_type_test,
            .expr_stmt,
            .var_decl,
            .if_stmt,
            .for_stmt,
            .for_of_stmt,
            .for_in_stmt,
            .while_stmt,
            .do_while_stmt,
            .switch_stmt,
            .case_clause,
            .return_stmt,
            .assert_stmt,
            .throw_stmt,
            .break_stmt,
            .continue_stmt,
            .try_stmt,
            .block,
            .labeled_stmt,
            .function_decl,
            .array_pattern,
            .pattern_element,
            .pattern_rest,
            .pattern_default,
            .import_decl,
            .import_specifier,
            .import_default,
            .import_namespace,
            .export_decl,
            .export_specifier,
            .export_default,
            .export_all,
            .program,
            .param_list,
            .arg_list,
            .stmt_list,
            => return error.Unsupported,
        }
    }

    fn encodeSelect(
        self: *Lowerer,
        hasher: *std.crypto.hash.sha2.Sha256,
        condition: NodeIndex,
        then_branch: NodeIndex,
        else_branch: NodeIndex,
        depth: u32,
    ) LowerError!void {
        frame(hasher, "select");
        frame(hasher, "truthy");
        try self.encodeNode(hasher, condition, depth + 1);
        try self.encodeNode(hasher, then_branch, depth + 1);
        try self.encodeNode(hasher, else_branch, depth + 1);
    }

    fn encodeBooleanMatch(
        self: *Lowerer,
        hasher: *std.crypto.hash.sha2.Sha256,
        node: NodeIndex,
        depth: u32,
    ) LowerError!void {
        const match = self.view.getMatchExpr(node) orelse return error.Unsupported;
        if (match.arms_count != 2) return error.Unsupported;
        const first = self.view.getMatchArm(self.view.getListIndex(match.arms_start, 0)) orelse
            return error.Unsupported;
        const second = self.view.getMatchArm(self.view.getListIndex(match.arms_start, 1)) orelse
            return error.Unsupported;
        if (self.view.getTag(first.pattern) != .lit_bool or
            !(self.view.getBoolValue(first.pattern) orelse return error.Unsupported) or
            self.view.isValid(second.pattern))
        {
            return error.Unsupported;
        }
        const condition = self.unwrapDoubleNot(match.discriminant) orelse return error.Unsupported;
        try self.encodeSelect(hasher, condition, first.body, second.body, depth);
    }

    fn unwrapDoubleNot(self: *Lowerer, node: NodeIndex) ?NodeIndex {
        const outer = self.view.getUnary(node) orelse return null;
        if (outer.op != .not) return null;
        const inner = self.view.getUnary(outer.operand) orelse return null;
        if (inner.op != .not) return null;
        return inner.operand;
    }

    const Field = struct {
        key: []const u8,
        value: [32]u8,
    };

    fn encodeClosedObject(
        self: *Lowerer,
        hasher: *std.crypto.hash.sha2.Sha256,
        node: NodeIndex,
        depth: u32,
    ) LowerError!void {
        var fields: std.ArrayList(Field) = .empty;
        defer fields.deinit(self.allocator);
        try self.collectClosedFields(&fields, node, depth + 1);
        for (fields.items, 0..) |field, index| {
            for (fields.items[0..index]) |previous| {
                if (std.mem.eql(u8, field.key, previous.key)) return error.Unsupported;
            }
        }

        frame(hasher, "record");
        frameCount(hasher, fields.items.len);
        for (fields.items) |field| {
            frame(hasher, field.key);
            frame(hasher, &field.value);
        }
    }

    fn collectClosedFields(
        self: *Lowerer,
        fields: *std.ArrayList(Field),
        node: NodeIndex,
        depth: u32,
    ) LowerError!void {
        if (depth > self.max_depth) return error.Unsupported;
        const object_expr = self.view.getObject(node) orelse return error.Unsupported;
        for (0..object_expr.properties_count) |index| {
            const child = self.view.getListIndex(object_expr.properties_start, @intCast(index));
            if (self.view.getTag(child) == .object_spread) {
                const spread_value = self.view.getOptValue(child) orelse return error.Unsupported;
                if (self.view.getTag(spread_value) != .object_literal) return error.Unsupported;
                try self.collectClosedFields(fields, spread_value, depth + 1);
                continue;
            }

            const property = self.view.getProperty(child) orelse return error.Unsupported;
            const key_index = self.view.getStringIdx(property.key) orelse return error.Unsupported;
            const key = self.constants.getString(key_index) orelse return error.Unsupported;
            try fields.append(self.allocator, .{
                .key = key,
                .value = try self.digestAtDepth(property.value, depth + 1),
            });
        }
    }

    fn digestAtDepth(self: *Lowerer, node: NodeIndex, depth: u32) LowerError![32]u8 {
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        frame(&hasher, "zts-expression-kernel-value-v1");
        try self.encodeNode(&hasher, node, depth);
        return hasher.finalResult();
    }
};

fn frame(hasher: *std.crypto.hash.sha2.Sha256, value: []const u8) void {
    var length: [8]u8 = undefined;
    std.mem.writeInt(u64, &length, @intCast(value.len), .big);
    hasher.update(&length);
    hasher.update(value);
}

fn frameCount(hasher: *std.crypto.hash.sha2.Sha256, value: anytype) void {
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, @intCast(value), .big);
    frame(hasher, &bytes);
}

const testing = std.testing;

test "pure chained conditional and boolean match share one kernel term" {
    const original = "ready ? 1 : fallback ? 2 : 3";
    const repaired = "match (!!(ready)) { when true: 1, default: fallback ? 2 : 3 }";
    try testing.expectEqual(
        Verdict.identical,
        try compareExpressions(testing.allocator, original, repaired, .{}),
    );
}

test "conditional near misses do not discharge" {
    const original = "ready ? 1 : fallback ? 2 : 3";
    const swapped = "match (!!(ready)) { when true: fallback ? 2 : 3, default: 1 }";
    const answer = try compareExpressions(testing.allocator, original, swapped, .{});
    try testing.expect(answer == .differs);

    const missing_truthiness = "match (ready) { when true: 1, default: fallback ? 2 : 3 }";
    const unsupported = try compareExpressions(testing.allocator, original, missing_truthiness, .{});
    try testing.expectEqual(Side.repaired, unsupported.unsupported);
}

test "moving a nonempty literal spread changes observable insertion order" {
    const original = "{ a: 1, ...{ b: 2 }, c: 3 }";
    const repaired = "{ ...{ b: 2 }, a: 1, c: 3 }";
    const answer = try compareExpressions(testing.allocator, original, repaired, .{});
    try testing.expect(answer == .differs);
}

test "moving an empty literal spread preserves the ordered record term" {
    try testing.expectEqual(
        Verdict.identical,
        try compareExpressions(testing.allocator, "{ a: 1, ...{} }", "{ ...{}, a: 1 }", .{}),
    );
}

test "dynamic and colliding spreads stay outside the kernel" {
    const dynamic = try compareExpressions(
        testing.allocator,
        "{ a: 1, ...base }",
        "{ ...base, a: 1 }",
        .{},
    );
    try testing.expectEqual(Side.original, dynamic.unsupported);

    const collision = try compareExpressions(
        testing.allocator,
        "{ a: 1, ...{ a: 2 } }",
        "{ ...{ a: 2 }, a: 1 }",
        .{},
    );
    try testing.expectEqual(Side.original, collision.unsupported);
}

test "calls stay outside the M3 slice even when both sides spell one" {
    const answer = try compareExpressions(
        testing.allocator,
        "ready ? load() : 0",
        "match (!!(ready)) { when true: load(), default: 0 }",
        .{},
    );
    try testing.expectEqual(Side.original, answer.unsupported);
}
