//! Native benchmark sampling, comparison, and baseline recording.

const std = @import("std");
const builtin = @import("builtin");
const zts = @import("zts");

const default_run_count: usize = 5;
const default_regression_pct: f64 = 8.0;
const default_geomean_pct: f64 = 3.0;
const max_report_bytes = 8 * 1024 * 1024;

const skipped_benchmarks = [_][]const u8{
    "forOfLoop",
    "httpHandler",
    "httpHandlerHeavy",
    "stringConcat",
};

const Perf = struct {
    backedge_count: u64 = 0,
    pic_hits: u64 = 0,
    pic_misses: u64 = 0,
    mega_recoveries: u64 = 0,
    opcode_histogram_enabled: bool = false,
    opcode_histogram_nonzero: u64 = 0,
};

const OptStats = struct {
    get_loc_add_count: u64 = 0,
    get_loc_get_loc_add_count: u64 = 0,
    push_const_call_count: u64 = 0,
    get_field_call_count: u64 = 0,
    if_false_goto_count: u64 = 0,
    drop_goto_count: u64 = 0,
    bytes_saved: u64 = 0,
    dispatches_saved: u64 = 0,
    total_fusions: u64 = 0,
};

const Benchmark = struct {
    name: []const u8,
    iterations: u64 = 0,
    success: bool,
    time_ms: f64 = 0,
    ops_per_sec: f64,
    @"error": ?[]const u8 = null,
    perf: ?Perf = null,
    opt_stats: ?OptStats = null,
};

const Report = struct {
    schema_version: u64 = 1,
    benchmarks: []Benchmark,
};

const Comparison = struct {
    count: usize,
    geomean: f64,
    regression_pct: f64,
};

const Regression = struct {
    name: []const u8,
    current_ops: f64,
    baseline_ops: f64,
    regression_pct: f64,
};

const ComparisonDecision = union(enum) {
    pass: Comparison,
    individual_regression: Regression,
    geomean_regression: Comparison,
};

const CheckDefaults = struct {
    runs: usize = default_run_count,
    regression_pct: f64 = default_regression_pct,
    geomean_pct: f64 = default_geomean_pct,
};

const CheckOptions = struct {
    baseline: []const u8,
    bench: []const u8,
    runs: usize = default_run_count,
    regression_pct: f64 = default_regression_pct,
    geomean_pct: f64 = default_geomean_pct,
};

const RecordOptions = struct {
    baseline: []const u8,
    bench: []const u8,
    zig: []const u8 = "zig",
    runs: usize = default_run_count,
};

const Mode = union(enum) {
    check: CheckOptions,
    record: RecordOptions,
};

const SampleCapability = struct {
    context: ?*anyopaque,
    run: *const fn (?*anyopaque, std.mem.Allocator, std.Io, []const u8) anyerror![]u8,
};

const usage =
    \\Usage:
    \\  zttp-benchmark check --baseline FILE --bench FILE [--runs N]
    \\                       [--regression-pct N] [--geomean-pct N]
    \\  zttp-benchmark record --baseline FILE --bench FILE [--zig FILE] [--runs N]
    \\
;

