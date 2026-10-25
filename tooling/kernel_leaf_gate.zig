//! Acceptance-kernel boundary and floor gate.
//!
//! `packages/proof-checker` is the only code in this repository whose word decides
//! whether an artifact may serve production traffic, and an audit stays cheap only
//! while the package is a leaf. This gate pins four things:
//!
//!   1. The kernel imports `std` and its own siblings and nothing else, declares no
//!      dependency in its manifest, and reaches no ambient capability: no file
//!      system, clock, process, network, signing, allocator, or mutable static.
//!   2. `std` is reached through one name, so the capability patterns above, which
//!      only match the dotted form, cannot be evaded by a rebinding.
//!   3. The suite cited as evidence is not empty: every source file is referenced by
//!      `src/test_root.zig` and carries a test, and the total reaches a floor.
//!   4. Every public `ReasonCode` is named by a kernel test or carries a stated reason
//!      that no input can produce it.
//!
//! Each check also asserts a floor on its own input, so a gate that reads nothing
//! fails instead of passing. Subcommand `kernel-leaf` of `zts-graph-gate`. It
//! replaces `scripts/check-proof-checker.sh` (decision D-005).

const std = @import("std");

const package_path = "packages/proof-checker";
const src_path = package_path ++ "/src";
const test_root_name = "test_root.zig";
const test_root_path = src_path ++ "/" ++ test_root_name;
const manifest_path = package_path ++ "/build.zig.zon";
const verdict_path = src_path ++ "/verdict.zig";
/// The kernel is small on purpose. Fewer sources than this means the listing broke or a
/// retained file was dropped.
const min_sources = 13;
/// The unfiltered kernel suite runs at least this many test blocks.
const min_tests = 195;
/// The census reads at least this many `ReasonCode` members.
const min_reason_codes = 71;
const permitted_alias_a = "= std.testing;";
const permitted_alias_b = "= std.crypto.hash.sha2.Sha256;";
/// Reason codes no input can produce, each with its mechanism.
/// `unsupported_proof_system`: ProofSystem has one member, and a validated policy cannot
/// select an empty set, so no certificate can name a proof system the policy excludes.
const unproducible_codes = [_][]const u8{"unsupported_proof_system"};

pub const Source = struct {
    ctx: *anyopaque,
    dir_exists: *const fn (ctx: *anyopaque, path: []const u8) bool,
    file_exists: *const fn (ctx: *anyopaque, path: []const u8) bool,
    /// Paths under `packages/proof-checker/src`, tracked or untracked and not ignored,
    /// in the order Git lists them.
    list: *const fn (ctx: *anyopaque, arena: std.mem.Allocator) anyerror![]const []const u8,
    read: *const fn (ctx: *anyopaque, arena: std.mem.Allocator, path: []const u8) anyerror![]const u8,
};

pub const Outcome = union(enum) {
    pass: struct { tests: usize, files: usize },
    /// The complete diagnostic text, newline terminated, for stderr.
    fail: []const u8,
};

const Note = struct {
    arena: std.mem.Allocator,
    text: std.ArrayList(u8) = .empty,
    count: usize = 0,

    fn add(self: *Note, comptime format: []const u8, args: anytype) !void {
        try self.text.print(self.arena, "proof-checker: " ++ format ++ "\n", args);
        self.count += 1;
    }

    fn raw(self: *Note, text: []const u8) !void {
        try self.text.appendSlice(self.arena, text);
        try self.text.append(self.arena, '\n');
    }
};

fn isIdentChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

fn isIdentStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_';
}

fn lessString(_: void, lhs: []const u8, rhs: []const u8) bool {
    return std.mem.order(u8, lhs, rhs) == .lt;
}

const File = struct {
    path: []const u8,
    text: []const u8,
    lines: []const []const u8,
    newlines: usize,

    fn basename(self: File) []const u8 {
        const slash = std.mem.findScalarLast(u8, self.path, '/') orelse return self.path;
        return self.path[slash + 1 ..];
    }
};

/// Lines as `grep -n` numbers them: a trailing newline does not start another line.
fn splitLines(arena: std.mem.Allocator, text: []const u8) ![]const []const u8 {
    var lines: std.ArrayList([]const u8) = .empty;
    var pieces = std.mem.splitScalar(u8, text, '\n');
    while (pieces.next()) |piece| {
        if (pieces.peek() == null and piece.len == 0) break;
        try lines.append(arena, piece);
    }
    return lines.items;
}

const LineMatcher = *const fn (line: []const u8) bool;

fn substring(comptime needle: []const u8) LineMatcher {
    return struct {
        fn matches(line: []const u8) bool {
            return std.mem.find(u8, line, needle) != null;
        }
    }.matches;
}

/// `(^|[^A-Za-z0-9_])<word>[^A-Za-z0-9_]`: the word as a whole token with a character
/// after it. A word that ends the line does not match.
fn tokenWithFollower(line: []const u8, word: []const u8) bool {
    var from: usize = 0;
    while (std.mem.find(u8, line[from..], word)) |relative| {
        const at = from + relative;
        from = at + 1;
        if (at > 0 and isIdentChar(line[at - 1])) continue;
        const after = at + word.len;
        if (after < line.len and !isIdentChar(line[after])) return true;
    }
    return false;
}

fn externToken(line: []const u8) bool {
    return tokenWithFollower(line, "extern");
}

fn asmToken(line: []const u8) bool {
    return tokenWithFollower(line, "asm");
}

