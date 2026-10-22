//! zts Compile-Time Microbenchmark
//!
//! Measures parse/codegen or full semantic analysis, allocation churn, peak
//! live allocator bytes, and teardown across handler-shaped programs. Peak
//! bytes count requested allocator storage, not process RSS or reserved pages.
//!
//! Usage: `zig build compile-bench -Doptimize=ReleaseFast -- [flags]`
//! Flags:
//!   --json            Emit JSON to stdout.
//!   --quiet           Suppress human-readable output.
//!   --iterations N    Iterations per fixture (default 50).
//!   --profile check   Resolve types/strict rules, verify, and check flow instead
//!                     of generating bytecode. Diagnostic counts are reported;
//!                     completion does not claim the handler is proven.

const std = @import("std");
const zq = @import("zts");
const compat = zq.compat;

pub const std_options: std.Options = .{
    .log_level = .err,
};

// -- Fixtures -----------------------------------------------------------------
//
// Inline ES5+ subset fixtures. Kept in-file to avoid coupling the harness to
// any on-disk example that might change shape over time. Four sizes span the
// spectrum the tuner cares about: tiny (hello), small (arith loop), medium
// (struct/array work), large (module-style with many functions).

const Fixture = struct {
    name: []const u8,
    source: []const u8,
};

const fixtures = [_]Fixture{
    .{
        .name = "tiny_hello",
        .source =
        \\function handler(req) {
        \\  return Response.json({ ok: true, msg: "hello" });
        \\}
        ,
    },
    .{
        .name = "small_arith",
        .source =
        \\function handler(req) {
        \\  let sum = 0;
        \\  for (const n of [1, 2, 3, 4, 5, 6, 7, 8]) {
        \\    sum = sum + n * 2;
        \\  }
        \\  const doubled = sum + sum;
        \\  const tripled = doubled + sum;
        \\  return Response.json({ sum: sum, doubled: doubled, tripled: tripled });
        \\}
        ,
    },
    .{
        .name = "medium_object_ops",
        .source =
        \\function buildUser(id, name) {
        \\  return { id: id, name: name, active: true, score: id * 10 };
        \\}
        \\
        \\function scoreFor(user) {
        \\  const bonus = user.active ? 100 : 0;
        \\  return user.score + bonus;
        \\}
        \\
        \\function handler(req) {
        \\  const users = [
        \\    buildUser(1, "alice"),
        \\    buildUser(2, "bob"),
        \\    buildUser(3, "carol"),
        \\    buildUser(4, "dave"),
        \\  ];
        \\  let total = 0;
        \\  for (const u of users) {
        \\    total = total + scoreFor(u);
        \\  }
        \\  const first = users[0];
        \\  const summary = {
        \\    count: 4,
        \\    total: total,
        \\    lead: first.name,
        \\    status: total > 100 ? "ok" : "low",
        \\  };
        \\  return Response.json(summary);
        \\}
        ,
    },
    .{
        .name = "large_module",
        .source =
        \\function greet(name) { return ["hello, ", name].join(""); }
        \\function shout(s) { return [s, "!"].join(""); }
        \\function wrap(s) { return ["<", s, ">"].join(""); }
        \\function pair(a, b) { return { a: a, b: b }; }
        \\function triple(a, b, c) { return { a: a, b: b, c: c }; }
        \\function sumArr(xs) {
        \\  let s = 0;
        \\  for (const x of xs) { s = s + x; }
        \\  return s;
        \\}
        \\function mulArr(xs) {
        \\  let m = 1;
        \\  for (const x of xs) { m = m * x; }
        \\  return m;
        \\}
        \\function maxArr(xs) {
        \\  let m = xs[0];
        \\  for (const x of xs) { if (x > m) { m = x; } }
        \\  return m;
        \\}
        \\function buildReport(xs) {
        \\  const s = sumArr(xs);
        \\  const m = mulArr(xs);
        \\  const top = maxArr(xs);
        \\  return { sum: s, product: m, max: top, count: xs.length };
        \\}
        \\function handler(req) {
        \\  const xs = [2, 3, 5, 7, 11, 13];
        \\  const ys = [1, 4, 9, 16, 25];
        \\  const r1 = buildReport(xs);
        \\  const r2 = buildReport(ys);
        \\  const greeting = shout(wrap(greet("world")));
        \\  const out = {
        \\    greeting: greeting,
        \\    reports: pair(r1, r2),
        \\    meta: triple("v1", "compile-bench", xs.length + ys.length),
        \\  };
        \\  return Response.json(out);
        \\}
        ,
    },

    // The four fixtures above are plain functions, objects, arrays, and
    // for-of loops. The four below exist because that shape leaves whole
    // front-end paths unexercised - nested HTML calls, explicit text joins,
    // import specifiers, and member/optional chains - so
    // parser work on those paths measured as exactly zero.
    .{
        .name = "explicit_text_joins",
        .source =
        \\function handler(req) {
        \\  const name = "world";
        \\  const n = 42;
        \\  const greeting = ["hello, ", name, "!"].join("");
        \\  const detail = ["count=", String(n), " doubled=", String(n * 2), " nested=inner-", name].join("");
        \\  const lines = [["a-", String(n)].join(""), ["b-", String(n)].join(""), ["c-", String(n)].join(""), ["d-", String(n)].join("")];
        \\  const joined = [greeting, " / ", detail, " / ", String(lines.length)].join("");
        \\  return Response.text(joined);
        \\}
        ,
    },
    .{
        .name = "member_chains",
        .source =
        \\function handler(req) {
        \\  const cfg = { a: { b: { c: { d: { e: 7 } } } } };
        \\  const deep = cfg.a.b.c.d.e;
        \\  const safe = cfg?.a?.b?.c?.d?.e ?? 0;
        \\  const miss = cfg?.x?.y?.z ?? -1;
        \\  const list = [cfg.a.b.c, cfg.a.b, cfg.a];
        \\  return Response.json({ deep: deep, safe: safe, miss: miss, n: list.length });
        \\}
        ,
    },
    .{
        .name = "module_imports",
        .source =
        \\import { sha256, base64Encode } from "zttp:crypto";
        \\import { logInfo } from "zttp:log";
        \\import { uuid, ulid, nanoid } from "zttp:id";
        \\function handler(req) {
        \\  const id = uuid();
        \\  const digest = sha256(id);
        \\  logInfo("request");
        \\  return Response.json({
        \\    id: id,
        \\    digest: base64Encode(digest),
        \\    alt: ulid(),
        \\    short: nanoid(),
        \\  });
        \\}
        ,
    },
    .{
        .name = "html_component",
        .source =
        \\function Row(props) {
        \\  return h("li", { className: "row", id: props.name }, props.name, ": ", props.score);
        \\}
        \\function Header(props) {
        \\  return h("h1", { className: "title" }, props.text);
        \\}
        \\function handler(req) {
        \\  const users = [
        \\    { name: "alice", score: 10 },
        \\    { name: "bob", score: 20 },
        \\    { name: "carol", score: 30 },
        \\  ];
        \\  const rows = users.map((u) => h(Row, { name: u.name, score: u.score }));
        \\  return Response.html(
        \\    renderToString(h("div", { className: "page" },
        \\      h(Header, { text: "scores" }),
        \\      h("ul", { className: "list" }, rows)
        \\    ))
        \\  );
        \\}
        ,
    },
};

