//! The restriction gate: `zig build test-ts-restrictions`.
//!
//! `docs/ts-restrictions.md` is the authority for the source profile. This gate
//! fails when the compiler and that file disagree. It reads the file, runs each
//! probe of `ts_restrictions_probes.zig` through the real check, and compares
//! what the check reports with what the file says. The probe table holds
//! inputs only: every expected code comes from the file.
//!
//!   * A refusal row (`| Refused form | Code | Write instead |`) needs one
//!     refused probe for each backticked span of its form cell and one clean
//!     probe. A refused probe reports an error (or a warning that the row marks
//!     `(warning)`), every error code is in the row, and the probes together
//!     report every code of the row. A clean probe reports no error.
//!   * A gap row (`| Form | Observed result |`) names the codes that the
//!     compiler gives today, or says "Accepted". Its probes must match.
//!   * Censuses: every row has a probe and every probe has a row; every source
//!     refusing diagnostic kind is observed or has a row in
//!     `scripts/ts-restrictions-unprobed.allow`; every array and string member
//!     of the runtime is in "Admitted Members" or in a form cell; the ambient
//!     names and the limits equal the `meta` payload.
//!
//! `-- --list` prints one line for each probe. It changes no verdict.

const std = @import("std");
const zts = @import("zts");
const precompile = @import("precompile.zig");
const meta = @import("agent_protocol_meta.zig");
const probes = @import("ts_restrictions_probes.zig");
const doc_options = @import("ts_restrictions_doc");
const allow_options = @import("ts_restrictions_allow");

const Source = probes.Source;

// ---------------------------------------------------------------------------
// The document
// ---------------------------------------------------------------------------

/// A code of a "Code" cell, with the severity that the probes must report.
pub const Code = struct { code: []const u8, severity: Severity = .err };

pub const RefusalDoc = struct {
    key: []const u8,
    spans: []const []const u8,
    codes: []const Code,
};

pub const GapDoc = struct {
    key: []const u8,
    /// Empty when the observation names no code ("Accepted ...").
    codes: []const []const u8,
    /// The code and the form that the compiler must give. The gate checks only
    /// that the cell is not empty: a fix moves the row to a refusal table.
    required: []const u8,
};

pub const AdmittedLine = struct {
    scope: []const u8,
    members: []const []const u8,
};

pub const LimitDoc = struct { label: []const u8, value: u64 };

pub const Doc = struct {
    refusals: []const RefusalDoc,
    gaps: []const GapDoc,
    admitted: []const AdmittedLine,
    ambient: []const []const u8,
    limits: []const LimitDoc,
    /// The backticked spans of every refusal and gap form cell.
    form_spans: []const []const u8,
    /// The backticked spans of every gap form cell.
    gap_spans: []const []const u8,
};

const refusal_header = [_][]const u8{ "Refused form", "Code", "Write instead" };
const gap_header = [_][]const u8{ "Form", "Observed result", "Required" };
const limit_header = [_][]const u8{ "Limit", "Value" };

/// Split a table line into trimmed cells. A `\|` does not split, and it reads
/// as `|` in the cell.
fn splitCells(a: std.mem.Allocator, line: []const u8) ![]const []const u8 {
    var cells: std.ArrayList([]const u8) = .empty;
    errdefer cells.deinit(a);
    var text = std.mem.trim(u8, line, " \t\r");
    if (text.len != 0 and text[0] == '|') text = text[1..];
    if (text.len != 0 and text[text.len - 1] == '|' and !(text.len >= 2 and text[text.len - 2] == '\\')) text = text[0 .. text.len - 1];
    var cell: std.ArrayList(u8) = .empty;
    defer cell.deinit(a);
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (text[i] == '\\' and i + 1 < text.len and text[i + 1] == '|') {
            try cell.append(a, '|');
            i += 1;
        } else if (text[i] == '|') {
            try cells.append(a, try a.dupe(u8, std.mem.trim(u8, cell.items, " \t")));
            cell.clearRetainingCapacity();
        } else {
            try cell.append(a, text[i]);
        }
    }
    try cells.append(a, try a.dupe(u8, std.mem.trim(u8, cell.items, " \t")));
    return cells.toOwnedSlice(a);
}

/// The Markdown code spans of `text`. A run of backticks opens a span and the
/// next run of the same length closes it, so a span can hold a backtick.
fn codeSpans(a: std.mem.Allocator, text: []const u8) ![]const []const u8 {
    var spans: std.ArrayList([]const u8) = .empty;
    errdefer spans.deinit(a);
    var i: usize = 0;
    while (i < text.len) {
        if (text[i] != '`') {
            i += 1;
            continue;
        }
        var run: usize = 0;
        while (i + run < text.len and text[i + run] == '`') run += 1;
        const start = i + run;
        var j = start;
        var close: ?usize = null;
        while (j < text.len) {
            if (text[j] != '`') {
                j += 1;
                continue;
            }
            var n: usize = 0;
            while (j + n < text.len and text[j + n] == '`') n += 1;
            if (n == run) {
                close = j;
                break;
            }
            j += n;
        }
        const end = close orelse return error.UnclosedCodeSpan;
        try spans.append(a, try a.dupe(u8, std.mem.trim(u8, text[start..end], " ")));
        i = end + run;
    }
    return spans.toOwnedSlice(a);
}

fn isCode(token: []const u8) bool {
    if (token.len != 6 or !std.mem.startsWith(u8, token, "ZTS")) return false;
    for (token[3..]) |ch| {
        if (ch < '0' or ch > '9') return false;
    }
    return true;
}

/// The codes of a "Code" cell: `ZTS001`, `ZTS308, ZTS309`, `ZTS216 (warning)`,
/// `ZTS625 (advisory)`. An advisory never fails a build (spec 4.2.1).
fn parseCodeCell(a: std.mem.Allocator, cell: []const u8) ![]const Code {
    var codes: std.ArrayList(Code) = .empty;
    errdefer codes.deinit(a);
    var parts = std.mem.splitScalar(u8, cell, ',');
    while (parts.next()) |raw| {
        const part = std.mem.trim(u8, raw, " ");
        const word_end = std.mem.indexOfScalar(u8, part, ' ') orelse part.len;
        const word = part[0..word_end];
        if (!isCode(word)) return error.BadCodeCell;
        const rest = std.mem.trim(u8, part[word_end..], " ");
        const severity: Severity = if (rest.len == 0)
            .err
        else if (std.mem.eql(u8, rest, "(warning)"))
            .warning
        else if (std.mem.eql(u8, rest, "(advisory)"))
            .other
        else
            return error.BadCodeCell;
        try codes.append(a, .{ .code = word, .severity = severity });
    }
    return codes.toOwnedSlice(a);
}