/// `^[[:space:]]*(pub )?export `
fn exportDeclaration(line: []const u8) bool {
    var cursor: usize = 0;
    while (cursor < line.len and std.ascii.isWhitespace(line[cursor])) cursor += 1;
    if (std.mem.startsWith(u8, line[cursor..], "pub ")) cursor += "pub ".len;
    return std.mem.startsWith(u8, line[cursor..], "export ");
}

const Forbidden = struct { display: []const u8, matches: LineMatcher };

/// SHA-256 over caller-supplied bytes is pure and is permitted. Signing, I/O, time, and
/// process control are not. The display text is the pattern the shell gate printed.
const forbidden = [_]Forbidden{
    .{ .display = "std\\.fs\\.", .matches = substring("std.fs.") },
    .{ .display = "std\\.process\\.", .matches = substring("std.process.") },
    .{ .display = "std\\.time\\.", .matches = substring("std.time.") },
    .{ .display = "std\\.net\\.", .matches = substring("std.net.") },
    .{ .display = "std\\.Thread", .matches = substring("std.Thread") },
    .{ .display = "std\\.posix", .matches = substring("std.posix") },
    .{ .display = "std\\.os\\.", .matches = substring("std.os.") },
    .{ .display = "std\\.http", .matches = substring("std.http") },
    .{ .display = "std\\.crypto\\.sign", .matches = substring("std.crypto.sign") },
    .{ .display = "std\\.crypto\\.random", .matches = substring("std.crypto.random") },
    .{ .display = "std\\.Random", .matches = substring("std.Random") },
    .{ .display = "getStdOut", .matches = substring("getStdOut") },
    .{ .display = "getStdErr", .matches = substring("getStdErr") },
    .{ .display = "std\\.heap\\.", .matches = substring("std.heap.") },
    .{ .display = "std\\.Io", .matches = substring("std.Io") },
    .{ .display = "std\\.log", .matches = substring("std.log") },
    .{ .display = "std\\.c\\.", .matches = substring("std.c.") },
    .{ .display = "std\\.atomic", .matches = substring("std.atomic") },
    .{ .display = "@embedFile", .matches = substring("@embedFile") },
    .{ .display = "(^|[^A-Za-z0-9_])extern[^A-Za-z0-9_]", .matches = externToken },
    .{ .display = "^[[:space:]]*(pub )?export ", .matches = exportDeclaration },
    .{ .display = "(^|[^A-Za-z0-9_])asm[^A-Za-z0-9_]", .matches = asmToken },
    .{ .display = "threadlocal", .matches = substring("threadlocal") },
};

fn appendHits(arena: std.mem.Allocator, hits: *std.ArrayList(u8), files: []const File, matches: LineMatcher) !usize {
    var count: usize = 0;
    for (files) |file| {
        for (file.lines, 1..) |line, number| {
            if (!matches(line)) continue;
            try hits.print(arena, "{s}:{d}:{s}\n", .{ file.path, number, line });
            count += 1;
        }
    }
    return count;
}

fn noteHits(note: *Note, files: []const File, matches: LineMatcher, comptime heading: []const u8, args: anytype) !void {
    var hits: std.ArrayList(u8) = .empty;
    if (try appendHits(note.arena, &hits, files, matches) == 0) return;
    try note.add(heading, args);
    try note.text.appendSlice(note.arena, hits.items);
}

fn containerVar(line: []const u8) bool {
    return std.mem.startsWith(u8, line, "var ") or std.mem.startsWith(u8, line, "pub var ");
}

/// `^[[:space:]]*(pub )?const <ident> = (std|std\.<ident-path>);`, a line that aliases
/// `std` or one of its namespaces and does not end in a permitted alias target.
fn stdAliasNotPermitted(line: []const u8) bool {
    var cursor: usize = 0;
    while (cursor < line.len and std.ascii.isWhitespace(line[cursor])) cursor += 1;
    if (std.mem.startsWith(u8, line[cursor..], "pub ")) cursor += "pub ".len;
    if (!std.mem.startsWith(u8, line[cursor..], "const ")) return false;
    cursor += "const ".len;
    if (cursor >= line.len or !isIdentStart(line[cursor])) return false;
    while (cursor < line.len and isIdentChar(line[cursor])) cursor += 1;
    if (!std.mem.startsWith(u8, line[cursor..], " = ")) return false;
    cursor += " = ".len;
    if (!std.mem.startsWith(u8, line[cursor..], "std")) return false;
    cursor += "std".len;
    if (cursor < line.len and line[cursor] == ';') return !permittedAliasEnding(line);
    if (cursor + 1 >= line.len or line[cursor] != '.' or !isIdentStart(line[cursor + 1])) return false;
    cursor += 1;
    while (cursor < line.len and (isIdentChar(line[cursor]) or line[cursor] == '.')) cursor += 1;
    if (cursor >= line.len or line[cursor] != ';') return false;
    return !permittedAliasEnding(line);
}

fn permittedAliasEnding(line: []const u8) bool {
    return std.mem.endsWith(u8, line, permitted_alias_a) or std.mem.endsWith(u8, line, permitted_alias_b);
}

fn bindsStdElsewhere(line: []const u8) bool {
    return std.mem.find(u8, line, "@import(\"std\")") != null and
        std.mem.find(u8, line, "const std = @import(\"std\");") == null;
}

fn namesAllocator(line: []const u8) bool {
    return std.mem.find(u8, line, "std.mem.Allocator") != null or std.mem.find(u8, line, "allocator") != null;
}

