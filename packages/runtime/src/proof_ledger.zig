//! Append-only ledger of proof events. One JSONL line per `zttp deploy`
//! and per `dev --watch --prove` swap.
//!
//! Storage: `.zttp/proofs.jsonl`. Lines are appended via POSIX `O_APPEND`;
//! concurrent writers within the PIPE_BUF window (4 KiB on Linux/macOS)
//! cannot tear lines. Lines exceeding that window are safe under a single
//! writer.
//!
//! `ReviewFacts` (from `deploy/review.zig`) is already PII/secret-free, so
//! the ledger inherits that contract.

const std = @import("std");
const zts = @import("zts");
const review = @import("zttp_proof_review").review;
const json_util = @import("zttp_proof_review").json_util;

pub const EventKind = enum {
    deploy,
    swap,
    /// Legacy: a signed perf-as-proof receipt attached to an applied edit.
    /// Nothing writes this kind any more (the probe was removed in plan 005
    /// G10), but existing ledgers hold such rows and `parseLine` rejects an
    /// unknown kind, so it stays readable. Carries a `perf` JSON object
    /// alongside `facts`.
    perf,
    /// Legacy: a signed behavioral-equivalence verdict, the classification
    /// `contract_diff` computed between two handler versions, in a signed
    /// `equivalence` JSON object alongside `facts`. Nothing writes this kind
    /// any more (plan 005 G10); it stays readable for existing ledgers.
    equivalence,

    pub fn toString(self: EventKind) []const u8 {
        return switch (self) {
            .deploy => "deploy",
            .swap => "swap",
            .perf => "perf",
            .equivalence => "equivalence",
        };
    }

    pub fn fromString(s: []const u8) ?EventKind {
        if (std.mem.eql(u8, s, "deploy")) return .deploy;
        if (std.mem.eql(u8, s, "swap")) return .swap;
        if (std.mem.eql(u8, s, "perf")) return .perf;
        if (std.mem.eql(u8, s, "equivalence")) return .equivalence;
        return null;
    }
};

/// Payload of a legacy `kind=perf` row. The `sig` field is the compact JWS
/// that the removed `zts.perf_receipt.sign` produced over the same numeric
/// fields (see `pre-rebase:packages/zts/src/perf_receipt.zig`). This code
/// never verifies it.
///
/// `sample_count == 0` means the probe was skipped (handler capabilities
/// disqualified it: see proof_enrichment.zig). The row still records the
/// fact that an apply happened so that a future audit can prove no
/// receipt was suppressed.
pub const PerfPayload = struct {
    handler_hash: []const u8,
    p50_us: u64,
    p99_us: u64,
    alloc_bytes: u64,
    sample_count: u64,
    sig: []const u8,

    pub fn deinit(self: *PerfPayload, allocator: std.mem.Allocator) void {
        allocator.free(self.handler_hash);
        allocator.free(self.sig);
    }
};

/// Payload of a legacy `kind=equivalence` row. The `sig` field is the
/// compact JWS that the removed `zts.equivalence_receipt.sign` produced over
/// the verdict-defining fields (see
/// `pre-rebase:packages/zts/src/equivalence_receipt.zig`). This code never
/// verifies it. `classification` is one of
/// equivalent / equivalent_modulo_laws / additive / breaking, and
/// `claim_scope` (pure / deterministic / structural) records how strong the
/// claim is, so an effectful handler never reads as a clean behavioral
/// equivalence.
pub const EquivalencePayload = struct {
    before_contract_hash: []const u8,
    after_contract_hash: []const u8,
    classification: []const u8,
    laws_fired: []const []const u8 = &.{},
    preserved: u32 = 0,
    response_changed: u32 = 0,
    added: u32 = 0,
    removed: u32 = 0,
    claim_scope: []const u8,
    sig: []const u8,

    pub fn deinit(self: *EquivalencePayload, allocator: std.mem.Allocator) void {
        allocator.free(self.before_contract_hash);
        allocator.free(self.after_contract_hash);
        allocator.free(self.classification);
        for (self.laws_fired) |law| allocator.free(law);
        allocator.free(self.laws_fired);
        allocator.free(self.claim_scope);
        allocator.free(self.sig);
    }
};

/// Strings are owned so a parsed event survives independently of the buffer
/// it came from.
pub const Event = struct {
    ts_unix_ms: i64,
    kind: EventKind,
    handler_path: []const u8,
    service_name: ?[]const u8,
    facts: review.ReviewFacts,
    /// Present only when `kind == .perf`. Older readers that predate
    /// Slice H ignore this field, which keeps the schema additive.
    perf: ?PerfPayload = null,
    /// Present only when `kind == .equivalence`. Older readers ignore this
    /// field, which keeps the schema additive.
    equivalence: ?EquivalencePayload = null,

    pub fn deinit(self: *Event, allocator: std.mem.Allocator) void {
        allocator.free(self.handler_path);
        if (self.service_name) |s| allocator.free(s);
        self.facts.deinit(allocator);
        if (self.perf) |*p| p.deinit(allocator);
        if (self.equivalence) |*e| e.deinit(allocator);
    }
};

pub fn ledgerPath() []const u8 {
    return ".zttp/proofs.jsonl";
}

