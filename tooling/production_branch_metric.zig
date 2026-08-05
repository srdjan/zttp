//! Repository-only production branch metric.
//!
//! This is a maintenance signal, not a product binary. It parses Zig sources
//! with `std.zig.Ast`, excludes inline `test` bodies from production totals,
//! and reports stable per-package counts. The definition intentionally counts
//! explicit paths rather than treating every exhaustive switch as a problem:
//! one point per `if`, `else`, non-default switch prong, loop, `catch`,
//! `orelse`, boolean short circuit, and distinct return inside a branch body.
//!
//! Run the tracked-source gate with:
//!
//!     zig build production-branch-metric-json

const std = @import("std");

const Package = enum {
    modules,
    pi,
    proof_review,
    runtime,
    tools,
    zts,
    zttp_sdk,
    repo,

    fn label(self: Package) []const u8 {
        return switch (self) {
            .modules => "modules",
            .pi => "pi",
            .proof_review => "proof-review",
            .runtime => "runtime",
            .tools => "tools",
            .zts => "zts",
            .zttp_sdk => "zttp-sdk",
            .repo => "repo",
        };
    }
};

const package_count = @typeInfo(Package).@"enum".fields.len;
const required_packages = [_]Package{
    .modules,
    .pi,
    .proof_review,
    .runtime,
    .tools,
    .zts,
    .zttp_sdk,
};

const Counts = struct {
    files: usize = 0,
    production_functions: usize = 0,
    production_branches: usize = 0,
    test_branches: usize = 0,

    fn add(self: *Counts, other: Counts) void {
        self.files += other.files;
        self.production_functions += other.production_functions;
        self.production_branches += other.production_branches;
        self.test_branches += other.test_branches;
    }

    fn cyclomatic(self: Counts) usize {
        return self.production_functions + self.production_branches;
    }
};

const Report = struct {
    totals: Counts = .{},
    packages: [package_count]Counts = [_]Counts{.{}} ** package_count,
    parse_failures: usize = 0,

    fn add(self: *Report, package: Package, counts: Counts) void {
        self.totals.add(counts);
        self.packages[@intFromEnum(package)].add(counts);
    }
};

fn missingRequiredPackage(report: Report) ?Package {
    for (required_packages) |package| {
        if (report.packages[@intFromEnum(package)].files == 0) return package;
    }
    return null;
}

const TokenRange = struct {
    first: std.zig.Ast.TokenIndex,
    last: std.zig.Ast.TokenIndex,
};

fn packageForPath(path: []const u8) error{UnknownPackage}!Package {
    const prefix = "packages/";
    if (!std.mem.startsWith(u8, path, prefix)) return .repo;
    const rest = path[prefix.len..];
    const slash = std.mem.findScalar(u8, rest, '/') orelse return error.UnknownPackage;
    const name = rest[0..slash];
    for (required_packages) |package| {
        if (std.mem.eql(u8, name, package.label())) return package;
    }
    return error.UnknownPackage;
}

fn mergeRanges(ranges: *std.ArrayList(TokenRange)) void {
    std.mem.sort(TokenRange, ranges.items, {}, struct {
        fn lessThan(_: void, lhs: TokenRange, rhs: TokenRange) bool {
            return lhs.first < rhs.first or (lhs.first == rhs.first and lhs.last < rhs.last);
        }
    }.lessThan);
    if (ranges.items.len < 2) return;

    var merged: usize = 0;
    for (ranges.items[1..]) |range| {
        const current = &ranges.items[merged];
        if (range.first <= current.last) {
            current.last = @max(current.last, range.last);
        } else {
            merged += 1;
            ranges.items[merged] = range;
        }
    }
    ranges.shrinkRetainingCapacity(merged + 1);
}

fn tokenInRanges(token: std.zig.Ast.TokenIndex, ranges: []const TokenRange) bool {
    var low: usize = 0;
    var high = ranges.len;
    while (low < high) {
        const middle = low + (high - low) / 2;
        const range = ranges[middle];
        if (token < range.first) {
            high = middle;
        } else if (token > range.last) {
            low = middle + 1;
        } else {
            return true;
        }
    }
    return false;
}

fn appendNodeRange(
    allocator: std.mem.Allocator,
    tree: std.zig.Ast,
    ranges: *std.ArrayList(TokenRange),
    node: std.zig.Ast.Node.Index,
) !void {
    try ranges.append(allocator, .{
        .first = tree.firstToken(node),
        .last = tree.lastToken(node),
    });
}

