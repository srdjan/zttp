//! Proof-driven runtime adapter: compile-time proofs drive runtime behavior.
//!
//! When the handler contract proves properties like `deterministic` and `read_only`,
//! the runtime can safely optimize request handling without configuration. This module
//! implements the first such optimization: response memoization for proven-deterministic
//! handlers. A GET request that produced a given response will produce the same response
//! on every subsequent call - the compiler proved it - so we cache and serve directly
//! from Zig without entering the JS runtime.
//!
//! Activation: automatic when contract proves `pure` OR (`deterministic` AND `read_only`).
//! No configuration required. The proof IS the configuration.
//!
//! Cache key: method+URL only. The proven properties do not establish that the
//! response is independent of request headers, so requests carrying credential
//! headers (authorization/cookie) and responses declaring a non-empty `Vary`
//! are not cached - the key cannot capture the headers those responses vary on.

const std = @import("std");
const compat = @import("zts").compat;
const http_types = @import("http_types.zig");
const contract_runtime = @import("contract_runtime.zig");

const HttpResponse = http_types.HttpResponse;
const HttpHeader = http_types.HttpHeader;
const Wyhash = std.hash.Wyhash;

// ============================================================================
// Types
// ============================================================================

const OwnedHeader = struct {
    key: []u8,
    value: []u8,
};

pub const CacheKey = struct {
    method: []const u8,
    url: []const u8,
};

const CacheEntry = struct {
    status: u16,
    headers: []OwnedHeader,
    body: []u8,
    created_ns: u64,
    byte_size: usize,
};

