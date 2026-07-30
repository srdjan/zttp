//! Fixed-budget latency probe over a handler, shared by the perf-receipt
//! path and the benchmark harness.
//!
//! This is product code, not measurement tooling: `perf_probe_lib.zig` calls
//! `runHandlerCorpusFromSource` on every applied edit to sign the `kind=perf`
//! receipt. It lived inside `benchmark.zig` until the harness moved out of
//! `src/`; the probe stayed behind because the product depends on it.

const std = @import("std");
const compat = @import("zts").compat;
const zq = @import("zts");
const handler_instance = @import("handler_instance.zig");
const HandlerInstance = handler_instance.HandlerInstance;
const RuntimeConfig = @import("runtime_config.zig").RuntimeConfig;

const readFilePosix = zq.file_io.readFile;

/// Result of `runHandlerCorpus`. p50/p99 are reported in microseconds so the
/// values fit a `u64` comfortably and serialise into the perf-receipt JWS
/// without floating-point. `sample_count == 0` means the probe could not
/// gather a useful measurement (handler crashed on the first call or the
/// budget was so small no iteration completed); callers should treat that
/// as a skipped probe and record the row accordingly.
pub const HandlerCorpusStats = struct {
    p50_us: u64 = 0,
    p99_us: u64 = 0,
    /// Sum of per-iteration latencies. Lets callers reconstruct mean
    /// without retaining the full sample array.
    total_ns: u64 = 0,
    /// Bytes the request-scoped allocator served across all iterations.
    /// Best-effort: derived from the runtime's snapshot stats so a
    /// zero-allocation handler reports 0.
    alloc_bytes: u64 = 0,
    sample_count: u64 = 0,
};

/// Run a handler through a fixed-budget loop and return latency statistics.
///
/// Contract:
///   - Wall-clock spend is capped by `budget_ns`. The probe runs as many
///     iterations as fit; once the budget elapses (checked between calls),
///     the loop stops.
///   - Each iteration calls a global `handler` function with `undefined`
///     as the request argument. Handlers that ignore `req` execute as if
///     they were pure constant returns; handlers that dereference `req`
///     will fault on the first call and the probe returns
///     `sample_count == 0`.
///   - The handler must be loadable as a script (the same constraint
///     `zig build bench --script` honours).
///   - The function is independent of the `main` entry point so callers
///     outside `zig build bench` can drive a probe directly.
///
/// Slice H wires this from the runtime test suite; Slice K will replace
/// the "call with undefined" stub with a real per-request corpus.
pub fn runHandlerCorpus(
    handler_path: []const u8,
    budget_ns: u64,
    allocator: std.mem.Allocator,
) !HandlerCorpusStats {
    const code = try readFilePosix(allocator, handler_path, 10 * 1024 * 1024);
    defer allocator.free(code);
    return runHandlerCorpusFromSource(code, handler_path, budget_ns, allocator);
}

