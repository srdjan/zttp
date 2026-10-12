//! TUI frame writer for ProofCard.
//!
//! Renders a ProofCard as a static ASCII frame: a properties grid and a
//! surface tree, with a status bar below. The frame does not move the cursor
//! and does not require raw mode, so callers can drive a live HUD by simply rendering
//! a fresh frame after each event (e.g. each recompile).
//!
//! Layout (default 100 cols):
//!
//!     +-------- Properties --------+----------- Surface -----------+
//!     | [+] retry-safe             | routes (2)                    |
//!     | [+] read-only              |   /healthz                    |
//!     | ...                        |   /api (prefix)               |
//!     +----------------------------+-------------------------------+
//!     | Verdict: safe              | Contract: sha-...             |
//!     | Baseline: ...                                              |
//!     +----------------------------+-------------------------------+

const std = @import("std");
const review = @import("zttp_proof_review").review;

pub const FrameOptions = struct {
    /// Total visible width in columns. Min 60, max 200.
    width: u16 = 100,
    /// Recompile elapsed time in ms, shown as a sub-line in the properties
    /// pane header. `null` means dev hasn't reported a recompile yet.
    recompile_ms: ?u32 = null,
    /// Pre-rendered `proofTrace` JSON object from the analyzer. When present,
    /// a "Proof trace" block beneath the panes surfaces the reasoning behind
    /// every red proof. Null (the default) skips the block entirely.
    proof_trace_json: ?[]const u8 = null,
};

const ColumnWidths = struct {
    properties: u16,
    surface: u16,

    /// Two panes plus three border columns consume the total width. The
    /// content split is roughly 45/55 with the surface pane absorbing
    /// rounding so the totals always match.
    fn from(total_width: u16) ColumnWidths {
        const clamped: u16 = @max(60, @min(total_width, 200));
        const inside: u16 = clamped - 3;
        const props: u16 = @max(20, inside * 45 / 100);
        return .{ .properties = props, .surface = inside - props };
    }
};

/// Render a ProofCard as a two-pane TUI frame. Caller flushes the writer.
pub fn writeProofCardFrame(
    allocator: std.mem.Allocator,
    card: *const review.ProofCard,
    writer: *std.Io.Writer,
    opts: FrameOptions,
) !void {
    const widths = ColumnWidths.from(opts.width);

    var left = try buildPropertiesPane(allocator, card);
    defer freeLines(allocator, &left);
    var surface = try buildSurfacePane(allocator, card);
    defer freeLines(allocator, &surface);

    try writeBorder(writer, widths);
    try writeRow(writer, widths, "Properties", "Surface");
    if (opts.recompile_ms) |ms| {
        var buf: [32]u8 = undefined;
        const stamp = try std.fmt.bufPrint(&buf, "  {d}ms recompile", .{ms});
        try writeRow(writer, widths, stamp, "");
    }
    try writeBorder(writer, widths);

    const tall: usize = @max(left.items.len, surface.items.len);
    var i: usize = 0;
    while (i < tall) : (i += 1) {
        const p = if (i < left.items.len) left.items[i] else "";
        const s = if (i < surface.items.len) surface.items[i] else "";
        try writeRow(writer, widths, p, s);
    }

    try writeBorder(writer, widths);
    if (try buildWhyRow(allocator, card)) |why_line| {
        defer allocator.free(why_line);
        try writeFullRow(writer, widths, why_line);
        try writeBorder(writer, widths);
    }
    if (card.counterexample) |cx| {
        try writeCounterexampleBlock(allocator, writer, widths, &cx);
        try writeBorder(writer, widths);
    }
    // The trace and resisted blocks read the same object, so parse once and
    // share it.
    if (opts.proof_trace_json) |ptj| {
        if (std.json.parseFromSlice(std.json.Value, allocator, ptj, .{})) |parsed| {
            defer parsed.deinit();
            if (parsed.value == .object) {
                const obj = parsed.value.object;
                if (try writeProofTraceBlock(allocator, writer, widths, obj)) {
                    try writeBorder(writer, widths);
                }
                if (try writeResistedBlock(allocator, writer, widths, obj)) {
                    try writeBorder(writer, widths);
                }
            }
        } else |_| {}
    }
    try writeStatusBar(writer, widths, card);
    try writeBorder(writer, widths);
}

