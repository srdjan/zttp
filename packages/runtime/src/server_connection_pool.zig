//! The threaded connection pool behind `Server`: accept queue, worker threads, and per-connection request handling.

const std = @import("std");
const engine = @import("engine_adapter.zig");
const Io = std.Io;
const http_parser = @import("http_parser.zig");
const http_types = @import("http_types.zig");
const HttpRequestView = http_types.HttpRequestView;
const HttpResponse = http_types.HttpResponse;
const HttpHeader = http_types.HttpHeader;
const fault_explain = @import("fault_explain.zig");
const proof_adapter = @import("proof_adapter.zig");
const attest_well_known = @import("attest/well_known.zig");
const response_mod = @import("server_response.zig");
const static_mod = @import("server_static.zig");
const resolveStaticFile = static_mod.resolveStaticFile;
const io_mod = @import("posix_util.zig");
const unixMillisNow = io_mod.unixMillisNow;
const writeAllFd = io_mod.writeAllFd;
const createUnixSocketPair = io_mod.createUnixSocketPair;
const writevAllFd = io_mod.writevAllFd;
const etagMatchesIfNoneMatch = http_types.etagMatchesIfNoneMatch;
const findHeaderValue = http_types.findHeaderValue;
const formatHttpError = response_mod.formatHttpError;
const formatStaticNotModified = response_mod.formatStaticNotModified;
const formatStaticOkHeader = response_mod.formatStaticOkHeader;
const buildDynamicResponseHeader = response_mod.buildDynamicResponseHeader;
const formatWellKnownHeaders = response_mod.formatWellKnownHeaders;
const findHeaderEnd = http_parser.findHeaderEnd;
const parseContentLength = http_parser.parseContentLength;
const server_mod = @import("server.zig");
const Server = server_mod.Server;

// ============================================================================
// Connection Thread Pool (for macOS threaded backend)
// ============================================================================

const max_logged_request_id_len: usize = 128;

const max_logged_access_field_len: usize = 256;

const max_logged_access_field_bytes: usize = max_logged_access_field_len * 3;

fn accessLogRequestId(value: ?[]const u8) []const u8 {
    const raw = value orelse return "-";
    if (raw.len == 0 or raw.len > max_logged_request_id_len) return "-";
    for (raw) |c| {
        if (!isAccessLogRequestIdByte(c)) return "-";
    }
    return raw;
}

fn isAccessLogRequestIdByte(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.' or c == ':';
}

fn accessLogField(value: []const u8, out: *[max_logged_access_field_bytes]u8) []const u8 {
    if (value.len == 0) return "-";

    const input = value[0..@min(value.len, max_logged_access_field_len)];
    var pos: usize = 0;
    for (input) |c| {
        if (isAccessLogFieldByte(c)) {
            out[pos] = c;
            pos += 1;
            continue;
        }
        out[pos] = '%';
        out[pos + 1] = hexDigit(c >> 4);
        out[pos + 2] = hexDigit(c & 0x0f);
        pos += 3;
    }

    return if (pos == 0) "-" else out[0..pos];
}

fn isAccessLogFieldByte(c: u8) bool {
    return c > 0x20 and c < 0x7f;
}

fn hexDigit(n: u8) u8 {
    return if (n < 10) '0' + n else 'A' + (n - 10);
}

