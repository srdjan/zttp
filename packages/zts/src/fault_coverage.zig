//! Compile-Time Fault Coverage Analysis
//!
//! Consumes the PathGenerator's enumerated execution paths and analyzes how
//! the handler responds to each I/O failure mode. Produces a FaultCoverageReport
//! containing per-call-site entries, an overall coverage grade, and diagnostics
//! for suspicious failure handling (e.g., 2xx on auth failure).
//!
//! This is possible because zttp's virtual modules have known failure modes
//! declared via FailureSeverity in their FunctionBinding, and the PathGenerator
//! already enumerates every success/failure fork with constraints.
//!
//! The checker does NOT prescribe correct status codes. It warns about structural
//! patterns that are overwhelmingly correlated with bugs (returning 200 when
//! JWT verification fails) and produces a coverage matrix as a build artifact.

const std = @import("std");
const mb = @import("zts-engine").module_binding;
const builtin_modules = @import("zts-engine").builtin_modules;
const atom_table = @import("zts-engine").atom_table;
const parser_mod = @import("zts-engine").parser;
const path_gen = @import("path_generator.zig");
const handler_verifier = @import("handler_verifier.zig");

const route_match = @import("zts-base").route_match;
const Constraint = path_gen.Constraint;
const StubInfo = path_gen.StubInfo;
const GeneratedTest = path_gen.GeneratedTest;
const IrView = parser_mod.IrView;

// ---------------------------------------------------------------------------
// External severity overrides
// ---------------------------------------------------------------------------

pub const ExternalSeverity = struct {
    path: []const u8,
    method: []const u8,
    severity: mb.FailureSeverity,
    reason: []const u8,
};

/// Parse external severity overrides from JSON bytes.
/// Expected format:
/// ```json
/// {
///   "callSites": [
///     { "path": "/api/orders/:id/approve", "method": "POST",
///       "severity": "critical", "reason": "Governed transition" }
///   ]
/// }
/// ```
pub fn parseExternalSeverities(
    allocator: std.mem.Allocator,
    json_bytes: []const u8,
) ![]const ExternalSeverity {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, json_bytes, .{}) catch
        return error.InvalidJson;
    defer parsed.deinit();

    if (parsed.value != .object) return error.InvalidJson;
    const root = parsed.value.object;

    const call_sites_val = root.get("callSites") orelse return error.InvalidJson;
    if (call_sites_val != .array) return error.InvalidJson;
    const call_sites = call_sites_val.array;

    var result: std.ArrayList(ExternalSeverity) = .empty;
    errdefer {
        for (result.items) |item| {
            allocator.free(item.path);
            allocator.free(item.method);
            allocator.free(item.reason);
        }
        result.deinit(allocator);
    }

    for (call_sites.items) |entry| {
        if (entry != .object) continue;
        const obj = entry.object;

        const path_val = obj.get("path") orelse continue;
        const method_val = obj.get("method") orelse continue;
        const severity_val = obj.get("severity") orelse continue;

        if (path_val != .string or method_val != .string or severity_val != .string) continue;

        const severity = mapSeverityString(severity_val.string) orelse continue;

        const reason_val = obj.get("reason");
        const reason_str = if (reason_val) |rv|
            (if (rv == .string) rv.string else "")
        else
            "";

        const path_dupe = try allocator.dupe(u8, path_val.string);
        errdefer allocator.free(path_dupe);
        const method_dupe = try allocator.dupe(u8, method_val.string);
        errdefer allocator.free(method_dupe);
        const reason_dupe = try allocator.dupe(u8, reason_str);
        errdefer allocator.free(reason_dupe);

        try result.append(allocator, .{
            .path = path_dupe,
            .method = method_dupe,
            .severity = severity,
            .reason = reason_dupe,
        });
    }

    return try result.toOwnedSlice(allocator);
}

/// Map a severity string to the FailureSeverity enum.
/// "high" is treated as an alias for "critical".
pub fn mapSeverityString(s: []const u8) ?mb.FailureSeverity {
    if (std.mem.eql(u8, s, "critical")) return .critical;
    if (std.mem.eql(u8, s, "high")) return .critical;
    if (std.mem.eql(u8, s, "normal")) return .expected;
    if (std.mem.eql(u8, s, "upstream")) return .upstream;
    if (std.mem.eql(u8, s, "none")) return .none;
    return null;
}

/// Return the more severe of two severity levels.
/// Ordering: critical > upstream > expected > none.
pub fn maxSeverity(a: mb.FailureSeverity, b: mb.FailureSeverity) mb.FailureSeverity {
    return if (severityRank(a) >= severityRank(b)) a else b;
}

fn severityRank(s: mb.FailureSeverity) u8 {
    return switch (s) {
        .critical => 3,
        .upstream => 2,
        .expected => 1,
        .none => 0,
    };
}

const pathsMatch = route_match.pathsMatch;

// ---------------------------------------------------------------------------
// Diagnostic types
// ---------------------------------------------------------------------------

pub const Severity = enum {
    warning,
    info,

    pub fn label(self: Severity) []const u8 {
        return switch (self) {
            .warning => "warning",
            .info => "info",
        };
    }
};

pub const DiagnosticKind = enum {
    success_on_critical_failure,
    success_on_upstream_failure,
};

pub const Diagnostic = struct {
    severity: Severity,
    kind: DiagnosticKind,
    func_name: []const u8,
    module_name: []const u8,
    path_name: []const u8,
    status: u16,
    message: []const u8,
};

// ---------------------------------------------------------------------------
// Per-call-site entry in the coverage report
// ---------------------------------------------------------------------------

pub const CallSiteEntry = struct {
    func: []const u8,
    module: []const u8,
    severity: mb.FailureSeverity,
    has_failure_path: bool,
    failure_status: u16,
    flagged: bool,
    /// A failure path of an upstream site returns 2xx. The site is covered, and
    /// this records that the 2xx may be a fallback the author meant.
    upstream_fallback: bool = false,
};

// ---------------------------------------------------------------------------
// Coverage report
// ---------------------------------------------------------------------------

pub const FaultCoverageReport = struct {
    entries: []const CallSiteEntry,
    diagnostics: []const Diagnostic,
    total_failable: u32,
    covered: u32,
    warning_count: u32,
    /// Covered upstream sites whose failure path returns 2xx. They stay covered
    /// (a fallback may be intended), and this count makes them visible.
    upstream_fallback_sites: u32 = 0,

    pub fn isCovered(self: FaultCoverageReport) bool {
        return self.covered == self.total_failable and self.total_failable > 0;
    }

    pub fn isClean(self: FaultCoverageReport) bool {
        return self.isCovered() and self.warning_count == 0;
    }
};

// ---------------------------------------------------------------------------
// FaultCoverageChecker
// ---------------------------------------------------------------------------