fn severityName(severity: Severity) []const u8 {
    return switch (severity) {
        .err => "error",
        .warning => "warning",
        .other => "advisory",
    };
}

/// The codes of an "Observed result" cell: every code in its first sentence.
fn parseObservedCodes(a: std.mem.Allocator, cell: []const u8) ![]const []const u8 {
    var end = cell.len;
    var k: usize = 0;
    while (k < cell.len) : (k += 1) {
        if (cell[k] == '.' and (k + 1 == cell.len or cell[k + 1] == ' ')) {
            end = k;
            break;
        }
    }
    var codes: std.ArrayList([]const u8) = .empty;
    errdefer codes.deinit(a);
    var i: usize = 0;
    const sentence = cell[0..end];
    while (i + 6 <= sentence.len) : (i += 1) {
        if (!isCode(sentence[i .. i + 6])) continue;
        if (i + 6 < sentence.len and sentence[i + 6] >= '0' and sentence[i + 6] <= '9') continue;
        try codes.append(a, sentence[i .. i + 6]);
        i += 5;
    }
    return codes.toOwnedSlice(a);
}

fn headerIs(cells: []const []const u8, expected: []const []const u8) bool {
    if (cells.len != expected.len) return false;
    for (cells, expected) |cell, want| {
        if (!std.mem.eql(u8, cell, want)) return false;
    }
    return true;
}

fn leadingInteger(text: []const u8) !u64 {
    var end: usize = 0;
    while (end < text.len and text[end] >= '0' and text[end] <= '9') end += 1;
    if (end == 0) return error.BadLimitValue;
    return std.fmt.parseInt(u64, text[0..end], 10);
}

/// Read `text`. Slices point into `a`.
pub fn parseDoc(a: std.mem.Allocator, text: []const u8) !Doc {
    var refusals: std.ArrayList(RefusalDoc) = .empty;
    var gaps: std.ArrayList(GapDoc) = .empty;
    var admitted: std.ArrayList(AdmittedLine) = .empty;
    var limits: std.ArrayList(LimitDoc) = .empty;
    var form_spans: std.ArrayList([]const u8) = .empty;
    var gap_spans: std.ArrayList([]const u8) = .empty;
    var ambient: []const []const u8 = &.{};

    var lines: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| try lines.append(a, std.mem.trimEnd(u8, line, "\r"));

    var section: []const u8 = "";
    var i: usize = 0;
    while (i < lines.items.len) : (i += 1) {
        const line = lines.items[i];
        if (std.mem.startsWith(u8, line, "## ")) {
            section = std.mem.trim(u8, line[3..], " ");
            continue;
        }
        if (std.mem.eql(u8, section, "Admitted Members") and line.len != 0) {
            const spans = try codeSpans(a, line);
            if (spans.len != 0 and std.mem.endsWith(u8, spans[0], ".prototype")) {
                try admitted.append(a, .{ .scope = spans[0], .members = spans[1..] });
            }
            continue;
        }
        if (std.mem.eql(u8, section, "Ambient Names And Effects") and
            std.mem.indexOf(u8, line, "The closed ambient value namespace is:") != null)
        {
            var paragraph: std.ArrayList(u8) = .empty;
            var j = i;
            while (j < lines.items.len and lines.items[j].len != 0) : (j += 1) {
                try paragraph.appendSlice(a, lines.items[j]);
                try paragraph.append(a, ' ');
            }
            const marker = "namespace is:";
            const start = (std.mem.indexOf(u8, paragraph.items, marker) orelse return error.BadAmbientList) + marker.len;
            const stop = std.mem.indexOfPos(u8, paragraph.items, start, ".") orelse return error.BadAmbientList;
            ambient = try codeSpans(a, paragraph.items[start..stop]);
            i = j;
            continue;
        }
        if (line.len == 0 or line[0] != '|') continue;

        // A table: the header, the separator, then rows to the first non-row.
        const header = try splitCells(a, line);
        var end = i + 1;
        while (end < lines.items.len and lines.items[end].len != 0 and lines.items[end][0] == '|') end += 1;
        defer i = end - 1;
        const rows = if (i + 2 <= end) lines.items[i + 2 .. end] else lines.items[0..0];

        if (headerIs(header, &refusal_header)) {
            for (rows) |row_line| {
                const cells = try splitCells(a, row_line);
                if (cells.len != 3) return error.BadRefusalRow;
                const spans = try codeSpans(a, cells[0]);
                try form_spans.appendSlice(a, spans);
                try refusals.append(a, .{ .key = cells[0], .spans = spans, .codes = try parseCodeCell(a, cells[1]) });
            }
        } else if (headerIs(header, &gap_header) and std.mem.startsWith(u8, section, "Spec Rules That")) {
            for (rows) |row_line| {
                const cells = try splitCells(a, row_line);
                if (cells.len != 3) return error.BadGapRow;
                const spans = try codeSpans(a, cells[0]);
                try form_spans.appendSlice(a, spans);
                try gap_spans.appendSlice(a, spans);
                try gaps.append(a, .{ .key = cells[0], .codes = try parseObservedCodes(a, cells[1]), .required = cells[2] });
            }
        } else if (headerIs(header, &limit_header) and std.mem.eql(u8, section, "Limits")) {
            for (rows) |row_line| {
                const cells = try splitCells(a, row_line);
                if (cells.len != 2) return error.BadLimitRow;
                try limits.append(a, .{ .label = cells[0], .value = try leadingInteger(cells[1]) });
            }
        }
    }
    return .{
        .refusals = try refusals.toOwnedSlice(a),
        .gaps = try gaps.toOwnedSlice(a),
        .admitted = try admitted.toOwnedSlice(a),
        .ambient = ambient,
        .limits = try limits.toOwnedSlice(a),
        .form_spans = try form_spans.toOwnedSlice(a),
        .gap_spans = try gap_spans.toOwnedSlice(a),
    };
}

// ---------------------------------------------------------------------------
// The check
// ---------------------------------------------------------------------------

pub const Severity = enum { err, warning, other };

pub const Diag = struct { code: []const u8, severity: Severity };

/// Run one probe. The diagnostics and their strings live in `a`.
pub const CheckFn = *const fn (a: std.mem.Allocator, source: Source) anyerror![]const Diag;

const virtual_dir = "/ts-restrictions-probe";

