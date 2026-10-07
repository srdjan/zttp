//! Golden diagnostic corpus gate (Tier 1, R2).
//!
//! Every case under `tests/corpus/{parse,check}/{good,bad}/NAME.ts` (or
//! `.tsx`) is run through the same in-process check that `zts check --json`
//! uses, and its result is compared byte for byte against `NAME.diag`.
//!
//! A golden records two things. The first line lists the analysis stages that
//! ran, so a `good` case cannot pass because a stage was skipped. The lines
//! after it are the diagnostics, one per line, exactly as
//! `json_diagnostics.writeDiagnosticJson` emits them. `tests/corpus/README.md`
//! documents the format.
//!
//! What this gate refuses, each as a named `FailureKind`:
//!   * a source with no golden, a golden with no source, a golden that differs;
//!   * a `good` case with any diagnostic, or one that skipped a stage;
//!   * a `bad` case with no diagnostic;
//!   * a case filed under the wrong family (`parse` stops at or before the
//!     import check, `check` runs past it);
//!   * a file outside the layout, or two sources with one name;
//!   * a corpus below the committed floor, or a family with no case;
//!   * a filter that matches no case.
//!
//! The floor, the stage requirement, and the filter rule exist because a gate
//! that finds nothing reports the same success as a gate that found
//! everything. The unit tests at the bottom probe every `FailureKind` through
//! a scratch corpus, and a census test requires that every member is probed.
//!
//! The check runs with `persist_witnesses = false`, so a gate run writes no
//! `.zttp/witnesses` into the working tree. It reads neither `zttp.json` nor
//! `.zttp/witnesses`: `runCheckOnlyFromSourceWithOptions` takes its policy,
//! declaration and schema from its options, and the gate passes none.

const std = @import("std");
const precompile = @import("precompile.zig");
const zts = @import("zts");

/// The number of cases committed under `tests/corpus`. The gate fails below
/// it, so deleting a case fails. Raise it in the commit that adds cases, to
/// the count the gate prints. Never lower it to make a deletion pass.
pub const minimum_cases: usize = 4;

const corpus_root = "tests/corpus";
const max_file_bytes = 1024 * 1024;

pub const Family = enum { parse, check };
pub const Kind = enum { good, bad };

/// The stages a `good` case must run. `policy` runs only when the caller
/// supplies a policy, and the gate supplies none.
const good_stages: precompile.StageSet = blk: {
    var set = precompile.StageSet.initFull();
    set.remove(.policy);
    break :blk set;
};

pub const FailureKind = enum {
    layout,
    unexpected_file,
    duplicate_name,
    below_floor,
    empty_family,
    filter_matched_nothing,
    unreadable_source,
    check_crashed,
    missing_golden,
    orphan_golden,
    golden_mismatch,
    good_has_diagnostics,
    bad_has_no_diagnostics,
    good_skipped_stage,
    misfiled,
};

pub const Failure = struct {
    kind: FailureKind,
    path: []const u8,
    detail: []const u8,
};

pub const CheckFn = *const fn (gpa: std.mem.Allocator, source: []const u8, handler_path: []const u8) anyerror!precompile.CheckResult;

/// The same call `zts check --json` makes, with witness persistence off and no
/// policy, declaration, schema or system path: nothing is read from
/// `zttp.json`, and nothing is written under `.zttp/`.
fn defaultCheck(gpa: std.mem.Allocator, source: []const u8, handler_path: []const u8) anyerror!precompile.CheckResult {
    return precompile.runCheckOnlyFromSourceWithOptions(gpa, source, handler_path, .{
        .json_mode = true,
        .persist_witnesses = false,
    });
}

pub const Options = struct {
    /// The check to run. Tests replace it to reach a crash the real check
    /// does not produce on demand.
    check: CheckFn = defaultCheck,
    /// Rewrite the golden of every selected case instead of comparing.
    write: bool = false,
    /// Run only cases whose source path contains this text.
    filter: ?[]const u8 = null,
    /// The case count below which the corpus is refused.
    floor: usize,
};

