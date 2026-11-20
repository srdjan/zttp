//! M3 expression-kernel identity for the repair slices that can be lowered
//! without guessing.
//!
//! The kernel deliberately covers less than the language. It normalizes two
//! semantic forms:
//!
//! - a conditional expression and the exact two-arm boolean `match` emitted by
//!   the canonicalizer both lower to `select(truthy(c), a, b)`. The `match`
//!   scrutinee is a name that the repair binds before the statement
//!   (`const c = !!(cond);`). The caller passes that binding in `Options`, and
//!   the kernel reads the name as the lowered initializer;
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

pub const Side = enum { original, repaired };

pub const Verdict = union(enum) {
    identical,
    differs: []const u8,
    unsupported: Side,
    unparsable: Side,
};

/// One `const name = initializer;` that the repair inserts before the statement
/// that holds the repaired expression. The initializer is `!!(condition)`.
pub const Binding = struct {
    name: []const u8,
    initializer: []const u8,
};

pub const Options = struct {
    max_depth: u32 = 128,
    /// The binding that the repaired expression reads. The kernel refuses a
    /// binding whose initializer it cannot lower, a name that the original
    /// expression also uses, and a name that the repaired expression does not
    /// use exactly once, as its `match` scrutinee.
    binding: ?Binding = null,
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

    return compareParsedToLowered(
        allocator,
        &left,
        right.view(),
        right.root,
        &atoms,
        options,
    );
}

/// Compare one source expression with an already admitted and lowered IR node.
/// The caller owns admission, intrinsic resolution, and the node identity.
pub fn compareLoweredExpression(
    allocator: std.mem.Allocator,
    original: []const u8,
    repaired_view: IrView,
    repaired_root: NodeIndex,
    atoms: *AtomTable,
    options: Options,
) error{OutOfMemory}!Verdict {
    var left = Parsed.init(allocator, original, atoms) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.NoExpression => return .{ .unparsable = .original },
    };
    defer left.deinit();

    return compareParsedToLowered(
        allocator,
        &left,
        repaired_view,
        repaired_root,
        atoms,
        options,
    );
}

fn compareParsedToLowered(
    allocator: std.mem.Allocator,
    left: *Parsed,
    repaired_view: IrView,
    repaired_root: NodeIndex,
    atoms: *AtomTable,
    options: Options,
) error{OutOfMemory}!Verdict {
    var init_parsed: ?Parsed = null;
    defer if (init_parsed) |*parsed| parsed.deinit();
    var init_lowerer: Lowerer = undefined;
    var bound: Bound = undefined;
    const forbidden: ?[]const u8 = if (options.binding) |binding| binding.name else null;
    if (options.binding) |binding| {
        init_parsed = Parsed.init(allocator, binding.initializer, atoms) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.NoExpression => return .{ .unparsable = .repaired },
        };
        init_lowerer = .{
            .allocator = allocator,
            .view = init_parsed.?.view(),
            .atoms = atoms,
            .max_depth = options.max_depth,
            .forbidden = forbidden,
        };
        // The initializer is `!!(condition)`. Any other form does not give the
        // truthiness test that a ternary applies, so it is not lowered.
        const condition = init_lowerer.unwrapDoubleNot(init_parsed.?.root) orelse
            return .{ .unsupported = .repaired };
        _ = init_lowerer.digest(condition) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Unsupported => return .{ .unsupported = .repaired },
        };
        bound = .{ .name = binding.name, .lowerer = &init_lowerer, .condition = condition };
    }

    var left_lowerer = Lowerer{
        .allocator = allocator,
        .view = left.view(),
        .atoms = atoms,
        .max_depth = options.max_depth,
        .forbidden = forbidden,
    };
    const left_digest = left_lowerer.digest(left.root) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Unsupported => return .{ .unsupported = .original },
    };

    var right_lowerer = Lowerer{
        .allocator = allocator,
        .view = repaired_view,
        .atoms = atoms,
        .max_depth = options.max_depth,
        .forbidden = forbidden,
        .bound = if (options.binding != null) &bound else null,
    };
    const right_digest = right_lowerer.digest(repaired_root) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Unsupported => return .{ .unsupported = .repaired },
    };
    if (options.binding != null and bound.uses != 1) return .{ .unsupported = .repaired };

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

