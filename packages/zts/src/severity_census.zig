//! The failure-severity census gate (fault-coverage plan R3, unit U0, K2).
//!
//! Fault coverage has three declarations that nothing ties together: the
//! export's `failure_severity`, the return kind the path generator can fork
//! on, and the stub that drives the fork to its failure. A drift in any one of
//! them is silent. An export can declare a severity and have no fork, so its
//! failure is never a path. An export can have a fork and declare no severity,
//! so the generator forks on a failure that coverage then drops. This census
//! runs the real path generator and the real fault checker over one generated
//! probe handler per export, and reads the verdicts in both directions.
//!
//! Direction A (`severity_probe`): every export with a `failure_severity` other
//! than `.none` gets a probe that calls it and branches on its failure shape
//! (`!r.ok` for a Result, `r === undefined` for an optional, `!r` for a
//! boolean, and `!r.ok` again for an export whose declared signature is an
//! `ok: boolean` record, which is `fetch` and `fetchWithRetry`). The verdict is
//! `ok` when the generator emitted a failure constraint for that call, the stub
//! on that path has the failing shape, and the fault checker counts the call as
//! one covered site. Otherwise the verdict names the first link that broke:
//! `no_fork`, `stub_not_failing`, or `not_counted`.
//!
//! Direction B (`reverse_probe`): every export whose declared return the
//! generator can fork on (`.result`, `.optional_*`, `.boolean`) and whose
//! severity is `.none`. The generator forks on such a call and the checker
//! drops it. The verdict is `fork_without_severity`. A declared forkable return
//! that the generator does not fork on is `declared_forkable_no_fork`.
//!
//! Sentinel rows (`sentinel_probe`): exports the audit found to fail with a
//! plain `undefined` that their declared return does not name. The probe
//! compares the result to `undefined`. The generator forks on that only for an
//! optional return, so each such row is `no_fork` today.
//!
//! Every verdict other than `ok` is a finding. Today's findings are the
//! starting state, so each is carried by one row of `allowed_rows` below, with
//! a mechanism tag from a closed set and a reason. A finding with no row fails
//! the gate, and a row whose finding is gone is stale and fails it too. A fork
//! rule, a stub, or a severity that drifts therefore shows up as a changed
//! count or a missing row, never as a silent pass.
//!
//! The counts per verdict are printed on every run, and a committed floor sits
//! under each. A census whose registry lost its exports would report no
//! findings and check nothing, so the floors come first.

const std = @import("std");
const mb = @import("zts-engine").module_binding;
const builtin_modules = @import("zts-engine").builtin_modules;
const atom_table = @import("zts-engine").atom_table;
const parser_mod = @import("zts-engine").parser;
const path_gen = @import("path_generator.zig");
const handler_verifier = @import("handler_verifier.zig");
const fault_coverage = @import("fault_coverage.zig");

const IrView = parser_mod.IrView;

pub const ProbeKind = enum { severity_probe, reverse_probe, sentinel_probe };

/// The shape of the failure test the probe handler writes.
pub const Shape = enum {
    /// `const r = f("a"); if (!r.ok) return 502;`
    result_ok,
    /// The same test on an export whose declared signature returns a record
    /// with an `ok: boolean` field (`fetch`). The stub that fails it is a
    /// response with a failing `status`, not a Result.
    ok_record,
    /// `const r = f("a"); if (r === undefined) return 502;` on an optional.
    optional_absent,
    /// `const r = f("a"); if (!r) return 502;`
    boolean_falsy,
    /// `const r = f("a"); if (r === undefined) return 502;` on a return kind
    /// that does not name `undefined`.
    undefined_sentinel,
};

pub const Verdict = enum {
    ok,
    no_fork,
    stub_not_failing,
    not_counted,
    fork_without_severity,
    declared_forkable_no_fork,
    probe_error,
};

/// What one probe handler showed.
pub const Observation = struct {
    /// The probe parsed and the path generator ran.
    ran: bool,
    /// The generator emitted a failure constraint for the probed call.
    fork: bool,
    /// The stub the generator wrote on that path has the failing shape.
    stub_fails: bool,
    /// The fault checker counts the call as one covered site, with the
    /// severity the export declares.
    counted: bool,
};

pub fn shapeFor(returns: mb.ReturnKind) Shape {
    return switch (returns) {
        .result => .result_ok,
        .optional_string, .optional_object, .optional_number => .optional_absent,
        .boolean => .boolean_falsy,
        .number, .string, .object, .undefined, .unknown, .dict, .bytes => .undefined_sentinel,
    };
}

/// The probe shape of one export. An export that declares a failure severity and
/// whose declared signature spells an `ok: boolean` field is probed as an
/// `ok_record`. The test reads the declared text on purpose: it is the census's
/// own oracle, so a generator rule that stops recognizing the record shows up
/// as a `no_fork` finding instead of moving the probe with it. A `Result`
/// export (`ledger.post`) also spells `ok: boolean`, and forks through its
/// return kind, so it keeps the `result_ok` probe and its Result stub.
pub fn shapeForExport(func: *const mb.FunctionBinding) Shape {
    if (func.returns != .result and func.failure_severity != .none and declaresOkField(func)) return .ok_record;
    return shapeFor(func.returns);
}