const Case = struct {
    family: Family,
    kind: Kind,
    name: []const u8,
    /// Path of the source relative to the corpus root, e.g. `check/bad/x.ts`.
    source_path: []const u8,
    /// Path of the golden relative to the corpus root.
    golden_path: []const u8,
};

pub const Report = struct {
    arena: std.heap.ArenaAllocator,
    failures: std.ArrayList(Failure) = .empty,
    cases_found: usize = 0,
    cases_run: usize = 0,

    pub fn init(gpa: std.mem.Allocator) Report {
        return .{ .arena = std.heap.ArenaAllocator.init(gpa) };
    }

    pub fn deinit(self: *Report) void {
        self.arena.deinit();
    }

    pub fn has(self: *const Report, kind: FailureKind) bool {
        for (self.failures.items) |failure| {
            if (failure.kind == kind) return true;
        }
        return false;
    }

    fn add(self: *Report, kind: FailureKind, path: []const u8, comptime fmt: []const u8, args: anytype) !void {
        const a = self.arena.allocator();
        try self.failures.append(a, .{
            .kind = kind,
            .path = try a.dupe(u8, path),
            .detail = try std.fmt.allocPrint(a, fmt, args),
        });
    }
};

fn splitName(file_name: []const u8) ?struct { stem: []const u8, ext: []const u8 } {
    const dot = std.mem.findScalarLast(u8, file_name, '.') orelse return null;
    if (dot == 0) return null;
    return .{ .stem = file_name[0..dot], .ext = file_name[dot..] };
}

const Golden = struct { family: Family, kind: Kind, name: []const u8, path: []const u8 };

/// Walk the corpus root, classify every file, and report layout failures.
/// Returns the cases (sorted by source path) and the goldens found.
fn discover(
    gpa: std.mem.Allocator,
    io: std.Io,
    root: std.Io.Dir,
    report: *Report,
    cases: *std.ArrayList(Case),
    goldens: *std.ArrayList(Golden),
) !void {
    const a = report.arena.allocator();
    var walker = try root.walk(gpa);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        const path = entry.path;
        var parts: [3][]const u8 = undefined;
        var count: usize = 0;
        var overflow = false;
        var it = std.mem.splitScalar(u8, path, '/');
        while (it.next()) |part| {
            if (count == parts.len) {
                overflow = true;
                break;
            }
            parts[count] = part;
            count += 1;
        }
        if (count == 1 and std.mem.eql(u8, path, "README.md")) continue;
        const split = splitName(entry.basename);
        const is_source = if (split) |s| std.mem.eql(u8, s.ext, ".ts") or std.mem.eql(u8, s.ext, ".tsx") else false;
        const is_golden = if (split) |s| std.mem.eql(u8, s.ext, ".diag") else false;
        if (!is_source and !is_golden) {
            try report.add(.unexpected_file, path, "only NAME.ts, NAME.tsx, NAME.diag and a root README.md belong in the corpus", .{});
            continue;
        }
        const family = if (!overflow and count == 3) std.meta.stringToEnum(Family, parts[0]) else null;
        const kind = if (!overflow and count == 3) std.meta.stringToEnum(Kind, parts[1]) else null;
        if (family == null or kind == null) {
            try report.add(.layout, path, "a case lives at {{parse,check}}/{{good,bad}}/NAME.ts", .{});
            continue;
        }
        const name = try a.dupe(u8, split.?.stem);
        const owned_path = try a.dupe(u8, path);
        if (is_golden) {
            try goldens.append(a, .{ .family = family.?, .kind = kind.?, .name = name, .path = owned_path });
        } else {
            const golden_path = try std.fmt.allocPrint(a, "{s}/{s}/{s}.diag", .{ parts[0], parts[1], name });
            try cases.append(a, .{
                .family = family.?,
                .kind = kind.?,
                .name = name,
                .source_path = owned_path,
                .golden_path = golden_path,
            });
        }
    }
    std.mem.sort(Case, cases.items, {}, struct {
        fn lessThan(_: void, lhs: Case, rhs: Case) bool {
            return std.mem.lessThan(u8, lhs.source_path, rhs.source_path);
        }
    }.lessThan);
}

