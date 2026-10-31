//! Completeness check for `IrView.expressionChildren`, the one child visitor for
//! expressions and statements.
//!
//! `expressionChildren` names every `NodeTag` in an exhaustive switch, so a new tag fails to
//! compile there. This file adds the second half of that decision: every tag also has a row in
//! `decision` below, and the test parses a witness source for each row and compares the children
//! the visitor yields with the row. A new tag fails to compile here until someone states whether
//! it has children (`yields`) or has none on purpose (`leaf`). The row for a tag with children
//! lists them in source order, so a child that the visitor stops yielding fails the matching row,
//! not a distant verdict.

const std = @import("std");
const ir = @import("ir.zig");
const parse = @import("parse.zig");

const NodeTag = ir.NodeTag;
const NodeIndex = ir.NodeIndex;
const IrView = ir.IrView;
const null_node = ir.null_node;

const Row = union(enum) {
    /// The visitor yields exactly `children`, in order, for the `nth` node with this tag in the
    /// parse of `source`. `children` is never empty.
    yields: struct { source: []const u8, nth: usize = 0, children: []const NodeTag },
    /// The visitor yields nothing, for the stated reason. `source` is a witness when the parser
    /// can produce the tag.
    leaf: struct { reason: []const u8, source: ?[]const u8 = null, nth: usize = 0 },
};

fn yields(source: []const u8, children: []const NodeTag) Row {
    return .{ .yields = .{ .source = source, .children = children } };
}

fn yieldsNth(source: []const u8, nth: usize, children: []const NodeTag) Row {
    return .{ .yields = .{ .source = source, .nth = nth, .children = children } };
}

fn leafOf(reason: []const u8, source: []const u8) Row {
    return .{ .leaf = .{ .reason = reason, .source = source } };
}

fn leafNth(reason: []const u8, source: []const u8, nth: usize) Row {
    return .{ .leaf = .{ .reason = reason, .source = source, .nth = nth } };
}

/// The decision for every tag. No `else` arm: a new `NodeTag` member is a compile error here.
fn decision(comptime tag: NodeTag) Row {
    return switch (tag) {
        .lit_int => leafOf("a literal holds a constant, not a child node", "const r = 1;"),
        .lit_float => leafOf("a literal holds a constant, not a child node", "const r = 1.5;"),
        .lit_string => leafOf("a literal holds a constant, not a child node", "const r = \"s\";"),
        .lit_bool => leafOf("a literal holds a constant, not a child node", "const r = true;"),
        .lit_null => leafOf("a literal holds a constant, not a child node", "const r = null;"),
        .lit_undefined => leafOf("a literal holds a constant, not a child node", "const r = undefined;"),
        .identifier => leafNth("a reference names a binding, not a child node", "const r = a;", 0),
        .binary_op => yields("const r = a + b;", &.{ .identifier, .identifier }),
        .unary_op => yields("const r = !a;", &.{.identifier}),
        .ternary => yields("const r = a ? b : c;", &.{ .identifier, .identifier, .identifier }),
        .call => yields("f(a, b);", &.{ .identifier, .identifier, .identifier }),
        .member_access => yields("const r = a.b;", &.{.identifier}),
        .computed_access => yields("const r = a[b];", &.{ .identifier, .identifier }),
        .optional_chain => yields("const r = a?.b;", &.{.identifier}),
        .assignment => yields("a.b = c;", &.{ .member_access, .identifier }),
        .array_literal => yields("const r = [a, ...b];", &.{ .identifier, .spread }),
        .object_literal => yields("const r = { k: a, ...b };", &.{ .object_property, .object_spread }),
        .object_property => yields("const r = { k: a };", &.{.identifier}),
        .object_spread => yields("const r = { ...b };", &.{.identifier}),
        .function_expr => yields("function f(a) { return a; }", &.{.block}),
        .arrow_function => yields("const f = (a) => a;", &.{.return_stmt}),
        .spread => yields("const r = [...b];", &.{.identifier}),
        .match_expr => yields("const r = match (a) { when 1: 1 default: 2 };", &.{ .identifier, .match_arm, .match_arm }),
        .match_arm => yields("const r = match (a) { when 1: b default: 2 };", &.{.identifier}),
        .match_pattern => leafOf(
            "a pattern is a test, not code: the visitor excludes match patterns on purpose",
            "const r = match (a) { when { kind: \"x\" }: 1 default: 2 };",
        ),
        .match_type_test => leafOf(
            "the parser builds a type test's predicate as a call; reaching it would mark every type-test match as unknown",
            "const r = match (a) { when string: 1 default: 2 };",
        ),
        .expr_stmt => yields("f();", &.{.call}),
        .var_decl => yields("const a = b;", &.{.identifier}),
        .if_stmt => yields("if (a) { f(); } else { g(); }", &.{ .identifier, .block, .block }),
        .for_of_stmt => yields("for (const x of xs) { f(x); }", &.{ .identifier, .block }),
        .return_stmt => yields("function f() { return a; }", &.{.identifier}),
        .assert_stmt => yields("assert a, b;", &.{ .identifier, .identifier }),
        .break_stmt => leafOf("a jump holds no expression", "function g(xs) { for (const x of xs) { break; } }"),
        .continue_stmt => leafOf("a jump holds no expression", "function g(xs) { for (const x of xs) { continue; } }"),
        .block => yields("function f() { g(); return 1; }", &.{ .expr_stmt, .return_stmt }),
        .function_decl => yields("function f(a) { return a; }", &.{.function_expr}),
        .array_pattern => leafOf(
            "a pattern is a test, not code: the visitor excludes match patterns on purpose",
            "const r = match (a) { when [1, 2]: 1 default: 2 };",
        ),
        .pattern_element => leafNth(
            "a parameter binding holds a name; only a default value is code, and this one has none",
            "function f(a) { return a; }",
            0,
        ),
        .import_decl => leafOf(
            "an import names bindings and a module path; it holds no code",
            "import { env } from \"zttp:env\";",
        ),
        .import_specifier => leafOf("a specifier names a binding; it holds no code", "import { a as b } from \"zttp:env\";"),
        .export_decl => yields("export function f() { return 1; }", &.{.function_decl}),
        .program => yieldsNth("const a = 1; f();", 0, &.{ .var_decl, .expr_stmt }),
    };
}

