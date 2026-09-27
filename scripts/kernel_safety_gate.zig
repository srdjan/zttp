const std = @import("std");

const minimum_files = 16;
const minimum_functions = 300;

const Counts = struct {
    functions: usize = 0,
    failures: usize = 0,
};

fn insideTest(tree: *const std.zig.Ast, token: std.zig.Ast.TokenIndex) bool {
    const offset = tree.tokenStart(token);
    const tags = tree.nodes.items(.tag);
    for (tags, 0..) |tag, index| {
        if (tag != .test_decl) continue;
        const node: std.zig.Ast.Node.Index = @enumFromInt(index);
        const first = tree.tokenStart(tree.firstToken(node));
        const last_token = tree.lastToken(node);
        const last = tree.tokenStart(last_token) + tree.tokenSlice(last_token).len;
        if (offset >= first and offset < last) return true;
    }
    return false;
}

fn isRuntimeSafetyStatement(tree: *const std.zig.Ast, statement: std.zig.Ast.Node.Index) bool {
    const first = tree.firstToken(statement);
    const last = tree.lastToken(statement);
    if (last != first + 3) return false;

    return tree.tokenTag(first) == .builtin and
        std.mem.eql(u8, tree.tokenSlice(first), "@setRuntimeSafety") and
        tree.tokenTag(first + 1) == .l_paren and
        std.mem.eql(u8, tree.tokenSlice(first + 2), "true") and
        tree.tokenTag(first + 3) == .r_paren;
}

fn sourceLine(tree: *const std.zig.Ast, token: std.zig.Ast.TokenIndex) usize {
    return tree.tokenLocation(0, token).line + 1;
}

fn checkFunctions(path: []const u8, tree: *const std.zig.Ast) Counts {
    var counts: Counts = .{};
    const tags = tree.nodes.items(.tag);
    for (tags, 0..) |tag, index| {
        if (tag != .fn_decl) continue;
        const node: std.zig.Ast.Node.Index = @enumFromInt(index);
        const fn_token = tree.nodeMainToken(node);
        if (insideTest(tree, fn_token)) continue;

        counts.functions += 1;
        const body = tree.nodeData(node).node_and_node[1];
        var statement_buffer: [2]std.zig.Ast.Node.Index = undefined;
        const statements = tree.blockStatements(&statement_buffer, body) orelse &.{};
        if (statements.len > 0 and isRuntimeSafetyStatement(tree, statements[0])) continue;

        std.debug.print(
            "kernel safety: {s}:{d}: function body does not begin with @setRuntimeSafety(true);\n",
            .{ path, sourceLine(tree, fn_token) },
        );
        counts.failures += 1;
    }
    return counts;
}

fn checkDebugAsserts(path: []const u8, tree: *const std.zig.Ast) usize {
    const expected = [_][]const u8{ "std", ".", "debug", ".", "assert" };
    const token_tags = tree.tokens.items(.tag);
    var failures: usize = 0;
    var index: usize = 0;
    while (index + expected.len <= token_tags.len) : (index += 1) {
        var matches = true;
        for (expected, 0..) |text, offset| {
            if (!std.mem.eql(u8, tree.tokenSlice(@intCast(index + offset)), text)) {
                matches = false;
                break;
            }
        }
        if (!matches) continue;

        const token: std.zig.Ast.TokenIndex = @intCast(index);
        if (insideTest(tree, token)) continue;
        std.debug.print(
            "kernel safety: {s}:{d}: std.debug.assert is not allowed outside a test block; use safety.check\n",
            .{ path, sourceLine(tree, token) },
        );
        failures += 1;
    }
    return failures;
}

/// A leading @setRuntimeSafety(true) is worth nothing if a later statement in
/// the same body turns safety back off, so any other setting outside a test
/// fails.
fn checkSafetyDisabled(path: []const u8, tree: *const std.zig.Ast) usize {
    var failures: usize = 0;
    var index: usize = 0;
    while (index + 2 < tree.tokens.len) : (index += 1) {
        const token: std.zig.Ast.TokenIndex = @intCast(index);
        if (tree.tokenTag(token) != .builtin) continue;
        if (!std.mem.eql(u8, tree.tokenSlice(token), "@setRuntimeSafety")) continue;
        if (std.mem.eql(u8, tree.tokenSlice(token + 2), "true")) continue;
        if (insideTest(tree, token)) continue;
        std.debug.print(
            "kernel safety: {s}:{d}: runtime safety may only be set to true outside a test block\n",
            .{ path, sourceLine(tree, token) },
        );
        failures += 1;
    }
    return failures;
}

fn checkFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    source_root: []const u8,
    path: []const u8,
) !Counts {
    const allocated_path = if (std.mem.eql(u8, source_root, "."))
        null
    else
        try std.fs.path.join(allocator, &.{ source_root, path });
    defer if (allocated_path) |value| allocator.free(value);
    const full_path = allocated_path orelse path;
    const source = std.Io.Dir.cwd().readFileAllocOptions(
        io,
        full_path,
        allocator,
        .limited(16 * 1024 * 1024),
        .of(u8),
        0,
    ) catch |err| {
        std.debug.print("kernel safety: cannot read {s}: {s}\n", .{ full_path, @errorName(err) });
        return err;
    };
    defer allocator.free(source);

    var tree = try std.zig.Ast.parse(allocator, source, .zig);
    defer tree.deinit(allocator);
    if (tree.errors.len != 0) {
        std.debug.print("kernel safety: {s}: Zig parser reported {d} error(s)\n", .{ path, tree.errors.len });
        return error.InvalidZigSource;
    }

    var counts = checkFunctions(path, &tree);
    counts.failures += checkDebugAsserts(path, &tree);
    counts.failures += checkSafetyDisabled(path, &tree);
    return counts;
}

pub fn main(init: std.process.Init) !void {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer _ = debug_allocator.deinit();
    const allocator = debug_allocator.allocator();

    var args = std.process.Args.Iterator.init(init.minimal.args);
    defer args.deinit();
    _ = args.next();

    var source_root: []const u8 = ".";
    var file_count: usize = 0;
    var function_count: usize = 0;
    var failure_count: usize = 0;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--root")) {
            source_root = args.next() orelse {
                std.debug.print("kernel safety: --root requires a path\n", .{});
                std.process.exit(2);
            };
            continue;
        }

        file_count += 1;
        const counts = checkFile(allocator, init.io, source_root, arg) catch {
            failure_count += 1;
            continue;
        };
        function_count += counts.functions;
        failure_count += counts.failures;
    }

    if (file_count < minimum_files) {
        std.debug.print(
            "kernel safety: found only {d} proof-checker source files; expected at least {d}\n",
            .{ file_count, minimum_files },
        );
        failure_count += 1;
    }
    if (function_count < minimum_functions) {
        std.debug.print(
            "kernel safety: found only {d} non-test function bodies; expected at least {d}\n",
            .{ function_count, minimum_functions },
        );
        failure_count += 1;
    }
    if (failure_count != 0) std.process.exit(1);

    std.debug.print(
        "kernel safety OK: checked {d} non-test function bodies in {d} files\n",
        .{ function_count, file_count },
    );
}