fn sameName(a: Case, b: Case) bool {
    return a.family == b.family and a.kind == b.kind and std.mem.eql(u8, a.name, b.name);
}

fn renderGolden(
    allocator: std.mem.Allocator,
    stages: precompile.StageSet,
    diagnostics: []const precompile.json_diag.JsonDiagnostic,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const w = &out.writer;
    try w.writeAll("stages: ");
    var first = true;
    var it = stages.iterator();
    while (it.next()) |stage| {
        if (!first) try w.writeByte(',');
        first = false;
        try w.writeAll(@tagName(stage));
    }
    try w.writeByte('\n');
    for (diagnostics) |*diag| {
        try precompile.json_diag.writeDiagnosticJson(w, diag);
        try w.writeByte('\n');
    }
    return out.toOwnedSlice();
}

fn firstDifference(arena: std.mem.Allocator, expected: []const u8, actual: []const u8) ![]u8 {
    var exp_lines = std.mem.splitScalar(u8, expected, '\n');
    var act_lines = std.mem.splitScalar(u8, actual, '\n');
    var line: usize = 1;
    while (true) : (line += 1) {
        const e = exp_lines.next();
        const g = act_lines.next();
        if (e == null and g == null) break;
        if (e != null and g != null and std.mem.eql(u8, e.?, g.?)) continue;
        return std.fmt.allocPrint(
            arena,
            "first difference at line {d}\n  golden: {s}\n  actual: {s}\n--- golden ---\n{s}--- actual ---\n{s}",
            .{ line, e orelse "(end of file)", g orelse "(end of file)", expected, actual },
        );
    }
    return std.fmt.allocPrint(arena, "texts differ\n--- golden ---\n{s}--- actual ---\n{s}", .{ expected, actual });
}

fn latestStageIndex(stages: precompile.StageSet) ?usize {
    var latest: ?usize = null;
    var it = stages.iterator();
    while (it.next()) |stage| latest = @intFromEnum(stage);
    return latest;
}