fn writeCounterexampleBlock(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    widths: ColumnWidths,
    cx: *const review.CounterexamplePreview,
) !void {
    try writeCounterexampleHeadline(allocator, writer, widths, cx);
    if (cx.suggestion) |hint| try writeWhyRow(allocator, writer, widths, hint);
    if (cx.failing_request) |req| try writeReplaySection(allocator, writer, widths, req, cx);
    try writeFullRow(
        writer,
        widths,
        "  [r] replay live   [s] pin as regression test   [a] ask expert to fix",
    );
}

fn writeCounterexampleHeadline(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    widths: ColumnWidths,
    cx: *const review.CounterexamplePreview,
) !void {
    const line = try std.fmt.allocPrint(
        allocator,
        "Counterexample: -{s} at {s}:{d}: {s}",
        .{ cx.label, cx.handler_path, cx.line, cx.snippet },
    );
    defer allocator.free(line);
    try writeFullRow(writer, widths, line);
}

fn writeWhyRow(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    widths: ColumnWidths,
    hint: []const u8,
) !void {
    const line = try std.fmt.allocPrint(allocator, "  why: {s}", .{hint});
    defer allocator.free(line);
    try writeFullRow(writer, widths, line);
}

fn writeReplaySection(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    widths: ColumnWidths,
    req: review.CounterexamplePreview.FailingRequest,
    cx: *const review.CounterexamplePreview,
) !void {
    const req_line = try std.fmt.allocPrint(
        allocator,
        "  request: {s} {s}",
        .{ req.method, req.url },
    );
    defer allocator.free(req_line);
    try writeFullRow(writer, widths, req_line);

    if (cx.previous_response) |prev| {
        const line = try formatReplayLine(allocator, "  previous build", prev);
        defer allocator.free(line);
        try writeFullRow(writer, widths, line);
    }
    if (cx.current_response) |curr| {
        const line = try formatReplayLine(allocator, "  this build    ", curr);
        defer allocator.free(line);
        try writeFullRow(writer, widths, line);
    }
}

fn formatReplayLine(
    allocator: std.mem.Allocator,
    prefix: []const u8,
    r: review.CounterexamplePreview.ReplayResponse,
) ![]u8 {
    if (r.error_text) |err| {
        return std.fmt.allocPrint(allocator, "{s}: crashed - {s}", .{ prefix, err });
    }
    return std.fmt.allocPrint(allocator, "{s}: {d}  {s}", .{ prefix, r.status, r.body });
}

/// Build the Why-on-regression row content for the live HUD: when a property
/// demoted between this prove cycle and the baseline AND the live-reload path
/// supplied a cause for that property, surface "Why: -<prop> at handler.ts:N: <snippet>".
/// Returns null when there is nothing to say (no demotions, no causes, or no
/// match between the two). Caller frees the returned slice.
fn buildWhyRow(
    allocator: std.mem.Allocator,
    card: *const review.ProofCard,
) !?[]u8 {
    if (card.property_causes.len == 0) return null;
    if (card.delta.demoted_properties.len == 0) return null;

    for (card.delta.demoted_properties) |demoted| {
        for (card.property_causes) |cause| {
            if (std.mem.eql(u8, cause.field, demoted.name)) {
                return try std.fmt.allocPrint(
                    allocator,
                    "Why: -{s} at {s}:{d}: {s}",
                    .{ demoted.label, card.handler_path, cause.line, cause.snippet },
                );
            }
        }
    }
    return null;
}

/// Render a single full-width row that spans every pane (no internal pipes).
/// Used for the Why-on-regression row, which is one logical message and reads
/// better unbroken than packed into the two-pane grid.
fn writeFullRow(
    writer: *std.Io.Writer,
    widths: ColumnWidths,
    content: []const u8,
) !void {
    const inside_width: usize =
        @as(usize, widths.properties) + @as(usize, widths.surface) + 1;
    try writer.writeAll("|");
    const visible: usize = @min(content.len, inside_width);
    try writer.writeAll(content[0..visible]);
    try writer.splatByteAll(' ', inside_width - visible);
    try writer.writeAll("|\n");
}