fn countTree(allocator: std.mem.Allocator, tree: std.zig.Ast) !Counts {
    const tags = tree.nodes.items(.tag);
    var test_ranges: std.ArrayList(TokenRange) = .empty;
    defer test_ranges.deinit(allocator);
    var branch_ranges: std.ArrayList(TokenRange) = .empty;
    defer branch_ranges.deinit(allocator);

    for (tags, 0..) |tag, raw_index| {
        const node: std.zig.Ast.Node.Index = @enumFromInt(raw_index);
        switch (tag) {
            .test_decl => {
                const body = tree.nodeData(node).opt_token_and_node[1];
                try appendNodeRange(allocator, tree, &test_ranges, body);
            },
            .if_simple, .@"if" => {
                const info = tree.fullIf(node).?.ast;
                try appendNodeRange(allocator, tree, &branch_ranges, info.then_expr);
                if (info.else_expr.unwrap()) |body| {
                    try appendNodeRange(allocator, tree, &branch_ranges, body);
                }
            },
            .while_simple, .while_cont, .@"while" => {
                const info = tree.fullWhile(node).?.ast;
                try appendNodeRange(allocator, tree, &branch_ranges, info.then_expr);
                if (info.else_expr.unwrap()) |body| {
                    try appendNodeRange(allocator, tree, &branch_ranges, body);
                }
            },
            .for_simple, .@"for" => {
                const info = tree.fullFor(node).?.ast;
                try appendNodeRange(allocator, tree, &branch_ranges, info.then_expr);
                if (info.else_expr.unwrap()) |body| {
                    try appendNodeRange(allocator, tree, &branch_ranges, body);
                }
            },
            .switch_case_one, .switch_case_inline_one, .switch_case, .switch_case_inline => {
                const body = tree.fullSwitchCase(node).?.ast.target_expr;
                try appendNodeRange(allocator, tree, &branch_ranges, body);
            },
            .bool_and, .bool_or, .@"orelse", .@"catch" => {
                const rhs = tree.nodeData(node).node_and_node[1];
                try appendNodeRange(allocator, tree, &branch_ranges, rhs);
            },
            else => {},
        }
    }
    mergeRanges(&test_ranges);
    mergeRanges(&branch_ranges);

    var counts: Counts = .{ .files = 1 };
    for (tags, 0..) |tag, raw_index| {
        const node: std.zig.Ast.Node.Index = @enumFromInt(raw_index);
        const token = tree.nodeMainToken(node);
        const in_test = tokenInRanges(token, test_ranges.items);
        var branches: usize = 0;

        switch (tag) {
            .if_simple, .@"if" => {
                branches += 1;
                if (tree.fullIf(node).?.ast.else_expr != .none) branches += 1;
            },
            .while_simple, .while_cont, .@"while" => {
                branches += 1;
                if (tree.fullWhile(node).?.ast.else_expr != .none) branches += 1;
            },
            .for_simple, .@"for" => {
                branches += 1;
                if (tree.fullFor(node).?.ast.else_expr != .none) branches += 1;
            },
            .switch_case_one, .switch_case_inline_one, .switch_case, .switch_case_inline => {
                if (tree.fullSwitchCase(node).?.ast.values.len != 0) branches += 1;
            },
            .bool_and, .bool_or, .@"orelse", .@"catch" => branches += 1,
            .@"return" => {
                if (tokenInRanges(token, branch_ranges.items)) branches += 1;
            },
            .fn_decl => {
                if (!in_test) counts.production_functions += 1;
            },
            else => {},
        }

        if (in_test) {
            counts.test_branches += branches;
        } else {
            counts.production_branches += branches;
        }
    }
    return counts;
}

fn countSource(allocator: std.mem.Allocator, source: [:0]const u8) !Counts {
    var tree = try std.zig.Ast.parse(allocator, source, .zig);
    defer tree.deinit(allocator);
    if (tree.errors.len != 0) return error.ParseFailed;
    return countTree(allocator, tree);
}

fn countFile(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
) !Counts {
    const source = try std.Io.Dir.cwd().readFileAllocOptions(io, path, allocator, .unlimited, .of(u8), 0);
    defer allocator.free(source);
    return countSource(allocator, source);
}