fn ensureLedgerDir() !void {
    var io_backend = std.Io.Threaded.init(std.heap.smp_allocator, .{ .environ = .empty });
    defer io_backend.deinit();
    try std.Io.Dir.createDirPath(std.Io.Dir.cwd(), io_backend.io(), ".zttp");
}

pub const AppendParams = struct {
    kind: EventKind,
    facts: *const review.ReviewFacts,
    handler_path: []const u8,
    service_name: ?[]const u8 = null,
    /// Override clock for tests; null means read the wall clock.
    now_unix_ms: ?i64 = null,
    /// Present on deploy rows when the contract carries a cost envelope.
    /// `null` total with a body limit means the worst case is unbounded.
    cost_worst_case_total: ?u64 = null,
    cost_worst_case_body_limit: ?u64 = null,
};

pub fn appendEvent(allocator: std.mem.Allocator, params: AppendParams) !void {
    try ensureLedgerDir();

    const ts = params.now_unix_ms orelse defaultNowMs();

    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    var json: std.json.Stringify = .{ .writer = &aw.writer };
    try json.beginObject();
    try json.objectField("ts");
    try json.write(ts);
    try json.objectField("kind");
    try json.write(params.kind.toString());
    try json.objectField("handlerPath");
    try json.write(params.handler_path);
    if (params.service_name) |name| {
        try json.objectField("serviceName");
        try json.write(name);
    }
    try json.objectField("facts");
    try params.facts.writeJson(&json);
    if (params.cost_worst_case_body_limit) |body_limit| {
        try json.objectField("costWorstCase");
        if (params.cost_worst_case_total) |total| {
            try json.write(total);
        } else {
            try json.write("unbounded");
        }
        try json.objectField("costBodyLimit");
        try json.write(body_limit);
    }
    try json.endObject();
    try aw.writer.writeByte('\n');

    const bytes = aw.writer.buffered();

    const fd = try zts.file_io.openAppend(allocator, ledgerPath());
    defer std.Io.Threaded.closeFd(fd);

    var written: usize = 0;
    while (written < bytes.len) {
        const result = std.c.write(fd, bytes[written..].ptr, bytes.len - written);
        if (result < 0) {
            // SIGCHLD from cleanup of child processes is the common case during deploys.
            if (std.posix.errno(result) == .INTR) continue;
            return error.LedgerWriteFailed;
        }
        if (result == 0) return error.LedgerWriteFailed;
        written += @intCast(result);
    }
}

/// Reads in chronological order (oldest first). A missing ledger file
/// returns an empty slice. Caller frees with `freeEvents`.
pub fn readEvents(allocator: std.mem.Allocator) ![]Event {
    const bytes = zts.file_io.readFile(allocator, ledgerPath(), MAX_LEDGER_BYTES) catch |err| switch (err) {
        error.FileNotFound => return try allocator.alloc(Event, 0),
        // The ledger is append-only with no rotation, so it grows past the cap
        // on a long-lived dev/CI runner. Rather than brick the entire proofs
        // subsystem with a hard error, read the trailing window (recent events
        // are the useful ones for list/show/diff/watch).
        error.FileTooBig => try zts.file_io.readFileTail(allocator, ledgerPath(), MAX_LEDGER_BYTES),
        else => return err,
    };
    defer allocator.free(bytes);

    var out: std.ArrayList(Event) = .empty;
    errdefer {
        for (out.items) |*ev| ev.deinit(allocator);
        out.deinit(allocator);
    }

    var line_iter = std.mem.splitScalar(u8, bytes, '\n');
    while (line_iter.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        const event = try parseLine(allocator, trimmed);
        try out.append(allocator, event);
    }

    return try out.toOwnedSlice(allocator);
}

pub fn freeEvents(allocator: std.mem.Allocator, events: []Event) void {
    for (events) |*ev| ev.deinit(allocator);
    allocator.free(events);
}

const MAX_LEDGER_BYTES = 16 * 1024 * 1024;

// ---------------------------------------------------------------------------
// Ref resolution
// ---------------------------------------------------------------------------

/// `head` is the most recent event; `head_back(N)` is N entries before
/// HEAD; `sha_prefix` matches against `facts.contract_sha` and rejects
/// ambiguity.
pub const Ref = union(enum) {
    head: void,
    head_back: usize,
    sha_prefix: []const u8,
};

pub const RefError = error{
    EmptyRef,
    InvalidHeadOffset,
};

/// Borrows the input slice for `sha_prefix`; caller must keep it alive.
pub fn parseRef(text: []const u8) RefError!Ref {
    if (text.len == 0) return error.EmptyRef;
    if (std.mem.eql(u8, text, "HEAD")) return .{ .head = {} };
    if (std.mem.startsWith(u8, text, "HEAD~")) {
        const tail = text["HEAD~".len..];
        if (tail.len == 0) return error.InvalidHeadOffset;
        const n = std.fmt.parseInt(usize, tail, 10) catch return error.InvalidHeadOffset;
        return .{ .head_back = n };
    }
    return .{ .sha_prefix = text };
}

pub const ResolveError = error{
    NoEvents,
    OutOfRange,
    NotFound,
    Ambiguous,
};

