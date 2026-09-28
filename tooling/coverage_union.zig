//! The union of tripped rules across every published coverage run for one
//! corpus identity.
//!
//! A single coverage row is a sample, not a property of the corpus. Three
//! recordings of corpus `0012ad8ca6d5` measured 4, 5 and 2 rules. A rule is
//! counted only when the recorded model output makes the mistake that trips it.
//! Any one of those rows understates what these prompts can reach. The union
//! does not.
//!
//! The record is `git log docs/coverage.json`, which the coverage page already
//! names as its history. This reads exactly that, keeps the entries whose
//! `corpusVersion` matches the identity asked for, and unions their `tripped`
//! arrays. Codes given on the command line form the pending set. Its source tree
//! hash identifies the committed packages tree that contains the cassettes,
//! corpus, and compiler. A source tree not yet in history joins every aggregate.
//!
//! Ported from `scripts/coverage-union.sh`, which computed this in a python3
//! heredoc. The port is not cosmetic: the shell version refused outright when
//! no published run carried the identity asked for, which made the first
//! publication of any new corpus impossible.
//!
//! That guard was probed, and the probe passed: its commit names three floors
//! and records that "All three were probed and refuse". A probe shows the
//! branch executes and that
//! it rejects what it names. It cannot show that what it rejects is illegitimate,
//! and here it was: a new identity is what editing a prompt produces, and it
//! arrives with no published run by definition. The guard was written when
//! every identity in the tree already had rows, so the one input that would
//! have exposed it did not exist yet to be tried.
//!
//! Usage:
//!   coverage-union <corpus-version> <source-tree-hash> [code ...]
//!
//! Prints one `[coverage-union] {json}` line on stdout.

const std = @import("std");

pub const marker = "[coverage-union] ";

/// One measured tripped set, sorted and deduplicated so two runs that named the
/// same rules in a different order count as one shape rather than two.
const CodeSet = struct {
    codes: []const []const u8,

    fn order(a: CodeSet, b: CodeSet) std.math.Order {
        const shared = @min(a.codes.len, b.codes.len);
        var index: usize = 0;
        while (index < shared) : (index += 1) {
            switch (std.mem.order(u8, a.codes[index], b.codes[index])) {
                .eq => continue,
                else => |non_eq| return non_eq,
            }
        }
        return std.math.order(a.codes.len, b.codes.len);
    }

    fn eql(a: CodeSet, b: CodeSet) bool {
        return a.order(b) == .eq;
    }
};

const RecordedSet = struct {
    set: CodeSet,
    source_tree_hash: ?[]const u8,
};

pub const Union = struct {
    corpus_version: []const u8,
    source_tree_hash: []const u8,
    /// How many published runs and new pending source trees of this identity the
    /// union was computed from. The first publication counts the pending run.
    observations: usize,
    distinct_sets: usize,
    smallest_set: usize,
    largest_set: usize,
    codes: []const []const u8,

    pub fn deinit(self: *Union, allocator: std.mem.Allocator) void {
        for (self.codes) |code| allocator.free(code);
        allocator.free(self.codes);
        allocator.free(self.corpus_version);
        allocator.free(self.source_tree_hash);
        self.* = undefined;
    }
};

pub const Failure = error{
    UsageMissingVersion,
    VersionNotHex,
    SourceTreeHashNotHex,
    ShallowClone,
    NoCoverageHistory,
    NoParsedBlob,
    NoTrippedList,
    FirstRunWithoutCodes,
    FirstRunWithUnreadableHistory,
    SourceTreeSetConflict,
};

/// The message each refusal prints. Kept beside the error set so a new member
/// cannot be added without a reader-facing reason, and so the census test below
/// can require every one of them to be exercised.
pub fn failureMessage(failure: Failure) []const u8 {
    return switch (failure) {
        error.UsageMissingVersion => "usage: coverage-union <corpus-version> <source-tree-hash> [code ...]",
        error.VersionNotHex => "corpus version must be 64 lowercase hex characters",
        error.SourceTreeHashNotHex => "source tree hash must be 40 or 64 lowercase hex characters",
        error.ShallowClone => "shallow clone: the history this union is computed from is truncated",
        error.NoCoverageHistory => "no commit in this history touches docs/coverage.json; there is nothing to union",
        error.NoParsedBlob => "no coverage.json blob in history parsed",
        error.NoTrippedList => "no entry for this corpus carries a tripped list",
        error.FirstRunWithoutCodes => "this identity has no published run and no pending codes were given; that would publish an empty set as an observation",
        error.FirstRunWithUnreadableHistory => "no readable published run carries this identity, but some coverage.json blob in history could not be read; it may have been one, so this cannot be reported as a first publication",
        error.SourceTreeSetConflict => "the pending tripped set differs from the published set for the same source tree hash",
    };
}

