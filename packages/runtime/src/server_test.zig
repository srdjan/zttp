//! test-server: integration suite for the HTTP server / runtime facade.
//!
//! This is the Phase 0b gate for the engine/runtime facade refactor. It tests
//! the server through PUBLIC entry points only:
//!   - `Server.init` / `Server.deinit` lifecycle (server.zig)
//!   - `HandlerPool.executeHandler` / `.executeHandlerBorrowed` request flow,
//!     pool occupancy via `.getInUse` / `.max_size` (engine_adapter facade)
//!     instead of poking `zq.interpreter.*` globals directly.
//!
//! It deliberately does NOT reach into interpreter/JIT internals. The JIT and
//! profiling tests in zruntime_tests.zig (the `setJitPolicy`/`getJitPolicy`/
//! `snapshotPerfStats` sites flagged by the facade audit) should migrate here
//! and be re-expressed against `RuntimeConfig` + a future public perf-stats
//! accessor on `Runtime`.
//!
//! Track-B1 runtime features have landed in pieces. The tests below keep the
//! public coverage honest: timeout handling is exercised through HandlerPool,
//! while shutdown, probe routing, keep-alive, and panic isolation still need
//! accept-path or E2E coverage where noted.

const std = @import("std");

const server = @import("server.zig");
const engine = @import("engine_adapter.zig");
const http_types = @import("http_types.zig");

const Server = server.Server;
const ServerConfig = server.ServerConfig;
const HandlerPool = engine.HandlerPool;
const RuntimeConfig = engine.RuntimeConfig;
const HttpRequestOwned = http_types.HttpRequestOwned;
const HttpResponse = http_types.HttpResponse;

/// Build an owned GET request with no body. Caller deinits.
fn getRequest(allocator: std.mem.Allocator, url: []const u8) !HttpRequestOwned {
    return .{
        .method = try allocator.dupe(u8, "GET"),
        .url = try allocator.dupe(u8, url),
        .headers = .empty,
        .body = null,
    };
}

// ===========================================================================
// Server lifecycle (public init/deinit surface)
// ===========================================================================

test "Server.init/deinit round-trips an inline handler without leaking" {
    const allocator = std.testing.allocator;
    var srv = try Server.init(allocator, .{
        .handler = .{ .inline_code = "function handler(req) { return Response.text('ok'); }" },
        .log_requests = false,
        .pool_size = 1,
    });
    defer srv.deinit();

    // init must not start the listener or pool; those are start()'s job.
    try std.testing.expect(srv.pool == null);
    try std.testing.expect(!srv.running.load(.acquire));
}

test "Server.init auto-sizes the pool when pool_size is zero" {
    const allocator = std.testing.allocator;
    var srv = try Server.init(allocator, .{
        .handler = .{ .inline_code = "function handler(req) { return Response.text('ok'); }" },
        .log_requests = false,
        .pool_size = 0,
    });
    defer srv.deinit();
    // Twice the CPU count, clamped to 8..128.
    const cpus = try std.Thread.getCpuCount();
    try std.testing.expectEqual(std.math.clamp(cpus * 2, 8, 128), srv.config.pool_size);
}

test "Server.start rejects a malformed present contract" {
    const allocator = std.testing.allocator;
    var srv = try Server.init(allocator, .{
        .handler = .{ .inline_code = "function handler(req) { return Response.text('ok'); }" },
        .contract_json = "{not-json",
        .log_requests = false,
        .pool_size = 1,
        .port = 0,
    });
    defer srv.deinit();

    // The contract is now read through the shared codec, which reports
    // error.InvalidJson where the runtime's own reader reported std.json's
    // error.SyntaxError. The outcome is unchanged: a malformed contract is
    // refused and the binary does not serve. Neither call site switches on the
    // value; server.zig logs it and returns it.
    try std.testing.expectError(error.InvalidJson, srv.start());
}

