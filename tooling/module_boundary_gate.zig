//! Module boundary gate: which `zts` internal modules each consumer package may name.
//!
//! `packages/zts/src/root.zig` re-exports a curated surface and, after a banner, an
//! internal tier of implementation modules. `scripts/module-boundary.allow` lists the
//! (package, module) pairs that consumers may reach in the internal tier. The check
//! fails in both directions: a pair in use that no row allows, and a row that no
//! package uses. The curated surface is not gated. The internal tier is read from
//! `root.zig` on every run, so no count is written down here to go stale.
//!
//! Subcommand `module-boundary` of `zts-graph-gate`. It replaces
//! `scripts/check-module-boundary.sh`, and its tests replace `scripts/test-module-boundary.sh`.

const std = @import("std");

const allow_path = "scripts/module-boundary.allow";
const root_path = "packages/zts/src/root.zig";
const consumer_packages = [_][]const u8{ "runtime", "tools", "pi", "modules", "zttp-sdk" };
/// The internal tier is large. Fewer parsed modules than this means the layout of
/// `root.zig` changed and the parse read nothing.
const min_internals = 40;
const banner = "// Internal implementation modules";
const tier_prefixes = [_][]const u8{ "base.", "contracts.", "engine.", "compiler." };

/// Where the gate reads its package listings and file bodies. The real one asks
/// Git and the file system; the tests answer from memory.
pub const Source = struct {
    ctx: *anyopaque,
    package_exists: *const fn (ctx: *anyopaque, package: []const u8) bool,
    /// Tracked `.zig` paths of one package, as `git ls-files -z packages/<package>/*.zig`
    /// lists them.
    list: *const fn (ctx: *anyopaque, arena: std.mem.Allocator, package: []const u8) anyerror![]const []const u8,
    read: *const fn (ctx: *anyopaque, arena: std.mem.Allocator, path: []const u8) anyerror![]const u8,
};

pub const Outcome = union(enum) {
    pass: struct { internals: usize, reaches: usize },
    /// The complete diagnostic text, newline terminated, for stderr.
    fail: []const u8,
};

fn failf(arena: std.mem.Allocator, comptime format: []const u8, args: anytype) !Outcome {
    return .{ .fail = try std.fmt.allocPrint(arena, format, args) };
}

fn isIdentStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_';
}

fn isIdentChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

fn identEnd(text: []const u8, start: usize) usize {
    var end = start;
    while (end < text.len and isIdentChar(text[end])) end += 1;
    return end;
}

fn lessString(_: void, lhs: []const u8, rhs: []const u8) bool {
    return std.mem.order(u8, lhs, rhs) == .lt;
}

fn sortedUnique(arena: std.mem.Allocator, items: []const []const u8) ![]const []const u8 {
    const copy = try arena.dupe([]const u8, items);
    std.mem.sort([]const u8, copy, {}, lessString);
    var kept: usize = 0;
    for (copy) |item| {
        if (kept > 0 and std.mem.eql(u8, copy[kept - 1], item)) continue;
        copy[kept] = item;
        kept += 1;
    }
    return copy[0..kept];
}

/// The internal tier: every `pub const <lowercase> = <tier>.<module>` between the
/// banner and the first `// ====` rule that follows an entry. Curated entries are
/// UpperCamelCase types or plain functions and are deliberately not matched.
pub fn parseInternals(arena: std.mem.Allocator, root_text: []const u8) ![]const []const u8 {
    var names: std.ArrayList([]const u8) = .empty;
    var in_section = false;
    var seen_entry = false;
    var lines = std.mem.splitScalar(u8, root_text, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, banner)) in_section = true;
        if (in_section and seen_entry and isEqualsRule(line)) break;
        if (!in_section) continue;
        const entry = "pub const ";
        if (!std.mem.startsWith(u8, line, entry)) continue;
        const name_start = entry.len;
        if (name_start >= line.len or !(std.ascii.isLower(line[name_start]) or line[name_start] == '_')) continue;
        var name_end = name_start;
        while (name_end < line.len and (std.ascii.isLower(line[name_end]) or std.ascii.isDigit(line[name_end]) or line[name_end] == '_')) name_end += 1;
        var cursor = name_end;
        while (cursor < line.len and line[cursor] == ' ') cursor += 1;
        if (cursor >= line.len or line[cursor] != '=') continue;
        cursor += 1;
        if (cursor >= line.len or line[cursor] != ' ') continue;
        cursor += 1;
        var tiered = false;
        for (tier_prefixes) |tier| {
            if (std.mem.startsWith(u8, line[cursor..], tier)) tiered = true;
        }
        if (!tiered) continue;
        seen_entry = true;
        try names.append(arena, line[name_start..name_end]);
    }
    return sortedUnique(arena, names.items);
}