const GitResult = struct {
    ok: bool,
    stdout: []u8,
    stderr: []u8,

    fn deinit(self: *GitResult, allocator: std.mem.Allocator) void {
        allocator.free(self.stdout);
        allocator.free(self.stderr);
        self.* = undefined;
    }
};

fn runGit(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: []const u8,
    argv: []const []const u8,
) !GitResult {
    const result = try std.process.run(allocator, io, .{
        .argv = argv,
        .cwd = .{ .path = root },
        .stdout_limit = .limited(8 * 1024 * 1024),
        .stderr_limit = .limited(256 * 1024),
    });
    return .{
        .ok = switch (result.term) {
            .exited => |code| code == 0,
            else => false,
        },
        .stdout = result.stdout,
        .stderr = result.stderr,
    };
}

pub fn isCorpusVersion(value: []const u8) bool {
    if (value.len != 64) return false;
    for (value) |byte| {
        if (!std.ascii.isDigit(byte) and !(byte >= 'a' and byte <= 'f')) return false;
    }
    return true;
}

fn isSourceTreeHash(value: []const u8) bool {
    if (value.len != 40 and value.len != 64) return false;
    for (value) |byte| {
        if (!std.ascii.isDigit(byte) and !(byte >= 'a' and byte <= 'f')) return false;
    }
    return true;
}

