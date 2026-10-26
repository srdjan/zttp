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
//! The expected verdict is `refuse`, `refuse_or_unprove`, `hold`, or
//! `hold_or_unprove`. The outcome of the comparison is `match`, `fail_open` (expected a refusal, the
//! property held), `over_refusal` (expected a hold, got a refusal or an
//! unproven property), `weak` (expected a refusal, got only an unproven
//! property), or `no_verdict`.
//!
//! A probe whose observed outcome is not `match` fails the gate. No allowlist
//! carries a mismatch: fix the checker or correct the expectation.
//!
//! What this gate refuses, each as a named `FailureKind`:
//!   * a probe with no verdict (a parse or type error, a missing flow stage,
//!     an error outside the flow codes, a claim failure that disagrees with
//!     the property), or a check that crashed;
//!   * a probe whose outcome is `fail_open`, `over_refusal`, or `weak`;
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
//! The check reads no `zttp.json`.
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

pub const Observed = enum { refused, unproven, held, no_verdict };

pub const Outcome = enum { match, fail_open, over_refusal, weak, no_verdict };

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
};

pub const Failure = struct {
    kind: FailureKind,
    path: []const u8,
    detail: []const u8,
};

pub const CheckFn = *const fn (gpa: std.mem.Allocator, source: []const u8, handler_path: []const u8) anyerror!precompile.CheckResult;

/// The policy every census probe runs under. `API_TOKEN` stays secret and
/// `REGION` is the one name the policy vouches for (D-014): without the
/// `public` row the clean source `env("REGION") ?? ""` would be a secret.
pub const census_policy_source =
    \\{"env":{"allow":["API_TOKEN","REGION"],"public":["REGION"]}}
;