/// A comment line of `// ` followed by one or more `=` and nothing else.
fn isEqualsRule(line: []const u8) bool {
    if (!std.mem.startsWith(u8, line, "// ")) return false;
    const rule = line[3..];
    if (rule.len == 0) return false;
    for (rule) |c| if (c != '=') return false;
    return true;
}

fn isInternal(internals: []const []const u8, name: []const u8) bool {
    for (internals) |internal| if (std.mem.eql(u8, internal, name)) return true;
    return false;
}

/// `const <alias> = @import("zts");` after optional leading spaces. Returns the alias.
fn aliasDefinition(line: []const u8) ?[]const u8 {
    var cursor: usize = 0;
    while (cursor < line.len and line[cursor] == ' ') cursor += 1;
    const keyword = "const ";
    if (!std.mem.startsWith(u8, line[cursor..], keyword)) return null;
    cursor += keyword.len;
    if (cursor >= line.len or !isIdentStart(line[cursor])) return null;
    const alias_end = identEnd(line, cursor);
    const alias = line[cursor..alias_end];
    cursor = alias_end;
    while (cursor < line.len and line[cursor] == ' ') cursor += 1;
    if (cursor >= line.len or line[cursor] != '=') return null;
    cursor += 1;
    while (cursor < line.len and line[cursor] == ' ') cursor += 1;
    const import = "@import(\"zts\")";
    if (!std.mem.startsWith(u8, line[cursor..], import)) return null;
    cursor += import.len;
    while (cursor < line.len and line[cursor] == ' ') cursor += 1;
    if (cursor >= line.len or line[cursor] != ';') return null;
    return alias;
}

const AliasHit = struct { name: []const u8, end: usize };

/// The next `<alias>.<name>` in `rest` that does not continue a longer identifier or
/// a dotted path.
fn findAliasUse(rest: []const u8, alias: []const u8) ?AliasHit {
    var from: usize = 0;
    while (std.mem.find(u8, rest[from..], alias)) |relative| {
        const at = from + relative;
        from = at + 1;
        if (at > 0 and (isIdentChar(rest[at - 1]) or rest[at - 1] == '.')) continue;
        const dot = at + alias.len;
        if (dot + 1 < rest.len and rest[dot] == '.' and isIdentStart(rest[dot + 1])) {
            const end = identEnd(rest, dot + 1);
            return .{ .name = rest[dot + 1 .. end], .end = end };
        }
    }
    return null;
}

/// Every internal name one file reaches through the `zts` module, whatever the file
/// aliases the import to: `const zts = @import("zts")`, `const zq = @import("zts")`,
/// and the direct `@import("zts").compat`. Aliases do not leak into the next file.
pub fn namesUsedIn(
    arena: std.mem.Allocator,
    text: []const u8,
    internals: []const []const u8,
    found: *std.StringHashMapUnmanaged(void),
) !void {
    var aliases: std.ArrayList([]const u8) = .empty;
    const direct = "@import(\"zts\").";
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        var from: usize = 0;
        while (std.mem.find(u8, line[from..], direct)) |relative| {
            const at = from + relative + direct.len;
            from = at;
            if (at < line.len and isIdentStart(line[at])) {
                const name = line[at..identEnd(line, at)];
                if (isInternal(internals, name)) try found.put(arena, name, {});
            }
        }
        if (aliasDefinition(line)) |alias| try aliases.append(arena, alias);
        for (aliases.items) |alias| {
            var rest = line;
            while (findAliasUse(rest, alias)) |hit| {
                if (isInternal(internals, hit.name)) try found.put(arena, hit.name, {});
                rest = rest[hit.end..];
            }
        }
    }
}