fn lessThanString(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

/// Sort and deduplicate, taking ownership of nothing: the returned slice
/// borrows the input strings and only the outer array is allocated.
fn sortedUnique(
    allocator: std.mem.Allocator,
    values: []const []const u8,
) ![]const []const u8 {
    const copy = try allocator.alloc([]const u8, values.len);
    errdefer allocator.free(copy);
    @memcpy(copy, values);
    std.mem.sort([]const u8, copy, {}, lessThanString);

    var kept: usize = 0;
    for (copy) |value| {
        if (kept != 0 and std.mem.eql(u8, copy[kept - 1], value)) continue;
        copy[kept] = value;
        kept += 1;
    }
    return try allocator.realloc(copy, kept);
}

/// Every `tripped` array published for `version`, oldest last, as `git log`
/// orders them. A blob that does not parse is skipped rather than fatal: the
/// page predates its own schema in early history, and refusing there would make
/// this unusable for the identity it is actually about.
///
/// `unreadable` counts those skips, and the caller needs it. A skipped blob has
/// no readable `corpusVersion`, so it could have carried the identity being
/// asked about. An empty result therefore means one of two different things -
/// no run of this identity was ever published, or one was and could not be read
/// - and only the first of them may be reported as a first publication.
fn publishedSets(
    arena: std.mem.Allocator,
    io: std.Io,
    root: []const u8,
    version: []const u8,
    parsed_any: *bool,
    unreadable: *usize,
) !std.ArrayList(RecordedSet) {
    const log = try runGit(arena, io, root, &.{ "git", "log", "--format=%H", "--", "docs/coverage.json" });
    if (!log.ok or std.mem.trim(u8, log.stdout, " \t\r\n").len == 0) return error.NoCoverageHistory;

    var sets: std.ArrayList(RecordedSet) = .empty;
    var commits = std.mem.tokenizeAny(u8, log.stdout, " \t\r\n");
    while (commits.next()) |commit| {
        const spec = try std.fmt.allocPrint(arena, "{s}:docs/coverage.json", .{commit});
        const blob = try runGit(arena, io, root, &.{ "git", "show", spec });
        if (!blob.ok) {
            unreadable.* += 1;
            continue;
        }

        const parsed = std.json.parseFromSliceLeaky(
            std.json.Value,
            arena,
            blob.stdout,
            .{},
        ) catch {
            unreadable.* += 1;
            continue;
        };
        if (parsed != .object) {
            unreadable.* += 1;
            continue;
        }
        parsed_any.* = true;

        const published = parsed.object.get("corpusVersion") orelse continue;
        if (published != .string or !std.mem.eql(u8, published.string, version)) continue;

        const tripped = parsed.object.get("tripped") orelse continue;
        if (tripped != .array) continue;

        var codes: std.ArrayList([]const u8) = .empty;
        for (tripped.array.items) |item| {
            if (item != .string) continue;
            try codes.append(arena, item.string);
        }
        var source_tree_hash: ?[]const u8 = null;
        if (parsed.object.get("corpusUnion")) |union_value| {
            if (union_value == .object) {
                if (union_value.object.get("sourceTreeHash")) |hash_value| {
                    if (hash_value == .string) source_tree_hash = hash_value.string;
                }
            }
        }
        try sets.append(arena, .{
            .set = .{ .codes = try sortedUnique(arena, codes.items) },
            .source_tree_hash = source_tree_hash,
        });
    }
    return sets;
}

/// Compute the union for one identity.
///
/// `pending` is the run about to be published. Its `source_tree_hash` names the
/// committed packages tree that produced it. A pending tree absent from history
/// joins the observations and all set statistics. A matching tree contributes
/// nothing new. Historical rows without this identity remain observations and
/// cannot suppress the pending run.
pub fn compute(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: []const u8,
    version: []const u8,
    source_tree_hash: []const u8,
    pending: []const []const u8,
) !Union {
    if (!isCorpusVersion(version)) return error.VersionNotHex;
    if (!isSourceTreeHash(source_tree_hash)) return error.SourceTreeHashNotHex;

    var shallow = try runGit(allocator, io, root, &.{ "git", "rev-parse", "--is-shallow-repository" });
    defer shallow.deinit(allocator);
    // A shallow clone holds a truncated history, so the union it computes is a
    // smaller set than the one the repository actually recorded - and it would
    // be published as though it were complete. Refuse rather than understate.
    // An unreadable answer is treated as shallow for the same reason.
    if (!shallow.ok or !std.mem.eql(u8, std.mem.trim(u8, shallow.stdout, " \t\r\n"), "false")) {
        return error.ShallowClone;
    }

    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();
    const arena = scratch.allocator();

    var parsed_any = false;
    var unreadable: usize = 0;
    const published = try publishedSets(arena, io, root, version, &parsed_any, &unreadable);
    if (!parsed_any) return error.NoParsedBlob;

    const pending_set = try sortedUnique(arena, pending);

    var sets: std.ArrayList(CodeSet) = .empty;
    for (published.items) |recorded| try sets.append(arena, recorded.set);
    if (published.items.len == 0) {
        if (pending_set.len == 0) return error.FirstRunWithoutCodes;
        // The first-publication path claims that nothing of this identity was
        // ever published. A blob that could not be read carries no readable
        // identity, so it may have been exactly that run, and the claim would
        // be false. Relaxing the shell version's refusal here must not turn it
        // into a silent wrong count: where history is unreadable the honest
        // answer is a refusal that says which commit to look at.
        if (unreadable != 0) return error.FirstRunWithUnreadableHistory;
        try sets.append(arena, .{ .codes = pending_set });
    } else if (pending_set.len != 0) {
        const pending_code_set = CodeSet{ .codes = pending_set };
        var already_published = false;
        for (published.items) |recorded| {
            if (recorded.source_tree_hash) |published_hash| {
                if (!std.mem.eql(u8, published_hash, source_tree_hash)) continue;
                if (!recorded.set.eql(pending_code_set)) return error.SourceTreeSetConflict;
                already_published = true;
            }
        }
        if (!already_published) try sets.append(arena, pending_code_set);
    }
    if (sets.items.len == 0) return error.NoTrippedList;

    var seen: std.StringArrayHashMapUnmanaged(void) = .empty;

    var distinct: std.ArrayList(CodeSet) = .empty;
    var smallest: usize = std.math.maxInt(usize);
    var largest: usize = 0;
    for (sets.items) |set| {
        for (set.codes) |code| try seen.put(arena, code, {});
        smallest = @min(smallest, set.codes.len);
        largest = @max(largest, set.codes.len);

        var already = false;
        for (distinct.items) |kept| {
            if (kept.eql(set)) {
                already = true;
                break;
            }
        }
        if (!already) try distinct.append(arena, set);
    }

    const union_codes = try sortedUnique(arena, seen.keys());
    const owned = try allocator.alloc([]const u8, union_codes.len);
    errdefer allocator.free(owned);
    var filled: usize = 0;
    errdefer for (owned[0..filled]) |code| allocator.free(code);
    for (union_codes) |code| {
        owned[filled] = try allocator.dupe(u8, code);
        filled += 1;
    }

    return .{
        .corpus_version = try allocator.dupe(u8, version),
        .source_tree_hash = try allocator.dupe(u8, source_tree_hash),
        .observations = sets.items.len,
        .distinct_sets = distinct.items.len,
        .smallest_set = smallest,
        .largest_set = largest,
        .codes = owned,
    };
}

pub fn writeJson(result: Union, writer: *std.Io.Writer) !void {
    try writer.print(
        "{{\"corpusVersion\": \"{s}\", \"sourceTreeHash\": \"{s}\", \"observations\": {d}, \"distinctSets\": {d}, " ++
            "\"smallestSet\": {d}, \"largestSet\": {d}, \"unionCount\": {d}, \"union\": [",
        .{
            result.corpus_version,
            result.source_tree_hash,
            result.observations,
            result.distinct_sets,
            result.smallest_set,
            result.largest_set,
            result.codes.len,
        },
    );
    for (result.codes, 0..) |code, index| {
        if (index != 0) try writer.writeAll(", ");
        try writer.print("\"{s}\"", .{code});
    }
    try writer.writeAll("]}");
}

fn collectArgs(allocator: std.mem.Allocator, args_vector: std.process.Args) ![]const []const u8 {
    var args_iter = std.process.Args.Iterator.init(args_vector);
    defer args_iter.deinit();

    var list: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (list.items) |arg| allocator.free(arg);
        list.deinit(allocator);
    }
    while (args_iter.next()) |arg| {
        try list.append(allocator, try allocator.dupe(u8, arg));
    }
    return list.toOwnedSlice(allocator);
}

