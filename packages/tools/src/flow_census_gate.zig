//! The flow census gate (plan F0, constraint K1).
//!
//! `test-flow-census` measures the flow checker's three leak properties
//! (`no_secret_leakage`, `no_credential_leakage`, `injection_safe`) over a
//! generated census of probes, and compares every probe's observed verdict
//! with the expected verdict in `flow_census_probes.zig`. A probe puts one
//! labelled value on a path to one sink, through one kind of callee, and its
//! handler claims exactly one property with `Proof<T, | "...">`.
//!
//! The observed verdict is one of four classes:
//!   * `refused`: the claimed property is false and at least one flow sink
//!     diagnostic that witnesses that property (`witnessesProperty`) says why;
//!   * `unproven`: the claimed property is false and no flow diagnostic says why;
//!   * `held`: the claimed property is true;
//!   * `no_verdict`: the probe did not reach a flow verdict. The gate reads
//!     that as a failure, never as a refusal of the leak.
//! The expected verdict is `refuse`, `refuse_or_unprove`, or `hold`. The
//! outcome of the comparison is `match`, `fail_open` (expected a refusal, the
//! property held), `over_refusal` (expected a hold, got a refusal or an
//! unproven property), `weak` (expected a refusal, got only an unproven
//! property), or `no_verdict`.
//!
//! Today's verdicts are the starting state, so a non-matching probe is
//! carried by one row of `scripts/flow-census.allow`. The row names the probe,
//! the outcome it carries, and a mechanism tag from a closed set that names
//! the plan unit expected to close it. Each unit that fixes the checker
//! deletes the rows it closes. The gate fails on the opposite case too: a row
//! whose probe now matches is stale, and the ratchet only moves toward fewer
//! rows.
//!
//! What this gate refuses, each as a named `FailureKind`:
//!   * a probe with no verdict (a parse or type error, a missing flow stage,
//!     an error outside the flow codes, a claim failure that disagrees with
//!     the property), or a check that crashed;
//!   * a non-matching probe with no allowlist row, and a row whose recorded
//!     outcome differs from the observed outcome;
//!   * a row for a matching probe, for an unknown probe, a duplicate row, a
//!     row with an empty or unknown mechanism, and a row with an outcome that
//!     is not `fail_open`, `over_refusal`, or `weak`;
//!   * a census below the committed floor in total, in a group, or in any
//!     (label, sink) column, and two probes with one name;
//!   * an expectation that states no reason.
//!
//! The floors exist because a census that lost an axis would still report
//! success: the counts below the floor mean less than they say. The counts are
//! per (label, sink) column, per group, and in total, and the gate prints them
//! on every run. The unit tests probe every `FailureKind` through a small
//! synthetic census, and a census test requires that every member is probed.
//!
//! The scratch directory is under `$TMPDIR`, because import probes need real
//! files and the working tree must stay clean. The check runs with
//! `persist_witnesses = false` and reads no `zttp.json`.
//!
//! `-- --list` prints one line per probe: its name, expected verdict, observed
//! verdict, outcome, and diagnostic codes. It changes no verdict.

const std = @import("std");
const precompile = @import("precompile.zig");
const probes_mod = @import("flow_census_probes.zig");

const Probe = probes_mod.Probe;
const Expect = probes_mod.Expect;
const Group = probes_mod.Group;
const Property = probes_mod.Property;

const allow_path = "scripts/flow-census.allow";
const max_file_bytes = 1024 * 1024;

pub const Observed = enum { refused, unproven, held, no_verdict };

pub const Outcome = enum { match, fail_open, over_refusal, weak, no_verdict };

/// The plan units that can close a non-matching probe. A row names exactly
/// one. The closed set is the contract between this gate and the plan.
pub const mechanisms = [_][]const u8{
    "F1", // a sink is silent during a summary
    "F1b", // an unresolved call whose result is discarded
    "F1c", // recursion stops at the active frame
    "F2", // a captured value carries no label
    "F3", // a re-walked callee keeps stale labels
    "F4", // HTML built in a callee and discarded
    "F5", // a return-path, concise-body, or nested-expression sink
    "F6", // a credential read through a passed request
    "F7", // a cross-file helper
    "F10", // a credential in an egress body
    "G", // a module-level declaration carries no label
};

pub const FailureKind = enum {
    below_floor,
    group_below_floor,
    column_below_floor,
    duplicate_probe,
    missing_reason,
    scratch_failed,
    check_crashed,
    no_verdict,
    unexplained_mismatch,
    wrong_outcome,
    stale_row,
    unknown_probe_row,
    duplicate_row,
    empty_mechanism,
    unknown_mechanism,
    unknown_outcome_row,
};

pub const Failure = struct {
    kind: FailureKind,
    path: []const u8,
    detail: []const u8,
};

pub const CheckFn = *const fn (gpa: std.mem.Allocator, source: []const u8, handler_path: []const u8) anyerror!precompile.CheckResult;

/// The same call `zts check --json` makes, with witness persistence off and no
/// policy, declaration, schema or system path.
fn defaultCheck(gpa: std.mem.Allocator, source: []const u8, handler_path: []const u8) anyerror!precompile.CheckResult {
    return precompile.runCheckOnlyFromSourceWithOptions(gpa, source, handler_path, .{
        .json_mode = true,
        .persist_witnesses = false,
    });
}

pub const Floors = struct {
    total: usize,
    matrix: usize,
    extended: usize,
    hand: usize,
    per_column: usize,
};

pub const committed_floors: Floors = .{
    .total = probes_mod.minimum_matrix + probes_mod.minimum_extended + probes_mod.minimum_hand,
    .matrix = probes_mod.minimum_matrix,
    .extended = probes_mod.minimum_extended,
    .hand = probes_mod.minimum_hand,
    .per_column = probes_mod.minimum_per_column,
};

pub const Options = struct {
    check: CheckFn = defaultCheck,
    /// The text of `scripts/flow-census.allow`.
    allow_text: []const u8,
    floors: Floors = committed_floors,
    /// Print one line per probe.
    list: bool = false,
};