/// `events` are ordered oldest-first as returned by `readEvents`.
pub fn resolve(events: []const Event, ref: Ref) ResolveError!usize {
    if (events.len == 0) return error.NoEvents;
    return switch (ref) {
        .head => events.len - 1,
        .head_back => |n| if (n >= events.len) error.OutOfRange else events.len - 1 - n,
        .sha_prefix => |prefix| blk: {
            var match: ?usize = null;
            for (events, 0..) |ev, i| {
                if (std.mem.startsWith(u8, ev.facts.contract_sha, prefix)) {
                    if (match != null) break :blk error.Ambiguous;
                    match = i;
                }
            }
            break :blk match orelse error.NotFound;
        },
    };
}

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

// Wall clock in unix milliseconds. Mirrors `control_plane.defaultNowSec` but
// includes ms precision so two events appended within the same second still
// sort deterministically.
pub fn defaultNowMs() i64 {
    var ts: std.posix.timespec = undefined;
    switch (std.posix.errno(std.posix.system.clock_gettime(.REALTIME, &ts))) {
        .SUCCESS => {
            const sec_ms: i64 = @as(i64, @intCast(ts.sec)) * 1000;
            const nsec_ms: i64 = @divTrunc(@as(i64, @intCast(ts.nsec)), std.time.ns_per_ms);
            return sec_ms + nsec_ms;
        },
        else => return 0,
    }
}

fn parseLine(allocator: std.mem.Allocator, line: []const u8) !Event {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidLedgerLine;
    const obj = parsed.value.object;

    const ts = json_util.getI64(obj, "ts") orelse return error.InvalidLedgerLine;

    const kind_str = json_util.getString(obj, "kind") orelse return error.InvalidLedgerLine;
    const kind = EventKind.fromString(kind_str) orelse return error.InvalidLedgerLine;

    const handler_path_value = json_util.getString(obj, "handlerPath") orelse return error.InvalidLedgerLine;
    const handler_path = try allocator.dupe(u8, handler_path_value);
    errdefer allocator.free(handler_path);

    var service_name: ?[]const u8 = null;
    errdefer if (service_name) |s| allocator.free(s);
    if (json_util.getString(obj, "serviceName")) |name| {
        service_name = try allocator.dupe(u8, name);
    }

    const facts_value = obj.get("facts") orelse return error.InvalidLedgerLine;
    if (facts_value != .object) return error.InvalidLedgerLine;
    var facts = try review.ReviewFacts.parseJson(allocator, facts_value.object);
    errdefer facts.deinit(allocator);

    var perf_payload: ?PerfPayload = null;
    errdefer if (perf_payload) |*p| p.deinit(allocator);
    if (obj.get("perf")) |perf_value| {
        if (perf_value != .object) return error.InvalidLedgerLine;
        perf_payload = try parsePerfPayload(allocator, perf_value.object);
    }

    var equivalence_payload: ?EquivalencePayload = null;
    errdefer if (equivalence_payload) |*e| e.deinit(allocator);
    if (obj.get("equivalence")) |eq_value| {
        if (eq_value != .object) return error.InvalidLedgerLine;
        equivalence_payload = try parseEquivalencePayload(allocator, eq_value.object);
    }

    return .{
        .ts_unix_ms = ts,
        .kind = kind,
        .handler_path = handler_path,
        .service_name = service_name,
        .facts = facts,
        .perf = perf_payload,
        .equivalence = equivalence_payload,
    };
}

fn parseEquivalencePayload(allocator: std.mem.Allocator, obj: std.json.ObjectMap) !EquivalencePayload {
    const before_str = json_util.getString(obj, "beforeContractHash") orelse return error.InvalidLedgerLine;
    const after_str = json_util.getString(obj, "afterContractHash") orelse return error.InvalidLedgerLine;
    const classification_str = json_util.getString(obj, "classification") orelse return error.InvalidLedgerLine;
    const claim_scope_str = json_util.getString(obj, "claimScope") orelse return error.InvalidLedgerLine;
    const sig_str = json_util.getString(obj, "sig") orelse return error.InvalidLedgerLine;

    var preserved: u32 = 0;
    var response_changed: u32 = 0;
    var added: u32 = 0;
    var removed: u32 = 0;
    if (obj.get("behaviorDiff")) |bd_value| {
        if (bd_value != .object) return error.InvalidLedgerLine;
        const bd = bd_value.object;
        preserved = readU32Field(bd, "preserved") orelse 0;
        response_changed = readU32Field(bd, "responseChanged") orelse 0;
        added = readU32Field(bd, "added") orelse 0;
        removed = readU32Field(bd, "removed") orelse 0;
    }

    var laws: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (laws.items) |law| allocator.free(law);
        laws.deinit(allocator);
    }
    if (obj.get("lawsFired")) |laws_value| {
        if (laws_value != .array) return error.InvalidLedgerLine;
        for (laws_value.array.items) |item| {
            if (item != .string) return error.InvalidLedgerLine;
            const dup = try allocator.dupe(u8, item.string);
            errdefer allocator.free(dup);
            try laws.append(allocator, dup);
        }
    }

    const before = try allocator.dupe(u8, before_str);
    errdefer allocator.free(before);
    const after = try allocator.dupe(u8, after_str);
    errdefer allocator.free(after);
    const classification = try allocator.dupe(u8, classification_str);
    errdefer allocator.free(classification);
    const claim_scope = try allocator.dupe(u8, claim_scope_str);
    errdefer allocator.free(claim_scope);
    const sig = try allocator.dupe(u8, sig_str);
    errdefer allocator.free(sig);

    return .{
        .before_contract_hash = before,
        .after_contract_hash = after,
        .classification = classification,
        .laws_fired = try laws.toOwnedSlice(allocator),
        .preserved = preserved,
        .response_changed = response_changed,
        .added = added,
        .removed = removed,
        .claim_scope = claim_scope,
        .sig = sig,
    };
}