fn containsAsciiIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (haystack.len < needle.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

fn defaultComputeKey(method: []const u8, url: []const u8) u64 {
    var hasher = Wyhash.init(0);
    hasher.update(method);
    hasher.update("\x00");
    hasher.update(url);
    return hasher.final();
}

// ============================================================================
// ProofCache
// ============================================================================

pub const ProofCache = ProofCacheWithHash(defaultComputeKey);

fn ProofCacheWithHash(comptime hash_fn: fn ([]const u8, []const u8) u64) type {
    const KeyContext = struct {
        pub fn hash(_: @This(), k: CacheKey) u64 {
            return hash_fn(k.method, k.url);
        }

        pub fn eql(_: @This(), a: CacheKey, b: CacheKey) bool {
            return std.mem.eql(u8, a.method, b.method) and std.mem.eql(u8, a.url, b.url);
        }
    };

    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        entries: std.HashMapUnmanaged(CacheKey, CacheEntry, KeyContext, std.hash_map.default_max_load_percentage),
        insertion_order: std.ArrayListUnmanaged(CacheKey),
        // Index of the oldest live key in `insertion_order`. Eviction advances this
        // cursor instead of shifting the whole array (O(1) instead of O(n)); the
        // dead prefix [0..order_head] is reclaimed by compaction in `put` so the
        // backing array stays bounded by the live entry count.
        order_head: usize,
        rw_lock: compat.RwLock,
        max_entries: u32,
        ttl_ns: u64,
        max_body_size: usize,
        hits: std.atomic.Value(u64),
        misses: std.atomic.Value(u64),
        enabled: bool,
        total_bytes: std.atomic.Value(usize),

        pub const Config = struct {
            max_entries: u32 = 1024,
            ttl_seconds: u32 = 300,
            max_body_size: usize = 256 * 1024,
        };

        pub const Stats = struct {
            hits: u64,
            misses: u64,
            entries: u32,
            total_bytes: usize,
        };

        /// Create a ProofCache. Enabled only when properties prove the handler is
        /// deterministic and side-effect-free (pure, or deterministic + read_only).
        pub fn init(
            allocator: std.mem.Allocator,
            properties: contract_runtime.Properties,
            config: Config,
        ) Self {
            const cacheable = properties.pure or (properties.deterministic and properties.read_only);
            return .{
                .allocator = allocator,
                .entries = .{},
                .insertion_order = .empty,
                .order_head = 0,
                .rw_lock = .{},
                .max_entries = config.max_entries,
                .ttl_ns = @as(u64, config.ttl_seconds) * std.time.ns_per_s,
                .max_body_size = config.max_body_size,
                .hits = std.atomic.Value(u64).init(0),
                .misses = std.atomic.Value(u64).init(0),
                .enabled = cacheable,
                .total_bytes = std.atomic.Value(usize).init(0),
            };
        }

        pub fn deinit(self: *Self) void {
            var it = self.entries.iterator();
            while (it.next()) |kv| {
                self.freeKey(kv.key_ptr.*);
                self.freeEntry(kv.value_ptr);
            }
            self.entries.deinit(self.allocator);
            self.insertion_order.deinit(self.allocator);
        }

        /// Check if a request method and headers qualify for caching.
        /// Only GET and HEAD are cached. Cache-Control: no-cache/no-store/private
        /// bypasses the cache (case-insensitive ASCII).
        pub fn shouldCache(method: []const u8, headers: std.ArrayListUnmanaged(HttpHeader)) bool {
            // Only cache GET and HEAD
            if (!std.ascii.eqlIgnoreCase(method, "GET") and
                !std.ascii.eqlIgnoreCase(method, "HEAD"))
            {
                return false;
            }

            for (headers.items) |header| {
                // Respect Cache-Control: no-cache / no-store / private (case-insensitive)
                if (std.ascii.eqlIgnoreCase(header.key, "cache-control")) {
                    if (containsAsciiIgnoreCase(header.value, "no-cache") or
                        containsAsciiIgnoreCase(header.value, "no-store") or
                        containsAsciiIgnoreCase(header.value, "private"))
                    {
                        return false;
                    }
                }
                // Never cache a request carrying per-user credentials. The cache key
                // is method+URL only, and "pure"/"deterministic+read_only" do NOT
                // prove the response is independent of these headers, so caching an
                // authenticated/session response under the URL would replay one
                // user's body (or a 200-vs-401 decision) to every other caller.
                // (A future contract `input_independent` property could restore
                // caching for handlers proven not to read request state.)
                if (std.ascii.eqlIgnoreCase(header.key, "authorization") or
                    std.ascii.eqlIgnoreCase(header.key, "proxy-authorization") or
                    std.ascii.eqlIgnoreCase(header.key, "cookie"))
                {
                    return false;
                }
            }

            return true;
        }

        /// Compute the 64-bit hash for a request's method and URL.
        /// Map lookups verify exact (method, url) byte equality on top of this hash.
        pub fn computeKey(method: []const u8, url: []const u8) u64 {
            return hash_fn(method, url);
        }

        /// Look up a cached response by exact (method, url). Returns an owned
        /// HttpResponse on hit (caller must call deinit on it), or null on miss
        /// or TTL expiry.
        pub fn get(self: *Self, method: []const u8, url: []const u8, resp_allocator: std.mem.Allocator) ?HttpResponse {
            if (!self.enabled) return null;

            self.rw_lock.lockShared();
            defer self.rw_lock.unlockShared();

            const lookup_key = CacheKey{ .method = method, .url = url };
            const entry = self.entries.get(lookup_key) orelse {
                _ = self.misses.fetchAdd(1, .monotonic);
                return null;
            };

            // Check TTL
            const now_ns = compat.monotonicNowNs() catch 0;
            if (self.ttl_ns > 0 and now_ns > entry.created_ns and
                now_ns - entry.created_ns > self.ttl_ns)
            {
                _ = self.misses.fetchAdd(1, .monotonic);
                return null;
            }

            // Clone into an owned HttpResponse
            const response = cloneToResponse(&entry, resp_allocator) catch {
                _ = self.misses.fetchAdd(1, .monotonic);
                return null;
            };

            _ = self.hits.fetchAdd(1, .monotonic);
            return response;
        }

        /// Store a response in the cache under exact (method, url). Deep-copies all
        /// data from the response. Refuses non-2xx/3xx statuses, Set-Cookie,
        /// Cache-Control with no-store/private/no-cache, non-empty Vary, oversized
        /// bodies, zero capacity, or a disabled cache.
        pub fn put(self: *Self, method: []const u8, url: []const u8, response: *const HttpResponse) void {
            if (!self.enabled) return;
            if (self.max_entries == 0) return;
            if (response.status < 200 or response.status >= 400) return;
            if (response.body.len > self.max_body_size) return;

            for (response.headers.items) |h| {
                // A response that declares `Vary` is content-negotiated: its body
                // depends on request headers (e.g. Accept) that the cache key
                // (method+URL only) does not carry. An empty Vary does not vary.
                if (std.ascii.eqlIgnoreCase(h.key, "vary") and
                    std.mem.trim(u8, h.value, " \t").len != 0)
                {
                    return;
                }
                // Never cache session/cookie-setting responses in a shared cache.
                if (std.ascii.eqlIgnoreCase(h.key, "set-cookie")) {
                    return;
                }
                // Respect response Cache-Control directives that forbid shared caching.
                if (std.ascii.eqlIgnoreCase(h.key, "cache-control")) {
                    if (containsAsciiIgnoreCase(h.value, "no-store") or
                        containsAsciiIgnoreCase(h.value, "private") or
                        containsAsciiIgnoreCase(h.value, "no-cache"))
                    {
                        return;
                    }
                }
            }

            // Deep-copy outside the lock. Manual cleanup on failure since errdefer
            // does not fire in void functions (no error return path).
            const method_copy = self.allocator.dupe(u8, method) catch return;
            const url_copy = self.allocator.dupe(u8, url) catch {
                self.allocator.free(method_copy);
                return;
            };
            const owned_key = CacheKey{ .method = method_copy, .url = url_copy };

            const body_copy = self.allocator.dupe(u8, response.body) catch {
                self.freeKey(owned_key);
                return;
            };

            const headers_copy = self.allocator.alloc(OwnedHeader, response.headers.items.len) catch {
                self.allocator.free(body_copy);
                self.freeKey(owned_key);
                return;
            };
            var headers_initialized: usize = 0;

            for (response.headers.items, 0..) |h, i| {
                const key_dup = self.allocator.dupe(u8, h.key) catch {
                    self.freePartialCopy(headers_copy, headers_initialized, body_copy);
                    self.freeKey(owned_key);
                    return;
                };
                const val_dup = self.allocator.dupe(u8, h.value) catch {
                    self.allocator.free(key_dup);
                    self.freePartialCopy(headers_copy, headers_initialized, body_copy);
                    self.freeKey(owned_key);
                    return;
                };
                headers_copy[i] = .{ .key = key_dup, .value = val_dup };
                headers_initialized = i + 1;
            }

            var byte_size: usize = method_copy.len + url_copy.len + body_copy.len + headers_copy.len * @sizeOf(OwnedHeader);
            for (headers_copy) |h| {
                byte_size += h.key.len + h.value.len;
            }

            const now_ns = compat.monotonicNowNs() catch 0;

            const new_entry = CacheEntry{
                .status = response.status,
                .headers = headers_copy,
                .body = body_copy,
                .created_ns = now_ns,
                .byte_size = byte_size,
            };

            // Acquire exclusive lock for mutation
            self.rw_lock.lock();
            defer self.rw_lock.unlock();

            // Single lookup: getOrPut avoids double hash probe on miss
            const gop = self.entries.getOrPut(self.allocator, owned_key) catch {
                var copy = new_entry;
                self.freeEntry(&copy);
                self.freeKey(owned_key);
                return;
            };

            if (gop.found_existing) {
                // Keep the existing key backing slices intact so `insertion_order`
                // keeps pointing at live memory; free our duplicate key copy.
                self.freeKey(owned_key);
                _ = self.total_bytes.fetchSub(gop.value_ptr.byte_size, .monotonic);
                self.freeEntry(gop.value_ptr);
                gop.value_ptr.* = new_entry;
                _ = self.total_bytes.fetchAdd(byte_size, .monotonic);
                return;
            }

            gop.key_ptr.* = owned_key;
            gop.value_ptr.* = new_entry;

            // Track insertion order for eviction. On append failure, roll the
            // just-inserted map slot back instead of keeping an entry the
            // eviction queue can never reach - otherwise entries.count() drifts
            // above insertion_order.len and the cache grows past max_entries
            // unboundedly.
            self.insertion_order.append(self.allocator, owned_key) catch {
                _ = self.entries.remove(owned_key);
                var copy = new_entry;
                self.freeEntry(&copy);
                self.freeKey(owned_key);
                return;
            };
            _ = self.total_bytes.fetchAdd(byte_size, .monotonic);

            // Evict if over capacity. Pop the oldest key in O(1) by advancing the
            // head cursor after inserting the new entry so `gop` is no longer live.
            if (self.entries.count() > self.max_entries and
                self.insertion_order.items.len > self.order_head)
            {
                const oldest_key = self.insertion_order.items[self.order_head];
                self.order_head += 1;
                if (self.entries.fetchRemove(oldest_key)) |removed| {
                    _ = self.total_bytes.fetchSub(removed.value.byte_size, .monotonic);
                    var entry = removed.value;
                    self.freeEntry(&entry);
                    self.freeKey(removed.key);
                }
                // Reclaim the dead prefix once it dominates the array so the
                // backing store stays bounded by the live entry count.
                if (self.order_head > 16 and self.order_head * 2 > self.insertion_order.items.len) {
                    const live = self.insertion_order.items[self.order_head..];
                    std.mem.copyForwards(CacheKey, self.insertion_order.items[0..live.len], live);
                    self.insertion_order.shrinkRetainingCapacity(live.len);
                    self.order_head = 0;
                }
            }
        }

        fn freePartialCopy(self: *Self, headers: []OwnedHeader, count: usize, body: []u8) void {
            for (headers[0..count]) |h| {
                self.allocator.free(h.key);
                self.allocator.free(h.value);
            }
            self.allocator.free(headers);
            self.allocator.free(body);
        }

        pub fn getStats(self: *Self) Stats {
            self.rw_lock.lockShared();
            defer self.rw_lock.unlockShared();
            return .{
                .hits = self.hits.load(.monotonic),
                .misses = self.misses.load(.monotonic),
                .entries = @intCast(self.entries.count()),
                .total_bytes = self.total_bytes.load(.monotonic),
            };
        }

        // -- Private helpers --

        fn freeKey(self: *Self, key: CacheKey) void {
            self.allocator.free(key.method);
            self.allocator.free(key.url);
        }

        fn freeEntry(self: *Self, entry: *CacheEntry) void {
            for (entry.headers) |h| {
                self.allocator.free(h.key);
                self.allocator.free(h.value);
            }
            self.allocator.free(entry.headers);
            self.allocator.free(entry.body);
        }

        fn cloneToResponse(entry: *const CacheEntry, resp_allocator: std.mem.Allocator) !HttpResponse {
            var response = HttpResponse.init(resp_allocator);
            errdefer response.deinit();

            response.status = entry.status;

            // Deep-copy body
            if (entry.body.len > 0) {
                const body_copy = try resp_allocator.dupe(u8, entry.body);
                response.setBodyOwned(body_copy);
            }

            // Deep-copy headers (putHeader dupes internally)
            for (entry.headers) |h| {
                try response.putHeader(h.key, h.value);
            }

            // Mark as cache hit
            try response.putHeaderBorrowed("X-Zttp-Proof-Cache", "hit");

            return response;
        }
    };
}