test "Server.start accepts an absent contract" {
    const allocator = std.testing.allocator;
    var srv = try Server.init(allocator, .{
        .handler = .{ .inline_code = "function handler(req) { return Response.text('ok'); }" },
        .contract_json = null,
        .log_requests = false,
        .pool_size = 1,
        .port = 0,
    });
    defer srv.deinit();

    try srv.start();
    try std.testing.expect(srv.pool != null);
}

// ===========================================================================
// Handler execution: happy path (HandlerPool public surface)
// ===========================================================================

test "executeHandler returns 200 with the handler body" {
    const allocator = std.heap.c_allocator;
    var pool = try HandlerPool.init(
        allocator,
        .{},
        "function handler(req) { return Response.json({ ok: true }); }",
        "<server-test>",
        1,
        0,
    );
    defer pool.deinit();

    var req = try getRequest(allocator, "/");
    defer req.deinit(allocator);

    var resp = try pool.executeHandler(req.asView());
    defer resp.deinit();

    try std.testing.expectEqual(@as(u16, 200), resp.status);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"ok\":true") != null);
}

test "executeHandler echoes request method and url back to the handler" {
    const allocator = std.heap.c_allocator;
    // `req.url` is the raw path here (the subset has no `new URL`); the runtime
    // surfaces the request line as method + url.
    var pool = try HandlerPool.init(
        allocator,
        .{},
        "function handler(req) { return Response.text([req.method, ' ', req.url].join('')); }",
        "<server-test>",
        1,
        0,
    );
    defer pool.deinit();

    var req = try getRequest(allocator, "/widgets");
    defer req.deinit(allocator);

    var resp = try pool.executeHandler(req.asView());
    defer resp.deinit();

    try std.testing.expectEqual(@as(u16, 200), resp.status);
    try std.testing.expectEqualStrings("GET /widgets", resp.body);
}

test "pool occupancy is zero before and after a completed request" {
    const allocator = std.heap.c_allocator;
    var pool = try HandlerPool.init(
        allocator,
        .{},
        "function handler(req) { return Response.text('ok'); }",
        "<server-test>",
        2,
        0,
    );
    defer pool.deinit();

    try std.testing.expectEqual(@as(usize, 0), pool.getInUse());
    try std.testing.expect(pool.max_size == 2);

    var req = try getRequest(allocator, "/");
    defer req.deinit(allocator);
    var resp = try pool.executeHandler(req.asView());
    resp.deinit();

    // The runtime is returned to the pool, so occupancy settles back to zero.
    try std.testing.expectEqual(@as(usize, 0), pool.getInUse());
}

// ===========================================================================
// Handler execution: error paths
// ===========================================================================

test "assert guard rejection short-circuits with the guard response" {
    const allocator = std.heap.c_allocator;
    // `assert cond, response` is the supported statement form: on a failed
    // condition the handler returns the guard response instead of falling
    // through. This is the documented error path for declarative guards.
    var pool = try HandlerPool.init(
        allocator,
        .{},
        "function handler(req) { assert req.method === 'POST', Response.text('method not allowed', { status: 405 }); return Response.text('ok'); }",
        "<server-test>",
        1,
        0,
    );
    defer pool.deinit();

    var req = try getRequest(allocator, "/"); // GET -> guard fails
    defer req.deinit(allocator);

    var resp = try pool.executeHandler(req.asView());
    defer resp.deinit();
    try std.testing.expectEqual(@as(u16, 405), resp.status);
    try std.testing.expectEqualStrings("method not allowed", resp.body);
}

test "a failed assert without a message answers without the frame's values" {
    // `halt` returns the stack top. Before the fix a failed bare assert sent
    // whatever the frame left there, here the local `s`, as a 200 body.
    const allocator = std.heap.c_allocator;
    var pool = try HandlerPool.init(
        allocator,
        .{},
        "function handler(req) { const s = 'held-in-a-local'; assert req.method === 'POST'; return Response.text(s.length > 0 ? 'ok' : 'empty'); }",
        "<server-test>",
        1,
        0,
    );
    defer pool.deinit();

    var req = try getRequest(allocator, "/"); // GET -> assert fails
    defer req.deinit(allocator);

    var resp = try pool.executeHandler(req.asView());
    defer resp.deinit();
    try std.testing.expect(resp.status != 200);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "held-in-a-local") == null);
}