pub const FaultCoverageChecker = struct {
    allocator: std.mem.Allocator,
    tests: []const GeneratedTest,
    entries: std.ArrayList(CallSiteEntry),
    diagnostics: std.ArrayList(Diagnostic),
    external_severities: ?[]const ExternalSeverity = null,

    pub fn init(allocator: std.mem.Allocator, tests: []const GeneratedTest) FaultCoverageChecker {
        return .{
            .allocator = allocator,
            .tests = tests,
            .entries = .empty,
            .diagnostics = .empty,
        };
    }

    pub fn setExternalSeverities(self: *FaultCoverageChecker, severities: []const ExternalSeverity) void {
        self.external_severities = severities;
    }

    pub fn deinit(self: *FaultCoverageChecker) void {
        self.entries.deinit(self.allocator);
        self.diagnostics.deinit(self.allocator);
    }

    pub fn analyze(self: *FaultCoverageChecker) !void {
        var seen_funcs = std.StringHashMapUnmanaged(CallSiteEntry).empty;
        defer {
            var key_iter = seen_funcs.iterator();
            while (key_iter.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
            }
            seen_funcs.deinit(self.allocator);
        }

        for (self.tests) |test_case| {
            // Determine external severity override for this test case's route
            const ext_override = self.lookupExternalOverride(test_case);

            // Seed every failable site on every emitted path, on the handler
            // root as on route roots, including calls whose result the path
            // never branches on. A constraint below can prove that this exact
            // site has a failure path. Another call to the same module
            // function cannot lend it coverage, so every entry is keyed by its
            // call site.
            for (test_case.io_stubs.items) |stub| {
                const seeded = try self.getOrPutEntry(
                    &seen_funcs,
                    stub.module,
                    stub.func,
                    routedCallSiteId(test_case, stub.call_site, stub.seq),
                    ext_override,
                ) orelse continue;
                // `export() ?? fallback`: the fallback is the explicit failure
                // path for an absent value. The site is covered, and the
                // path's status is not a failure status, so nothing is flagged.
                if (stub.absent_handled) {
                    seeded.has_failure_path = true;
                    seeded.failure_status = test_case.expected_status;
                }
            }

            for (test_case.constraints) |c| {
                // `countedSite` is the one definition of which constraints name
                // a call this checker counts; the generator's unseen-call scan
                // uses it too, so the two cannot disagree. A request shape or a
                // status test names no call and is skipped.
                const info: StubInfo = c.countedSite() orelse continue;

                const entry = try self.getOrPutEntry(
                    &seen_funcs,
                    info.module,
                    info.func,
                    routedCallSiteId(test_case, info.call_site, 0),
                    ext_override,
                ) orelse continue;

                if (c.isFailure()) {
                    entry.has_failure_path = true;
                    entry.failure_status = test_case.expected_status;
                    try self.checkFailurePath(entry, test_case, ext_override);
                }
            }
        }

        // Collect entries sorted by function name for deterministic output
        var func_names: std.ArrayList([]const u8) = .empty;
        defer func_names.deinit(self.allocator);
        var it = seen_funcs.iterator();
        while (it.next()) |kv| {
            try func_names.append(self.allocator, kv.key_ptr.*);
        }
        std.mem.sort([]const u8, func_names.items, {}, struct {
            fn cmp(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.order(u8, a, b) == .lt;
            }
        }.cmp);

        for (func_names.items) |name| {
            try self.entries.append(self.allocator, seen_funcs.get(name).?);
        }
    }

    fn getOrPutEntry(
        self: *FaultCoverageChecker,
        seen: *std.StringHashMapUnmanaged(CallSiteEntry),
        module: []const u8,
        func: []const u8,
        call_site: u64,
        ext_override: ?ExternalSeverity,
    ) !?*CallSiteEntry {
        const key = try std.fmt.allocPrint(
            self.allocator,
            "{d}\x00{s}\x00{s}",
            .{ call_site, module, func },
        );
        const gop = seen.getOrPut(self.allocator, key) catch |err| {
            self.allocator.free(key);
            return err;
        };
        if (!gop.found_existing) {
            var severity = lookupSeverity(module, func);
            if (ext_override) |ext| severity = maxSeverity(severity, ext.severity);
            if (severity == .none) {
                _ = seen.remove(key);
                self.allocator.free(key);
                return null;
            }
            gop.value_ptr.* = .{
                .func = func,
                .module = module,
                .severity = severity,
                .has_failure_path = false,
                .failure_status = 0,
                .flagged = false,
            };
        } else {
            self.allocator.free(key);
            if (ext_override) |ext| {
                gop.value_ptr.severity = maxSeverity(gop.value_ptr.severity, ext.severity);
            }
        }
        return gop.value_ptr;
    }

    fn routedCallSiteId(
        test_case: GeneratedTest,
        call_site: path_gen.NodeIndex,
        fallback_seq: u32,
    ) u64 {
        const local_site: u32 = if (call_site == path_gen.null_node)
            std.math.maxInt(u32) - fallback_seq
        else
            call_site;
        return (@as(u64, test_case.root_function) << 32) | local_site;
    }

    fn checkFailurePath(
        self: *FaultCoverageChecker,
        entry: *CallSiteEntry,
        test_case: GeneratedTest,
        ext_override: ?ExternalSeverity,
    ) !void {
        const status = test_case.expected_status;
        if (status < 200 or status >= 300) return;

        switch (entry.severity) {
            .critical => {
                entry.flagged = true;
                const message = if (ext_override) |ext|
                    ext.reason
                else
                    "handler returns 2xx when auth/validation fails";
                try self.diagnostics.append(self.allocator, .{
                    .severity = .warning,
                    .kind = .success_on_critical_failure,
                    .func_name = entry.func,
                    .module_name = entry.module,
                    .path_name = test_case.name,
                    .status = status,
                    .message = message,
                });
            },
            .upstream => {
                entry.upstream_fallback = true;
                const message = if (ext_override) |ext|
                    ext.reason
                else
                    "handler returns 2xx on upstream failure (graceful degradation?)";
                try self.diagnostics.append(self.allocator, .{
                    .severity = .info,
                    .kind = .success_on_upstream_failure,
                    .func_name = entry.func,
                    .module_name = entry.module,
                    .path_name = test_case.name,
                    .status = status,
                    .message = message,
                });
            },
            .expected, .none => {},
        }
    }

    fn lookupExternalOverride(self: *const FaultCoverageChecker, test_case: GeneratedTest) ?ExternalSeverity {
        const externals = self.external_severities orelse return null;
        if (test_case.route_root) {
            // Route roots do not yet carry the route table's method and path.
            // Any configured route can conservatively reach this function, so
            // use the strictest override. This can report a false positive when
            // one function serves routes with different severities, but it
            // cannot hide a critical failure behind the synthetic GET `/`.
            var strictest: ?ExternalSeverity = null;
            for (externals) |ext| {
                if (strictest == null or
                    severityRank(ext.severity) > severityRank(strictest.?.severity))
                {
                    strictest = ext;
                }
            }
            return strictest;
        }
        for (externals) |ext| {
            if (pathsMatch(ext.path, test_case.url) and
                std.ascii.eqlIgnoreCase(ext.method, test_case.method))
            {
                return ext;
            }
        }
        return null;
    }

    pub fn getReport(self: *const FaultCoverageChecker) FaultCoverageReport {
        var total_failable: u32 = 0;
        var covered: u32 = 0;
        var warning_count: u32 = 0;
        var upstream_fallback_sites: u32 = 0;

        for (self.entries.items) |entry| {
            total_failable += 1;
            if (entry.has_failure_path) covered += 1;
            if (entry.has_failure_path and entry.upstream_fallback) upstream_fallback_sites += 1;
        }
        for (self.diagnostics.items) |diag| {
            if (diag.severity == .warning) warning_count += 1;
        }

        return .{
            .entries = self.entries.items,
            .diagnostics = self.diagnostics.items,
            .total_failable = total_failable,
            .covered = covered,
            .warning_count = warning_count,
            .upstream_fallback_sites = upstream_fallback_sites,
        };
    }

    pub fn formatMatrix(self: *const FaultCoverageChecker, report: FaultCoverageReport, writer: anytype) !void {
        if (report.total_failable == 0) return;

        try writer.writeAll("\nFAULT COVERAGE:\n");

        for (self.entries.items) |entry| {
            try writer.print("  {s:<20}{s:<10}", .{ entry.func, entry.module });

            if (entry.has_failure_path) {
                try writer.print("failure -> {d}", .{entry.failure_status});
                if (!entry.flagged) {
                    if (entry.severity == .expected) {
                        try writer.writeAll("  OK (graceful)");
                    } else {
                        try writer.writeAll("  OK");
                    }
                } else {
                    try writer.writeAll("  WARNING");
                }
            } else {
                try writer.writeAll("no failure path");
            }

            try writer.writeByte('\n');
        }

        try writer.print("\n  Coverage: {d}/{d} failure modes handled\n", .{
            report.covered, report.total_failable,
        });
        try writer.print("  Warnings: {d}\n", .{report.warning_count});
    }

    pub fn formatDiagnostics(self: *const FaultCoverageChecker, writer: anytype) !void {
        for (self.diagnostics.items) |diag| {
            if (diag.severity != .warning) continue;
            try writer.print("fault-coverage {s}: {s}\n", .{ diag.severity.label(), diag.message });
            try writer.print("  function: {s} (zttp:{s})\n", .{ diag.func_name, diag.module_name });
            try writer.print("  path: {s}\n", .{diag.path_name});
            try writer.print("  status: {d}\n\n", .{diag.status});
        }
    }
};

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn lookupSeverity(module_name: []const u8, func_name: []const u8) mb.FailureSeverity {
    for (&builtin_modules.all) |*binding| {
        if (!std.mem.eql(u8, binding.name, module_name) and !std.mem.eql(u8, binding.specifier, module_name)) continue;
        for (binding.exports) |*candidate| {
            if (std.mem.eql(u8, candidate.name, func_name)) {
                return candidate.failure_severity;
            }
        }
    }
    return .none;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const SourceFaultCoverage = struct {
    clean: bool,
    total_failable: u32,
    covered: u32,
    unseen_calls: usize,
    paths_exhaustive: bool,
    upstream_fallback_sites: u32,
    warning_count: u32,
};

fn analyzeSourceFaultCoverage(allocator: std.mem.Allocator, source: []const u8) !SourceFaultCoverage {
    var parser = try parser_mod.JsParser.init(allocator, source);
    defer parser.deinit();
    var atoms = atom_table.AtomTable.init(allocator);
    defer atoms.deinit();
    parser.setAtomTable(&atoms);

    const root = try parser.parse();
    const ir_view = IrView.fromIRStore(&parser.nodes, &parser.constants);
    const handler_fn = handler_verifier.findHandlerFunction(ir_view, root) orelse
        return error.HandlerNotFound;

    var generator = path_gen.PathGenerator.init(allocator, ir_view, &atoms);
    defer generator.deinit();
    try generator.generate(handler_fn);

    var checker = FaultCoverageChecker.init(allocator, generator.getTests());
    defer checker.deinit();
    try checker.analyze();
    const report = checker.getReport();
    return .{
        .clean = report.isClean() and generator.faultAnalysisComplete(),
        .total_failable = report.total_failable,
        .covered = report.covered,
        .unseen_calls = generator.unseenFailableCalls().len,
        .paths_exhaustive = generator.pathsExhaustive(),
        .upstream_fallback_sites = report.upstream_fallback_sites,
        .warning_count = report.warning_count,
    };
}

test "fault coverage checks routerMatch route functions" {
    const direct_violation =
        \\import { jwtVerify } from "zttp:auth";
        \\function handler(req) {
        \\  const auth = jwtVerify("token", "secret");
        \\  if (!auth.ok) return Response.text("accepted");
        \\  return Response.text("ok");
        \\}
    ;
    const routed_violation =
        \\import { jwtVerify } from "zttp:auth";
        \\import { routerMatch } from "zttp:router";
        \\function route(req) {
        \\  const auth = jwtVerify("token", "secret");
        \\  if (!auth.ok) return Response.text("accepted");
        \\  return Response.text("ok");
        \\}
        \\const routes = { "GET /probe": route };
        \\function handler(req) {
        \\  const found = routerMatch(routes, req);
        \\  if (found === undefined) return Response.text("not found", { status: 404 });
        \\  return found.handler(req);
        \\}
    ;
    const clean_routed =
        \\import { jwtVerify } from "zttp:auth";
        \\import { routerMatch } from "zttp:router";
        \\function route(req) {
        \\  const auth = jwtVerify("token", "secret");
        \\  if (!auth.ok) return Response.text("unauthorized", { status: 401 });
        \\  return Response.text("ok");
        \\}
        \\const routes = { "GET /probe": route };
        \\function handler(req) {
        \\  const found = routerMatch(routes, req);
        \\  if (found === undefined) return Response.text("not found", { status: 404 });
        \\  return found.handler(req);
        \\}
    ;

    const direct = try analyzeSourceFaultCoverage(std.testing.allocator, direct_violation);
    const routed = try analyzeSourceFaultCoverage(std.testing.allocator, routed_violation);
    const clean = try analyzeSourceFaultCoverage(std.testing.allocator, clean_routed);

    try std.testing.expect(!direct.clean);
    try std.testing.expect(!routed.clean);
    try std.testing.expect(clean.clean);
    try std.testing.expectEqual(direct.total_failable + 1, routed.total_failable);
    try std.testing.expectEqual(routed.total_failable, clean.total_failable);
}

test "fault coverage fails closed for unresolved routerMatch dispatch" {
    const source =
        \\import { routerMatch } from "zttp:router";
        \\function handler(req) {
        \\  const found = routerMatch(req.routes, req);
        \\  if (found === undefined) return Response.text("not found", { status: 404 });
        \\  return found.handler(req);
        \\}
    ;

    const coverage = try analyzeSourceFaultCoverage(std.testing.allocator, source);
    try std.testing.expect(!coverage.clean);
    try std.testing.expect(!coverage.paths_exhaustive);
}

test "a routed call site cannot borrow fault coverage from the handler" {
    const source =
        \\import { jwtVerify } from "zttp:auth";
        \\import { routerMatch } from "zttp:router";
        \\function route(req) {
        \\  jwtVerify("route-token", "secret");
        \\  return Response.text("ok");
        \\}
        \\const routes = { "GET /probe": route };
        \\function handler(req) {
        \\  const auth = jwtVerify("handler-token", "secret");
        \\  if (!auth.ok) return Response.text("unauthorized", { status: 401 });
        \\  const found = routerMatch(routes, req);
        \\  if (found === undefined) return Response.text("not found", { status: 404 });
        \\  return found.handler(req);
        \\}
    ;

    const coverage = try analyzeSourceFaultCoverage(std.testing.allocator, source);
    try std.testing.expect(!coverage.clean);
    try std.testing.expectEqual(@as(u32, 3), coverage.total_failable);
}

test "fault coverage fails closed when the handler discards a route response" {
    const source =
        \\import { jwtVerify } from "zttp:auth";
        \\import { routerMatch } from "zttp:router";
        \\function route(req) {
        \\  const auth = jwtVerify("token", "secret");
        \\  if (!auth.ok) return Response.text("unauthorized", { status: 401 });
        \\  return Response.text("ok");
        \\}
        \\const routes = { "GET /probe": route };
        \\function handler(req) {
        \\  const found = routerMatch(routes, req);
        \\  if (found === undefined) return Response.text("not found", { status: 404 });
        \\  found.handler(req);
        \\  return Response.text("discarded route response");
        \\}
    ;

    const coverage = try analyzeSourceFaultCoverage(std.testing.allocator, source);
    try std.testing.expect(!coverage.clean);
    try std.testing.expect(!coverage.paths_exhaustive);
}

test "an unbranched handler call is an uncovered site" {
    const source =
        \\import { jwtVerify } from "zttp:auth";
        \\function handler(req) {
        \\  jwtVerify("token", "secret");
        \\  return Response.text("ok");
        \\}
    ;

    const coverage = try analyzeSourceFaultCoverage(std.testing.allocator, source);
    try std.testing.expectEqual(@as(u32, 1), coverage.total_failable);
    try std.testing.expectEqual(@as(u32, 0), coverage.covered);
    try std.testing.expect(!coverage.clean);
}

/// One probe of the handler root: a handler body and the verdict it must get.
/// Every probe holds one checked `jwtVerify` beside a second failable call in
/// one position, so a hidden position is the only difference between a probe
/// and the `one checked call` control.
const FaultProbe = struct {
    name: []const u8,
    source: []const u8,
    clean: bool,
};

const probe_prefix =
    \\import { jwtVerify } from "zttp:auth";
    \\import { env } from "zttp:env";
    \\import { logInfo } from "zttp:log";
    \\function wrap(r) {
    \\  return r;
    \\}
    \\
;

const fault_probes = [_]FaultProbe{
    // Controls: these hold before and after the second call is added.
    .{ .name = "one checked call", .clean = true, .source = probe_prefix ++
        \\function handler(req) {
        \\  const a = jwtVerify("t1", "secret");
        \\  if (!a.ok) return Response.text("unauthorized", { status: 401 });
        \\  return Response.text("ok");
        \\}
    },
    .{ .name = "two calls, both checked", .clean = true, .source = probe_prefix ++
        \\function handler(req) {
        \\  const a = jwtVerify("t1", "secret");
        \\  if (!a.ok) return Response.text("unauthorized", { status: 401 });
        \\  const b = jwtVerify("t2", "secret");
        \\  if (!b.ok) return Response.text("forbidden", { status: 403 });
        \\  return Response.text("ok");
        \\}
    },
    .{ .name = "optional read answered by ??", .clean = true, .source = probe_prefix ++
        \\function handler(req) {
        \\  const a = jwtVerify("t1", "secret");
        \\  if (!a.ok) return Response.text("unauthorized", { status: 401 });
        \\  const name = env("NAME") ?? "anon";
        \\  return Response.text(name);
        \\}
    },
    // Wrong trues today: the second call is real and nothing counts it.
    .{ .name = "second call unchecked (p8)", .clean = false, .source = probe_prefix ++
        \\function handler(req) {
        \\  const a = jwtVerify("t1", "secret");
        \\  const b = jwtVerify("t2", "secret");
        \\  if (!a.ok) return Response.text("unauthorized", { status: 401 });
        \\  return Response.text("ok");
        \\}
    },
    .{ .name = "second call in a nested function (f1)", .clean = false, .source = probe_prefix ++
        \\function handler(req) {
        \\  const a = jwtVerify("t1", "secret");
        \\  if (!a.ok) return Response.text("unauthorized", { status: 401 });
        \\  function check() {
        \\    return jwtVerify("t2", "secret");
        \\  }
        \\  const rows = [check()];
        \\  return Response.json({ rows: rows });
        \\}
    },
    .{ .name = "second call inline (f2)", .clean = false, .source = probe_prefix ++
        \\function handler(req) {
        \\  const a = jwtVerify("t1", "secret");
        \\  if (!a.ok) return Response.text("unauthorized", { status: 401 });
        \\  return Response.text(jwtVerify("t2", "secret").error);
        \\}
    },
    .{ .name = "second call in a helper (f3)", .clean = false, .source = probe_prefix ++
        \\function load() {
        \\  const r = jwtVerify("t2", "secret");
        \\  return r;
        \\}
        \\function handler(req) {
        \\  const a = jwtVerify("t1", "secret");
        \\  if (!a.ok) return Response.text("unauthorized", { status: 401 });
        \\  const b = load();
        \\  return Response.json({ b: b });
        \\}
    },
    .{ .name = "second call as a match scrutinee (f6)", .clean = false, .source = probe_prefix ++
        \\function handler(req) {
        \\  const a = jwtVerify("t1", "secret");
        \\  if (!a.ok) return Response.text("unauthorized", { status: 401 });
        \\  return match (jwtVerify("t2", "secret").ok) {
        \\    when true: Response.text("ok")
        \\    when false: Response.text("forbidden", { status: 403 })
        \\  };
        \\}
    },
    .{ .name = "second call as an argument (f12)", .clean = false, .source = probe_prefix ++
        \\function handler(req) {
        \\  const a = jwtVerify("t1", "secret");
        \\  if (!a.ok) return Response.text("unauthorized", { status: 401 });
        \\  const b = wrap(jwtVerify("t2", "secret"));
        \\  return Response.json({ b: b });
        \\}
    },
    .{ .name = "second call in a branch that does not return (f14)", .clean = false, .source = probe_prefix ++
        \\function handler(req) {
        \\  const a = jwtVerify("t1", "secret");
        \\  if (!a.ok) return Response.text("unauthorized", { status: 401 });
        \\  if (req.method === "POST") {
        \\    const b = jwtVerify("t2", "secret");
        \\    logInfo(b.error, {});
        \\  }
        \\  return Response.text("ok");
        \\}
    },
    .{ .name = "failable export held in a const and called later", .clean = false, .source = probe_prefix ++
        \\function handler(req) {
        \\  const a = jwtVerify("t1", "secret");
        \\  if (!a.ok) return Response.text("unauthorized", { status: 401 });
        \\  const verify = jwtVerify;
        \\  const b = verify("t2", "secret");
        \\  return Response.json({ b: b });
        \\}
    },
    .{ .name = "failable export passed as a callback", .clean = false, .source = probe_prefix ++
        \\function handler(req) {
        \\  const a = jwtVerify("t1", "secret");
        \\  if (!a.ok) return Response.text("unauthorized", { status: 401 });
        \\  const rows = ["t2"].map(jwtVerify);
        \\  return Response.json({ rows: rows });
        \\}
    },
    .{ .name = "checked call in a summarized loop (f7)", .clean = false, .source = probe_prefix ++
        \\function handler(req) {
        \\  for (const i of range(2)) {
        \\    const a = jwtVerify("t1", "secret");
        \\    if (!a.ok) return Response.text("unauthorized", { status: 401 });
        \\  }
        \\  return Response.text("ok");
        \\}
    },
    // Already false today. U1 must not make these true.
    .{ .name = "alias of a checked result (f4)", .clean = false, .source = probe_prefix ++
        \\function handler(req) {
        \\  const r = jwtVerify("t1", "secret");
        \\  const r2 = r;
        \\  if (!r2.ok) return Response.text("unauthorized", { status: 401 });
        \\  return Response.text("ok");
        \\}
    },
    .{ .name = "result never checked (p3)", .clean = false, .source = probe_prefix ++
        \\function handler(req) {
        \\  const a = jwtVerify("t1", "secret");
        \\  return Response.text("ok");
        \\}
    },
};

test "a failable call in a position the walk cannot see blocks fault coverage" {
    // The census must run every probe: a loop that skipped them would pass.
    try std.testing.expectEqual(@as(usize, 15), fault_probes.len);
    var held: usize = 0;
    var blocked: usize = 0;
    var mismatched: usize = 0;
    for (fault_probes) |probe| {
        const coverage = try analyzeSourceFaultCoverage(std.testing.allocator, probe.source);
        if (probe.clean != coverage.clean) {
            std.debug.print("fault probe '{s}': expected clean={}, got clean={}\n", .{ probe.name, probe.clean, coverage.clean });
            mismatched += 1;
        }
        if (probe.clean) held += 1 else blocked += 1;
    }
    try std.testing.expectEqual(@as(usize, 0), mismatched);
    try std.testing.expectEqual(@as(usize, 3), held);
    try std.testing.expectEqual(@as(usize, 12), blocked);
}

test "empty test list produces empty report" {
    const tests: []const GeneratedTest = &.{};
    var checker = FaultCoverageChecker.init(std.testing.allocator, tests);
    defer checker.deinit();
    try checker.analyze();
    const report = checker.getReport();
    try std.testing.expectEqual(@as(u32, 0), report.total_failable);
    try std.testing.expect(!report.isCovered());
}

test "critical failure with 2xx produces warning" {
    const constraints = [_]Constraint{
        .{ .result_not_ok = .{ .module = "auth", .func = "jwtVerify", .returns = .result } },
    };
    const tests = [_]GeneratedTest{
        .{
            .name = "path 1 !result.ok",
            .method = "GET",
            .url = "/",
            .has_auth_header = false,
            .expected_status = 200,
            .io_stubs = .empty,
            .constraints = &constraints,
        },
    };
    var checker = FaultCoverageChecker.init(std.testing.allocator, &tests);
    defer checker.deinit();
    try checker.analyze();
    const report = checker.getReport();
    try std.testing.expectEqual(@as(u32, 1), report.total_failable);
    try std.testing.expectEqual(@as(u32, 1), report.covered);
    try std.testing.expectEqual(@as(u32, 1), report.warning_count);
    try std.testing.expect(report.isCovered());
    try std.testing.expect(!report.isClean());
}

test "critical failure with 403 produces no warning" {
    const constraints = [_]Constraint{
        .{ .result_not_ok = .{ .module = "auth", .func = "jwtVerify", .returns = .result } },
    };
    const tests = [_]GeneratedTest{
        .{
            .name = "path 1 !result.ok",
            .method = "GET",
            .url = "/",
            .has_auth_header = false,
            .expected_status = 403,
            .io_stubs = .empty,
            .constraints = &constraints,
        },
    };
    var checker = FaultCoverageChecker.init(std.testing.allocator, &tests);
    defer checker.deinit();
    try checker.analyze();
    const report = checker.getReport();
    try std.testing.expectEqual(@as(u32, 1), report.total_failable);
    try std.testing.expectEqual(@as(u32, 1), report.covered);
    try std.testing.expectEqual(@as(u32, 0), report.warning_count);
    try std.testing.expect(report.isClean());
}

test "expected failure (cache miss) with 200 produces no warning" {
    const constraints = [_]Constraint{
        .{ .stub_falsy = .{ .module = "cache", .func = "cacheGet", .returns = .optional_string } },
    };
    const tests = [_]GeneratedTest{
        .{
            .name = "path 1 cache miss",
            .method = "GET",
            .url = "/",
            .has_auth_header = false,
            .expected_status = 200,
            .io_stubs = .empty,
            .constraints = &constraints,
        },
    };
    var checker = FaultCoverageChecker.init(std.testing.allocator, &tests);
    defer checker.deinit();
    try checker.analyze();
    const report = checker.getReport();
    try std.testing.expectEqual(@as(u32, 1), report.total_failable);
    try std.testing.expectEqual(@as(u32, 0), report.warning_count);
    try std.testing.expect(report.isClean());
}

test "multiple call sites tracked independently" {
    const constraints_ok = [_]Constraint{
        .{ .result_not_ok = .{ .module = "auth", .func = "jwtVerify", .returns = .result } },
    };
    const constraints_bad = [_]Constraint{
        .{ .result_not_ok = .{ .module = "validate", .func = "validateJson", .returns = .result } },
    };
    const tests = [_]GeneratedTest{
        .{
            .name = "jwt failure",
            .method = "GET",
            .url = "/",
            .has_auth_header = false,
            .expected_status = 403,
            .io_stubs = .empty,
            .constraints = &constraints_ok,
        },
        .{
            .name = "validation failure",
            .method = "POST",
            .url = "/",
            .has_auth_header = false,
            .expected_status = 200,
            .io_stubs = .empty,
            .constraints = &constraints_bad,
        },
    };
    var checker = FaultCoverageChecker.init(std.testing.allocator, &tests);
    defer checker.deinit();
    try checker.analyze();
    const report = checker.getReport();
    try std.testing.expectEqual(@as(u32, 2), report.total_failable);
    try std.testing.expectEqual(@as(u32, 2), report.covered);
    try std.testing.expectEqual(@as(u32, 1), report.warning_count);
}

test "format matrix output" {
    const constraints = [_]Constraint{
        .{ .result_not_ok = .{ .module = "auth", .func = "jwtVerify", .returns = .result } },
    };
    const tests = [_]GeneratedTest{
        .{
            .name = "jwt failure",
            .method = "GET",
            .url = "/",
            .has_auth_header = false,
            .expected_status = 403,
            .io_stubs = .empty,
            .constraints = &constraints,
        },
    };
    var checker = FaultCoverageChecker.init(std.testing.allocator, &tests);
    defer checker.deinit();
    try checker.analyze();
    const report = checker.getReport();

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    var aw: std.Io.Writer.Allocating = .fromArrayList(std.testing.allocator, &buf);
    try checker.formatMatrix(report, &aw.writer);
    buf = aw.toArrayList();
    const output = buf.items;
    try std.testing.expect(std.mem.indexOf(u8, output, "FAULT COVERAGE") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "jwtVerify") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "1/1") != null);
}