pub fn main(init: std.process.Init.Minimal) !void {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer _ = debug_allocator.deinit();
    const allocator = debug_allocator.allocator();
    var io_backend = std.Io.Threaded.init(allocator, .{ .environ = .empty });
    defer io_backend.deinit();
    const io = io_backend.io();

    const args = try collectArgs(allocator, init.args);
    defer {
        for (args) |arg| allocator.free(arg);
        allocator.free(args);
    }

    var stderr_buffer: [4096]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(io, &stderr_buffer);

    const fail = struct {
        fn print(w: *std.Io.Writer, failure: Failure) noreturn {
            w.print("coverage union: {s}\n", .{failureMessage(failure)}) catch {};
            w.flush() catch {};
            std.process.exit(1);
        }
    }.print;

    if (args.len < 3) fail(&stderr_writer.interface, error.UsageMissingVersion);

    var result = compute(allocator, io, ".", args[1], args[2], args[3..]) catch |err| switch (err) {
        error.VersionNotHex,
        error.SourceTreeHashNotHex,
        error.ShallowClone,
        error.NoCoverageHistory,
        error.NoParsedBlob,
        error.NoTrippedList,
        error.FirstRunWithoutCodes,
        error.SourceTreeSetConflict,
        => |failure| fail(&stderr_writer.interface, failure),
        else => return err,
    };
    defer result.deinit(allocator);

    var stdout_buffer: [64 * 1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);
    try stdout_writer.interface.writeAll(marker);
    try writeJson(result, &stdout_writer.interface);
    try stdout_writer.interface.writeByte('\n');
    try stdout_writer.interface.flush();
}

// ---------------------------------------------------------------------------
// Tests
//
// Each one builds a throwaway git repository and commits real coverage.json
// blobs, so the thing under test is the same `git log`/`git show` path the gate
// runs rather than a fixture standing in for it.
// ---------------------------------------------------------------------------

const testing = std.testing;