fn readU32Field(obj: std.json.ObjectMap, key: []const u8) ?u32 {
    const v = json_util.getI64(obj, key) orelse return null;
    if (v < 0 or v > std.math.maxInt(u32)) return null;
    return @intCast(v);
}

fn parsePerfPayload(allocator: std.mem.Allocator, obj: std.json.ObjectMap) !PerfPayload {
    const handler_hash_str = json_util.getString(obj, "handlerHash") orelse return error.InvalidLedgerLine;
    const sig_str = json_util.getString(obj, "sig") orelse return error.InvalidLedgerLine;
    const p50 = json_util.getI64(obj, "p50Us") orelse return error.InvalidLedgerLine;
    const p99 = json_util.getI64(obj, "p99Us") orelse return error.InvalidLedgerLine;
    const alloc_bytes = json_util.getI64(obj, "allocBytes") orelse return error.InvalidLedgerLine;
    const samples = json_util.getI64(obj, "sampleCount") orelse return error.InvalidLedgerLine;
    if (p50 < 0 or p99 < 0 or alloc_bytes < 0 or samples < 0) return error.InvalidLedgerLine;

    const handler_hash = try allocator.dupe(u8, handler_hash_str);
    errdefer allocator.free(handler_hash);
    const sig = try allocator.dupe(u8, sig_str);
    errdefer allocator.free(sig);

    return .{
        .handler_hash = handler_hash,
        .p50_us = @intCast(p50),
        .p99_us = @intCast(p99),
        .alloc_bytes = @intCast(alloc_bytes),
        .sample_count = @intCast(samples),
        .sig = sig,
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

/// Chdir to a tmp dir for tests that need an isolated `.zttp/` root.
/// Returned slice is the previous cwd; caller frees with the testing
/// allocator and restores via `std.Io.Threaded.chdir`.
pub fn chdirTmpForTest(tmp: *std.testing.TmpDir) ![:0]u8 {
    const old_cwd = try std.process.currentPathAlloc(testing.io, testing.allocator);
    errdefer testing.allocator.free(old_cwd);
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(testing.io, &buf);
    try std.Io.Threaded.chdir(buf[0..len]);
    return old_cwd;
}

/// Test fixture: a ReviewFacts with one env key and a few proven properties.
/// `with_route` adds a `/healthz` route so callers can build deltas that
/// flip between safe and safe_with_additions.
pub fn buildFactsForTest(
    allocator: std.mem.Allocator,
    sha: []const u8,
    with_route: bool,
) !review.ReviewFacts {
    var routes: []review.Route = undefined;
    if (with_route) {
        routes = try allocator.alloc(review.Route, 1);
        routes[0] = .{ .pattern = try allocator.dupe(u8, "/healthz"), .is_prefix = false };
    } else {
        routes = try allocator.alloc(review.Route, 0);
    }
    return review.ReviewFacts{
        .contract_sha = try allocator.dupe(u8, sha),
        .proof_level = .complete,
        .env_keys = blk: {
            const arr = try allocator.alloc([]const u8, 1);
            arr[0] = try allocator.dupe(u8, "PORT");
            break :blk arr;
        },
        .egress_endpoints = try allocator.alloc([]const u8, 0),
        .cache_namespaces = try allocator.alloc([]const u8, 0),
        .routes = routes,
        .capabilities = try allocator.alloc([]const u8, 0),
        .properties = .{ .results_safe = true, .read_only = true },
    };
}

test "appendEvent then readEvents round trips" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const old_cwd = try chdirTmpForTest(&tmp);
    defer testing.allocator.free(old_cwd);
    defer std.Io.Threaded.chdir(old_cwd) catch {};

    var facts = try buildFactsForTest(testing.allocator, "sha-abc123", false);
    defer facts.deinit(testing.allocator);

    try appendEvent(testing.allocator, .{
        .kind = .deploy,
        .facts = &facts,
        .handler_path = "src/handler.ts",
        .service_name = "demo",
        .now_unix_ms = 1_700_000_000_000,
    });

    const events = try readEvents(testing.allocator);
    defer freeEvents(testing.allocator, events);

    try testing.expectEqual(@as(usize, 1), events.len);
    try testing.expectEqual(EventKind.deploy, events[0].kind);
    try testing.expectEqual(@as(i64, 1_700_000_000_000), events[0].ts_unix_ms);
    try testing.expectEqualStrings("src/handler.ts", events[0].handler_path);
    try testing.expect(events[0].service_name != null);
    try testing.expectEqualStrings("demo", events[0].service_name.?);
    try testing.expectEqualStrings("sha-abc123", events[0].facts.contract_sha);
    try testing.expectEqual(@as(usize, 1), events[0].facts.env_keys.len);
    try testing.expectEqualStrings("PORT", events[0].facts.env_keys[0]);
    try testing.expect(events[0].facts.properties.results_safe);
    try testing.expect(events[0].facts.properties.read_only);
}

test "appendEvent preserves existing hosted state bytes" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const old_cwd = try chdirTmpForTest(&tmp);
    defer testing.allocator.free(old_cwd);
    defer std.Io.Threaded.chdir(old_cwd) catch {};

    try ensureLedgerDir();
    const hosted_state = "{\"schemaVersion\":1,\"sentinel\":\"keep exactly\"}\n";
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = ".zttp/deploy-state.json",
        .data = hosted_state,
    });

    var facts = try buildFactsForTest(testing.allocator, "sha-sentinel", false);
    defer facts.deinit(testing.allocator);
    try appendEvent(testing.allocator, .{
        .kind = .deploy,
        .facts = &facts,
        .handler_path = "src/handler.ts",
        .now_unix_ms = 1,
    });

    const after = try tmp.dir.readFileAlloc(
        testing.io,
        ".zttp/deploy-state.json",
        testing.allocator,
        .limited(1024),
    );
    defer testing.allocator.free(after);
    try testing.expectEqualStrings(hosted_state, after);

    const proof_row = try tmp.dir.readFileAlloc(
        testing.io,
        ledgerPath(),
        testing.allocator,
        .limited(4096),
    );
    defer testing.allocator.free(proof_row);
    try testing.expectEqualStrings(
        "{\"ts\":1,\"kind\":\"deploy\",\"handlerPath\":\"src/handler.ts\",\"facts\":{" ++
            "\"contractSha\":\"sha-sentinel\",\"proofLevel\":\"complete\",\"envKeys\":[\"PORT\"]," ++
            "\"egressEndpoints\":[],\"cacheNamespaces\":[],\"capabilities\":[],\"routes\":[]," ++
            "\"properties\":{\"retrySafe\":false,\"readOnly\":true,\"deterministic\":true," ++
            "\"injectionSafe\":true,\"idempotent\":false,\"stateIsolated\":true," ++
            "\"noSecretLeakage\":true,\"noCredentialLeakage\":true,\"inputValidated\":true," ++
            "\"piiContained\":true,\"resultsSafe\":true,\"faultCovered\":false}," ++
            "\"declaredSpecs\":[],\"intentAssertionCount\":0,\"intentDynamic\":false," ++
            "\"behaviorPathCount\":0,\"failurePathCount\":0}}\n",
        proof_row,
    );
}

