//! Baked-in skill catalog. Each entry is a markdown file alongside this
//! source at `packages/pi/src/skills/<name>.md` with YAML frontmatter
//! carrying `name` and `description`. Files are embedded at compile time
//! via `@embedFile` and frontmatter is parsed by the shared `frontmatter`
//! module. Skills cannot be added, replaced, or silently altered at runtime:
//! adding one requires dropping a new `.md` file, listing it in
//! `embedded_sources` below, and rebuilding.
//!
//! The `.md` files live under `src/skills/` (not a sibling `skills/` dir)
//! because `@embedFile` is restricted to the importing module's package
//! tree. This keeps the files inside `pi_app` without extending the module
//! system.

const std = @import("std");
const frontmatter = @import("../frontmatter.zig");

pub const Skill = struct {
    name: []const u8,
    description: []const u8,
    body: []const u8,
};

const embedded_sources = [_][]const u8{
    @embedFile("handler-scaffold.md"),
    @embedFile("fix-violations.md"),
    @embedFile("route-table.md"),
    @embedFile("auth-jwt.md"),
    @embedFile("sql-query.md"),
    @embedFile("canonical-style.md"),
};

pub const catalog: [embedded_sources.len]Skill = build: {
    var out: [embedded_sources.len]Skill = undefined;
    for (embedded_sources, 0..) |src, i| {
        const doc = frontmatter.parseComptime(src);
        out[i] = .{
            .name = doc.require("name"),
            .description = doc.require("description"),
            .body = std.mem.trimEnd(u8, doc.body, " \t\r\n"),
        };
    }
    break :build out;
};

pub fn findByName(name: []const u8) ?*const Skill {
    for (&catalog) |*skill| {
        if (std.mem.eql(u8, skill.name, name)) return skill;
    }
    return null;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "catalog has exactly the expected entries, in order" {
    const expected = [_][]const u8{
        "handler-scaffold",
        "fix-violations",
        "route-table",
        "auth-jwt",
        "sql-query",
        "canonical-style",
    };
    try testing.expectEqual(expected.len, catalog.len);
    for (expected, 0..) |name, i| {
        try testing.expectEqualStrings(name, catalog[i].name);
    }
}

test "findByName returns a hit for every entry and null for unknowns" {
    for (&catalog) |*skill| {
        const found = findByName(skill.name) orelse return error.TestExpected;
        try testing.expectEqualStrings(skill.name, found.name);
    }
    try testing.expect(findByName("does-not-exist") == null);
}

test "every skill body is non-empty and every description fits on one line" {
    for (&catalog) |*skill| {
        try testing.expect(skill.body.len > 0);
        try testing.expect(std.mem.indexOfScalar(u8, skill.description, '\n') == null);
    }
}

test "handler-scaffold body preserves the conventions list verbatim" {
    const skill = findByName("handler-scaffold") orelse return error.TestExpected;
    try testing.expect(std.mem.indexOf(u8, skill.body, "zttp:decode") != null);
    try testing.expect(std.mem.indexOf(u8, skill.body, "No classes, no async/await") != null);
}

test "skills steer coding tasks through compiler-native expert tools" {
    const fix = findByName("fix-violations") orelse return error.TestExpected;
    try testing.expect(std.mem.indexOf(u8, fix.body, "zts_expert_verify_paths") != null);
    try testing.expect(std.mem.indexOf(u8, fix.body, "pi_goal_candidate") != null);
    try testing.expect(std.mem.indexOf(u8, fix.body, "/check") == null);

    const route = findByName("route-table") orelse return error.TestExpected;
    try testing.expect(std.mem.indexOf(u8, route.body, "Author the COMPLETE file content yourself") != null);
    try testing.expect(std.mem.indexOf(u8, route.body, "pi_apply_feature_plan") == null);
    try testing.expect(std.mem.indexOf(u8, route.body, "one `propose_change_set` call") != null);

    const auth = findByName("auth-jwt") orelse return error.TestExpected;
    try testing.expect(std.mem.indexOf(u8, auth.body, "no_credential_leakage") != null);
    try testing.expect(std.mem.indexOf(u8, auth.body, "fallback secret") != null);

    const sql = findByName("sql-query") orelse return error.TestExpected;
    try testing.expect(std.mem.indexOf(u8, sql.body, "named SQL parameters") != null);
    try testing.expect(std.mem.indexOf(u8, sql.body, "WHERE id = ?") == null);
}

/// Census of the TypeScript in the skill files, which the model copies. Every
/// `ts` block runs through the real check as a module and must produce no
/// error and no warning. A block that opens with `// before` pairs a refused
/// form with its replacement: the census checks the replacement, the text after
/// the `// after` line. Blocks are numbered from 0 per skill, in file order.
/// A block that fails today sits in `census_known_failures` with the codes it
/// fails with and the reason. The list ratchets: a listed block that checks
/// clean, or fails with a code outside its row, fails the census.
const CensusFailure = struct {
    skill: []const u8,
    block: usize,
    codes: []const []const u8,
    reason: []const u8,
};

const census_known_failures = [_]CensusFailure{
    .{ .skill = "route-table", .block = 0, .codes = &.{"ZTS500"}, .reason = "finding: the handler declares no Proof capsule, so the default proof profile refuses the example" },
    .{ .skill = "sql-query", .block = 0, .codes = &.{"check:MissingSqlSchema"}, .reason = "needs a project input: SQL verification requires a configured sqlite schema that the block cannot carry" },
    .{ .skill = "canonical-style", .block = 0, .codes = &.{"ZTS002"}, .reason = "fragment: a statement list with a top-level return" },
    .{ .skill = "canonical-style", .block = 1, .codes = &.{ "ZTS600", "ZTS629" }, .reason = "fragment: calls makeUser, which the block does not declare" },
    .{ .skill = "canonical-style", .block = 3, .codes = &.{ "ZTS600", "ZTS629" }, .reason = "fragment: uses load, pickStatus, ready, and fallback, which the block does not declare" },
    .{ .skill = "canonical-style", .block = 4, .codes = &.{"ZTS629"}, .reason = "fragment: uses a and b, which the block does not declare" },
    .{ .skill = "canonical-style", .block = 5, .codes = &.{ "ZTS106", "ZTS629" }, .reason = "fragment: uses count, which the block does not declare" },
    .{ .skill = "canonical-style", .block = 6, .codes = &.{"ZTS629"}, .reason = "fragment: uses base, which the block does not declare" },
    .{ .skill = "canonical-style", .block = 7, .codes = &.{ "ZTS600", "ZTS629" }, .reason = "fragment: uses send and args, which the block does not declare" },
    .{ .skill = "canonical-style", .block = 8, .codes = &.{"ZTS500"}, .reason = "finding: a complete module without a handler is refused with ZTS500" },
    .{ .skill = "canonical-style", .block = 9, .codes = &.{ "ZTS600", "ZTS629" }, .reason = "fragment: uses payload, items, and use, which the block does not declare" },
    .{ .skill = "canonical-style", .block = 10, .codes = &.{"ZTS002"}, .reason = "fragment: elided `{ ... }` body" },
    .{ .skill = "canonical-style", .block = 11, .codes = &.{"ZTS002"}, .reason = "fragment: a statement list with a top-level return" },
    .{ .skill = "canonical-style", .block = 12, .codes = &.{"ZTS002"}, .reason = "fragment: a statement list with a top-level return" },
    .{ .skill = "canonical-style", .block = 13, .codes = &.{"ZTS002"}, .reason = "fragment: a statement list with a top-level return" },
};

const census_block_count = 16;

const CensusNoSiblings = struct {
    fn read(_: *anyopaque, _: std.mem.Allocator, _: []const u8) anyerror![]u8 {
        return error.FileNotFound;
    }
};

/// The codes of every error and warning diagnostic the real check reports for
/// `source`. An analyzer failure counts as the code `analyzer:<error name>`. A check that fails to run counts as `check:<error name>`.
fn censusCodes(arena: std.mem.Allocator, label: []const u8, source: []const u8) ![]const []const u8 {
    const precompile = @import("zts_cli").precompile;
    var context: u8 = 0;
    const path = try std.fmt.allocPrint(arena, "/skill-census/{s}.ts", .{label});
    var result = precompile.runCheckOnlyFromSourceWithOptions(arena, source, path, .{
        .json_mode = true,
        .import_reader = .{ .context = &context, .read = CensusNoSiblings.read },
    }) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => {
            const code = try std.fmt.allocPrint(arena, "check:{s}", .{@errorName(err)});
            return try arena.dupe([]const u8, &.{code});
        },
    };
    defer result.deinit(arena);
    var codes: std.ArrayList([]const u8) = .empty;
    if (result.analyzer_error) |err| {
        const code = try std.fmt.allocPrint(arena, "analyzer:{s}", .{@errorName(err)});
        try codes.append(arena, code);
    }
    for (result.json_diagnostics.items) |d| {
        const blocking = std.mem.eql(u8, d.severity, "error") or std.mem.eql(u8, d.severity, "warning");
        if (!blocking) continue;
        try codes.append(arena, try arena.dupe(u8, d.code));
    }
    return codes.items;
}