const outcome_count = std.meta.fields(Outcome).len;
const group_count = std.meta.fields(Group).len;

pub const Record = struct {
    probe: usize,
    observed: Observed,
    outcome: Outcome,
    /// The flow codes and the claim failure the check reported, or the reason
    /// for a missing verdict.
    detail: []const u8,
};

pub const Report = struct {
    arena: std.heap.ArenaAllocator,
    failures: std.ArrayList(Failure) = .empty,
    records: std.ArrayList(Record) = .empty,
    probes_total: usize = 0,
    /// Probes per column and group, counted before any probe runs.
    column_probes: [probes_mod.column_count]usize = @splat(0),
    group_probes: [group_count]usize = @splat(0),
    /// Outcomes per column, per group, and in total.
    column_outcomes: [probes_mod.column_count][outcome_count]usize = @splat(@splat(0)),
    group_outcomes: [group_count][outcome_count]usize = @splat(@splat(0)),
    total_outcomes: [outcome_count]usize = @splat(0),
    /// Matches by what the probe expected, for the plan's table shape.
    matched_refuse: [group_count]usize = @splat(0),
    matched_hold: [group_count]usize = @splat(0),
    /// Allowlisted probes per mechanism (index into `mechanisms`) and rows read.
    mechanism_counts: [mechanisms.len]usize = @splat(0),
    allowlisted: usize = 0,
    rows_read: usize = 0,

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

// ---------------------------------------------------------------------------
// Classification.
// ---------------------------------------------------------------------------

pub const Verdict = struct {
    observed: Observed,
    /// For `no_verdict`, the reason. Otherwise the diagnostic codes seen.
    detail: []const u8,
};

fn isFlowCode(code: []const u8) bool {
    if (code.len != 6 or !std.mem.startsWith(u8, code, "ZTS40")) return false;
    return code[5] >= '0' and code[5] <= '7';
}

/// The flow codes that witness `property` (`propertyTagForKind` in
/// flow_checker.zig). A refusal counts only when one of these says why, so a
/// credential probe falsified through ZTS407 alone is not read as a refusal
/// of the credential leak.
fn witnessesProperty(code: []const u8, property: Property) bool {
    const witnesses: []const []const u8 = switch (property) {
        .no_secret_leakage => &.{ "ZTS400", "ZTS402", "ZTS404", "ZTS406" },
        .no_credential_leakage => &.{ "ZTS401", "ZTS403", "ZTS405" },
        .injection_safe => &.{"ZTS407"},
    };
    for (witnesses) |w| {
        if (std.mem.eql(u8, w, code)) return true;
    }
    return false;
}

/// The warnings that every probe carries: an import the probe does not use,
/// and a variable the probe does not read. Neither says anything about flow.
fn isBenignWarning(code: []const u8) bool {
    return std.mem.eql(u8, code, "ZTS305") or std.mem.eql(u8, code, "ZTS306");
}

const claim_failure_code = "ZTS500";

fn claimed(props: anytype, property: Property) bool {
    return switch (property) {
        .no_secret_leakage => props.no_secret_leakage,
        .no_credential_leakage => props.no_credential_leakage,
        .injection_safe => props.injection_safe,
    };
}

/// Read the verdict for `property` from a check result. All memory comes from
/// `a`.
pub fn classify(a: std.mem.Allocator, result: *const precompile.CheckResult, property: Property) !Verdict {
    if (!result.stages_run.contains(.flow)) {
        return .{ .observed = .no_verdict, .detail = "the flow stage did not run" };
    }
    const props = result.properties orelse {
        return .{ .observed = .no_verdict, .detail = "the check produced no contract, so no property was decided" };
    };
    var codes: std.ArrayList(u8) = .empty;
    var flow_codes: usize = 0;
    var claim_failures: usize = 0;
    for (result.json_diagnostics.items) |diag| {
        const is_error = std.mem.eql(u8, diag.severity, "error");
        const is_warning = std.mem.eql(u8, diag.severity, "warning");
        if (isFlowCode(diag.code)) {
            if (witnessesProperty(diag.code, property)) flow_codes += 1;
        } else if (std.mem.eql(u8, diag.code, claim_failure_code)) {
            // The claim failure names the property it could not discharge.
            if (std.mem.find(u8, diag.message, @tagName(property)) != null) claim_failures += 1;
        } else if (is_error) {
            return .{ .observed = .no_verdict, .detail = try std.fmt.allocPrint(a, "an error outside the flow codes: {s} {s}", .{ diag.code, diag.message }) };
        } else if (!(is_warning and isBenignWarning(diag.code))) {
            return .{ .observed = .no_verdict, .detail = try std.fmt.allocPrint(a, "an unexpected {s}: {s} {s}", .{ diag.severity, diag.code, diag.message }) };
        }
        if (codes.items.len != 0) try codes.append(a, ',');
        try codes.appendSlice(a, diag.code);
    }
    const holds = claimed(props, property);
    // A probe whose property verdict and whose claim failure disagree did not
    // reach the verdict it appears to have.
    if (holds and claim_failures != 0) {
        return .{ .observed = .no_verdict, .detail = "the property holds, yet a claim failure names it" };
    }
    if (!holds and claim_failures == 0) {
        return .{ .observed = .no_verdict, .detail = "the property is false, yet no claim failure names it" };
    }
    const detail = try codes.toOwnedSlice(a);
    if (holds) return .{ .observed = .held, .detail = detail };
    return .{ .observed = if (flow_codes != 0) .refused else .unproven, .detail = detail };
}

pub fn outcomeOf(expect: Expect, observed: Observed) Outcome {
    return switch (observed) {
        .no_verdict => .no_verdict,
        .held => switch (expect) {
            .hold => .match,
            .refuse, .refuse_or_unprove => .fail_open,
        },
        .refused => switch (expect) {
            .refuse, .refuse_or_unprove => .match,
            .hold => .over_refusal,
        },
        .unproven => switch (expect) {
            .refuse => .weak,
            .refuse_or_unprove => .match,
            .hold => .over_refusal,
        },
    };
}

// ---------------------------------------------------------------------------
// The allowlist.
// ---------------------------------------------------------------------------

pub const AllowRow = struct {
    probe: []const u8,
    outcome: []const u8,
    mechanism: []const u8,
    line: usize,
};

/// Parse `PROBE OUTCOME MECHANISM [note...]` rows. A blank line and a line that
/// starts with `#` are skipped. A missing field is the empty string, so the
/// gate can name the row that lacks it.
pub fn parseAllow(a: std.mem.Allocator, text: []const u8) ![]AllowRow {
    var rows: std.ArrayList(AllowRow) = .empty;
    var line_no: usize = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        line_no += 1;
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        var fields = std.mem.tokenizeAny(u8, line, " \t");
        try rows.append(a, .{
            .probe = fields.next() orelse "",
            .outcome = fields.next() orelse "",
            .mechanism = fields.next() orelse "",
            .line = line_no,
        });
    }
    return rows.toOwnedSlice(a);
}