fn runCase(
    gpa: std.mem.Allocator,
    io: std.Io,
    root: std.Io.Dir,
    case: Case,
    options: Options,
    report: *Report,
) !void {
    const a = report.arena.allocator();
    const source = root.readFileAlloc(io, case.source_path, gpa, .limited(max_file_bytes)) catch |err| {
        try report.add(.unreadable_source, case.source_path, "cannot read the source: {s}", .{@errorName(err)});
        return;
    };
    defer gpa.free(source);

    var result = options.check(gpa, source, case.source_path) catch |err| {
        try report.add(.check_crashed, case.source_path, "the check returned error.{s}", .{@errorName(err)});
        return;
    };
    defer result.deinit(gpa);
    report.cases_run += 1;

    const diagnostics = result.json_diagnostics.items;
    switch (case.kind) {
        .good => {
            if (diagnostics.len != 0) {
                try report.add(.good_has_diagnostics, case.source_path, "a good case reports {d} diagnostic(s), first {s}", .{ diagnostics.len, diagnostics[0].code });
            }
            const missing = good_stages.differenceWith(result.stages_run);
            if (missing.count() != 0) {
                var names: std.ArrayList(u8) = .empty;
                var it = missing.iterator();
                while (it.next()) |stage| {
                    if (names.items.len != 0) try names.append(a, ',');
                    try names.appendSlice(a, @tagName(stage));
                }
                try report.add(.good_skipped_stage, case.source_path, "a good case must run every stage, but skipped: {s}", .{names.items});
            }
        },
        .bad => if (diagnostics.len == 0) {
            try report.add(.bad_has_no_diagnostics, case.source_path, "a bad case reports no diagnostic", .{});
        },
    }
    const import_index = @intFromEnum(precompile.Stage.imports);
    const latest = latestStageIndex(result.stages_run);
    switch (case.family) {
        .parse => if (case.kind == .bad) {
            if (latest != null and latest.? > import_index) {
                try report.add(.misfiled, case.source_path, "a parse case stops at or before the import check, but this one ran stage {s}; move it to check/", .{@tagName(@as(precompile.Stage, @enumFromInt(latest.?)))});
            }
        },
        .check => if (case.kind == .bad) {
            if (latest == null or latest.? <= import_index) {
                try report.add(.misfiled, case.source_path, "a check case runs past the import check, but this one stopped at it; move it to parse/", .{});
            }
        },
    }

    const actual = try renderGolden(gpa, result.stages_run, diagnostics);
    defer gpa.free(actual);

    if (options.write) {
        root.writeFile(io, .{ .sub_path = case.golden_path, .data = actual }) catch |err| {
            try report.add(.missing_golden, case.golden_path, "cannot write the golden: {s}", .{@errorName(err)});
        };
        return;
    }
    const expected = root.readFileAlloc(io, case.golden_path, gpa, .limited(max_file_bytes)) catch |err| switch (err) {
        error.FileNotFound => {
            try report.add(.missing_golden, case.golden_path, "no golden for this case; review the diagnostics, then run `zig build diagnostic-corpus-write`", .{});
            return;
        },
        else => {
            try report.add(.missing_golden, case.golden_path, "cannot read the golden: {s}", .{@errorName(err)});
            return;
        },
    };
    defer gpa.free(expected);
    if (!std.mem.eql(u8, expected, actual)) {
        try report.add(.golden_mismatch, case.golden_path, "{s}", .{try firstDifference(a, expected, actual)});
    }
}

/// Run the corpus under `root`. The caller owns the returned report.
pub fn runCorpus(gpa: std.mem.Allocator, io: std.Io, root: std.Io.Dir, options: Options) !Report {
    var report = Report.init(gpa);
    errdefer report.deinit();
    const a = report.arena.allocator();

    var cases: std.ArrayList(Case) = .empty;
    var goldens: std.ArrayList(Golden) = .empty;
    try discover(gpa, io, root, &report, &cases, &goldens);
    report.cases_found = cases.items.len;

    // Floors on the gate's own input come first: every verdict below means
    // nothing when the corpus is empty or shrunk.
    if (cases.items.len < options.floor) {
        try report.add(.below_floor, corpus_root, "found {d} case(s), the floor is {d}; a deleted case must be restored, and a new case raises the floor", .{ cases.items.len, options.floor });
    }
    inline for (std.meta.fields(Family)) |family_field| {
        inline for (std.meta.fields(Kind)) |kind_field| {
            var n: usize = 0;
            for (cases.items) |case| {
                if (case.family == @field(Family, family_field.name) and case.kind == @field(Kind, kind_field.name)) n += 1;
            }
            if (n == 0) {
                try report.add(.empty_family, family_field.name ++ "/" ++ kind_field.name, "no case in this family", .{});
            }
        }
    }

    for (cases.items, 0..) |case, i| {
        for (cases.items[0..i]) |earlier| {
            if (sameName(earlier, case)) {
                try report.add(.duplicate_name, case.source_path, "shares the golden {s} with {s}", .{ case.golden_path, earlier.source_path });
            }
        }
    }
    for (goldens.items) |golden| {
        var has_source = false;
        for (cases.items) |case| {
            if (case.family == golden.family and case.kind == golden.kind and std.mem.eql(u8, case.name, golden.name)) {
                has_source = true;
                break;
            }
        }
        if (!has_source) try report.add(.orphan_golden, golden.path, "no NAME.ts or NAME.tsx beside this golden", .{});
    }

    var selected: usize = 0;
    for (cases.items) |case| {
        if (options.filter) |text| {
            if (std.mem.find(u8, case.source_path, text) == null) continue;
        }
        selected += 1;
        try runCase(gpa, io, root, case, options, &report);
    }
    if (options.filter) |text| {
        if (selected == 0) {
            try report.add(.filter_matched_nothing, text, "the filter matched none of the {d} case(s)", .{cases.items.len});
        }
    }
    _ = a;
    return report;
}