pub fn main(init: std.process.Init.Minimal) !void {
    var debug_alloc: std.heap.DebugAllocator(.{}) = .init;
    defer _ = debug_alloc.deinit();
    const allocator = debug_alloc.allocator();

    const argv = try collectArgs(allocator, init.args);
    defer freeArgs(allocator, argv);
    var environ = try std.process.Environ.createMap(init.environ, allocator);
    defer environ.deinit();
    const defaults = checkDefaultsFromEnvironment(environ) catch |err| {
        std.debug.print("error: invalid benchmark environment: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
    const mode = parseArgsWithDefaults(argv[1..], defaults) catch |err| {
        std.debug.print("error: {s}\n\n{s}", .{ @errorName(err), usage });
        std.process.exit(1);
    };

    var io_backend = std.Io.Threaded.init(allocator, .{ .environ = init.environ });
    defer io_backend.deinit();
    run(allocator, io_backend.io(), mode) catch |err| {
        std.debug.print("error: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
}

fn run(allocator: std.mem.Allocator, io: std.Io, mode: Mode) !void {
    switch (mode) {
        .check => |opts| {
            var arena_state = std.heap.ArenaAllocator.init(allocator);
            defer arena_state.deinit();
            const arena = arena_state.allocator();
            const baseline = try loadBaseline(arena, opts.baseline);
            const current = try sampleBenchmarks(arena, io, opts.bench, opts.runs, .{
                .context = null,
                .run = runBenchmark,
            });
            const decision = try compareReports(
                current,
                baseline,
                opts.regression_pct,
                opts.geomean_pct,
            );
            switch (decision) {
                .pass => |comparison| std.debug.print(
                    "bench-check ok: compared {d} benchmarks, geomean={d:.5}, regression={d:.2}%\n",
                    .{ comparison.count, comparison.geomean, comparison.regression_pct },
                ),
                .individual_regression => |regression| {
                    std.debug.print(
                        "benchmark regression >{d}%: {s} current={d:.0} baseline={d:.0} regression={d:.2}%\n",
                        .{
                            opts.regression_pct,
                            regression.name,
                            regression.current_ops,
                            regression.baseline_ops,
                            regression.regression_pct,
                        },
                    );
                    return error.IndividualRegression;
                },
                .geomean_regression => |comparison| {
                    std.debug.print(
                        "geomean regression >{d}%: geomean={d:.5} regression={d:.2}%\n",
                        .{ opts.geomean_pct, comparison.geomean, comparison.regression_pct },
                    );
                    return error.GeomeanRegression;
                },
            }
        },
        .record => |opts| try recordBaseline(allocator, io, opts),
    }
}

fn parseArgs(args: []const []const u8) !Mode {
    return parseArgsWithDefaults(args, .{});
}

fn parseArgsWithDefaults(args: []const []const u8, defaults: CheckDefaults) !Mode {
    if (args.len == 0) return error.InvalidArgument;
    if (std.mem.eql(u8, args[0], "check")) {
        var baseline: ?[]const u8 = null;
        var bench: ?[]const u8 = null;
        var runs = defaults.runs;
        var regression_pct = defaults.regression_pct;
        var geomean_pct = defaults.geomean_pct;
        var i: usize = 1;
        while (i < args.len) : (i += 1) {
            const flag = args[i];
            const value = try nextValue(args, &i);
            if (std.mem.eql(u8, flag, "--baseline")) baseline = value else if (std.mem.eql(u8, flag, "--bench")) bench = value else if (std.mem.eql(u8, flag, "--runs")) runs = try parsePositiveInt(value) else if (std.mem.eql(u8, flag, "--regression-pct")) regression_pct = try parsePositiveFloat(value) else if (std.mem.eql(u8, flag, "--geomean-pct")) geomean_pct = try parsePositiveFloat(value) else return error.InvalidArgument;
        }
        return .{ .check = .{
            .baseline = baseline orelse return error.InvalidArgument,
            .bench = bench orelse return error.InvalidArgument,
            .runs = runs,
            .regression_pct = regression_pct,
            .geomean_pct = geomean_pct,
        } };
    }
    if (std.mem.eql(u8, args[0], "record")) {
        var baseline: ?[]const u8 = null;
        var bench: ?[]const u8 = null;
        var zig: []const u8 = "zig";
        var runs = default_run_count;
        var i: usize = 1;
        while (i < args.len) : (i += 1) {
            const flag = args[i];
            const value = try nextValue(args, &i);
            if (std.mem.eql(u8, flag, "--baseline")) baseline = value else if (std.mem.eql(u8, flag, "--bench")) bench = value else if (std.mem.eql(u8, flag, "--zig")) zig = value else if (std.mem.eql(u8, flag, "--runs")) runs = try parsePositiveInt(value) else return error.InvalidArgument;
        }
        if (runs != default_run_count) return error.InvalidArgument;
        return .{ .record = .{
            .baseline = baseline orelse return error.InvalidArgument,
            .bench = bench orelse return error.InvalidArgument,
            .zig = zig,
            .runs = runs,
        } };
    }
    return error.InvalidArgument;
}

fn checkDefaultsFromEnvironment(environ: std.process.Environ.Map) !CheckDefaults {
    return .{
        .runs = if (environ.get("BENCH_RUNS")) |value| try parsePositiveInt(value) else default_run_count,
        .regression_pct = if (environ.get("BENCH_REGRESSION_PCT")) |value| try parsePositiveFloat(value) else default_regression_pct,
        .geomean_pct = if (environ.get("BENCH_GEOMEAN_PCT")) |value| try parsePositiveFloat(value) else default_geomean_pct,
    };
}

fn nextValue(args: []const []const u8, index: *usize) ![]const u8 {
    if (!std.mem.startsWith(u8, args[index.*], "--")) return error.InvalidArgument;
    index.* += 1;
    if (index.* >= args.len) return error.InvalidArgument;
    return args[index.*];
}

fn parsePositiveInt(value: []const u8) !usize {
    const parsed = try std.fmt.parseInt(usize, value, 10);
    if (parsed == 0) return error.InvalidArgument;
    return parsed;
}

fn parsePositiveFloat(value: []const u8) !f64 {
    const parsed = try std.fmt.parseFloat(f64, value);
    if (!std.math.isFinite(parsed) or parsed <= 0) return error.InvalidArgument;
    return parsed;
}

fn collectArgs(allocator: std.mem.Allocator, vector: std.process.Args) ![]const []const u8 {
    var iterator = std.process.Args.Iterator.init(vector);
    defer iterator.deinit();
    var args: std.ArrayList([]const u8) = .empty;
    errdefer freeArgs(allocator, args.items);
    while (iterator.next()) |arg| try args.append(allocator, try allocator.dupe(u8, arg));
    return args.toOwnedSlice(allocator);
}

fn freeArgs(allocator: std.mem.Allocator, args: []const []const u8) void {
    for (args) |arg| allocator.free(arg);
    allocator.free(args);
}

fn loadBaseline(allocator: std.mem.Allocator, path: []const u8) !Report {
    const bytes = try zts.file_io.readFile(allocator, path, max_report_bytes);
    defer allocator.free(bytes);
    const root = std.json.parseFromSliceLeaky(std.json.Value, allocator, bytes, .{
        .allocate = .alloc_always,
    }) catch return error.InvalidBenchmarkBaseline;
    try validateBaselineValue(root);
    return std.json.parseFromSliceLeaky(Report, allocator, bytes, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    }) catch return error.InvalidBenchmarkBaseline;
}

fn validateBaselineValue(root: std.json.Value) !void {
    if (root != .object) return error.InvalidBenchmarkBaseline;
    const schema = root.object.get("schema_version") orelse return error.InvalidBenchmarkBaseline;
    if (schema != .integer or schema.integer != 1) return error.InvalidBenchmarkBaseline;
    const provenance = root.object.get("provenance") orelse return error.InvalidBenchmarkBaseline;
    if (provenance != .object) return error.InvalidBenchmarkBaseline;
    const source_dirty = provenance.object.get("source_dirty") orelse return error.InvalidBenchmarkBaseline;
    if (source_dirty != .bool or source_dirty.bool) return error.InvalidBenchmarkBaseline;
    const source_commit = try requiredString(provenance.object, "source_commit");
    if (!isLowerHexCommit(source_commit)) return error.InvalidBenchmarkBaseline;
    if ((try requiredString(provenance.object, "zig_version")).len == 0) return error.InvalidBenchmarkBaseline;
    const aggregation = try requiredString(provenance.object, "aggregation");
    if (!std.mem.eql(u8, aggregation, "per-benchmark best ops_per_sec")) return error.InvalidBenchmarkBaseline;
    const run_count = provenance.object.get("run_count") orelse return error.InvalidBenchmarkBaseline;
    if (run_count != .integer or run_count.integer != default_run_count) return error.InvalidBenchmarkBaseline;
    const host = provenance.object.get("host") orelse return error.InvalidBenchmarkBaseline;
    if (host != .object) return error.InvalidBenchmarkBaseline;
    for ([_][]const u8{ "os", "os_release", "architecture", "processor" }) |field| {
        if ((try requiredString(host.object, field)).len == 0) return error.InvalidBenchmarkBaseline;
    }
}

fn requiredString(object: std.json.ObjectMap, field: []const u8) ![]const u8 {
    const value = object.get(field) orelse return error.InvalidBenchmarkBaseline;
    if (value != .string) return error.InvalidBenchmarkBaseline;
    return value.string;
}

fn isLowerHexCommit(value: []const u8) bool {
    if (value.len != 40) return false;
    for (value) |byte| {
        if (!std.ascii.isDigit(byte) and !(byte >= 'a' and byte <= 'f')) return false;
    }
    return true;
}

fn runBenchmark(_: ?*anyopaque, allocator: std.mem.Allocator, io: std.Io, bench: []const u8) ![]u8 {
    const result = try std.process.run(allocator, io, .{
        .argv = &.{ bench, "--json", "--quiet" },
        .stdout_limit = .limited(max_report_bytes),
        .stderr_limit = .limited(256 * 1024),
    });
    allocator.free(result.stderr);
    if (!termSucceeded(result.term)) {
        allocator.free(result.stdout);
        return error.BenchmarkRunFailed;
    }
    return result.stdout;
}

fn termSucceeded(term: std.process.Child.Term) bool {
    return switch (term) {
        .exited => |code| code == 0,
        else => false,
    };
}

fn sampleBenchmarks(
    allocator: std.mem.Allocator,
    io: std.Io,
    bench: []const u8,
    run_count: usize,
    capability: SampleCapability,
) !Report {
    if (run_count == 0) return error.InvalidRunCount;
    var best: ?Report = null;
    for (0..run_count) |_| {
        const output = try capability.run(capability.context, allocator, io, bench);
        defer allocator.free(output);
        const report = std.json.parseFromSliceLeaky(Report, allocator, output, .{
            .allocate = .alloc_always,
            .ignore_unknown_fields = true,
        }) catch return error.InvalidBenchmarkReport;
        try validateReport(report);
        if (best) |*current_best| {
            if (!sameBenchmarkSet(current_best.*, report)) return error.BenchmarkSetChanged;
            for (current_best.benchmarks) |*entry| {
                const candidate = findBenchmark(report, entry.name).?;
                if (candidate.ops_per_sec > entry.ops_per_sec) entry.* = candidate;
            }
        } else {
            const entries = try allocator.dupe(Benchmark, report.benchmarks);
            best = .{ .schema_version = report.schema_version, .benchmarks = entries };
        }
    }
    return best orelse error.NoBenchmarkRuns;
}

fn validateReport(report: Report) !void {
    if (report.benchmarks.len == 0) return error.NoBenchmarks;
    for (report.benchmarks, 0..) |entry, i| {
        if (entry.name.len == 0) return error.InvalidBenchmarkName;
        if (!entry.success) return error.BenchmarkFailed;
        if (!std.math.isFinite(entry.ops_per_sec) or entry.ops_per_sec <= 0) return error.InvalidOperationsPerSecond;
        for (report.benchmarks[0..i]) |previous| {
            if (std.mem.eql(u8, previous.name, entry.name)) return error.DuplicateBenchmark;
        }
    }
}

fn findBenchmark(report: Report, name: []const u8) ?Benchmark {
    for (report.benchmarks) |entry| {
        if (std.mem.eql(u8, entry.name, name)) return entry;
    }
    return null;
}

fn sameBenchmarkSet(left: Report, right: Report) bool {
    if (left.benchmarks.len != right.benchmarks.len) return false;
    for (left.benchmarks) |entry| if (findBenchmark(right, entry.name) == null) return false;
    return true;
}

fn compareReports(current: Report, baseline: Report, regression_limit: f64, geomean_limit: f64) !ComparisonDecision {
    if (!std.math.isFinite(regression_limit) or regression_limit <= 0 or
        !std.math.isFinite(geomean_limit) or geomean_limit <= 0)
    {
        return error.InvalidThreshold;
    }
    try validateReport(current);
    try validateReport(baseline);
    for (baseline.benchmarks) |entry| {
        if (findBenchmark(current, entry.name) == null) return error.MissingBaselineBenchmark;
    }
    if (!sameBenchmarkSet(current, baseline)) return error.BenchmarkSetChanged;
    var log_sum: f64 = 0;
    var count: usize = 0;
    for (baseline.benchmarks) |baseline_entry| {
        const current_entry = findBenchmark(current, baseline_entry.name) orelse return error.MissingBaselineBenchmark;
        if (isSkipped(baseline_entry.name)) continue;
        const ratio = current_entry.ops_per_sec / baseline_entry.ops_per_sec;
        const regression_pct = @max(0.0, (1.0 - ratio) * 100.0);
        if (regression_pct > regression_limit) return .{ .individual_regression = .{
            .name = baseline_entry.name,
            .current_ops = current_entry.ops_per_sec,
            .baseline_ops = baseline_entry.ops_per_sec,
            .regression_pct = regression_pct,
        } };
        log_sum += @log(ratio);
        count += 1;
    }
    if (count == 0) return error.NoComparableBenchmarks;
    const geomean = @exp(log_sum / @as(f64, @floatFromInt(count)));
    const regression_pct = @max(0.0, (1.0 - geomean) * 100.0);
    const comparison: Comparison = .{
        .count = count,
        .geomean = geomean,
        .regression_pct = regression_pct,
    };
    if (regression_pct > geomean_limit) return .{ .geomean_regression = comparison };
    return .{ .pass = comparison };
}

fn isSkipped(name: []const u8) bool {
    for (skipped_benchmarks) |skipped| if (std.mem.eql(u8, skipped, name)) return true;
    return false;
}

fn recordBaseline(allocator: std.mem.Allocator, io: std.Io, opts: RecordOptions) !void {
    const source_commit = try cleanSourceCommit(allocator, io);
    defer allocator.free(source_commit);

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const sampled = try sampleBenchmarks(arena_state.allocator(), io, opts.bench, opts.runs, .{
        .context = null,
        .run = runBenchmark,
    });
    const after_commit = try cleanSourceCommit(allocator, io);
    defer allocator.free(after_commit);
    if (!std.mem.eql(u8, source_commit, after_commit)) return error.SourceChanged;

    const zig_version = try commandOutput(allocator, io, &.{ opts.zig, "version" });
    defer allocator.free(zig_version);
    const os_release = commandOutput(allocator, io, &.{ "uname", "-r" }) catch try allocator.dupe(u8, "unknown");
    defer allocator.free(os_release);
    const processor = if (builtin.os.tag == .macos)
        commandOutput(allocator, io, &.{ "sysctl", "-n", "machdep.cpu.brand_string" }) catch try allocator.dupe(u8, "unknown")
    else
        try allocator.dupe(u8, "unknown");
    defer allocator.free(processor);

    const output = try renderBaseline(allocator, sampled, .{
        .source_commit = source_commit,
        .zig_version = zig_version,
        .os_release = os_release,
        .processor = processor,
        .run_count = opts.runs,
    });
    defer allocator.free(output);
    try zts.file_io.writeFile(allocator, opts.baseline, output);
    std.debug.print(
        "bench-record ok: recorded {d} benchmarks from {d} runs at {s}\n",
        .{ sampled.benchmarks.len, opts.runs, source_commit },
    );
}

fn cleanSourceCommit(allocator: std.mem.Allocator, io: std.Io) ![]u8 {
    const commit = try commandOutput(allocator, io, &.{ "git", "rev-parse", "HEAD" });
    errdefer allocator.free(commit);
    const status = try commandOutput(allocator, io, &.{ "git", "status", "--porcelain=v1", "--untracked-files=all" });
    defer allocator.free(status);
    if (status.len != 0) return error.DirtySource;
    return commit;
}

fn commandOutput(allocator: std.mem.Allocator, io: std.Io, argv: []const []const u8) ![]u8 {
    const result = try std.process.run(allocator, io, .{
        .argv = argv,
        .stdout_limit = .limited(8 * 1024 * 1024),
        .stderr_limit = .limited(256 * 1024),
    });
    defer allocator.free(result.stderr);
    if (!termSucceeded(result.term)) {
        allocator.free(result.stdout);
        return error.CommandFailed;
    }
    const trimmed = std.mem.trim(u8, result.stdout, " \t\r\n");
    const owned = try allocator.dupe(u8, trimmed);
    allocator.free(result.stdout);
    return owned;
}

const Provenance = struct {
    source_commit: []const u8,
    zig_version: []const u8,
    os_release: []const u8,
    processor: []const u8,
    run_count: usize,
};

fn renderBaseline(allocator: std.mem.Allocator, report: Report, provenance: Provenance) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    var json: std.json.Stringify = .{
        .writer = &aw.writer,
        .options = .{ .whitespace = .indent_2 },
    };
    try json.beginObject();
    try json.objectField("schema_version");
    try json.write(report.schema_version);
    try json.objectField("provenance");
    try json.beginObject();
    try json.objectField("source_commit");
    try json.write(provenance.source_commit);
    try json.objectField("source_dirty");
    try json.write(false);
    try json.objectField("zig_version");
    try json.write(provenance.zig_version);
    try json.objectField("host");
    try json.beginObject();
    try json.objectField("os");
    try json.write(if (builtin.os.tag == .macos) "Darwin" else @tagName(builtin.os.tag));
    try json.objectField("os_release");
    try json.write(provenance.os_release);
    try json.objectField("architecture");
    try json.write(if (builtin.cpu.arch == .aarch64) "arm64" else @tagName(builtin.cpu.arch));
    try json.objectField("processor");
    try json.write(provenance.processor);
    try json.endObject();
    try json.objectField("run_count");
    try json.write(provenance.run_count);
    try json.objectField("aggregation");
    try json.write("per-benchmark best ops_per_sec");
    try json.endObject();
    try json.objectField("benchmarks");
    try json.write(report.benchmarks);
    try json.endObject();
    try aw.writer.writeByte('\n');
    return allocator.dupe(u8, aw.writer.buffered());
}

fn makeReport(entries: []Benchmark) Report {
    return .{ .benchmarks = entries };
}

test "thresholds and skip set remain stable" {
    try std.testing.expectEqual(@as(usize, 5), default_run_count);
    try std.testing.expectEqual(@as(f64, 8.0), default_regression_pct);
    try std.testing.expectEqual(@as(f64, 3.0), default_geomean_pct);
    try std.testing.expectEqual(@as(usize, 4), skipped_benchmarks.len);
}

test "comparison accepts equal reports" {
    var entries = [_]Benchmark{
        .{ .name = "alpha", .success = true, .ops_per_sec = 100 },
        .{ .name = "beta", .success = true, .ops_per_sec = 100 },
    };
    const result = (try compareReports(makeReport(&entries), makeReport(&entries), 8, 3)).pass;
    try std.testing.expectEqual(@as(usize, 2), result.count);
    try std.testing.expectApproxEqAbs(@as(f64, 1), result.geomean, 0.00001);
}

test "comparison rejects individual and aggregate regressions" {
    var baseline_entries = [_]Benchmark{
        .{ .name = "alpha", .success = true, .ops_per_sec = 100 },
        .{ .name = "beta", .success = true, .ops_per_sec = 100 },
    };
    var individual_entries = [_]Benchmark{
        .{ .name = "alpha", .success = true, .ops_per_sec = 90 },
        .{ .name = "beta", .success = true, .ops_per_sec = 100 },
    };
    try std.testing.expectEqual(.individual_regression, std.meta.activeTag(try compareReports(
        makeReport(&individual_entries),
        makeReport(&baseline_entries),
        8,
        20,
    )));
    var aggregate_entries = [_]Benchmark{
        .{ .name = "alpha", .success = true, .ops_per_sec = 96 },
        .{ .name = "beta", .success = true, .ops_per_sec = 96 },
    };
    try std.testing.expectEqual(.geomean_regression, std.meta.activeTag(try compareReports(
        makeReport(&aggregate_entries),
        makeReport(&baseline_entries),
        8,
        3,
    )));
}

test "comparison rejects missing entries and empty skip result" {
    var baseline_entries = [_]Benchmark{
        .{ .name = "alpha", .success = true, .ops_per_sec = 100 },
        .{ .name = "stringConcat", .success = true, .ops_per_sec = 100 },
    };
    var missing_entries = [_]Benchmark{
        .{ .name = "stringConcat", .success = true, .ops_per_sec = 10 },
    };
    try std.testing.expectError(error.MissingBaselineBenchmark, compareReports(
        makeReport(&missing_entries),
        makeReport(&baseline_entries),
        8,
        3,
    ));
    try std.testing.expectError(error.NoComparableBenchmarks, compareReports(
        makeReport(&missing_entries),
        makeReport(&missing_entries),
        8,
        3,
    ));
}

test "comparison rejects an extra current benchmark" {
    var baseline_entries = [_]Benchmark{
        .{ .name = "alpha", .success = true, .ops_per_sec = 100 },
    };
    var current_entries = [_]Benchmark{
        .{ .name = "alpha", .success = true, .ops_per_sec = 100 },
        .{ .name = "beta", .success = true, .ops_per_sec = 1 },
    };
    try std.testing.expectError(error.BenchmarkSetChanged, compareReports(
        makeReport(&current_entries),
        makeReport(&baseline_entries),
        8,
        3,
    ));
}

test "baseline validation requires clean five-run provenance" {
    const valid =
        \\{"schema_version":1,"provenance":{
        \\"source_commit":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        \\"source_dirty":false,"zig_version":"0.16.0",
        \\"host":{"os":"Darwin","os_release":"25.6.0","architecture":"arm64","processor":"Apple"},
        \\"run_count":5,"aggregation":"per-benchmark best ops_per_sec"},
        \\"benchmarks":[{"name":"alpha","success":true,"ops_per_sec":100}]}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, valid, .{});
    defer parsed.deinit();
    try validateBaselineValue(parsed.value);

    const partial = "{\"schema_version\":1,\"benchmarks\":[{\"name\":\"alpha\",\"success\":true,\"ops_per_sec\":100}]}";
    var partial_parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, partial, .{});
    defer partial_parsed.deinit();
    try std.testing.expectError(error.InvalidBenchmarkBaseline, validateBaselineValue(partial_parsed.value));
}