/// The last `@import("<target>")` on the line whose target holds no quote.
fn lastImportTarget(line: []const u8) ?[]const u8 {
    const open = "@import(\"";
    var search_end = line.len;
    while (std.mem.findLast(u8, line[0..search_end], open)) |at| {
        const target_start = at + open.len;
        if (std.mem.findScalar(u8, line[target_start..], '"')) |relative| {
            const close = target_start + relative;
            if (close + 1 < line.len and line[close + 1] == ')') return line[target_start..close];
        }
        search_end = at;
    }
    return null;
}

pub fn check(arena: std.mem.Allocator, source: Source) !Outcome {
    var note: Note = .{ .arena = arena };

    if (!source.dir_exists(source.ctx, src_path)) {
        try note.add("missing {s}", .{src_path});
        return .{ .fail = note.text.items };
    }
    if (!source.file_exists(source.ctx, test_root_path)) {
        try note.add("missing {s}", .{test_root_path});
        return .{ .fail = note.text.items };
    }

    // Floor: the file set the rest of this gate reads must not be empty.
    const listed = source.list(source.ctx, arena) catch {
        try note.add("cannot list the files under {s}", .{src_path});
        return .{ .fail = note.text.items };
    };
    var paths: std.ArrayList([]const u8) = .empty;
    for (listed) |path| {
        if (std.mem.endsWith(u8, path, ".zig")) try paths.append(arena, path);
    }
    std.mem.sort([]const u8, paths.items, {}, lessString);
    if (paths.items.len < min_sources) {
        try note.add(
            "found {d} source files under {s}, expected at least {d} - the gate is reading nothing",
            .{ paths.items.len, src_path, min_sources },
        );
        return .{ .fail = note.text.items };
    }
    var files = try arena.alloc(File, paths.items.len);
    var total_newlines: usize = 0;
    for (paths.items, 0..) |path, index| {
        const text = source.read(source.ctx, arena, path) catch {
            try note.add("cannot read {s}", .{path});
            return .{ .fail = note.text.items };
        };
        files[index] = .{
            .path = path,
            .text = text,
            .lines = try splitLines(arena, text),
            .newlines = std.mem.count(u8, text, "\n"),
        };
        total_newlines += files[index].newlines;
    }

    // 1. Leaf boundary. The manifest declares no dependency at all.
    const manifest = source.read(source.ctx, arena, manifest_path) catch "";
    if (std.mem.find(u8, manifest, ".dependencies = .{}") == null) {
        try note.add("{s} declares dependencies; the acceptance kernel must stay a leaf", .{manifest_path});
    }

    // Imports: `std` plus sibling files in this directory. Anything else, a package name
    // or a relative path that leaves the directory, widens the trusted computing base.
    for (files) |file| {
        for (file.lines) |line| {
            if (std.mem.find(u8, line, "@import(") == null) continue;
            const target = lastImportTarget(line) orelse continue;
            if (target.len == 0) continue;
            if (std.mem.eql(u8, target, "std")) continue;
            if (std.mem.findScalar(u8, target, '/') != null) {
                try note.add("{s} imports '{s}': the kernel may not reach outside its own directory", .{ file.path, target });
            } else if (std.mem.endsWith(u8, target, ".zig")) {
                const sibling = try std.fmt.allocPrint(arena, "{s}/{s}", .{ src_path, target });
                if (!source.file_exists(source.ctx, sibling)) {
                    try note.add("{s} imports '{s}', which is not a sibling of the kernel", .{ file.path, target });
                }
            } else {
                try note.add("{s} imports package '{s}': the kernel must stay a leaf", .{ file.path, target });
            }
        }
    }

    // Ambient capability. SHA-256 is permitted; signing, I/O, time, and process control are not.
    for (forbidden) |pattern| {
        try noteHits(&note, files, pattern.matches, "ambient capability '{s}' reached from the kernel:", .{pattern.display});
    }

    // Mutable statics. A container-level `var` is state shared by every call, which makes a
    // verdict depend on the calls before it. `zig fmt` puts every container declaration at
    // column 0, so a column-0 `var` is exactly the top-level form.
    try noteHits(&note, files, containerVar, "the kernel declares a container-level var; it holds no mutable state:", .{});

    // Production-only patterns are checked outside `test` blocks and outside the private
    // `fn expect...` helpers those blocks call. `zig fmt` opens a top-level declaration at
    // column 0 and closes it with a bare `}` at column 0, which is what this keys on.
    var production: std.ArrayList([]const u8) = .empty;
    for (files) |file| {
        var in_test = false;
        for (file.lines, 1..) |line, number| {
            if (std.mem.startsWith(u8, line, "test \"") or std.mem.startsWith(u8, line, "fn expect")) in_test = true;
            if (!in_test) try production.append(arena, try std.fmt.allocPrint(arena, "{s}:{d}:{s}", .{ file.path, number, line }));
            if (in_test and std.mem.startsWith(u8, line, "}")) in_test = false;
        }
    }
    // Floor on the filter: it must drop the test lines and keep the rest, or a shape
    // change has made it pass everything or check nothing. An empty result counts as one
    // line, as the shell gate's line count did.
    const production_count = @max(production.items.len, 1);
    if (production_count >= total_newlines or production_count < total_newlines / 4) {
        try note.add(
            "the test-block filter kept {d} of {d} lines; it no longer separates tests from production code",
            .{ production_count, total_newlines },
        );
    }
    {
        var hits: std.ArrayList(u8) = .empty;
        for (production.items) |line| {
            if (std.mem.find(u8, line, "std.debug.print") != null) try hits.print(arena, "{s}\n", .{line});
        }
        if (hits.items.len > 0) {
            try note.add("'std\\.debug\\.print' reached from kernel production code:", .{});
            try note.text.appendSlice(arena, hits.items);
        }
    }

    // The patterns above only see a capability reached as `std.fs.cwd()`. A rebinding such as
    // `const fs = std.fs;` or `const s = @import("std");` puts the dotted form out of sight, so
    // the patterns are sound only while `std` is reached through exactly one name. Two alias
    // targets are permitted: `std.testing`, reachable only from a test block, and SHA-256
    // over caller-supplied bytes, which is pure.
    try noteHits(
        &note,
        files,
        stdAliasNotPermitted,
        "the kernel aliases std or one of its namespaces; the capability patterns above only match the dotted form, so an alias makes them blind:",
        .{},
    );
    // Floor on the check above: a permitted alias must match something, or the check has
    // become a pattern that refuses nothing.
    var permitted_seen = false;
    for (files) |file| {
        for (file.lines) |line| {
            if (permittedAliasEnding(line)) permitted_seen = true;
        }
    }
    if (!permitted_seen) {
        try note.add("no permitted std alias matches in the kernel; the alias check is vacuous - update permitted_aliases", .{});
    }
    try noteHits(
        &note,
        files,
        bindsStdElsewhere,
        "the kernel binds @import(\"std\") to a name other than 'std'; reach std through one name so the capability patterns above can see it:",
        .{},
    );

    // Allocation. The kernel is allocation-free so a certificate cannot choose how much memory
    // a consumer spends.
    try noteHits(&note, files, namesAllocator, "the kernel names an allocator; it is allocation-free by design:", .{});

    // 2. Non-empty suite, and every source in it.
    const test_root_text = blk: {
        for (files) |file| if (std.mem.eql(u8, file.basename(), test_root_name)) break :blk file.text;
        break :blk source.read(source.ctx, arena, test_root_path) catch "";
    };
    var total_tests: usize = 0;
    for (files) |file| {
        const base = file.basename();
        if (std.mem.eql(u8, base, test_root_name)) continue;
        const reference = try std.fmt.allocPrint(arena, "@import(\"{s}\")", .{base});
        if (std.mem.find(u8, test_root_text, reference) == null) {
            try note.add("{s} is not referenced by {s}, so its tests never run", .{ base, test_root_path });
        }
        var count: usize = 0;
        for (file.lines) |line| {
            if (std.mem.startsWith(u8, line, "test \"")) count += 1;
        }
        if (!std.mem.eql(u8, base, "root.zig") and count == 0) {
            try note.add("{s} declares no test; the kernel's suite must cover every file in it", .{base});
        }
        total_tests += count;
    }
    // The floor itself. Deleting the corpus must fail this gate, not quietly pass it.
    if (total_tests < min_tests) {
        try note.add("found {d} kernel tests, expected at least {d}", .{ total_tests, min_tests });
    }

    // 3. Reason-code census. Every public ReasonCode is named inside at least one kernel test
    // block, or carries a row stating why no input can produce it. A code nothing names is
    // either unpinned or unproducible.
    const verdict_text = source.read(source.ctx, arena, verdict_path) catch "";
    const codes = try reasonCodes(arena, verdict_text);
    if (codes.len < min_reason_codes) {
        try note.add("read {d} ReasonCode members from {s}; the census is reading nothing", .{ codes.len, verdict_path });
    }
    var test_lines: std.ArrayList([]const u8) = .empty;
    for (files) |file| {
        var in_test = false;
        for (file.lines) |line| {
            if (std.mem.startsWith(u8, line, "test \"")) in_test = true;
            if (in_test) try test_lines.append(arena, line);
            if (in_test and std.mem.startsWith(u8, line, "}")) in_test = false;
        }
    }
    for (codes) |code| {
        var allowed = false;
        for (unproducible_codes) |row| {
            if (std.mem.eql(u8, row, code)) allowed = true;
        }
        var named = false;
        for (test_lines.items) |line| {
            if (namesCode(line, code)) {
                named = true;
                break;
            }
        }
        if (allowed and named) {
            try note.add("ReasonCode.{s} is allowlisted as unproducible but a test names it; remove the row", .{code});
        } else if (!allowed and !named) {
            try note.add("ReasonCode.{s} is named by no kernel test; pin it or allowlist it with the mechanism", .{code});
        }
    }
    for (unproducible_codes) |row| {
        var found = false;
        for (codes) |code| {
            if (std.mem.eql(u8, code, row)) found = true;
        }
        if (!found) try note.add("unproducible_codes row '{s}' is not a ReasonCode member", .{row});
    }

    if (note.count > 0) return .{ .fail = note.text.items };
    return .{ .pass = .{ .tests = total_tests, .files = files.len } };
}