// ---------------------------------------------------------------------------
// External severity override tests
// ---------------------------------------------------------------------------

test "parseExternalSeverities with valid JSON" {
    const json =
        \\{
        \\  "callSites": [
        \\    { "path": "/api/orders/:id/approve", "method": "POST", "severity": "critical", "reason": "Governed transition" },
        \\    { "path": "/api/users", "method": "GET", "severity": "none", "reason": "Public endpoint" }
        \\  ]
        \\}
    ;
    const result = try parseExternalSeverities(std.testing.allocator, json);
    defer {
        for (result) |item| {
            std.testing.allocator.free(item.path);
            std.testing.allocator.free(item.method);
            std.testing.allocator.free(item.reason);
        }
        std.testing.allocator.free(result);
    }

    try std.testing.expectEqual(@as(usize, 2), result.len);

    try std.testing.expectEqualStrings("/api/orders/:id/approve", result[0].path);
    try std.testing.expectEqualStrings("POST", result[0].method);
    try std.testing.expectEqual(mb.FailureSeverity.critical, result[0].severity);
    try std.testing.expectEqualStrings("Governed transition", result[0].reason);

    try std.testing.expectEqualStrings("/api/users", result[1].path);
    try std.testing.expectEqual(mb.FailureSeverity.none, result[1].severity);
}