const FileReader = struct {
    files: []const probes.File,

    fn read(context: *anyopaque, allocator: std.mem.Allocator, path: []const u8) anyerror![]u8 {
        const self: *FileReader = @ptrCast(@alignCast(context));
        const base = std.fs.path.basename(path);
        for (self.files) |file| {
            if (std.mem.eql(u8, file.name, base)) return allocator.dupe(u8, file.text);
        }
        return error.FileNotFound;
    }
};

fn realCheck(a: std.mem.Allocator, source: Source) anyerror![]const Diag {
    var reader: FileReader = .{ .files = source.files };
    const path = try std.fs.path.join(a, &.{ virtual_dir, source.path });
    var result = try precompile.runCheckOnlyFromSourceWithOptions(a, source.text, path, .{
        .json_mode = true,
        .import_reader = .{ .context = &reader, .read = FileReader.read },
    });
    defer result.deinit(a);
    if (result.analyzer_error) |err| return err;
    var out: std.ArrayList(Diag) = .empty;
    for (result.json_diagnostics.items) |d| {
        const severity: Severity = if (std.mem.eql(u8, d.severity, "error"))
            .err
        else if (std.mem.eql(u8, d.severity, "warning"))
            .warning
        else
            .other;
        try out.append(a, .{ .code = try a.dupe(u8, d.code), .severity = severity });
    }
    return out.toOwnedSlice(a);
}

// ---------------------------------------------------------------------------
// The registries
// ---------------------------------------------------------------------------

pub const Member = struct { scope: []const u8, name: []const u8 };
pub const Limit = struct { label: []const u8, value: u64 };

pub const Registry = struct {
    /// The codes of every source-refusing diagnostic kind, without repeats.
    kind_codes: []const []const u8,
    members: []const Member,
    ambient: []const []const u8,
    limits: []const Limit,
};

// ---------------------------------------------------------------------------
// The report
// ---------------------------------------------------------------------------

pub const Report = struct {
    arena: std.heap.ArenaAllocator,
    failures: std.ArrayList([]const u8) = .empty,
    probes_run: usize = 0,
    rows_checked: usize = 0,
    lines: std.ArrayList([]const u8) = .empty,

    pub fn init(gpa: std.mem.Allocator) Report {
        return .{ .arena = std.heap.ArenaAllocator.init(gpa) };
    }

    pub fn deinit(self: *Report) void {
        self.arena.deinit();
    }

    fn fail(self: *Report, comptime fmt: []const u8, args: anytype) !void {
        const a = self.arena.allocator();
        try self.failures.append(a, try a.print(fmt, args));
    }

    fn note(self: *Report, comptime fmt: []const u8, args: anytype) !void {
        const a = self.arena.allocator();
        try self.lines.append(a, try a.print(fmt, args));
    }
};

const Run = struct {
    errors: []const []const u8,
    warnings: []const []const u8,
    advisories: []const []const u8,
    all: []const []const u8,
    /// The check could not run the probe.
    crashed: ?anyerror,
};

fn runProbe(report: *Report, check: CheckFn, source: Source) !Run {
    const a = report.arena.allocator();
    report.probes_run += 1;
    const diags = check(a, source) catch |err| return .{ .errors = &.{}, .warnings = &.{}, .advisories = &.{}, .all = &.{}, .crashed = err };
    var errors: std.ArrayList([]const u8) = .empty;
    var warnings: std.ArrayList([]const u8) = .empty;
    var advisories: std.ArrayList([]const u8) = .empty;
    var all: std.ArrayList([]const u8) = .empty;
    for (diags) |d| {
        try all.append(a, d.code);
        switch (d.severity) {
            .err => try errors.append(a, d.code),
            .warning => try warnings.append(a, d.code),
            .other => try advisories.append(a, d.code),
        }
    }
    return .{
        .errors = try errors.toOwnedSlice(a),
        .warnings = try warnings.toOwnedSlice(a),
        .advisories = try advisories.toOwnedSlice(a),
        .all = try all.toOwnedSlice(a),
        .crashed = null,
    };
}

fn contains(haystack: []const []const u8, needle: []const u8) bool {
    for (haystack) |item| {
        if (std.mem.eql(u8, item, needle)) return true;
    }
    return false;
}

fn appendUnique(a: std.mem.Allocator, list: *std.ArrayList([]const u8), item: []const u8) !void {
    if (!contains(list.items, item)) try list.append(a, item);
}

fn joinCodes(a: std.mem.Allocator, codes: []const []const u8) ![]const u8 {
    if (codes.len == 0) return "none";
    return std.mem.join(a, ", ", codes);
}

fn codeSet(a: std.mem.Allocator, codes: []const Code) ![]const u8 {
    var names: std.ArrayList([]const u8) = .empty;
    for (codes) |code| try names.append(a, code.code);
    return joinCodes(a, names.items);
}

// ---------------------------------------------------------------------------
// The gate
// ---------------------------------------------------------------------------

pub const Inputs = struct {
    doc: []const u8,
    allow: []const u8,
    refusal_probes: []const probes.RefusalRow,
    gap_probes: []const probes.GapRow,
    check: CheckFn,
    registry: Registry,
    list: bool = false,
};

fn findRefusalProbe(rows: []const probes.RefusalRow, key: []const u8) ?probes.RefusalRow {
    for (rows) |row| {
        if (std.mem.eql(u8, row.key, key)) return row;
    }
    return null;
}

fn findGapProbe(rows: []const probes.GapRow, key: []const u8) ?probes.GapRow {
    for (rows) |row| {
        if (std.mem.eql(u8, row.key, key)) return row;
    }
    return null;
}

fn sourceLabel(source: Source) []const u8 {
    return source.path;
}

pub fn runGate(gpa: std.mem.Allocator, inputs: Inputs) !Report {
    var report = Report.init(gpa);
    errdefer report.deinit();
    const a = report.arena.allocator();
    const doc = try parseDoc(a, inputs.doc);

    var observed: std.ArrayList([]const u8) = .empty;

    try checkRefusalRows(&report, doc, inputs, &observed);
    try checkGapRows(&report, doc, inputs, &observed);
    try checkKinds(&report, inputs, observed.items);
    try checkAdmitted(&report, doc, inputs.registry.members);
    try checkMemberReads(&report, doc, inputs);
    try checkAmbient(&report, doc, inputs.registry.ambient);
    try checkLimits(&report, doc, inputs.registry.limits);
    return report;
}