test "comparison rejects non-finite thresholds and measurements" {
    var valid = [_]Benchmark{.{ .name = "alpha", .success = true, .ops_per_sec = 100 }};
    try std.testing.expectError(error.InvalidThreshold, compareReports(
        makeReport(&valid),
        makeReport(&valid),
        std.math.nan(f64),
        3,
    ));
    try std.testing.expectError(error.InvalidThreshold, compareReports(
        makeReport(&valid),
        makeReport(&valid),
        8,
        std.math.inf(f64),
    ));
    var invalid = [_]Benchmark{.{ .name = "alpha", .success = true, .ops_per_sec = std.math.inf(f64) }};
    try std.testing.expectError(error.InvalidOperationsPerSecond, compareReports(
        makeReport(&invalid),
        makeReport(&valid),
        8,
        3,
    ));
}

const FakeSampler = struct {
    reports: []const []const u8,
    index: usize = 0,

    fn run(context: ?*anyopaque, allocator: std.mem.Allocator, _: std.Io, _: []const u8) ![]u8 {
        const self: *FakeSampler = @ptrCast(@alignCast(context.?));
        if (self.index >= self.reports.len) return error.NoFixtureReport;
        defer self.index += 1;
        return allocator.dupe(u8, self.reports[self.index]);
    }
};