fn declaresOkField(func: *const mb.FunctionBinding) bool {
    const sig = func.signature orelse return false;
    return std.mem.indexOf(u8, sig.returns, "ok: boolean") != null;
}

/// A declared return the path generator has a fork rule for. This reads the
/// return kind only: an `ok`-record export declares `.object`, so a severity
/// of `.none` leaves it out of the reverse direction, and a probe row for it
/// exists only through its declared severity.
pub fn isForkableReturn(returns: mb.ReturnKind) bool {
    return switch (shapeFor(returns)) {
        .result_ok, .optional_absent, .boolean_falsy => true,
        .undefined_sentinel => false,
        // No return kind maps to an `ok_record` probe: `shapeFor` never yields it.
        .ok_record => false,
    };
}

/// Direction A. The first broken link names the verdict.
pub fn classifySeverityProbe(obs: Observation) Verdict {
    if (!obs.ran) return .probe_error;
    if (!obs.fork) return .no_fork;
    if (!obs.stub_fails) return .stub_not_failing;
    if (!obs.counted) return .not_counted;
    return .ok;
}

/// Direction B, for an export with `.none` severity and a forkable return.
pub fn classifyReverseProbe(obs: Observation) Verdict {
    if (!obs.ran) return .probe_error;
    if (!obs.fork) return .declared_forkable_no_fork;
    return .fork_without_severity;
}

/// A sentinel probe asks whether the generator forks on `=== undefined`. A
/// fork there is a finding gone, which makes the row stale.
pub fn classifySentinelProbe(obs: Observation) Verdict {
    if (!obs.ran) return .probe_error;
    if (!obs.fork) return .no_fork;
    if (!obs.stub_fails) return .stub_not_failing;
    return .ok;
}

/// A call the audit found to fail with a plain `undefined`. The declared
/// return does not name it, so the generator has nothing to fork on.
pub const SentinelExport = struct { module: []const u8, func: []const u8 };

/// `parseIso` is not listed: it declares a severity, so its `severity_probe` row
/// already asks the same question.
pub const sentinel_exports = [_]SentinelExport{
    .{ .module = "ratelimit", .func = "rateCheck" },
    .{ .module = "cache", .func = "cacheIncr" },
    .{ .module = "http", .func = "setCookie" },
    .{ .module = "crypto", .func = "base64Decode" },
};

/// The plan units or decisions that own a finding. A row names exactly one.
pub const Mechanism = enum {
    /// A fork for `=== undefined` on a return that does not declare it.
    sentinel_fork,
    /// A severity decision: the failure is a fault, or it is not, and the
    /// audit labels the call as inferred.
    severity_decision,
    /// The false or absent answer is the export's answer, not a failure.
    answer_not_failure,
    /// A pure total function over data. Its Result is a value, not I/O.
    pure_data,
    /// A constructor or propagator of a Result. It performs no I/O.
    result_plumbing,
};

pub const AllowedRow = struct {
    /// `module.func#probe_kind`.
    key: []const u8,
    verdict: Verdict,
    mechanism: Mechanism,
    reason: []const u8,
};