// ============================================================================
// Tests
// ============================================================================

test "computeKey deterministic" {
    const k1 = ProofCache.computeKey("GET", "/api/health");
    const k2 = ProofCache.computeKey("GET", "/api/health");
    const k3 = ProofCache.computeKey("GET", "/api/users");
    const k4 = ProofCache.computeKey("POST", "/api/health");

    try std.testing.expectEqual(k1, k2);
    try std.testing.expect(k1 != k3);
    try std.testing.expect(k1 != k4);
}

test "computeKey includes query string" {
    const k1 = ProofCache.computeKey("GET", "/api/users?page=1");
    const k2 = ProofCache.computeKey("GET", "/api/users?page=2");
    const k3 = ProofCache.computeKey("GET", "/api/users?page=1");

    try std.testing.expect(k1 != k2);
    try std.testing.expectEqual(k1, k3);
}

test "shouldCache GET only" {
    const empty_headers: std.ArrayListUnmanaged(HttpHeader) = .empty;

    try std.testing.expect(ProofCache.shouldCache("GET", empty_headers));
    try std.testing.expect(ProofCache.shouldCache("HEAD", empty_headers));
    try std.testing.expect(ProofCache.shouldCache("get", empty_headers));
    try std.testing.expect(!ProofCache.shouldCache("POST", empty_headers));
    try std.testing.expect(!ProofCache.shouldCache("PUT", empty_headers));
    try std.testing.expect(!ProofCache.shouldCache("DELETE", empty_headers));
    try std.testing.expect(!ProofCache.shouldCache("PATCH", empty_headers));
}