/// The text the census checks for one fenced block: the whole block, or the
/// text after the `// after` line when the block opens with `// before`.
fn censusSource(block: []const u8) []const u8 {
    if (!std.mem.startsWith(u8, block, "// before")) return block;
    var offset: usize = 0;
    var lines = std.mem.splitScalar(u8, block, '\n');
    while (lines.next()) |line| {
        offset += line.len + 1;
        if (std.mem.startsWith(u8, line, "// after")) return block[@min(offset, block.len)..];
    }
    return block;
}

test "skill ts blocks pass the real check with no error and no warning" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var checked: usize = 0;
    var failed = false;
    for (&catalog) |*skill| {
        var block_index: usize = 0;
        var cursor: usize = 0;
        while (std.mem.indexOfPos(u8, skill.body, cursor, "```ts\n")) |open| {
            const start = open + "```ts\n".len;
            const close = std.mem.indexOfPos(u8, skill.body, start, "```") orelse return error.TestUnexpectedResult;
            cursor = close + 3;
            const label = try std.fmt.allocPrint(arena, "{s}-{d}", .{ skill.name, block_index });
            const codes = try censusCodes(arena, label, censusSource(skill.body[start..close]));
            checked += 1;
            var row: ?CensusFailure = null;
            for (census_known_failures) |known| {
                if (std.mem.eql(u8, known.skill, skill.name) and known.block == block_index) row = known;
            }
            if (row) |known| {
                if (codes.len == 0) {
                    std.debug.print("skill census: {s} is listed as failing and now passes\n", .{label});
                    failed = true;
                }
                for (codes) |code| {
                    var listed = false;
                    for (known.codes) |k| listed = listed or std.mem.eql(u8, k, code);
                    if (!listed) {
                        std.debug.print("skill census: {s} fails with unlisted code {s}\n", .{ label, code });
                        failed = true;
                    }
                }
            } else if (codes.len != 0) {
                for (codes) |code| std.debug.print("skill census: {s} fails with {s}\n", .{ label, code });
                failed = true;
            }
            block_index += 1;
        }
    }
    try testing.expectEqual(@as(usize, census_block_count), checked);
    try testing.expect(!failed);
}