fn checkRefusalRows(report: *Report, doc: Doc, inputs: Inputs, observed: *std.ArrayList([]const u8)) !void {
    const a = report.arena.allocator();
    for (doc.refusals, 0..) |row, index| {
        report.rows_checked += 1;
        for (doc.refusals[0..index]) |earlier| {
            if (std.mem.eql(u8, earlier.key, row.key)) {
                try report.fail("refusal row \"{s}\": the document has this form cell twice", .{row.key});
            }
        }
        const probe_row = findRefusalProbe(inputs.refusal_probes, row.key) orelse {
            try report.fail("refusal row \"{s}\": no probe row", .{row.key});
            continue;
        };
        try checkSpanTags(report, row, probe_row);

        var seen_errors: std.ArrayList([]const u8) = .empty;
        var seen_warnings: std.ArrayList([]const u8) = .empty;
        var seen_advisories: std.ArrayList([]const u8) = .empty;
        const row_codes = try codeSet(a, row.codes);
        for (probe_row.refused) |refusal| {
            const run = try runProbe(report, inputs.check, refusal.source);
            if (inputs.list) try report.note("refused  {s} [{s}] {s}: errors={s} warnings={s}", .{ row.key, refusal.span, sourceLabel(refusal.source), try joinCodes(a, run.errors), try joinCodes(a, run.warnings) });
            if (run.crashed) |err| {
                try report.fail("refusal row \"{s}\" [{s}]: the check failed with {s}", .{ row.key, refusal.span, @errorName(err) });
                continue;
            }
            for (run.all) |code| try appendUnique(a, observed, code);
            var refused = run.errors.len != 0;
            for (run.warnings) |code| {
                if (rowHasCodeAt(row, code, .warning)) refused = true;
            }
            for (run.advisories) |code| {
                if (rowHasCodeAt(row, code, .other)) refused = true;
            }
            if (!refused) {
                try report.fail("refusal row \"{s}\" [{s}]: the probe reports no error (codes in the document: {s}; reported: {s})", .{ row.key, refusal.span, row_codes, try joinCodes(a, run.all) });
            }
            for (run.errors) |code| {
                try appendUnique(a, &seen_errors, code);
                if (!rowHasCodeAt(row, code, .err)) {
                    try report.fail("refusal row \"{s}\" [{s}]: the probe reports error {s}, which is not in the row ({s})", .{ row.key, refusal.span, code, row_codes });
                }
            }
            for (run.warnings) |code| try appendUnique(a, &seen_warnings, code);
            for (run.advisories) |code| try appendUnique(a, &seen_advisories, code);
        }
        for (row.codes) |code| {
            const seen = switch (code.severity) {
                .err => seen_errors.items,
                .warning => seen_warnings.items,
                .other => seen_advisories.items,
            };
            if (!contains(seen, code.code)) {
                try report.fail("refusal row \"{s}\": no probe reports {s} at {s} severity", .{ row.key, code.code, severityName(code.severity) });
            }
        }

        const run = try runProbe(report, inputs.check, probe_row.clean);
        if (inputs.list) try report.note("clean    {s}: errors={s}", .{ row.key, try joinCodes(a, run.errors) });
        if (run.crashed) |err| {
            try report.fail("refusal row \"{s}\": the clean probe failed with {s}", .{ row.key, @errorName(err) });
        } else if (run.errors.len != 0) {
            try report.fail("refusal row \"{s}\": the clean probe of the \"Write instead\" form reports {s}", .{ row.key, try joinCodes(a, run.errors) });
        }
    }
    for (inputs.refusal_probes, 0..) |probe_row, index| {
        for (inputs.refusal_probes[0..index]) |earlier| {
            if (std.mem.eql(u8, earlier.key, probe_row.key)) try report.fail("probe key \"{s}\": two probe rows have this key", .{probe_row.key});
        }
        var matched = false;
        for (doc.refusals) |row| {
            if (std.mem.eql(u8, row.key, probe_row.key)) matched = true;
        }
        if (!matched) try report.fail("probe key \"{s}\": no refusal row has this form cell", .{probe_row.key});
    }
}

fn rowHasCodeAt(row: RefusalDoc, code: []const u8, severity: Severity) bool {
    for (row.codes) |c| {
        if (c.severity == severity and std.mem.eql(u8, c.code, code)) return true;
    }
    return false;
}

/// The span tags of a row's refused probes must be the spans of its form cell.
fn checkSpanTags(report: *Report, row: RefusalDoc, probe_row: probes.RefusalRow) !void {
    if (probe_row.refused.len == 0) try report.fail("refusal row \"{s}\": no refused probe", .{row.key});
    if (row.spans.len == 0) {
        for (probe_row.refused) |refusal| {
            if (refusal.span.len != 0) try report.fail("refusal row \"{s}\": the form cell has no span, and a probe is tagged \"{s}\"", .{ row.key, refusal.span });
        }
        return;
    }
    for (row.spans) |span| {
        var found = false;
        for (probe_row.refused) |refusal| {
            if (std.mem.eql(u8, refusal.span, span)) found = true;
        }
        if (!found) try report.fail("refusal row \"{s}\": no refused probe for the span `{s}`", .{ row.key, span });
    }
    for (probe_row.refused) |refusal| {
        if (!contains(row.spans, refusal.span)) try report.fail("refusal row \"{s}\": a probe is tagged `{s}`, which is not a span of the form cell", .{ row.key, refusal.span });
    }
}