const GeneratedFixture = enum {
    dense_expressions,
    wide_lists,
    nested_functions,
    typed_declarations,
    blob_4mb,
    escaped_strings,

    fn source(self: GeneratedFixture, allocator: std.mem.Allocator) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(allocator);
        defer out.deinit();
        const w = &out.writer;
        switch (self) {
            .dense_expressions => {
                for (0..128) |i| {
                    try w.print("function dense{d}(x: number): number {{\n", .{i});
                    for (0..32) |_| try w.writeAll("x = (x + 1) * (x - 2) + (x + 3) * (x - 4);\n");
                    try w.writeAll("return x;\n}\n");
                }
                try w.writeAll("function handler(req: Request): Response { return Response.text(String(dense0(1))); }\n");
            },
            .wide_lists => {
                try w.writeAll("function handler(req: Request): Response { const values = [\n");
                for (0..512) |_| try w.writeAll("{ a: 1, b: [2, 3, 4] },\n");
                try w.writeAll("]; return Response.json(values); }\n");
            },
            .nested_functions => {
                for (0..24) |i| try w.print("function nested{d}(x: number): number {{\n", .{i});
                try w.writeAll("return x + 1;\n}\n");
                var depth: usize = 23;
                while (depth > 0) : (depth -= 1) try w.print("return nested{d}(x);\n}}\n", .{depth});
                try w.writeAll("function handler(req: Request): Response { return Response.text(String(nested0(1))); }\n");
            },
            .typed_declarations => {
                for (0..128) |i| {
                    try w.print("structural Row{d} = {{ value: number, label: string }};\n", .{i});
                    try w.print("function read{d}(row: Row{d}): number {{ return row.value; }}\n", .{ i, i });
                }
                try w.writeAll("function handler(req: Request): Response { return Response.text(String(read0({value: 1, label: \"ok\"}))); }\n");
            },
            .blob_4mb => {
                try w.writeAll("function handler(req: Request): Response { return Response.text(\"");
                const block = [_]u8{'a'} ** 4096;
                for (0..1024) |_| try w.writeAll(&block);
                try w.writeAll("\"); }\n");
            },
            .escaped_strings => {
                try w.writeAll("function handler(req: Request): Response { return Response.json([\n");
                for (0..512) |i| try w.print("\"line\\n{d}\\tvalue\\u{{1F600}}\",\n", .{i % 64});
                try w.writeAll("]); }\n");
            },
        }
        return out.toOwnedSlice();
    }
};

