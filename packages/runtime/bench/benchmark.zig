//! zts Performance Benchmark Runner
//!
//! Runs JavaScript benchmarks and times them individually from Zig side.
//!
//! Usage: zig build bench

const std = @import("std");
const compat = @import("zts").compat;
const runtime_instance = @import("runtime_instance");
const zq = @import("zts");
const HandlerInstance = runtime_instance.HandlerInstance;
const HandlerPool = runtime_instance.HandlerPool;
const RuntimeConfig = runtime_instance.RuntimeConfig;
const PerfStats = zq.interpreter.PerfStats;
const OptStats = zq.OptStats;

pub const std_options: std.Options = .{
    .log_level = .err,
};

const BenchmarkResult = struct {
    name: []const u8,
    iterations: u32,
    time_ms: f64 = 0,
    ops_per_sec: u64 = 0,
    success: bool = true,
    error_name: ?[]const u8 = null,
    perf: PerfStats = .{},
    opt_stats: OptStats = .{},
};

const Options = struct {
    json: bool = false,
    quiet: bool = false,
    script_path: ?[]const u8 = null,
    bench: bool = false,
    request_path: bool = false,
    bench_fn: []const u8 = "run",
    bench_iterations: u32 = 200000,
    warmup_rounds: u32 = 120,
    warmup_iterations: u32 = 200,
};

const usage =
    "Usage: zttp-bench [--json] [--quiet] [--script <path>] [--bench] [--request-path]\n" ++
    "                   [--bench-fn <name>] [--iterations <n>] [--warmup <n>] [--warmup-iters <n>]\n";

fn writeStdout(data: []const u8) void {
    _ = std.c.write(std.c.STDOUT_FILENO, data.ptr, data.len);
}

fn parseU32(arg: []const u8, flag: []const u8) u32 {
    return std.fmt.parseInt(u32, arg, 10) catch {
        writeStdout("Invalid value for ");
        writeStdout(flag);
        writeStdout("\n");
        writeStdout(usage);
        std.process.exit(1);
    };
}

// Global to store args from main
var g_args: std.process.Args = undefined;

fn parseOptions() Options {
    var options = Options{};
    var args = std.process.Args.Iterator.init(g_args);
    defer args.deinit();
    _ = args.skip();

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--json")) {
            options.json = true;
        } else if (std.mem.eql(u8, arg, "--quiet")) {
            options.quiet = true;
        } else if (std.mem.eql(u8, arg, "--script")) {
            const path = args.next() orelse {
                writeStdout("Missing value for --script\n");
                writeStdout(usage);
                std.process.exit(1);
            };
            options.script_path = path;
        } else if (std.mem.eql(u8, arg, "--bench")) {
            options.bench = true;
        } else if (std.mem.eql(u8, arg, "--request-path")) {
            options.request_path = true;
        } else if (std.mem.eql(u8, arg, "--bench-fn")) {
            const name = args.next() orelse {
                writeStdout("Missing value for --bench-fn\n");
                writeStdout(usage);
                std.process.exit(1);
            };
            options.bench_fn = name;
        } else if (std.mem.eql(u8, arg, "--iterations")) {
            const value = args.next() orelse {
                writeStdout("Missing value for --iterations\n");
                writeStdout(usage);
                std.process.exit(1);
            };
            options.bench_iterations = parseU32(value, "--iterations");
        } else if (std.mem.eql(u8, arg, "--warmup")) {
            const value = args.next() orelse {
                writeStdout("Missing value for --warmup\n");
                writeStdout(usage);
                std.process.exit(1);
            };
            options.warmup_rounds = parseU32(value, "--warmup");
        } else if (std.mem.eql(u8, arg, "--warmup-iters")) {
            const value = args.next() orelse {
                writeStdout("Missing value for --warmup-iters\n");
                writeStdout(usage);
                std.process.exit(1);
            };
            options.warmup_iterations = parseU32(value, "--warmup-iters");
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            writeStdout(usage);
            std.process.exit(0);
        }
    }

    return options;
}

fn println(msg: []const u8) void {
    writeStdout(msg);
    writeStdout("\n");
}

const readFilePosix = zq.file_io.readFile;

fn printFmt(comptime fmt: []const u8, args: anytype) void {
    var buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;
    println(msg);
}