/// Members of `pub const ReasonCode = enum`: `    name = 1234,` lines up to the closing `};`.
fn reasonCodes(arena: std.mem.Allocator, verdict_text: []const u8) ![]const []const u8 {
    var codes: std.ArrayList([]const u8) = .empty;
    var in_range = false;
    var pieces = std.mem.splitScalar(u8, verdict_text, '\n');
    while (pieces.next()) |line| {
        if (!in_range) {
            if (std.mem.startsWith(u8, line, "pub const ReasonCode = enum")) in_range = true else continue;
        }
        if (std.mem.startsWith(u8, line, "};")) break;
        var cursor: usize = 0;
        while (cursor < line.len and std.ascii.isWhitespace(line[cursor])) cursor += 1;
        if (cursor == 0) continue;
        const name_start = cursor;
        while (cursor < line.len and (std.ascii.isLower(line[cursor]) or line[cursor] == '_')) cursor += 1;
        if (cursor == name_start) continue;
        const name = line[name_start..cursor];
        if (!std.mem.startsWith(u8, line[cursor..], " = ")) continue;
        cursor += " = ".len;
        const digits_start = cursor;
        while (cursor < line.len and std.ascii.isDigit(line[cursor])) cursor += 1;
        if (cursor == digits_start) continue;
        if (cursor >= line.len or line[cursor] != ',') continue;
        try codes.append(arena, name);
    }
    return codes.items;
}