// Typed accessors over std.json.Value for the proof-trace render blocks
// below. Both blocks pull object/string/array fields by key from the same
// parsed `proofTrace` object; these flatten the `get + switch` idiom to a
// single optional read.
fn jsonString(v: std.json.Value) ?[]const u8 {
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}
fn objField(obj: std.json.ObjectMap, key: []const u8) ?std.json.ObjectMap {
    return switch (obj.get(key) orelse return null) {
        .object => |o| o,
        else => null,
    };
}
fn strField(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    return jsonString(obj.get(key) orelse return null);
}
fn arrField(obj: std.json.ObjectMap, key: []const u8) ?std.json.Array {
    return switch (obj.get(key) orelse return null) {
        .array => |a| a,
        else => null,
    };
}

/// Render the "Proof trace" block: for every headline property that did not
/// hold, one full-width row carrying the analyzer's reasoning. Surfaces the
/// counterexample behind each red chip without a keystroke. Returns true when
/// at least one row was written. `obj` is the parsed `proofTrace` object,
/// shared with `writeResistedBlock` so the JSON is parsed once per frame.
fn writeProofTraceBlock(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    widths: ColumnWidths,
    obj: std.json.ObjectMap,
) !bool {
    var wrote_title = false;
    inline for (review.property_metas) |meta| {
        if (objField(obj, meta.field)) |fields| {
            const holds = if (fields.get("holds")) |h| switch (h) {
                .bool => |b| b,
                else => true,
            } else true;
            if (!holds) {
                if (!wrote_title) {
                    try writeFullRow(writer, widths, "Proof trace: how each red proof broke");
                    wrote_title = true;
                }
                const summary = strField(fields, "summary") orelse "";
                const line = try std.fmt.allocPrint(allocator, "  -{s}: {s}", .{ meta.label, summary });
                defer allocator.free(line);
                try writeFullRow(writer, widths, line);
            }
        }
    }
    return wrote_title;
}

/// Render the "resisted" block: for every held flow property that carries a
/// `resisted` object, show the representative attack the prover considered and
/// the source -> guard -> sink chain that defeats it. The green-proof mirror of
/// `writeProofTraceBlock`: it turns a passing checkmark into legible evidence.
/// Returns true when at least one row was written. `obj` is the parsed
/// `proofTrace` object, shared with `writeProofTraceBlock`.
fn writeResistedBlock(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    widths: ColumnWidths,
    obj: std.json.ObjectMap,
) !bool {
    var wrote_title = false;
    inline for (review.property_metas) |meta| {
        if (objField(obj, meta.field)) |fields| {
            if (objField(fields, "resisted")) |rf| {
                if (!wrote_title) {
                    try writeFullRow(writer, widths, "Resisted: the attack each proof defeats");
                    wrote_title = true;
                }
                const header = try std.fmt.allocPrint(allocator, "  +{s}", .{meta.label});
                defer allocator.free(header);
                try writeFullRow(writer, widths, header);

                if (strField(rf, "attackInput")) |s| {
                    const line = try std.fmt.allocPrint(allocator, "    tried: {s}", .{s});
                    defer allocator.free(line);
                    try writeFullRow(writer, widths, line);
                }
                if (arrField(rf, "chain")) |steps| {
                    for (steps.items) |step| if (jsonString(step)) |s| {
                        const line = try std.fmt.allocPrint(allocator, "    -> {s}", .{s});
                        defer allocator.free(line);
                        try writeFullRow(writer, widths, line);
                    };
                }
                if (strField(rf, "conclusion")) |s| {
                    const line = try std.fmt.allocPrint(allocator, "    {s}", .{s});
                    defer allocator.free(line);
                    try writeFullRow(writer, widths, line);
                }
            }
        }
    }
    return wrote_title;
}

/// Render the verdict, contract sha, and baseline sha rows at the bottom of the
/// frame. Shas are clipped to 24 chars so each row fits its column.
fn writeStatusBar(
    writer: *std.Io.Writer,
    widths: ColumnWidths,
    card: *const review.ProofCard,
) !void {
    const sha_max: usize = 24;
    const current_sha = card.current.contract_sha;
    var verdict_buf: [64]u8 = undefined;
    var contract_buf: [64]u8 = undefined;
    var baseline_buf: [64]u8 = undefined;

    const verdict_text = try std.fmt.bufPrint(
        &verdict_buf,
        "Verdict: {s}",
        .{card.verdict().slug()},
    );
    const contract_text = try std.fmt.bufPrint(
        &contract_buf,
        "Contract: {s}",
        .{current_sha[0..@min(current_sha.len, sha_max)]},
    );
    const baseline_text = if (card.baseline) |b| blk: {
        const sha = b.contract_sha;
        break :blk try std.fmt.bufPrint(
            &baseline_buf,
            "Baseline: {s}",
            .{sha[0..@min(sha.len, sha_max)]},
        );
    } else "Baseline: (first deploy)";

    try writeRow(writer, widths, verdict_text, contract_text);
    try writeFullRow(writer, widths, baseline_text);
}