test "shouldCache respects no-cache" {
    const allocator = std.testing.allocator;

    var headers: std.ArrayListUnmanaged(HttpHeader) = .empty;
    defer headers.deinit(allocator);
    try headers.append(allocator, .{ .key = "cache-control", .value = "no-cache" });

    try std.testing.expect(!ProofCache.shouldCache("GET", headers));
}

test "shouldCache respects no-store" {
    const allocator = std.testing.allocator;

    var headers: std.ArrayListUnmanaged(HttpHeader) = .empty;
    defer headers.deinit(allocator);
    try headers.append(allocator, .{ .key = "cache-control", .value = "no-store, max-age=0" });

    try std.testing.expect(!ProofCache.shouldCache("GET", headers));
}

test "disabled when properties not met" {
    const allocator = std.testing.allocator;
    var cache = ProofCache.init(allocator, .{}, .{});
    defer cache.deinit();

    try std.testing.expect(!cache.enabled);

    // get and put are no-ops when disabled
    try std.testing.expect(cache.get("GET", "/test", allocator) == null);

    var resp = HttpResponse.init(allocator);
    defer resp.deinit();
    resp.status = 200;
    cache.put("GET", "/test", &resp); // should not crash

    try std.testing.expect(cache.get("GET", "/test", allocator) == null);
}