/// The same call `zts check --json` makes with the census policy and no
/// declaration or schema path.
fn defaultCheck(gpa: std.mem.Allocator, source: []const u8, handler_path: []const u8) anyerror!precompile.CheckResult {
    return precompile.runCheckOnlyFromSourceWithOptions(gpa, source, handler_path, .{
        .json_mode = true,
        .policy_source = census_policy_source,
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
    floors: Floors = committed_floors,
    /// Print one line per probe.
    list: bool = false,
};

const outcome_count = @typeInfo(Outcome).@"enum".field_names.len;
const group_count = @typeInfo(Group).@"enum".field_names.len;

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
            .detail = try a.print(fmt, args),
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
    return code[5] >= '0' and code[5] <= '8';
}

/// The flow codes that witness `property` (`propertyTagForKind` in
/// flow_checker.zig). A refusal counts only when one of these says why, so a
/// credential probe falsified through ZTS407 alone is not read as a refusal
/// of the credential leak.
fn witnessesProperty(code: []const u8, property: Property) bool {
    const witnesses: []const []const u8 = switch (property) {
        .no_secret_leakage => &.{ "ZTS400", "ZTS402", "ZTS404", "ZTS406" },
        .no_credential_leakage => &.{ "ZTS401", "ZTS403", "ZTS405", "ZTS408" },
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
            return .{ .observed = .no_verdict, .detail = try a.print("an error outside the flow codes: {s} {s}", .{ diag.code, diag.message }) };
        } else if (!(is_warning and isBenignWarning(diag.code))) {
            return .{ .observed = .no_verdict, .detail = try a.print("an unexpected {s}: {s} {s}", .{ diag.severity, diag.code, diag.message }) };
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
            .hold, .hold_or_unprove => .match,
            .refuse, .refuse_or_unprove => .fail_open,
        },
        .refused => switch (expect) {
            .refuse, .refuse_or_unprove => .match,
            .hold, .hold_or_unprove => .over_refusal,
        },
        .unproven => switch (expect) {
            .refuse => .weak,
            .refuse_or_unprove, .hold_or_unprove => .match,
            .hold => .over_refusal,
        },
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
        report.group_probes[@backingInt(probe.group)] += 1;
    }
    if (probes.len < options.floors.total) {
        try report.add(.below_floor, "census", "{d} probe(s), the floor is {d}", .{ probes.len, options.floors.total });
    }
    const group_floors = [group_count]usize{ options.floors.matrix, options.floors.extended, options.floors.hand };
    inline for (@typeInfo(Group).@"enum".field_names) |field| {
        const index = @backingInt(@field(Group, field));
        if (report.group_probes[index] < group_floors[index]) {
            try report.add(.group_below_floor, field, "{d} probe(s) in group {s}, the floor is {d}", .{ report.group_probes[index], field, group_floors[index] });
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
        report.column_outcomes[probes_mod.columnOf(probe)][@backingInt(outcome)] += 1;
        report.group_outcomes[@backingInt(probe.group)][@backingInt(outcome)] += 1;
        report.total_outcomes[@backingInt(outcome)] += 1;
        if (outcome == .match) {
            switch (probe.expect) {
                .refuse, .refuse_or_unprove => report.matched_refuse[@backingInt(probe.group)] += 1,
                .hold, .hold_or_unprove => report.matched_hold[@backingInt(probe.group)] += 1,
            }
        }
    }

    try checkOutcomes(&report, probes);
    return report;
}

fn checkOutcomes(report: *Report, probes: []const Probe) !void {
    for (report.records.items) |record| {
        const probe = probes[record.probe];
        switch (record.outcome) {
            .match => {},
            .no_verdict => try report.add(.no_verdict, probe.name, "the probe reached no flow verdict: {s}", .{record.detail}),
            .fail_open, .over_refusal, .weak => try report.add(.unexplained_mismatch, probe.name, "expected {s}, observed {s} ({s}), outcome {s}; fix the checker or the expectation", .{
                @tagName(probe.expect),
                @tagName(record.observed),
                record.detail,
                @tagName(record.outcome),
            }),
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
            o[@backingInt(Outcome.match)],
            o[@backingInt(Outcome.fail_open)],
            o[@backingInt(Outcome.over_refusal)],
            o[@backingInt(Outcome.weak)],
            o[@backingInt(Outcome.no_verdict)],
        });
    }
    inline for (@typeInfo(Group).@"enum".field_names) |field| {
        const g = @backingInt(@field(Group, field));
        const o = report.group_outcomes[g];
        std.debug.print(
            "flow census: group {s}: {d} probe(s): refused as expected {d}, fail-open {d}, held as expected {d}, over-refusal {d}, weak {d}, no verdict {d}\n",
            .{
                field,
                report.group_probes[g],
                report.matched_refuse[g],
                o[@backingInt(Outcome.fail_open)],
                report.matched_hold[g],
                o[@backingInt(Outcome.over_refusal)],
                o[@backingInt(Outcome.weak)],
                o[@backingInt(Outcome.no_verdict)],
            },
        );
    }
    const t = report.total_outcomes;
    std.debug.print(
        "flow census: total {d} probe(s): {d} match, {d} fail-open, {d} over-refusal, {d} weak, {d} no verdict; floor {d}\n",
        .{
            report.probes_total,
            t[@backingInt(Outcome.match)],
            t[@backingInt(Outcome.fail_open)],
            t[@backingInt(Outcome.over_refusal)],
            t[@backingInt(Outcome.weak)],
            t[@backingInt(Outcome.no_verdict)],
            options.floors.total,
        },
    );
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

    const options: Options = .{ .list = list };
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
        .name = try a.print("{s}.ts", .{t.name}),
        .text = try a.print("{s}\n", .{t.marker}),
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

fn tinyOptions() Options {
    return .{ .check = fakeCheck, .floors = tiny_floors };
}

/// Build the census the mutation probes start from: one probe of each good
/// shape. `p_ref` is refused as expected and `p_hold` is held as expected.
fn goodCensus(a: std.mem.Allocator) ![]Probe {
    const probes = try a.alloc(Probe, 2);
    probes[0] = try tinyProbe(a, .{ .name = "p_ref", .marker = "// refused", .expect = .refuse, .label = .secret, .sink = .log });
    probes[1] = try tinyProbe(a, .{ .name = "p_hold", .marker = "// held", .expect = .hold, .label = .clean, .sink = .log });
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
        var clean = try env.run(good, tinyOptions());
        defer clean.deinit();
        for (clean.failures.items) |failure| {
            std.debug.print("clean failure [{s}] {s}: {s}\n", .{ @tagName(failure.kind), failure.path, failure.detail });
        }
        try testing.expectEqual(@as(usize, 0), clean.failures.items.len);
    }

    switch (kind) {
        .below_floor => {
            var options = tinyOptions();
            options.floors.total = good.len + 1;
            var report = try env.run(good, options);
            defer report.deinit();
            try expectFailureAt(&report, kind, "census");
        },
        .group_below_floor => {
            var options = tinyOptions();
            options.floors.extended = 1;
            var report = try env.run(good, options);
            defer report.deinit();
            try expectFailureAt(&report, kind, "extended");
        },
        .column_below_floor => {
            var options = tinyOptions();
            options.floors.per_column = 1;
            var report = try env.run(good, options);
            defer report.deinit();
            try testing.expect(report.has(kind));
        },
        .duplicate_probe => {
            const doubled = try a.alloc(Probe, good.len + 1);
            @memcpy(doubled[0..good.len], good);
            doubled[good.len] = good[0];
            var report = try env.run(doubled, tinyOptions());
            defer report.deinit();
            try expectFailureAt(&report, kind, "p_ref");
        },
        .missing_reason => {
            const changed = try a.dupe(Probe, good);
            changed[1].reason = "";
            var report = try env.run(changed, tinyOptions());
            defer report.deinit();
            try expectFailureAt(&report, kind, "p_hold");
        },
        .scratch_failed => {
            // A file name inside a directory that does not exist cannot be written.
            const changed = try a.dupe(Probe, good);
            const files = try a.dupe(probes_mod.SourceFile, good[0].files);
            files[0].name = "no_such_dir/p_ref.ts";
            changed[0].files = files;
            var report = try env.run(changed, tinyOptions());
            defer report.deinit();
            try expectFailureAt(&report, kind, "p_ref");
        },
        .check_crashed => {
            const changed = try a.dupe(Probe, good);
            changed[1] = try tinyProbe(a, .{ .name = "p_hold", .marker = "// crash", .expect = .hold, .label = .clean, .sink = .log });
            var report = try env.run(changed, tinyOptions());
            defer report.deinit();
            try expectFailureAt(&report, kind, "p_hold");
        },
        .no_verdict => {
            // A type error is not a refusal of the leak: the probe must fail.
            const changed = try a.dupe(Probe, good);
            changed[0] = try tinyProbe(a, .{ .name = "p_ref", .marker = "// type_error", .expect = .refuse, .label = .secret, .sink = .log });
            var report = try env.run(changed, tinyOptions());
            defer report.deinit();
            try expectFailureAt(&report, kind, "p_ref");
        },
        .unexplained_mismatch => {
            // p_hold is held, so expecting a refusal makes it a fail_open.
            const changed = try a.dupe(Probe, good);
            changed[1] = try tinyProbe(a, .{ .name = "p_hold", .marker = "// held", .expect = .refuse, .label = .clean, .sink = .log });
            var report = try env.run(changed, tinyOptions());
            defer report.deinit();
            try expectFailureAt(&report, kind, "p_hold");
        },
    }
}