const generated_fixtures = std.meta.tags(GeneratedFixture);

// -- Counting allocator -------------------------------------------------------
//
// The shared live counter observes parser, codegen, and analysis together.
// Summing independent peaks would overstate memory when their lifetimes differ.

const MemoryUsage = struct {
    live_bytes: u64 = 0,
    peak_bytes: u64 = 0,

    fn resize(self: *MemoryUsage, old: usize, new: usize) void {
        self.live_bytes = self.live_bytes - old + new;
        self.peak_bytes = @max(self.peak_bytes, self.live_bytes);
    }
};

const CountingAlloc = struct {
    backing: std.mem.Allocator,
    memory: *MemoryUsage,
    total_bytes: u64 = 0,
    allocation_calls: u64 = 0,

    fn allocator(self: *CountingAlloc) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = vtAlloc,
                .resize = vtResize,
                .remap = vtRemap,
                .free = vtFree,
            },
        };
    }

    fn vtAlloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *CountingAlloc = @ptrCast(@alignCast(ctx));
        const result = self.backing.rawAlloc(len, alignment, ret_addr);
        if (result != null) {
            self.total_bytes += len;
            self.allocation_calls += 1;
            self.memory.resize(0, len);
        }
        return result;
    }

    fn vtResize(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *CountingAlloc = @ptrCast(@alignCast(ctx));
        const ok = self.backing.rawResize(buf, alignment, new_len, ret_addr);
        if (ok) {
            self.memory.resize(buf.len, new_len);
            if (new_len > buf.len) self.total_bytes += new_len - buf.len;
        }
        return ok;
    }

    fn vtRemap(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *CountingAlloc = @ptrCast(@alignCast(ctx));
        const result = self.backing.rawRemap(buf, alignment, new_len, ret_addr);
        if (result != null) {
            self.memory.resize(buf.len, new_len);
            if (new_len > buf.len) self.total_bytes += new_len - buf.len;
        }
        return result;
    }

    fn vtFree(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *CountingAlloc = @ptrCast(@alignCast(ctx));
        self.backing.rawFree(buf, alignment, ret_addr);
        self.memory.resize(buf.len, 0);
    }
};