test "readEvents returns empty when ledger is missing" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const old_cwd = try chdirTmpForTest(&tmp);
    defer testing.allocator.free(old_cwd);
    defer std.Io.Threaded.chdir(old_cwd) catch {};

    const events = try readEvents(testing.allocator);
    defer freeEvents(testing.allocator, events);
    try testing.expectEqual(@as(usize, 0), events.len);
}

test "appendEvent appends in order across calls" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const old_cwd = try chdirTmpForTest(&tmp);
    defer testing.allocator.free(old_cwd);
    defer std.Io.Threaded.chdir(old_cwd) catch {};

    var f1 = try buildFactsForTest(testing.allocator, "sha-1", false);
    defer f1.deinit(testing.allocator);
    var f2 = try buildFactsForTest(testing.allocator, "sha-2", false);
    defer f2.deinit(testing.allocator);
    var f3 = try buildFactsForTest(testing.allocator, "sha-3", false);
    defer f3.deinit(testing.allocator);

    try appendEvent(testing.allocator, .{
        .kind = .deploy,
        .facts = &f1,
        .handler_path = "src/handler.ts",
        .now_unix_ms = 1,
    });
    try appendEvent(testing.allocator, .{
        .kind = .swap,
        .facts = &f2,
        .handler_path = "src/handler.ts",
        .now_unix_ms = 2,
    });
    try appendEvent(testing.allocator, .{
        .kind = .deploy,
        .facts = &f3,
        .handler_path = "src/handler.ts",
        .service_name = "demo",
        .now_unix_ms = 3,
    });

    const events = try readEvents(testing.allocator);
    defer freeEvents(testing.allocator, events);

    try testing.expectEqual(@as(usize, 3), events.len);
    try testing.expectEqual(EventKind.deploy, events[0].kind);
    try testing.expectEqual(EventKind.swap, events[1].kind);
    try testing.expectEqual(EventKind.deploy, events[2].kind);
    try testing.expectEqualStrings("sha-1", events[0].facts.contract_sha);
    try testing.expectEqualStrings("sha-3", events[2].facts.contract_sha);
}

test "parseRef accepts HEAD, HEAD~N, sha prefix" {
    try testing.expectEqual(Ref{ .head = {} }, try parseRef("HEAD"));

    const back = try parseRef("HEAD~3");
    try testing.expectEqual(@as(usize, 3), back.head_back);

    const sha = try parseRef("abc123");
    try testing.expectEqualStrings("abc123", sha.sha_prefix);
}