test "severity string mapping" {
    try std.testing.expectEqual(mb.FailureSeverity.critical, mapSeverityString("critical").?);
    try std.testing.expectEqual(mb.FailureSeverity.critical, mapSeverityString("high").?);
    try std.testing.expectEqual(mb.FailureSeverity.expected, mapSeverityString("normal").?);
    try std.testing.expectEqual(mb.FailureSeverity.upstream, mapSeverityString("upstream").?);
    try std.testing.expectEqual(mb.FailureSeverity.none, mapSeverityString("none").?);
    try std.testing.expect(mapSeverityString("invalid") == null);
    try std.testing.expect(mapSeverityString("") == null);
}

test "maxSeverity returns the more severe value" {
    try std.testing.expectEqual(mb.FailureSeverity.critical, maxSeverity(.critical, .expected));
    try std.testing.expectEqual(mb.FailureSeverity.critical, maxSeverity(.expected, .critical));
    try std.testing.expectEqual(mb.FailureSeverity.upstream, maxSeverity(.upstream, .expected));
    try std.testing.expectEqual(mb.FailureSeverity.upstream, maxSeverity(.none, .upstream));
    try std.testing.expectEqual(mb.FailureSeverity.critical, maxSeverity(.critical, .critical));
    try std.testing.expectEqual(mb.FailureSeverity.none, maxSeverity(.none, .none));
}