test "sampler keeps each benchmark best across five runs" {
    const reports = [_][]const u8{
        "{\"benchmarks\":[{\"name\":\"alpha\",\"success\":true,\"ops_per_sec\":10},{\"name\":\"beta\",\"success\":true,\"ops_per_sec\":50}]}",
        "{\"benchmarks\":[{\"name\":\"alpha\",\"success\":true,\"ops_per_sec\":20},{\"name\":\"beta\",\"success\":true,\"ops_per_sec\":40}]}",
        "{\"benchmarks\":[{\"name\":\"alpha\",\"success\":true,\"ops_per_sec\":30},{\"name\":\"beta\",\"success\":true,\"ops_per_sec\":30}]}",
        "{\"benchmarks\":[{\"name\":\"alpha\",\"success\":true,\"ops_per_sec\":40},{\"name\":\"beta\",\"success\":true,\"ops_per_sec\":20}]}",
        "{\"benchmarks\":[{\"name\":\"alpha\",\"success\":true,\"ops_per_sec\":50},{\"name\":\"beta\",\"success\":true,\"ops_per_sec\":10}]}",
    };
    var fake: FakeSampler = .{ .reports = &reports };
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const sampled = try sampleBenchmarks(arena_state.allocator(), std.testing.io, "unused", 5, .{
        .context = &fake,
        .run = FakeSampler.run,
    });
    try std.testing.expectEqual(@as(usize, 5), fake.index);
    try std.testing.expectEqual(@as(f64, 50), findBenchmark(sampled, "alpha").?.ops_per_sec);
    try std.testing.expectEqual(@as(f64, 50), findBenchmark(sampled, "beta").?.ops_per_sec);
}