test "enabled for pure handler" {
    const allocator = std.testing.allocator;
    var cache = ProofCache.init(allocator, .{ .pure = true }, .{});
    defer cache.deinit();

    try std.testing.expect(cache.enabled);
}

test "enabled for deterministic + read_only handler" {
    const allocator = std.testing.allocator;
    var cache = ProofCache.init(allocator, .{ .deterministic = true, .read_only = true }, .{});
    defer cache.deinit();

    try std.testing.expect(cache.enabled);
}

test "not enabled for deterministic-only handler" {
    const allocator = std.testing.allocator;
    var cache = ProofCache.init(allocator, .{ .deterministic = true }, .{});
    defer cache.deinit();

    try std.testing.expect(!cache.enabled);
}

test "put and get round-trip" {
    const allocator = std.testing.allocator;
    var cache = ProofCache.init(allocator, .{ .pure = true }, .{});
    defer cache.deinit();

    // Build a response to cache
    var resp = HttpResponse.init(allocator);
    defer resp.deinit();
    resp.status = 200;
    const body = try allocator.dupe(u8, "{\"ok\":true}");
    resp.setBodyOwned(body);
    try resp.putHeader("content-type", "application/json");

    cache.put("GET", "/api/health", &resp);

    // Retrieve it
    var cached = cache.get("GET", "/api/health", allocator) orelse return error.TestUnexpectedResult;
    defer cached.deinit();

    try std.testing.expectEqual(@as(u16, 200), cached.status);
    try std.testing.expectEqualStrings("{\"ok\":true}", cached.body);

    // Should have original header + proof-cache header
    var found_content_type = false;
    var found_proof_cache = false;
    for (cached.headers.items) |h| {
        if (std.ascii.eqlIgnoreCase(h.key, "content-type")) {
            try std.testing.expectEqualStrings("application/json", h.value);
            found_content_type = true;
        }
        if (std.ascii.eqlIgnoreCase(h.key, "X-Zttp-Proof-Cache")) {
            try std.testing.expectEqualStrings("hit", h.value);
            found_proof_cache = true;
        }
    }
    try std.testing.expect(found_content_type);
    try std.testing.expect(found_proof_cache);
}