test "pathsMatch normalizes :id and {id} as equivalent" {
    try std.testing.expect(pathsMatch("/api/orders/:id/approve", "/api/orders/{id}/approve"));
    try std.testing.expect(pathsMatch("/api/orders/{id}/approve", "/api/orders/:id/approve"));
    try std.testing.expect(pathsMatch("/api/orders/:id", "/api/orders/123"));
    try std.testing.expect(pathsMatch("/api/orders/{id}", "/api/orders/123"));
    try std.testing.expect(!pathsMatch("/api/orders", "/api/users"));
    try std.testing.expect(!pathsMatch("/api/orders/:id", "/api/orders/:id/extra"));
    try std.testing.expect(pathsMatch("/", "/"));
}

test "external severity elevates expected to critical" {
    // cacheGet has .expected severity in builtin_modules. An external override
    // on the route marks it as critical. The checker should produce a warning
    // when the handler returns 2xx on the failure path.
    const constraints = [_]Constraint{
        .{ .stub_falsy = .{ .module = "cache", .func = "cacheGet", .returns = .optional_string } },
    };
    const tests = [_]GeneratedTest{
        .{
            .name = "cache miss elevated",
            .method = "POST",
            .url = "/api/orders/:id/approve",
            .has_auth_header = false,
            .expected_status = 200,
            .io_stubs = .empty,
            .constraints = &constraints,
        },
    };
    const ext = [_]ExternalSeverity{
        .{
            .path = "/api/orders/:id/approve",
            .method = "POST",
            .severity = .critical,
            .reason = "Governed transition",
        },
    };
    var checker = FaultCoverageChecker.init(std.testing.allocator, &tests);
    defer checker.deinit();
    checker.setExternalSeverities(&ext);
    try checker.analyze();
    const report = checker.getReport();

    // The entry should exist and be flagged as critical
    try std.testing.expectEqual(@as(u32, 1), report.total_failable);
    try std.testing.expectEqual(@as(u32, 1), report.covered);
    try std.testing.expectEqual(@as(u32, 1), report.warning_count);
    try std.testing.expect(!report.isClean());

    // Diagnostic message should contain the external reason
    try std.testing.expect(report.diagnostics.len > 0);
    try std.testing.expectEqualStrings("Governed transition", report.diagnostics[0].message);
}

test "route roots use the strictest external severity" {
    const allocator = std.testing.allocator;
    const source =
        \\import { cacheGet } from "zttp:cache";
        \\import { routerMatch } from "zttp:router";
        \\function route(req) {
        \\  const value = cacheGet("orders", "current");
        \\  if (value === undefined) return Response.text("accepted");
        \\  return Response.text(value);
        \\}
        \\const routes = { "POST /orders": route };
        \\function handler(req) {
        \\  const found = routerMatch(routes, req);
        \\  if (found === undefined) return Response.text("not found", { status: 404 });
        \\  return found.handler(req);
        \\}
    ;

    var parser = try parser_mod.JsParser.init(allocator, source);
    defer parser.deinit();
    var atoms = atom_table.AtomTable.init(allocator);
    defer atoms.deinit();
    parser.setAtomTable(&atoms);
    const root = try parser.parse();
    const ir_view = IrView.fromIRStore(&parser.nodes, &parser.constants);
    const handler_fn = handler_verifier.findHandlerFunction(ir_view, root) orelse
        return error.HandlerNotFound;

    var generator = path_gen.PathGenerator.init(allocator, ir_view, &atoms);
    defer generator.deinit();
    try generator.generate(handler_fn);

    const overrides = [_]ExternalSeverity{.{
        .path = "/orders",
        .method = "POST",
        .severity = .critical,
        .reason = "order lookup must fail closed",
    }};
    var checker = FaultCoverageChecker.init(allocator, generator.getTests());
    defer checker.deinit();
    checker.setExternalSeverities(&overrides);
    try checker.analyze();

    const report = checker.getReport();
    try std.testing.expect(!report.isClean());
    try std.testing.expect(report.warning_count > 0);
}