test "parseRef rejects empty and malformed offsets" {
    try testing.expectError(RefError.EmptyRef, parseRef(""));
    try testing.expectError(RefError.InvalidHeadOffset, parseRef("HEAD~"));
    try testing.expectError(RefError.InvalidHeadOffset, parseRef("HEAD~xyz"));
}

test "resolve handles HEAD, HEAD~N, sha prefix" {
    const allocator = testing.allocator;
    var f1 = try buildFactsForTest(allocator, "sha-aaa-1", false);
    defer f1.deinit(allocator);
    var f2 = try buildFactsForTest(allocator, "sha-bbb-2", false);
    defer f2.deinit(allocator);
    var f3 = try buildFactsForTest(allocator, "sha-ccc-3", false);
    defer f3.deinit(allocator);

    const events = [_]Event{
        .{ .ts_unix_ms = 1, .kind = .perf, .handler_path = "h", .service_name = null, .facts = f1 },
        .{ .ts_unix_ms = 2, .kind = .swap, .handler_path = "h", .service_name = null, .facts = f2 },
        .{ .ts_unix_ms = 3, .kind = .deploy, .handler_path = "h", .service_name = null, .facts = f3 },
    };

    try testing.expectEqual(@as(usize, 2), try resolve(&events, .{ .head = {} }));
    try testing.expectEqual(@as(usize, 1), try resolve(&events, .{ .head_back = 1 }));
    try testing.expectEqual(@as(usize, 0), try resolve(&events, .{ .head_back = 2 }));
    try testing.expectError(ResolveError.OutOfRange, resolve(&events, .{ .head_back = 3 }));
    try testing.expectEqual(@as(usize, 1), try resolve(&events, .{ .sha_prefix = "sha-bbb" }));
    try testing.expectError(ResolveError.NotFound, resolve(&events, .{ .sha_prefix = "sha-zzz" }));
    try testing.expectError(ResolveError.Ambiguous, resolve(&events, .{ .sha_prefix = "sha-" }));
}

test "resolve on empty ledger fails with NoEvents" {
    const events = &[_]Event{};
    try testing.expectError(ResolveError.NoEvents, resolve(events, .{ .head = {} }));
}

test "readEvents rejects malformed lines" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const old_cwd = try chdirTmpForTest(&tmp);
    defer testing.allocator.free(old_cwd);
    defer std.Io.Threaded.chdir(old_cwd) catch {};

    try ensureLedgerDir();

    const cases = [_][]const u8{
        "[1,2,3]\n", // root is array, not object
        "{\"kind\":\"deploy\",\"handlerPath\":\"h.ts\",\"facts\":{}}\n", // missing ts
        "{\"ts\":1,\"handlerPath\":\"h.ts\",\"facts\":{}}\n", // missing kind
        "{\"ts\":1,\"kind\":\"unknown-kind\",\"handlerPath\":\"h.ts\",\"facts\":{}}\n", // bad kind
        "{\"ts\":1,\"kind\":\"deploy\",\"facts\":{}}\n", // missing handlerPath
        "{\"ts\":1,\"kind\":\"deploy\",\"handlerPath\":\"h.ts\"}\n", // missing facts
        "{\"ts\":1,\"kind\":\"deploy\",\"handlerPath\":\"h.ts\",\"facts\":\"oops\"}\n", // facts not object
    };

    for (cases) |line| {
        // writeFile uses O_TRUNC, so each iteration starts fresh.
        try zts.file_io.writeFile(testing.allocator, ledgerPath(), line);
        try testing.expectError(error.InvalidLedgerLine, readEvents(testing.allocator));
    }
}

test "appendEvent without perf payload omits the field for back-compat" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const old_cwd = try chdirTmpForTest(&tmp);
    defer testing.allocator.free(old_cwd);
    defer std.Io.Threaded.chdir(old_cwd) catch {};

    var facts = try buildFactsForTest(testing.allocator, "sha-nope", false);
    defer facts.deinit(testing.allocator);

    try appendEvent(testing.allocator, .{
        .kind = .deploy,
        .facts = &facts,
        .handler_path = "src/handler.ts",
        .now_unix_ms = 1,
    });

    // Confirm the JSON has no "perf" key so old consumers see exactly
    // what they saw pre-Slice H.
    const raw = try zts.file_io.readFile(testing.allocator, ledgerPath(), 8192);
    defer testing.allocator.free(raw);
    try testing.expect(std.mem.indexOf(u8, raw, "\"perf\"") == null);

    const events = try readEvents(testing.allocator);
    defer freeEvents(testing.allocator, events);
    try testing.expectEqual(@as(usize, 1), events.len);
    try testing.expectEqual(@as(?PerfPayload, null), events[0].perf);
}

test "equivalence event kind round-trips through string" {
    try testing.expectEqual(EventKind.equivalence, EventKind.fromString("equivalence").?);
    try testing.expectEqualStrings("equivalence", EventKind.equivalence.toString());
}

