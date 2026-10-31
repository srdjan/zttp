//! Single-file compilation entry points.
//!
//! `compile` turns a source fragment into bytecode through the typed parser
//! and its admission step. It serves the semantics corpus, whose fragments
//! are not source files.

const std = @import("std");
const parser = @import("zts-engine").parser;
const source_frontend = @import("zts-engine").source_frontend;
const bytecode = @import("zts-engine").bytecode;
const value = @import("zts-engine").value;
const string = @import("zts-engine").string;
const context = @import("zts-engine").context;

// ============================================================================
// Simple Single-Threaded Compile API
// ============================================================================

/// Compile source code to bytecode (simple API for single files)
pub fn compile(
    allocator: std.mem.Allocator,
    source: []const u8,
) !*bytecode.FunctionBytecode {
    var strings = string.StringTable.init(allocator);
    defer strings.deinit();

    var p = try parser.Parser.initTyped(allocator, allocator, source, &strings, null);
    defer p.deinit();

    switch (try p.parseTypedIr()) {
        .accepted => {},
        .parser_refused => |refusal| return refusal.first_error,
        .terminal_admission_refused => |failure| return source_frontend.prepareErrorForAdmissionFailure(failure),
        .recovered_admission_refused => unreachable,
    }
    const code = try p.generateParsed(allocator);

    // Copy code and constants to output allocator (parser memory is freed on deinit)
    const code_copy = try allocator.dupe(u8, code);
    errdefer allocator.free(code_copy);

    const constants_copy = try allocator.dupe(value.JSValue, p.constants.items);
    errdefer allocator.free(constants_copy);

    const line_table_copy = try allocator.dupe(bytecode.LineEntry, p.getLineTable());
    errdefer allocator.free(line_table_copy);

    const func = try allocator.create(bytecode.FunctionBytecode);
    func.* = .{
        .header = .{},
        .name_atom = 0,
        .arg_count = 0,
        .local_count = @intCast(p.max_local_count),
        .stack_size = @intCast(p.max_local_count + 16),
        .flags = .{},
        .upvalue_count = 0,
        .upvalue_info = &.{},
        .code = code_copy,
        .constants = constants_copy,
        .source_map = null,
        .line_table = line_table_copy,
    };

    return func;
}

// ============================================================================
// Tests
// ============================================================================

test "compile rejects object declaration destructuring" {
    const allocator = std.testing.allocator;

    try std.testing.expectError(
        error.ParseError,
        compile(allocator, "let obj = { a: 1, b: 2 }; const { a } = obj;"),
    );
}

test "compile rejects array declaration destructuring" {
    const allocator = std.testing.allocator;

    try std.testing.expectError(
        error.ParseError,
        compile(allocator, "let arr = [10, 20]; const [x] = arr;"),
    );
}

test "simple compile API" {
    const allocator = std.testing.allocator;

    // Use 'let' instead of 'var' - zts is strict mode only
    const func = try compile(allocator, "let x = 42;");
    defer {
        allocator.free(func.code);
        allocator.free(func.constants);
        if (func.line_table) |line_table| {
            if (line_table.len > 0) allocator.free(line_table);
        }
        allocator.destroy(func);
    }

    try std.testing.expect(func.code.len > 0);
    // The generator ends every program with ret_undefined.
    try std.testing.expectEqual(@backingInt(bytecode.Opcode.ret_undefined), func.code[func.code.len - 1]);
}

test "compile erases annotations from a fragment" {
    const allocator = std.testing.allocator;
    const annotated = try compile(allocator, "const value: number = 1; value;");
    defer {
        allocator.free(annotated.code);
        allocator.free(annotated.constants);
        if (annotated.line_table) |lines| allocator.free(lines);
        allocator.destroy(annotated);
    }
    const plain = try compile(allocator, "const value         = 1; value;");
    defer {
        allocator.free(plain.code);
        allocator.free(plain.constants);
        if (plain.line_table) |lines| allocator.free(lines);
        allocator.destroy(plain);
    }
    try std.testing.expectEqualSlices(u8, plain.code, annotated.code);
    try std.testing.expectEqualSlices(value.JSValue, plain.constants, annotated.constants);
}