/// Thread pool for handling connections without spawning threads per-connection.
/// Used on macOS where evented I/O is unavailable.
pub const ConnectionPool = struct {
    workers: []std.Thread,
    queue: BoundedQueue,
    running: std.atomic.Value(bool),
    server: *Server,
    allocator: std.mem.Allocator,

    // Increased from 256 to handle burst traffic without rejecting connections
    pub const QUEUE_SIZE = 4096;

    pub const WorkItem = struct {
        stream_fd: std.posix.fd_t,
    };

    /// Mutex-protected SPMC (single-producer, multiple-consumer) bounded queue.
    /// Workers block on a semaphore when the queue is empty to avoid spin-wait CPU burn.
    pub const BoundedQueue = struct {
        items: [QUEUE_SIZE]WorkItem,
        head: usize,
        tail: usize,
        count: std.atomic.Value(usize), // Atomic for lock-free count check
        mutex: engine.Mutex,
        ready: std.Io.Semaphore,

        pub fn init() BoundedQueue {
            return .{
                .items = undefined,
                .head = 0,
                .tail = 0,
                .count = std.atomic.Value(usize).init(0),
                .mutex = .{},
                .ready = .{},
            };
        }

        pub fn push(self: *BoundedQueue, item: WorkItem) bool {
            // Fast-fail under obvious saturation to keep accept loop non-blocking.
            if (self.count.load(.acquire) >= QUEUE_SIZE) return false;

            self.mutex.lock();
            const cnt = self.count.load(.acquire);
            if (cnt >= QUEUE_SIZE) {
                self.mutex.unlock();
                return false; // Queue full
            }

            self.items[self.tail] = item;
            self.tail = (self.tail + 1) % QUEUE_SIZE;
            _ = self.count.fetchAdd(1, .release);
            self.mutex.unlock();
            self.ready.post(std.Options.debug_io);
            return true;
        }

        pub fn pop(self: *BoundedQueue, running: *std.atomic.Value(bool)) ?WorkItem {
            while (true) {
                self.ready.waitUncancelable(std.Options.debug_io);

                self.mutex.lock();
                const cnt = self.count.load(.acquire);
                if (cnt > 0) {
                    const item = self.items[self.head];
                    self.head = (self.head + 1) % QUEUE_SIZE;
                    _ = self.count.fetchSub(1, .release);
                    self.mutex.unlock();
                    return item;
                }
                self.mutex.unlock();

                if (!running.load(.acquire)) return null;
            }
        }

        pub fn wakeWorkers(self: *BoundedQueue, n: usize) void {
            for (0..n) |_| self.ready.post(std.Options.debug_io);
        }

        pub fn drainAndClose(self: *BoundedQueue) usize {
            self.mutex.lock();
            defer self.mutex.unlock();

            var drained: usize = 0;
            while (self.count.load(.acquire) > 0) {
                const item = self.items[self.head];
                self.head = (self.head + 1) % QUEUE_SIZE;
                _ = self.count.fetchSub(1, .release);
                std.Io.Threaded.closeFd(item.stream_fd);
                drained += 1;
            }
            self.tail = self.head;
            return drained;
        }
    };

    pub fn init(allocator: std.mem.Allocator, server: *Server, worker_count: usize) !*ConnectionPool {
        const self = try allocator.create(ConnectionPool);
        errdefer allocator.destroy(self);

        const workers = try allocator.alloc(std.Thread, worker_count);
        errdefer allocator.free(workers);

        self.* = .{
            .workers = workers,
            .queue = BoundedQueue.init(),
            .running = std.atomic.Value(bool).init(true),
            .server = server,
            .allocator = allocator,
        };

        // Spawn workers
        for (self.workers, 0..) |*worker, i| {
            worker.* = std.Thread.spawn(.{}, workerFn, .{self}) catch {
                // If spawn fails, clean up already spawned workers
                // errdefers will handle freeing workers array and destroying self
                self.running.store(false, .release);
                self.queue.wakeWorkers(i);
                for (self.workers[0..i]) |w| w.join();
                return error.ThreadSpawnFailed;
            };
        }

        return self;
    }

    pub fn deinit(self: *ConnectionPool) void {
        self.running.store(false, .release);
        // Wake blocked workers so they can observe running=false and exit.
        self.queue.wakeWorkers(self.workers.len);
        for (self.workers) |w| w.join();
        _ = self.queue.drainAndClose();
        self.allocator.free(self.workers);
        self.allocator.destroy(self);
    }

    pub fn submit(self: *ConnectionPool, stream_fd: std.posix.fd_t) bool {
        return self.queue.push(.{ .stream_fd = stream_fd });
    }

    fn workerFn(self: *ConnectionPool) void {
        while (self.running.load(.acquire)) {
            const item = self.queue.pop(&self.running) orelse continue;
            self.handleConnection(item.stream_fd);
        }
    }

    pub fn handleConnection(self: *ConnectionPool, fd: std.posix.fd_t) void {
        defer std.Io.Threaded.closeFd(fd);

        // TCP_NODELAY: disable Nagle's algorithm for lower latency
        // This reduces response latency by sending data immediately.
        // Raw syscall, result discarded: the option does not exist on
        // non-TCP fds (tests drive this loop over a socketpair), and the
        // std.posix wrapper dumps a stack trace to stderr for the unmapped
        // errno under test builds.
        _ = std.posix.system.setsockopt(fd, std.posix.IPPROTO.TCP, std.posix.TCP.NODELAY, &std.mem.toBytes(@as(c_int, 1)), @sizeOf(c_int));

        // SO_RCVTIMEO makes a blocking read return error.WouldBlock once a single
        // idle gap exceeds the timeout. Note it resets on every byte received, so
        // it bounds only per-read idle, NOT total request time; a drip-feeding
        // slowloris is bounded instead by the absolute read deadline in
        // readRequestData. SO_SNDTIMEO bounds a slow-reading peer on the write side.
        const recv_timeout = std.posix.timeval{
            .sec = @intCast(self.server.config.timeout_ms / 1000),
            .usec = @intCast((self.server.config.timeout_ms % 1000) * 1000),
        };
        std.posix.setsockopt(fd, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, std.mem.asBytes(&recv_timeout)) catch {};
        std.posix.setsockopt(fd, std.posix.SOL.SOCKET, std.posix.SO.SNDTIMEO, std.mem.asBytes(&recv_timeout)) catch {};

        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();

        var requests_on_connection: u32 = 0;
        var pending_request_bytes: PendingRequestBytes = .{};
        defer pending_request_bytes.deinit(self.allocator);

        while (true) {
            if (requests_on_connection > 0 and pending_request_bytes.bytes.len == 0 and !self.waitForNextRequest(fd)) break;
            _ = arena.reset(.retain_capacity);
            const req_allocator = arena.allocator();
            const outcome = self.handleSingleRequestSync(fd, requests_on_connection, req_allocator, &pending_request_bytes) catch break;
            requests_on_connection += 1;

            if (outcome == .close) break;
            if (self.server.config.keep_alive_max_requests > 0 and
                requests_on_connection >= self.server.config.keep_alive_max_requests) break;
        }
    }

    /// Bound the idle gap between keep-alive requests by keep_alive_timeout_ms
    /// instead of timeout_ms: the pool has only cpu_count*2 workers, so a few
    /// idle connections each holding a worker for the full request timeout
    /// would starve the server. Polls for readability without consuming bytes,
    /// so SO_RCVTIMEO (timeout_ms) still bounds the request once its first
    /// byte arrives, and data already buffered by a pipelining client returns
    /// immediately. Returns false when the idle timeout expires or polling
    /// fails: normal keep-alive expiry, the caller closes without logging.
    pub fn waitForNextRequest(self: *ConnectionPool, fd: std.posix.fd_t) bool {
        var fds = [_]std.posix.pollfd{.{ .fd = fd, .events = std.posix.POLL.IN, .revents = 0 }};
        const timeout: i32 = @intCast(@min(self.server.config.keep_alive_timeout_ms, std.math.maxInt(i32)));
        const ready = std.posix.poll(&fds, timeout) catch return false;
        // POLLHUP/POLLERR also count as ready: the subsequent read surfaces
        // EOF or the reset, which maps to a clean close.
        return ready > 0;
    }

    /// Outcome of a single request on a keep-alive connection. `keep_alive`
    /// continues the loop; `close` breaks and the defer closes the fd.
    pub const RequestOutcome = enum { keep_alive, close };

    pub const PendingRequestBytes = struct {
        bytes: []u8 = &.{},

        pub fn deinit(self: *PendingRequestBytes, allocator: std.mem.Allocator) void {
            if (self.bytes.len > 0) allocator.free(self.bytes);
            self.bytes = &.{};
        }

        pub fn take(self: *PendingRequestBytes) []u8 {
            const bytes = self.bytes;
            self.bytes = &.{};
            return bytes;
        }

        pub fn replace(self: *PendingRequestBytes, allocator: std.mem.Allocator, bytes: []const u8) !void {
            self.deinit(allocator);
            if (bytes.len == 0) return;
            self.bytes = try allocator.dupe(u8, bytes);
        }
    };

    pub fn handleSingleRequestSync(
        self: *ConnectionPool,
        fd: std.posix.fd_t,
        request_num: u32,
        req_allocator: std.mem.Allocator,
        pending: *PendingRequestBytes,
    ) !RequestOutcome {
        _ = request_num;

        // Hold a shared lock across the request so the live-reload watcher's
        // exclusive contract/proof_cache swap (replaceSourceGeneration) waits for
        // in-flight readers instead of freeing structures this request still
        // points into. Gated on reload being active: the production path takes
        // no lock. Concurrent requests still run in parallel (shared lock).
        const guard_contract = self.server.reload_active;
        if (guard_contract) self.server.contract_lock.lockShared();
        defer if (guard_contract) self.server.contract_lock.unlockShared();

        var is_head = false;
        const request_data = self.readRequestData(fd, req_allocator, pending, &is_head) catch |err| {
            if (err == error.EndOfStream or err == error.ConnectionResetByPeer or err == error.WouldBlock) return .close;
            if (err == error.UnsupportedTransferEncoding) {
                self.sendErrorSync(fd, 501, "Not Implemented", is_head) catch {};
                return .close;
            }
            if (err == error.FileTooBig) {
                self.sendErrorSync(fd, 413, "Payload Too Large", is_head) catch {};
                return .close;
            }
            if (err == error.RequestTimeout) {
                self.sendErrorSync(fd, 408, "Request Timeout", is_head) catch {};
                return .close;
            }
            return err;
        };
        var request = self.server.parseRequestFromBuffer(req_allocator, request_data) catch |err| {
            // Send an HTTP response for a malformed request instead of silently
            // resetting the connection, so clients, scanners, and test harnesses
            // see a diagnostic rather than ECONNRESET.
            const status = parseErrorStatus(err);
            self.sendErrorSync(fd, status, response_mod.getStatusText(status), is_head) catch {};
            return .close;
        };
        defer request.deinit(req_allocator);

        var access_status: u16 = 500;
        const access_started_ms = unixMillisNow();
        defer self.logAccess(request.method, request.path, request.headers.items, access_status, access_started_ms);

        // Check keep-alive using fast header slot
        const client_wants_keep_alive = blk: {
            if (request.connection) |conn| {
                break :blk std.ascii.eqlIgnoreCase(conn, "keep-alive");
            }
            // HTTP/1.0 defaults to close; HTTP/1.1 defaults to keep-alive.
            break :blk !request.is_http_10;
        };
        const keep_alive = self.server.config.keep_alive and client_wants_keep_alive;
        const outcome_if_alive: RequestOutcome = if (keep_alive) .keep_alive else .close;

        // Health and readiness probes - before WebSocket, static, and JS handler
        if (std.mem.eql(u8, request.path, "/_health")) {
            access_status = 200;
            self.sendStatusSync(fd, 200, "OK", keep_alive, is_head) catch {};
            return outcome_if_alive;
        }
        if (std.mem.eql(u8, request.path, "/_readiness")) {
            const pool_full = if (self.server.pool) |*pool|
                pool.getInUse() >= pool.max_size
            else
                false;
            if (pool_full) {
                access_status = 503;
                self.sendErrorSync(fd, 503, "Service Unavailable", is_head) catch {};
                return .close;
            }
            access_status = 200;
            self.sendStatusSync(fd, 200, "OK", keep_alive, is_head) catch {};
            return outcome_if_alive;
        }

        // Handle static files
        if (self.server.config.static_dir) |static_dir| {
            if (std.mem.startsWith(u8, request.path, "/static/")) {
                // Strip the full "/static/" prefix (8 chars) off request.path,
                // not request.url[7..]: the old slice kept a leading slash (so the
                // file resolved as absolute -> 403) and carried the query string.
                access_status = self.serveStaticFileSync(fd, static_dir, request.path["/static/".len..], keep_alive, request.headers.items, is_head) catch |err| {
                    if (err == error.StaticFileTruncated) {
                        // Headers + a partial body already went out; the file
                        // shrank under us, so the only safe action is to close
                        // rather than leave a keep-alive client awaiting bytes
                        // that no longer exist. No 500 - the status line is sent.
                        access_status = 200;
                        return .close;
                    }
                    std.log.warn("static file error for {s}: {}", .{ request.url, err });
                    access_status = 500;
                    self.sendErrorSync(fd, 500, "Internal Server Error", is_head) catch {};
                    return outcome_if_alive;
                };
                return outcome_if_alive;
            }
        }

        // Well-known proof-receipt endpoint (slice 2 item B). Intercept before
        // the contract route filter so this fixed path is reachable even on
        // handlers whose contract proves a restricted route set.
        if (self.server.well_known_doc) |*doc| {
            if (std.mem.eql(u8, request.path, attest_well_known.route_path)) {
                const inm = findHeaderValue(request.headers.items, "If-None-Match");
                const cached = etagMatchesIfNoneMatch(inm, &doc.etag_hex);
                var header_buf: [512]u8 = undefined;
                const header_len = formatWellKnownHeaders(doc, cached, keep_alive, &header_buf) catch return .close;
                access_status = if (cached) 304 else 200;
                writeAllFd(fd, header_buf[0..header_len]) catch return .close;
                // HEAD: headers only (Content-Length already in the header block).
                if (!cached and !is_head) writeAllFd(fd, doc.body) catch return .close;
                return outcome_if_alive;
            }
        }

        // Route pre-filtering (threaded path)
        if (self.server.contract) |*contract| {
            if (!contract.matchesRoute(request.method, request.path)) {
                access_status = 404;
                self.sendStatusSync(fd, 404, "Not Found", keep_alive, is_head) catch {};
                return outcome_if_alive;
            }
        }

        // Proof-driven response memoization: serve cached response without entering JS
        var proof_cache_key: ?u64 = null;
        if (self.server.proof_cache) |*cache| {
            if (cache.enabled and proof_adapter.ProofCache.shouldCache(request.method, request.headers)) {
                const key = proof_adapter.ProofCache.computeKey(request.method, request.url);
                var cached_opt = cache.get(key, req_allocator);
                if (cached_opt != null) {
                    defer cached_opt.?.deinit();
                    access_status = cached_opt.?.status;
                    self.sendResponseSync(fd, &cached_opt.?, keep_alive, is_head) catch return .close;
                    return outcome_if_alive;
                }
                proof_cache_key = key;
            }
        }

        // Invoke handler
        if (self.server.pool) |*pool| {
            // The runtime resolves the faulting source line, but is released
            // before the 500 body below is built, so the pool copies the value
            // out here while it still holds the runtime.
            var fault_location: ?engine.FaultLocation = null;
            var handle = engine.executeHandlerBorrowedCapturingFault(pool, HttpRequestView{
                .url = request.url,
                .method = request.method,
                .path = request.path,
                .query_params = request.query_params,
                .headers = request.headers,
                .body = request.body,
            }, &fault_location) catch |err| {
                const status: u16 = if (err == error.PoolExhausted) 503 else if (err == error.RequestTimeout) 504 else if (err == error.HandlerNotImplemented) 501 else 500;
                var fault_buf: [256]u8 = undefined;
                var fault_loc_buf: [320]u8 = undefined;
                const message: []const u8 = blk: {
                    if (err == error.PoolExhausted) break :blk "Service Unavailable";
                    if (err == error.RequestTimeout) break :blk "Gateway Timeout";
                    if (err == error.HandlerNotImplemented) break :blk "Not Implemented: this path reached a hole() the handler has not filled yet";
                    if (err == error.HandlerTypeFault) {
                        // Proof-explained failure: attribute the fault against the
                        // handler's proven contract, in hand here under contract_lock.
                        const proof: fault_explain.Proof = if (self.server.contract) |*c| p: {
                            const props = c.properties();
                            break :p .{ .optional_safe = props.optional_safe, .result_safe = props.result_safe };
                        } else .{};
                        // The runtime already detected and recorded any soundness
                        // incident (it holds handler_proof and the incident log);
                        // here we render the explained 500 body and append the
                        // faulting source line the runtime resolved (feature A).
                        const diag = fault_explain.diagnose(proof, .type_fault);
                        const base = fault_explain.formatMessage(&fault_buf, diag);
                        if (fault_location) |loc| {
                            break :blk std.fmt.bufPrint(
                                &fault_loc_buf,
                                "{s} at {d}:{d}",
                                .{ base, loc.line, loc.column },
                            ) catch base;
                        }
                        break :blk base;
                    }
                    break :blk "Internal Server Error";
                };
                access_status = status;
                self.sendErrorSync(fd, status, message, is_head) catch |send_err| {
                    std.log.warn("failed to send error response: {}", .{send_err});
                };
                return .close;
            };
            defer handle.deinit();

            // Store response in proof cache on miss
            if (proof_cache_key) |key| {
                if (self.server.proof_cache) |*cache| {
                    cache.put(key, &handle.response);
                }
            }

            // Send response
            access_status = handle.response.status;
            self.sendResponseSync(fd, &handle.response, keep_alive, is_head) catch return .close;
        }

        return outcome_if_alive;
    }

    fn logAccess(
        self: *ConnectionPool,
        method: []const u8,
        path: []const u8,
        headers: []const HttpHeader,
        status: u16,
        started_ms: i64,
    ) void {
        if (!self.server.config.log_requests) return;

        const now_ms = unixMillisNow();
        const duration_ms: i64 = if (now_ms >= started_ms) now_ms - started_ms else 0;
        const request_id = accessLogRequestId(findHeaderValue(headers, "X-Request-Id"));
        var method_buf: [max_logged_access_field_bytes]u8 = undefined;
        var path_buf: [max_logged_access_field_bytes]u8 = undefined;
        const logged_method = accessLogField(method, &method_buf);
        const logged_path = accessLogField(path, &path_buf);
        std.log.info("access method={s} path={s} status={d} duration_ms={d} request_id={s}", .{
            logged_method,
            logged_path,
            status,
            duration_ms,
            request_id,
        });
    }

    pub fn readRequestData(
        self: *ConnectionPool,
        fd: std.posix.fd_t,
        allocator: std.mem.Allocator,
        pending: *PendingRequestBytes,
        is_head: ?*bool,
    ) ![]u8 {
        var data: std.ArrayList(u8) = .empty;
        defer data.deinit(allocator);
        // Chunked-body parse resume state for this request only: a fresh
        // request always starts a new parse at offset 0, so this must not
        // be shared across requests (see ChunkedBodyParseState doc comment).
        var chunked_state: http_parser.ChunkedBodyParseState = .{};

        const pending_bytes = pending.take();
        defer if (pending_bytes.len > 0) self.allocator.free(pending_bytes);
        if (pending_bytes.len > 0) {
            try data.appendSlice(allocator, pending_bytes);
            if (is_head) |head| head.* = std.mem.startsWith(u8, data.items, "HEAD ");
            if (try self.completeRequestLength(data.items, &chunked_state)) |request_len| {
                return try self.splitRequestAndPending(allocator, pending, data.items, request_len);
            }
        }

        var read_buf: [16 * 1024]u8 = undefined;
        // Absolute read deadline. SO_RCVTIMEO bounds only per-read idle and resets
        // on any byte received, so a drip-feeding client (one byte just before each
        // timeout) could otherwise pin a worker indefinitely (slowloris). Cap the
        // total time spent assembling one request.
        var read_timer = engine.Timer.start() catch null;
        const read_budget_ns: u64 = @as(u64, self.server.config.timeout_ms) * std.time.ns_per_ms;
        while (true) {
            if (read_budget_ns > 0) {
                if (read_timer) |*t| {
                    if (t.read() > read_budget_ns) return error.RequestTimeout;
                }
            }
            const n = std.posix.read(fd, &read_buf) catch |err| {
                if (err == error.ConnectionResetByPeer or err == error.WouldBlock) return err;
                return err;
            };
            if (n == 0) return error.EndOfStream;
            try data.appendSlice(allocator, read_buf[0..n]);
            if (is_head) |head| head.* = std.mem.startsWith(u8, data.items, "HEAD ");

            if (try self.completeRequestLength(data.items, &chunked_state)) |request_len| {
                return try self.splitRequestAndPending(allocator, pending, data.items, request_len);
            }
        }
    }

    fn splitRequestAndPending(
        self: *ConnectionPool,
        allocator: std.mem.Allocator,
        pending: *PendingRequestBytes,
        data: []const u8,
        request_len: usize,
    ) ![]u8 {
        if (request_len > data.len) return error.IncompleteBody;
        try pending.replace(self.allocator, data[request_len..]);
        return try allocator.dupe(u8, data[0..request_len]);
    }

    pub fn completeRequestLength(self: *ConnectionPool, data: []const u8, chunked_state: *http_parser.ChunkedBodyParseState) !?usize {
        const max_header_bytes: usize = 32 * 1024;
        const header_end = findHeaderEnd(data) orelse {
            if (data.len > max_header_bytes) return error.InvalidRequest;
            return null;
        };

        const body_start = header_end + 4;
        const header_section = data[0..header_end];
        const content_length_opt = try parseContentLength(header_section);
        const transfer_encoding = try http_parser.parseTransferEncoding(header_section);
        if (transfer_encoding == .chunked and content_length_opt != null) return error.InvalidRequest;

        if (transfer_encoding == .chunked) {
            const encoded_cap = http_parser.maxChunkedEncodedBodyBytes(self.server.config.max_body_size);
            const encoded_len = (try http_parser.chunkedBodyConsumedResumable(
                data[body_start..],
                self.server.config.max_body_size,
                chunked_state,
            )) orelse {
                const encoded_so_far = if (body_start <= data.len) data.len - body_start else 0;
                if (encoded_so_far > encoded_cap) {
                    return error.FileTooBig;
                }
                return null;
            };
            // The cap must also gate the completed body: a read that both crosses
            // the cap and finishes the body would otherwise return through here
            // without ever entering the incomplete branch above.
            if (encoded_len > encoded_cap) return error.FileTooBig;
            return body_start + encoded_len;
        }

        const content_length = content_length_opt orelse 0;
        if (content_length > self.server.config.max_body_size) return error.FileTooBig;
        const total_needed = body_start + content_length;
        if (data.len < total_needed) return null;
        return total_needed;
    }

    fn sendResponseSync(self: *ConnectionPool, fd: std.posix.fd_t, response: *HttpResponse, keep_alive: bool, is_head: bool) !void {
        // FAST PATH: If prebuilt_raw is available, write it directly (zero header construction).
        // Slice 1 of proof receipts intentionally skips this path: cached
        // static-file responses don't carry handler semantics, so omitting
        // attestation headers there is the correct shape.
        //
        // A HEAD response must NOT take this path: prebuilt_raw embeds the body,
        // and RFC 7231 forbids a body on a HEAD response (a client reading it
        // would mis-frame the next response on a keep-alive connection).
        if (!is_head) {
            if (response_mod.statusAllowsBody(response.status)) {
                if (response.prebuilt_raw) |prebuilt| {
                    // Only take the zero-construction fast path when attestation is off.
                    // The prebuilt blob omits the Zttp-Proofs/Zttp-Attest header lines,
                    // so when attestation is active we must fall through to the normal
                    // builder; otherwise a constant-Response handler would ship attestation
                    // headers on close connections but drop them on keep-alive, making
                    // their presence unpredictable for a third-party `zttp verify`.
                    if (keep_alive and self.server.attestation_headers == null) {
                        // Prebuilt response already has keep-alive, write directly
                        try writeAllFd(fd, prebuilt);
                        return;
                    }
                    // For close (or when attestation is active) fall through to normal path.
                }
            }
        }

        // Increased buffer to 8KB to fit headers + most response bodies in single write
        var header_buf: [8192]u8 = undefined;
        var pos = try buildDynamicResponseHeader(
            &header_buf,
            response,
            keep_alive,
            self.server.attestation_headers,
        );

        if (is_head) {
            // RFC 7231: a HEAD response carries the same headers GET would
            // produce - including the Content-Length built above from
            // response.body.len - but never the message body.
            try writeAllFd(fd, header_buf[0..pos]);
            return;
        }

        if (!response_mod.statusAllowsBody(response.status)) {
            try writeAllFd(fd, header_buf[0..pos]);
            return;
        }

        // OPTIMIZATION: Combine headers + body in single syscall
        if (response.body.len > 0 and pos + response.body.len <= header_buf.len) {
            // Body fits in remaining buffer space - single memcpy + write
            @memcpy(header_buf[pos..][0..response.body.len], response.body);
            pos += response.body.len;
            try writeAllFd(fd, header_buf[0..pos]);
        } else if (response.body.len > 0) {
            // Body too large - use writev scatter-gather (single syscall, no copy)
            var iovecs: [2]std.posix.iovec_const = .{
                .{ .base = &header_buf, .len = pos },
                .{ .base = response.body.ptr, .len = response.body.len },
            };
            try writevAllFd(fd, &iovecs);
        } else {
            // Empty body - just headers
            try writeAllFd(fd, header_buf[0..pos]);
        }
    }

    test "sendResponseSync suppresses forbidden bodies and preserves 200 and HEAD framing" {
        const readResponse = struct {
            fn read(writer_fd: std.posix.fd_t, reader_fd: std.posix.fd_t, buf: []u8) !usize {
                _ = std.c.shutdown(writer_fd, std.c.SHUT.WR);
                var len: usize = 0;
                while (len < buf.len) {
                    const n = try std.posix.read(reader_fd, buf[len..]);
                    if (n == 0) break;
                    len += n;
                }
                return len;
            }
        }.read;

        var server: Server = undefined;
        server.attestation_headers = null;
        var pool = ConnectionPool{
            .workers = &[_]std.Thread{},
            .queue = ConnectionPool.BoundedQueue.init(),
            .running = std.atomic.Value(bool).init(true),
            .server = &server,
            .allocator = std.testing.allocator,
        };

        const forbidden_statuses = [_]u16{ 103, 204, 304 };
        for (forbidden_statuses) |status| {
            var response = HttpResponse.init(std.testing.allocator);
            defer response.deinit();
            response.status = status;
            response.body = "unexpected body";
            response.prebuilt_raw = "HTTP/1.1 200 OK\r\nContent-Length: 15\r\nConnection: keep-alive\r\n\r\nunexpected body";

            const fds = try createUnixSocketPair();
            defer std.Io.Threaded.closeFd(fds[0]);
            defer std.Io.Threaded.closeFd(fds[1]);
            try pool.sendResponseSync(fds[0], &response, true, false);

            var buf: [512]u8 = undefined;
            const n = try readResponse(fds[0], fds[1], &buf);
            try std.testing.expect(std.mem.indexOf(u8, buf[0..n], "Content-Length:") == null);
            try std.testing.expect(std.mem.endsWith(u8, buf[0..n], "\r\n\r\n"));
        }

        var response = HttpResponse.init(std.testing.allocator);
        defer response.deinit();
        response.body = "hello";

        const get_fds = try createUnixSocketPair();
        defer std.Io.Threaded.closeFd(get_fds[0]);
        defer std.Io.Threaded.closeFd(get_fds[1]);
        try pool.sendResponseSync(get_fds[0], &response, true, false);
        var get_buf: [512]u8 = undefined;
        const get_n = try readResponse(get_fds[0], get_fds[1], &get_buf);
        try std.testing.expect(std.mem.endsWith(u8, get_buf[0..get_n], "Content-Length: 5\r\nConnection: keep-alive\r\n\r\nhello"));

        const head_fds = try createUnixSocketPair();
        defer std.Io.Threaded.closeFd(head_fds[0]);
        defer std.Io.Threaded.closeFd(head_fds[1]);
        try pool.sendResponseSync(head_fds[0], &response, true, true);
        var head_buf: [512]u8 = undefined;
        const head_n = try readResponse(head_fds[0], head_fds[1], &head_buf);
        try std.testing.expect(std.mem.endsWith(u8, head_buf[0..head_n], "Content-Length: 5\r\nConnection: keep-alive\r\n\r\n"));

        for ([_]bool{ false, true }) |is_head| {
            const status_fds = try createUnixSocketPair();
            defer std.Io.Threaded.closeFd(status_fds[0]);
            defer std.Io.Threaded.closeFd(status_fds[1]);
            try pool.sendStatusSync(status_fds[0], 404, "Not Found", true, is_head);
            try pool.sendErrorSync(status_fds[0], 503, "Service Unavailable", is_head);
            var status_buf: [512]u8 = undefined;
            const status_n = try readResponse(status_fds[0], status_fds[1], &status_buf);
            const expected = if (is_head)
                "HTTP/1.1 404 Not Found\r\nContent-Length: 9\r\nConnection: keep-alive\r\n\r\n" ++
                    "HTTP/1.1 503 Service Unavailable\r\nContent-Length: 19\r\nConnection: close\r\n\r\n"
            else
                "HTTP/1.1 404 Not Found\r\nContent-Length: 9\r\nConnection: keep-alive\r\n\r\nNot Found" ++
                    "HTTP/1.1 503 Service Unavailable\r\nContent-Length: 19\r\nConnection: close\r\n\r\nService Unavailable";
            try std.testing.expectEqualStrings(expected, status_buf[0..status_n]);
        }
    }

    /// Map a request-parse error to an HTTP status. Takes `anyerror` so it can
    /// name errors from across the parser without coupling to one error set.
    fn parseErrorStatus(err: anyerror) u16 {
        return switch (err) {
            error.OutOfMemory => 500,
            error.UriTooLong, error.QueryTooLong => 414,
            error.TooManyHeaders, error.HeaderStorageExhausted, error.HeaderKeyTooLong => 431,
            error.FileTooBig => 413,
            // A well-formed method token this runtime does not implement, and
            // a transfer coding it does not support, are both "understood the
            // message, will not act on it".
            error.UnsupportedTransferEncoding, error.UnknownMethod => 501,
            // InvalidRequest, InvalidHeaderName, DuplicateContentLength,
            // InvalidContentLength, IncompleteBody, and anything else: a
            // malformed request.
            else => 400,
        };
    }

    fn sendErrorSync(self: *ConnectionPool, fd: std.posix.fd_t, status: u16, message: []const u8, is_head: bool) !void {
        return self.sendStatusSync(fd, status, message, false, is_head);
    }

    /// Like sendErrorSync but frames with the connection's actual keep_alive
    /// flag. The health/readiness/404 fast paths return `outcome_if_alive`
    /// (keeping the fd open), so they must not advertise `Connection: close`
    /// (which a spec-compliant client treats as not reusable, defeating
    /// keep-alive on exactly the highest-frequency probe paths).
    fn sendStatusSync(self: *ConnectionPool, fd: std.posix.fd_t, status: u16, message: []const u8, keep_alive: bool, is_head: bool) !void {
        _ = self;
        var buf: [512]u8 = undefined;
        const response = try formatHttpError(&buf, status, message, keep_alive, null);
        const wire = if (is_head) response[0 .. response.len - message.len] else response;
        try writeAllFd(fd, wire);
    }

    fn serveStaticFileSync(
        self: *ConnectionPool,
        fd: std.posix.fd_t,
        static_dir: []const u8,
        path: []const u8,
        keep_alive: bool,
        headers: []const HttpHeader,
        is_head: bool,
    ) !u16 {
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        var etag_buf: [34]u8 = undefined;
        var resolved = try resolveStaticFile(self.server.allocator, self.server.io_backend.io(), static_dir, path, &path_buf, &etag_buf);
        switch (resolved) {
            .forbidden => {
                try self.sendStatusSync(fd, 403, "Forbidden", keep_alive, is_head);
                return 403;
            },
            .not_found => {
                try self.sendStatusSync(fd, 404, "Not Found", keep_alive, is_head);
                return 404;
            },
            .ok => |*file_info| {
                defer file_info.file.close(self.server.io_backend.io());

                if (findHeaderValue(headers, "if-none-match")) |client_etag| {
                    const eff_etag = if (std.mem.startsWith(u8, client_etag, "W/")) client_etag[2..] else client_etag;
                    if (std.mem.eql(u8, eff_etag, file_info.etag)) {
                        var out_buf: [256]u8 = undefined;
                        const response = formatStaticNotModified(&out_buf, file_info.etag, keep_alive) catch return error.BufferOverflow;
                        try writeAllFd(fd, response);
                        return 304;
                    }
                }

                var header_buf: [1024]u8 = undefined;
                const header = formatStaticOkHeader(
                    &header_buf,
                    file_info.size,
                    file_info.content_type,
                    file_info.etag,
                    keep_alive,
                ) catch return error.BufferOverflow;
                try writeAllFd(fd, header);

                // HEAD: the header block already carries Content-Length =
                // file_info.size (what GET would return); emit no body (RFC 7231).
                if (is_head) return 200;

                if (file_info.size == 0) return 200;

                var file_reader = file_info.file.reader(self.server.io_backend.io(), &.{});
                var file_buf: [16 * 1024]u8 = undefined;
                // Write exactly file_info.size bytes - the value already emitted
                // as Content-Length. Reading to EOF instead diverges from
                // Content-Length if the file changed after the stat that
                // captured the size (server_static.zig opens then stats): a file
                // that grew would over-deliver (surplus bytes mis-framed as the
                // next response on a keep-alive connection); one that shrank
                // would under-deliver (client hangs awaiting the missing bytes).
                var remaining: usize = @intCast(file_info.size);
                while (remaining > 0) {
                    const want = @min(file_buf.len, remaining);
                    const n = file_reader.interface.readSliceShort(file_buf[0..want]) catch |err| switch (err) {
                        error.ReadFailed => return file_reader.err.?,
                    };
                    if (n == 0) break; // file shrank below the stat size after we sent Content-Length
                    try writeAllFd(fd, file_buf[0..n]);
                    remaining -= n;
                }
                if (remaining > 0) {
                    // Under-delivered the declared Content-Length; the framing is
                    // unrecoverable on a keep-alive connection. Signal a close.
                    return error.StaticFileTruncated;
                }
                return 200;
            },
        }
    }
};