/// Rows of the allowlist: comment and trailing whitespace stripped, blank rows dropped.
pub fn parseAllow(arena: std.mem.Allocator, text: []const u8) ![]const []const u8 {
    var rows: std.ArrayList([]const u8) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const comment = std.mem.findScalar(u8, raw, '#') orelse raw.len;
        const row = std.mem.trimEnd(u8, raw[0..comment], " \t\r\x0b\x0c");
        if (row.len == 0) continue;
        try rows.append(arena, row);
    }
    return sortedUnique(arena, rows.items);
}

fn contains(items: []const []const u8, wanted: []const u8) bool {
    for (items) |item| if (std.mem.eql(u8, item, wanted)) return true;
    return false;
}

pub fn check(
    arena: std.mem.Allocator,
    source: Source,
    allow_text: ?[]const u8,
    root_text: ?[]const u8,
) !Outcome {
    const allow = allow_text orelse return failf(arena, "module boundary: missing {s}\n", .{allow_path});
    const root = root_text orelse return failf(arena, "module boundary: missing {s}\n", .{root_path});

    const internals = try parseInternals(arena, root);
    if (internals.len < min_internals) return failf(
        arena,
        "module boundary: only {d} internal modules parsed from {s}; the file layout changed\n",
        .{ internals.len, root_path },
    );

    var used: std.ArrayList([]const u8) = .empty;
    for (consumer_packages) |package| {
        if (!source.package_exists(source.ctx, package)) continue;
        const paths = source.list(source.ctx, arena, package) catch
            return failf(arena, "module boundary: failed to enumerate tracked Zig files for {s}\n", .{package});
        var names: std.StringHashMapUnmanaged(void) = .empty;
        for (paths) |path| {
            // A tracked path that is gone from the working tree is skipped, so a
            // cleanup diff cannot turn into a scan failure.
            const text = source.read(source.ctx, arena, path) catch |failure| switch (failure) {
                error.FileNotFound => continue,
                else => return failf(arena, "module boundary: failed to scan tracked Zig files for {s}\n", .{package}),
            };
            namesUsedIn(arena, text, internals, &names) catch
                return failf(arena, "module boundary: failed to scan tracked Zig files for {s}\n", .{package});
        }
        var iterator = names.keyIterator();
        while (iterator.next()) |name| try used.append(arena, try std.fmt.allocPrint(arena, "{s} {s}", .{ package, name.* }));
    }
    const used_pairs = try sortedUnique(arena, used.items);
    // A scan that read nothing would report a clean boundary. The tree holds dozens
    // of reaches, so none at all means the scan is broken.
    if (used_pairs.len == 0) return failf(
        arena,
        "module boundary: the scan found no reach into zts internals; it read nothing\n",
        .{},
    );
    const allowed_pairs = try parseAllow(arena, allow);

    var report: std.ArrayList(u8) = .empty;
    var new_reach: usize = 0;
    for (used_pairs) |pair| {
        if (contains(allowed_pairs, pair)) continue;
        if (new_reach == 0) try report.print(arena, "module boundary: these packages reach a zts internal that {s} does not allow:\n", .{allow_path});
        new_reach += 1;
        try report.print(arena, "  {s}\n", .{pair});
    }
    if (new_reach > 0) {
        try report.print(arena, "Use the curated surface in {s}, or add the row deliberately.\n", .{root_path});
        return .{ .fail = report.items };
    }
    var stale: usize = 0;
    for (allowed_pairs) |pair| {
        if (contains(used_pairs, pair)) continue;
        if (stale == 0) try report.print(arena, "module boundary: {s} allows internals nothing uses any more:\n", .{allow_path});
        stale += 1;
        try report.print(arena, "  {s}\n", .{pair});
    }
    if (stale > 0) {
        try report.appendSlice(arena, "Delete those rows: the allowlist only ratchets down.\n");
        return .{ .fail = report.items };
    }
    return .{ .pass = .{ .internals = internals.len, .reaches = used_pairs.len } };
}