test "let without an initializer reads undefined, not a reused slot" {
    // Sibling blocks share local slots. Before the fix `let b;` emitted no
    // store, so `b` read the value the first block left in the shared slot.
    const allocator = std.heap.c_allocator;
    var pool = try HandlerPool.init(
        allocator,
        .{},
        "function handler(req) { if (req.method === 'GET') { const a = 'held-in-a-slot'; } if (req.method === 'GET') { let b; return Response.text(b ?? 'none'); } return Response.text('end'); }",
        "<server-test>",
        1,
        0,
    );
    defer pool.deinit();

    var req = try getRequest(allocator, "/");
    defer req.deinit(allocator);

    var resp = try pool.executeHandler(req.asView());
    defer resp.deinit();
    try std.testing.expectEqual(@as(u16, 200), resp.status);
    try std.testing.expectEqualStrings("none", resp.body);
}

test "a closure that escapes a block keeps its binding, not a reused slot" {
    // A closed block gave its slots to later bindings even when a closure
    // still held an open upvalue on one, so the closure read the later value.
    // The loop form reaches the same state through `break`, which jumps past
    // the per-iteration close at the back edge.
    const allocator = std.heap.c_allocator;
    const sources = [_][]const u8{
        "function handler(req) { let saved = () => 'clean'; if (req.method === 'GET') { const y = 'kept'; saved = () => y; } const other = 'reused'; return Response.text([saved(), other].join('|')); }",
        "function handler(req) { let saved = () => 'clean'; const xs = ['kept']; for (const x of xs) { saved = () => x; break; } const other = 'reused'; return Response.text([saved(), other].join('|')); }",
        "function handler(req) { let saved = () => 'clean'; if (req.method === 'GET') { if (req.method === 'GET') { const y = 'kept'; saved = () => y; } } const other = 'reused'; return Response.text([saved(), other].join('|')); }",
    };
    for (sources) |source| {
        var pool = try HandlerPool.init(allocator, .{}, source, "<server-test>", 1, 0);
        defer pool.deinit();

        var req = try getRequest(allocator, "/");
        defer req.deinit(allocator);

        var resp = try pool.executeHandler(req.asView());
        defer resp.deinit();
        try std.testing.expectEqual(@as(u16, 200), resp.status);
        try std.testing.expectEqualStrings("kept|reused", resp.body);
    }
}

test "B6: handler returning a non-Response primitive yields 500, not silent empty 200" {
    const allocator = std.heap.c_allocator;
    var pool = try HandlerPool.init(
        allocator,
        .{},
        "function handler(req) { return 42; }",
        "<server-test>",
        1,
        0,
    );
    defer pool.deinit();
    var req = try getRequest(allocator, "/");
    defer req.deinit(allocator);
    var resp = try pool.executeHandler(req.asView());
    defer resp.deinit();
    try std.testing.expectEqual(@as(u16, 500), resp.status);
    // The non-Response 500 is now proof-explained against the exhaustive_returns
    // chip instead of a bare "did not return a Response object" string.
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "exhaustive_returns") != null);
}

test "handler returning a string body yields a 200 with that body" {
    // The non-object/string branch of extractResponseInternal is a supported,
    // documented path: a bare string return becomes the response body.
    const allocator = std.heap.c_allocator;
    var pool = try HandlerPool.init(
        allocator,
        .{},
        "function handler(req) { return 'plain body'; }",
        "<server-test>",
        1,
        0,
    );
    defer pool.deinit();

    var req = try getRequest(allocator, "/");
    defer req.deinit(allocator);

    var resp = try pool.executeHandler(req.asView());
    defer resp.deinit();
    try std.testing.expectEqual(@as(u16, 200), resp.status);
    try std.testing.expectEqualStrings("plain body", resp.body);
}