test "get returns null on miss" {
    const allocator = std.testing.allocator;
    var cache = ProofCache.init(allocator, .{ .pure = true }, .{});
    defer cache.deinit();

    try std.testing.expect(cache.get("GET", "/nonexistent", allocator) == null);
}

test "capacity eviction" {
    const allocator = std.testing.allocator;
    var cache = ProofCache.init(allocator, .{ .pure = true }, .{ .max_entries = 2 });
    defer cache.deinit();

    // Insert 3 entries - first should be evicted
    var resp = HttpResponse.init(allocator);
    resp.status = 200;
    cache.put("GET", "/one", &resp);

    resp.status = 201;
    cache.put("GET", "/two", &resp);

    resp.status = 202;
    cache.put("GET", "/three", &resp);
    resp.deinit();

    // /one should be evicted
    try std.testing.expect(cache.get("GET", "/one", allocator) == null);

    // /two and /three should still be present
    var c2 = cache.get("GET", "/two", allocator) orelse return error.TestUnexpectedResult;
    defer c2.deinit();
    try std.testing.expectEqual(@as(u16, 201), c2.status);

    var c3 = cache.get("GET", "/three", allocator) orelse return error.TestUnexpectedResult;
    defer c3.deinit();
    try std.testing.expectEqual(@as(u16, 202), c3.status);
}

test "capacity eviction stays correct and bounded across compaction" {
    const allocator = std.testing.allocator;
    var cache = ProofCache.init(allocator, .{ .pure = true }, .{ .max_entries = 4 });
    defer cache.deinit();

    var resp = HttpResponse.init(allocator);
    defer resp.deinit();

    var buf: [32]u8 = undefined;
    const total: usize = 60;
    var i: usize = 0;
    while (i < total) : (i += 1) {
        const path = std.fmt.bufPrint(&buf, "/k{d}", .{i}) catch unreachable;
        resp.status = @intCast(200 + (i % 100));
        cache.put("GET", path, &resp);
    }

    // Only the last max_entries keys survive; everything older is evicted.
    i = 0;
    while (i < total) : (i += 1) {
        const path = std.fmt.bufPrint(&buf, "/k{d}", .{i}) catch unreachable;
        const got = cache.get("GET", path, allocator);
        if (i >= total - 4) {
            var c = got orelse return error.TestUnexpectedResult;
            c.deinit();
        } else {
            try std.testing.expect(got == null);
        }
    }

    // Compaction reclaimed the dead prefix: the backing array tracks the live
    // entry count, not the total number of inserts.
    try std.testing.expect(cache.insertion_order.items.len <= 32);
}

test "max_body_size enforcement" {
    const allocator = std.testing.allocator;
    var cache = ProofCache.init(allocator, .{ .pure = true }, .{ .max_body_size = 16 });
    defer cache.deinit();

    var resp = HttpResponse.init(allocator);
    defer resp.deinit();
    resp.status = 200;
    // Body larger than max_body_size
    const big_body = try allocator.dupe(u8, "this body exceeds the sixteen byte limit");
    resp.setBodyOwned(big_body);

    cache.put("GET", "/big", &resp);

    // Should not be cached
    try std.testing.expect(cache.get("GET", "/big", allocator) == null);
}

test "Vary response is not cached" {
    const allocator = std.testing.allocator;
    var cache = ProofCache.init(allocator, .{ .pure = true }, .{});
    defer cache.deinit();

    var resp = HttpResponse.init(allocator);
    defer resp.deinit();
    resp.status = 200;
    const body = try allocator.dupe(u8, "{\"ok\":true}");
    resp.setBodyOwned(body);
    try resp.putHeader("vary", "Accept");

    cache.put("GET", "/negotiated", &resp);

    // Content-negotiated response must not be served from a method+URL key.
    try std.testing.expect(cache.get("GET", "/negotiated", allocator) == null);
}