test "accessLogRequestId keeps safe token values" {
    try std.testing.expectEqualStrings("req-123_abc.DEF:456", accessLogRequestId("req-123_abc.DEF:456"));
}

test "accessLogRequestId hides missing empty control whitespace and oversized values" {
    try std.testing.expectEqualStrings("-", accessLogRequestId(null));
    try std.testing.expectEqualStrings("-", accessLogRequestId(""));
    try std.testing.expectEqualStrings("-", accessLogRequestId("abc\x00def"));
    try std.testing.expectEqualStrings("-", accessLogRequestId("abc\ndef"));
    try std.testing.expectEqualStrings("-", accessLogRequestId("abc def"));

    const oversized = @as([((max_logged_request_id_len + 1))]u8, @splat('a'));
    try std.testing.expectEqualStrings("-", accessLogRequestId(&oversized));
}

test "accessLogField percent-escapes unsafe bytes" {
    var buf: [max_logged_access_field_bytes]u8 = undefined;
    try std.testing.expectEqualStrings("GET", accessLogField("GET", &buf));
    try std.testing.expectEqualStrings(
        "/a%00b%0Ac%20d%7F%80",
        accessLogField("/a\x00b\nc d\x7F\x80", &buf),
    );
}

test "accessLogField caps oversized values" {
    const oversized = @as([((max_logged_access_field_len + 1))]u8, @splat('a'));
    var buf: [max_logged_access_field_bytes]u8 = undefined;
    const logged = accessLogField(&oversized, &buf);
    try std.testing.expectEqual(@as(usize, max_logged_access_field_len), logged.len);
    try std.testing.expectEqualStrings(&@as([max_logged_access_field_len:0]u8, @splat('a')), logged);
}