// The perf and equivalence probes were removed and nothing writes these kinds
// any more. Ledgers on disk still hold such rows, and `parseLine` rejects an
// unknown kind, so both kinds must stay readable. The two rows below are the
// bytes the removed writers produced (captured from their own tests, with a
// fixed signing key), not rows built by `appendEvent`.
const legacy_perf_row =
    \\{"ts":1700000002000,"kind":"perf","handlerPath":"handler.ts","facts":{"contractSha":"91b697dc8adcc528386f9f6e70843eeb6522b304491e685b8a5e780cb0a5ba68","proofLevel":"none","envKeys":[],"egressEndpoints":[],"cacheNamespaces":[],"capabilities":[],"routes":[],"properties":{"retrySafe":false,"readOnly":false,"deterministic":true,"injectionSafe":true,"idempotent":false,"stateIsolated":true,"noSecretLeakage":true,"noCredentialLeakage":true,"inputValidated":true,"piiContained":true,"resultsSafe":false,"faultCovered":false},"declaredSpecs":[],"intentAssertionCount":0,"intentDynamic":false,"behaviorPathCount":0,"failurePathCount":0},"perf":{"handlerHash":"91b697dc8adcc528386f9f6e70843eeb6522b304491e685b8a5e780cb0a5ba68","p50Us":2,"p99Us":3,"allocBytes":0,"sampleCount":4096,"sig":"eyJhbGciOiJFZERTQSIsInR5cCI6Inp0dHAtcGVyZitqd3MiLCJraWQiOiIzMDk3ZTJkZWUyY2I0YTM0YjUzODQwY2RiNzA1YWVkNzEwNjdjMzZmNjhkYjBlMGY1NTljM2YzZmEwNDMzMTVmIiwiandrIjp7Imt0eSI6Ik9LUCIsImNydiI6IkVkMjU1MTkiLCJ4IjoiSVZMNDBadDVIU1JGTWtMaFh5NnJiTGZQLW50cVh0TUFsNVlPQnBpQjJ4SSJ9fQ.eyJ2IjoienR0cC1wZXJmLXYxIiwiaGFuZGxlckhhc2giOiI5MWI2OTdkYzhhZGNjNTI4Mzg2ZjlmNmU3MDg0M2VlYjY1MjJiMzA0NDkxZTY4NWI4YTVlNzgwY2IwYTViYTY4IiwicDUwVXMiOjIsInA5OVVzIjozLCJhbGxvY0J5dGVzIjowLCJzYW1wbGVDb3VudCI6NDA5Niwic2lnbmVkQXQiOjE3MDAwMDAwMDJ9.3pdG3LPmo6Uh7fFU5GC26J_l0v6HSSIRRx8TbJJPOpKk7Tdurd1CBGRa2BZo-eC4JBGOqoBcWD3k0C8p4APnBQ"}}
;

const legacy_equivalence_row =
    \\{"ts":1700000003000,"kind":"equivalence","handlerPath":"handler.ts","facts":{"contractSha":"d110210a2a5bf2eecc5ea09a01258cddae408c663986d87f2ba7ffc990982b24","proofLevel":"none","envKeys":[],"egressEndpoints":[],"cacheNamespaces":[],"capabilities":[],"routes":[],"properties":{"retrySafe":false,"readOnly":false,"deterministic":true,"injectionSafe":true,"idempotent":false,"stateIsolated":true,"noSecretLeakage":true,"noCredentialLeakage":true,"inputValidated":true,"piiContained":true,"resultsSafe":false,"faultCovered":false},"declaredSpecs":[],"intentAssertionCount":0,"intentDynamic":false,"behaviorPathCount":0,"failurePathCount":0},"equivalence":{"beforeContractHash":"d110210a2a5bf2eecc5ea09a01258cddae408c663986d87f2ba7ffc990982b24","afterContractHash":"d110210a2a5bf2eecc5ea09a01258cddae408c663986d87f2ba7ffc990982b24","classification":"equivalent","lawsFired":[],"behaviorDiff":{"preserved":1,"responseChanged":0,"added":0,"removed":0},"claimScope":"pure","sig":"eyJhbGciOiJFZERTQSIsInR5cCI6Inp0dHAtZXF1aXZhbGVuY2UrandzIn0.enR0cC1lcXVpdmFsZW5jZS12MQpkMTEwMjEwYTJhNWJmMmVlY2M1ZWEwOWEwMTI1OGNkZGFlNDA4YzY2Mzk4NmQ4N2YyYmE3ZmZjOTkwOTgyYjI0CmQxMTAyMTBhMmE1YmYyZWVjYzVlYTA5YTAxMjU4Y2RkYWU0MDhjNjYzOTg2ZDg3ZjJiYTdmZmM5OTA5ODJiMjQKZXF1aXZhbGVudApwdXJlCjEKMAowCjA.uyIK6MazyH96t8-7z-N6HanREgdUfcAwZY8JtBQyaEAupdOWkUG5KVfulL0iXnG6_2CZVzYCApv7TC24ERU2Bg"}}
;