fn mechanismIndex(name: []const u8) ?usize {
    for (mechanisms, 0..) |known, i| {
        if (std.mem.eql(u8, known, name)) return i;
    }
    return null;
}

/// The outcomes a row may carry. `match` needs no row, and `no_verdict` is
/// never explained by a row.
fn rowOutcome(text: []const u8) ?Outcome {
    const outcome = std.meta.stringToEnum(Outcome, text) orelse return null;
    return switch (outcome) {
        .fail_open, .over_refusal, .weak => outcome,
        .match, .no_verdict => null,
    };
}

// ---------------------------------------------------------------------------
// The run.
// ---------------------------------------------------------------------------

fn writeProbeFiles(io: std.Io, scratch: std.Io.Dir, probe: Probe) !void {
    for (probe.files) |file| {
        try scratch.writeFile(io, .{ .sub_path = file.name, .data = file.text });
    }
}

/// Run `probes` and compare every verdict with its expectation. `scratch` is a
/// writable directory whose absolute path is `scratch_path`. The caller owns
/// the returned report.
pub fn runCensus(
    gpa: std.mem.Allocator,
    io: std.Io,
    scratch: std.Io.Dir,
    scratch_path: []const u8,
    probes: []const Probe,
    options: Options,
) !Report {
    var report = Report.init(gpa);
    errdefer report.deinit();
    const a = report.arena.allocator();

    // The floors on the gate's own input come first: every count below means
    // nothing when the census lost an axis.
    report.probes_total = probes.len;
    for (probes) |probe| {
        report.column_probes[probes_mod.columnOf(probe)] += 1;
        report.group_probes[@intFromEnum(probe.group)] += 1;
    }
    if (probes.len < options.floors.total) {
        try report.add(.below_floor, "census", "{d} probe(s), the floor is {d}", .{ probes.len, options.floors.total });
    }
    const group_floors = [group_count]usize{ options.floors.matrix, options.floors.extended, options.floors.hand };
    inline for (std.meta.fields(Group)) |field| {
        const index = @intFromEnum(@field(Group, field.name));
        if (report.group_probes[index] < group_floors[index]) {
            try report.add(.group_below_floor, field.name, "{d} probe(s) in group {s}, the floor is {d}", .{ report.group_probes[index], field.name, group_floors[index] });
        }
    }
    for (0..probes_mod.hand_column) |column| {
        if (report.column_probes[column] < options.floors.per_column) {
            var buf: [64]u8 = undefined;
            const name = probes_mod.columnName(&buf, column);
            try report.add(.column_below_floor, name, "{d} probe(s) in column {s}, the floor is {d}", .{ report.column_probes[column], name, options.floors.per_column });
        }
    }
    var names: std.StringHashMapUnmanaged(usize) = .empty;
    for (probes, 0..) |probe, i| {
        if (names.get(probe.name)) |earlier| {
            try report.add(.duplicate_probe, probe.name, "shares its name with probe {d}", .{earlier});
        } else {
            try names.put(a, probe.name, i);
        }
        if (probe.reason.len == 0) {
            try report.add(.missing_reason, probe.name, "an expectation states why it holds or refuses", .{});
        }
    }

    for (probes, 0..) |probe, i| {
        writeProbeFiles(io, scratch, probe) catch |err| {
            try report.add(.scratch_failed, probe.name, "cannot write the probe files: {s}", .{@errorName(err)});
            continue;
        };
        const path = try std.fs.path.join(a, &.{ scratch_path, probe.files[0].name });
        var result = options.check(gpa, probe.files[0].text, path) catch |err| {
            try report.add(.check_crashed, probe.name, "the check returned error.{s}", .{@errorName(err)});
            continue;
        };
        defer result.deinit(gpa);
        const verdict = try classify(a, &result, probe.property);
        const outcome = outcomeOf(probe.expect, verdict.observed);
        try report.records.append(a, .{ .probe = i, .observed = verdict.observed, .outcome = outcome, .detail = verdict.detail });
        report.column_outcomes[probes_mod.columnOf(probe)][@intFromEnum(outcome)] += 1;
        report.group_outcomes[@intFromEnum(probe.group)][@intFromEnum(outcome)] += 1;
        report.total_outcomes[@intFromEnum(outcome)] += 1;
        if (outcome == .match) {
            switch (probe.expect) {
                .refuse, .refuse_or_unprove => report.matched_refuse[@intFromEnum(probe.group)] += 1,
                .hold => report.matched_hold[@intFromEnum(probe.group)] += 1,
            }
        }
    }

    try checkAllowlist(&report, probes, options.allow_text);
    return report;
}