/// `\.<code>([^a-z_]|$)` somewhere in the line.
fn namesCode(line: []const u8, code: []const u8) bool {
    var from: usize = 0;
    while (std.mem.findScalar(u8, line[from..], '.')) |relative| {
        const at = from + relative;
        from = at + 1;
        if (!std.mem.startsWith(u8, line[at + 1 ..], code)) continue;
        const after = at + 1 + code.len;
        if (after >= line.len) return true;
        if (!(std.ascii.isLower(line[after]) or line[after] == '_')) return true;
    }
    return false;
}

// ---------------------------------------------------------------------------
// The real source: Git for the listing, the working tree for the bodies.
// ---------------------------------------------------------------------------

const RealSource = struct {
    io: std.Io,

    fn dirExists(ctx: *anyopaque, path: []const u8) bool {
        const self: *RealSource = @ptrCast(@alignCast(ctx));
        var dir = std.Io.Dir.cwd().openDir(self.io, path, .{}) catch return false;
        dir.close(self.io);
        return true;
    }

    fn fileExists(ctx: *anyopaque, path: []const u8) bool {
        const self: *RealSource = @ptrCast(@alignCast(ctx));
        const file = std.Io.Dir.cwd().openFile(self.io, path, .{}) catch return false;
        file.close(self.io);
        return true;
    }

    fn list(ctx: *anyopaque, arena: std.mem.Allocator) anyerror![]const []const u8 {
        const self: *RealSource = @ptrCast(@alignCast(ctx));
        const result = try std.process.run(arena, self.io, .{
            .argv = &.{ "git", "ls-files", "-z", "--cached", "--others", "--exclude-standard", src_path },
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
    const outcome = try check(arena, .{
        .ctx = &real,
        .dir_exists = RealSource.dirExists,
        .file_exists = RealSource.fileExists,
        .list = RealSource.list,
        .read = RealSource.read,
    });
    switch (outcome) {
        .pass => |counts| {
            try stdout.print("proof-checker: leaf boundary holds; {d} tests across {d} files\n", .{ counts.tests, counts.files });
            return 0;
        },
        .fail => |message| {
            std.debug.print("{s}", .{message});
            return 1;
        },
    }
}

// ---------------------------------------------------------------------------
// Tests: a synthetic kernel that passes, and one mutation for each rejection.
// ---------------------------------------------------------------------------

const TestKernel = struct {
    names: []const []const u8,
    texts: []const []const u8,
    manifest: []const u8 = ".{ .dependencies = .{}, }",
    omit_dir: bool = false,
    omit_test_root: bool = false,

    fn source(self: *TestKernel) Source {
        return .{ .ctx = self, .dir_exists = dirExists, .file_exists = fileExists, .list = list, .read = read };
    }

    fn dirExists(ctx: *anyopaque, path: []const u8) bool {
        const self: *TestKernel = @ptrCast(@alignCast(ctx));
        return !self.omit_dir and std.mem.eql(u8, path, src_path);
    }

    fn fileExists(ctx: *anyopaque, path: []const u8) bool {
        const self: *TestKernel = @ptrCast(@alignCast(ctx));
        if (self.omit_test_root and std.mem.eql(u8, path, test_root_path)) return false;
        for (self.names) |name| {
            if (path.len == src_path.len + 1 + name.len and std.mem.endsWith(u8, path, name)) return true;
        }
        return false;
    }

    fn list(ctx: *anyopaque, arena: std.mem.Allocator) anyerror![]const []const u8 {
        const self: *TestKernel = @ptrCast(@alignCast(ctx));
        const paths = try arena.alloc([]const u8, self.names.len);
        for (self.names, paths) |name, *path| path.* = try std.fmt.allocPrint(arena, "{s}/{s}", .{ src_path, name });
        return paths;
    }

    fn read(ctx: *anyopaque, _: std.mem.Allocator, path: []const u8) anyerror![]const u8 {
        const self: *TestKernel = @ptrCast(@alignCast(ctx));
        if (std.mem.eql(u8, path, manifest_path)) return self.manifest;
        for (self.names, self.texts) |name, text| {
            if (path.len == src_path.len + 1 + name.len and std.mem.endsWith(u8, path, name)) return text;
        }
        return error.FileNotFound;
    }
};

const file_names = [_][]const u8{
    "a.zig", "b.zig", "c.zig",    "d.zig",       "e.zig",         "f.zig", "g.zig", "h.zig",
    "i.zig", "j.zig", "root.zig", "verdict.zig", "test_root.zig",
};

/// The member count of the synthetic enum: above the floor, each named by a test in `a.zig`.
const code_count = 72;

/// Text of the synthetic kernel files, built once per test from `base`, then one file replaced.
fn buildTexts(arena: std.mem.Allocator, replace: ?struct { name: []const u8, text: []const u8 }, append_to_a: []const u8) ![]const []const u8 {
    const texts = try arena.alloc([]const u8, file_names.len);
    for (file_names, texts) |name, *text| {
        if (replace) |change| {
            if (std.mem.eql(u8, name, change.name)) {
                text.* = change.text;
                continue;
            }
        }
        text.* = try baseText(arena, name, append_to_a);
    }
    return texts;
}

fn baseText(arena: std.mem.Allocator, name: []const u8, append_to_a: []const u8) ![]const u8 {
    var text: std.ArrayList(u8) = .empty;
    if (std.mem.eql(u8, name, "test_root.zig")) {
        try text.appendSlice(arena, "comptime {\n");
        for (file_names) |entry| {
            if (std.mem.eql(u8, entry, "test_root.zig")) continue;
            try text.print(arena, "    _ = @import(\"{s}\");\n", .{entry});
        }
        try text.appendSlice(arena, "}\n");
        return text.items;
    }
    try text.appendSlice(arena, "const std = @import(\"std\");\nconst testing = std.testing;\n");
    if (std.mem.eql(u8, name, "verdict.zig")) {
        try text.appendSlice(arena, "pub const ReasonCode = enum(u16) {\n");
        for (0..code_count) |index| try text.print(arena, "    code_{c}{c} = {d},\n", .{ 'a' + @as(u8, @intCast(index / 26)), 'a' + @as(u8, @intCast(index % 26)), index + 1 });
        try text.appendSlice(arena, "    unsupported_proof_system = 900,\n};\n");
    }
    // Every file carries production lines and a few tests; `a.zig` also carries the census names.
    for (0..4) |index| try text.print(arena, "pub fn f{d}() u32 {{\n    return {d};\n}}\n", .{ index, index });
    if (!std.mem.eql(u8, name, "root.zig")) {
        // `a.zig` holds the bulk of the suite: 187 here, one in each of the ten other files
        // with tests, and the census block below.
        const tests: usize = if (std.mem.eql(u8, name, "a.zig")) 186 else 1;
        for (0..tests) |index| try text.print(arena, "test \"t{d}\" {{\n}}\n", .{index});
    }
    if (std.mem.eql(u8, name, "a.zig")) {
        try text.appendSlice(arena, "test \"census\" {\n");
        for (0..code_count) |index| try text.print(arena, "    _ = .code_{c}{c};\n", .{ 'a' + @as(u8, @intCast(index / 26)), 'a' + @as(u8, @intCast(index % 26)) });
        try text.appendSlice(arena, "}\n");
        try text.appendSlice(arena, append_to_a);
    }
    return text.items;
}

fn runKernel(arena: std.mem.Allocator, texts: []const []const u8, configure: ?*const fn (*TestKernel) void) !Outcome {
    var kernel: TestKernel = .{ .names = &file_names, .texts = texts };
    if (configure) |apply| apply(&kernel);
    return check(arena, kernel.source());
}

fn expectNote(outcome: Outcome, needle: []const u8) !void {
    switch (outcome) {
        .pass => return error.TestExpectedFailure,
        .fail => |message| {
            if (std.mem.find(u8, message, needle) == null) {
                std.debug.print("expected {s} in:\n{s}", .{ needle, message });
                return error.TestNoteMissing;
            }
        },
    }
}

fn mutated(arena: std.mem.Allocator, append_to_a: []const u8) !Outcome {
    return runKernel(arena, try buildTexts(arena, null, append_to_a), null);
}

test "a synthetic kernel that follows every rule passes and reports its counts" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const outcome = try mutated(arena, "");
    switch (outcome) {
        .pass => |counts| {
            try std.testing.expectEqual(@as(usize, file_names.len), counts.files);
            try std.testing.expect(counts.tests >= min_tests);
        },
        .fail => |message| {
            std.debug.print("{s}", .{message});
            return error.TestExpectedPass;
        },
    }
}

test "an import of a package, a path, or a missing sibling is refused" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try expectNote(try mutated(arena, "const z = @import(\"zts\");\n"), "a.zig imports package 'zts': the kernel must stay a leaf");
    try expectNote(try mutated(arena, "const z = @import(\"../x.zig\");\n"), "a.zig imports '../x.zig': the kernel may not reach outside its own directory");
    try expectNote(try mutated(arena, "const z = @import(\"nothere.zig\");\n"), "a.zig imports 'nothere.zig', which is not a sibling of the kernel");
    // The last import on a line decides, and an import without a literal target is ignored.
    try expectNote(try mutated(arena, "const a = @import(\"std\"); const b = @import(\"zts\");\n"), "imports package 'zts'");
    const first_ignored = try mutated(arena, "const b = @import(\"zts\"); const a = @import(\"std\");\n");
    try expectNote(first_ignored, "binds @import(\"std\") to a name other than");
    try std.testing.expect(std.mem.find(u8, first_ignored.fail, "imports package") == null);
    try std.testing.expect((try mutated(arena, "const b = @import(name);\n")) == .pass);
}

test "a manifest that declares a dependency is refused, and so is a manifest that cannot be read" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const texts = try buildTexts(arena, null, "");
    const dependent = struct {
        fn apply(kernel: *TestKernel) void {
            kernel.manifest = ".{ .dependencies = .{ .x = .{} }, }";
        }
    }.apply;
    try expectNote(try runKernel(arena, texts, dependent), "declares dependencies; the acceptance kernel must stay a leaf");
    const empty = struct {
        fn apply(kernel: *TestKernel) void {
            kernel.manifest = "";
        }
    }.apply;
    try expectNote(try runKernel(arena, texts, empty), "declares dependencies");
}