test "external severity does not downgrade critical to expected" {
    // jwtVerify is .critical in builtin_modules. An external override of
    // .expected should not lower it - the function-level severity wins.
    const constraints = [_]Constraint{
        .{ .result_not_ok = .{ .module = "auth", .func = "jwtVerify", .returns = .result } },
    };
    const tests = [_]GeneratedTest{
        .{
            .name = "jwt failure not downgraded",
            .method = "GET",
            .url = "/api/public",
            .has_auth_header = false,
            .expected_status = 200,
            .io_stubs = .empty,
            .constraints = &constraints,
        },
    };
    const ext = [_]ExternalSeverity{
        .{
            .path = "/api/public",
            .method = "GET",
            .severity = .expected,
            .reason = "Public endpoint",
        },
    };
    var checker = FaultCoverageChecker.init(std.testing.allocator, &tests);
    defer checker.deinit();
    checker.setExternalSeverities(&ext);
    try checker.analyze();
    const report = checker.getReport();

    // Should still produce a warning because jwtVerify is .critical
    try std.testing.expectEqual(@as(u32, 1), report.warning_count);
    try std.testing.expect(report.diagnostics.len > 0);
    try std.testing.expectEqual(DiagnosticKind.success_on_critical_failure, report.diagnostics[0].kind);
}

test "external severity with {id} matches :id route" {
    const constraints = [_]Constraint{
        .{ .stub_falsy = .{ .module = "cache", .func = "cacheGet", .returns = .optional_string } },
    };
    const tests = [_]GeneratedTest{
        .{
            .name = "cache miss brace id",
            .method = "PUT",
            .url = "/api/items/{id}",
            .has_auth_header = false,
            .expected_status = 200,
            .io_stubs = .empty,
            .constraints = &constraints,
        },
    };
    const ext = [_]ExternalSeverity{
        .{
            .path = "/api/items/:id",
            .method = "PUT",
            .severity = .critical,
            .reason = "Sensitive update",
        },
    };
    var checker = FaultCoverageChecker.init(std.testing.allocator, &tests);
    defer checker.deinit();
    checker.setExternalSeverities(&ext);
    try checker.analyze();
    const report = checker.getReport();

    // External override should match despite :id vs {id} difference
    try std.testing.expectEqual(@as(u32, 1), report.warning_count);
    try std.testing.expectEqualStrings("Sensitive update", report.diagnostics[0].message);
}

test "a handler whose only failable call is unseen is not covered" {
    // One failable call, on no emitted path. The report counts zero sites, so
    // the report alone would say nothing. The verdict must still be false.
    const source =
        \\import { jwtVerify } from "zttp:auth";
        \\function handler(req) {
        \\  return Response.text(jwtVerify("t", "secret").error);
        \\}
    ;

    const coverage = try analyzeSourceFaultCoverage(std.testing.allocator, source);
    try std.testing.expectEqual(@as(u32, 0), coverage.total_failable);
    try std.testing.expectEqual(@as(usize, 1), coverage.unseen_calls);
    try std.testing.expect(!coverage.clean);
}

test "a handler root counts each call to one function as its own site" {
    const source =
        \\import { jwtVerify } from "zttp:auth";
        \\function handler(req) {
        \\  const a = jwtVerify("t1", "secret");
        \\  if (!a.ok) return Response.text("unauthorized", { status: 401 });
        \\  const b = jwtVerify("t2", "secret");
        \\  if (!b.ok) return Response.text("forbidden", { status: 403 });
        \\  return Response.text("ok");
        \\}
    ;

    const coverage = try analyzeSourceFaultCoverage(std.testing.allocator, source);
    try std.testing.expectEqual(@as(u32, 2), coverage.total_failable);
    try std.testing.expectEqual(@as(u32, 2), coverage.covered);
    try std.testing.expect(coverage.clean);
}

test "a ?? fallback on an optional export covers the site without a diagnostic" {
    const source =
        \\import { env } from "zttp:env";
        \\function handler(req) {
        \\  const name = env("NAME") ?? "anon";
        \\  return Response.text(name);
        \\}
    ;

    const coverage = try analyzeSourceFaultCoverage(std.testing.allocator, source);
    try std.testing.expectEqual(@as(u32, 1), coverage.total_failable);
    try std.testing.expectEqual(@as(u32, 1), coverage.covered);
    try std.testing.expect(coverage.clean);
}

test "a ?? fallback does not cover a Result export" {
    // `??` answers an absent value. A Result never is absent, so the fallback
    // is not its failure path.
    const source =
        \\import { jwtVerify } from "zttp:auth";
        \\function handler(req) {
        \\  const a = jwtVerify("t", "secret") ?? "x";
        \\  return Response.text("ok");
        \\}
    ;

    const coverage = try analyzeSourceFaultCoverage(std.testing.allocator, source);
    try std.testing.expectEqual(@as(u32, 1), coverage.total_failable);
    try std.testing.expectEqual(@as(u32, 0), coverage.covered);
    try std.testing.expect(!coverage.clean);
}

const fetch_prefix =
    \\import { fetch } from "zttp:fetch";
    \\import { logInfo } from "zttp:log";
    \\import { routerMatch } from "zttp:router";
    \\function wrap(r) {
    \\  return r;
    \\}
    \\
;

const routed_tail =
    \\function getHealth(req) {
    \\  return Response.json({ healthy: true });
    \\}
    \\const routes = { "GET /data": getData, "GET /health": getHealth };
    \\function handler(req) {
    \\  const found = routerMatch(routes, req);
    \\  if (found === undefined) return Response.text("not found", { status: 404 });
    \\  return found.handler(req);
    \\}
;