fn writePerfStatsJson(writer: anytype, perf: PerfStats) !void {
    try writer.print(
        "{{\"backedge_count\":{d},\"pic_hits\":{d},\"pic_misses\":{d},\"mega_recoveries\":{d},\"opcode_histogram_enabled\":{s},\"opcode_histogram_nonzero\":{d}",
        .{
            perf.backedge_count,
            perf.pic_hits,
            perf.pic_misses,
            perf.mega_recoveries,
            if (perf.opcode_histogram_enabled) "true" else "false",
            perf.opcode_histogram_nonzero,
        },
    );
    if (perf.opcode_histogram_enabled) {
        try writer.writeAll(",\"opcode_histogram\":[");
        var first = true;
        for (perf.opcode_histogram, 0..) |count, opcode_idx| {
            if (count == 0) continue;
            if (!first) try writer.writeAll(",");
            first = false;
            try writer.print("[{d},{d}]", .{ opcode_idx, count });
        }
        try writer.writeAll("]");
    }
    try writer.writeAll("}");
}

fn writeBenchmarkResultJson(writer: anytype, result: BenchmarkResult) !void {
    try writer.print(
        "{{\"name\":\"{s}\",\"iterations\":{d},\"success\":{s},\"time_ms\":{d:.3},\"ops_per_sec\":{d},\"error\":",
        .{
            result.name,
            result.iterations,
            if (result.success) "true" else "false",
            result.time_ms,
            result.ops_per_sec,
        },
    );
    if (result.error_name) |error_name| {
        try writer.print("\"{s}\"", .{error_name});
    } else {
        try writer.writeAll("null");
    }
    try writer.writeAll(",\"perf\":");
    try writePerfStatsJson(writer, result.perf);
    try writer.writeAll(",\"opt_stats\":");
    try result.opt_stats.writeJson(writer);
    try writer.writeAll("}");
}

const ITERATIONS: u32 = 50000;