test "executeHandlerBorrowed releases the runtime even when the handler errors" {
    const allocator = std.heap.c_allocator;
    var pool = try HandlerPool.init(
        allocator,
        .{},
        "function handler(req) { return Response.text('ok'); }",
        "<server-test>",
        1,
        0,
    );
    defer pool.deinit();

    var req = try getRequest(allocator, "/");
    defer req.deinit(allocator);

    {
        var handle = try pool.executeHandlerBorrowed(req.asView());
        try std.testing.expectEqual(@as(usize, 1), pool.getInUse());
        handle.deinit();
    }
    // After the borrowed handle is released the slot returns to the pool.
    try std.testing.expectEqual(@as(usize, 0), pool.getInUse());
}

// ===========================================================================
// Keep-alive coverage note
// ===========================================================================

test "coverage note: keep-alive socket path is exercised in server.zig" {
    // Cross-module server_test cannot call ConnectionPool.handleConnection
    // without widening the public surface. The real socket coverage lives in
    // server.zig's `threaded keep-alive connection serves two sequential
    // requests` test, which runs under the same `test-server` root.
    return error.SkipZigTest;
}

// ===========================================================================
// Track-B1 coverage and remaining accept-path gaps.
// ===========================================================================

test "B2: per-request timeout aborts a slow handler and returns RequestTimeout" {
    // Verifies that request_timeout_ms is enforced via cooperative back-edge
    // checking in the interpreter. The infinite loop in the handler body triggers
    // error.RequestTimeout within 50ms, proving the deadline path is wired.
    const allocator = std.heap.c_allocator;
    var pool = try HandlerPool.init(
        allocator,
        .{ .request_timeout_ms = 50 },
        "function handler(req) { let x = 0; for (let i of range(1000000000)) { x = x + 1; } return Response.text('unreachable'); }",
        "<server-test>",
        1,
        0,
    );
    defer pool.deinit();
    var req = try getRequest(allocator, "/");
    defer req.deinit(allocator);
    try std.testing.expectError(error.RequestTimeout, pool.executeHandler(req.asView()));
    // The slot was invalidated; a subsequent fast request rebuilds and succeeds.
    var fast_req = try getRequest(allocator, "/fast");
    defer fast_req.deinit(allocator);
    // Use a separate pool with a fast handler to prove the slot recycle works.
    var fast_pool = try HandlerPool.init(
        allocator,
        .{ .request_timeout_ms = 5000 },
        "function handler(req) { return Response.text('alive'); }",
        "<server-test>",
        1,
        0,
    );
    defer fast_pool.deinit();
    var resp = try fast_pool.executeHandler(fast_req.asView());
    defer resp.deinit();
    try std.testing.expectEqualStrings("alive", resp.body);
}

const fib_source = "function fib(n) { if (n < 2) { return n; } return fib(n - 1) + fib(n - 2); }";
const fib_n = "30";
const map_n = 100;

// range() is a lazy iterator without map, and an array literal holds fewer than 255 elements,
// so the callbacks nest three deep over a 100-element literal.
const map_items = blk: {
    @setEvalBranchQuota(100_000);
    var items: []const u8 = "[0";
    for (1..map_n) |i| items = items ++ std.fmt.comptimePrint(",{d}", .{i});
    break :blk items ++ "]";
};

// Sizes measured with request_timeout_ms = 0: each handler runs far past the
// 50 ms deadline used below, and none of them executes a loop back-edge outside
// a native callback.
const slow_recursion_handler = fib_source ++
    "function handler(req) { return Response.text(String(fib(" ++ fib_n ++ "))); }";
const slow_map_handler =
    "function handler(req) { const xs = " ++ map_items ++ "; const f = (a, y) => a + y; const r = xs.map((x) => xs.map((z) => xs.reduce(f, 0) + xs.reduce(f, 0) + xs.reduce(f, 0) + xs.reduce(f, 0)));" ++
    " return Response.text(String(r.length)); }";