fn checkGapRows(report: *Report, doc: Doc, inputs: Inputs, observed: *std.ArrayList([]const u8)) !void {
    const a = report.arena.allocator();
    for (doc.gaps, 0..) |row, index| {
        report.rows_checked += 1;
        for (doc.gaps[0..index]) |earlier| {
            if (std.mem.eql(u8, earlier.key, row.key)) try report.fail("gap row \"{s}\": the document has this form cell twice", .{row.key});
        }
        const probe_row = findGapProbe(inputs.gap_probes, row.key) orelse {
            try report.fail("gap row \"{s}\": no probe row", .{row.key});
            continue;
        };
        if (probe_row.sources.len == 0) try report.fail("gap row \"{s}\": no probe", .{row.key});
        if (row.required.len == 0) try report.fail("gap row \"{s}\": the Required cell is empty", .{row.key});
        const expected = try joinCodes(a, row.codes);
        var seen: std.ArrayList([]const u8) = .empty;
        for (probe_row.sources) |source| {
            const run = try runProbe(report, inputs.check, source);
            if (inputs.list) try report.note("gap      {s}: errors={s} warnings={s}", .{ row.key, try joinCodes(a, run.errors), try joinCodes(a, run.warnings) });
            if (run.crashed) |err| {
                try report.fail("gap row \"{s}\": the check failed with {s}", .{ row.key, @errorName(err) });
                continue;
            }
            for (run.all) |code| try appendUnique(a, observed, code);
            if (row.codes.len == 0) {
                if (run.errors.len != 0) try report.fail("gap row \"{s}\": the document says the form is accepted, and the probe reports {s}", .{ row.key, try joinCodes(a, run.errors) });
                continue;
            }
            for (run.errors) |code| {
                try appendUnique(a, &seen, code);
                if (!contains(row.codes, code)) try report.fail("gap row \"{s}\": the probe reports error {s}, and the document says {s}", .{ row.key, code, expected });
            }
            if (run.errors.len == 0) try report.fail("gap row \"{s}\": the document says {s}, and the probe reports no error", .{ row.key, expected });
        }
        for (row.codes) |code| {
            if (!contains(seen.items, code)) try report.fail("gap row \"{s}\": no probe reports {s}", .{ row.key, code });
        }
    }
    for (inputs.gap_probes, 0..) |probe_row, index| {
        for (inputs.gap_probes[0..index]) |earlier| {
            if (std.mem.eql(u8, earlier.key, probe_row.key)) try report.fail("gap probe key \"{s}\": two probe rows have this key", .{probe_row.key});
        }
        var matched = false;
        for (doc.gaps) |row| {
            if (std.mem.eql(u8, row.key, probe_row.key)) matched = true;
        }
        if (!matched) try report.fail("gap probe key \"{s}\": no gap row has this form", .{probe_row.key});
    }
}

/// A row of the allowlist: a code and the reason that no probe reaches it.
const AllowRow = struct { code: []const u8, reason: []const u8 };

fn parseAllow(a: std.mem.Allocator, text: []const u8) ![]const AllowRow {
    var rows: std.ArrayList(AllowRow) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        const space = std.mem.indexOfScalar(u8, line, ' ') orelse line.len;
        try rows.append(a, .{ .code = line[0..space], .reason = std.mem.trim(u8, line[space..], " ") });
    }
    return rows.toOwnedSlice(a);
}

fn checkKinds(report: *Report, inputs: Inputs, observed: []const []const u8) !void {
    const a = report.arena.allocator();
    const allow = try parseAllow(a, inputs.allow);
    for (allow) |row| {
        if (row.reason.len == 0) try report.fail("allowlist row {s}: the row states no reason", .{row.code});
        if (!contains(inputs.registry.kind_codes, row.code)) try report.fail("allowlist row {s}: no source-refusing diagnostic kind has this code", .{row.code});
        if (contains(observed, row.code)) try report.fail("allowlist row {s}: a probe now observes this code, so delete the row", .{row.code});
    }
    for (inputs.registry.kind_codes) |code| {
        if (contains(observed, code)) continue;
        var allowed = false;
        for (allow) |row| {
            if (std.mem.eql(u8, row.code, code)) allowed = true;
        }
        if (!allowed) try report.fail("diagnostic kind {s}: no refused probe observes it, and the allowlist has no row for it", .{code});
    }
}

/// A handler that reads `member` off a value of its scope. A read of an
/// admitted member type-checks; a read of any other member is ZTS201.
fn memberRead(a: std.mem.Allocator, member: Member) ![]const u8 {
    const value = if (std.mem.eql(u8, member.scope, "Array.prototype"))
        "const xs: number[] = [1, 2];\n  const f = xs."
    else
        "const s: string = \"a\";\n  const f = s.";
    return std.mem.concat(a, u8, &.{
        "export function handler(req: Request): Proof<Response, \"no_secret_leakage\"> {\n  ",
        value,
        member.name,
        ";\n  return Response.text(\"ok\");\n}\n",
    });
}

fn isAdmitted(doc: Doc, member: Member) bool {
    for (doc.admitted) |line| {
        if (std.mem.eql(u8, line.scope, member.scope) and contains(line.members, member.name)) return true;
    }
    return false;
}

/// Read each runtime member through the real check. An admitted member must be
/// accepted. Any other member must be refused, unless a gap row names it.
fn checkMemberReads(report: *Report, doc: Doc, inputs: Inputs) !void {
    const a = report.arena.allocator();
    for (inputs.registry.members) |m| {
        const admitted = isAdmitted(doc, m);
        if (!admitted and contains(doc.gap_spans, m.name)) continue;
        const run = try runProbe(report, inputs.check, .{ .text = try memberRead(a, m) });
        if (run.crashed) |err| {
            try report.fail("member {s}.{s}: the check of a read failed with {s}", .{ m.scope, m.name, @errorName(err) });
        } else if (admitted and run.errors.len != 0) {
            try report.fail("Admitted Members {s}: a read of `{s}` reports {s}", .{ m.scope, m.name, try joinCodes(a, run.errors) });
        } else if (!admitted and run.errors.len == 0) {
            try report.fail("member {s}.{s}: a read is accepted, and the document does not admit it", .{ m.scope, m.name });
        }
    }
}

fn checkAdmitted(report: *Report, doc: Doc, members: []const Member) !void {
    for (doc.admitted) |line| {
        for (line.members, 0..) |name, index| {
            if (index != 0 and !std.mem.lessThan(u8, line.members[index - 1], name)) {
                try report.fail("Admitted Members {s}: `{s}` is not in sorted order after `{s}`", .{ line.scope, name, line.members[index - 1] });
            }
            var known = false;
            for (members) |m| {
                if (std.mem.eql(u8, m.scope, line.scope) and std.mem.eql(u8, m.name, name)) known = true;
            }
            if (!known) try report.fail("Admitted Members {s}: `{s}` is not a member of the runtime", .{ line.scope, name });
        }
    }
    for (members) |m| {
        var covered = contains(doc.form_spans, m.name);
        for (doc.admitted) |line| {
            if (std.mem.eql(u8, line.scope, m.scope) and contains(line.members, m.name)) covered = true;
        }
        if (!covered) try report.fail("member {s}.{s}: not in Admitted Members, and no refusal or gap row names it", .{ m.scope, m.name });
    }
}

fn checkAmbient(report: *Report, doc: Doc, registry: []const []const u8) !void {
    for (doc.ambient) |name| {
        if (!contains(registry, name)) try report.fail("ambient name `{s}`: the document lists it, and the meta payload does not", .{name});
    }
    for (registry) |name| {
        if (!contains(doc.ambient, name)) try report.fail("ambient name `{s}`: the meta payload lists it, and the document does not", .{name});
    }
    if (doc.ambient.len == 0) try report.fail("the document lists no ambient names", .{});
}