const allowed_rows = [_]AllowedRow{
    // Undefined failures with no fork. Follow-up: a fork on `=== undefined`
    // for a return whose declaration does not name it, or a declared optional.
    .{
        .key = "time.parseIso#severity_probe",
        .verdict = .no_fork,
        .mechanism = .sentinel_fork,
        .reason = "declares `expected`, but its failure is `undefined` from a plain `number` (time.zig:93-96); the generator forks `=== undefined` only on an optional return, so the failure is never a path",
    },
    .{
        .key = "ratelimit.rateCheck#sentinel_probe",
        .verdict = .no_fork,
        .mechanism = .sentinel_fork,
        .reason = "its Result failures fork (the severity_probe row is ok); bad arguments, a non-finite window, and clock, store, or allocation errors return plain `undefined` (ratelimit.zig:210-224), which no fork represents",
    },
    .{
        .key = "cache.cacheIncr#sentinel_probe",
        .verdict = .no_fork,
        .mechanism = .sentinel_fork,
        .reason = "returns `undefined` on bad arguments, overflow, and capacity (cache.zig:422-446) while declaring a plain `number`; it declares no severity either",
    },
    .{
        .key = "http.setCookie#sentinel_probe",
        .verdict = .no_fork,
        .mechanism = .sentinel_fork,
        .reason = "returns `undefined` on an invalid cookie name, header-injection characters, or a bad SameSite (http_mod.zig:66-124) while declaring a plain `string`; it declares no severity either",
    },
    .{
        .key = "crypto.base64Decode#sentinel_probe",
        .verdict = .no_fork,
        .mechanism = .sentinel_fork,
        .reason = "returns `undefined` on invalid base64 (crypto.zig:120-130) while declaring a plain `string`; it declares no severity either",
    },

    // A fork with no severity, where the failure may be a fault. Follow-up:
    // the severity audit (R3 section 2.3); each call needs a decision.
    .{
        .key = "auth.verifyWebhookSignature#reverse_probe",
        .verdict = .fork_without_severity,
        .mechanism = .severity_decision,
        .reason = "false means a bad signature or a length mismatch (auth.zig:437-451), a security decision",
    },
    .{
        .key = "validate.schemaCompile#reverse_probe",
        .verdict = .fork_without_severity,
        .mechanism = .severity_decision,
        .reason = "false on bad JSON, a bad schema, or a full registry (validate.zig:156-185)",
    },
    .{
        .key = "cache.cacheSet#reverse_probe",
        .verdict = .fork_without_severity,
        .mechanism = .severity_decision,
        .reason = "false on capacity exceeded, bad arguments, or a clock error (cache.zig:397-409); the builtin_modules.zig severity test pins `.none` and names this row",
    },
    .{
        .key = "durable.signal#reverse_probe",
        .verdict = .fork_without_severity,
        .mechanism = .severity_decision,
        .reason = "false when the target durable run does not exist (durable_executor.zig:436-452)",
    },
    .{
        .key = "durable.signalAt#reverse_probe",
        .verdict = .fork_without_severity,
        .mechanism = .severity_decision,
        .reason = "false when the target durable run does not exist (durable_executor.zig:436-466)",
    },
    .{
        .key = "tool.callTool#reverse_probe",
        .verdict = .fork_without_severity,
        .mechanism = .severity_decision,
        .reason = "returns a Result and `.ok` forks; only the severity is missing, and tool.zig:200 pins `.none`",
    },
    .{
        .key = "io.race#reverse_probe",
        .verdict = .fork_without_severity,
        .mechanism = .severity_decision,
        .reason = "answers the first thunk's 599 Response when none succeeds, and `undefined` when no thunk fetched (io.zig:337,369); it is an orchestration call that needs its own fork",
    },

    // A fork with no severity, where the answer is the export's answer.
    .{
        .key = "auth.timingSafeEqual#reverse_probe",
        .verdict = .fork_without_severity,
        .mechanism = .answer_not_failure,
        .reason = "false means the values differ; a mismatch is the answer (auth.zig:453-457)",
    },
    .{
        .key = "validate.schemaDrop#reverse_probe",
        .verdict = .fork_without_severity,
        .mechanism = .answer_not_failure,
        .reason = "false means the schema was absent (validate.zig:240-249)",
    },
    .{
        .key = "cache.cacheDelete#reverse_probe",
        .verdict = .fork_without_severity,
        .mechanism = .answer_not_failure,
        .reason = "false means the key was absent (cache.zig:412-419)",
    },
    .{
        .key = "collections.dictHas#reverse_probe",
        .verdict = .fork_without_severity,
        .mechanism = .answer_not_failure,
        .reason = "a membership answer",
    },
    .{
        .key = "ratelimit.rateReset#reverse_probe",
        .verdict = .fork_without_severity,
        .mechanism = .answer_not_failure,
        .reason = "false means the key was absent",
    },
    .{
        .key = "sql.sql#reverse_probe",
        .verdict = .fork_without_severity,
        .mechanism = .answer_not_failure,
        .reason = "returns true or throws (sql.zig:211-225); the runtime turns a throw into a 500, and the boolean never reports a failure",
    },

    // A fork with no severity, on a pure total function over data.
    .{
        .key = "collections.dictFromEntries#reverse_probe",
        .verdict = .fork_without_severity,
        .mechanism = .pure_data,
        .reason = "a Result for duplicate or malformed entries (collections.zig:138-167); pure, no I/O",
    },
    .{
        .key = "bytes.bytesFromOctets#reverse_probe",
        .verdict = .fork_without_severity,
        .mechanism = .pure_data,
        .reason = "a Result over data; pure, no I/O",
    },
    .{
        .key = "bytes.byteAt#reverse_probe",
        .verdict = .fork_without_severity,
        .mechanism = .pure_data,
        .reason = "`undefined` out of range (bytes_mod.zig:218-221); pure, no I/O",
    },
    .{
        .key = "bytes.sliceBytes#reverse_probe",
        .verdict = .fork_without_severity,
        .mechanism = .pure_data,
        .reason = "a Result over data; pure, no I/O",
    },
    .{
        .key = "bytes.concatBytes#reverse_probe",
        .verdict = .fork_without_severity,
        .mechanism = .pure_data,
        .reason = "a Result over data; pure, no I/O",
    },
    .{
        .key = "bytes.decodeUtf8#reverse_probe",
        .verdict = .fork_without_severity,
        .mechanism = .pure_data,
        .reason = "a Result for invalid encoding; pure, no I/O",
    },
    .{
        .key = "bytes.decodeBase64#reverse_probe",
        .verdict = .fork_without_severity,
        .mechanism = .pure_data,
        .reason = "a Result over data; pure, no I/O",
    },
    .{
        .key = "json.parseJson#reverse_probe",
        .verdict = .fork_without_severity,
        .mechanism = .pure_data,
        .reason = "a Result with a kind and offset taxonomy (json_mod.zig:390-420); pure, no I/O",
    },
    .{
        .key = "json.parseJsonBytes#reverse_probe",
        .verdict = .fork_without_severity,
        .mechanism = .pure_data,
        .reason = "a Result with a kind and offset taxonomy; pure, no I/O",
    },
    .{
        .key = "json.stringifyJson#reverse_probe",
        .verdict = .fork_without_severity,
        .mechanism = .pure_data,
        .reason = "a Result for unencodable, cyclic, or non-finite values (json_mod.zig:455-470); pure, no I/O",
    },
    .{
        .key = "result.collectAll#reverse_probe",
        .verdict = .fork_without_severity,
        .mechanism = .pure_data,
        .reason = "a Result for a non-array or the first error (result_mod.zig:135-144); pure, no I/O",
    },

    // A fork with no severity, on a Result constructor or propagator.
    .{
        .key = "result.ok#reverse_probe",
        .verdict = .fork_without_severity,
        .mechanism = .result_plumbing,
        .reason = "builds a Result; it performs no I/O",
    },
    .{
        .key = "result.err#reverse_probe",
        .verdict = .fork_without_severity,
        .mechanism = .result_plumbing,
        .reason = "builds a Result; it performs no I/O",
    },
    .{
        .key = "result.mapResult#reverse_probe",
        .verdict = .fork_without_severity,
        .mechanism = .result_plumbing,
        .reason = "propagates the input Result; it performs no I/O",
    },
    .{
        .key = "result.mapError#reverse_probe",
        .verdict = .fork_without_severity,
        .mechanism = .result_plumbing,
        .reason = "propagates the input Result; it performs no I/O",
    },
    .{
        .key = "result.andThen#reverse_probe",
        .verdict = .fork_without_severity,
        .mechanism = .result_plumbing,
        .reason = "propagates the input Result; it performs no I/O",
    },
    .{
        .key = "result.orElse#reverse_probe",
        .verdict = .fork_without_severity,
        .mechanism = .result_plumbing,
        .reason = "propagates the input Result; it performs no I/O",
    },
};