const version_a = "e6801afae0990b304b924bcb27e5d435cf75ed922f6064241cb401a1d6845576";
const version_b = "0012ad8ca6d5d08ac5023862378fe0c971b3672dadbc079256fb47d810033516";
const source_tree_a = "1111111111111111111111111111111111111111";
const source_tree_b = "2222222222222222222222222222222222222222";

/// A throwaway repository with a real `docs/coverage.json` history, so the
/// thing under test is the same `git log`/`git show` path the gate runs rather
/// than a fixture standing in for it.
const Fixture = struct {
    tmp: testing.TmpDir,
    root: [:0]u8,

    fn init(io: std.Io) !Fixture {
        var tmp = testing.tmpDir(.{});
        errdefer tmp.cleanup();
        try tmp.dir.createDirPath(io, "docs");
        const root = try tmp.dir.realPathFileAlloc(io, ".", testing.allocator);
        errdefer testing.allocator.free(root);
        var init_git = try runGit(testing.allocator, io, root, &.{ "git", "init", "-q" });
        defer init_git.deinit(testing.allocator);
        if (!init_git.ok) return error.GitInitFailed;
        return .{ .tmp = tmp, .root = root };
    }

    fn deinit(self: *Fixture) void {
        testing.allocator.free(self.root);
        self.tmp.cleanup();
    }

    /// Commit one `docs/coverage.json` carrying `version` and `codes`. A null
    /// `version` writes bytes that are not JSON at all, for the skip path.
    fn publish(
        self: *Fixture,
        io: std.Io,
        version: ?[]const u8,
        codes: []const []const u8,
        source_tree_hash: ?[]const u8,
    ) !void {
        var body: std.ArrayList(u8) = .empty;
        defer body.deinit(testing.allocator);
        if (version) |value| {
            try body.appendSlice(testing.allocator, "{\"corpusVersion\": \"");
            try body.appendSlice(testing.allocator, value);
            try body.appendSlice(testing.allocator, "\", \"tripped\": [");
            for (codes, 0..) |code, index| {
                if (index != 0) try body.appendSlice(testing.allocator, ", ");
                try body.append(testing.allocator, '"');
                try body.appendSlice(testing.allocator, code);
                try body.append(testing.allocator, '"');
            }
            try body.append(testing.allocator, ']');
            if (source_tree_hash) |hash| {
                try body.appendSlice(testing.allocator, ", \"corpusUnion\": {\"sourceTreeHash\": \"");
                try body.appendSlice(testing.allocator, hash);
                try body.appendSlice(testing.allocator, "\"}");
            }
            try body.appendSlice(testing.allocator, "}\n");
        } else {
            try body.appendSlice(testing.allocator, "this is not json\n");
        }
        try self.tmp.dir.writeFile(io, .{ .sub_path = "docs/coverage.json", .data = body.items });

        var add = try runGit(testing.allocator, io, self.root, &.{ "git", "add", "docs/coverage.json" });
        defer add.deinit(testing.allocator);
        if (!add.ok) return error.GitAddFailed;
        var commit = try runGit(testing.allocator, io, self.root, &.{
            "git",                  "-c",                              "user.name=zttp test",
            "-c",                   "user.email=test@example.invalid", "-c",
            "commit.gpgsign=false", "commit",                          "-qm",
            "coverage",
        });
        defer commit.deinit(testing.allocator);
        if (!commit.ok) return error.GitCommitFailed;
    }
};

fn testIo() std.Io.Threaded {
    return std.Io.Threaded.init(testing.allocator, .{ .environ = .empty });
}

test "a first pending run contributes every aggregate statistic" {
    var backend = testIo();
    defer backend.deinit();
    const io = backend.io();

    var fixture = try Fixture.init(io);
    defer fixture.deinit();
    // History exists but carries a different identity - exactly the state a
    // prompt edit leaves behind, and the one the shell version refused.
    try fixture.publish(io, version_b, &.{ "ZTS400", "ZTS500" }, null);

    var result = try compute(
        testing.allocator,
        io,
        fixture.root,
        version_a,
        source_tree_a,
        &.{ "ZTS500", "ZTS400", "ZTS501" },
    );
    defer result.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), result.observations);
    try testing.expectEqual(@as(usize, 1), result.distinct_sets);
    try testing.expectEqual(@as(usize, 3), result.smallest_set);
    try testing.expectEqual(@as(usize, 3), result.largest_set);
    try testing.expectEqual(@as(usize, 3), result.codes.len);
    try testing.expectEqualStrings("ZTS400", result.codes[0]);
    try testing.expectEqualStrings("ZTS501", result.codes[2]);
}