test "every ambient capability pattern is refused on the input that trips it" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const rejected = [_]struct { line: []const u8, display: []const u8 }{
        .{ .line = "// std.fs.cwd", .display = "std\\.fs\\." },
        .{ .line = "// std.process.exit", .display = "std\\.process\\." },
        .{ .line = "// std.time.now", .display = "std\\.time\\." },
        .{ .line = "// std.net.x", .display = "std\\.net\\." },
        .{ .line = "// std.Thread", .display = "std\\.Thread" },
        .{ .line = "// std.posix", .display = "std\\.posix" },
        .{ .line = "// std.os.x", .display = "std\\.os\\." },
        .{ .line = "// std.http", .display = "std\\.http" },
        .{ .line = "// std.crypto.sign", .display = "std\\.crypto\\.sign" },
        .{ .line = "// std.crypto.random", .display = "std\\.crypto\\.random" },
        .{ .line = "// std.Random", .display = "std\\.Random" },
        .{ .line = "// getStdOut", .display = "getStdOut" },
        .{ .line = "// getStdErr", .display = "getStdErr" },
        .{ .line = "// std.heap.x", .display = "std\\.heap\\." },
        .{ .line = "// std.Io", .display = "std\\.Io" },
        .{ .line = "// std.log", .display = "std\\.log" },
        .{ .line = "// std.c.x", .display = "std\\.c\\." },
        .{ .line = "// std.atomic", .display = "std\\.atomic" },
        .{ .line = "// @embedFile", .display = "@embedFile" },
        .{ .line = "// extern foo", .display = "(^|[^A-Za-z0-9_])extern[^A-Za-z0-9_]" },
        .{ .line = "export fn f() void {}", .display = "^[[:space:]]*(pub )?export " },
        .{ .line = "pub export fn f() void {}", .display = "^[[:space:]]*(pub )?export " },
        .{ .line = "    export fn f() void {}", .display = "^[[:space:]]*(pub )?export " },
        .{ .line = "// asm volatile", .display = "(^|[^A-Za-z0-9_])asm[^A-Za-z0-9_]" },
        .{ .line = "// threadlocal", .display = "threadlocal" },
    };
    for (rejected) |case| {
        const line = try std.fmt.allocPrint(arena, "{s}\n", .{case.line});
        const needle = try std.fmt.allocPrint(arena, "ambient capability '{s}' reached from the kernel:\n", .{case.display});
        try expectNote(try mutated(arena, line), needle);
    }
    // The shell patterns needed a following character, and a longer identifier is not the word.
    for ([_][]const u8{ "// extern\n", "// asm\n", "// externs foo\n" }) |accepted| {
        try std.testing.expect((try mutated(arena, accepted)) == .pass);
    }
}