pub const FailureKind = enum {
    below_floor,
    verdict_below_floor,
    probe_error,
    unlisted_finding,
    wrong_verdict_row,
    stale_row,
    duplicate_row,
    empty_reason,
};

pub const Failure = struct {
    kind: FailureKind,
    key: []const u8,
};

pub const Row = struct {
    key: []const u8,
    kind: ProbeKind,
    verdict: Verdict,
};

pub const Floors = struct {
    /// Rows in total.
    total: usize,
    /// Rows from exports that declare a severity. Each is probed for a fork.
    severity_rows: usize,
    /// Rows from exports that declare a severity or that have a forkable
    /// return with no severity. A severity given to a forkable export moves a
    /// row between the two kinds and leaves this sum alone.
    forkable_rows: usize,
    /// Rows from the audit's undefined-sentinel exports.
    sentinel_rows: usize,
    /// Rows whose verdict is `ok`.
    ok_rows: usize,
};

/// The committed floors. A change to the registry that moves a row between
/// verdicts edits `allowed_rows`; one that adds or drops an export edits these.
const floors = Floors{
    .total = 64,
    .severity_rows = 30,
    .forkable_rows = 60,
    .sentinel_rows = 4,
    .ok_rows = 29,
};

// ---------------------------------------------------------------------------
// Probe sources
// ---------------------------------------------------------------------------

fn probeSource(
    allocator: std.mem.Allocator,
    specifier: []const u8,
    func: []const u8,
    shape: Shape,
) ![]u8 {
    const test_line: []const u8 = switch (shape) {
        .result_ok, .ok_record => "if (!r.ok) return Response.text(\"failed\", { status: 502 });",
        .optional_absent, .undefined_sentinel => "if (r === undefined) return Response.text(\"failed\", { status: 502 });",
        .boolean_falsy => "if (!r) return Response.text(\"failed\", { status: 502 });",
    };
    return std.fmt.allocPrint(
        allocator,
        "import {{ {s} }} from \"{s}\";\nfunction handler(req) {{\n  const r = {s}(\"a\");\n  {s}\n  return Response.text(\"ok\");\n}}\n",
        .{ func, specifier, func, test_line },
    );
}

/// Whether the stub has the shape that fails the probed call. An `ok_record` stub
/// must be a response the replay reads as a failure: an integer `status` of 400
/// or more, beside the `statusText`, `headers`, and `body` the replay reads. The
/// replay derives `ok` from `status` and ignores a field named `ok`.
fn failingStubShape(shape: Shape, returns: mb.ReturnKind, json: []const u8) bool {
    if (shape == .ok_record) return failingResponseStub(json);
    return switch (returns) {
        .result => std.mem.indexOf(u8, json, "\"ok\":false") != null,
        .optional_string, .optional_object, .optional_number => std.mem.eql(u8, json, "null"),
        .boolean => std.mem.eql(u8, json, "false"),
        .number, .string, .object, .undefined, .unknown, .dict, .bytes => false,
    };
}