fn checkLimits(report: *Report, doc: Doc, registry: []const Limit) !void {
    for (doc.limits) |row| {
        var found = false;
        for (registry) |limit| {
            if (!std.mem.eql(u8, limit.label, row.label)) continue;
            found = true;
            if (limit.value != row.value) try report.fail("limit \"{s}\": the document says {d}, and the meta payload says {d}", .{ row.label, row.value, limit.value });
        }
        if (!found) try report.fail("limit \"{s}\": the meta payload has no such limit", .{row.label});
    }
    for (registry) |limit| {
        var found = false;
        for (doc.limits) |row| {
            if (std.mem.eql(u8, limit.label, row.label)) found = true;
        }
        if (!found) try report.fail("limit \"{s}\": the meta payload has it, and the document has no row", .{limit.label});
    }
}

// ---------------------------------------------------------------------------
// The real registries
// ---------------------------------------------------------------------------

/// The doc label of each field of the `meta` payload's `limits` object. The
/// type serialization depth is in `type_serialization`, not in `limits`.
const limit_labels = [_]struct { field: []const u8, label: []const u8 }{
    .{ .field = "source_bytes", .label = "Source file size" },
    .{ .field = "request_bytes", .label = "Request size" },
    .{ .field = "module_graph_modules", .label = "Modules in one module graph" },
    .{ .field = "normalize_iterations", .label = "Normalization iterations" },
    .{ .field = "type_parameters", .label = "Type parameters in one generic declaration" },
};
const depth_label = "Type serialization depth";

fn integerOf(value: ?std.json.Value) !u64 {
    const v = value orelse return error.MissingMetaField;
    return switch (v) {
        .integer => |n| @intCast(n),
        else => error.MissingMetaField,
    };
}

fn realRegistry(a: std.mem.Allocator, gpa: std.mem.Allocator) !Registry {
    // Kinds that refuse source: the parser, the type stripper, the type
    // checker, and the strict checker.
    var codes: std.ArrayList([]const u8) = .empty;
    for (zts.DiagnosticCatalog.entries()) |entry| {
        switch (entry.producer) {
            .parser, .type_stripper, .type_checker, .strict_checker => try appendUnique(a, &codes, entry.code),
            else => {},
        }
    }

    // The runtime registry behind the type checker's member tables.
    var gc_state = try zts.GC.init(a, .{ .nursery_size = 4096 });
    defer gc_state.deinit();
    const ctx = try zts.Context.init(a, &gc_state, .{});
    defer ctx.deinit();
    try zts.initBuiltins(ctx);
    const pool = ctx.hidden_class_pool orelse return error.NoHiddenClassPool;
    var members: std.ArrayList(Member) = .empty;
    const holders = [_]struct { scope: []const u8, holder: ?*zts.JSObject }{
        .{ .scope = "Array.prototype", .holder = ctx.array_prototype },
        .{ .scope = "String.prototype", .holder = ctx.string_prototype },
    };
    for (holders) |entry| {
        const holder = entry.holder orelse return error.NoPrototype;
        var it = holder.propertyIterator(pool);
        while (it.next()) |prop| {
            // The atoms 0xFFFE and 0xFFFF are hidden-class sentinels.
            if (@as(u32, @backingInt(prop.atom)) >= 0xFFFE) continue;
            const name = prop.atom.toPredefinedName() orelse ctx.atoms.getName(prop.atom) orelse return error.UnnamedProperty;
            try members.append(a, .{ .scope = entry.scope, .name = try a.dupe(u8, name) });
        }
        // `length` is a property read, not an own property of the prototype.
        try members.append(a, .{ .scope = entry.scope, .name = "length" });
    }

    // The ambient names and the limits come from the `meta` payload.
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var json: std.json.Stringify = .{ .writer = &out.writer };
    _ = try meta.writeMetaPayload(&json, .full);
    const parsed = try std.json.parseFromSlice(std.json.Value, a, out.written(), .{});
    const payload = parsed.value.object;

    var ambient: std.ArrayList([]const u8) = .empty;
    const values = (payload.get("ambient_names") orelse return error.MissingMetaField).object.get("values") orelse return error.MissingMetaField;
    for (values.array.items) |item| try ambient.append(a, item.string);

    var limits: std.ArrayList(Limit) = .empty;
    const limit_object = (payload.get("limits") orelse return error.MissingMetaField).object;
    var field_it = limit_object.iterator();
    while (field_it.next()) |field| {
        var label: ?[]const u8 = null;
        for (limit_labels) |known| {
            if (std.mem.eql(u8, known.field, field.key_ptr.*)) label = known.label;
        }
        const found = label orelse {
            std.debug.print("ts restrictions: the meta payload has a limit `{s}` with no label in the gate\n", .{field.key_ptr.*});
            return error.UnlabelledLimit;
        };
        try limits.append(a, .{ .label = found, .value = try integerOf(field.value_ptr.*) });
    }
    const serialization = (payload.get("type_serialization") orelse return error.MissingMetaField).object;
    try limits.append(a, .{ .label = depth_label, .value = try integerOf(serialization.get("max_depth")) });

    return .{
        .kind_codes = try codes.toOwnedSlice(a),
        .members = try members.toOwnedSlice(a),
        .ambient = try ambient.toOwnedSlice(a),
        .limits = try limits.toOwnedSlice(a),
    };
}

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

pub fn main(init: std.process.Init) void {
    runGateMain(init) catch |err| {
        if (err != error.GateFailed and err != error.InvalidArguments) {
            std.debug.print("ts restrictions: {s}\n", .{@errorName(err)});
        }
        std.process.exit(1);
    };
}

fn runGateMain(init: std.process.Init) !void {
    const gpa = init.gpa;
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, gpa);
    defer args.deinit();
    _ = args.next();
    var list = false;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--list")) {
            list = true;
        } else {
            std.debug.print("usage: ts-restrictions-gate [--list]\n", .{});
            return error.InvalidArguments;
        }
    }

    var registry_arena = std.heap.ArenaAllocator.init(gpa);
    defer registry_arena.deinit();
    const registry = try realRegistry(registry_arena.allocator(), gpa);

    var report = try runGate(gpa, .{
        .doc = doc_options.contents,
        .allow = allow_options.contents,
        .refusal_probes = &probes.refusal_rows,
        .gap_probes = &probes.gap_rows,
        .check = realCheck,
        .registry = registry,
        .list = list,
    });
    defer report.deinit();
    for (report.lines.items) |line| std.debug.print("{s}\n", .{line});
    for (report.failures.items) |failure| std.debug.print("ts restrictions: FAIL {s}\n", .{failure});
    std.debug.print("ts restrictions: {d} rows, {d} probes, {d} failures\n", .{ report.rows_checked, report.probes_run, report.failures.items.len });
    if (report.failures.items.len != 0) return error.GateFailed;
}