fn collect(
    io: std.Io,
    allocator: std.mem.Allocator,
    paths: []const []const u8,
    require_package_floor: bool,
) !Report {
    if (paths.len == 0) return error.NoProductionInputs;

    var report: Report = .{};
    for (paths) |path| {
        const package = try packageForPath(path);
        const counts = countFile(io, allocator, path) catch |err| {
            report.parse_failures += 1;
            std.debug.print("production branch metric: {s}: {s}\n", .{ path, @errorName(err) });
            continue;
        };
        report.add(package, counts);
    }

    if (report.parse_failures != 0) return error.ParseFailed;
    if (report.totals.files == 0) return error.NoProductionInputs;
    if (require_package_floor) {
        if (missingRequiredPackage(report)) |package| {
            std.debug.print("production branch metric: package floor missing {s}\n", .{package.label()});
            return error.PackageFloorMissing;
        }
    }
    return report;
}

fn writeText(writer: *std.Io.Writer, report: Report) !void {
    try writer.print(
        "production_branch_metric files={d} production_branches={d} production_functions={d} cyclomatic_sum={d} test_branches={d} parse_failures={d}\n",
        .{
            report.totals.files,
            report.totals.production_branches,
            report.totals.production_functions,
            report.totals.cyclomatic(),
            report.totals.test_branches,
            report.parse_failures,
        },
    );
    for (std.enums.values(Package)) |package| {
        const counts = report.packages[@intFromEnum(package)];
        if (counts.files == 0) continue;
        try writer.print(
            "package={s} files={d} production_branches={d} production_functions={d} cyclomatic_sum={d}\n",
            .{ package.label(), counts.files, counts.production_branches, counts.production_functions, counts.cyclomatic() },
        );
    }
}

fn writeJson(writer: *std.Io.Writer, report: Report) !void {
    try writer.print(
        "{{\"files\":{d},\"productionBranches\":{d},\"productionFunctions\":{d},\"cyclomaticSum\":{d},\"testBranches\":{d},\"parseFailures\":{d},\"packages\":[",
        .{
            report.totals.files,
            report.totals.production_branches,
            report.totals.production_functions,
            report.totals.cyclomatic(),
            report.totals.test_branches,
            report.parse_failures,
        },
    );
    var emitted: usize = 0;
    for (std.enums.values(Package)) |package| {
        const counts = report.packages[@intFromEnum(package)];
        if (counts.files == 0) continue;
        if (emitted != 0) try writer.writeAll(",");
        try writer.print(
            "{{\"name\":\"{s}\",\"files\":{d},\"productionBranches\":{d},\"productionFunctions\":{d},\"cyclomaticSum\":{d}}}",
            .{ package.label(), counts.files, counts.production_branches, counts.production_functions, counts.cyclomatic() },
        );
        emitted += 1;
    }
    try writer.writeAll("]}\n");
}

pub fn main(init: std.process.Init.Minimal) !void {
    const allocator = std.heap.smp_allocator;
    var io_backend = std.Io.Threaded.init(allocator, .{ .environ = .empty });
    defer io_backend.deinit();

    var args = std.process.Args.Iterator.init(init.args);
    defer args.deinit();
    _ = args.next();

    var json = false;
    var require_package_floor = false;
    var paths0_from_stdin = false;
    var paths: std.ArrayList([]const u8) = .empty;
    defer paths.deinit(allocator);
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--json")) {
            json = true;
        } else if (std.mem.eql(u8, arg, "--require-package-floor")) {
            require_package_floor = true;
        } else if (std.mem.eql(u8, arg, "--paths0-from-stdin")) {
            paths0_from_stdin = true;
        } else if (std.mem.startsWith(u8, arg, "--")) {
            std.debug.print("production branch metric: unknown option {s}\n", .{arg});
            return error.InvalidArgument;
        } else {
            try paths.append(allocator, arg);
        }
    }

    var stdin_paths: ?[]u8 = null;
    defer if (stdin_paths) |buffer| allocator.free(buffer);
    if (paths0_from_stdin) {
        var stdin_buffer: [4096]u8 = undefined;
        var stdin_reader = std.Io.File.stdin().reader(io_backend.io(), &stdin_buffer);
        const buffer = try stdin_reader.interface.allocRemaining(allocator, .limited(64 * 1024 * 1024));
        stdin_paths = buffer;
        var path_iterator = std.mem.splitScalar(u8, buffer, 0);
        while (path_iterator.next()) |path| {
            if (path.len != 0) try paths.append(allocator, path);
        }
    }

    const report = try collect(io_backend.io(), allocator, paths.items, require_package_floor);
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io_backend.io(), &stdout_buffer);
    defer stdout_writer.interface.flush() catch {};
    if (json) try writeJson(&stdout_writer.interface, report) else try writeText(&stdout_writer.interface, report);
}