fn checkAllowlist(report: *Report, probes: []const Probe, allow_text: []const u8) !void {
    const a = report.arena.allocator();
    const rows = try parseAllow(a, allow_text);
    report.rows_read = rows.len;

    var probe_index: std.StringHashMapUnmanaged(usize) = .empty;
    for (probes, 0..) |probe, i| try probe_index.put(a, probe.name, i);
    var outcome_of_probe: std.AutoHashMapUnmanaged(usize, Outcome) = .empty;
    for (report.records.items) |record| try outcome_of_probe.put(a, record.probe, record.outcome);

    var seen: std.StringHashMapUnmanaged(void) = .empty;
    var explained: std.AutoHashMapUnmanaged(usize, void) = .empty;
    for (rows) |row| {
        if (seen.contains(row.probe)) {
            try report.add(.duplicate_row, row.probe, "{s}:{d}: a second row for this probe", .{ allow_path, row.line });
            continue;
        }
        try seen.put(a, row.probe, {});
        const index = probe_index.get(row.probe) orelse {
            try report.add(.unknown_probe_row, row.probe, "{s}:{d}: no probe has this name", .{ allow_path, row.line });
            continue;
        };
        if (row.mechanism.len == 0) {
            try report.add(.empty_mechanism, row.probe, "{s}:{d}: the row names no mechanism", .{ allow_path, row.line });
            continue;
        }
        const mechanism = mechanismIndex(row.mechanism) orelse {
            try report.add(.unknown_mechanism, row.probe, "{s}:{d}: \"{s}\" is not a mechanism of the closed set", .{ allow_path, row.line, row.mechanism });
            continue;
        };
        const carried = rowOutcome(row.outcome) orelse {
            try report.add(.unknown_outcome_row, row.probe, "{s}:{d}: \"{s}\" is not fail_open, over_refusal, or weak", .{ allow_path, row.line, row.outcome });
            continue;
        };
        // A probe that did not run has no outcome; its own failure is reported.
        const observed = outcome_of_probe.get(index) orelse continue;
        if (observed == .match) {
            try report.add(.stale_row, row.probe, "{s}:{d}: the probe now matches its expected verdict; delete the row", .{ allow_path, row.line });
            continue;
        }
        if (observed != carried) {
            try report.add(.wrong_outcome, row.probe, "{s}:{d}: the row says {s}, the probe is now {s}", .{ allow_path, row.line, @tagName(carried), @tagName(observed) });
            continue;
        }
        try explained.put(a, index, {});
        report.mechanism_counts[mechanism] += 1;
        report.allowlisted += 1;
    }

    for (report.records.items) |record| {
        const probe = probes[record.probe];
        switch (record.outcome) {
            .match => {},
            .no_verdict => try report.add(.no_verdict, probe.name, "the probe reached no flow verdict: {s}", .{record.detail}),
            .fail_open, .over_refusal, .weak => {
                if (explained.contains(record.probe) or seen.contains(probe.name)) continue;
                try report.add(.unexplained_mismatch, probe.name, "expected {s}, observed {s} ({s}), outcome {s}; fix the checker, or add a row to {s} that states the mechanism", .{
                    @tagName(probe.expect),
                    @tagName(record.observed),
                    record.detail,
                    @tagName(record.outcome),
                    allow_path,
                });
            },
        }
    }
}

// ---------------------------------------------------------------------------
// Output.
// ---------------------------------------------------------------------------

fn printReport(report: *const Report, probes: []const Probe, options: Options) void {
    if (options.list) {
        for (report.records.items) |record| {
            const probe = probes[record.probe];
            std.debug.print("probe {s} expect={s} observed={s} outcome={s} codes={s}\n", .{
                probe.name, @tagName(probe.expect), @tagName(record.observed), @tagName(record.outcome), record.detail,
            });
        }
    }
    for (report.failures.items) |failure| {
        std.debug.print("FAIL [{s}] {s}: {s}\n", .{ @tagName(failure.kind), failure.path, failure.detail });
    }
    std.debug.print("flow census: columns (probes: match / fail_open / over_refusal / weak / no_verdict)\n", .{});
    for (0..probes_mod.column_count) |column| {
        var buf: [64]u8 = undefined;
        const o = report.column_outcomes[column];
        std.debug.print("  {s:<28} {d:>4}: {d:>3} / {d:>3} / {d:>3} / {d:>3} / {d:>3}\n", .{
            probes_mod.columnName(&buf, column),
            report.column_probes[column],
            o[@intFromEnum(Outcome.match)],
            o[@intFromEnum(Outcome.fail_open)],
            o[@intFromEnum(Outcome.over_refusal)],
            o[@intFromEnum(Outcome.weak)],
            o[@intFromEnum(Outcome.no_verdict)],
        });
    }
    inline for (std.meta.fields(Group)) |field| {
        const g = @intFromEnum(@field(Group, field.name));
        const o = report.group_outcomes[g];
        std.debug.print(
            "flow census: group {s}: {d} probe(s): refused as expected {d}, fail-open {d}, held as expected {d}, over-refusal {d}, weak {d}, no verdict {d}\n",
            .{
                field.name,
                report.group_probes[g],
                report.matched_refuse[g],
                o[@intFromEnum(Outcome.fail_open)],
                report.matched_hold[g],
                o[@intFromEnum(Outcome.over_refusal)],
                o[@intFromEnum(Outcome.weak)],
                o[@intFromEnum(Outcome.no_verdict)],
            },
        );
    }
    const t = report.total_outcomes;
    std.debug.print(
        "flow census: total {d} probe(s): {d} match, {d} fail-open, {d} over-refusal, {d} weak, {d} no verdict; floor {d}\n",
        .{
            report.probes_total,
            t[@intFromEnum(Outcome.match)],
            t[@intFromEnum(Outcome.fail_open)],
            t[@intFromEnum(Outcome.over_refusal)],
            t[@intFromEnum(Outcome.weak)],
            t[@intFromEnum(Outcome.no_verdict)],
            options.floors.total,
        },
    );
    std.debug.print("flow census: {d} allowlist row(s) read, {d} probe(s) carried; by mechanism:", .{ report.rows_read, report.allowlisted });
    for (mechanisms, 0..) |name, i| std.debug.print(" {s}={d}", .{ name, report.mechanism_counts[i] });
    std.debug.print("\n", .{});
}