fn failingResponseStub(json: []const u8) bool {
    var parsed = std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, json, .{}) catch return false;
    defer parsed.deinit();
    if (parsed.value != .object) return false;
    const fields = parsed.value.object;
    const status = fields.get("status") orelse return false;
    if (status != .integer or status.integer < 400 or status.integer > 599) return false;
    if (fields.get("statusText") == null or fields.get("headers") == null or fields.get("body") == null) return false;
    // A Result-shaped stub carries `ok`; the replay would ignore it.
    return fields.get("ok") == null;
}

/// Run the real path generator and fault checker over one probe handler.
fn observe(
    allocator: std.mem.Allocator,
    source: []const u8,
    module: []const u8,
    func: []const u8,
    shape: Shape,
    returns: mb.ReturnKind,
    severity: mb.FailureSeverity,
) !Observation {
    var observed = Observation{ .ran = false, .fork = false, .stub_fails = false, .counted = false };

    var parser = parser_mod.JsParser.init(allocator, source) catch return observed;
    defer parser.deinit();
    var atoms = atom_table.AtomTable.init(allocator);
    defer atoms.deinit();
    parser.setAtomTable(&atoms);

    const root = parser.parse() catch return observed;
    const ir_view = IrView.fromIRStore(&parser.nodes, &parser.constants);
    const handler_fn = handler_verifier.findHandlerFunction(ir_view, root) orelse return observed;

    var generator = path_gen.PathGenerator.init(allocator, ir_view, &atoms);
    defer generator.deinit();
    generator.generate(handler_fn) catch return observed;
    observed.ran = true;

    for (generator.getTests()) |test_case| {
        for (test_case.constraints) |constraint| {
            if (!constraint.isFailure()) continue;
            const info = switch (constraint) {
                .stub_falsy, .result_not_ok => |stub| stub,
                else => continue,
            };
            if (!std.mem.eql(u8, info.module, module) or !std.mem.eql(u8, info.func, func)) continue;
            observed.fork = true;
            for (test_case.io_stubs.items) |stub| {
                if (stub.call_site != info.call_site) continue;
                if (failingStubShape(shape, returns, stub.result_json)) observed.stub_fails = true;
            }
        }
    }

    var checker = fault_coverage.FaultCoverageChecker.init(allocator, generator.getTests());
    defer checker.deinit();
    try checker.analyze();
    const report = checker.getReport();
    if (report.total_failable == 1 and report.covered == 1 and report.entries.len == 1) {
        observed.counted = report.entries[0].severity == severity;
    }
    return observed;
}

// ---------------------------------------------------------------------------
// The census
// ---------------------------------------------------------------------------

fn appendKey(
    allocator: std.mem.Allocator,
    module: []const u8,
    func: []const u8,
    kind: ProbeKind,
) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}.{s}#{s}", .{ module, func, @tagName(kind) });
}

/// Probe every export in the registry. The caller owns the rows and their keys.
pub fn collectRows(allocator: std.mem.Allocator) !std.ArrayList(Row) {
    var rows: std.ArrayList(Row) = .empty;
    errdefer freeRows(allocator, &rows);

    for (&builtin_modules.all) |*binding| {
        for (binding.exports) |*export_fn| {
            const returns = export_fn.returns;
            const severity = export_fn.failure_severity;
            const shape = shapeForExport(export_fn);

            const source = try probeSource(allocator, binding.specifier, export_fn.name, shape);
            defer allocator.free(source);
            const obs = try observe(allocator, source, binding.name, export_fn.name, shape, returns, severity);

            if (severity != .none) {
                const key = try appendKey(allocator, binding.name, export_fn.name, .severity_probe);
                errdefer allocator.free(key);
                try rows.append(allocator, .{ .key = key, .kind = .severity_probe, .verdict = classifySeverityProbe(obs) });
            } else if (isForkableReturn(returns)) {
                const key = try appendKey(allocator, binding.name, export_fn.name, .reverse_probe);
                errdefer allocator.free(key);
                try rows.append(allocator, .{ .key = key, .kind = .reverse_probe, .verdict = classifyReverseProbe(obs) });
            }
        }
    }

    for (sentinel_exports) |sentinel| {
        const found = findExport(sentinel.module, sentinel.func) orelse {
            const key = try appendKey(allocator, sentinel.module, sentinel.func, .sentinel_probe);
            errdefer allocator.free(key);
            try rows.append(allocator, .{ .key = key, .kind = .sentinel_probe, .verdict = .probe_error });
            continue;
        };
        const source = try probeSource(allocator, found.specifier, sentinel.func, .undefined_sentinel);
        defer allocator.free(source);
        const obs = try observe(allocator, source, sentinel.module, sentinel.func, .undefined_sentinel, found.returns, found.severity);
        const key = try appendKey(allocator, sentinel.module, sentinel.func, .sentinel_probe);
        errdefer allocator.free(key);
        try rows.append(allocator, .{ .key = key, .kind = .sentinel_probe, .verdict = classifySentinelProbe(obs) });
    }

    return rows;
}