// ---------------------------------------------------------------------------
// The real source: Git for the listing, the working tree for the bodies.
// ---------------------------------------------------------------------------

const RealSource = struct {
    io: std.Io,

    fn packageExists(ctx: *anyopaque, package: []const u8) bool {
        const self: *RealSource = @ptrCast(@alignCast(ctx));
        var buffer: [128]u8 = undefined;
        const path = std.fmt.bufPrint(&buffer, "packages/{s}", .{package}) catch return false;
        var dir = std.Io.Dir.cwd().openDir(self.io, path, .{}) catch return false;
        dir.close(self.io);
        return true;
    }

    fn list(ctx: *anyopaque, arena: std.mem.Allocator, package: []const u8) anyerror![]const []const u8 {
        const self: *RealSource = @ptrCast(@alignCast(ctx));
        const pattern = try std.fmt.allocPrint(arena, "packages/{s}/*.zig", .{package});
        const result = try std.process.run(arena, self.io, .{
            .argv = &.{ "git", "ls-files", "-z", pattern },
            .stdout_limit = .limited(4 * 1024 * 1024),
            .stderr_limit = .limited(256 * 1024),
        });
        switch (result.term) {
            .exited => |code| if (code != 0) return error.GitLsFilesFailed,
            else => return error.GitLsFilesFailed,
        }
        var paths: std.ArrayList([]const u8) = .empty;
        var pieces = std.mem.splitScalar(u8, result.stdout, 0);
        while (pieces.next()) |path| {
            if (path.len > 0) try paths.append(arena, path);
        }
        return paths.items;
    }

    fn read(ctx: *anyopaque, arena: std.mem.Allocator, path: []const u8) anyerror![]const u8 {
        const self: *RealSource = @ptrCast(@alignCast(ctx));
        return std.Io.Dir.cwd().readFileAlloc(self.io, path, arena, .limited(16 * 1024 * 1024));
    }
};

/// Run against the working directory. Prints the verdict and returns the exit code.
pub fn run(io: std.Io, allocator: std.mem.Allocator, stdout: *std.Io.Writer) !u8 {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var real: RealSource = .{ .io = io };
    const source: Source = .{
        .ctx = &real,
        .package_exists = RealSource.packageExists,
        .list = RealSource.list,
        .read = RealSource.read,
    };
    const allow_text = readOptional(io, arena, allow_path);
    const root_text = readOptional(io, arena, root_path);
    const outcome = try check(arena, source, allow_text, root_text);
    switch (outcome) {
        .pass => |counts| {
            try stdout.print("module boundary: OK ({d} internal modules, {d} allowed package reaches)\n", .{ counts.internals, counts.reaches });
            return 0;
        },
        .fail => |message| {
            std.debug.print("{s}", .{message});
            return 1;
        },
    }
}

fn readOptional(io: std.Io, arena: std.mem.Allocator, path: []const u8) ?[]const u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(16 * 1024 * 1024)) catch null;
}

// ---------------------------------------------------------------------------
// Tests: in-memory inputs, one per rejection the shell gate and its wrapper made.
// ---------------------------------------------------------------------------

const TestPackage = struct { name: []const u8, files: []const TestFile };
const TestFile = struct { path: []const u8, text: ?[]const u8 = null, read_error: ?anyerror = null };