// Each benchmark as a separate code string
const benchmarks = [_]struct { name: []const u8, iterations: u32, code: []const u8 }{
    .{
        .name = "intArithmetic",
        .iterations = ITERATIONS,
        .code =
        \\function runIntArithmetic(iterations) {
        \\    let sum = 0;
        \\    for (let i of range(iterations)) {
        \\        sum = (sum + i) % 1000000;
        \\        sum = (sum - (i % 1000) + 1000000) % 1000000;
        \\        sum = (sum * 2) % 1000000;
        \\        sum = (sum >> 1);
        \\    }
        \\    return sum;
        \\}
        \\runIntArithmetic(50000);
        ,
    },
    .{
        .name = "stringConcat",
        .iterations = ITERATIONS,
        .code =
        \\function runStringConcat(iterations) {
        \\    let result = '';
        \\    for (let i of range(iterations)) {
        \\        result = [result, 'x'].join('');
        \\        if (result.length > 1000) {
        \\            result = '';
        \\        }
        \\    }
        \\    return result.length;
        \\}
        \\runStringConcat(50000);
        ,
    },
    .{
        .name = "stringOps",
        .iterations = ITERATIONS,
        .code =
        \\function runStringOps(iterations) {
        \\    let str = 'The quick brown fox jumps over the lazy dog';
        \\    let count = 0;
        \\    for (let i of range(iterations)) {
        \\        count = (count + str.indexOf('fox')) % 1000000;
        \\        count = (count + str.length) % 1000000;
        \\    }
        \\    return count;
        \\}
        \\runStringOps(50000);
        ,
    },
    .{
        .name = "objectCreate",
        .iterations = ITERATIONS,
        .code =
        \\function runObjectCreate(iterations) {
        \\    let objects = [];
        \\    for (let i of range(iterations)) {
        \\        objects.push({ id: i, name: 'item' });
        \\        if (objects.length > 100) {
        \\            objects = [];
        \\        }
        \\    }
        \\    return objects.length;
        \\}
        \\runObjectCreate(50000);
        ,
    },
    .{
        .name = "propertyAccess",
        .iterations = ITERATIONS,
        .code =
        \\function runPropertyAccess(iterations) {
        \\    let obj = { a: 1, b: 2, c: 3, d: 4, e: 5 };
        \\    let sum = 0;
        \\    for (let i of range(iterations)) {
        \\        sum = (sum + obj.a + obj.b + obj.c + obj.d + obj.e) % 1000000;
        \\        obj.a = i % 100;
        \\    }
        \\    return sum;
        \\}
        \\runPropertyAccess(50000);
        ,
    },
    .{
        .name = "arrayOps",
        .iterations = ITERATIONS,
        .code =
        \\function runArrayOps(iterations) {
        \\    let arr = [];
        \\    let sum = 0;
        \\    for (let i of range(iterations)) {
        \\        arr.push(i % 1000);
        \\        if (arr.length > 100) {
        \\            for (let val of arr) {
        \\                sum = (sum + val) % 1000000;
        \\            }
        \\            arr = [];
        \\        }
        \\    }
        \\    return sum;
        \\}
        \\runArrayOps(50000);
        ,
    },
    .{
        .name = "functionCalls",
        .iterations = ITERATIONS,
        .code =
        \\function add(a, b) { return (a + b) % 1000000; }
        \\function compute(x, y) { return add(x, y); }
        \\function runFunctionCalls(iterations) {
        \\    let result = 0;
        \\    for (let i of range(iterations)) {
        \\        result = compute(i % 1000, result);
        \\    }
        \\    return result;
        \\}
        \\runFunctionCalls(50000);
        ,
    },
    .{
        .name = "recursion",
        .iterations = 25,
        .code =
        \\function fib(n) {
        \\    if (n <= 1) return n;
        \\    return fib(n - 1) + fib(n - 2);
        \\}
        \\fib(25);
        ,
    },
    .{
        .name = "jsonOps",
        .iterations = 5000,
        .code =
        \\function runJsonOps(iterations) {
        \\    let obj = { users: [{ id: 1 }, { id: 2 }] };
        \\    let count = 0;
        \\    for (let i of range(iterations)) {
        \\        let json = JSON.stringify(obj);
        \\        let parsed = JSON.parse(json);
        \\        count = (count + parsed.users.length) % 1000000;
        \\    }
        \\    return count;
        \\}
        \\runJsonOps(5000);
        ,
    },
    .{
        .name = "gcPressure",
        .iterations = ITERATIONS,
        .code =
        \\function runGcPressure(iterations) {
        \\    let count = 0;
        \\    for (let i of range(iterations)) {
        \\        let obj = { a: i % 100, b: 'str' };
        \\        let str = JSON.stringify(obj);
        \\        count = (count + str.length) % 1000000;
        \\    }
        \\    return count;
        \\}
        \\runGcPressure(50000);
        ,
    },
    .{
        .name = "httpHandler",
        .iterations = 5000,
        .code =
        \\function runHttpHandler(iterations) {
        \\    let responses = 0;
        \\    for (let i of range(iterations)) {
        \\        let response = {
        \\            status: 200,
        \\            body: JSON.stringify({ id: i % 100, name: 'User' })
        \\        };
        \\        responses = (responses + response.body.length) % 1000000;
        \\    }
        \\    return responses;
        \\}
        \\runHttpHandler(5000);
        ,
    },
    .{
        .name = "httpHandlerHeavy",
        .iterations = 2000,
        .code =
        \\function runHttpHandlerHeavy(iterations) {
        \\    let responses = 0;
        \\    let baseHeaders = { 'content-type': 'application/json', 'cache-control': 'no-store' };
        \\    let payload = JSON.stringify({ id: 1, name: 'User1', tags: ['alpha','beta','gamma'] });
        \\    for (let i of range(iterations)) {
        \\        let reqPath = (i % 3 === 0) ? '/api/users' : '/api/users/42';
        \\        let query = (i % 2 === 0) ? '?limit=10&offset=5' : '?limit=25&offset=0';
        \\        let limit = (query.indexOf('limit=25') !== -1) ? 25 : 10;
        \\        let offset = (query.indexOf('offset=5') !== -1) ? 5 : 0;
        \\        let bodyObj = undefined;
        \\        if (reqPath.indexOf('/api/users') === 0) {
        \\            bodyObj = JSON.parse(payload);
        \\            bodyObj.limit = limit;
        \\            bodyObj.offset = offset;
        \\        }
        \\        let headers = {
        \\            'content-type': baseHeaders['content-type'],
        \\            'cache-control': baseHeaders['cache-control'],
        \\            'x-request-id': ['req-', String(i % 1000)].join('')
        \\        };
        \\        let response = {
        \\            status: (reqPath === '/api/users') ? 200 : 201,
        \\            headers: headers,
        \\            body: JSON.stringify({ ok: true, path: reqPath, data: bodyObj })
        \\        };
        \\        responses = (responses + response.body.length + response.status) % 1000000;
        \\    }
        \\    return responses;
        \\}
        \\runHttpHandlerHeavy(2000);
        ,
    },
    .{
        .name = "forOfLoop",
        .iterations = ITERATIONS,
        .code =
        \\function runForOfLoop(iterations) {
        \\    let arr = [];
        \\    for (let i of range(100)) {
        \\        arr.push(i);
        \\    }
        \\    let sum = 0;
        \\    let loops = (iterations / 100) >> 0;
        \\    for (let j of range(loops)) {
        \\        for (let val of arr) {
        \\            sum = (sum + val) % 1000000;
        \\        }
        \\    }
        \\    return sum;
        \\}
        \\runForOfLoop(50000);
        ,
    },
};