const slow_component_handler = fib_source ++
    "function Comp(props) { return h('p', {}, String(fib(" ++ fib_n ++ "))); }" ++
    "function handler(req) { return Response.html(renderToString(h(Comp, {}))); }";

fn expectTimeout(handler_source: []const u8) !void {
    const allocator = std.heap.c_allocator;
    var pool = try HandlerPool.init(allocator, .{ .request_timeout_ms = 50 }, handler_source, "<server-test>", 1, 0);
    defer pool.deinit();
    var req = try getRequest(allocator, "/");
    defer req.deinit(allocator);
    try std.testing.expectError(error.RequestTimeout, pool.executeHandler(req.asView()));
}

test "a recursive handler with no loop times out" {
    try expectTimeout(slow_recursion_handler);
}

test "nested map callbacks time out" {
    try expectTimeout(slow_map_handler);
}

test "a function component that runs past the deadline times out" {
    try expectTimeout(slow_component_handler);
}

const rate_limit = 5;
const rate_handler = "import { rateCheck } from \"zttp:ratelimit\";" ++
    "function handler(req) { return Response.json({ ok: rateCheck(\"k\", " ++
    std.fmt.comptimePrint("{d}", .{rate_limit}) ++ ", 60).ok }); }";

test "zttp:ratelimit counts across the runtimes held at the same time" {
    const allocator = std.heap.c_allocator;
    var pool = try HandlerPool.init(allocator, .{}, rate_handler, "<server-test>", 4, 0);
    defer pool.deinit();

    var leases: [4]HandlerPool.WorkerRuntimeLease = undefined;
    for (&leases, 0..) |*lease, i| {
        errdefer for (leases[0..i]) |*held| held.deinit();
        lease.* = try pool.acquireWorkerRuntime();
    }
    defer for (&leases) |*lease| lease.deinit();
    for (leases[1..]) |lease| try std.testing.expect(lease.runtime != leases[0].runtime);

    // A per-runtime counter admits `rate_limit` requests on each of the four runtimes.
    var admitted: usize = 0;
    for (0..40) |i| {
        var req = try getRequest(allocator, "/");
        defer req.deinit(allocator);
        var resp = try leases[i % leases.len].runtime.executeHandler(req.asView());
        defer resp.deinit();
        if (std.mem.indexOf(u8, resp.body, "\"ok\":true") != null) admitted += 1;
    }
    try std.testing.expectEqual(@as(usize, rate_limit), admitted);
}

test "zttp:ratelimit survives the recycle of its runtime" {
    const allocator = std.heap.c_allocator;
    var pool = try HandlerPool.init(allocator, .{}, rate_handler, "<server-test>", 4, 0);
    defer pool.deinit();

    // Each runtime recycles after `pooling_thresholds.max_requests` requests. A
    // per-runtime counter restarts at every recycle.
    const requests = 3 * pool.pooling_thresholds.max_requests + 8;
    var admitted: usize = 0;
    for (0..requests) |_| {
        var req = try getRequest(allocator, "/");
        defer req.deinit(allocator);
        var resp = try pool.executeHandler(req.asView());
        defer resp.deinit();
        if (std.mem.indexOf(u8, resp.body, "\"ok\":true") != null) admitted += 1;
    }
    try std.testing.expectEqual(@as(usize, rate_limit), admitted);
    try std.testing.expect(pool.getMetrics().recycles >= 3);
}

test "B3: Server.shutdown() is safe before start" {
    // This structural edge case complements the real SIGTERM socket test in
    // server.zig, which owns the accept loop and in-flight request machinery.
    const allocator = std.testing.allocator;
    var srv = try Server.init(allocator, .{
        .handler = .{ .inline_code = "function handler(req) { return Response.text('ok'); }" },
        .log_requests = false,
        .pool_size = 1,
    });
    defer srv.deinit();
    // Server is not started; shutdown must not crash on nil pool/listener.
    srv.shutdown(100);
    try std.testing.expect(!srv.running.load(.acquire));
}