test "a new pending set contributes every aggregate statistic" {
    var backend = testIo();
    defer backend.deinit();
    const io = backend.io();

    var fixture = try Fixture.init(io);
    defer fixture.deinit();
    try fixture.publish(io, version_a, &.{ "ZTS400", "ZTS500", "ZTS509" }, null);
    try fixture.publish(io, version_a, &.{ "ZTS400", "ZTS500" }, null);

    var result = try compute(testing.allocator, io, fixture.root, version_a, source_tree_a, &.{"ZTS502"});
    defer result.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 3), result.observations);
    try testing.expectEqual(@as(usize, 3), result.distinct_sets);
    try testing.expectEqual(@as(usize, 1), result.smallest_set);
    try testing.expectEqual(@as(usize, 3), result.largest_set);
    try testing.expectEqual(@as(usize, 4), result.codes.len);
    try testing.expectEqualStrings("ZTS502", result.codes[2]);
}

test "a pending set larger than history becomes the largest observation" {
    var backend = testIo();
    defer backend.deinit();
    const io = backend.io();

    var fixture = try Fixture.init(io);
    defer fixture.deinit();
    try fixture.publish(io, version_a, &.{ "ZTS400", "ZTS500", "ZTS501", "ZTS509" }, null);

    var result = try compute(
        testing.allocator,
        io,
        fixture.root,
        version_a,
        source_tree_a,
        &.{ "ZTS308", "ZTS400", "ZTS500", "ZTS501", "ZTS509", "ZTS604" },
    );
    defer result.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 2), result.observations);
    try testing.expectEqual(@as(usize, 2), result.distinct_sets);
    try testing.expectEqual(@as(usize, 4), result.smallest_set);
    try testing.expectEqual(@as(usize, 6), result.largest_set);
    try testing.expectEqual(@as(usize, 6), result.codes.len);
}

test "a pending source tree already in history is not counted twice" {
    var backend = testIo();
    defer backend.deinit();
    const io = backend.io();

    var fixture = try Fixture.init(io);
    defer fixture.deinit();
    try fixture.publish(io, version_a, &.{ "ZTS500", "ZTS400" }, source_tree_a);

    var result = try compute(
        testing.allocator,
        io,
        fixture.root,
        version_a,
        source_tree_a,
        &.{ "ZTS500", "ZTS400" },
    );
    defer result.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), result.observations);
    try testing.expectEqual(@as(usize, 1), result.distinct_sets);
    try testing.expectEqual(@as(usize, 2), result.smallest_set);
    try testing.expectEqual(@as(usize, 2), result.largest_set);
}

test "a pending source tree refuses a conflicting tripped set" {
    var backend = testIo();
    defer backend.deinit();
    const io = backend.io();

    var fixture = try Fixture.init(io);
    defer fixture.deinit();
    try fixture.publish(io, version_a, &.{ "ZTS400", "ZTS500" }, source_tree_a);

    try testing.expectError(
        error.SourceTreeSetConflict,
        compute(
            testing.allocator,
            io,
            fixture.root,
            version_a,
            source_tree_a,
            &.{ "ZTS400", "ZTS500", "ZTS509" },
        ),
    );
}

test "a distinct source tree counts even when its set matches history" {
    var backend = testIo();
    defer backend.deinit();
    const io = backend.io();

    var fixture = try Fixture.init(io);
    defer fixture.deinit();
    try fixture.publish(io, version_a, &.{ "ZTS500", "ZTS400" }, source_tree_a);

    var result = try compute(
        testing.allocator,
        io,
        fixture.root,
        version_a,
        source_tree_b,
        &.{ "ZTS400", "ZTS500" },
    );
    defer result.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 2), result.observations);
    try testing.expectEqual(@as(usize, 1), result.distinct_sets);
    try testing.expectEqual(@as(usize, 2), result.smallest_set);
    try testing.expectEqual(@as(usize, 2), result.largest_set);
}