test "every failure kind is probed and rejected" {
    inline for (@typeInfo(FailureKind).@"enum".field_names) |field| {
        mutate(@field(FailureKind, field)) catch |err| {
            std.debug.print("probe for {s} failed: {s}\n", .{ field, @errorName(err) });
            return err;
        };
    }
}

test "the outcome of every expected and observed pair is the one written here" {
    // The census of the comparison: four expectations by four observations.
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
        .{ .hold_or_unprove, .refused, .over_refusal },
        .{ .hold_or_unprove, .unproven, .match },
        .{ .hold_or_unprove, .held, .match },
        .{ .hold_or_unprove, .no_verdict, .no_verdict },
    };
    try testing.expectEqual(@typeInfo(Expect).@"enum".field_names.len * @typeInfo(Observed).@"enum".field_names.len, table.len);
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
    var report = try env.run(&probes, tinyOptions());
    defer report.deinit();
    try testing.expectEqual(@as(usize, 1), report.total_outcomes[@backingInt(Outcome.match)]);
    try testing.expectEqual(@as(usize, 1), report.total_outcomes[@backingInt(Outcome.weak)]);
    try testing.expectEqual(@as(usize, 1), report.total_outcomes[@backingInt(Outcome.fail_open)]);
    try testing.expectEqual(@as(usize, 1), report.total_outcomes[@backingInt(Outcome.over_refusal)]);
    try testing.expectEqual(@as(usize, 1), report.total_outcomes[@backingInt(Outcome.no_verdict)]);
    // Three mismatches and one probe with no verdict each fail.
    try testing.expectEqual(@as(usize, 4), report.failures.items.len);
    try testing.expect(report.has(.no_verdict));
    try testing.expect(report.has(.unexplained_mismatch));
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
    no_flow.stages_run = precompile.StageSet.empty;
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
        by_group[@backingInt(p.group)] += 1;
        by_column[probes_mod.columnOf(p)] += 1;
    }
    try testing.expect(probes.len >= committed_floors.total);
    try testing.expect(by_group[@backingInt(Group.matrix)] >= committed_floors.matrix);
    try testing.expect(by_group[@backingInt(Group.extended)] >= committed_floors.extended);
    try testing.expect(by_group[@backingInt(Group.hand)] >= committed_floors.hand);
    for (by_column[0..probes_mod.hand_column]) |n| try testing.expect(n >= committed_floors.per_column);
}