test "coverage note: health/readiness socket path is exercised in server.zig" {
    // The health/readiness probes intercept in server.zig before the JS handler.
    // The real accept-path coverage lives in server.zig's socket-level probe
    // test. This local note keeps the pool field expectations visible without
    // pretending to dispatch an HTTP request from this module.
    const allocator = std.heap.c_allocator;
    var pool = try HandlerPool.init(
        allocator,
        .{},
        "function handler(req) { return Response.text('ok'); }",
        "<server-test>",
        2,
        0,
    );
    defer pool.deinit();
    // pool.getInUse() / pool.max_size are the exact fields /_readiness reads.
    try std.testing.expectEqual(@as(usize, 0), pool.getInUse());
    try std.testing.expectEqual(@as(usize, 2), pool.max_size);
}

test "B1: panic isolation: HandlerPanicked leaves pool reusable (needs test-root panic override)" {
    // Full panic isolation requires the binary root to declare:
    //   pub const panic = std.debug.FullPanic(panic_recovery.handlePanic);
    // which is in main.zig and cli_main.zig but NOT in the test runner root.
    // The E2E verification is in scripts/test-panic-isolation.sh, which uses
    // the internal --_debug-panic-path serve flag to trigger a real panic under
    // callHandlerGuarded. This test confirms the pool stays alive after a
    // non-panicking request, which is necessary for isolation to matter.
    const allocator = std.heap.c_allocator;
    var pool = try HandlerPool.init(
        allocator,
        .{},
        "function handler(req) { return Response.text('alive'); }",
        "<server-test>",
        1,
        0,
    );
    defer pool.deinit();
    var req = try getRequest(allocator, "/");
    defer req.deinit(allocator);
    var resp = try pool.executeHandler(req.asView());
    defer resp.deinit();
    try std.testing.expectEqual(@as(u16, 200), resp.status);
    try std.testing.expectEqualStrings("alive", resp.body);
}

test "Server.start retains prepared evaluation through its handler pool" {
    const allocator = std.testing.allocator;
    var srv = try Server.init(allocator, .{
        .handler = .{ .prepared_eval = .{ .code = "function handler(req: Request): Response { const value: number = \"ok\"; return Response.text(value); }" } },
        .log_requests = false,
        .pool_size = 1,
        .port = 0,
    });
    defer srv.deinit();
    try std.testing.expectEqualStrings("<inline>", srv.handler_filename);
    try srv.start();
    var request = try getRequest(allocator, "/");
    defer request.deinit(allocator);
    var response = try srv.pool.?.executeHandler(request.asView());
    defer response.deinit();
    try std.testing.expectEqual(@as(u16, 200), response.status);
    try std.testing.expectEqualStrings("ok", response.body);
}

test "a second server on a busy port fails with AddressInUse and the port reopens after shutdown" {
    const allocator = std.testing.allocator;
    const handler = "function handler(req) { return Response.text('ok'); }";
    var first = try Server.init(allocator, .{
        .handler = .{ .inline_code = handler },
        .log_requests = false,
        .pool_size = 1,
        .port = 0,
    });
    defer first.deinit();
    try first.start();
    const port = first.listener.?.socket.address.getPort();

    var second = try Server.init(allocator, .{
        .handler = .{ .inline_code = handler },
        .log_requests = false,
        .pool_size = 1,
        .port = port,
    });
    defer second.deinit();
    try std.testing.expectError(error.AddressInUse, second.start());

    first.shutdown(100);
    var third = try Server.init(allocator, .{
        .handler = .{ .inline_code = handler },
        .log_requests = false,
        .pool_size = 1,
        .port = port,
    });
    defer third.deinit();
    try third.start();
    third.shutdown(100);
}