// ---------------------------------------------------------------------------
// Pane builders
// ---------------------------------------------------------------------------

const LineList = std.ArrayList([]u8);

fn buildPropertiesPane(
    allocator: std.mem.Allocator,
    card: *const review.ProofCard,
) !LineList {
    var lines: LineList = .empty;
    errdefer freeLines(allocator, &lines);

    inline for (review.property_metas) |meta| {
        const proven = @field(card.current.properties, meta.field);
        const glyph: []const u8 = if (proven) "[+]" else "[-]";
        const line = try std.fmt.allocPrint(allocator, "{s} {s}", .{ glyph, meta.label });
        try lines.append(allocator, line);
    }

    const proof_line = try std.fmt.allocPrint(
        allocator,
        "proof: {s}",
        .{card.current.proof_level.toString()},
    );
    try lines.append(allocator, proof_line);

    // Active specs render directly under the inferred properties. Failing
    // specs use [-]; passing specs use [*] to distinguish them from the
    // inferred property dots.
    if (card.current.declared_specs.len > 0) {
        try lines.append(allocator, try allocator.dupe(u8, ""));
        try lines.append(allocator, try allocator.dupe(u8, "Specs (active)"));
        for (card.current.declared_specs) |s| {
            const glyph: []const u8 = if (s.discharged) "[*]" else "[-]";
            const line = try std.fmt.allocPrint(allocator, "{s} spec {s}", .{ glyph, s.name });
            try lines.append(allocator, line);
        }
    }
    return lines;
}

fn buildSurfacePane(
    allocator: std.mem.Allocator,
    card: *const review.ProofCard,
) !LineList {
    var lines: LineList = .empty;
    errdefer freeLines(allocator, &lines);

    // Routes carry the prefix/exact distinction, so they get their own block.
    try appendCountedHeading(allocator, &lines, "routes", card.current.routes.len);
    for (card.current.routes) |r| {
        const suffix: []const u8 = if (r.is_prefix) " (prefix)" else "";
        const line = try std.fmt.allocPrint(allocator, "  {s}{s}", .{ r.pattern, suffix });
        try lines.append(allocator, line);
    }

    try appendStringSection(allocator, &lines, "env", card.current.env_keys);
    try appendStringSection(allocator, &lines, "egress", card.current.egress_endpoints);
    try appendStringSection(allocator, &lines, "caches", card.current.cache_namespaces);
    try appendStringSection(allocator, &lines, "capabilities", card.current.capabilities);

    return lines;
}

fn appendStringSection(
    allocator: std.mem.Allocator,
    lines: *LineList,
    name: []const u8,
    items: []const []const u8,
) !void {
    try appendCountedHeading(allocator, lines, name, items.len);
    for (items) |item| {
        const line = try std.fmt.allocPrint(allocator, "  {s}", .{item});
        try lines.append(allocator, line);
    }
}

fn appendCountedHeading(
    allocator: std.mem.Allocator,
    lines: *LineList,
    name: []const u8,
    count: usize,
) !void {
    const line = try std.fmt.allocPrint(allocator, "{s} ({d})", .{ name, count });
    try lines.append(allocator, line);
}

fn freeLines(allocator: std.mem.Allocator, lines: *LineList) void {
    for (lines.items) |line| allocator.free(line);
    lines.deinit(allocator);
}

// ---------------------------------------------------------------------------
// Frame primitives
// ---------------------------------------------------------------------------

fn writeBorder(writer: *std.Io.Writer, widths: ColumnWidths) !void {
    try writer.writeAll("+");
    try writer.splatByteAll('-', widths.properties);
    try writer.writeAll("+");
    try writer.splatByteAll('-', widths.surface);
    try writer.writeAll("+\n");
}

fn writeRow(
    writer: *std.Io.Writer,
    widths: ColumnWidths,
    a: []const u8,
    b: []const u8,
) !void {
    try writer.writeAll("|");
    try writePadded(writer, a, widths.properties);
    try writer.writeAll("|");
    try writePadded(writer, b, widths.surface);
    try writer.writeAll("|\n");
}