test "a container-level var is refused, a test-local one is not" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try expectNote(try mutated(arena, "var counter: u32 = 0;\n"), "the kernel declares a container-level var");
    try expectNote(try mutated(arena, "pub var counter: u32 = 0;\n"), "the kernel declares a container-level var");
    try std.testing.expect((try mutated(arena, "test \"x\" {\n    var local: u32 = 0;\n    _ = &local;\n}\n")) == .pass);
}

test "a diagnostic print is refused in production code and allowed in tests and expect helpers" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try expectNote(try mutated(arena, "fn prod() void {\n    std.debug.print(\"x\", .{});\n}\n"), "'std\\.debug\\.print' reached from kernel production code:");
    try std.testing.expect((try mutated(arena, "test \"t\" {\n    std.debug.print(\"x\", .{});\n}\n")) == .pass);
    try std.testing.expect((try mutated(arena, "fn expectX() void {\n    std.debug.print(\"x\", .{});\n}\n")) == .pass);
}

test "the test-block filter must separate tests from production code" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var big: std.ArrayList(u8) = .empty;
    try big.appendSlice(arena, "test \"big\" {\n");
    for (0..50_000) |_| try big.appendSlice(arena, "    _ = 1;\n");
    try big.appendSlice(arena, "}\n");
    try expectNote(try mutated(arena, big.items), "it no longer separates tests from production code");
}

test "an alias of std or a namespace of it, or a second name for std, is refused" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try expectNote(try mutated(arena, "const fs = std.fs;\n"), "the kernel aliases std or one of its namespaces");
    try expectNote(try mutated(arena, "pub const heap = std.heap.page_allocator;\n"), "the kernel aliases std or one of its namespaces");
    try expectNote(try mutated(arena, "const same = std;\n"), "the kernel aliases std or one of its namespaces");
    try expectNote(try mutated(arena, "const s = @import(\"std\");\n"), "the kernel binds @import(\"std\") to a name other than 'std'");
    // The two permitted targets are fine, but only when the line ends with the target.
    try std.testing.expect((try mutated(arena, "const hash = std.crypto.hash.sha2.Sha256;\n")) == .pass);
    try expectNote(try mutated(arena, "const t2 = std.testing; // note\n"), "the kernel aliases std or one of its namespaces");
}