const TestSource = struct {
    packages: []const TestPackage,
    list_failure: ?[]const u8 = null,

    fn source(self: *TestSource) Source {
        return .{ .ctx = self, .package_exists = packageExists, .list = list, .read = read };
    }

    fn packageExists(ctx: *anyopaque, package: []const u8) bool {
        const self: *TestSource = @ptrCast(@alignCast(ctx));
        for (self.packages) |entry| if (std.mem.eql(u8, entry.name, package)) return true;
        return false;
    }

    fn list(ctx: *anyopaque, arena: std.mem.Allocator, package: []const u8) anyerror![]const []const u8 {
        const self: *TestSource = @ptrCast(@alignCast(ctx));
        if (self.list_failure) |failing| if (std.mem.eql(u8, failing, package)) return error.GitLsFilesFailed;
        var paths: std.ArrayList([]const u8) = .empty;
        for (self.packages) |entry| {
            if (!std.mem.eql(u8, entry.name, package)) continue;
            for (entry.files) |file| try paths.append(arena, file.path);
        }
        return paths.items;
    }

    fn read(ctx: *anyopaque, _: std.mem.Allocator, path: []const u8) anyerror![]const u8 {
        const self: *TestSource = @ptrCast(@alignCast(ctx));
        for (self.packages) |entry| for (entry.files) |file| {
            if (!std.mem.eql(u8, file.path, path)) continue;
            if (file.read_error) |failure| return failure;
            return file.text orelse error.FileNotFound;
        };
        return error.FileNotFound;
    }
};

/// A `root.zig` with `count` internal modules named `m0`, `m1`, ... plus a curated entry.
fn testRoot(arena: std.mem.Allocator, count: usize) ![]const u8 {
    var text: std.ArrayList(u8) = .empty;
    try text.appendSlice(arena, "pub const Context = engine.Context;\n// Internal implementation modules\n");
    for (0..count) |index| try text.print(arena, "pub const m{d} = engine.m{d};\n", .{ index, index });
    try text.appendSlice(arena, "// ====\npub const Curated = compiler.Curated;\n");
    return text.items;
}

fn testAllow(arena: std.mem.Allocator, rows: []const []const u8) ![]const u8 {
    var text: std.ArrayList(u8) = .empty;
    for (rows) |row| try text.print(arena, "{s}\n", .{row});
    return text.items;
}

fn expectFail(outcome: Outcome, needle: []const u8) !void {
    switch (outcome) {
        .pass => return error.TestExpectedFailure,
        .fail => |message| try std.testing.expect(std.mem.find(u8, message, needle) != null),
    }
}

fn expectPass(outcome: Outcome, internals: usize, reaches: usize) !void {
    switch (outcome) {
        .pass => |counts| {
            try std.testing.expectEqual(internals, counts.internals);
            try std.testing.expectEqual(reaches, counts.reaches);
        },
        .fail => |message| {
            std.debug.print("{s}", .{message});
            return error.TestExpectedPass;
        },
    }
}

const reach_runtime = TestFile{ .path = "packages/runtime/src/a.zig", .text = "const zts = @import(\"zts\");\nconst x = zts.m1;\n" };

test "a listed reach passes and the verdict counts internals and reaches" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var src: TestSource = .{ .packages = &.{.{ .name = "runtime", .files = &.{reach_runtime} }} };
    const root = try testRoot(arena, 41);
    const allow = try testAllow(arena, &.{ "# why", "runtime m1   # trailing comment and spaces", "" });
    try expectPass(try check(arena, src.source(), allow, root), 41, 1);
}

test "a reach that no row allows fails and names the pair" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var src: TestSource = .{ .packages = &.{.{ .name = "runtime", .files = &.{reach_runtime} }} };
    const root = try testRoot(arena, 41);
    const allow = try testAllow(arena, &.{"runtime m2"});
    const outcome = try check(arena, src.source(), allow, root);
    try expectFail(outcome, "these packages reach a zts internal that scripts/module-boundary.allow does not allow:\n  runtime m1\n");
    try expectFail(outcome, "Use the curated surface in packages/zts/src/root.zig, or add the row deliberately.");
}