test "a legacy kind=perf row written by the removed probe still loads" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const old_cwd = try chdirTmpForTest(&tmp);
    defer testing.allocator.free(old_cwd);
    defer std.Io.Threaded.chdir(old_cwd) catch {};

    try ensureLedgerDir();
    try zts.file_io.writeFile(testing.allocator, ledgerPath(), legacy_perf_row ++ "\n");

    const events = try readEvents(testing.allocator);
    defer freeEvents(testing.allocator, events);

    try testing.expectEqual(@as(usize, 1), events.len);
    try testing.expectEqual(EventKind.perf, events[0].kind);
    try testing.expectEqual(@as(i64, 1_700_000_002_000), events[0].ts_unix_ms);
    try testing.expectEqualStrings("handler.ts", events[0].handler_path);
    try testing.expectEqualStrings(
        "91b697dc8adcc528386f9f6e70843eeb6522b304491e685b8a5e780cb0a5ba68",
        events[0].facts.contract_sha,
    );
    try testing.expect(events[0].equivalence == null);
    const perf = events[0].perf orelse return error.MissingPerfPayload;
    try testing.expectEqualStrings(events[0].facts.contract_sha, perf.handler_hash);
    try testing.expectEqual(@as(u64, 2), perf.p50_us);
    try testing.expectEqual(@as(u64, 3), perf.p99_us);
    try testing.expectEqual(@as(u64, 0), perf.alloc_bytes);
    try testing.expectEqual(@as(u64, 4096), perf.sample_count);
    try testing.expect(std.mem.startsWith(u8, perf.sig, "eyJhbGciOiJFZERTQSIs"));
}

test "a legacy kind=equivalence row written by the removed probe still loads" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const old_cwd = try chdirTmpForTest(&tmp);
    defer testing.allocator.free(old_cwd);
    defer std.Io.Threaded.chdir(old_cwd) catch {};

    try ensureLedgerDir();
    try zts.file_io.writeFile(testing.allocator, ledgerPath(), legacy_equivalence_row ++ "\n");

    const events = try readEvents(testing.allocator);
    defer freeEvents(testing.allocator, events);

    try testing.expectEqual(@as(usize, 1), events.len);
    try testing.expectEqual(EventKind.equivalence, events[0].kind);
    try testing.expectEqual(@as(i64, 1_700_000_003_000), events[0].ts_unix_ms);
    try testing.expectEqualStrings("handler.ts", events[0].handler_path);
    try testing.expect(events[0].perf == null);
    const eq = events[0].equivalence orelse return error.MissingEquivalencePayload;
    try testing.expectEqualStrings(
        "d110210a2a5bf2eecc5ea09a01258cddae408c663986d87f2ba7ffc990982b24",
        eq.before_contract_hash,
    );
    try testing.expectEqualStrings(eq.before_contract_hash, eq.after_contract_hash);
    try testing.expectEqualStrings("equivalent", eq.classification);
    try testing.expectEqualStrings("pure", eq.claim_scope);
    try testing.expectEqual(@as(usize, 0), eq.laws_fired.len);
    try testing.expectEqual(@as(u32, 1), eq.preserved);
    try testing.expectEqual(@as(u32, 0), eq.response_changed);
    try testing.expectEqual(@as(u32, 0), eq.added);
    try testing.expectEqual(@as(u32, 0), eq.removed);
    try testing.expect(std.mem.startsWith(u8, eq.sig, "eyJhbGciOiJFZERTQSIs"));
}

// A raw `kind=equivalence` row whose payload is not empty: it carries fired
// laws and non-zero counts, which the captured legacy row above does not.
// The facts are the legacy row's own; only the payload differs.
const raw_equivalence_row = legacy_equivalence_row[0..(std.mem.indexOf(u8, legacy_equivalence_row, "\"equivalence\":") orelse unreachable)] ++
    "\"equivalence\":{\"beforeContractHash\":\"aa\",\"afterContractHash\":\"bb\",\"classification\":\"equivalent_modulo_laws\",\"lawsFired\":[\"spread_assoc\",\"guard_hoist\"],\"behaviorDiff\":{\"preserved\":5,\"responseChanged\":0,\"added\":1,\"removed\":0},\"claimScope\":\"deterministic\",\"sig\":\"header.payload.signature\"}}";

test "a raw kind=equivalence row decodes fired laws and counts" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const old_cwd = try chdirTmpForTest(&tmp);
    defer testing.allocator.free(old_cwd);
    defer std.Io.Threaded.chdir(old_cwd) catch {};

    try ensureLedgerDir();
    try zts.file_io.writeFile(testing.allocator, ledgerPath(), raw_equivalence_row ++ "\n");

    const events = try readEvents(testing.allocator);
    defer freeEvents(testing.allocator, events);

    try testing.expectEqual(@as(usize, 1), events.len);
    try testing.expectEqual(EventKind.equivalence, events[0].kind);
    try testing.expect(events[0].equivalence != null);
    const got = events[0].equivalence.?;
    try testing.expectEqualStrings("aa", got.before_contract_hash);
    try testing.expectEqualStrings("bb", got.after_contract_hash);
    try testing.expectEqualStrings("equivalent_modulo_laws", got.classification);
    try testing.expectEqual(@as(usize, 2), got.laws_fired.len);
    try testing.expectEqualStrings("spread_assoc", got.laws_fired[0]);
    try testing.expectEqualStrings("guard_hoist", got.laws_fired[1]);
    try testing.expectEqual(@as(u32, 5), got.preserved);
    try testing.expectEqual(@as(u32, 1), got.added);
    try testing.expectEqualStrings("deterministic", got.claim_scope);
    try testing.expectEqualStrings("header.payload.signature", got.sig);
}