fn usage() error{InvalidArguments} {
    std.debug.print("usage: flow-census-gate [--list] [--dump DIR]\n", .{});
    return error.InvalidArguments;
}

pub fn main(init: std.process.Init) void {
    run(init) catch |err| {
        if (err != error.CensusFailed and err != error.InvalidArguments) {
            std.debug.print("flow census: {s}\n", .{@errorName(err)});
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
    var list = false;
    var dump: ?[]const u8 = null;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--list")) {
            list = true;
        } else if (std.mem.eql(u8, arg, "--dump")) {
            dump = args.next() orelse return usage();
        } else {
            return usage();
        }
    }

    const allow_text = std.Io.Dir.cwd().readFileAlloc(io, allow_path, gpa, .limited(max_file_bytes)) catch |err| {
        std.debug.print("flow census: cannot read {s}: {s}\n", .{ allow_path, @errorName(err) });
        return error.CensusFailed;
    };
    defer gpa.free(allow_text);

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const probes = try probes_mod.generate(arena.allocator());

    if (dump) |dump_path| {
        try std.Io.Dir.cwd().createDirPath(io, dump_path);
        var dump_dir = try std.Io.Dir.cwd().openDir(io, dump_path, .{});
        defer dump_dir.close(io);
        for (probes) |p| try writeProbeFiles(io, dump_dir, p);
        std.debug.print("flow census: wrote {d} probe(s) to {s}\n", .{ probes.len, dump_path });
        return;
    }

    // The probes go to a fresh directory under TMPDIR, never the working tree.
    const tmp_root = init.environ_map.get("TMPDIR") orelse "/tmp";
    var name_buf: [64]u8 = undefined;
    const stamp: u64 = @intCast(std.Io.Clock.real.now(io).toNanoseconds());
    const work_name = try std.fmt.bufPrint(&name_buf, "zttp-flow-census-{x}", .{stamp});
    const work = try std.fs.path.join(gpa, &.{ tmp_root, work_name });
    defer gpa.free(work);
    try std.Io.Dir.cwd().createDirPath(io, work);
    defer std.Io.Dir.cwd().deleteTree(io, work) catch {};
    var scratch = try std.Io.Dir.cwd().openDir(io, work, .{});
    defer scratch.close(io);
    const real = try scratch.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(real);

    const options: Options = .{ .allow_text = allow_text, .list = list };
    var report = try runCensus(gpa, io, scratch, real, probes, options);
    defer report.deinit();
    printReport(&report, probes, options);
    if (report.failures.items.len != 0) return error.CensusFailed;
}

// ---------------------------------------------------------------------------
// Tests. They run a small synthetic census with a fake check, and a few real
// probes through the real check.
// ---------------------------------------------------------------------------

const testing = std.testing;

const HandlerProperties = @typeInfo(@FieldType(precompile.CheckResult, "properties")).optional.child;

/// A check result that claims the three leak properties as given, with the
/// listed diagnostics. The fake check below builds these from the source.
fn fakeResult(
    gpa: std.mem.Allocator,
    secret: bool,
    credential: bool,
    injection: bool,
    diags: []const [3][]const u8,
) !precompile.CheckResult {
    var result: precompile.CheckResult = .{};
    errdefer result.deinit(gpa);
    result.stages_run.insert(.flow);
    var props = std.mem.zeroes(HandlerProperties);
    props.no_secret_leakage = secret;
    props.no_credential_leakage = credential;
    props.injection_safe = injection;
    result.properties = props;
    for (diags) |d| {
        try result.json_diagnostics.append(gpa, .{
            .code = d[0],
            .severity = d[1],
            .message = d[2],
            .file = "probe.ts",
            .line = 1,
            .column = 1,
            .suggestion = null,
        });
    }
    return result;
}

/// The fake check reads a marker from the source and returns a canned result.
fn fakeCheck(gpa: std.mem.Allocator, source: []const u8, _: []const u8) anyerror!precompile.CheckResult {
    const claim_failure = [_][3][]const u8{
        .{ "ZTS402", "error", "secret data flows into console output" },
        .{ "ZTS500", "error", "declared Proof capsule was not discharged by handler proof (failing spec: no_secret_leakage)" },
    };
    if (std.mem.find(u8, source, "// refused") != null) return fakeResult(gpa, false, true, true, &claim_failure);
    if (std.mem.find(u8, source, "// unproven") != null) {
        return fakeResult(gpa, false, true, true, &.{.{ "ZTS500", "error", "declared Proof capsule was not discharged by handler proof (failing spec: no_secret_leakage)" }});
    }
    if (std.mem.find(u8, source, "// crash") != null) return error.ProbeCrash;
    if (std.mem.find(u8, source, "// type_error") != null) {
        return fakeResult(gpa, true, true, true, &.{.{ "ZTS204", "error", "return type does not match declared return type" }});
    }
    return fakeResult(gpa, true, true, true, &.{.{ "ZTS306", "warning", "imported binding is never used" }});
}

const Tiny = struct {
    name: []const u8,
    marker: []const u8,
    expect: Expect,
    label: probes_mod.Label,
    sink: probes_mod.Sink,
    group: Group = .matrix,
};

fn tinyProbe(a: std.mem.Allocator, t: Tiny) !Probe {
    const files = try a.alloc(probes_mod.SourceFile, 1);
    files[0] = .{
        .name = try std.fmt.allocPrint(a, "{s}.ts", .{t.name}),
        .text = try std.fmt.allocPrint(a, "{s}\n", .{t.marker}),
    };
    return .{
        .name = t.name,
        .group = t.group,
        .label = t.label,
        .sink = t.sink,
        .kind = "tiny",
        .property = .no_secret_leakage,
        .expect = t.expect,
        .reason = "a synthetic expectation",
        .files = files,
    };
}