// ---------------------------------------------------------------------------
// Tests: a small synthetic document, a table check, and the failure each
// disagreement produces.
// ---------------------------------------------------------------------------

const testing = std.testing;

const test_doc =
    \\## Rules
    \\
    \\| Refused form | Code | Write instead |
    \\|---|---|---|
    \\| `var` and `let \| x` | ZTS001, ZTS216 (warning) | `const` |
    \\| A plain form | ZTS002 | Fix it |
    \\
    \\## Admitted Members
    \\
    \\`Array.prototype`: `map`, `slice`
    \\
    \\## Ambient Names And Effects
    \\
    \\The closed ambient value namespace is: `Array`, `Math`. The `meta` list.
    \\
    \\## Limits
    \\
    \\| Limit | Value |
    \\|---|---|
    \\| Source file size | 10 bytes |
    \\
    \\## Spec Rules That `zts check` Does Not Enforce
    \\
    \\| Form | Observed result | Required |
    \\|---|---|---|
    \\| Gap one | Accepted, exit 0 | ZTS001 |
    \\| Gap two | Refused with ZTS003, "x". The registry names ZTS042 | ZTS042 |
    \\
;

/// A fake check: the source text names the diagnostics, as `code:severity ...`.
fn fakeCheck(a: std.mem.Allocator, source: Source) anyerror![]const Diag {
    var out: std.ArrayList(Diag) = .empty;
    var words = std.mem.tokenizeScalar(u8, source.text, ' ');
    while (words.next()) |word| {
        const colon = std.mem.indexOfScalar(u8, word, ':') orelse continue;
        const label = word[colon + 1 ..];
        const severity: Severity = if (std.mem.eql(u8, label, "error")) .err else if (std.mem.eql(u8, label, "advisory")) .other else .warning;
        try out.append(a, .{ .code = word[0..colon], .severity = severity });
    }
    return out.toOwnedSlice(a);
}

const good_refusals = [_]probes.RefusalRow{
    .{
        .key = "`var` and `let | x`",
        .refused = &.{
            .{ .span = "var", .source = .{ .text = "ZTS001:error" } },
            .{ .span = "let | x", .source = .{ .text = "ZTS216:warning" } },
        },
        .clean = .{ .text = "clean" },
    },
    .{
        .key = "A plain form",
        .refused = &.{.{ .source = .{ .text = "ZTS002:error" } }},
        .clean = .{ .text = "clean" },
    },
};

const good_gaps = [_]probes.GapRow{
    .{ .key = "Gap one", .sources = &.{.{ .text = "clean" }} },
    .{ .key = "Gap two", .sources = &.{.{ .text = "ZTS003:error" }} },
};

const test_registry: Registry = .{
    .kind_codes = &.{ "ZTS001", "ZTS002" },
    .members = &.{
        .{ .scope = "Array.prototype", .name = "map" },
        .{ .scope = "Array.prototype", .name = "slice" },
    },
    .ambient = &.{ "Array", "Math" },
    .limits = &.{.{ .label = "Source file size", .value = 10 }},
};

fn testInputs(doc: []const u8, refusals: []const probes.RefusalRow, gaps: []const probes.GapRow, registry: Registry) Inputs {
    return .{
        .doc = doc,
        .allow = "",
        .refusal_probes = refusals,
        .gap_probes = gaps,
        .check = fakeCheck,
        .registry = registry,
    };
}

fn expectFailure(report: *const Report, fragment: []const u8) !void {
    for (report.failures.items) |failure| {
        if (std.mem.indexOf(u8, failure, fragment) != null) return;
    }
    std.debug.print("no failure contains: {s}\nfailures:\n", .{fragment});
    for (report.failures.items) |failure| std.debug.print("  {s}\n", .{failure});
    return error.MissingFailure;
}

test "a document and probes that agree pass" {
    var report = try runGate(testing.allocator, testInputs(test_doc, &good_refusals, &good_gaps, test_registry));
    defer report.deinit();
    try testing.expectEqual(@as(usize, 0), report.failures.items.len);
    try testing.expectEqual(@as(usize, 4), report.rows_checked);
}

test "a changed code in the document names the row" {
    const doc = try std.mem.replaceOwned(u8, testing.allocator, test_doc, "| A plain form | ZTS002 |", "| A plain form | ZTS003 |");
    defer testing.allocator.free(doc);
    var report = try runGate(testing.allocator, testInputs(doc, &good_refusals, &good_gaps, test_registry));
    defer report.deinit();
    try expectFailure(&report, "refusal row \"A plain form\" []: the probe reports error ZTS002, which is not in the row (ZTS003)");
}

test "a deleted probe names the row and the span" {
    const fewer = [_]probes.RefusalRow{.{
        .key = "`var` and `let | x`",
        .refused = &.{.{ .span = "var", .source = .{ .text = "ZTS001:error" } }},
        .clean = .{ .text = "clean" },
    }};
    var report = try runGate(testing.allocator, testInputs(test_doc, &fewer, &good_gaps, test_registry));
    defer report.deinit();
    try expectFailure(&report, "refusal row \"A plain form\": no probe row");
    try expectFailure(&report, "no refused probe for the span `let | x`");
}

test "a warning code that no probe reports at warning severity fails" {
    const wrong = [_]probes.RefusalRow{
        .{
            .key = "`var` and `let | x`",
            .refused = &.{
                .{ .span = "var", .source = .{ .text = "ZTS001:error" } },
                .{ .span = "let | x", .source = .{ .text = "ZTS001:error" } },
            },
            .clean = .{ .text = "clean" },
        },
        good_refusals[1],
    };
    var report = try runGate(testing.allocator, testInputs(test_doc, &wrong, &good_gaps, test_registry));
    defer report.deinit();
    try expectFailure(&report, "no probe reports ZTS216 at warning severity");
}