fn expectChildren(source: []const u8, tag: NodeTag, nth: usize, expected: []const NodeTag) !void {
    const allocator = std.testing.allocator;
    var parser = try parse.Parser.initAdmission(allocator, allocator, source, .compile);
    defer parser.deinit();
    _ = try parser.parse();
    if (parser.errors.hasErrors()) {
        std.debug.print("witness for {s} does not parse: {s}\n", .{ @tagName(tag), source });
        return error.TestWitnessRefused;
    }
    const view = IrView.fromIRStore(&parser.nodes, &parser.constants);

    var seen: usize = 0;
    var node: NodeIndex = null_node;
    var i: NodeIndex = 0;
    while (i < view.nodeCount()) : (i += 1) {
        if (view.getTag(i) != tag) continue;
        if (seen == nth) {
            node = i;
            break;
        }
        seen += 1;
    }
    if (node == null_node) {
        std.debug.print("no {s} node in witness: {s}\n", .{ @tagName(tag), source });
        return error.TestNodeNotFound;
    }

    var it = view.expressionChildren(node);
    var count: usize = 0;
    while (it.next()) |child| : (count += 1) {
        if (count >= expected.len) {
            std.debug.print("extra child of {s}: {s}\n", .{ @tagName(tag), @tagName(view.getTag(child).?) });
            return error.TestUnexpectedChild;
        }
        if (view.getTag(child).? != expected[count]) {
            std.debug.print("child {d} of {s} is {s}, want {s}\n", .{
                count,
                @tagName(tag),
                @tagName(view.getTag(child).?),
                @tagName(expected[count]),
            });
            return error.TestChildTagMismatch;
        }
    }
    try std.testing.expectEqual(expected.len, count);
}

test "every NodeTag has a child decision and its witness matches the visitor" {
    inline for (@typeInfo(NodeTag).@"enum".field_names) |name| {
        const tag = @field(NodeTag, name);
        switch (comptime decision(tag)) {
            .yields => |row| {
                try std.testing.expect(row.children.len > 0);
                try expectChildren(row.source, tag, row.nth, row.children);
            },
            .leaf => |row| {
                try std.testing.expect(row.reason.len > 0);
                if (row.source) |source| try expectChildren(source, tag, row.nth, &.{});
            },
        }
    }
}

test "the child decisions account for every NodeTag once" {
    var yielding: usize = 0;
    var leaf: usize = 0;
    inline for (@typeInfo(NodeTag).@"enum".field_names) |name| {
        switch (comptime decision(@field(NodeTag, name))) {
            .yields => yielding += 1,
            .leaf => leaf += 1,
        }
    }
    try std.testing.expectEqual(@typeInfo(NodeTag).@"enum".field_names.len, yielding + leaf);
    // The floor: a table that decided nothing would satisfy the sum above only by listing no tag.
    try std.testing.expect(yielding >= 25);
    try std.testing.expect(leaf >= 8);
}