fn writePadded(writer: *std.Io.Writer, s: []const u8, width: u16) !void {
    const visible: usize = @min(s.len, width);
    try writer.writeAll(s[0..visible]);
    try writer.splatByteAll(' ', @as(usize, width) - visible);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const Route = review.Route;
const ReviewFacts = review.ReviewFacts;
const ProofCard = review.ProofCard;

fn buildTestFacts(allocator: std.mem.Allocator) !ReviewFacts {
    return ReviewFacts{
        .contract_sha = try allocator.dupe(u8, "sha-frame-test-12345678"),
        .proof_level = .complete,
        .env_keys = blk: {
            var arr = try allocator.alloc([]const u8, 2);
            arr[0] = try allocator.dupe(u8, "DATABASE_URL");
            arr[1] = try allocator.dupe(u8, "PORT");
            break :blk arr;
        },
        .egress_endpoints = blk: {
            var arr = try allocator.alloc([]const u8, 1);
            arr[0] = try allocator.dupe(u8, "api.example.com");
            break :blk arr;
        },
        .cache_namespaces = try allocator.alloc([]const u8, 0),
        .routes = blk: {
            var arr = try allocator.alloc(Route, 2);
            arr[0] = .{ .pattern = try allocator.dupe(u8, "/api"), .is_prefix = true };
            arr[1] = .{ .pattern = try allocator.dupe(u8, "/healthz"), .is_prefix = false };
            break :blk arr;
        },
        .capabilities = blk: {
            var arr = try allocator.alloc([]const u8, 1);
            arr[0] = try allocator.dupe(u8, "clock");
            break :blk arr;
        },
        .properties = .{ .read_only = true, .input_validated = true },
    };
}

test "writeProofCardFrame: structure and content" {
    const allocator = std.testing.allocator;
    var current = try buildTestFacts(allocator);
    defer current.deinit(allocator);

    var delta = try review.deriveDelta(allocator, &current, null);
    defer delta.deinit(allocator);

    const card = ProofCard{
        .handler_path = "src/handler.ts",
        .service_name = "demo",
        .region = "us-east",
        .current = &current,
        .baseline = null,
        .delta = &delta,
    };

    var aw = std.Io.Writer.Allocating.init(allocator);
    defer aw.deinit();
    try writeProofCardFrame(allocator, &card, &aw.writer, .{});
    const out = aw.writer.buffered();

    // Frame headers and panes are present.
    try std.testing.expect(std.mem.indexOf(u8, out, "Properties") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Surface") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Requests") == null);

    // Property glyphs reflect proven/not-proven flags.
    try std.testing.expect(std.mem.indexOf(u8, out, "[+] read-only") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "[-] retry-safe") != null);

    // Surface tree heading + entries.
    try std.testing.expect(std.mem.indexOf(u8, out, "routes (2)") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "/healthz") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "/api (prefix)") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "env (2)") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "DATABASE_URL") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "egress (1)") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "api.example.com") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "capabilities (1)") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "clock") != null);

    // Status bar shows verdict, truncated contract sha, baseline note.
    try std.testing.expect(std.mem.indexOf(u8, out, "Verdict: safe") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Contract: sha-frame-test-12345678") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Baseline: (first deploy)") != null);

    // Border characters are present.
    try std.testing.expect(std.mem.indexOf(u8, out, "+--") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "|") != null);
}

test "writeProofCardFrame: every row has identical visible width" {
    const allocator = std.testing.allocator;
    var current = try buildTestFacts(allocator);
    defer current.deinit(allocator);

    var delta = try review.deriveDelta(allocator, &current, null);
    defer delta.deinit(allocator);

    const card = ProofCard{
        .handler_path = "src/handler.ts",
        .service_name = "demo",
        .region = "us-east",
        .current = &current,
        .baseline = null,
        .delta = &delta,
    };

    var aw = std.Io.Writer.Allocating.init(allocator);
    defer aw.deinit();
    try writeProofCardFrame(allocator, &card, &aw.writer, .{ .width = 100 });
    const out = aw.writer.buffered();

    var expected_width: ?usize = null;
    var iter = std.mem.splitScalar(u8, out, '\n');
    while (iter.next()) |line| {
        if (line.len == 0) continue;
        if (expected_width == null) expected_width = line.len;
        try std.testing.expectEqual(expected_width.?, line.len);
    }
    try std.testing.expectEqual(@as(usize, 100), expected_width.?);
}