const FoundExport = struct {
    specifier: []const u8,
    returns: mb.ReturnKind,
    severity: mb.FailureSeverity,
    shape: Shape,
};

fn findExport(module: []const u8, func: []const u8) ?FoundExport {
    for (&builtin_modules.all) |*binding| {
        if (!std.mem.eql(u8, binding.name, module)) continue;
        for (binding.exports) |*export_fn| {
            if (std.mem.eql(u8, export_fn.name, func)) {
                return .{
                    .specifier = binding.specifier,
                    .returns = export_fn.returns,
                    .severity = export_fn.failure_severity,
                    .shape = shapeForExport(export_fn),
                };
            }
        }
    }
    return null;
}

pub fn freeRows(allocator: std.mem.Allocator, rows: *std.ArrayList(Row)) void {
    for (rows.items) |row| allocator.free(row.key);
    rows.deinit(allocator);
}

fn countKind(rows: []const Row, kind: ProbeKind) usize {
    var n: usize = 0;
    for (rows) |row| {
        if (row.kind == kind) n += 1;
    }
    return n;
}

fn countVerdict(rows: []const Row, verdict: Verdict) usize {
    var n: usize = 0;
    for (rows) |row| {
        if (row.verdict == verdict) n += 1;
    }
    return n;
}

/// Compare the observed rows with the allowed rows and the floors. Returns the
/// failures; the caller owns the list.
pub fn check(
    allocator: std.mem.Allocator,
    rows: []const Row,
    allowed: []const AllowedRow,
    committed: Floors,
) !std.ArrayList(Failure) {
    var failures: std.ArrayList(Failure) = .empty;
    errdefer failures.deinit(allocator);

    if (rows.len < committed.total) {
        try failures.append(allocator, .{ .kind = .below_floor, .key = "total" });
    }
    if (countKind(rows, .severity_probe) < committed.severity_rows) {
        try failures.append(allocator, .{ .kind = .below_floor, .key = "severity_rows" });
    }
    if (countKind(rows, .severity_probe) + countKind(rows, .reverse_probe) < committed.forkable_rows) {
        try failures.append(allocator, .{ .kind = .below_floor, .key = "forkable_rows" });
    }
    if (countKind(rows, .sentinel_probe) < committed.sentinel_rows) {
        try failures.append(allocator, .{ .kind = .below_floor, .key = "sentinel_rows" });
    }
    if (countVerdict(rows, .ok) < committed.ok_rows) {
        try failures.append(allocator, .{ .kind = .verdict_below_floor, .key = "ok" });
    }

    for (allowed, 0..) |row, i| {
        if (row.reason.len == 0) try failures.append(allocator, .{ .kind = .empty_reason, .key = row.key });
        for (allowed[0..i]) |earlier| {
            if (std.mem.eql(u8, earlier.key, row.key)) {
                try failures.append(allocator, .{ .kind = .duplicate_row, .key = row.key });
            }
        }
    }

    for (rows) |row| {
        if (row.verdict == .probe_error) {
            try failures.append(allocator, .{ .kind = .probe_error, .key = row.key });
            continue;
        }
        const allow = findAllowed(allowed, row.key);
        if (row.verdict == .ok) {
            if (allow != null) try failures.append(allocator, .{ .kind = .stale_row, .key = row.key });
            continue;
        }
        const matched = allow orelse {
            try failures.append(allocator, .{ .kind = .unlisted_finding, .key = row.key });
            continue;
        };
        if (matched.verdict != row.verdict) {
            try failures.append(allocator, .{ .kind = .wrong_verdict_row, .key = row.key });
        }
    }

    for (allowed) |row| {
        var seen = false;
        for (rows) |observed| {
            if (std.mem.eql(u8, observed.key, row.key)) seen = true;
        }
        if (!seen) try failures.append(allocator, .{ .kind = .stale_row, .key = row.key });
    }
    return failures;
}