test "empty Vary value still caches" {
    const allocator = std.testing.allocator;
    var cache = ProofCache.init(allocator, .{ .pure = true }, .{});
    defer cache.deinit();

    var resp = HttpResponse.init(allocator);
    defer resp.deinit();
    resp.status = 200;
    const body = try allocator.dupe(u8, "ok");
    resp.setBodyOwned(body);
    try resp.putHeader("vary", "");

    cache.put("GET", "/plain", &resp);

    var cached = cache.get("GET", "/plain", allocator) orelse return error.TestUnexpectedResult;
    defer cached.deinit();
    try std.testing.expectEqual(@as(u16, 200), cached.status);
}

test "deep copy independence" {
    const allocator = std.testing.allocator;
    var cache = ProofCache.init(allocator, .{ .pure = true }, .{});
    defer cache.deinit();

    // Build and cache a response, then destroy the original
    {
        var resp = HttpResponse.init(allocator);
        defer resp.deinit();
        resp.status = 200;
        const body = try allocator.dupe(u8, "original");
        resp.setBodyOwned(body);
        try resp.putHeader("x-test", "value");

        cache.put("GET", "/test", &resp);
    }
    // Original is now freed

    // Cached copy should still be valid
    var cached = cache.get("GET", "/test", allocator) orelse return error.TestUnexpectedResult;
    defer cached.deinit();

    try std.testing.expectEqual(@as(u16, 200), cached.status);
    try std.testing.expectEqualStrings("original", cached.body);
}

test "stats tracking" {
    const allocator = std.testing.allocator;
    var cache = ProofCache.init(allocator, .{ .pure = true }, .{});
    defer cache.deinit();

    // Miss
    _ = cache.get("GET", "/test", allocator);

    // Put + hit
    var resp = HttpResponse.init(allocator);
    resp.status = 200;
    cache.put("GET", "/test", &resp);
    resp.deinit();

    var cached = cache.get("GET", "/test", allocator) orelse return error.TestUnexpectedResult;
    cached.deinit();

    const stats = cache.getStats();
    try std.testing.expectEqual(@as(u64, 1), stats.hits);
    try std.testing.expectEqual(@as(u64, 1), stats.misses);
    try std.testing.expectEqual(@as(u32, 1), stats.entries);
}

test "replacing existing key" {
    const allocator = std.testing.allocator;
    var cache = ProofCache.init(allocator, .{ .pure = true }, .{});
    defer cache.deinit();

    // Insert first version
    var resp1 = HttpResponse.init(allocator);
    resp1.status = 200;
    const body1 = try allocator.dupe(u8, "v1");
    resp1.setBodyOwned(body1);
    cache.put("GET", "/test", &resp1);
    resp1.deinit();

    // Replace with second version
    var resp2 = HttpResponse.init(allocator);
    resp2.status = 201;
    const body2 = try allocator.dupe(u8, "v2");
    resp2.setBodyOwned(body2);
    cache.put("GET", "/test", &resp2);
    resp2.deinit();

    // Should get the second version
    var cached = cache.get("GET", "/test", allocator) orelse return error.TestUnexpectedResult;
    defer cached.deinit();

    try std.testing.expectEqual(@as(u16, 201), cached.status);
    try std.testing.expectEqualStrings("v2", cached.body);
}

test "hash collisions do not poison or overwrite distinct method+url entries" {
    const CollidingCache = ProofCacheWithHash(struct {
        fn constantHash(_: []const u8, _: []const u8) u64 {
            return 0x1234_5678_9abc_def0;
        }
    }.constantHash);

    const allocator = std.testing.allocator;
    var cache = CollidingCache.init(allocator, .{ .pure = true }, .{});
    defer cache.deinit();

    var r1 = HttpResponse.init(allocator);
    defer r1.deinit();
    r1.status = 200;
    r1.setBodyOwned(try allocator.dupe(u8, "secret-payload"));
    cache.put("GET", "/a", &r1);

    var r2 = HttpResponse.init(allocator);
    defer r2.deinit();
    r2.status = 200;
    r2.setBodyOwned(try allocator.dupe(u8, "public-payload"));
    cache.put("GET", "/b", &r2);

    var got_a = cache.get("GET", "/a", allocator) orelse return error.TestUnexpectedResult;
    defer got_a.deinit();
    try std.testing.expectEqualStrings("secret-payload", got_a.body);

    var got_b = cache.get("GET", "/b", allocator) orelse return error.TestUnexpectedResult;
    defer got_b.deinit();
    try std.testing.expectEqualStrings("public-payload", got_b.body);

    try std.testing.expect(cache.get("GET", "/c", allocator) == null);
    try std.testing.expect(cache.get("HEAD", "/a", allocator) == null);
    try std.testing.expectEqual(@as(u32, 2), cache.getStats().entries);
}