test "writeProofCardFrame: proof trace block surfaces failing properties and keeps width" {
    const allocator = std.testing.allocator;
    var current = try buildTestFacts(allocator);
    defer current.deinit(allocator);

    var delta = try review.deriveDelta(allocator, &current, null);
    defer delta.deinit(allocator);

    const card = ProofCard{
        .handler_path = "src/handler.ts",
        .service_name = "demo",
        .region = "us-east",
        .current = &current,
        .baseline = null,
        .delta = &delta,
    };

    const trace_json =
        \\{"deterministic":{"holds":false,"kind":"structural","summary":"Date.now() reads a clock."},
        \\"read_only":{"holds":true,"kind":"structural","summary":"no writes"}}
    ;

    var aw = std.Io.Writer.Allocating.init(allocator);
    defer aw.deinit();
    try writeProofCardFrame(allocator, &card, &aw.writer, .{ .width = 100, .proof_trace_json = trace_json });
    const out = aw.writer.buffered();

    // The failing property appears with its reasoning; the passing one does not.
    try std.testing.expect(std.mem.indexOf(u8, out, "Proof trace: how each red proof broke") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Date.now() reads a clock.") != null);

    // Every rendered row still has identical visible width.
    var iter = std.mem.splitScalar(u8, out, '\n');
    while (iter.next()) |line| {
        if (line.len == 0) continue;
        try std.testing.expectEqual(@as(usize, 100), line.len);
    }
}

test "writeProofCardFrame: resisted block surfaces a held flow proof and keeps width" {
    const allocator = std.testing.allocator;
    var current = try buildTestFacts(allocator);
    defer current.deinit(allocator);

    var delta = try review.deriveDelta(allocator, &current, null);
    defer delta.deinit(allocator);

    const card = ProofCard{
        .handler_path = "src/handler.ts",
        .service_name = "demo",
        .region = "us-east",
        .current = &current,
        .baseline = null,
        .delta = &delta,
    };

    const trace_json =
        \\{"injection_safe":{"holds":true,"kind":"flow-trace","summary":"No unvalidated user input reaches a SQL or HTML sink.",
        \\"resisted":{"attackInput":"1; DROP TABLE users--","chain":["user input enters the handler","validated by schemaCompile() at L7","reaches an HTML response body at L12, already cleared"],"conclusion":"the validator clears the taint before the sink; the attack input cannot reach it unescaped."}}}
    ;

    var aw = std.Io.Writer.Allocating.init(allocator);
    defer aw.deinit();
    try writeProofCardFrame(allocator, &card, &aw.writer, .{ .width = 100, .proof_trace_json = trace_json });
    const out = aw.writer.buffered();

    try std.testing.expect(std.mem.indexOf(u8, out, "Resisted: the attack each proof defeats") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "+injection-safe") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "tried: 1; DROP TABLE users--") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "validated by schemaCompile() at L7") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "the validator clears the taint") != null);

    // Every rendered row still has identical visible width.
    var iter = std.mem.splitScalar(u8, out, '\n');
    while (iter.next()) |line| {
        if (line.len == 0) continue;
        try std.testing.expectEqual(@as(usize, 100), line.len);
    }
}

test "writeProofCardFrame: recompile_ms surfaces in properties header" {
    const allocator = std.testing.allocator;
    var current = try buildTestFacts(allocator);
    defer current.deinit(allocator);

    var delta = try review.deriveDelta(allocator, &current, null);
    defer delta.deinit(allocator);

    const card = ProofCard{
        .handler_path = "src/handler.ts",
        .service_name = "demo",
        .region = "us-east",
        .current = &current,
        .baseline = null,
        .delta = &delta,
    };

    var aw = std.Io.Writer.Allocating.init(allocator);
    defer aw.deinit();
    try writeProofCardFrame(allocator, &card, &aw.writer, .{ .recompile_ms = 145 });
    const out = aw.writer.buffered();

    try std.testing.expect(std.mem.indexOf(u8, out, "145ms recompile") != null);
}