// ---------------------------------------------------------------------------
// request_path: HandlerPool.executeHandlerBorrowed under the default pooling policy
// ---------------------------------------------------------------------------

/// Nanosecond clock for the request_path section. macOS CLOCK_MONOTONIC counts whole
/// microseconds, so a sub-microsecond request would read 0 or 1000ns; UPTIME_RAW does not.
fn requestPathNowNs() !u64 {
    var ts: std.c.timespec = undefined;
    const clock: std.c.clockid_t = if (@import("builtin").os.tag.isDarwin()) .UPTIME_RAW else .MONOTONIC;
    if (std.c.clock_gettime(clock, &ts) != 0) return error.ClockGettimeFailed;
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

const request_path_requests: usize = 1024;
const request_path_min_recycles: u64 = 16;
const request_path_handler = "examples/handler/handler.ts";

/// Counts every call that reaches the backing allocator. The driver is single
/// threaded, but pool prewarm may use threads, so the counters are atomic.
const CountingAllocator = struct {
    backing: std.mem.Allocator,
    alloc_calls: std.atomic.Value(u64) = .init(0),
    free_calls: std.atomic.Value(u64) = .init(0),

    const vtable: std.mem.Allocator.VTable = .{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };

    fn allocator(self: *CountingAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        _ = self.alloc_calls.fetchAdd(1, .monotonic);
        return self.backing.rawAlloc(len, alignment, ret_addr);
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        _ = self.alloc_calls.fetchAdd(1, .monotonic);
        return self.backing.rawResize(memory, alignment, new_len, ret_addr);
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        _ = self.alloc_calls.fetchAdd(1, .monotonic);
        return self.backing.rawRemap(memory, alignment, new_len, ret_addr);
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        _ = self.free_calls.fetchAdd(1, .monotonic);
        self.backing.rawFree(memory, alignment, ret_addr);
    }
};

/// Nearest-rank percentile of an ascending slice. With fewer than 100 samples
/// p99 is the maximum.
fn percentileSorted(sorted: []const u64, pct: usize) u64 {
    if (sorted.len == 0) return 0;
    const rank = (pct * sorted.len + 99) / 100; // ceil(pct * n / 100)
    return sorted[@max(rank, 1) - 1];
}

const LatencyGroup = struct {
    count: usize = 0,
    p50_ns: u64 = 0,
    p99_ns: u64 = 0,
};

fn latencyGroup(allocator: std.mem.Allocator, samples: []const u64) !LatencyGroup {
    const sorted = try allocator.dupe(u64, samples);
    defer allocator.free(sorted);
    std.mem.sort(u64, sorted, {}, std.sort.asc(u64));
    return .{
        .count = sorted.len,
        .p50_ns = percentileSorted(sorted, 50),
        .p99_ns = percentileSorted(sorted, 99),
    };
}

fn requestPathFail(comptime fmt: []const u8, args: anytype) noreturn {
    printFmt("request_path FAILED: " ++ fmt, args);
    std.process.exit(1);
}

/// Drives 1024 requests through one HandlerPool slot at the default
/// count-bounded policy, the way the server does: the call is timed until the
/// borrowed handle returns (request latency), then `handle.deinit()` is timed
/// on its own (release latency), because the server sends the body before the
/// release. A request is a "recycle" request when the pool's `recycles` counter
/// rises across its release. The request after a recycle is the "rebuild" request.
fn runRequestPath(options: Options) !void {
    const backing = std.heap.c_allocator;
    var counter = CountingAllocator{ .backing = backing };
    const allocator = counter.allocator();

    const source = readFilePosix(backing, request_path_handler, 1024 * 1024) catch |err| {
        requestPathFail("cannot read {s}: {s}", .{ request_path_handler, @errorName(err) });
    };
    defer backing.free(source);

    // Default RuntimeConfig, so the arena and value stack keep their shipped sizes.
    var pool = try HandlerPool.init(allocator, RuntimeConfig{}, source, request_path_handler, 1, 0);
    defer pool.deinit();

    // The section reports the default policy, so refuse a drifted default.
    if (pool.pooling_policy != .reuse_bounded_by_count) requestPathFail("pooling policy is not reuse_bounded_by_count", .{});
    const max_requests = pool.pooling_thresholds.max_requests;
    if (max_requests != 64) requestPathFail("default max_requests is {d}, expected 64", .{max_requests});

    var latencies: [request_path_requests]u64 = undefined;
    var release_latencies: [request_path_requests]u64 = undefined;
    var call_allocs: [request_path_requests]u64 = undefined;
    var recycled: [request_path_requests]bool = undefined;

    const alloc_base = counter.alloc_calls.load(.monotonic);
    const free_base = counter.free_calls.load(.monotonic);
    var completed: usize = 0;
    while (completed < request_path_requests) : (completed += 1) {
        const request = runtime_instance.HttpRequestView{
            .method = "GET",
            .url = "/",
            .path = "/",
            .headers = .empty,
            .body = null,
        };
        const recycles_before = pool.getMetrics().recycles;
        const allocs_before = counter.alloc_calls.load(.monotonic);
        const start = try requestPathNowNs();
        var handle = pool.executeHandlerBorrowed(request) catch |err| {
            requestPathFail("request {d} failed: {s}", .{ completed, @errorName(err) });
        };
        const end = try requestPathNowNs();
        handle.deinit();
        const released = try requestPathNowNs();
        latencies[completed] = end -| start;
        release_latencies[completed] = released -| end;
        call_allocs[completed] = counter.alloc_calls.load(.monotonic) - allocs_before;
        recycled[completed] = pool.getMetrics().recycles > recycles_before;
    }

    // Floor: no number is reported unless the run did the work it names.
    const recycles = pool.getMetrics().recycles;
    if (completed != request_path_requests) requestPathFail("completed {d} of {d} requests", .{ completed, request_path_requests });
    if (recycles < request_path_min_recycles) requestPathFail("observed {d} recycles, need at least {d}", .{ recycles, request_path_min_recycles });

    var release_samples: std.ArrayList(u64) = .empty;
    defer release_samples.deinit(backing);
    var rebuild_samples: std.ArrayList(u64) = .empty;
    defer rebuild_samples.deinit(backing);
    var rebuild_allocs: u64 = 0;
    for (0..request_path_requests) |i| {
        if (recycled[i]) try release_samples.append(backing, release_latencies[i]);
        if (i > 0 and recycled[i - 1]) {
            try rebuild_samples.append(backing, latencies[i]);
            rebuild_allocs += call_allocs[i];
        }
    }
    // Floor on the groups: a recycle on the final request has no rebuild successor.
    if (release_samples.items.len != recycles) requestPathFail("{d} recycle requests for {d} recycles", .{ release_samples.items.len, recycles });
    if (rebuild_samples.items.len + 1 < release_samples.items.len) requestPathFail("only {d} rebuild requests", .{rebuild_samples.items.len});

    const all = try latencyGroup(backing, &latencies);
    const rebuild = try latencyGroup(backing, rebuild_samples.items);
    const release = try latencyGroup(backing, release_samples.items);
    const n: f64 = @floatFromInt(request_path_requests);
    const allocs_per_request = @as(f64, @floatFromInt(counter.alloc_calls.load(.monotonic) - alloc_base)) / n;
    const frees_per_request = @as(f64, @floatFromInt(counter.free_calls.load(.monotonic) - free_base)) / n;
    const rebuild_allocs_per_request = if (rebuild.count > 0)
        @as(f64, @floatFromInt(rebuild_allocs)) / @as(f64, @floatFromInt(rebuild.count))
    else
        0;

    if (options.json) {
        var buf: [1024]u8 = undefined;
        const json = try std.fmt.bufPrint(&buf, "{{\"schema_version\":1,\"request_path\":{{\"requests\":{d},\"recycles\":{d},\"max_requests\":{d}," ++
            "\"p50_ns\":{d},\"p99_ns\":{d}," ++
            "\"recycle\":{{\"count\":{d},\"p50_ns\":{d},\"p99_ns\":{d}}}," ++
            "\"rebuild\":{{\"count\":{d},\"p50_ns\":{d},\"p99_ns\":{d},\"alloc_calls_per_request\":{d:.2}}}," ++
            "\"alloc_calls_per_request\":{d:.2},\"free_calls_per_request\":{d:.2}}}}}\n", .{
            completed,          recycles,          max_requests,
            all.p50_ns,         all.p99_ns,        release.count,
            release.p50_ns,     release.p99_ns,    rebuild.count,
            rebuild.p50_ns,     rebuild.p99_ns,    rebuild_allocs_per_request,
            allocs_per_request, frees_per_request,
        });
        writeStdout(json);
        return;
    }

    printFmt("request_path: requests={d} recycles={d} policy=reuse_bounded_by_count max_requests={d} pool=1", .{ completed, recycles, max_requests });
    printFmt("request_path all (request latency): p50={d}ns p99={d}ns", .{ all.p50_ns, all.p99_ns });
    printFmt("request_path recycle release (handle.deinit, recycles counter rose): n={d} p50={d}ns p99={d}ns", .{ release.count, release.p50_ns, release.p99_ns });
    printFmt("request_path rebuild (request latency after a recycle; p99 is the max below 100 samples): n={d} p50={d}ns p99={d}ns allocator-calls={d:.1}", .{ rebuild.count, rebuild.p50_ns, rebuild.p99_ns, rebuild_allocs_per_request });
    printFmt("request_path allocator calls per request: alloc={d:.2} free={d:.2}", .{ allocs_per_request, frees_per_request });
}

pub fn main(init: std.process.Init.Minimal) !void {
    g_args = init.args;
    const options = parseOptions();
    // Use c_allocator (libc malloc/free) for benchmarks
    // - Proper memory freeing (unlike page_allocator)
    // - No tracking overhead (unlike GPA which is 20x slower)
    const allocator = std.heap.c_allocator;

    if (options.request_path) {
        try runRequestPath(options);
        return;
    }

    const config = RuntimeConfig{
        .memory_limit = 64 * 1024 * 1024, // 64MB for benchmarks
        .use_hybrid_allocation = true, // Keep arena for performance
        // Large arena prevents overflow churn in long-running microbenches.
        .arena_size = 32 * 1024 * 1024,
        .enforce_arena_escape = false, // Allow arena escapes - script lifetime matches arena
    };

    if (options.script_path) |script_path| {
        const code = readFilePosix(allocator, script_path, 10 * 1024 * 1024) catch |err| {
            std.log.err("Failed to read script {s}: {}", .{ script_path, err });
            return;
        };
        defer allocator.free(code);

        const runtime = try HandlerInstance.init(allocator, config);
        // Note: Skip runtime.deinit() - page_allocator doesn't support individual frees
        // All memory is released when the process exits

        runtime.loadCodeNoHandler(code, script_path) catch |err| {
            std.log.err("Failed to execute script {s}: {}", .{ script_path, err });
            return;
        };

        if (options.bench) {
            runtime.interpreter.resetProfilingCounters();
            const max_i32 = std.math.maxInt(i32);
            if (options.bench_iterations > max_i32 or options.warmup_iterations > max_i32) {
                std.log.err("Iterations exceed i32 range", .{});
                return;
            }

            const warmup_arg = zq.JSValue.fromInt(@intCast(options.warmup_iterations));
            const warmup_args = [_]zq.JSValue{warmup_arg};
            var warm_idx: u32 = 0;
            while (warm_idx < options.warmup_rounds) : (warm_idx += 1) {
                _ = runtime.callGlobalFunction(options.bench_fn, &warmup_args) catch |err| {
                    std.log.err("Warmup call failed: {}", .{err});
                    return;
                };
            }

            const run_arg = zq.JSValue.fromInt(@intCast(options.bench_iterations));
            const run_args = [_]zq.JSValue{run_arg};

            const start = compat.Instant.now() catch {
                std.log.err("Timer not available", .{});
                return;
            };
            _ = runtime.callGlobalFunction(options.bench_fn, &run_args) catch |err| {
                std.log.err("Benchmark call failed: {}", .{err});
                return;
            };
            const end = compat.Instant.now() catch {
                std.log.err("Timer not available", .{});
                return;
            };

            const elapsed_ns = end.since(start);
            const elapsed_ms = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000.0;
            const ops_per_sec: u64 = if (elapsed_ns > 0)
                @intFromFloat(@as(f64, @floatFromInt(options.bench_iterations)) * 1_000_000_000.0 / @as(f64, @floatFromInt(elapsed_ns)))
            else
                0;

            const name = std.fs.path.basename(script_path);
            printFmt("bench {s}::{s} iters={} warmup={} ms={d:.3} ops/s={}", .{
                name,
                options.bench_fn,
                options.bench_iterations,
                options.warmup_rounds,
                elapsed_ms,
                ops_per_sec,
            });
            const perf = runtime.interpreter.snapshotPerfStats();
            const pic_total = @as(u64, perf.pic_hits) + @as(u64, perf.pic_misses);
            if (pic_total > 0) {
                const hit_rate = @as(f64, @floatFromInt(perf.pic_hits)) * 100.0 /
                    @as(f64, @floatFromInt(pic_total));
                printFmt("  IC: {} hits / {} total ({d:.1}%)", .{
                    perf.pic_hits, pic_total, hit_rate,
                });
            }
            return;
        }
        return;
    }

    if (!options.quiet and !options.json) {
        println("");
        println("=== zts JavaScript Engine Benchmarks ===");
        println("");
    }

    var results: [benchmarks.len]BenchmarkResult = undefined;
    for (benchmarks, 0..) |bench, i| {
        results[i] = .{
            .name = bench.name,
            .iterations = bench.iterations,
        };
    }
    var total_time_ns: u64 = 0;

    for (benchmarks, 0..) |bench, i| {
        // Create fresh runtime for each benchmark
        const runtime = try HandlerInstance.init(allocator, config);
        // Note: Skip runtime.deinit() - page_allocator doesn't support individual frees

        const start = compat.Instant.now() catch {
            println("Timer not available");
            return;
        };

        runtime.loadCodeNoHandler(bench.code, "<builtin-benchmark>") catch |err| {
            results[i].success = false;
            results[i].error_name = @errorName(err);
            if (!options.quiet and !options.json) {
                printFmt("{s}: ERROR - {}", .{ bench.name, err });
            }
            continue;
        };

        const end = compat.Instant.now() catch continue;
        const elapsed_ns = end.since(start);
        total_time_ns += elapsed_ns;
        const perf = runtime.interpreter.snapshotPerfStats();

        results[i].time_ms = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000.0;
        results[i].ops_per_sec = if (elapsed_ns > 0)
            @intFromFloat(@as(f64, @floatFromInt(bench.iterations)) * 1_000_000_000.0 / @as(f64, @floatFromInt(elapsed_ns)))
        else
            0;
        results[i].perf = perf;
        results[i].opt_stats = runtime.last_opt_stats;

        if (!options.quiet and !options.json) {
            printFmt("{s}: {d:.3}ms ({} ops/sec)", .{ bench.name, results[i].time_ms, results[i].ops_per_sec });
            const pic_total = @as(u64, results[i].perf.pic_hits) + @as(u64, results[i].perf.pic_misses);
            if (pic_total > 0) {
                const hit_rate = @as(f64, @floatFromInt(results[i].perf.pic_hits)) * 100.0 /
                    @as(f64, @floatFromInt(pic_total));
                printFmt("  IC: {} hits / {} total ({d:.1}%)", .{
                    results[i].perf.pic_hits, pic_total, hit_rate,
                });
            }
        }
    }

    if (options.json) {
        var output: std.ArrayList(u8) = .empty;
        defer output.deinit(allocator);
        var aw: std.Io.Writer.Allocating = .fromArrayList(allocator, &output);
        try aw.writer.writeAll("{\n  \"schema_version\":1,\n  \"benchmarks\":[\n");
        for (results, 0..) |result, i| {
            try aw.writer.writeAll("    ");
            try writeBenchmarkResultJson(&aw.writer, result);
            if (i + 1 < results.len) {
                try aw.writer.writeAll(",\n");
            } else {
                try aw.writer.writeAll("\n");
            }
        }
        const total_ms = @as(f64, @floatFromInt(total_time_ns)) / 1_000_000.0;
        try aw.writer.print("  ],\n  \"total_ms\":{d:.3}\n}}\n", .{total_ms});
        output = aw.toArrayList();
        writeStdout(output.items);
        return;
    }

    const total_ms = @as(f64, @floatFromInt(total_time_ns)) / 1_000_000.0;
    printFmt("Total time: {d:.1}ms", .{total_ms});
    println("");
}