fn printReport(report: *const Report, options: Options) void {
    for (report.failures.items) |failure| {
        std.debug.print("FAIL [{s}] {s}: {s}\n", .{ @tagName(failure.kind), failure.path, failure.detail });
    }
    std.debug.print(
        "diagnostic corpus: {d} case(s) found, {d} run, {d} failure(s), floor {d}{s}\n",
        .{ report.cases_found, report.cases_run, report.failures.items.len, options.floor, if (options.write) " (golden write mode)" else "" },
    );
}

fn usage() error{InvalidArguments} {
    std.debug.print(
        \\usage: diagnostic-corpus-gate [--write] [--root DIR] [FILTER]
        \\
        \\  --write      rewrite the golden of each selected case, then check the rules
        \\  --root DIR   corpus root (default tests/corpus)
        \\  FILTER       run only cases whose path contains FILTER; a filter that
        \\               matches no case fails
        \\
    , .{});
    return error.InvalidArguments;
}

pub fn main(init: std.process.Init) void {
    run(init) catch |err| {
        if (err != error.CorpusFailed and err != error.InvalidArguments) {
            std.debug.print("diagnostic corpus: {s}\n", .{@errorName(err)});
        }
        std.process.exit(1);
    };
}

fn run(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, gpa);
    defer args.deinit();
    _ = args.next();
    var options: Options = .{ .floor = minimum_cases };
    var root_path: []const u8 = corpus_root;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--write")) {
            options.write = true;
        } else if (std.mem.eql(u8, arg, "--root")) {
            root_path = args.next() orelse return usage();
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            return usage();
        } else if (options.filter == null and !std.mem.startsWith(u8, arg, "--")) {
            options.filter = arg;
        } else {
            return usage();
        }
    }

    var root = std.Io.Dir.cwd().openDir(io, root_path, .{ .iterate = true }) catch |err| {
        std.debug.print("diagnostic corpus: cannot open {s}: {s}\n", .{ root_path, @errorName(err) });
        return error.CorpusFailed;
    };
    defer root.close(io);

    var report = try runCorpus(gpa, io, root, options);
    defer report.deinit();
    printReport(&report, options);
    if (report.failures.items.len != 0) return error.CorpusFailed;
}

// ---------------------------------------------------------------------------
// Tests. They build scratch corpora under the Zig cache, never the real one.
// ---------------------------------------------------------------------------

const testing = std.testing;

const good_source =
    \\// A handler with a narrow capsule passes every stage.
    \\structural Guardrails<T> = Proof<T, "result_safe">;
    \\
    \\function handler(req: Request): Guardrails<Response> {
    \\    return Response.json({ ok: true });
    \\}
    \\
;

const parse_bad_source =
    \\// A default arm that is not last is refused by the parser.
    \\function handler(req: Request): Response {
    \\    return match (1) { when 1: Response.text("a") default: Response.text("b") when 2: Response.text("c") };
    \\}
    \\
;

const check_bad_source =
    \\// A match with no default arm is not exhaustive.
    \\structural Guardrails<T> = Proof<T, "result_safe">;
    \\
    \\function handler(req: Request): Guardrails<Response> {
    \\    return match (req.method) {
    \\        when "GET": Response.json({ ok: true })
    \\    };
    \\}
    \\
;

fn writeScratch(dir: std.Io.Dir, path: []const u8, data: []const u8) !void {
    if (std.fs.path.dirname(path)) |parent| try dir.createDirPath(testing.io, parent);
    try dir.writeFile(testing.io, .{ .sub_path = path, .data = data });
}