test "writeProofCardFrame: renders Why row when a demoted property has a cause" {
    const allocator = std.testing.allocator;

    // Baseline: deterministic = true (proven). Current: deterministic = false
    // (regressed). Everything else stays equal so the only delta entry is the
    // deterministic demotion.
    var current = try buildTestFacts(allocator);
    defer current.deinit(allocator);
    var baseline = try buildTestFacts(allocator);
    defer baseline.deinit(allocator);
    current.properties.deterministic = false;
    baseline.properties.deterministic = true;

    var delta = try review.deriveDelta(allocator, &current, &baseline);
    defer delta.deinit(allocator);

    const causes = [_]review.PropertyCauseEntry{.{
        .field = "deterministic",
        .line = 14,
        .column = 9,
        .snippet = "Date.now()",
    }};

    const card = ProofCard{
        .handler_path = "src/handler.ts",
        .service_name = "demo",
        .region = "local",
        .current = &current,
        .baseline = &baseline,
        .delta = &delta,
        .property_causes = causes[0..],
    };

    var aw = std.Io.Writer.Allocating.init(allocator);
    defer aw.deinit();
    try writeProofCardFrame(allocator, &card, &aw.writer, .{});
    const out = aw.writer.buffered();

    try std.testing.expect(std.mem.indexOf(u8, out, "Why: -deterministic at src/handler.ts:14: Date.now()") != null);
}

test "writeProofCardFrame: no Why row when there are no demotions" {
    const allocator = std.testing.allocator;
    var current = try buildTestFacts(allocator);
    defer current.deinit(allocator);

    // No baseline -> empty delta -> no demotions.
    var delta = try review.deriveDelta(allocator, &current, null);
    defer delta.deinit(allocator);

    const causes = [_]review.PropertyCauseEntry{.{
        .field = "deterministic",
        .line = 14,
        .column = 9,
        .snippet = "Date.now()",
    }};

    const card = ProofCard{
        .handler_path = "src/handler.ts",
        .service_name = "demo",
        .region = "local",
        .current = &current,
        .baseline = null,
        .delta = &delta,
        .property_causes = causes[0..],
    };

    var aw = std.Io.Writer.Allocating.init(allocator);
    defer aw.deinit();
    try writeProofCardFrame(allocator, &card, &aw.writer, .{});
    const out = aw.writer.buffered();

    try std.testing.expect(std.mem.indexOf(u8, out, "Why:") == null);
}

test "writeProofCardFrame: demotion without a matching cause renders no Why row" {
    const allocator = std.testing.allocator;

    var current = try buildTestFacts(allocator);
    defer current.deinit(allocator);
    var baseline = try buildTestFacts(allocator);
    defer baseline.deinit(allocator);
    current.properties.deterministic = false;
    baseline.properties.deterministic = true;

    var delta = try review.deriveDelta(allocator, &current, &baseline);
    defer delta.deinit(allocator);

    const card = ProofCard{
        .handler_path = "src/handler.ts",
        .service_name = "demo",
        .region = "local",
        .current = &current,
        .baseline = &baseline,
        .delta = &delta,
        // property_causes intentionally empty.
    };

    var aw = std.Io.Writer.Allocating.init(allocator);
    defer aw.deinit();
    try writeProofCardFrame(allocator, &card, &aw.writer, .{});
    const out = aw.writer.buffered();

    try std.testing.expect(std.mem.indexOf(u8, out, "Why:") == null);
}

const TestDemote = enum { none, deterministic, input_validated };

/// Build a ProofCard around a freshly-derived demotion delta and render it,
/// returning the buffered TUI output for substring assertions. Passing
/// `.none` produces a clean first-deploy frame with no baseline.
fn renderForTest(
    allocator: std.mem.Allocator,
    demote: TestDemote,
    cx: ?review.CounterexamplePreview,
    out_aw: *std.Io.Writer.Allocating,
) !void {
    var current = try buildTestFacts(allocator);
    defer current.deinit(allocator);
    var baseline = try buildTestFacts(allocator);
    defer baseline.deinit(allocator);

    switch (demote) {
        .none => {},
        .deterministic => {
            current.properties.deterministic = false;
            baseline.properties.deterministic = true;
        },
        .input_validated => {
            current.properties.input_validated = false;
            baseline.properties.input_validated = true;
        },
    }

    const baseline_ptr: ?*const review.ReviewFacts =
        if (demote == .none) null else &baseline;

    var delta = try review.deriveDelta(allocator, &current, baseline_ptr);
    defer delta.deinit(allocator);

    const card = ProofCard{
        .handler_path = "src/handler.ts",
        .service_name = "demo",
        .region = "local",
        .current = &current,
        .baseline = baseline_ptr,
        .delta = &delta,
        .counterexample = cx,
    };

    try writeProofCardFrame(allocator, &card, &out_aw.writer, .{});
}