// -- Compile once ------------------------------------------------------------
//
// Keep the historical parse -> codegen measurement separate from semantic
// checking. Both profiles use the production typed parser and own teardown.

const Profile = enum { compile, check };

const CompileStats = struct {
    /// Total bytes across tokenizer/parser/IR/codegen. Matches the prior
    /// single-counter number so baselines remain comparable.
    bytes: u64,
    /// Subset of `bytes` attributable to CodeGen (reserveCapacity growth,
    /// constants pool, labels, pending_jumps, bytecode array). This is the
    /// number the Phase 8 tuning pass uses to calibrate `reserveCapacity`.
    codegen_bytes: u64,
    ir_nodes: u64,
    bytecode_len: u64,
    parse_ns: u64,
    codegen_ns: u64,
    analysis_ns: u64,
    teardown_ns: u64,
    allocation_calls: u64,
    peak_bytes: u64,
    diagnostics: u64,
};

fn compileOnce(backing: std.mem.Allocator, source: []const u8, profile: Profile) !CompileStats {
    var memory: MemoryUsage = .{};
    var parser_counting = CountingAlloc{ .backing = backing, .memory = &memory };
    var codegen_counting = CountingAlloc{ .backing = backing, .memory = &memory };
    const parser_alloc = parser_counting.allocator();
    const codegen_alloc = codegen_counting.allocator();
    const start = try compat.Instant.now();
    var parsed_at: compat.Instant = undefined;
    var teardown_at: compat.Instant = undefined;
    var ir_node_count: u64 = 0;
    var bytecode_len: u64 = 0;
    var diagnostics: u64 = 0;
    {
        var strings = zq.StringTable.init(parser_alloc);
        defer strings.deinit();
        var atoms = zq.AtomTable.init(parser_alloc);
        defer atoms.deinit();

        var p = try zq.Parser.initTyped(parser_alloc, parser_alloc, source, &strings, &atoms);
        defer {
            // Runtime Contexts adopt these payloads; this harness owns them.
            if (p.code_gen) |*cg| cg.freeOwnedConstantPayloads();
            p.deinit();
        }
        switch (try p.parseTypedIr()) {
            .accepted => {},
            .terminal_admission_refused => |failure| return zq.prepareErrorForAdmissionFailure(failure),
            .parser_refused => |refusal| return refusal.first_error,
            .recovered_admission_refused => return error.AdmissionRefused,
        }
        parsed_at = try compat.Instant.now();
        ir_node_count = @intCast(p.js_parser.nodes.tags.items.len);
        var analysis: zq.pipeline.ModuleAnalysisSession = .{};
        defer analysis.deinit();
        switch (profile) {
            .compile => bytecode_len = @intCast((try p.generateParsed(codegen_alloc)).len),
            .check => {
                const view = zq.IrView.fromIRStore(&p.js_parser.nodes, &p.js_parser.constants);
                var parsed = zq.pipeline.ParsedModule.fromTypedExisting(view, p.root_node, &atoms, &p.js_parser.type_store);
                parsed.scopes = &p.js_parser.scopes;
                try analysis.initFull(parser_alloc, parsed, .{
                    .source_types = .direct,
                    .select_verifier = true,
                    .select_flow = true,
                });
                try analysis.complete();
                const resolved = try analysis.resolvedForReport();
                diagnostics = resolved.bool_error_count + resolved.typeErrorCount() + resolved.strict_error_count;
                const handler = zq.findHandlerFunction(view, p.root_node) orelse return error.BenchmarkHandlerMissing;
                try analysis.prepareChecked(handler, .{ .module_facts = try analysis.facts() });
                diagnostics += try analysis.runVerifier(handler);
                diagnostics += try analysis.runFlow(handler);
            },
        }
        teardown_at = try compat.Instant.now();
    }
    const end = try compat.Instant.now();
    if (memory.live_bytes != 0) return error.BenchmarkAllocationLeak;

    return .{
        .bytes = parser_counting.total_bytes + codegen_counting.total_bytes,
        .codegen_bytes = codegen_counting.total_bytes,
        .ir_nodes = ir_node_count,
        .bytecode_len = bytecode_len,
        .parse_ns = parsed_at.since(start),
        .codegen_ns = if (profile == .compile) teardown_at.since(parsed_at) else 0,
        .analysis_ns = if (profile == .check) teardown_at.since(parsed_at) else 0,
        .teardown_ns = end.since(teardown_at),
        .allocation_calls = parser_counting.allocation_calls + codegen_counting.allocation_calls,
        .peak_bytes = memory.peak_bytes,
        .diagnostics = diagnostics,
    };
}