fn seedScratch(dir: std.Io.Dir) !void {
    try writeScratch(dir, "parse/bad/p.ts", parse_bad_source);
    try writeScratch(dir, "parse/good/g.ts", good_source);
    try writeScratch(dir, "check/bad/c.ts", check_bad_source);
    try writeScratch(dir, "check/good/g.ts", good_source);
    var written = try runCorpus(testing.allocator, testing.io, dir, .{ .write = true, .floor = 4 });
    defer written.deinit();
    for (written.failures.items) |failure| {
        std.debug.print("seed failure [{s}] {s}: {s}\n", .{ @tagName(failure.kind), failure.path, failure.detail });
    }
    try testing.expectEqual(@as(usize, 0), written.failures.items.len);
}

fn expectFailure(dir: std.Io.Dir, options: Options, kind: FailureKind) !void {
    var report = try runCorpus(testing.allocator, testing.io, dir, options);
    defer report.deinit();
    if (!report.has(kind)) {
        for (report.failures.items) |failure| {
            std.debug.print("got [{s}] {s}: {s}\n", .{ @tagName(failure.kind), failure.path, failure.detail });
        }
        std.debug.print("expected [{s}] and did not find it\n", .{@tagName(kind)});
        return error.ProbeNotRejected;
    }
}

fn alwaysCrashes(_: std.mem.Allocator, _: []const u8, _: []const u8) anyerror!precompile.CheckResult {
    return error.ProbeCrash;
}

fn goldenText(dir: std.Io.Dir, path: []const u8) ![]u8 {
    return dir.readFileAlloc(testing.io, path, testing.allocator, .limited(max_file_bytes));
}

/// Apply one mutation to a fresh, passing scratch corpus and require the gate
/// to name the failure it should. Every `FailureKind` is a case of the switch,
/// so a new kind does not compile until it has a probe.
fn probe(kind: FailureKind) !void {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const dir = tmp.dir;
    try seedScratch(dir);
    const base: Options = .{ .floor = 4 };

    // The unmutated corpus passes, so a failure below comes from the mutation.
    {
        var clean = try runCorpus(testing.allocator, testing.io, dir, base);
        defer clean.deinit();
        try testing.expectEqual(@as(usize, 0), clean.failures.items.len);
        try testing.expectEqual(@as(usize, 4), clean.cases_run);
    }

    switch (kind) {
        .layout => {
            try writeScratch(dir, "check/bad/deeper/x.ts", check_bad_source);
            try expectFailure(dir, base, kind);
        },
        .unexpected_file => {
            try writeScratch(dir, "check/bad/notes.txt", "x");
            try expectFailure(dir, base, kind);
        },
        .duplicate_name => {
            try writeScratch(dir, "check/bad/c.tsx", check_bad_source);
            try expectFailure(dir, base, kind);
        },
        .below_floor => try expectFailure(dir, .{ .floor = 5 }, kind),
        .empty_family => {
            try dir.deleteFile(testing.io, "check/good/g.ts");
            try dir.deleteFile(testing.io, "check/good/g.diag");
            try expectFailure(dir, .{ .floor = 0 }, kind);
        },
        .filter_matched_nothing => try expectFailure(dir, .{ .floor = 4, .filter = "no-such-case" }, kind),
        .unreadable_source => {
            // A source over the size limit cannot be read whole.
            const big = try testing.allocator.alloc(u8, max_file_bytes + 1);
            defer testing.allocator.free(big);
            @memset(big, '/');
            try dir.writeFile(testing.io, .{ .sub_path = "check/bad/c.ts", .data = big });
            try expectFailure(dir, base, kind);
        },
        .check_crashed => try expectFailure(dir, .{ .floor = 4, .check = alwaysCrashes }, kind),
        .missing_golden => {
            try dir.deleteFile(testing.io, "check/bad/c.diag");
            try expectFailure(dir, base, kind);
        },
        .orphan_golden => {
            try dir.deleteFile(testing.io, "check/bad/c.ts");
            try expectFailure(dir, .{ .floor = 0 }, kind);
        },
        .golden_mismatch => {
            const text = try goldenText(dir, "check/bad/c.diag");
            defer testing.allocator.free(text);
            const changed = try testing.allocator.dupe(u8, text);
            defer testing.allocator.free(changed);
            const at = std.mem.find(u8, changed, "ZTS") orelse return error.ProbeNotRejected;
            changed[at + 1] = 'Q';
            try dir.writeFile(testing.io, .{ .sub_path = "check/bad/c.diag", .data = changed });
            try expectFailure(dir, base, kind);
        },
        .good_has_diagnostics => {
            try writeScratch(dir, "check/good/g.ts", check_bad_source);
            try expectFailure(dir, base, kind);
        },
        .bad_has_no_diagnostics => {
            try writeScratch(dir, "check/bad/c.ts", good_source);
            try expectFailure(dir, base, kind);
        },
        .good_skipped_stage => {
            // Source with no handler function skips the verifier, flow and
            // later stages, yet reports no diagnostic.
            try writeScratch(dir, "check/good/g.ts", "const answer = 42;\n");
            try expectFailure(dir, base, kind);
        },
        .misfiled => {
            try writeScratch(dir, "parse/bad/p.ts", check_bad_source);
            try expectFailure(dir, base, kind);
        },
    }
}