/// The floors for a census of exactly the probes the test builds.
const tiny_floors: Floors = .{ .total = 1, .matrix = 1, .extended = 0, .hand = 0, .per_column = 0 };

const TinyRun = struct {
    tmp: std.testing.TmpDir,
    path: [:0]u8,
    arena: std.heap.ArenaAllocator,

    fn init() !TinyRun {
        var tmp = testing.tmpDir(.{});
        errdefer tmp.cleanup();
        const path = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
        return .{ .tmp = tmp, .path = path, .arena = std.heap.ArenaAllocator.init(testing.allocator) };
    }

    fn deinit(self: *TinyRun) void {
        self.arena.deinit();
        testing.allocator.free(self.path);
        self.tmp.cleanup();
    }

    fn run(self: *TinyRun, probes: []const Probe, options: Options) !Report {
        return runCensus(testing.allocator, testing.io, self.tmp.dir, self.path, probes, options);
    }
};

fn tinyOptions(allow_text: []const u8) Options {
    return .{ .check = fakeCheck, .allow_text = allow_text, .floors = tiny_floors };
}

const ok_allow = "p_open  fail_open  F1  a hold probe whose property held\n";

/// Build the census the mutation probes start from: one probe of each good
/// shape. `p_ref` is refused as expected, `p_hold` is held as expected, and
/// `p_open` expects a refusal but is held, which the allowlist carries.
fn goodCensus(a: std.mem.Allocator) ![]Probe {
    const probes = try a.alloc(Probe, 3);
    probes[0] = try tinyProbe(a, .{ .name = "p_ref", .marker = "// refused", .expect = .refuse, .label = .secret, .sink = .log });
    probes[1] = try tinyProbe(a, .{ .name = "p_hold", .marker = "// held", .expect = .hold, .label = .clean, .sink = .log });
    probes[2] = try tinyProbe(a, .{ .name = "p_open", .marker = "// held", .expect = .refuse, .label = .secret, .sink = .egress_body });
    return probes;
}

fn expectFailureAt(report: *const Report, kind: FailureKind, path: []const u8) !void {
    for (report.failures.items) |failure| {
        if (failure.kind == kind and std.mem.eql(u8, failure.path, path)) return;
    }
    for (report.failures.items) |failure| {
        std.debug.print("got [{s}] {s}: {s}\n", .{ @tagName(failure.kind), failure.path, failure.detail });
    }
    std.debug.print("expected [{s}] at {s} and did not find it\n", .{ @tagName(kind), path });
    return error.ProbeNotRejected;
}

/// Apply one mutation to a good census and require the gate to name the
/// failure it should. Every `FailureKind` is a case of the switch, so a new
/// kind does not compile until it has a probe.
fn mutate(kind: FailureKind) !void {
    var env = try TinyRun.init();
    defer env.deinit();
    const a = env.arena.allocator();
    const good = try goodCensus(a);

    // The unmutated census passes, so a failure below comes from the mutation.
    {
        var clean = try env.run(good, tinyOptions(ok_allow));
        defer clean.deinit();
        for (clean.failures.items) |failure| {
            std.debug.print("clean failure [{s}] {s}: {s}\n", .{ @tagName(failure.kind), failure.path, failure.detail });
        }
        try testing.expectEqual(@as(usize, 0), clean.failures.items.len);
        try testing.expectEqual(@as(usize, 1), clean.allowlisted);
    }

    switch (kind) {
        .below_floor => {
            var options = tinyOptions(ok_allow);
            options.floors.total = good.len + 1;
            var report = try env.run(good, options);
            defer report.deinit();
            try expectFailureAt(&report, kind, "census");
        },
        .group_below_floor => {
            var options = tinyOptions(ok_allow);
            options.floors.extended = 1;
            var report = try env.run(good, options);
            defer report.deinit();
            try expectFailureAt(&report, kind, "extended");
        },
        .column_below_floor => {
            var options = tinyOptions(ok_allow);
            options.floors.per_column = 1;
            var report = try env.run(good, options);
            defer report.deinit();
            try testing.expect(report.has(kind));
        },
        .duplicate_probe => {
            const doubled = try a.alloc(Probe, good.len + 1);
            @memcpy(doubled[0..good.len], good);
            doubled[good.len] = good[0];
            var report = try env.run(doubled, tinyOptions(ok_allow));
            defer report.deinit();
            try expectFailureAt(&report, kind, "p_ref");
        },
        .missing_reason => {
            const changed = try a.dupe(Probe, good);
            changed[1].reason = "";
            var report = try env.run(changed, tinyOptions(ok_allow));
            defer report.deinit();
            try expectFailureAt(&report, kind, "p_hold");
        },
        .scratch_failed => {
            // A file name inside a directory that does not exist cannot be written.
            const changed = try a.dupe(Probe, good);
            const files = try a.dupe(probes_mod.SourceFile, good[0].files);
            files[0].name = "no_such_dir/p_ref.ts";
            changed[0].files = files;
            var report = try env.run(changed, tinyOptions(ok_allow));
            defer report.deinit();
            try expectFailureAt(&report, kind, "p_ref");
        },
        .check_crashed => {
            const changed = try a.dupe(Probe, good);
            changed[1] = try tinyProbe(a, .{ .name = "p_hold", .marker = "// crash", .expect = .hold, .label = .clean, .sink = .log });
            var report = try env.run(changed, tinyOptions(ok_allow));
            defer report.deinit();
            try expectFailureAt(&report, kind, "p_hold");
        },
        .no_verdict => {
            // A type error is not a refusal of the leak: the probe must fail.
            const changed = try a.dupe(Probe, good);
            changed[0] = try tinyProbe(a, .{ .name = "p_ref", .marker = "// type_error", .expect = .refuse, .label = .secret, .sink = .log });
            var report = try env.run(changed, tinyOptions(ok_allow));
            defer report.deinit();
            try expectFailureAt(&report, kind, "p_ref");
        },
        .unexplained_mismatch => {
            var report = try env.run(good, tinyOptions(""));
            defer report.deinit();
            try expectFailureAt(&report, kind, "p_open");
        },
        .wrong_outcome => {
            // The probe is a fail_open, and the row says it is over-refused.
            var report = try env.run(good, tinyOptions("p_open over_refusal F1\n"));
            defer report.deinit();
            try expectFailureAt(&report, kind, "p_open");
        },
        .stale_row => {
            // p_hold matches its expectation, so a row for it is stale.
            var report = try env.run(good, tinyOptions(ok_allow ++ "p_hold fail_open F1\n"));
            defer report.deinit();
            try expectFailureAt(&report, kind, "p_hold");
        },
        .unknown_probe_row => {
            var report = try env.run(good, tinyOptions(ok_allow ++ "p_missing fail_open F1\n"));
            defer report.deinit();
            try expectFailureAt(&report, kind, "p_missing");
        },
        .duplicate_row => {
            var report = try env.run(good, tinyOptions(ok_allow ++ "p_open fail_open F1\n"));
            defer report.deinit();
            try expectFailureAt(&report, kind, "p_open");
        },
        .empty_mechanism => {
            var report = try env.run(good, tinyOptions("p_open fail_open\n"));
            defer report.deinit();
            try expectFailureAt(&report, kind, "p_open");
        },
        .unknown_mechanism => {
            var report = try env.run(good, tinyOptions("p_open fail_open F99\n"));
            defer report.deinit();
            try expectFailureAt(&report, kind, "p_open");
        },
        .unknown_outcome_row => {
            var report = try env.run(good, tinyOptions("p_open nonsense F1\n"));
            defer report.deinit();
            try expectFailureAt(&report, kind, "p_open");
        },
    }
}