test "refuses non-2xx/3xx responses, Set-Cookie, and case-insensitive Cache-Control directives" {
    const allocator = std.testing.allocator;
    var cache = ProofCache.init(allocator, .{ .pure = true }, .{});
    defer cache.deinit();

    // Non-2xx/3xx statuses are refused
    var r500 = HttpResponse.init(allocator);
    defer r500.deinit();
    r500.status = 500;
    cache.put("GET", "/err500", &r500);
    try std.testing.expect(cache.get("GET", "/err500", allocator) == null);

    var r404 = HttpResponse.init(allocator);
    defer r404.deinit();
    r404.status = 404;
    cache.put("GET", "/err404", &r404);
    try std.testing.expect(cache.get("GET", "/err404", allocator) == null);

    var r100 = HttpResponse.init(allocator);
    defer r100.deinit();
    r100.status = 100;
    cache.put("GET", "/info100", &r100);
    try std.testing.expect(cache.get("GET", "/info100", allocator) == null);

    // 3xx status IS allowed when headers permit caching
    var r301 = HttpResponse.init(allocator);
    defer r301.deinit();
    r301.status = 301;
    cache.put("GET", "/redir", &r301);
    var got_redir = cache.get("GET", "/redir", allocator) orelse return error.TestUnexpectedResult;
    defer got_redir.deinit();
    try std.testing.expectEqual(@as(u16, 301), got_redir.status);

    // Set-Cookie is refused
    var r_cookie = HttpResponse.init(allocator);
    defer r_cookie.deinit();
    r_cookie.status = 200;
    try r_cookie.putHeader("Set-Cookie", "sid=abc; HttpOnly");
    cache.put("GET", "/login", &r_cookie);
    try std.testing.expect(cache.get("GET", "/login", allocator) == null);

    // Response Cache-Control: NO-STORE and Private (mixed case) are refused
    var r_nostore = HttpResponse.init(allocator);
    defer r_nostore.deinit();
    r_nostore.status = 200;
    try r_nostore.putHeader("Cache-Control", "NO-STORE, max-age=0");
    cache.put("GET", "/nostore", &r_nostore);
    try std.testing.expect(cache.get("GET", "/nostore", allocator) == null);

    var r_private = HttpResponse.init(allocator);
    defer r_private.deinit();
    r_private.status = 200;
    try r_private.putHeader("Cache-Control", "Private, max-age=60");
    cache.put("GET", "/private", &r_private);
    try std.testing.expect(cache.get("GET", "/private", allocator) == null);

    // Request Cache-Control case-insensitive checks
    var req_hdrs: std.ArrayListUnmanaged(HttpHeader) = .empty;
    defer req_hdrs.deinit(allocator);
    try req_hdrs.append(allocator, .{ .key = "Cache-Control", .value = "NO-STORE" });
    try std.testing.expect(!ProofCache.shouldCache("GET", req_hdrs));

    req_hdrs.clearRetainingCapacity();
    try req_hdrs.append(allocator, .{ .key = "Cache-Control", .value = "Private" });
    try std.testing.expect(!ProofCache.shouldCache("GET", req_hdrs));

    req_hdrs.clearRetainingCapacity();
    try req_hdrs.append(allocator, .{ .key = "Cache-Control", .value = "NO-CACHE" });
    try std.testing.expect(!ProofCache.shouldCache("GET", req_hdrs));
}