// -- Driver ------------------------------------------------------------------

const Options = struct {
    json: bool = false,
    quiet: bool = false,
    iterations: u32 = 50,
    profile: Profile = .compile,
};

const usage =
    "Usage: compile-bench [--json] [--quiet] [--iterations N] [--profile compile|check]\n";

fn writeStdout(data: []const u8) void {
    _ = std.c.write(std.c.STDOUT_FILENO, data.ptr, data.len);
}

fn printFmt(comptime fmt: []const u8, args: anytype) void {
    var buf: [1024]u8 = undefined;
    const out = std.fmt.bufPrint(&buf, fmt ++ "\n", args) catch return;
    writeStdout(out);
}

fn parseOptions() Options {
    var options = Options{};
    var iter = std.process.Args.Iterator.init(g_args);
    defer iter.deinit();
    _ = iter.skip();

    while (iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "--json")) {
            options.json = true;
        } else if (std.mem.eql(u8, arg, "--quiet")) {
            options.quiet = true;
        } else if (std.mem.eql(u8, arg, "--profile")) {
            options.profile = std.meta.stringToEnum(Profile, iter.next() orelse "") orelse {
                writeStdout(usage);
                std.process.exit(1);
            };
        } else if (std.mem.eql(u8, arg, "--iterations")) {
            const val = iter.next() orelse {
                writeStdout("Missing value for --iterations\n");
                writeStdout(usage);
                std.process.exit(1);
            };
            options.iterations = std.fmt.parseInt(u32, val, 10) catch {
                writeStdout("Invalid value for --iterations\n");
                writeStdout(usage);
                std.process.exit(1);
            };
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            writeStdout(usage);
            std.process.exit(0);
        }
    }

    if (options.iterations == 0) options.iterations = 1;
    return options;
}

const Result = struct {
    name: []const u8,
    iterations: u32,
    ns_per_iter: u64 = 0,
    stats: CompileStats = std.mem.zeroes(CompileStats),
    success: bool = false,
    error_name: ?[]const u8 = null,
};

fn runFixture(allocator: std.mem.Allocator, fx: Fixture, iterations: u32, profile: Profile) Result {
    var result: Result = .{ .name = fx.name, .iterations = iterations };
    if (iterations == 0) {
        result.error_name = "EmptyBenchmark";
        return result;
    }
    // Fail before timing when a fixture no longer parses or checks.
    const warm = compileOnce(allocator, fx.source, profile) catch |err| {
        result.error_name = @errorName(err);
        return result;
    };
    if (warm.ir_nodes == 0) {
        result.error_name = "EmptyBenchmark";
        return result;
    }
    const start = compat.Instant.now() catch {
        result.error_name = "TimerUnavailable";
        return result;
    };
    for (0..iterations) |_| {
        const stats = compileOnce(allocator, fx.source, profile) catch |err| {
            result.error_name = @errorName(err);
            return result;
        };
        inline for (std.meta.fields(CompileStats)) |field| {
            @field(result.stats, field.name) += @field(stats, field.name);
        }
    }
    const end = compat.Instant.now() catch {
        result.error_name = "TimerUnavailable";
        return result;
    };
    result.ns_per_iter = end.since(start) / iterations;
    inline for (std.meta.fields(CompileStats)) |field| {
        @field(result.stats, field.name) /= iterations;
    }
    result.success = true;
    return result;
}

