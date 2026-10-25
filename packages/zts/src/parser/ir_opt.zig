//! Allocation-free constant evaluation for code generation. Analysis always
//! sees the original IR: folding must not erase a refused operator, a call, or
//! a proof member. Only complete, side-effect-free expression trees fold.
//!
//! A shared visit budget bounds work even for a long expression containing a
//! nonconstant leaf. No node-order assumption, replacement map, or IR mutation
//! is needed. Larger trees emit normally; smaller subtrees can still fold.

const std = @import("std");
const ir = @import("ir.zig");

pub const Constant = union(enum) {
    int: i32,
    float: f64,
    boolean: bool,

    fn number(self: Constant) ?f64 {
        return switch (self) {
            .int => |v| @floatFromInt(v),
            .float => |v| v,
            .boolean => null,
        };
    }
};

/// Called only for expressions about to be emitted, after semantic analysis.
pub fn fold(view: ir.IrView, index: ir.NodeIndex) ?Constant {
    var remaining: usize = 64;
    return evaluate(view, index, &remaining);
}

fn evaluate(view: ir.IrView, index: ir.NodeIndex, remaining: *usize) ?Constant {
    if (remaining.* == 0) return null;
    remaining.* -= 1;
    const tag = view.getTag(index) orelse return null;
    return switch (tag) {
        .lit_int => .{ .int = view.getIntValue(index) orelse return null },
        .lit_float => .{ .float = view.getFloat(view.getFloatIdx(index) orelse return null) orelse return null },
        .lit_bool => .{ .boolean = view.getBoolValue(index) orelse return null },
        .unary_op => blk: {
            const expr = view.getUnary(index) orelse return null;
            break :blk unary(expr.op, evaluate(view, expr.operand, remaining) orelse return null);
        },
        .binary_op => blk: {
            const expr = view.getBinary(index) orelse return null;
            const left = evaluate(view, expr.left, remaining) orelse return null;
            // Require both sides even for && and ||. Otherwise folding could
            // remove a call that the proof IR still contains.
            const right = evaluate(view, expr.right, remaining) orelse return null;
            break :blk binary(expr.op, left, right);
        },
        else => null,
    };
}

fn unary(op: ir.UnaryOp, operand: Constant) ?Constant {
    return switch (op) {
        .not => switch (operand) {
            .boolean => |v| .{ .boolean = !v },
            else => null,
        },
        .neg => switch (operand) {
            // The VM promotes MIN_INT to a float. Leave that case to it.
            .int => |v| if (v == std.math.minInt(i32)) null else .{ .int = -v },
            .float => |v| finite(-v),
            else => null,
        },
        .bit_not => switch (operand) {
            .int => |v| .{ .int = ~v },
            else => null,
        },
        else => null,
    };
}

fn finite(v: f64) ?Constant {
    // Keep NaN/infinity representation and exceptional arithmetic in the VM.
    return if (std.math.isFinite(v)) .{ .float = v } else null;
}

fn binary(op: ir.BinaryOp, left: Constant, right: Constant) ?Constant {
    if (op == .and_op or op == .or_op) {
        if (left != .boolean) return null;
        return if (op == .and_op)
            (if (left.boolean) right else left)
        else
            (if (left.boolean) left else right);
    }

    if (left == .int and right == .int) {
        const a = left.int;
        const b = right.int;
        switch (op) {
            .add, .sub, .mul => {
                const result = switch (op) {
                    .add => @addWithOverflow(a, b),
                    .sub => @subWithOverflow(a, b),
                    .mul => @mulWithOverflow(a, b),
                    else => unreachable,
                };
                return if (result[1] == 0) .{ .int = result[0] } else null;
            },
            .mod => return if (b == 0) null else .{
                .int = if (a == std.math.minInt(i32) and b == -1) 0 else @rem(a, b),
            },
            .bit_and => return .{ .int = a & b },
            .bit_or => return .{ .int = a | b },
            .bit_xor => return .{ .int = a ^ b },
            .shl => return .{ .int = a << @as(u5, @truncate(@as(u32, @bitCast(b)))) },
            .shr => return .{ .int = a >> @as(u5, @truncate(@as(u32, @bitCast(b)))) },
            .strict_eq => return .{ .boolean = a == b },
            .strict_neq => return .{ .boolean = a != b },
            .lt => return .{ .boolean = a < b },
            .lte => return .{ .boolean = a <= b },
            .gt => return .{ .boolean = a > b },
            .gte => return .{ .boolean = a >= b },
            else => {},
        }
    }

    const a = left.number() orelse return null;
    const b = right.number() orelse return null;
    return switch (op) {
        .add => finite(a + b),
        .sub => finite(a - b),
        .mul => finite(a * b),
        // Division always produces a float, including two integer operands.
        .div => if (b == 0) null else finite(a / b),
        else => null,
    };
}

test "constant arithmetic follows VM division and remainder semantics" {
    try std.testing.expectEqual(@as(f64, 3.5), binary(.div, .{ .int = 7 }, .{ .int = 2 }).?.float);
    try std.testing.expectEqual(@as(i32, -2), binary(.mod, .{ .int = -5 }, .{ .int = 3 }).?.int);
    try std.testing.expectEqual(@as(i32, 2), binary(.mod, .{ .int = 5 }, .{ .int = -3 }).?.int);
    try std.testing.expectEqual(@as(i32, 0), binary(.mod, .{ .int = std.math.minInt(i32) }, .{ .int = -1 }).?.int);
    try std.testing.expect(binary(.div, .{ .int = 1 }, .{ .int = 0 }) == null);
    try std.testing.expect(binary(.mod, .{ .int = 1 }, .{ .int = 0 }) == null);
    try std.testing.expect(binary(.add, .{ .int = std.math.maxInt(i32) }, .{ .int = 1 }) == null);
    try std.testing.expect(unary(.neg, .{ .int = std.math.minInt(i32) }) == null);
    try std.testing.expect(std.math.signbit(binary(.div, .{ .float = -0.0 }, .{ .int = 2 }).?.float));
}

test "folding is bounded and leaves calls in short circuits" {
    const allocator = std.testing.allocator;
    var store = ir.IRStore.init(allocator);
    defer store.deinit();
    var constants = ir.ConstantPool.init(allocator);
    defer constants.deinit();
    const loc: ir.SourceLocation = .{ .line = 1, .column = 1, .offset = 0 };
    const yes = try store.addNode(.lit_bool, loc, .{ .a = 1, .b = 0 });
    const call = try store.addNode(.call, loc, .{ .a = 0, .b = 0 });
    const expr = try store.addBinary(loc, .{ .op = .or_op, .left = yes, .right = call });
    try std.testing.expect(fold(ir.IrView.fromIRStore(&store, &constants), expr) == null);
    var nested = yes;
    for (0..1000) |_| nested = try store.addUnary(loc, .{ .op = .not, .operand = nested });
    const count = store.tags.items.len;
    try std.testing.expect(fold(ir.IrView.fromIRStore(&store, &constants), nested) == null);
    try std.testing.expectEqual(count, store.tags.items.len);
    try std.testing.expectEqual(ir.NodeTag.unary_op, store.getTag(nested));
}
