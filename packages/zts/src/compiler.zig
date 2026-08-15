//! Single-file compilation entry points.
//!
//! `compile` and `compileWithOptions` turn source into bytecode for one file.
//!
//! The parallel multi-file driver that once lived here (a `Compiler` struct, a
//! `CompileUnit` list, and a shared `ThreadSafeInternPool`) was removed during
//! the reset: it had no caller anywhere in the repository, and its only
//! importer used these two functions. See
//! docs/plans/2026-07-28-001-reset-simplification-plan.md.

const std = @import("std");
const parser = @import("zts-engine").parser;
const bytecode = @import("zts-engine").bytecode;
const value = @import("zts-engine").value;
const string = @import("zts-engine").string;
const context = @import("zts-engine").context;
const source_frontend = @import("zts-engine").source_frontend;

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

    var p = try parser.Parser.init(allocator, source, &strings, null);
    defer p.deinit();

    const code = try p.parse();

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

/// Compile with options
pub const CompileOptions = struct {
    strict_mode: bool = true,
    filename: []const u8 = "<eval>",
};

pub fn compileWithOptions(
    allocator: std.mem.Allocator,
    source: []const u8,
    options: CompileOptions,
) !*bytecode.FunctionBytecode {
    var prepared = try source_frontend.PreparedSource.init(allocator, source, options.filename, .{});
    defer prepared.deinit();
    var strings = string.StringTable.init(allocator);
    defer strings.deinit();

    var p = try parser.Parser.init(allocator, prepared.parserInput(), &strings, null);
    defer p.deinit();
    // Note: strict_mode is always true in zts (var keyword rejected)

    const code = try p.parse();

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

// The three tests that exercised the removed parallel driver went with it.
// These two assert language behavior, not driver mechanics, so they are kept
// and rewritten against `compile`.

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
}