fn emitJson(results: []const Result, profile: Profile) void {
    printFmt("{{\n  \"schema_version\": 1,\n  \"profile\": \"{s}\",\n  \"benchmarks\": [", .{@tagName(profile)});
    for (results, 0..) |r, i| {
        const s = r.stats;
        var line: [1024]u8 = undefined;
        const written = std.fmt.bufPrint(
            &line,
            "    {{\"name\":\"{s}\",\"iterations\":{},\"ns_per_iter\":{},\"bytes_alloc\":{},\"codegen_bytes\":{},\"ir_nodes\":{},\"bytecode_len\":{}," ++
                "\"parse_ns\":{},\"codegen_ns\":{},\"analysis_ns\":{},\"teardown_ns\":{},\"allocation_calls\":{},\"peak_bytes\":{},\"diagnostics\":{},\"success\":{}",
            .{ r.name, r.iterations, r.ns_per_iter, s.bytes, s.codegen_bytes, s.ir_nodes, s.bytecode_len, s.parse_ns, s.codegen_ns, s.analysis_ns, s.teardown_ns, s.allocation_calls, s.peak_bytes, s.diagnostics, r.success },
        ) catch unreachable;
        writeStdout(written);
        if (r.error_name) |err| {
            const error_text = std.fmt.bufPrint(&line, ",\"error_name\":\"{s}\"", .{err}) catch unreachable;
            writeStdout(error_text);
        }
        writeStdout(if (i + 1 < results.len) "},\n" else "}\n");
    }
    writeStdout("  ]\n}\n");
}

fn emitHuman(results: []const Result, profile: Profile) void {
    printFmt("\nzts {s} benchmark (times in ns; peak is allocator bytes, not RSS)\n", .{@tagName(profile)});
    printFmt("{s:<24} {s:>10} {s:>10} {s:>10} {s:>10} {s:>10} {s:>12} {s:>12} {s:>8}", .{ "fixture", "total", "parse", "codegen", "analysis", "teardown", "peak", "churn", "allocs" });
    for (results) |r| {
        if (r.success) {
            const s = r.stats;
            printFmt("{s:<24} {d:>10} {d:>10} {d:>10} {d:>10} {d:>10} {d:>10} {d:>12} {d:>8}", .{
                r.name, r.ns_per_iter, s.parse_ns, s.codegen_ns, s.analysis_ns, s.teardown_ns, s.peak_bytes, s.bytes, s.allocation_calls,
            });
        } else {
            printFmt("{s:<24} FAILED: {s}", .{ r.name, r.error_name orelse "unknown" });
        }
    }
    writeStdout("\n");
}

var g_args: std.process.Args = undefined;

pub fn main(init: std.process.Init.Minimal) !void {
    g_args = init.args;
    const options = parseOptions();
    // libc malloc/free for proper per-compile freeing without GPA tracking
    // overhead. Matches packages/runtime/bench/benchmark.zig.
    const allocator = std.heap.c_allocator;

    var results: [fixtures.len + generated_fixtures.len]Result = undefined;
    for (fixtures, 0..) |fx, i| {
        results[i] = runFixture(allocator, fx, options.iterations, options.profile);
    }

    for (generated_fixtures, fixtures.len..) |kind, i| {
        const source = try kind.source(allocator);
        defer allocator.free(source);
        results[i] = runFixture(allocator, .{ .name = @tagName(kind), .source = source }, options.iterations, options.profile);
    }

    if (options.json) {
        emitJson(&results, options.profile);
    } else if (!options.quiet) {
        emitHuman(&results, options.profile);
    }

    // A fixture that stops parsing is a front-end regression, so exit non-zero
    // after reporting it. Without this the failure is only a line of text and
    // `zig build compile-bench` still succeeds, which would let a break on the
    // HTML, template, import, or member-chain paths pass unnoticed.
    for (results) |r| {
        if (!r.success) std.process.exit(1);
    }
}