test "the permitted alias floor fails when no permitted alias is left to match" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var texts = try arena.dupe([]const u8, try buildTexts(arena, null, ""));
    for (texts, 0..) |text, index| {
        texts[index] = try std.mem.replaceOwned(u8, arena, text, "const testing = std.testing;", "const testing = std.testing ;");
    }
    try expectNote(try runKernel(arena, texts, null), "no permitted std alias matches in the kernel; the alias check is vacuous");
}

test "an allocator named anywhere in the kernel is refused" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try expectNote(try mutated(arena, "// allocator\n"), "the kernel names an allocator; it is allocation-free by design:");
    try expectNote(try mutated(arena, "const A = std.mem.Allocator;\n"), "the kernel names an allocator");
}

test "a source file with no listing, no reference, or no test is refused" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // A file the test root does not import.
    var texts = try arena.dupe([]const u8, try buildTexts(arena, null, ""));
    texts[file_names.len - 1] = try std.mem.replaceOwned(u8, arena, texts[file_names.len - 1], "    _ = @import(\"b.zig\");\n", "");
    try expectNote(try runKernel(arena, texts, null), "b.zig is not referenced by packages/proof-checker/src/test_root.zig, so its tests never run");
    // A file with no test block.
    const no_tests = try buildTexts(arena, .{ .name = "c.zig", .text = "pub const x = 1;\n" }, "");
    try expectNote(try runKernel(arena, no_tests, null), "c.zig declares no test; the kernel's suite must cover every file in it");
}

test "a suite below the floor is refused" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const base = try baseText(arena, "a.zig", "");
    // The synthetic suite holds 197 tests; dropping three leaves 194.
    var fewer = base;
    for ([_][]const u8{ "test \"t0\" {", "test \"t1\" {", "test \"t2\" {" }) |declaration| {
        const renamed = try std.fmt.allocPrint(arena, "x{s}", .{declaration});
        fewer = try std.mem.replaceOwned(u8, arena, fewer, declaration, renamed);
    }
    const texts = try buildTexts(arena, .{ .name = "a.zig", .text = fewer }, "");
    try expectNote(try runKernel(arena, texts, null), "kernel tests, expected at least 195");
}

test "fewer sources than the floor is refused before anything else is read" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const texts = try buildTexts(arena, null, "");
    var kernel: TestKernel = .{ .names = file_names[1..], .texts = texts[1..] };
    const outcome = try check(arena, kernel.source());
    try expectNote(outcome, "found 12 source files under packages/proof-checker/src, expected at least 13 - the gate is reading nothing");
}

test "a missing source directory or test root is refused by name" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const texts = try buildTexts(arena, null, "");
    const no_dir = struct {
        fn apply(kernel: *TestKernel) void {
            kernel.omit_dir = true;
        }
    }.apply;
    try expectNote(try runKernel(arena, texts, no_dir), "proof-checker: missing packages/proof-checker/src\n");
    const no_root = struct {
        fn apply(kernel: *TestKernel) void {
            kernel.omit_test_root = true;
        }
    }.apply;
    try expectNote(try runKernel(arena, texts, no_root), "proof-checker: missing packages/proof-checker/src/test_root.zig\n");
}

test "the reason-code census refuses an unnamed code, a named unproducible code, and a short read" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // A new member that no test names.
    const base_verdict = try baseText(arena, "verdict.zig", "");
    const extra = try std.mem.replaceOwned(u8, arena, base_verdict, "pub const ReasonCode = enum(u16) {\n", "pub const ReasonCode = enum(u16) {\n    brand_new_code = 9999,\n");
    const unnamed = try buildTexts(arena, .{ .name = "verdict.zig", .text = extra }, "");
    try expectNote(try runKernel(arena, unnamed, null), "ReasonCode.brand_new_code is named by no kernel test; pin it or allowlist it with the mechanism");
    // The allowlisted code is named by a test.
    try expectNote(try mutated(arena, "test \"names it\" {\n    _ = .unsupported_proof_system;\n}\n"), "ReasonCode.unsupported_proof_system is allowlisted as unproducible but a test names it; remove the row");
    // Members that no longer parse leave the census reading nothing.
    const garbled = try std.mem.replaceOwned(u8, arena, base_verdict, " = ", " : ");
    const unreadable = try buildTexts(arena, .{ .name = "verdict.zig", .text = garbled }, "");
    try expectNote(try runKernel(arena, unreadable, null), "read 0 ReasonCode members from packages/proof-checker/src/verdict.zig; the census is reading nothing");
}

test "a code named as a prefix of another is not named" {
    try std.testing.expect(namesCode("    _ = .alpha_beta,", "alpha_beta"));
    try std.testing.expect(namesCode("x.alpha_beta", "alpha_beta"));
    try std.testing.expect(!namesCode("    _ = .alpha_beta_two,", "alpha_beta"));
    try std.testing.expect(!namesCode("    _ = alpha_beta,", "alpha_beta"));
}

test "the last import on a line is the one that is read" {
    try std.testing.expectEqualStrings("zts", lastImportTarget("const a = @import(\"std\"); const b = @import(\"zts\");").?);
    try std.testing.expectEqualStrings("std", lastImportTarget("const b = @import(\"zts\"); const a = @import(\"std\");").?);
    try std.testing.expect(lastImportTarget("const b = @import(name);") == null);
}