/// Fetch probes. The verdict is read from the unfiltered source, so a hidden
/// second `fetch` must make `clean` false through the unseen-call scan, and a
/// handler with every `fetch` checked must be clean.
const fetch_probes = [_]FaultProbe{
    .{ .name = "p1 one fetch, !res.ok returns 502", .clean = true, .source = fetch_prefix ++
        \\function handler(req) {
        \\  const res = fetch("https://api.example.com/data");
        \\  if (!res.ok) return Response.text("upstream failed", { status: 502 });
        \\  return Response.text("ok");
        \\}
    },
    .{ .name = "p2 fetch with an init object", .clean = true, .source = fetch_prefix ++
        \\function handler(req) {
        \\  const res = fetch("https://api.example.com/data", { method: "POST", body: "x" });
        \\  if (!res.ok) return Response.text("upstream failed", { status: 502 });
        \\  return Response.text("ok");
        \\}
    },
    .{ .name = "p3 fetch result never checked", .clean = false, .source = fetch_prefix ++
        \\function handler(req) {
        \\  const res = fetch("https://api.example.com/data");
        \\  return Response.text(res.body);
        \\}
    },
    .{ .name = "p4 two fetches, only the first checked", .clean = false, .source = fetch_prefix ++
        \\function handler(req) {
        \\  const a = fetch("https://api.example.com/a");
        \\  const b = fetch("https://api.example.com/b");
        \\  if (!a.ok) return Response.text("upstream failed", { status: 502 });
        \\  return Response.text(b.body);
        \\}
    },
    .{ .name = "p5 two fetches, both checked", .clean = true, .source = fetch_prefix ++
        \\function handler(req) {
        \\  const a = fetch("https://api.example.com/a");
        \\  if (!a.ok) return Response.text("a failed", { status: 502 });
        \\  const b = fetch("https://api.example.com/b");
        \\  if (!b.ok) return Response.text("b failed", { status: 503 });
        \\  return Response.text("ok");
        \\}
    },
    .{ .name = "p6 !res.ok returns a 2xx fallback", .clean = true, .source = fetch_prefix ++
        \\function handler(req) {
        \\  const res = fetch("https://api.example.com/data");
        \\  if (!res.ok) return Response.text("fallback", { status: 200 });
        \\  return Response.text("ok");
        \\}
    },
    .{ .name = "p7 !== 200 is the complement of ok", .clean = true, .source = fetch_prefix ++
        \\function handler(req) {
        \\  const res = fetch("https://api.example.com/data");
        \\  if (res.status !== 200) return Response.text("upstream failed", { status: 502 });
        \\  return Response.text("ok");
        \\}
    },
    .{ .name = "p7b === 200 with the success branch first", .clean = true, .source = fetch_prefix ++
        \\function handler(req) {
        \\  const res = fetch("https://api.example.com/data");
        \\  if (res.status === 200) return Response.text("ok");
        \\  return Response.text("upstream failed", { status: 502 });
        \\}
    },
    .{ .name = "p7c a literal on the left", .clean = true, .source = fetch_prefix ++
        \\function handler(req) {
        \\  const res = fetch("https://api.example.com/data");
        \\  if (200 !== res.status) return Response.text("upstream failed", { status: 502 });
        \\  return Response.text("ok");
        \\}
    },
    .{ .name = "p7d >= 300 leaves 1xx on the success side", .clean = false, .source = fetch_prefix ++
        \\function handler(req) {
        \\  const res = fetch("https://api.example.com/data");
        \\  if (res.status >= 300) return Response.text("upstream failed", { status: 502 });
        \\  return Response.text("ok");
        \\}
    },
    .{ .name = "p7e >= 400 leaves 3xx on the success side", .clean = false, .source = fetch_prefix ++
        \\function handler(req) {
        \\  const res = fetch("https://api.example.com/data");
        \\  if (res.status >= 400) return Response.text("upstream failed", { status: 502 });
        \\  return Response.text("ok");
        \\}
    },
    .{ .name = "p7f === 404 alone is not a fork", .clean = false, .source = fetch_prefix ++
        \\function handler(req) {
        \\  const res = fetch("https://api.example.com/data");
        \\  if (res.status === 404) return Response.text("missing", { status: 404 });
        \\  return Response.text("ok");
        \\}
    },
    .{ .name = "p7g === 404 then !res.ok", .clean = true, .source = fetch_prefix ++
        \\function handler(req) {
        \\  const res = fetch("https://api.example.com/data");
        \\  if (res.status === 404) return Response.text("missing", { status: 404 });
        \\  if (!res.ok) return Response.text("upstream failed", { status: 502 });
        \\  return Response.text("ok");
        \\}
    },
    .{ .name = "p7h a status read into a const", .clean = false, .source = fetch_prefix ++
        \\function handler(req) {
        \\  const res = fetch("https://api.example.com/data");
        \\  const s = res.status;
        \\  if (s !== 200) return Response.text("upstream failed", { status: 502 });
        \\  return Response.text("ok");
        \\}
    },
    .{ .name = "p7i a shadowed res keeps the outer fork", .clean = true, .source = fetch_prefix ++
        \\function handler(req) {
        \\  const res = fetch("https://api.example.com/data");
        \\  if (req.method === "POST") {
        \\    const res = "shadow";
        \\    return Response.text(res);
        \\  }
        \\  if (res.status !== 200) return Response.text("upstream failed", { status: 502 });
        \\  return Response.text("ok");
        \\}
    },
    .{ .name = "p7j a status test on a Result export", .clean = false, .source = and_prefix ++
        \\function handler(req) {
        \\  const auth = jwtVerify("t", "secret");
        \\  if (auth.status !== 200) return Response.text("unauthorized", { status: 401 });
        \\  return Response.text("ok");
        \\}
    },
    .{ .name = "p9 routed, the route function never checks its fetch", .clean = false, .source = fetch_prefix ++
        \\function getData(req) {
        \\  const res = fetch("https://api.example.com/data");
        \\  return Response.text(res.body);
        \\}
        \\
    ++ routed_tail },
    .{ .name = "p10 routed, the route function checks its fetch", .clean = true, .source = fetch_prefix ++
        \\function getData(req) {
        \\  const res = fetch("https://api.example.com/data");
        \\  if (!res.ok) return Response.text("upstream failed", { status: 502 });
        \\  return Response.text(res.body);
        \\}
        \\
    ++ routed_tail },
    .{ .name = "f1 second fetch in a nested function", .clean = false, .source = fetch_prefix ++
        \\function handler(req) {
        \\  const a = fetch("https://api.example.com/a");
        \\  if (!a.ok) return Response.text("a failed", { status: 502 });
        \\  function load() {
        \\    return fetch("https://api.example.com/b", {});
        \\  }
        \\  const rows = [load()];
        \\  return Response.json({ rows: rows });
        \\}
    },
    .{ .name = "f2 second fetch inline", .clean = false, .source = fetch_prefix ++
        \\function handler(req) {
        \\  const a = fetch("https://api.example.com/a");
        \\  if (!a.ok) return Response.text("a failed", { status: 502 });
        \\  return Response.text(fetch("https://api.example.com/b").body);
        \\}
    },
    .{ .name = "f3 second fetch in a helper", .clean = false, .source = fetch_prefix ++
        \\function load() {
        \\  const r = fetch("https://api.example.com/b");
        \\  return r;
        \\}
        \\function handler(req) {
        \\  const a = fetch("https://api.example.com/a");
        \\  if (!a.ok) return Response.text("a failed", { status: 502 });
        \\  const b = load();
        \\  return Response.json({ b: b });
        \\}
    },
    .{ .name = "f6 second fetch as a match scrutinee", .clean = false, .source = fetch_prefix ++
        \\function handler(req) {
        \\  const a = fetch("https://api.example.com/a");
        \\  if (!a.ok) return Response.text("a failed", { status: 502 });
        \\  return match (fetch("https://api.example.com/b").ok) {
        \\    when true: Response.text("ok")
        \\    when false: Response.text("b failed", { status: 502 })
        \\  };
        \\}
    },
    .{ .name = "f12 second fetch as an argument", .clean = false, .source = fetch_prefix ++
        \\function handler(req) {
        \\  const a = fetch("https://api.example.com/a");
        \\  if (!a.ok) return Response.text("a failed", { status: 502 });
        \\  const b = wrap(fetch("https://api.example.com/b"));
        \\  return Response.json({ b: b });
        \\}
    },
    .{ .name = "f14 second fetch in a branch that does not return", .clean = false, .source = fetch_prefix ++
        \\function handler(req) {
        \\  const a = fetch("https://api.example.com/a");
        \\  if (!a.ok) return Response.text("a failed", { status: 502 });
        \\  if (req.method === "POST") {
        \\    const b = fetch("https://api.example.com/b");
        \\    logInfo(b.body, {});
        \\  }
        \\  return Response.text("ok");
        \\}
    },
    .{ .name = "a fetch held in a const and called later", .clean = false, .source = fetch_prefix ++
        \\function handler(req) {
        \\  const a = fetch("https://api.example.com/a");
        \\  if (!a.ok) return Response.text("a failed", { status: 502 });
        \\  const grab = fetch;
        \\  const b = grab("https://api.example.com/b");
        \\  return Response.json({ b: b });
        \\}
    },
};

test "a hidden or unchecked fetch never makes fault coverage true" {
    // The census must run every probe: a loop that skipped them would pass.
    try std.testing.expectEqual(@as(usize, 25), fetch_probes.len);
    var held: usize = 0;
    var blocked: usize = 0;
    var mismatched: usize = 0;
    for (fetch_probes) |probe| {
        const coverage = analyzeSourceFaultCoverage(std.testing.allocator, probe.source) catch |err| {
            std.debug.print("fetch probe '{s}' did not analyze: {s}\n", .{ probe.name, @errorName(err) });
            return err;
        };
        if (probe.clean != coverage.clean) {
            std.debug.print("fetch probe '{s}': expected clean={}, got clean={} ({d} of {d} sites, {d} unseen)\n", .{
                probe.name,              probe.clean,
                coverage.clean,          coverage.covered,
                coverage.total_failable, coverage.unseen_calls,
            });
            mismatched += 1;
        }
        if (probe.clean) held += 1 else blocked += 1;
    }
    try std.testing.expectEqual(@as(usize, 0), mismatched);
    try std.testing.expectEqual(@as(usize, 10), held);
    try std.testing.expectEqual(@as(usize, 15), blocked);
}

test "a 2xx fallback on an upstream failure is covered and counted" {
    const fallback = try analyzeSourceFaultCoverage(std.testing.allocator, fetch_probes[5].source);
    const refused = try analyzeSourceFaultCoverage(std.testing.allocator, fetch_probes[0].source);
    // p6 answers the failed fetch with a 200. It stays covered and clean, and
    // the report counts it so a reader can see it.
    try std.testing.expect(fallback.clean);
    try std.testing.expectEqual(@as(u32, 1), fallback.upstream_fallback_sites);
    // p1 answers with a 502: no fallback.
    try std.testing.expect(refused.clean);
    try std.testing.expectEqual(@as(u32, 0), refused.upstream_fallback_sites);
}

test "a status test behind an && with an opaque conjunct can answer 2xx" {
    // A failed fetch with a false header test falls through to the 200. The
    // status test forks like `!res.ok`, so the report counts the fallback.
    const source = fetch_prefix ++
        \\function handler(req) {
        \\  const res = fetch("https://api.example.com/data");
        \\  if (res.status !== 200 && req.headers["x"] === "y") {
        \\    return Response.text("upstream failed", { status: 502 });
        \\  }
        \\  return Response.text("ok");
        \\}
    ;
    const coverage = try analyzeSourceFaultCoverage(std.testing.allocator, source);
    try std.testing.expect(coverage.clean);
    try std.testing.expectEqual(@as(u32, 1), coverage.upstream_fallback_sites);
}

