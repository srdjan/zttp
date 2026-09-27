const std = @import("std");
const residual = @import("residual");
const guard_catalog = @import("guard_catalog");

const OutputPaths = struct {
    checker_catalog: []const u8,
    checker_doc_catalog: []const u8,
    mirror_catalog: []const u8,
    checker_enabled: []const u8,
    enabled: []const u8,
};

fn tokenIs(tree: *const std.zig.Ast, index: usize, expected: []const u8) bool {
    if (index >= tree.tokens.len) return false;
    return std.mem.eql(u8, tree.tokenSlice(@intCast(index)), expected);
}

fn catalogImplNames(
    allocator: std.mem.Allocator,
    source: [:0]const u8,
    expected_count: usize,
) ![][]const u8 {
    var tree = try std.zig.Ast.parse(allocator, source, .zig);
    defer tree.deinit(allocator);
    if (tree.errors.len != 0) return error.InvalidZigSource;

    var catalog_count: usize = 0;
    var catalog_token: usize = 0;
    var index: usize = 0;
    while (index + 2 < tree.tokens.len) : (index += 1) {
        if (!tokenIs(&tree, index, "const") or !tokenIs(&tree, index + 1, "catalog") or !tokenIs(&tree, index + 2, "=")) continue;
        catalog_count += 1;
        catalog_token = index + 2;
    }
    if (catalog_count != 1) return error.CatalogDeclarationAmbiguous;

    var open = catalog_token;
    while (open < tree.tokens.len and !tokenIs(&tree, open, "{")) : (open += 1) {}
    if (open == tree.tokens.len) return error.CatalogBodyMissing;

    var names: std.ArrayList([]const u8) = .empty;
    errdefer names.deinit(allocator);
    var depth: usize = 0;
    index = open;
    while (index < tree.tokens.len) : (index += 1) {
        if (tokenIs(&tree, index, "{")) {
            depth += 1;
            continue;
        }
        if (tokenIs(&tree, index, "}")) {
            if (depth == 0) return error.CatalogBodyInvalid;
            depth -= 1;
            if (depth == 0) break;
            continue;
        }
        if (depth != 2 or index + 5 >= tree.tokens.len) continue;
        if (!tokenIs(&tree, index, ".") or
            !tokenIs(&tree, index + 1, "impl_id") or
            !tokenIs(&tree, index + 2, "=") or
            !tokenIs(&tree, index + 3, "guard_impl") or
            !tokenIs(&tree, index + 4, ".")) continue;
        try names.append(allocator, tree.tokenSlice(@intCast(index + 5)));
    }
    if (depth != 0) return error.CatalogBodyInvalid;
    if (names.items.len != expected_count) return error.CatalogImplCountMismatch;
    return names.toOwnedSlice(allocator);
}

fn writeOutput(io: std.Io, path: []const u8, bytes: []const u8) !void {
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = bytes });
}

fn extract(
    allocator: std.mem.Allocator,
    io: std.Io,
    residual_source_path: []const u8,
    outputs: OutputPaths,
) !void {
    const checker_source = try std.Io.Dir.cwd().readFileAllocOptions(
        io,
        residual_source_path,
        allocator,
        .limited(1024 * 1024),
        .of(u8),
        0,
    );
    defer allocator.free(checker_source);

    const impl_names = try catalogImplNames(allocator, checker_source, residual.catalog.len);
    defer allocator.free(impl_names);

    var checker_catalog: std.Io.Writer.Allocating = .init(allocator);
    defer checker_catalog.deinit();
    var checker_doc_catalog: std.Io.Writer.Allocating = .init(allocator);
    defer checker_doc_catalog.deinit();
    for (residual.catalog, impl_names) |row, impl_name| {
        try checker_catalog.writer.print(
            "{s}|{s}|{d}|{s}\n",
            .{ row.module, row.export_name, row.arg_index, @tagName(row.kind) },
        );
        try checker_doc_catalog.writer.print(
            "{s}|{s}|{d}|{s}|{s}|{s}|{s}|{s}={d}\n",
            .{
                row.module,
                row.export_name,
                row.arg_index,
                @tagName(row.kind),
                @tagName(row.kind.normalization()),
                @tagName(row.kind.section()),
                @tagName(row.kind.sink()),
                impl_name,
                row.impl_id,
            },
        );
    }

    var mirror_catalog: std.Io.Writer.Allocating = .init(allocator);
    defer mirror_catalog.deinit();
    for (guard_catalog.entries) |row| {
        try mirror_catalog.writer.print(
            "{s}|{s}|{d}|{s}\n",
            .{ row.module, row.export_name, row.arg_index, @tagName(row.kind) },
        );
    }

    var checker_enabled: std.Io.Writer.Allocating = .init(allocator);
    defer checker_enabled.deinit();
    for (std.enums.values(residual.Family)) |family| {
        if (residual.enabled_families.contains(family)) try checker_enabled.writer.print("{s}\n", .{@tagName(family)});
    }

    var enabled: std.Io.Writer.Allocating = .init(allocator);
    defer enabled.deinit();
    for (std.enums.values(guard_catalog.Family)) |family| {
        if (guard_catalog.measured_families.contains(family)) try enabled.writer.print("{s}\n", .{@tagName(family)});
    }

    try writeOutput(io, outputs.checker_catalog, checker_catalog.written());
    try writeOutput(io, outputs.checker_doc_catalog, checker_doc_catalog.written());
    try writeOutput(io, outputs.mirror_catalog, mirror_catalog.written());
    try writeOutput(io, outputs.checker_enabled, checker_enabled.written());
    try writeOutput(io, outputs.enabled, enabled.written());
}

pub fn main(init: std.process.Init) !void {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer _ = debug_allocator.deinit();
    const allocator = debug_allocator.allocator();

    var args = std.process.Args.Iterator.init(init.minimal.args);
    defer args.deinit();
    _ = args.next();

    const residual_source_path = args.next() orelse return error.MissingResidualSourcePath;
    const outputs: OutputPaths = .{
        .checker_catalog = args.next() orelse return error.MissingOutputPath,
        .checker_doc_catalog = args.next() orelse return error.MissingOutputPath,
        .mirror_catalog = args.next() orelse return error.MissingOutputPath,
        .checker_enabled = args.next() orelse return error.MissingOutputPath,
        .enabled = args.next() orelse return error.MissingOutputPath,
    };
    if (args.next() != null) return error.UnexpectedArgument;

    try extract(allocator, init.io, residual_source_path, outputs);
}

test "catalog implementation names follow catalog rows" {
    const source: [:0]const u8 =
        \\pub const catalog = [_]CatalogEntry{
        \\    .{ .impl_id = guard_impl.first },
        \\    .{ .impl_id = guard_impl.second },
        \\};
    ;
    const names = try catalogImplNames(std.testing.allocator, source, 2);
    defer std.testing.allocator.free(names);
    try std.testing.expectEqual(@as(usize, 2), names.len);
    try std.testing.expectEqualStrings("first", names[0]);
    try std.testing.expectEqualStrings("second", names[1]);
}