test "every failure kind is probed and rejected" {
    inline for (std.meta.fields(FailureKind)) |field| {
        mutate(@field(FailureKind, field.name)) catch |err| {
            std.debug.print("probe for {s} failed: {s}\n", .{ field.name, @errorName(err) });
            return err;
        };
    }
}

test "every row outcome that is not a match needs a mechanism, and a row cannot explain no_verdict" {
    // `no_verdict` is an outcome that no row may carry; a `match` needs no row.
    try testing.expect(rowOutcome("no_verdict") == null);
    try testing.expect(rowOutcome("match") == null);
    try testing.expectEqual(Outcome.fail_open, rowOutcome("fail_open").?);
    try testing.expectEqual(Outcome.over_refusal, rowOutcome("over_refusal").?);
    try testing.expectEqual(Outcome.weak, rowOutcome("weak").?);
}

test "the outcome of every expected and observed pair is the one written here" {
    // The census of the comparison: three expectations by four observations.
    const table = [_]struct { Expect, Observed, Outcome }{
        .{ .refuse, .refused, .match },
        .{ .refuse, .unproven, .weak },
        .{ .refuse, .held, .fail_open },
        .{ .refuse, .no_verdict, .no_verdict },
        .{ .refuse_or_unprove, .refused, .match },
        .{ .refuse_or_unprove, .unproven, .match },
        .{ .refuse_or_unprove, .held, .fail_open },
        .{ .refuse_or_unprove, .no_verdict, .no_verdict },
        .{ .hold, .refused, .over_refusal },
        .{ .hold, .unproven, .over_refusal },
        .{ .hold, .held, .match },
        .{ .hold, .no_verdict, .no_verdict },
    };
    try testing.expectEqual(std.meta.fields(Expect).len * std.meta.fields(Observed).len, table.len);
    for (table) |row| try testing.expectEqual(row[2], outcomeOf(row[0], row[1]));
}

test "a synthetic census produces every outcome and every observed class" {
    var env = try TinyRun.init();
    defer env.deinit();
    const a = env.arena.allocator();
    const probes = [_]Probe{
        try tinyProbe(a, .{ .name = "match_ref", .marker = "// refused", .expect = .refuse, .label = .secret, .sink = .log }),
        try tinyProbe(a, .{ .name = "weak_one", .marker = "// unproven", .expect = .refuse, .label = .secret, .sink = .log }),
        try tinyProbe(a, .{ .name = "fail_open_one", .marker = "// held", .expect = .refuse, .label = .secret, .sink = .log }),
        try tinyProbe(a, .{ .name = "over_one", .marker = "// refused", .expect = .hold, .label = .secret, .sink = .log }),
        try tinyProbe(a, .{ .name = "no_verdict_one", .marker = "// type_error", .expect = .hold, .label = .secret, .sink = .log }),
    };
    const allow =
        "weak_one weak F1\n" ++
        "fail_open_one fail_open F1\n" ++
        "over_one over_refusal F4\n";
    var report = try env.run(&probes, tinyOptions(allow));
    defer report.deinit();
    try testing.expectEqual(@as(usize, 1), report.total_outcomes[@intFromEnum(Outcome.match)]);
    try testing.expectEqual(@as(usize, 1), report.total_outcomes[@intFromEnum(Outcome.weak)]);
    try testing.expectEqual(@as(usize, 1), report.total_outcomes[@intFromEnum(Outcome.fail_open)]);
    try testing.expectEqual(@as(usize, 1), report.total_outcomes[@intFromEnum(Outcome.over_refusal)]);
    try testing.expectEqual(@as(usize, 1), report.total_outcomes[@intFromEnum(Outcome.no_verdict)]);
    try testing.expectEqual(@as(usize, 3), report.allowlisted);
    // The only failure is the probe with no verdict.
    try testing.expectEqual(@as(usize, 1), report.failures.items.len);
    try testing.expect(report.has(.no_verdict));
    // The counts per column sum to the probes in it.
    const column = probes_mod.columnOf(probes[0]);
    var sum: usize = 0;
    for (report.column_outcomes[column]) |n| sum += n;
    try testing.expectEqual(report.column_probes[column], sum);
}