test "metric pins decision semantics and excludes test bodies" {
    const source: [:0]const u8 = @embedFile("fixtures/production_branch_metric/decisions.zig.txt");
    const counts = try countSource(std.testing.allocator, source);
    try std.testing.expectEqual(@as(usize, 1), counts.files);
    try std.testing.expectEqual(@as(usize, 2), counts.production_functions);
    try std.testing.expectEqual(@as(usize, 10), counts.production_branches);
    try std.testing.expectEqual(@as(usize, 4), counts.test_branches);
}

test "metric rejects malformed Zig" {
    const source: [:0]const u8 = @embedFile("fixtures/production_branch_metric/malformed.zig.txt");
    try std.testing.expectError(error.ParseFailed, countSource(std.testing.allocator, source));
}

test "metric collection reports malformed Zig inputs" {
    var io_backend = std.Io.Threaded.init(std.testing.allocator, .{ .environ = .empty });
    defer io_backend.deinit();
    try std.testing.expectError(
        error.ParseFailed,
        collect(
            io_backend.io(),
            std.testing.allocator,
            &.{"tooling/fixtures/production_branch_metric/malformed.zig.txt"},
            false,
        ),
    );
}

test "metric rejects an empty production input" {
    var io_backend = std.Io.Threaded.init(std.testing.allocator, .{ .environ = .empty });
    defer io_backend.deinit();
    try std.testing.expectError(
        error.NoProductionInputs,
        collect(io_backend.io(), std.testing.allocator, &.{}, false),
    );
}

test "metric maps every current package bucket" {
    const cases = [_]struct { path: []const u8, expected: Package }{
        .{ .path = "packages/modules/src/root.zig", .expected = .modules },
        .{ .path = "packages/pi/src/root.zig", .expected = .pi },
        .{ .path = "packages/proof-review/src/root.zig", .expected = .proof_review },
        .{ .path = "packages/runtime/src/root.zig", .expected = .runtime },
        .{ .path = "packages/tools/src/root.zig", .expected = .tools },
        .{ .path = "packages/zts/src/root.zig", .expected = .zts },
        .{ .path = "packages/zttp-sdk/src/root.zig", .expected = .zttp_sdk },
        .{ .path = "build.zig", .expected = .repo },
    };
    for (cases) |case| {
        try std.testing.expectEqual(case.expected, try packageForPath(case.path));
    }
}

test "metric rejects unknown package buckets" {
    try std.testing.expectError(
        error.UnknownPackage,
        packageForPath("packages/review-metric-probe/src/root.zig"),
    );
    try std.testing.expectError(
        error.UnknownPackage,
        packageForPath("packages/unscoped.zig"),
    );
}

test "metric collection rejects an unknown package before reading it" {
    var io_backend = std.Io.Threaded.init(std.testing.allocator, .{ .environ = .empty });
    defer io_backend.deinit();
    try std.testing.expectError(
        error.UnknownPackage,
        collect(
            io_backend.io(),
            std.testing.allocator,
            &.{"packages/review-metric-probe/src/root.zig"},
            false,
        ),
    );
}

test "metric rejects a missing required package" {
    var report: Report = .{};
    for (required_packages) |package| {
        report.packages[@intFromEnum(package)].files = 1;
    }
    try std.testing.expectEqual(@as(?Package, null), missingRequiredPackage(report));

    report.packages[@intFromEnum(Package.runtime)].files = 0;
    try std.testing.expectEqual(Package.runtime, missingRequiredPackage(report).?);
}

test "metric collection enforces the required package floor" {
    var io_backend = std.Io.Threaded.init(std.testing.allocator, .{ .environ = .empty });
    defer io_backend.deinit();
    try std.testing.expectError(
        error.PackageFloorMissing,
        collect(
            io_backend.io(),
            std.testing.allocator,
            &.{
                "packages/modules/src/root.zig",
                "packages/pi/src/standin_main.zig",
                "packages/proof-review/src/root.zig",
                "packages/tools/src/precompile.zig",
                "packages/zts/src/root.zig",
                "packages/zttp-sdk/src/root.zig",
            },
            true,
        ),
    );
}
