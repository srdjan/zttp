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
//!   * a filter that matches no case;
//!   * a catalog code that no `bad` case reports and that
//!     `scripts/corpus-uncovered.allow` does not explain (the code ratchet,
//!     U2.3), a row for a covered or unknown code, a duplicate row, a row with
//!     an empty or placeholder reason, and a catalog below `minimum_universe`.
//!     The ratchet matches the `code` field of each diagnostic, never a
//!     substring, and its universe is the diagnostic catalog, not
//!     `rule_registry`.
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
pub const minimum_cases: usize = 161;

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
    // The code ratchet (U2.3). Its universe is the diagnostic catalog.
    universe_below_floor,
    uncovered_code,
    stale_allow_row,
    unknown_code_row,
    duplicate_row,
    empty_reason,
    weak_reason,
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

/// The code ratchet input. `universe` holds each distinct code exactly once.
/// `allow_text` is the content of `scripts/corpus-uncovered.allow`.
pub const Ratchet = struct {
    universe: []const []const u8,
    allow_text: []const u8,
    /// The universe size below which the ratchet is refused, so an empty or
    /// shrunk catalog cannot report that every code is covered.
    universe_floor: usize,
};

/// The path of the allowlist, relative to the repository root.
const allow_path = "scripts/corpus-uncovered.allow";

/// The number of distinct codes in the diagnostic catalog when the ratchet
/// was written. The catalog may grow; it may not silently shrink to nothing.
pub const minimum_universe: usize = 140;