test "classify reads the claimed property and only that one" {
    // The credential property is false and the secret property holds. A
    // secret-claiming probe must read as held, a credential-claiming probe as
    // refused, whatever the neighbour says.
    var result = try fakeResult(testing.allocator, true, false, true, &.{
        .{ "ZTS405", "error", "credential data flows into an egress URL" },
        .{ "ZTS500", "error", "declared Proof capsule was not discharged by handler proof (failing spec: no_credential_leakage)" },
    });
    defer result.deinit(testing.allocator);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const secret = try classify(arena.allocator(), &result, .no_secret_leakage);
    // The claim failure names the credential property, not the secret one, yet
    // the secret property holds, so the claim failure is not about this probe.
    try testing.expectEqual(Observed.held, secret.observed);
    const credential = try classify(arena.allocator(), &result, .no_credential_leakage);
    try testing.expectEqual(Observed.refused, credential.observed);
}

test "classify gives no verdict when the property and its claim failure disagree" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    // False, with no claim failure naming it.
    var no_claim = try fakeResult(testing.allocator, false, true, true, &.{});
    defer no_claim.deinit(testing.allocator);
    try testing.expectEqual(Observed.no_verdict, (try classify(arena.allocator(), &no_claim, .no_secret_leakage)).observed);
    // True, with a claim failure naming it.
    var phantom = try fakeResult(testing.allocator, true, true, true, &.{
        .{ "ZTS500", "error", "declared Proof capsule was not discharged by handler proof (failing spec: no_secret_leakage)" },
    });
    defer phantom.deinit(testing.allocator);
    try testing.expectEqual(Observed.no_verdict, (try classify(arena.allocator(), &phantom, .no_secret_leakage)).observed);
    // A result with no flow stage, and one with no contract.
    var no_flow = try fakeResult(testing.allocator, true, true, true, &.{});
    defer no_flow.deinit(testing.allocator);
    no_flow.stages_run = precompile.StageSet.initEmpty();
    try testing.expectEqual(Observed.no_verdict, (try classify(arena.allocator(), &no_flow, .no_secret_leakage)).observed);
    var no_contract = try fakeResult(testing.allocator, true, true, true, &.{});
    defer no_contract.deinit(testing.allocator);
    no_contract.properties = null;
    try testing.expectEqual(Observed.no_verdict, (try classify(arena.allocator(), &no_contract, .no_secret_leakage)).observed);
    // An unknown warning is not benign.
    var odd = try fakeResult(testing.allocator, true, true, true, &.{.{ "ZTS999", "warning", "something new" }});
    defer odd.deinit(testing.allocator);
    try testing.expectEqual(Observed.no_verdict, (try classify(arena.allocator(), &odd, .no_secret_leakage)).observed);
}

test "allowlist rows parse probe, outcome, mechanism and note" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const rows = try parseAllow(arena.allocator(), "# note\n\na__b__c fail_open F1 the note\n  d weak\ne\n");
    try testing.expectEqual(@as(usize, 3), rows.len);
    try testing.expectEqualStrings("a__b__c", rows[0].probe);
    try testing.expectEqualStrings("fail_open", rows[0].outcome);
    try testing.expectEqualStrings("F1", rows[0].mechanism);
    try testing.expectEqualStrings("weak", rows[1].outcome);
    try testing.expectEqualStrings("", rows[1].mechanism);
    try testing.expectEqualStrings("", rows[2].outcome);
    try testing.expectEqual(@as(usize, 5), rows[2].line);
}

// The real check, on three probes: a leak the handler body refuses, a clean
// control, and an import probe. The real check reads files, so the imported
// library goes to the scratch directory first.

fn realVerdict(env: *TinyRun, p: Probe) !Observed {
    try writeProbeFiles(testing.io, env.tmp.dir, p);
    const a = env.arena.allocator();
    const path = try std.fs.path.join(a, &.{ env.path, p.files[0].name });
    var result = try defaultCheck(testing.allocator, p.files[0].text, path);
    defer result.deinit(testing.allocator);
    return (try classify(a, &result, p.property)).observed;
}

fn findProbe(probes: []const Probe, name: []const u8) !Probe {
    for (probes) |p| if (std.mem.eql(u8, p.name, name)) return p;
    std.debug.print("no probe named {s}\n", .{name});
    return error.ProbeNotFound;
}

test "the real check refuses a secret in a handler-body log and holds a clean control" {
    var env = try TinyRun.init();
    defer env.deinit();
    const probes = try probes_mod.generate(env.arena.allocator());
    try testing.expectEqual(Observed.refused, try realVerdict(&env, try findProbe(probes, "secret__log__handler")));
    try testing.expectEqual(Observed.held, try realVerdict(&env, try findProbe(probes, "clean__log__handler")));
}

test "the real check reaches a verdict on an import probe" {
    var env = try TinyRun.init();
    defer env.deinit();
    const probes = try probes_mod.generate(env.arena.allocator());
    const p = try findProbe(probes, "secret__log__import_fn");
    try testing.expect(p.files.len == 2);
    try testing.expect((try realVerdict(&env, p)) != Observed.no_verdict);
}

test "the committed census clears its floors and every expectation states a reason" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const probes = try probes_mod.generate(arena.allocator());
    var by_group: [group_count]usize = @splat(0);
    var by_column: [probes_mod.column_count]usize = @splat(0);
    for (probes) |p| {
        try testing.expect(p.reason.len != 0);
        by_group[@intFromEnum(p.group)] += 1;
        by_column[probes_mod.columnOf(p)] += 1;
    }
    try testing.expect(probes.len >= committed_floors.total);
    try testing.expect(by_group[@intFromEnum(Group.matrix)] >= committed_floors.matrix);
    try testing.expect(by_group[@intFromEnum(Group.extended)] >= committed_floors.extended);
    try testing.expect(by_group[@intFromEnum(Group.hand)] >= committed_floors.hand);
    for (by_column[0..probes_mod.hand_column]) |n| try testing.expect(n >= committed_floors.per_column);
}