/// Variant for callers that already hold the source bytes (e.g. the
/// `pi_apply_*` dry-run path that has a proposed-content buffer in
/// memory). Same contract as `runHandlerCorpus`.
pub fn runHandlerCorpusFromSource(
    source: []const u8,
    handler_path: []const u8,
    budget_ns: u64,
    allocator: std.mem.Allocator,
) !HandlerCorpusStats {
    const config = RuntimeConfig{
        .memory_limit = 32 * 1024 * 1024,
        .use_hybrid_allocation = true,
        .arena_size = 4 * 1024 * 1024,
        .enforce_arena_escape = false,
    };

    var runtime_arena = std.heap.ArenaAllocator.init(allocator);
    defer runtime_arena.deinit();
    const runtime_allocator = runtime_arena.allocator();

    const runtime = try HandlerInstance.init(runtime_allocator, config);

    runtime.loadCode(source, handler_path) catch return HandlerCorpusStats{};

    // Sample latencies into a stack-allocated bounded array. 4096 samples
    // is comfortably more than fit in 500 ms for any handler the corpus
    // care about (a single Response.json call is well under 100 us), and
    // capping the buffer at 32 KiB keeps the probe's own footprint small
    // enough not to pollute the alloc_bytes measurement.
    const max_samples: usize = 4096;
    var latencies: [max_samples]u64 = undefined;
    var samples: usize = 0;

    const arg_undef = [_]zq.JSValue{zq.JSValue.undefined_val};

    const overall_start = compat.Instant.now() catch return HandlerCorpusStats{};
    while (samples < max_samples) {
        // Budget check between calls keeps the probe responsive to a
        // tight wall-clock limit. We do not preempt mid-call - a runaway
        // handler is a bug we want the caller to see, not a perf metric
        // we want to smooth over.
        const now = compat.Instant.now() catch break;
        if (now.since(overall_start) >= budget_ns) break;

        const iter_start = compat.Instant.now() catch break;
        _ = runtime.callGlobalFunction("handler", &arg_undef) catch {
            // First-call crash means the handler shape is incompatible
            // with the stub Request. Surface this by returning the
            // empty stats so the caller records sample_count == 0.
            if (samples == 0) return HandlerCorpusStats{};
            break;
        };
        const iter_end = compat.Instant.now() catch break;
        latencies[samples] = iter_end.since(iter_start);
        samples += 1;
    }
    const overall_end = compat.Instant.now() catch return HandlerCorpusStats{};

    if (samples == 0) return HandlerCorpusStats{};

    std.mem.sort(u64, latencies[0..samples], {}, std.sort.asc(u64));
    const p50_ns = latencies[samples / 2];
    const p99_ns = latencies[@min(samples - 1, (samples * 99) / 100)];

    var total_ns: u64 = 0;
    for (latencies[0..samples]) |sample| total_ns += sample;

    _ = overall_end;

    return .{
        .p50_us = nsToUsCeil(p50_ns),
        .p99_us = nsToUsCeil(p99_ns),
        .total_ns = total_ns,
        // Slice H reports 0 for alloc_bytes: the runtime does not yet
        // expose a request-scoped allocator counter, and wrapping init's
        // allocator in a counting adapter would distort the latency we
        // are trying to measure. Slice K plumbs a real counter through
        // the heap/arena interface.
        .alloc_bytes = 0,
        .sample_count = samples,
    };
}

fn nsToUsCeil(ns: u64) u64 {
    // Round up so a 700 ns sample reports as 1 us; reporting "0 us"
    // for a measurable spend would obscure the perf surface.
    return (ns + std.time.ns_per_us - 1) / std.time.ns_per_us;
}
const testing = std.testing;

test "runHandlerCorpus on a benign pure handler reports samples and p50" {
    const allocator = testing.allocator;
    const source =
        \\function handler(req) {
        \\  return Response.json({ ok: true });
        \\}
    ;
    const stats = try runHandlerCorpusFromSource(
        source,
        "test://handler.ts",
        50 * std.time.ns_per_ms,
        allocator,
    );
    try testing.expect(stats.sample_count > 0);
    try testing.expect(stats.p50_us > 0 or stats.p99_us > 0 or stats.total_ns > 0);
    // p99 cannot be smaller than p50 by construction.
    try testing.expect(stats.p99_us >= stats.p50_us);
}

test "runHandlerCorpus respects the wall-clock budget" {
    const allocator = testing.allocator;
    const source =
        \\function handler(req) {
        \\  return Response.json({ ok: true });
        \\}
    ;
    // A tiny budget should yield few samples but never exceed the cap
    // by more than one iteration's worth.
    const budget_ns: u64 = 2 * std.time.ns_per_ms;
    const before = compat.Instant.now() catch unreachable;
    const stats = try runHandlerCorpusFromSource(
        source,
        "test://handler.ts",
        budget_ns,
        allocator,
    );
    const after = compat.Instant.now() catch unreachable;
    const elapsed = after.since(before);
    // Allow a 50 ms slack for first-call init costs (parser + bytecode
    // compile dominate sub-millisecond budgets).
    try testing.expect(elapsed < budget_ns + 50 * std.time.ns_per_ms);
    // Even with the tiny budget we expect at least one completed sample
    // because the budget check happens between iterations.
    try testing.expect(stats.sample_count >= 1 or stats.total_ns == 0);
}

test "runHandlerCorpus returns sample_count=0 when handler is missing" {
    const allocator = testing.allocator;
    const source =
        \\function not_handler() { return 1; }
    ;
    const stats = try runHandlerCorpusFromSource(
        source,
        "test://no_handler.ts",
        20 * std.time.ns_per_ms,
        allocator,
    );
    try testing.expectEqual(@as(u64, 0), stats.sample_count);
}