test "an unparseable blob is skipped rather than fatal" {
    var backend = testIo();
    defer backend.deinit();
    const io = backend.io();

    var fixture = try Fixture.init(io);
    defer fixture.deinit();
    try fixture.publish(io, null, &.{}, null);
    try fixture.publish(io, version_a, &.{"ZTS400"}, null);

    var result = try compute(testing.allocator, io, fixture.root, version_a, source_tree_a, &.{});
    defer result.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), result.observations);
    try testing.expectEqual(@as(usize, 1), result.codes.len);
}

test "every refusal carries a message and each reachable one is probed" {
    var backend = testIo();
    defer backend.deinit();
    const io = backend.io();

    // A census rather than a sample: iterating the error set means a refusal
    // added later cannot ship without a message. The tests in this file probe
    // every member the library path can reach.
    inline for (@typeInfo(Failure).error_set.?) |member| {
        try testing.expect(failureMessage(@field(Failure, member.name)).len != 0);
    }

    var fixture = try Fixture.init(io);
    defer fixture.deinit();

    // VersionNotHex, refused before any git call runs.
    try testing.expectError(
        error.VersionNotHex,
        compute(testing.allocator, io, fixture.root, "not-a-version", source_tree_a, &.{}),
    );

    try testing.expectError(
        error.SourceTreeHashNotHex,
        compute(testing.allocator, io, fixture.root, version_a, "not-a-tree", &.{}),
    );

    // NoCoverageHistory: a repository whose history never touches the page.
    try testing.expectError(
        error.NoCoverageHistory,
        compute(testing.allocator, io, fixture.root, version_a, source_tree_a, &.{"ZTS400"}),
    );

    // NoParsedBlob: the only history is bytes that are not JSON at all.
    try fixture.publish(io, null, &.{}, null);
    try testing.expectError(
        error.NoParsedBlob,
        compute(testing.allocator, io, fixture.root, version_a, source_tree_a, &.{"ZTS400"}),
    );

    // FirstRunWithoutCodes: history exists under another identity and the
    // pending run named nothing, so counting it would publish an empty set.
    try fixture.publish(io, version_b, &.{"ZTS400"}, null);
    try testing.expectError(
        error.FirstRunWithoutCodes,
        compute(testing.allocator, io, fixture.root, version_a, source_tree_a, &.{}),
    );

    // FirstRunWithUnreadableHistory: the unparseable blob published earlier in
    // this fixture carries no readable identity, so it may have been a run of
    // the identity being asked about. Reporting a first publication here would
    // be a claim the history cannot support.
    try testing.expectError(
        error.FirstRunWithUnreadableHistory,
        compute(testing.allocator, io, fixture.root, version_a, source_tree_a, &.{"ZTS400"}),
    );

    // UsageMissingVersion and ShallowClone are reached from `main` and from a
    // shallow checkout respectively, neither of which this library entry point
    // can construct; their messages are covered by the census above.
}

test "the rendered json carries every field the coverage publisher reads" {
    var backend = testIo();
    defer backend.deinit();
    const io = backend.io();

    var fixture = try Fixture.init(io);
    defer fixture.deinit();
    try fixture.publish(io, version_a, &.{ "ZTS400", "ZTS500" }, null);

    var result = try compute(testing.allocator, io, fixture.root, version_a, source_tree_a, &.{});
    defer result.deinit(testing.allocator);

    var buffer: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try writeJson(result, &writer);
    const text = writer.buffered();

    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, text, .{});
    defer parsed.deinit();
    const object = parsed.value.object;
    // The publisher reads exactly these; a rename here is a silent break there.
    inline for (.{
        "corpusVersion",
        "sourceTreeHash",
        "observations",
        "distinctSets",
        "smallestSet",
        "largestSet",
        "unionCount",
        "union",
    }) |field| {
        try testing.expect(object.get(field) != null);
    }
    try testing.expectEqualStrings(version_a, object.get("corpusVersion").?.string);
    try testing.expectEqualStrings(source_tree_a, object.get("sourceTreeHash").?.string);
    try testing.expectEqual(@as(i64, 2), object.get("unionCount").?.integer);
}