// -- Tests -------------------------------------------------------------------

test "compile-bench runs one iteration per fixture under 2s" {
    const allocator = std.testing.allocator;
    try std.testing.expect(fixtures.len >= 8);

    const start = try compat.Instant.now();
    for (fixtures) |fx| {
        const r = runFixture(allocator, fx, 1, .compile);
        try std.testing.expect(r.success);
        try std.testing.expect(r.stats.ir_nodes > 0);
    }
    const end = try compat.Instant.now();
    const elapsed_ns = end.since(start);
    // 2s wall-clock ceiling. Exists to catch catastrophic regressions
    // (e.g. an accidental O(n^2) path), not as a perf gate.
    try std.testing.expect(elapsed_ns < 2 * std.time.ns_per_s);
}

test "benchmark memory accounting includes shrink remap and overlapping owners" {
    var memory: MemoryUsage = .{};
    var first: CountingAlloc = .{ .backing = std.testing.allocator, .memory = &memory };
    var second: CountingAlloc = .{ .backing = std.testing.allocator, .memory = &memory };
    const a = first.allocator();
    const b = second.allocator();
    var bytes = try a.alloc(u8, 256);
    const other = try b.alloc(u8, 32);
    try std.testing.expectEqual(@as(u64, 288), memory.peak_bytes);
    // realloc exercises resize/remap or the alloc-copy-free fallback. Account
    // for either allocator behavior, rather than requiring an in-place grow.
    bytes = try a.realloc(bytes, 1024);
    try std.testing.expectEqual(@as(u64, 1056), memory.live_bytes);
    bytes = try a.realloc(bytes, 16);
    try std.testing.expectEqual(@as(u64, 48), memory.live_bytes);
    b.free(other);
    a.free(bytes);
    try std.testing.expectEqual(@as(u64, 0), memory.live_bytes);
    try std.testing.expect(memory.peak_bytes >= 1056);
    try std.testing.expect(first.total_bytes >= 1024);
    try std.testing.expectEqual(@as(u64, 1), second.allocation_calls);
}

test "generated benchmark census compiles and completes all semantic passes" {
    const allocator = std.testing.allocator;
    try std.testing.expectEqual(@as(usize, 6), generated_fixtures.len);
    for (generated_fixtures) |kind| {
        const source = try kind.source(allocator);
        defer allocator.free(source);
        if (kind == .blob_4mb) try std.testing.expect(source.len > 4 * 1024 * 1024);
        const compiled = try compileOnce(allocator, source, .compile);
        try std.testing.expect(compiled.ir_nodes > 0);
        try std.testing.expect(compiled.bytecode_len > 0);
        if (kind == .dense_expressions or kind == .wide_lists) try std.testing.expect(compiled.ir_nodes > 1024);
        const checked = try compileOnce(allocator, source, .check);
        try std.testing.expectEqual(compiled.ir_nodes, checked.ir_nodes);
        try std.testing.expectEqual(@as(u64, 0), checked.diagnostics);
        try std.testing.expectEqual(@as(u64, 0), checked.codegen_bytes);
        try std.testing.expect(checked.peak_bytes > 0);
    }
}

test "check profile reports semantic diagnostics and refuses empty timing runs" {
    const stats = try compileOnce(std.testing.allocator, "function handler(req: Request): Response { return Response.text('ok'); }", .check);
    try std.testing.expectEqual(@as(u64, 0), stats.diagnostics);
    try std.testing.expectEqual(@as(u64, 0), stats.bytecode_len);
    const refused = try compileOnce(std.testing.allocator, "function handler(req: Request): Response { const n: number = 'bad'; return Response.text(n); }", .check);
    try std.testing.expect(refused.diagnostics > 0);
    const empty = runFixture(std.testing.allocator, fixtures[0], 0, .compile);
    try std.testing.expect(!empty.success);
    try std.testing.expectEqualStrings("EmptyBenchmark", empty.error_name.?);
}