test "every failure kind is probed and rejected" {
    inline for (std.meta.fields(FailureKind)) |field| {
        probe(@field(FailureKind, field.name)) catch |err| {
            std.debug.print("probe for {s} failed: {s}\n", .{ field.name, @errorName(err) });
            return err;
        };
    }
}

test "a golden with one stage name removed no longer matches" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try seedScratch(tmp.dir);
    const text = try goldenText(tmp.dir, "check/good/g.diag");
    defer testing.allocator.free(text);
    try testing.expect(std.mem.startsWith(u8, text, "stages: strip,parse,imports,boolean,types,strict,verifier,flow,contract,paths,trace,spec,canonical\n"));
    const without_types = try std.mem.replaceOwned(u8, testing.allocator, text, "types,", "");
    defer testing.allocator.free(without_types);
    try testing.expect(!std.mem.eql(u8, text, without_types));
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "check/good/g.diag", .data = without_types });
    try expectFailure(tmp.dir, .{ .floor = 4 }, .golden_mismatch);
}

test "a filter selects cases and leaves the rest unrun" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try seedScratch(tmp.dir);
    var report = try runCorpus(testing.allocator, testing.io, tmp.dir, .{ .floor = 4, .filter = "check/bad" });
    defer report.deinit();
    try testing.expectEqual(@as(usize, 0), report.failures.items.len);
    try testing.expectEqual(@as(usize, 1), report.cases_run);
    try testing.expectEqual(@as(usize, 4), report.cases_found);
}

test "a check run leaves no witness corpus in the working tree" {
    // A flow leak is what makes the check want to persist a witness. With
    // persistence off, the directory named for this handler path must not
    // appear. The path is relative, so a stray write lands in the test's cwd.
    const leak =
        \\import { env } from "zttp:env";
        \\
        \\function handler(req: Request): Response {
        \\    const secret = env("API_KEY") ?? "";
        \\    return Response.json({ leaked: secret });
        \\}
        \\
    ;
    const handler_path = "witness-probe/handler.ts";
    var result = try defaultCheck(testing.allocator, leak, handler_path);
    defer result.deinit(testing.allocator);
    try testing.expect(result.stages_run.contains(.flow));
    const corpus_dir = try zts.witness_corpus.corpusDir(testing.allocator, handler_path);
    defer testing.allocator.free(corpus_dir);
    try testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(testing.io, corpus_dir, .{}));
}
