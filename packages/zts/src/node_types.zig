//! Per-node expression types, shared between the checker that infers them and
//! the code generator that consumes them.
//!
//! `BoolChecker` populates a `NodeTypeMap` during its walk and `CodeGen` reads
//! it to emit specialized opcodes (`add_num` instead of `add`, and so on). Both
//! sides need the vocabulary; only one side needs the checker.
//!
//! These two declarations lived in `bool_checker.zig`, which made
//! `parser/codegen.zig` import the whole boolean analysis - and through it the
//! module-facts table and the IR walk - to name a nine-case enum. This file has
//! no dependency beyond the IR node index. See
//! docs/plans/2026-08-07-021-zts-three-module-split-plan.md.

const std = @import("std");
const ir = @import("parser/ir.zig");

pub const ExprType = enum(u8) {
    boolean, // true/false, comparisons, !(bool), &&/|| of bools
    number, // int/float literals, arithmetic, bitwise, unary -/+/~
    string, // string/template literals, typeof
    undefined, // undefined literal
    object, // object/array literals
    function, // function/arrow expressions
    unknown, // cannot determine statically (params, fn calls, let vars, property access)
    // Optional variants: T | undefined
    optional_string, // e.g. env(), parseBearer(), cacheGet()
    optional_object, // e.g. routerMatch()

    /// Returns true if this type is known to never be undefined.
    pub fn isNonNullable(self: ExprType) bool {
        return switch (self) {
            .boolean, .number, .string, .object, .function => true,
            else => false,
        };
    }

    /// Remove optionality from a type: optional_string -> string, etc.
    /// Returns .unknown for types that are purely undefined.
    pub fn removeNullish(self: ExprType) ExprType {
        return switch (self) {
            .optional_string => .string,
            .optional_object => .object,
            .undefined => .unknown,
            else => self,
        };
    }
};

/// Per-node type annotation map for type-directed codegen.
/// Populated by BoolChecker during its walk, consumed by CodeGen to emit specialized opcodes.
pub const NodeTypeMap = std.AutoHashMapUnmanaged(ir.NodeIndex, ExprType);

test "ExprType optionality queries" {
    try std.testing.expect(ExprType.string.isNonNullable());
    try std.testing.expect(!ExprType.optional_string.isNonNullable());
    try std.testing.expect(!ExprType.undefined.isNonNullable());

    try std.testing.expectEqual(ExprType.string, ExprType.optional_string.removeNullish());
    try std.testing.expectEqual(ExprType.object, ExprType.optional_object.removeNullish());
    try std.testing.expectEqual(ExprType.unknown, ExprType.undefined.removeNullish());
    try std.testing.expectEqual(ExprType.number, ExprType.number.removeNullish());
}