test "a row that nothing uses fails as a stale row" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var src: TestSource = .{ .packages = &.{.{ .name = "runtime", .files = &.{reach_runtime} }} };
    const root = try testRoot(arena, 41);
    const allow = try testAllow(arena, &.{ "runtime m1", "runtime m2" });
    const outcome = try check(arena, src.source(), allow, root);
    try expectFail(outcome, "scripts/module-boundary.allow allows internals nothing uses any more:\n  runtime m2\n");
    try expectFail(outcome, "Delete those rows: the allowlist only ratchets down.");
}

test "a row with leading whitespace is not the pair it spells" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var src: TestSource = .{ .packages = &.{.{ .name = "runtime", .files = &.{reach_runtime} }} };
    const root = try testRoot(arena, 41);
    const allow = try testAllow(arena, &.{"  runtime m1"});
    try expectFail(try check(arena, src.source(), allow, root), "  runtime m1\n");
}

test "an alias does not leak from one scanned file into the next" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // The first file imports zts; the second only spells the same identifier.
    var src: TestSource = .{ .packages = &.{.{ .name = "runtime", .files = &.{
        reach_runtime,
        .{ .path = "packages/runtime/src/alias.zig", .text = "const zts = @import(\"zts\");\n" },
        .{ .path = "packages/runtime/src/use.zig", .text = "const leaked = zts.m2;\n" },
    } }} };
    const root = try testRoot(arena, 41);
    const allow = try testAllow(arena, &.{"runtime m1"});
    try expectPass(try check(arena, src.source(), allow, root), 41, 1);
}

test "an alias use inside the file that defines it is a reach, whatever the alias is called" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var src: TestSource = .{ .packages = &.{.{ .name = "pi", .files = &.{
        .{ .path = "packages/pi/src/a.zig", .text = "const zq = @import(\"zts\");\nconst both = zq.m1 + zq.m2;\nconst nested = other.zq.m3;\nconst dir = @import(\"zts\").m4;\n" },
    } }} };
    const root = try testRoot(arena, 41);
    const allow = try testAllow(arena, &.{"pi m1"});
    const outcome = try check(arena, src.source(), allow, root);
    // m3 is behind a dotted prefix and is not the alias. m2 and m4 are unlisted reaches.
    try expectFail(outcome, "  pi m2\n  pi m4\n");
}

test "two direct imports on one line are both counted" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var src: TestSource = .{ .packages = &.{.{ .name = "tools", .files = &.{
        .{ .path = "packages/tools/src/a.zig", .text = "const a = @import(\"zts\").m1; const b = @import(\"zts\").m2;\n" },
    } }} };
    const root = try testRoot(arena, 41);
    const allow = try testAllow(arena, &.{"tools m1"});
    try expectFail(try check(arena, src.source(), allow, root), "  tools m2\n");
}

test "the curated surface and packages outside the consumer list are not gated" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var src: TestSource = .{ .packages = &.{
        .{ .name = "runtime", .files = &.{
            reach_runtime,
            .{ .path = "packages/runtime/src/curated.zig", .text = "const zts = @import(\"zts\");\nconst c = zts.Context;\n" },
        } },
        .{ .name = "zts", .files = &.{.{ .path = "packages/zts/src/leak.zig", .text = "const zts = @import(\"zts\");\nconst x = zts.m5;\n" }} },
    } };
    const root = try testRoot(arena, 41);
    const allow = try testAllow(arena, &.{"runtime m1"});
    try expectPass(try check(arena, src.source(), allow, root), 41, 1);
}

test "every consumer package is scanned" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const root = try testRoot(arena, 41);
    for (consumer_packages) |package| {
        const path = try std.fmt.allocPrint(arena, "packages/{s}/bench/leak.zig", .{package});
        var src: TestSource = .{ .packages = &.{
            .{ .name = "runtime", .files = &.{reach_runtime} },
            .{ .name = package, .files = &.{.{ .path = path, .text = "const zq = @import(\"zts\");\nconst x = zq.m9;\n" }} },
        } };
        const allow = try testAllow(arena, &.{"runtime m1"});
        const needle = try std.fmt.allocPrint(arena, "  {s} m9\n", .{package});
        try expectFail(try check(arena, src.source(), allow, root), needle);
    }
}