test "a critical failure with 2xx is a warning, not an upstream fallback" {
    const constraints = [_]Constraint{
        .{ .result_not_ok = .{ .module = "auth", .func = "jwtVerify", .returns = .result } },
    };
    const tests = [_]GeneratedTest{.{
        .name = "path 1 !result.ok",
        .method = "GET",
        .url = "/",
        .has_auth_header = false,
        .expected_status = 200,
        .io_stubs = .empty,
        .constraints = &constraints,
    }};
    var checker = FaultCoverageChecker.init(std.testing.allocator, &tests);
    defer checker.deinit();
    try checker.analyze();
    const report = checker.getReport();
    try std.testing.expectEqual(@as(u32, 1), report.warning_count);
    try std.testing.expectEqual(@as(u32, 0), report.upstream_fallback_sites);
}

const and_prefix =
    \\import { jwtVerify } from "zttp:auth";
    \\import { fetch } from "zttp:fetch";
    \\
;

test "a failed check behind an && with an opaque conjunct can answer 2xx" {
    // The 401 is reached only when the header test is also true. A request
    // with a bad token and a false header test falls through to the 200.
    const source = and_prefix ++
        \\function handler(req) {
        \\  const auth = jwtVerify("t", "secret");
        \\  if (!auth.ok && req.headers["x"] === "y") {
        \\    return Response.json({ error: "unauthorized" }, { status: 401 });
        \\  }
        \\  return Response.json({ data: "private" });
        \\}
    ;
    const coverage = try analyzeSourceFaultCoverage(std.testing.allocator, source);
    try std.testing.expect(coverage.paths_exhaustive);
    try std.testing.expectEqual(@as(u32, 1), coverage.warning_count);
    try std.testing.expect(!coverage.clean);
}

test "the same hole with the opaque conjunct first also warns" {
    const source = and_prefix ++
        \\function handler(req) {
        \\  const auth = jwtVerify("t", "secret");
        \\  if (req.headers["x"] === "y" && !auth.ok) {
        \\    return Response.json({ error: "unauthorized" }, { status: 401 });
        \\  }
        \\  return Response.json({ data: "private" });
        \\}
    ;
    const coverage = try analyzeSourceFaultCoverage(std.testing.allocator, source);
    try std.testing.expectEqual(@as(u32, 1), coverage.warning_count);
    try std.testing.expect(!coverage.clean);
}

test "a second check inside an && can fail while the first passes" {
    // a passes and b fails: the condition is false and the handler answers 200.
    const source = and_prefix ++
        \\function handler(req) {
        \\  const a = jwtVerify("t1", "secret");
        \\  const b = jwtVerify("t2", "secret");
        \\  if (!a.ok && !b.ok) return Response.text("both failed", { status: 401 });
        \\  return Response.text("ok");
        \\}
    ;
    const coverage = try analyzeSourceFaultCoverage(std.testing.allocator, source);
    try std.testing.expectEqual(@as(u32, 2), coverage.warning_count);
    try std.testing.expect(!coverage.clean);
}

test "an upstream fallback behind an && is counted" {
    const source = and_prefix ++
        \\function handler(req) {
        \\  const res = fetch("https://api.example.com/a");
        \\  if (!res.ok && req.headers["x"] === "y") {
        \\    return Response.json({ error: "upstream" }, { status: 502 });
        \\  }
        \\  return Response.json({ a: res.body });
        \\}
    ;
    const coverage = try analyzeSourceFaultCoverage(std.testing.allocator, source);
    try std.testing.expect(coverage.clean);
    try std.testing.expectEqual(@as(u32, 1), coverage.upstream_fallback_sites);
}

test "an && that guards no failable call leaves a covered handler clean" {
    const source = and_prefix ++
        \\function handler(req) {
        \\  const auth = jwtVerify("t", "secret");
        \\  if (!auth.ok) return Response.json({ error: "unauthorized" }, { status: 401 });
        \\  if (req.headers["x"] === "y" && req.headers["z"] === "w") {
        \\    return Response.json({ error: "bad request" }, { status: 400 });
        \\  }
        \\  return Response.json({ data: "private" });
        \\}
    ;
    const coverage = try analyzeSourceFaultCoverage(std.testing.allocator, source);
    try std.testing.expect(coverage.clean);
    try std.testing.expectEqual(@as(u32, 1), coverage.total_failable);
    try std.testing.expectEqual(@as(u32, 1), coverage.covered);
    try std.testing.expectEqual(@as(u32, 0), coverage.warning_count);
}

test "a check behind || or a negated && gives no failure path and blocks the property" {
    // Neither form yields a constraint, so no path holds the failed check.
    // That under-claims coverage and never claims it falsely.
    const or_source = and_prefix ++
        \\function handler(req) {
        \\  const auth = jwtVerify("t", "secret");
        \\  if (!auth.ok || req.headers["x"] === "y") {
        \\    return Response.json({ error: "unauthorized" }, { status: 401 });
        \\  }
        \\  return Response.json({ data: "private" });
        \\}
    ;
    const negated_source = and_prefix ++
        \\function handler(req) {
        \\  const auth = jwtVerify("t", "secret");
        \\  if (!(auth.ok && req.headers["x"] === "y")) {
        \\    return Response.json({ error: "unauthorized" }, { status: 401 });
        \\  }
        \\  return Response.json({ data: "private" });
        \\}
    ;
    for ([_][]const u8{ or_source, negated_source }) |source| {
        const coverage = try analyzeSourceFaultCoverage(std.testing.allocator, source);
        try std.testing.expectEqual(@as(u32, 0), coverage.covered);
        try std.testing.expect(!coverage.clean);
    }
}

test "a failable call used as an if condition is walked, so the guard is covered" {
    const webhook =
        \\import { verifyWebhookSignature } from "zttp:auth";
        \\function handler(req) {
        \\  if (!verifyWebhookSignature(req.body, "secret", "sig")) {
        \\    return Response.text("bad signature", { status: 401 });
        \\  }
        \\  return Response.text("ok");
        \\}
    ;
    const cache_set =
        \\import { cacheSet } from "zttp:cache";
        \\function handler(req) {
        \\  if (!cacheSet("ns", "key", "value")) {
        \\    return Response.text("cache write failed", { status: 503 });
        \\  }
        \\  return Response.text("ok");
        \\}
    ;

    for ([_][]const u8{ webhook, cache_set }) |source| {
        const coverage = try analyzeSourceFaultCoverage(std.testing.allocator, source);
        try std.testing.expectEqual(@as(usize, 0), coverage.unseen_calls);
        try std.testing.expectEqual(@as(u32, 1), coverage.total_failable);
        try std.testing.expectEqual(@as(u32, 1), coverage.covered);
        try std.testing.expect(coverage.paths_exhaustive);
        try std.testing.expect(coverage.clean);
    }
}

test "a failable call that a conjunct condition tests is walked" {
    // Observed: each conjunct that tests the call gives it a stub constraint on
    // some path, so the checker counts it and the scan no longer lists it. This
    // holds for the call as the first conjunct and as a later one.
    const first =
        \\import { verifyWebhookSignature } from "zttp:auth";
        \\function handler(req) {
        \\  if (verifyWebhookSignature(req.body, "secret", "sig") && req.method === "POST") {
        \\    return Response.text("ok");
        \\  }
        \\  return Response.text("rejected", { status: 401 });
        \\}
    ;
    const later =
        \\import { verifyWebhookSignature } from "zttp:auth";
        \\function handler(req) {
        \\  if (req.method === "POST" && verifyWebhookSignature(req.body, "secret", "sig")) {
        \\    return Response.text("ok");
        \\  }
        \\  return Response.text("rejected", { status: 401 });
        \\}
    ;
    for ([_][]const u8{ first, later }) |source| {
        const coverage = try analyzeSourceFaultCoverage(std.testing.allocator, source);
        try std.testing.expectEqual(@as(usize, 0), coverage.unseen_calls);
        try std.testing.expectEqual(coverage.total_failable, coverage.covered);
    }
}

test "a failable call under an or in an if condition has no constraint and stays unseen" {
    // Observed: `||` yields no path constraint, so no path tests the call. It is
    // on no path and stays listed as unseen, and the handler is not clean.
    const source =
        \\import { verifyWebhookSignature } from "zttp:auth";
        \\function handler(req) {
        \\  if (req.method === "POST" || verifyWebhookSignature(req.body, "secret", "sig")) {
        \\    return Response.text("ok");
        \\  }
        \\  return Response.text("rejected", { status: 401 });
        \\}
    ;
    const coverage = try analyzeSourceFaultCoverage(std.testing.allocator, source);
    try std.testing.expectEqual(@as(usize, 1), coverage.unseen_calls);
    try std.testing.expect(!coverage.clean);
}