/// The repaired side's view of the inserted binding. `condition` is a node in
/// the initializer's own parse, so `lowerer` encodes it. `uses` counts the
/// `match` scrutinees that read the name.
const Bound = struct {
    name: []const u8,
    lowerer: *Lowerer,
    condition: NodeIndex,
    uses: u32 = 0,
};

const Lowerer = struct {
    allocator: std.mem.Allocator,
    view: IrView,
    atoms: *AtomTable,
    max_depth: u32,
    /// An identifier with this name is refused wherever it is read as an
    /// ordinary expression. Only the repaired side's scrutinee may read it, and
    /// that read does not pass through `encodeNode`.
    forbidden: ?[]const u8 = null,
    bound: ?*Bound = null,

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
            .lit_int, .lit_float => {
                // The expression parser stores every number as f64. Program
                // admission can use an exact i32 for the same number value.
                const value: f64 = if (tag == .lit_int)
                    @floatFromInt(self.view.getIntValue(node) orelse return error.Unsupported)
                else
                    self.view.ir_constants.getFloat(self.view.getFloatIdx(node) orelse return error.Unsupported) orelse return error.Unsupported;
                frame(hasher, "float");
                var bytes: [8]u8 = undefined;
                std.mem.writeInt(u64, &bytes, @bitCast(value), .big);
                frame(hasher, &bytes);
            },
            .lit_string => {
                frame(hasher, "string");
                const index = self.view.getStringIdx(node) orelse return error.Unsupported;
                frame(hasher, self.view.ir_constants.getString(index) orelse return error.Unsupported);
            },
            .lit_bool => {
                frame(hasher, "bool");
                frame(hasher, if (self.view.getBoolValue(node) orelse return error.Unsupported) "true" else "false");
            },
            .lit_null => frame(hasher, "null"),
            .lit_undefined => frame(hasher, "undefined"),
            .identifier => {
                frame(hasher, "identifier");
                const name = self.identifierName(node) orelse return error.Unsupported;
                if (self.forbidden) |forbidden| {
                    if (std.mem.eql(u8, name, forbidden)) return error.Unsupported;
                }
                frame(hasher, name);
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
                if (unary.op == .transparent) return self.encodeNode(hasher, unary.operand, depth);
                frame(hasher, "unary");
                frame(hasher, @tagName(unary.op));
                try self.encodeNode(hasher, unary.operand, depth + 1);
            },
            .ternary => {
                const ternary = self.view.getTernary(node) orelse return error.Unsupported;
                try self.encodeSelect(
                    hasher,
                    self,
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
                const atom: object.Atom = @fromBackingInt(@intCast(member.property));
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
            .assignment,
            .object_property,
            .object_spread,
            .function_expr,
            .arrow_function,
            .spread,
            .match_arm,
            .match_pattern,
            .match_type_test,
            .expr_stmt,
            .var_decl,
            .if_stmt,
            .for_of_stmt,
            .return_stmt,
            .assert_stmt,
            .break_stmt,
            .continue_stmt,
            .block,
            .function_decl,
            .array_pattern,
            .pattern_element,
            .import_decl,
            .import_specifier,
            .export_decl,
            .program,
            => return error.Unsupported,
        }
    }

    fn identifierName(self: *Lowerer, node: NodeIndex) ?[]const u8 {
        if (self.view.getTag(node) != .identifier) return null;
        const binding = self.view.getBinding(node) orelse return null;
        const atom: object.Atom = @fromBackingInt(@intCast(binding.name_atom));
        return self.atoms.getName(atom);
    }

    /// `condition` is a node of `condition_lowerer`'s parse. That is `self`
    /// for a ternary, and the binding's initializer for a bound `match`.
    fn encodeSelect(
        self: *Lowerer,
        hasher: *std.crypto.hash.sha2.Sha256,
        condition_lowerer: *Lowerer,
        condition: NodeIndex,
        then_branch: NodeIndex,
        else_branch: NodeIndex,
        depth: u32,
    ) LowerError!void {
        frame(hasher, "select");
        frame(hasher, "truthy");
        try condition_lowerer.encodeNode(hasher, condition, depth + 1);
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
        if (first.kind != second.kind) return error.Unsupported;

        const then_branch, const else_branch = switch (first.kind) {
            .value => .{ first.body, second.body },
            .callback => .{
                try self.callbackReturnExpression(first.body),
                try self.callbackReturnExpression(second.body),
            },
        };
        // The scrutinee is the bound name and nothing else.
        const bound = self.bound orelse return error.Unsupported;
        const name = self.identifierName(match.discriminant) orelse return error.Unsupported;
        if (!std.mem.eql(u8, name, bound.name)) return error.Unsupported;
        bound.uses += 1;
        try self.encodeSelect(hasher, bound.lowerer, bound.condition, then_branch, else_branch, depth);
    }

    fn callbackReturnExpression(self: *Lowerer, node: NodeIndex) LowerError!NodeIndex {
        if (self.view.getTag(node) != .arrow_function) return error.Unsupported;
        const function = self.view.getFunction(node) orelse return error.Unsupported;
        if (function.params_count != 0) return error.Unsupported;
        if (self.view.getTag(function.body) != .return_stmt) return error.Unsupported;
        return self.view.getOptValue(function.body) orelse error.Unsupported;
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
            const key = self.view.ir_constants.getString(key_index) orelse return error.Unsupported;
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

const ready_binding = Binding{ .name = "c", .initializer = "!!(ready)" };

test "pure chained conditional and bound boolean match share one kernel term" {
    const original = "ready ? 1 : fallback ? 2 : 3";
    const repaired = "match (c) { when true: 1, default: fallback ? 2 : 3 }";
    try testing.expectEqual(
        Verdict.identical,
        try compareExpressions(testing.allocator, original, repaired, .{ .binding = ready_binding }),
    );
}

test "conditional near misses do not discharge" {
    const original = "ready ? 1 : fallback ? 2 : 3";
    const swapped = "match (c) { when true: fallback ? 2 : 3, default: 1 }";
    const answer = try compareExpressions(testing.allocator, original, swapped, .{ .binding = ready_binding });
    try testing.expect(answer == .differs);

    const other_condition = Binding{ .name = "c", .initializer = "!!(other)" };
    const wrong_binding = try compareExpressions(
        testing.allocator,
        original,
        "match (c) { when true: 1, default: fallback ? 2 : 3 }",
        .{ .binding = other_condition },
    );
    try testing.expect(wrong_binding == .differs);

    const missing_name = "match (ready) { when true: 1, default: fallback ? 2 : 3 }";
    const unsupported = try compareExpressions(testing.allocator, original, missing_name, .{ .binding = ready_binding });
    try testing.expectEqual(Verdict{ .unsupported = .repaired }, unsupported);
}

test "a scrutinee that is not the bound name is never identical" {
    try testing.expectEqual(
        Verdict{ .unparsable = .repaired },
        try compareExpressions(
            testing.allocator,
            "ready ? 1 : 2",
            "match (!!(ready)) { when true: 1, default: 2 }",
            .{ .binding = ready_binding },
        ),
    );
    try testing.expectEqual(
        Verdict{ .unparsable = .repaired },
        try compareExpressions(
            testing.allocator,
            "ready ? 1 : 2",
            "match (!!(ready)) { when true: 1, default: 2 }",
            .{},
        ),
    );
}

test "a binding whose initializer is not a lowered truthiness test is refused" {
    const original = "ready ? 1 : 2";
    const repaired = "match (c) { when true: 1, default: 2 }";
    try testing.expectEqual(
        Verdict{ .unsupported = .repaired },
        try compareExpressions(testing.allocator, original, repaired, .{
            .binding = .{ .name = "c", .initializer = "!!(load())" },
        }),
    );
    try testing.expectEqual(
        Verdict{ .unsupported = .repaired },
        try compareExpressions(testing.allocator, original, repaired, .{
            .binding = .{ .name = "c", .initializer = "ready" },
        }),
    );
}

test "a bound name that the original also uses is refused" {
    try testing.expectEqual(
        Verdict{ .unsupported = .original },
        try compareExpressions(
            testing.allocator,
            "ready ? c : 2",
            "match (c) { when true: c, default: 2 }",
            .{ .binding = ready_binding },
        ),
    );
}

test "a bound name that the repaired expression uses twice or never is refused" {
    try testing.expectEqual(
        Verdict{ .unsupported = .repaired },
        try compareExpressions(
            testing.allocator,
            "ready ? 1 : 2",
            "match (c) { when true: 1, default: match (c) { when true: 1, default: 2 } }",
            .{ .binding = ready_binding },
        ),
    );
    try testing.expectEqual(
        Verdict{ .unsupported = .repaired },
        try compareExpressions(
            testing.allocator,
            "ready ? 1 : 2",
            "match (c) { when true: c, default: 2 }",
            .{ .binding = ready_binding },
        ),
    );
    try testing.expectEqual(
        Verdict{ .unsupported = .repaired },
        try compareExpressions(
            testing.allocator,
            "ready ? 1 : 2",
            "ready ? 1 : 2",
            .{ .binding = ready_binding },
        ),
    );
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
        "match (c) { when true: load(), default: 0 }",
        .{ .binding = ready_binding },
    );
    try testing.expectEqual(Verdict{ .unsupported = .original }, answer);
}

fn returnedExpression(view: IrView, program: NodeIndex) !NodeIndex {
    const program_block = view.getBlock(program) orelse return error.ProgramMissing;
    if (program_block.stmts_count != 2) return error.UnexpectedProgram;
    const function_node = view.getListIndex(program_block.stmts_start, 1);
    const function = view.getFunctionOfDecl(function_node) orelse return error.FunctionMissing;
    const body = view.getBlock(function.body) orelse return error.FunctionBodyMissing;
    if (body.stmts_count != 1) return error.UnexpectedFunctionBody;
    const return_node = view.getListIndex(body.stmts_start, 0);
    if (view.getTag(return_node) != .return_stmt) return error.ReturnMissing;
    return view.getOptValue(return_node) orelse error.ReturnValueMissing;
}

fn compareLoweredSource(
    source: []const u8,
    original: []const u8,
    binding: Binding,
) !Verdict {
    const pipeline = @import("pipeline.zig");
    var frontend: engine.source_frontend.DirectCheckSource = undefined;
    try frontend.initCompileInPlace(testing.allocator, testing.allocator, source, "/app/kernel.ts");
    defer frontend.deinit();
    const program = switch (frontend.parse_outcome) {
        .accepted => |root| root,
        else => return error.SourceAdmissionRefused,
    };
    var parsed = pipeline.ParsedModule.fromAdmittedParser(
        &frontend.parser,
        program,
        &frontend.atoms,
        "/app/kernel.ts",
    );
    parsed.scopes = &frontend.parser.scopes;
    var analysis: pipeline.ModuleAnalysisSession = .{};
    try analysis.initFull(testing.allocator, parsed, .{
        .source_types = .{ .direct = "/app/kernel.ts" },
        .strict = false,
    });
    defer analysis.deinit();
    try analysis.complete();

    const view = IrView.fromIRStore(&frontend.parser.nodes, &frontend.parser.constants);
    const lowered = try returnedExpression(view, program);
    return compareLoweredExpression(
        testing.allocator,
        original,
        view,
        lowered,
        &frontend.atoms,
        .{ .binding = binding },
    );
}

test "lowered fluent callbacks preserve a pure conditional kernel term" {
    const source =
        \\import { match } from "zttp:core";
        \\function choose(c: boolean): string {
        \\  return match(c).with(true, (): string => "yes").otherwise((): string => "no");
        \\}
    ;
    try testing.expectEqual(
        Verdict.identical,
        try compareLoweredSource(
            source,
            "ready ? \"yes\" : \"no\"",
            .{ .name = "c", .initializer = "!!(ready)" },
        ),
    );
}

test "lowered numeric callbacks preserve a chained conditional kernel term" {
    const source =
        \\import { match } from "zttp:core";
        \\function choose(c: boolean, fallback: boolean): number {
        \\  return match(c).with(true, (): number => 200).otherwise((): number => fallback ? 201 : 500);
        \\}
    ;
    try testing.expectEqual(
        Verdict.identical,
        try compareLoweredSource(
            source,
            "ready ? 200 : fallback ? 201 : 500",
            .{ .name = "c", .initializer = "!!(ready)" },
        ),
    );
    const changed_number = try compareLoweredSource(
        source,
        "ready ? 201 : fallback ? 201 : 500",
        .{ .name = "c", .initializer = "!!(ready)" },
    );
    try testing.expect(changed_number == .differs);
}

test "lowered fluent callback near misses differ" {
    const swapped =
        \\import { match } from "zttp:core";
        \\function choose(c: boolean): string {
        \\  return match(c).with(true, (): string => "no").otherwise((): string => "yes");
        \\}
    ;
    const swapped_verdict = try compareLoweredSource(
        swapped,
        "ready ? \"yes\" : \"no\"",
        .{ .name = "c", .initializer = "!!(ready)" },
    );
    try testing.expect(swapped_verdict == .differs);

    const matching =
        \\import { match } from "zttp:core";
        \\function choose(c: boolean): string {
        \\  return match(c).with(true, (): string => "yes").otherwise((): string => "no");
        \\}
    ;
    const wrong_condition = try compareLoweredSource(
        matching,
        "ready ? \"yes\" : \"no\"",
        .{ .name = "c", .initializer = "!!(other)" },
    );
    try testing.expect(wrong_condition == .differs);
}

test "lowered fluent callbacks with parameters blocks or calls stay unsupported" {
    const parameter =
        \\import { match } from "zttp:core";
        \\function choose(c: boolean): string {
        \\  return match(c).with(true, (selected: boolean): string => "yes").otherwise((): string => "no");
        \\}
    ;
    try testing.expectEqual(
        Verdict{ .unsupported = .repaired },
        try compareLoweredSource(parameter, "ready ? \"yes\" : \"no\"", ready_binding),
    );

    const block =
        \\import { match } from "zttp:core";
        \\function choose(c: boolean): string {
        \\  return match(c).with(true, (): string => { return "yes"; }).otherwise((): string => "no");
        \\}
    ;
    try testing.expectEqual(
        Verdict{ .unsupported = .repaired },
        try compareLoweredSource(block, "ready ? \"yes\" : \"no\"", ready_binding),
    );

    const call =
        \\import { match } from "zttp:core";
        \\function choose(c: boolean): string {
        \\  return match(c).with(true, (): string => String(c)).otherwise((): string => "no");
        \\}
    ;
    try testing.expectEqual(
        Verdict{ .unsupported = .repaired },
        try compareLoweredSource(call, "ready ? \"yes\" : \"no\"", ready_binding),
    );
}

test "raw fluent calls stay outside the lowered expression entry point" {
    const source =
        \\import { match } from "zttp:core";
        \\function choose(c: boolean): string {
        \\  return match(c).with(true, (): string => "yes").otherwise((): string => "no");
        \\}
    ;
    var frontend: engine.source_frontend.DirectCheckSource = undefined;
    try frontend.initCompileInPlace(testing.allocator, testing.allocator, source, "/app/raw-kernel.ts");
    defer frontend.deinit();
    const program = switch (frontend.parse_outcome) {
        .accepted => |root| root,
        else => return error.SourceAdmissionRefused,
    };
    const view = IrView.fromIRStore(&frontend.parser.nodes, &frontend.parser.constants);
    try testing.expectEqual(
        Verdict{ .unsupported = .repaired },
        try compareLoweredExpression(
            testing.allocator,
            "ready ? \"yes\" : \"no\"",
            view,
            try returnedExpression(view, program),
            &frontend.atoms,
            .{ .binding = ready_binding },
        ),
    );
}