test "a tracked file that is gone from the working tree is skipped" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var src: TestSource = .{ .packages = &.{.{ .name = "runtime", .files = &.{
        reach_runtime,
        .{ .path = "packages/runtime/src/gone.zig", .read_error = error.FileNotFound },
    } }} };
    const root = try testRoot(arena, 41);
    const allow = try testAllow(arena, &.{"runtime m1"});
    try expectPass(try check(arena, src.source(), allow, root), 41, 1);
}

test "an enumeration failure is reported at its source" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var src: TestSource = .{
        .packages = &.{.{ .name = "runtime", .files = &.{reach_runtime} }},
        .list_failure = "runtime",
    };
    const root = try testRoot(arena, 41);
    const allow = try testAllow(arena, &.{"runtime m1"});
    try expectFail(try check(arena, src.source(), allow, root), "module boundary: failed to enumerate tracked Zig files for runtime\n");
}

test "a scanner failure is not reclassified as an unused allowlist row" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // The only reach is in the file that cannot be read. Dropping its scan would
    // report the row as unused, which blames the allowlist for a broken scan.
    var src: TestSource = .{ .packages = &.{.{ .name = "runtime", .files = &.{
        .{ .path = "packages/runtime/src/a.zig", .read_error = error.AccessDenied },
    } }} };
    const root = try testRoot(arena, 41);
    const allow = try testAllow(arena, &.{"runtime m1"});
    const outcome = try check(arena, src.source(), allow, root);
    try expectFail(outcome, "module boundary: failed to scan tracked Zig files for runtime\n");
    try std.testing.expect(std.mem.find(u8, outcome.fail, "nothing uses") == null);
}

test "a layout change that parses too few internals fails before any verdict" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var src: TestSource = .{ .packages = &.{.{ .name = "runtime", .files = &.{reach_runtime} }} };
    const allow = try testAllow(arena, &.{"runtime m1"});
    try expectFail(
        try check(arena, src.source(), allow, try testRoot(arena, 39)),
        "module boundary: only 39 internal modules parsed from packages/zts/src/root.zig; the file layout changed\n",
    );
    // The banner moved: nothing is in the section at all.
    const moved = try std.mem.replaceOwned(u8, arena, try testRoot(arena, 41), "// Internal implementation modules", "// Other modules");
    try expectFail(try check(arena, src.source(), allow, moved), "only 0 internal modules parsed");
}

test "a scan that finds no reach at all fails the floor" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var src: TestSource = .{ .packages = &.{.{ .name = "runtime", .files = &.{
        .{ .path = "packages/runtime/src/a.zig", .text = "const x = 1;\n" },
    } }} };
    const root = try testRoot(arena, 41);
    try expectFail(try check(arena, src.source(), try testAllow(arena, &.{}), root), "the scan found no reach into zts internals; it read nothing");
}

test "a missing allowlist or root file fails by name" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var src: TestSource = .{ .packages = &.{.{ .name = "runtime", .files = &.{reach_runtime} }} };
    const root = try testRoot(arena, 41);
    try expectFail(try check(arena, src.source(), null, root), "module boundary: missing scripts/module-boundary.allow\n");
    try expectFail(try check(arena, src.source(), "runtime m1\n", null), "module boundary: missing packages/zts/src/root.zig\n");
}

test "the internal tier stops at the rule after the last entry and reads only tiered entries" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const text =
        \\pub const before = engine.before;
        \\// Internal implementation modules
        \\// ====
        \\pub const first = base.first;
        \\pub const second = contracts.second;
        \\pub const Curated = engine.Curated;
        \\pub const third = compiler.third;
        \\pub const function_like = fn_helper;
        \\// ====
        \\pub const after = engine.after;
    ;
    const names = try parseInternals(arena, text);
    try std.testing.expectEqual(@as(usize, 3), names.len);
    try std.testing.expectEqualStrings("first", names[0]);
    try std.testing.expectEqualStrings("second", names[1]);
    try std.testing.expectEqualStrings("third", names[2]);
}