test "a clean probe that reports an error fails" {
    const dirty = [_]probes.RefusalRow{
        good_refusals[0],
        .{
            .key = "A plain form",
            .refused = &.{.{ .source = .{ .text = "ZTS002:error" } }},
            .clean = .{ .text = "ZTS100:error" },
        },
    };
    var report = try runGate(testing.allocator, testInputs(test_doc, &dirty, &good_gaps, test_registry));
    defer report.deinit();
    try expectFailure(&report, "refusal row \"A plain form\": the clean probe of the \"Write instead\" form reports ZTS100");
}

test "a gap that the compiler now refuses fails" {
    const refused = [_]probes.GapRow{
        .{ .key = "Gap one", .sources = &.{.{ .text = "ZTS001:error" }} },
        good_gaps[1],
    };
    var report = try runGate(testing.allocator, testInputs(test_doc, &good_refusals, &refused, test_registry));
    defer report.deinit();
    try expectFailure(&report, "gap row \"Gap one\": the document says the form is accepted, and the probe reports ZTS001");
}

test "a member missing from Admitted Members and an extra ambient name fail" {
    const registry: Registry = .{
        .kind_codes = test_registry.kind_codes,
        .members = &.{
            .{ .scope = "Array.prototype", .name = "map" },
            .{ .scope = "Array.prototype", .name = "slice" },
            .{ .scope = "Array.prototype", .name = "join" },
        },
        .ambient = &.{"Array"},
        .limits = &.{.{ .label = "Source file size", .value = 11 }},
    };
    var report = try runGate(testing.allocator, testInputs(test_doc, &good_refusals, &good_gaps, registry));
    defer report.deinit();
    try expectFailure(&report, "member Array.prototype.join: not in Admitted Members");
    try expectFailure(&report, "member Array.prototype.join: a read is accepted, and the document does not admit it");
    try expectFailure(&report, "ambient name `Math`: the document lists it, and the meta payload does not");
    try expectFailure(&report, "limit \"Source file size\": the document says 10, and the meta payload says 11");
}

test "a kind that no probe observes needs an allowlist row, and a stale row fails" {
    const registry: Registry = .{
        .kind_codes = &.{ "ZTS001", "ZTS002", "ZTS004" },
        .members = test_registry.members,
        .ambient = test_registry.ambient,
        .limits = test_registry.limits,
    };
    var report = try runGate(testing.allocator, testInputs(test_doc, &good_refusals, &good_gaps, registry));
    defer report.deinit();
    try expectFailure(&report, "diagnostic kind ZTS004: no refused probe observes it");

    var stale_inputs = testInputs(test_doc, &good_refusals, &good_gaps, registry);
    stale_inputs.allow = "# header\nZTS004 syntax error, no row\nZTS001 observed already\n";
    var stale = try runGate(testing.allocator, stale_inputs);
    defer stale.deinit();
    try testing.expectEqual(@as(usize, 1), stale.failures.items.len);
    try expectFailure(&stale, "allowlist row ZTS001: a probe now observes this code");
}

test "parseDoc reads cells with an escaped pipe and spans with a backtick" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const doc = try parseDoc(arena.allocator(), test_doc);
    try testing.expectEqualStrings("`var` and `let | x`", doc.refusals[0].key);
    try testing.expectEqualStrings("let | x", doc.refusals[0].spans[1]);
    try testing.expectEqual(Severity.warning, doc.refusals[0].codes[1].severity);
    try testing.expectEqualStrings("ZTS042", doc.gaps[1].required);
    try testing.expectEqual(@as(usize, 1), doc.gaps[1].codes.len);
    try testing.expectEqualStrings("ZTS003", doc.gaps[1].codes[0]);
    const spans = try codeSpans(arena.allocator(), "Template `` `n=${n}` `` end");
    try testing.expectEqualStrings("`n=${n}`", spans[0]);
}

/// The fake check, except that a read of `xs.slice` is refused.
fn refuseSliceRead(a: std.mem.Allocator, source: Source) anyerror![]const Diag {
    if (std.mem.indexOf(u8, source.text, "xs.slice;") == null) return fakeCheck(a, source);
    const out = try a.alloc(Diag, 1);
    out[0] = .{ .code = "ZTS201", .severity = .err };
    return out;
}

test "an admitted member whose read is refused fails" {
    var inputs = testInputs(test_doc, &good_refusals, &good_gaps, test_registry);
    inputs.check = refuseSliceRead;
    var report = try runGate(testing.allocator, inputs);
    defer report.deinit();
    try testing.expectEqual(@as(usize, 1), report.failures.items.len);
    try expectFailure(&report, "Admitted Members Array.prototype: a read of `slice` reports ZTS201");
}

test "an advisory code passes only at advisory severity" {
    const doc = try std.mem.replaceOwned(u8, testing.allocator, test_doc, "| A plain form | ZTS002 |", "| A plain form | ZTS625 (advisory) |");
    defer testing.allocator.free(doc);
    const advisory = [_]probes.RefusalRow{ good_refusals[0], .{
        .key = "A plain form",
        .refused = &.{.{ .source = .{ .text = "ZTS625:advisory" } }},
        .clean = .{ .text = "clean" },
    } };
    var inputs = testInputs(doc, &advisory, &good_gaps, test_registry);
    inputs.allow = "ZTS002 no row names it in this test\n";
    var pass = try runGate(testing.allocator, inputs);
    defer pass.deinit();
    try testing.expectEqual(@as(usize, 0), pass.failures.items.len);

    const as_warning = [_]probes.RefusalRow{ good_refusals[0], .{
        .key = "A plain form",
        .refused = &.{.{ .source = .{ .text = "ZTS625:warning" } }},
        .clean = .{ .text = "clean" },
    } };
    inputs.refusal_probes = &as_warning;
    var fail = try runGate(testing.allocator, inputs);
    defer fail.deinit();
    try expectFailure(&fail, "refusal row \"A plain form\" []: the probe reports no error");
    try expectFailure(&fail, "no probe reports ZTS625 at advisory severity");
}

test "a gap row with an empty Required cell fails" {
    const doc = try std.mem.replaceOwned(u8, testing.allocator, test_doc, "| Gap one | Accepted, exit 0 | ZTS001 |", "| Gap one | Accepted, exit 0 | |");
    defer testing.allocator.free(doc);
    var report = try runGate(testing.allocator, testInputs(doc, &good_refusals, &good_gaps, test_registry));
    defer report.deinit();
    try testing.expectEqual(@as(usize, 1), report.failures.items.len);
    try expectFailure(&report, "gap row \"Gap one\": the Required cell is empty");
}