fn findAllowed(allowed: []const AllowedRow, key: []const u8) ?AllowedRow {
    for (allowed) |row| {
        if (std.mem.eql(u8, row.key, key)) return row;
    }
    return null;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "severity census over the registry" {
    const allocator = std.testing.allocator;
    var rows = try collectRows(allocator);
    defer freeRows(allocator, &rows);

    // One line per verdict, every run: a count that lost an axis shows here.
    for (std.meta.tags(Verdict)) |verdict| {
        std.debug.print("[severity-census] {s}: {d}\n", .{ @tagName(verdict), countVerdict(rows.items, verdict) });
    }
    std.debug.print("[severity-census] rows: {d} ({d} severity, {d} reverse, {d} sentinel), allowed: {d}\n", .{
        rows.items.len,
        countKind(rows.items, .severity_probe),
        countKind(rows.items, .reverse_probe),
        countKind(rows.items, .sentinel_probe),
        allowed_rows.len,
    });

    var failures = try check(allocator, rows.items, &allowed_rows, floors);
    defer failures.deinit(allocator);
    for (failures.items) |failure| {
        std.debug.print("[severity-census] FAIL {s} {s}\n", .{ @tagName(failure.kind), failure.key });
    }
    try std.testing.expectEqual(@as(usize, 0), failures.items.len);
}

// ---------------------------------------------------------------------------
// Tests of the gate itself. A gate that cannot fail checks nothing, so each
// failure kind and each verdict is produced from a small synthetic input.
// ---------------------------------------------------------------------------

const synthetic_floors = Floors{ .total = 2, .severity_rows = 1, .forkable_rows = 2, .sentinel_rows = 1, .ok_rows = 1 };

fn expectKinds(
    rows: []const Row,
    allowed: []const AllowedRow,
    committed: Floors,
    expected: []const FailureKind,
) !void {
    var failures = try check(std.testing.allocator, rows, allowed, committed);
    defer failures.deinit(std.testing.allocator);
    for (expected) |kind| {
        var found = false;
        for (failures.items) |failure| {
            if (failure.kind == kind) found = true;
        }
        if (!found) {
            std.debug.print("expected failure kind {s}, got {d} failure(s)\n", .{ @tagName(kind), failures.items.len });
            return error.ExpectedFailureMissing;
        }
    }
    if (expected.len == 0) try std.testing.expectEqual(@as(usize, 0), failures.items.len);
}

const clean_rows = [_]Row{
    .{ .key = "m.a#severity_probe", .kind = .severity_probe, .verdict = .ok },
    .{ .key = "m.b#reverse_probe", .kind = .reverse_probe, .verdict = .fork_without_severity },
    .{ .key = "m.c#sentinel_probe", .kind = .sentinel_probe, .verdict = .no_fork },
};
const clean_allowed = [_]AllowedRow{
    .{ .key = "m.b#reverse_probe", .verdict = .fork_without_severity, .mechanism = .pure_data, .reason = "r" },
    .{ .key = "m.c#sentinel_probe", .verdict = .no_fork, .mechanism = .sentinel_fork, .reason = "r" },
};

test "the gate accepts rows that match their allowed rows" {
    try expectKinds(&clean_rows, &clean_allowed, synthetic_floors, &.{});
}

test "the gate refuses every failure kind" {
    // below_floor: an empty census reports no finding and checks nothing.
    try expectKinds(&.{}, &.{}, synthetic_floors, &.{.below_floor});
    // verdict_below_floor: rows exist, none is ok.
    const none_ok = [_]Row{
        .{ .key = "m.a#severity_probe", .kind = .severity_probe, .verdict = .no_fork },
        .{ .key = "m.b#reverse_probe", .kind = .reverse_probe, .verdict = .no_fork },
        .{ .key = "m.c#sentinel_probe", .kind = .sentinel_probe, .verdict = .no_fork },
    };
    const none_ok_allowed = [_]AllowedRow{
        .{ .key = "m.a#severity_probe", .verdict = .no_fork, .mechanism = .sentinel_fork, .reason = "r" },
        .{ .key = "m.b#reverse_probe", .verdict = .no_fork, .mechanism = .sentinel_fork, .reason = "r" },
        .{ .key = "m.c#sentinel_probe", .verdict = .no_fork, .mechanism = .sentinel_fork, .reason = "r" },
    };
    try expectKinds(&none_ok, &none_ok_allowed, synthetic_floors, &.{.verdict_below_floor});
    // probe_error: the probe never ran.
    const errored = [_]Row{.{ .key = "m.a#severity_probe", .kind = .severity_probe, .verdict = .probe_error }};
    try expectKinds(&errored, &.{}, synthetic_floors, &.{.probe_error});
    // unlisted_finding: a finding with no row.
    try expectKinds(&clean_rows, clean_allowed[0..1], synthetic_floors, &.{.unlisted_finding});
    // wrong_verdict_row: the row names another verdict.
    const wrong = [_]AllowedRow{
        .{ .key = "m.b#reverse_probe", .verdict = .no_fork, .mechanism = .pure_data, .reason = "r" },
        clean_allowed[1],
    };
    try expectKinds(&clean_rows, &wrong, synthetic_floors, &.{.wrong_verdict_row});
    // stale_row, row for an ok finding.
    const stale_ok = [_]AllowedRow{ clean_allowed[0], clean_allowed[1], .{ .key = "m.a#severity_probe", .verdict = .no_fork, .mechanism = .sentinel_fork, .reason = "r" } };
    try expectKinds(&clean_rows, &stale_ok, synthetic_floors, &.{.stale_row});
    // stale_row, row for an export the census no longer probes.
    const stale_gone = [_]AllowedRow{ clean_allowed[0], clean_allowed[1], .{ .key = "m.gone#reverse_probe", .verdict = .fork_without_severity, .mechanism = .pure_data, .reason = "r" } };
    try expectKinds(&clean_rows, &stale_gone, synthetic_floors, &.{.stale_row});
    // duplicate_row.
    const duplicated = [_]AllowedRow{ clean_allowed[0], clean_allowed[1], clean_allowed[1] };
    try expectKinds(&clean_rows, &duplicated, synthetic_floors, &.{.duplicate_row});
    // empty_reason.
    const no_reason = [_]AllowedRow{
        .{ .key = "m.b#reverse_probe", .verdict = .fork_without_severity, .mechanism = .pure_data, .reason = "" },
        clean_allowed[1],
    };
    try expectKinds(&clean_rows, &no_reason, synthetic_floors, &.{.empty_reason});
}

test "every verdict is produced by a probe observation" {
    const ran = Observation{ .ran = true, .fork = true, .stub_fails = true, .counted = true };
    try std.testing.expectEqual(Verdict.ok, classifySeverityProbe(ran));
    try std.testing.expectEqual(Verdict.no_fork, classifySeverityProbe(.{ .ran = true, .fork = false, .stub_fails = false, .counted = false }));
    try std.testing.expectEqual(Verdict.stub_not_failing, classifySeverityProbe(.{ .ran = true, .fork = true, .stub_fails = false, .counted = true }));
    try std.testing.expectEqual(Verdict.not_counted, classifySeverityProbe(.{ .ran = true, .fork = true, .stub_fails = true, .counted = false }));
    try std.testing.expectEqual(Verdict.probe_error, classifySeverityProbe(.{ .ran = false, .fork = false, .stub_fails = false, .counted = false }));
    try std.testing.expectEqual(Verdict.fork_without_severity, classifyReverseProbe(ran));
    try std.testing.expectEqual(Verdict.declared_forkable_no_fork, classifyReverseProbe(.{ .ran = true, .fork = false, .stub_fails = false, .counted = false }));
    try std.testing.expectEqual(Verdict.ok, classifySentinelProbe(ran));
    try std.testing.expectEqual(Verdict.no_fork, classifySentinelProbe(.{ .ran = true, .fork = false, .stub_fails = false, .counted = false }));
}

test "every mechanism owns at least one allowed row" {
    for (std.meta.tags(Mechanism)) |mechanism| {
        var used = false;
        for (allowed_rows) |row| {
            if (row.mechanism == mechanism) used = true;
        }
        if (!used) {
            std.debug.print("mechanism {s} has no row\n", .{@tagName(mechanism)});
            return error.UnusedMechanism;
        }
    }
}

test "a probe observes a fork on a Result, an optional, and an ok record" {
    // The gate's own probes, one per fork kind, on exports that must pass.
    const allocator = std.testing.allocator;
    const cases = [_]struct { module: []const u8, func: []const u8 }{
        .{ .module = "auth", .func = "jwtVerify" },
        .{ .module = "env", .func = "env" },
        .{ .module = "fetch", .func = "fetch" },
        .{ .module = "fetch", .func = "fetchWithRetry" },
    };
    for (cases) |case| {
        const found = findExport(case.module, case.func) orelse return error.ExportMissing;
        const source = try probeSource(allocator, found.specifier, case.func, found.shape);
        defer allocator.free(source);
        const obs = try observe(allocator, source, case.module, case.func, found.shape, found.returns, found.severity);
        try std.testing.expectEqual(Verdict.ok, classifySeverityProbe(obs));
    }
}

test "the failing stub of an ok-record call is a response the replay reads as a failure" {
    try std.testing.expect(failingResponseStub("{\"status\":503,\"statusText\":\"Service Unavailable\",\"headers\":{},\"body\":\"{}\"}"));
    // The Result shape is not a fetch response.
    try std.testing.expect(!failingResponseStub("{\"ok\":false,\"error\":\"test-error\"}"));
    // A stub with an `ok` field and no failing status reads as a 200.
    try std.testing.expect(!failingResponseStub("{\"ok\":false,\"statusText\":\"x\",\"headers\":{},\"body\":\"\"}"));
    try std.testing.expect(!failingResponseStub("{\"status\":200,\"statusText\":\"OK\",\"headers\":{},\"body\":\"{}\"}"));
    // Missing fields the replay reads.
    try std.testing.expect(!failingResponseStub("{\"status\":503}"));
    try std.testing.expect(!failingResponseStub("null"));
    try std.testing.expect(!failingResponseStub("not json"));
}

test "only fetch and fetchWithRetry are probed as ok records" {
    var count: usize = 0;
    for (&builtin_modules.all) |*binding| {
        for (binding.exports) |*export_fn| {
            if (shapeForExport(export_fn) != .ok_record) continue;
            count += 1;
            const listed = std.mem.eql(u8, binding.name, "fetch") and
                (std.mem.eql(u8, export_fn.name, "fetch") or std.mem.eql(u8, export_fn.name, "fetchWithRetry"));
            if (!listed) {
                std.debug.print("unexpected ok-record export {s}.{s}\n", .{ binding.name, export_fn.name });
                return error.UnexpectedOkRecordExport;
            }
        }
    }
    try std.testing.expectEqual(@as(usize, 2), count);

    // `zttp:workflow` `call` declares the same record with no severity, so the
    // census does not probe it as an ok record: it forks on nothing.
    const call = findExport("workflow", "call") orelse return error.ExportMissing;
    try std.testing.expectEqual(Shape.undefined_sentinel, call.shape);
}