pub const Options = struct {
    /// The check to run. Tests replace it to reach a crash the real check
    /// does not produce on demand.
    check: CheckFn = defaultCheck,
    /// The code ratchet. Null leaves it off, which only the gate's own tests
    /// do. A filtered run skips it, because a filtered run covers a subset.
    ratchet: ?Ratchet = null,
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
    /// Every `code` field that a `bad` case's diagnostics carried.
    covered_codes: std.StringHashMapUnmanaged(void) = .empty,
    /// Per-verdict counts of the code ratchet. Their sum is the universe.
    codes_covered: usize = 0,
    codes_allowlisted: usize = 0,
    codes_defect: usize = 0,
    codes_uncovered: usize = 0,
    universe_size: usize = 0,

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
        .bad => {
            if (diagnostics.len == 0) {
                try report.add(.bad_has_no_diagnostics, case.source_path, "a bad case reports no diagnostic", .{});
            }
            // The ratchet matches the `code` field of each diagnostic, never
            // a substring: a ZTS code appears inside other messages. A case
            // whose golden differs fails above, so a code recorded here is
            // also the code the golden pins.
            for (diagnostics) |diag| {
                if (report.covered_codes.contains(diag.code)) continue;
                try report.covered_codes.put(a, try a.dupe(u8, diag.code), {});
            }
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

const AllowRow = struct { code: []const u8, reason: []const u8, line: usize };

/// Parse `CODE reason...` rows. A line that is blank or starts with `#` is
/// skipped. The reason is everything after the first run of blanks.
fn parseAllow(a: std.mem.Allocator, text: []const u8) ![]AllowRow {
    var rows: std.ArrayList(AllowRow) = .empty;
    var line_no: usize = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        line_no += 1;
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        const split = std.mem.findAny(u8, line, " \t") orelse line.len;
        try rows.append(a, .{
            .code = line[0..split],
            .reason = std.mem.trim(u8, line[split..], " \t"),
            .line = line_no,
        });
    }
    return rows.toOwnedSlice(a);
}

/// A reason names a mechanism, so a short or placeholder reason is refused.
fn isWeakReason(reason: []const u8) bool {
    if (reason.len < 12) return true;
    const placeholders = [_][]const u8{ "not written", "todo", "tbd", "later", "wip" };
    for (placeholders) |needle| {
        if (std.ascii.findIgnoreCase(reason, needle) != null) return true;
    }
    return false;
}

fn isDefectReason(reason: []const u8) bool {
    return std.mem.startsWith(u8, reason, "DEFECT:");
}

/// The code ratchet. Every code in the universe needs a `bad` case that
/// reports it, or an allowlist row that states why the default check cannot.
/// Each universe code gets exactly one verdict (covered, allowlisted, or
/// uncovered), and the counts sum to the universe.
fn checkRatchet(report: *Report, ratchet: Ratchet) !void {
    const a = report.arena.allocator();
    report.universe_size = ratchet.universe.len;
    // Floor first: an empty universe satisfies every set difference below.
    if (ratchet.universe.len < ratchet.universe_floor) {
        try report.add(.universe_below_floor, allow_path, "the code universe holds {d} code(s), the floor is {d}", .{ ratchet.universe.len, ratchet.universe_floor });
        return;
    }
    const rows = try parseAllow(a, ratchet.allow_text);
    for (rows, 0..) |row, i| {
        var duplicate = false;
        for (rows[0..i]) |earlier| {
            if (std.mem.eql(u8, earlier.code, row.code)) duplicate = true;
        }
        if (duplicate) {
            try report.add(.duplicate_row, row.code, "{s}:{d}: a second row for this code", .{ allow_path, row.line });
            continue;
        }
        var known = false;
        for (ratchet.universe) |code| {
            if (std.mem.eql(u8, code, row.code)) known = true;
        }
        if (!known) {
            try report.add(.unknown_code_row, row.code, "{s}:{d}: not a code in the diagnostic catalog", .{ allow_path, row.line });
            continue;
        }
        if (report.covered_codes.contains(row.code)) {
            try report.add(.stale_allow_row, row.code, "{s}:{d}: a bad case now reports this code; delete the row", .{ allow_path, row.line });
            continue;
        }
        if (row.reason.len == 0) {
            try report.add(.empty_reason, row.code, "{s}:{d}: the row has no reason", .{ allow_path, row.line });
        } else if (isWeakReason(row.reason)) {
            try report.add(.weak_reason, row.code, "{s}:{d}: the reason must state a mechanism, not a placeholder: {s}", .{ allow_path, row.line, row.reason });
        }
    }
    for (ratchet.universe) |code| {
        if (report.covered_codes.contains(code)) {
            report.codes_covered += 1;
            continue;
        }
        var allowed: ?AllowRow = null;
        for (rows) |row| {
            if (std.mem.eql(u8, row.code, code)) {
                allowed = row;
                break;
            }
        }
        if (allowed) |row| {
            report.codes_allowlisted += 1;
            if (isDefectReason(row.reason)) report.codes_defect += 1;
        } else {
            report.codes_uncovered += 1;
            try report.add(.uncovered_code, code, "no bad case reports this code, and {s} has no row for it; write a case that proves it, or add a row that states the mechanism that makes it unreachable", .{allow_path});
        }
    }
}

/// The distinct codes of the diagnostic catalog, in catalog order. A code
/// with two producers (ZTS008, ZTS044) appears once. The caller frees the
/// slice. The code strings are static.
pub fn catalogUniverse(gpa: std.mem.Allocator) ![]const []const u8 {
    var codes: std.ArrayList([]const u8) = .empty;
    errdefer codes.deinit(gpa);
    for (zts.DiagnosticCatalog.entries()) |entry| {
        var seen = false;
        for (codes.items) |code| {
            if (std.mem.eql(u8, code, entry.code)) seen = true;
        }
        if (!seen) try codes.append(gpa, entry.code);
    }
    return codes.toOwnedSlice(gpa);
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
    // A filtered run sees a subset of the cases, so it cannot say which codes
    // are uncovered.
    if (options.ratchet) |ratchet| {
        if (options.filter == null) try checkRatchet(&report, ratchet);
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
    if (options.ratchet != null and options.filter == null) {
        std.debug.print(
            "diagnostic corpus: code ratchet over the diagnostic catalog: {d} code(s) = {d} covered by a bad case + {d} allowlisted ({d} DEFECT) + {d} uncovered (floor {d})\n",
            .{ report.universe_size, report.codes_covered, report.codes_allowlisted, report.codes_defect, report.codes_uncovered, options.ratchet.?.universe_floor },
        );
    }
    if (options.filter) |text| {
        std.debug.print("diagnostic corpus: FILTERED run for \"{s}\": {d} of {d} case(s), not a verdict on the corpus\n", .{ text, report.cases_run, report.cases_found });
    }
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

    const allow_text = std.Io.Dir.cwd().readFileAlloc(io, allow_path, gpa, .limited(max_file_bytes)) catch |err| {
        std.debug.print("diagnostic corpus: cannot read {s}: {s}\n", .{ allow_path, @errorName(err) });
        return error.CorpusFailed;
    };
    defer gpa.free(allow_text);
    const universe = try catalogUniverse(gpa);
    defer gpa.free(universe);
    options.ratchet = .{ .universe = universe, .allow_text = allow_text, .universe_floor = minimum_universe };

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
    const ratcheted: Options = .{ .floor = 4, .ratchet = scratchRatchet(scratch_allow) };

    // The unmutated corpus passes, so a failure below comes from the mutation.
    // It passes with the ratchet on too: two covered codes and one allowlisted.
    {
        var clean = try runCorpus(testing.allocator, testing.io, dir, base);
        defer clean.deinit();
        try testing.expectEqual(@as(usize, 0), clean.failures.items.len);
        try testing.expectEqual(@as(usize, 4), clean.cases_run);
        var clean_ratchet = try runCorpus(testing.allocator, testing.io, dir, ratcheted);
        defer clean_ratchet.deinit();
        for (clean_ratchet.failures.items) |failure| {
            std.debug.print("clean ratchet failure [{s}] {s}: {s}\n", .{ @tagName(failure.kind), failure.path, failure.detail });
        }
        try testing.expectEqual(@as(usize, 0), clean_ratchet.failures.items.len);
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
        // The ratchet probes. Each mutates the allowlist text or the corpus and
        // requires the one failure kind that the mutation should cause.
        .universe_below_floor => {
            var options = ratcheted;
            options.ratchet.?.universe_floor = scratch_universe.len + 1;
            try expectFailure(dir, options, kind);
        },
        .uncovered_code => {
            // The only case that reports the code goes, and no row replaces it.
            try dir.deleteFile(testing.io, "check/bad/c.ts");
            try dir.deleteFile(testing.io, "check/bad/c.diag");
            try expectFailureAt(dir, .{ .floor = 0, .ratchet = scratchRatchet(scratch_allow) }, kind, scratch_check_code);
        },
        .stale_allow_row => {
            const allow = scratch_allow ++ scratch_check_code ++ " a covered code must not carry a row\n";
            try expectFailureAt(dir, .{ .floor = 4, .ratchet = scratchRatchet(allow) }, kind, scratch_check_code);
        },
        .unknown_code_row => {
            const allow = scratch_allow ++ "ZTS998 a code that the catalog does not hold\n";
            try expectFailureAt(dir, .{ .floor = 4, .ratchet = scratchRatchet(allow) }, kind, "ZTS998");
        },
        .duplicate_row => {
            const allow = scratch_allow ++ scratch_phony_code ++ " a second row for the same code\n";
            try expectFailureAt(dir, .{ .floor = 4, .ratchet = scratchRatchet(allow) }, kind, scratch_phony_code);
        },
        .empty_reason => {
            try expectFailureAt(dir, .{ .floor = 4, .ratchet = scratchRatchet(scratch_phony_code ++ "   \n") }, kind, scratch_phony_code);
        },
        .weak_reason => {
            try expectFailureAt(dir, .{ .floor = 4, .ratchet = scratchRatchet(scratch_phony_code ++ " not written yet\n") }, kind, scratch_phony_code);
        },
    }
}

// ---------------------------------------------------------------------------
// The code ratchet (U2.3). The scratch universe holds the two codes that the
// scratch corpus reports and one phony code that only an allowlist row covers.
// ---------------------------------------------------------------------------

const scratch_parse_code = "ZTS062";
const scratch_check_code = "ZTS205";
const scratch_phony_code = "ZTS990";
const scratch_universe = [_][]const u8{ scratch_parse_code, scratch_check_code, scratch_phony_code };
const scratch_allow =
    "# a comment line and a blank line are skipped\n" ++
    "\n" ++
    scratch_phony_code ++ " needs a policy source, which the in-process check does not take\n";

fn scratchRatchet(allow_text: []const u8) Ratchet {
    return .{ .universe = &scratch_universe, .allow_text = allow_text, .universe_floor = scratch_universe.len };
}

/// Like `expectFailure`, and the failure must be about `path` (the code or the
/// row), so a probe cannot pass on a failure that came from somewhere else.
fn expectFailureAt(dir: std.Io.Dir, options: Options, kind: FailureKind, path: []const u8) !void {
    var report = try runCorpus(testing.allocator, testing.io, dir, options);
    defer report.deinit();
    for (report.failures.items) |failure| {
        if (failure.kind == kind and std.mem.eql(u8, failure.path, path)) return;
    }
    for (report.failures.items) |failure| {
        std.debug.print("got [{s}] {s}: {s}\n", .{ @tagName(failure.kind), failure.path, failure.detail });
    }
    std.debug.print("expected [{s}] at {s} and did not find it\n", .{ @tagName(kind), path });
    return error.ProbeNotRejected;
}

/// Every verdict that the ratchet can give a code or the universe. A new
/// verdict does not compile until `probeVerdict` handles it. A failure verdict
/// must also be a `FailureKind`, which `probe` already requires a probe for.
const RatchetVerdict = enum {
    covered_by_case,
    allowlisted,
    uncovered_code,
    stale_allow_row,
    unknown_code_row,
    duplicate_row,
    empty_reason,
    weak_reason,
    universe_below_floor,
};

fn probeVerdict(verdict: RatchetVerdict) !void {
    switch (verdict) {
        .covered_by_case, .allowlisted => {
            var tmp = testing.tmpDir(.{ .iterate = true });
            defer tmp.cleanup();
            try seedScratch(tmp.dir);
            var report = try runCorpus(testing.allocator, testing.io, tmp.dir, .{ .floor = 4, .ratchet = scratchRatchet(scratch_allow) });
            defer report.deinit();
            try testing.expectEqual(@as(usize, 0), report.failures.items.len);
            // Each code has exactly one verdict, and the verdicts sum to the
            // universe. The counts are the values expected, not a difference.
            try testing.expectEqual(scratch_universe.len, report.universe_size);
            try testing.expectEqual(@as(usize, 2), report.codes_covered);
            try testing.expectEqual(@as(usize, 1), report.codes_allowlisted);
            try testing.expectEqual(@as(usize, 0), report.codes_uncovered);
            try testing.expectEqual(report.universe_size, report.codes_covered + report.codes_allowlisted + report.codes_uncovered);
            switch (verdict) {
                .covered_by_case => {
                    try testing.expect(report.covered_codes.contains(scratch_parse_code));
                    try testing.expect(report.covered_codes.contains(scratch_check_code));
                    try testing.expect(!report.covered_codes.contains(scratch_phony_code));
                },
                else => {
                    try testing.expectEqual(@as(usize, 0), report.codes_defect);
                },
            }
        },
        .uncovered_code => try probe(.uncovered_code),
        .stale_allow_row => try probe(.stale_allow_row),
        .unknown_code_row => try probe(.unknown_code_row),
        .duplicate_row => try probe(.duplicate_row),
        .empty_reason => try probe(.empty_reason),
        .weak_reason => try probe(.weak_reason),
        .universe_below_floor => try probe(.universe_below_floor),
    }
}

test "every ratchet verdict is probed" {
    inline for (std.meta.fields(RatchetVerdict)) |field| {
        probeVerdict(@field(RatchetVerdict, field.name)) catch |err| {
            std.debug.print("ratchet probe for {s} failed: {s}\n", .{ field.name, @errorName(err) });
            return err;
        };
    }
}

test "a ratchet verdict that fails the gate is a failure kind" {
    // A verdict name that is not a FailureKind would be a verdict that no
    // probe in `probe` could reach. `@field` does not compile for such a name.
    inline for (std.meta.fields(RatchetVerdict)) |field| {
        if (comptime std.mem.eql(u8, field.name, "covered_by_case") or std.mem.eql(u8, field.name, "allowlisted")) continue;
        _ = @field(FailureKind, field.name);
    }
}

test "the ratchet matches the code field and not a substring of a message" {
    // Every diagnostic here has code ZTS603 and a message that names ZTS990.
    // A substring match would call ZTS990 covered.
    const check = struct {
        fn run(gpa: std.mem.Allocator, _: []const u8, _: []const u8) anyerror!precompile.CheckResult {
            var result: precompile.CheckResult = .{};
            errdefer result.deinit(gpa);
            result.stages_run.insert(.strip);
            result.stages_run.insert(.parse);
            result.stages_run.insert(.imports);
            result.stages_run.insert(.boolean);
            try result.json_diagnostics.append(gpa, .{
                .code = scratch_check_code,
                .severity = "error",
                .message = "unrelated to " ++ scratch_phony_code ++ " in any way",
                .file = "check/bad/c.ts",
                .line = 1,
                .column = 1,
                .suggestion = null,
            });
            return result;
        }
    }.run;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try writeScratch(tmp.dir, "check/bad/c.ts", check_bad_source);
    var report = try runCorpus(testing.allocator, testing.io, tmp.dir, .{
        .floor = 0,
        .check = check,
        .write = true,
        .ratchet = .{ .universe = &[_][]const u8{ scratch_check_code, scratch_phony_code }, .allow_text = "", .universe_floor = 2 },
    });
    defer report.deinit();
    try testing.expect(report.covered_codes.contains(scratch_check_code));
    try testing.expect(!report.covered_codes.contains(scratch_phony_code));
    try testing.expectEqual(@as(usize, 1), report.codes_covered);
    try testing.expectEqual(@as(usize, 1), report.codes_uncovered);
}

test "a filtered run skips the ratchet" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try seedScratch(tmp.dir);
    var report = try runCorpus(testing.allocator, testing.io, tmp.dir, .{ .floor = 4, .filter = "check/bad", .ratchet = scratchRatchet("") });
    defer report.deinit();
    try testing.expect(!report.has(.uncovered_code));
    try testing.expectEqual(@as(usize, 0), report.universe_size);
}

test "the catalog universe holds each code once and clears the floor" {
    const universe = try catalogUniverse(testing.allocator);
    defer testing.allocator.free(universe);
    try testing.expect(universe.len >= minimum_universe);
    for (universe, 0..) |code, i| {
        for (universe[0..i]) |earlier| try testing.expect(!std.mem.eql(u8, earlier, code));
    }
}

test "allowlist rows parse code and reason" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const rows = try parseAllow(arena.allocator(), "# note\n\nZTS001 first reason here\n  ZTS002\tsecond reason\nZTS003\n");
    try testing.expectEqual(@as(usize, 3), rows.len);
    try testing.expectEqualStrings("ZTS001", rows[0].code);
    try testing.expectEqualStrings("first reason here", rows[0].reason);
    try testing.expectEqualStrings("ZTS002", rows[1].code);
    try testing.expectEqualStrings("second reason", rows[1].reason);
    try testing.expectEqualStrings("ZTS003", rows[2].code);
    try testing.expectEqualStrings("", rows[2].reason);
    try testing.expectEqual(@as(usize, 5), rows[2].line);
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