test "writeProofCardFrame: renders Counterexample block with suggestion and key hints" {
    const allocator = std.testing.allocator;
    const cx = review.CounterexamplePreview{
        .field = "deterministic",
        .label = "deterministic",
        .line = 14,
        .column = 9,
        .snippet = "Date.now()",
        .handler_path = "src/handler.ts",
        .suggestion = "remove Date.now() / Math.random() / performance.now() or move the call inside a `durable.step`.",
    };

    var aw = std.Io.Writer.Allocating.init(allocator);
    defer aw.deinit();
    try renderForTest(allocator, .deterministic, cx, &aw);
    const out = aw.writer.buffered();

    try std.testing.expect(std.mem.indexOf(u8, out, "Counterexample: -deterministic at src/handler.ts:14: Date.now()") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "why: remove Date.now()") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "[r] replay live") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "[s] pin as regression test") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "[a] ask expert to fix") != null);
}

test "writeProofCardFrame: omits Counterexample block when card has none" {
    const allocator = std.testing.allocator;
    var aw = std.Io.Writer.Allocating.init(allocator);
    defer aw.deinit();
    try renderForTest(allocator, .none, null, &aw);
    try std.testing.expect(std.mem.indexOf(u8, aw.writer.buffered(), "Counterexample:") == null);
}

test "writeProofCardFrame: Counterexample block includes failing request and replay diff when present" {
    const allocator = std.testing.allocator;
    const cx = review.CounterexamplePreview{
        .field = "input_validated",
        .label = "input-validated",
        .line = 18,
        .column = 12,
        .snippet = ".length",
        .handler_path = "src/handler.ts",
        .suggestion = "guard with `?.` or validate the input shape with zttp:validate.",
        .failing_request = .{ .method = "POST", .url = "/api/users", .body = "{\"name\":null}" },
        .previous_response = .{ .status = 201, .body = "{\"id\":\"u_abc\"}" },
        .current_response = .{ .status = 500, .body = "", .error_text = "cannot read length of undefined" },
    };

    var aw = std.Io.Writer.Allocating.init(allocator);
    defer aw.deinit();
    try renderForTest(allocator, .input_validated, cx, &aw);
    const out = aw.writer.buffered();

    try std.testing.expect(std.mem.indexOf(u8, out, "request: POST /api/users") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "previous build: 201  {\"id\":\"u_abc\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "this build    : crashed - cannot read length of undefined") != null);
}

test "writeProofCardFrame: two panes at every width, status bar rows keep the width" {
    const allocator = std.testing.allocator;
    var current = try buildTestFacts(allocator);
    defer current.deinit(allocator);

    var baseline = try buildTestFacts(allocator);
    defer baseline.deinit(allocator);

    var delta = try review.deriveDelta(allocator, &current, &baseline);
    defer delta.deinit(allocator);

    const card = ProofCard{
        .handler_path = "src/handler.ts",
        .service_name = "demo",
        .region = "us-east",
        .current = &current,
        .baseline = &baseline,
        .delta = &delta,
    };

    const widths = [_]u16{ 60, 100, 200 };
    for (widths) |width| {
        var aw = std.Io.Writer.Allocating.init(allocator);
        defer aw.deinit();
        try writeProofCardFrame(allocator, &card, &aw.writer, .{ .width = width });
        const out = aw.writer.buffered();

        var first_border = true;
        var iter = std.mem.splitScalar(u8, out, '\n');
        while (iter.next()) |line| {
            if (line.len == 0) continue;
            try std.testing.expectEqual(@as(usize, width), line.len);
            if (line[0] == '+') {
                // A border row holds exactly three corners: two panes.
                try std.testing.expectEqual(@as(usize, 3), std.mem.count(u8, line, "+"));
                first_border = false;
            }
        }
        try std.testing.expect(!first_border);
        try std.testing.expect(std.mem.indexOf(u8, out, "Baseline: sha-frame-test-12345678") != null);
    }
}