test "sampler rejects changing benchmark sets" {
    const reports = [_][]const u8{
        "{\"benchmarks\":[{\"name\":\"alpha\",\"success\":true,\"ops_per_sec\":10}]}",
        "{\"benchmarks\":[{\"name\":\"beta\",\"success\":true,\"ops_per_sec\":10}]}",
    };
    var fake: FakeSampler = .{ .reports = &reports };
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    try std.testing.expectError(error.BenchmarkSetChanged, sampleBenchmarks(
        arena_state.allocator(),
        std.testing.io,
        "unused",
        2,
        .{ .context = &fake, .run = FakeSampler.run },
    ));
}

test "argument parser rejects non-finite thresholds" {
    try std.testing.expectError(error.InvalidArgument, parseArgs(&.{
        "check", "--baseline", "base.json", "--bench", "bench", "--regression-pct", "nan",
    }));
    try std.testing.expectError(error.InvalidArgument, parseArgs(&.{
        "check", "--baseline", "base.json", "--bench", "bench", "--geomean-pct", "inf",
    }));
}

test "environment defaults reject non-finite thresholds" {
    var environ = std.process.Environ.Map.init(std.testing.allocator);
    defer environ.deinit();
    try environ.put("BENCH_REGRESSION_PCT", "nan");
    try std.testing.expectError(error.InvalidArgument, checkDefaultsFromEnvironment(environ));
    try environ.put("BENCH_REGRESSION_PCT", "8");
    try environ.put("BENCH_GEOMEAN_PCT", "-inf");
    try std.testing.expectError(error.InvalidArgument, checkDefaultsFromEnvironment(environ));
}
