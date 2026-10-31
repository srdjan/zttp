const std = @import("std");
const writeAllFd = @import("precompile_util.zig").writeAllFd;
const zts = @import("zts");

const zts_file_io = zts.file_io;

fn isHelpToken(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "help");
}

fn appendFmt(allocator: std.mem.Allocator, buf: *std.ArrayList(u8), comptime fmt: []const u8, args: anytype) !void {
    const s = try allocator.print(fmt, args);
    defer allocator.free(s);
    try buf.appendSlice(allocator, s);
}

pub fn runSpecHashCommand(_: std.mem.Allocator, argv: []const []const u8) !void {
    var json_mode = false;
    for (argv) |arg| {
        if (std.mem.eql(u8, arg, "--json")) {
            json_mode = true;
        } else if (isHelpToken(arg)) {} else {
            return error.InvalidArgument;
        }
    }
    const hash = zts.semantics.semanticsHash();
    if (json_mode) {
        const allocator = std.heap.smp_allocator;
        const line = try allocator.print("{{\"semanticsHash\":\"{s}\"}}\n", .{hash});
        defer allocator.free(line);
        try writeAllFd(std.c.STDOUT_FILENO, line);
    } else {
        try writeAllFd(std.c.STDOUT_FILENO, &hash);
        try writeAllFd(std.c.STDOUT_FILENO, "\n");
    }
}

pub fn runSpecRenderCommand(_: std.mem.Allocator, argv: []const []const u8) !void {
    var out_path: ?[]const u8 = null;
    var check_path: ?[]const u8 = null;
    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (std.mem.eql(u8, arg, "--out")) {
            i += 1;
            if (i >= argv.len) return error.MissingArgument;
            out_path = argv[i];
        } else if (std.mem.eql(u8, arg, "--check")) {
            i += 1;
            if (i >= argv.len) return error.MissingArgument;
            check_path = argv[i];
        } else if (isHelpToken(arg)) {} else {
            return error.InvalidArgument;
        }
    }

    const allocator = std.heap.smp_allocator;
    const rendered = try zts.renderSpecTs(allocator);
    defer allocator.free(rendered);

    if (check_path) |path| {
        // Drift gate: the committed artifact must match the current registry.
        const existing = zts_file_io.readFile(allocator, path, 1 << 20) catch {
            const msg = "spec-render --check: cannot read the spec artifact\n";
            _ = std.c.write(std.c.STDERR_FILENO, msg, msg.len);
            std.process.exit(2);
        };
        defer allocator.free(existing);
        if (!std.mem.eql(u8, existing, rendered)) {
            const msg = "spec-render --check: the committed spec is stale; run `zts spec-render --out <path>`\n";
            _ = std.c.write(std.c.STDERR_FILENO, msg, msg.len);
            std.process.exit(1);
        }
        const ok = "spec-render --check: spec is in sync\n";
        try writeAllFd(std.c.STDOUT_FILENO, ok);
        return;
    }

    if (out_path) |path| {
        try zts_file_io.writeFile(allocator, path, rendered);
        return;
    }

    if (rendered.len > 0) {
        try writeAllFd(std.c.STDOUT_FILENO, rendered);
    }
}

fn appendJsonString(allocator: std.mem.Allocator, buf: *std.ArrayList(u8), s: []const u8) !void {
    try buf.append(allocator, '"');
    for (s) |c| {
        switch (c) {
            '"' => try buf.appendSlice(allocator, "\\\""),
            '\\' => try buf.appendSlice(allocator, "\\\\"),
            '\n' => try buf.appendSlice(allocator, "\\n"),
            else => try buf.append(allocator, c),
        }
    }
    try buf.append(allocator, '"');
}

const SpecCheckReport = struct {
    check: *const zts.semantics_check.CheckResult,
    corpus: *const zts.semantics_corpus.CorpusResult,

    fn ok(self: SpecCheckReport) bool {
        return self.check.ok() and self.corpus.ok();
    }

    fn failureCount(self: SpecCheckReport) usize {
        return self.check.failures.items.len +
            self.corpus.failures.items.len;
    }
};

pub fn runSpecCheckCommand(_: std.mem.Allocator, argv: []const []const u8) !void {
    var json_mode = false;
    for (argv) |arg| {
        if (std.mem.eql(u8, arg, "--json")) {
            json_mode = true;
        } else if (isHelpToken(arg)) {
            // no separate help screen
        } else {
            return error.InvalidArgument;
        }
    }

    const allocator = std.heap.smp_allocator;
    var result = zts.semantics_check.runCheck(allocator) catch {
        const msg = "spec-check: internal error\n";
        _ = std.c.write(std.c.STDERR_FILENO, msg, msg.len);
        std.process.exit(2);
    };
    defer result.deinit();

    // Mechanism 4: the differential corpus runs the registry's denotations
    // against the real compiler's output.
    var corpus = zts.semantics_corpus.runCorpus(allocator) catch {
        const msg = "spec-check: corpus internal error\n";
        _ = std.c.write(std.c.STDERR_FILENO, msg, msg.len);
        std.process.exit(2);
    };
    defer corpus.deinit();

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    const report: SpecCheckReport = .{ .check = &result, .corpus = &corpus };
    if (json_mode) {
        try writeSpecCheckJson(allocator, &buf, report);
    } else {
        try writeSpecCheckText(allocator, &buf, report);
    }
    if (buf.items.len > 0) {
        try writeAllFd(std.c.STDOUT_FILENO, buf.items);
    }

    const all_ok = report.ok();

    // exit 0 conform, 1 divergence (2 for internal error handled above).
    if (!all_ok) std.process.exit(1);
}

fn writeSpecCheckText(allocator: std.mem.Allocator, buf: *std.ArrayList(u8), report: SpecCheckReport) !void {
    const cov = zts.semantics.coverage();
    const sh = zts.semantics.semanticsHash();
    const r = report.check;
    const corpus = report.corpus;
    try appendFmt(allocator, buf, "zts semantics spec-check\n", .{});
    try appendFmt(allocator, buf, "  semantics hash:    {s}\n", .{sh});
    try appendFmt(allocator, buf, "  nodes classified:  {d}/{d} reachable\n", .{ cov.nodes_classified, cov.nodes_reachable });
    try appendFmt(allocator, buf, "    assurance:       {d} specified, {d} translation-validated, {d} trusted, {d} unreachable\n", .{ cov.nodes_specified, cov.nodes_translation_validated, cov.nodes_trusted, cov.nodes_unreachable });
    try appendFmt(allocator, buf, "  opcodes classified:{d}/{d} reachable\n", .{ cov.opcodes_classified, cov.opcodes_reachable });
    try appendFmt(allocator, buf, "    assurance:       {d} specified, {d} translation-validated, {d} trusted, {d} unreachable\n", .{ cov.opcodes_specified, cov.opcodes_translation_validated, cov.opcodes_trusted, cov.opcodes_unreachable });
    try appendFmt(allocator, buf, "  value proofs:      {d} (binop x{d}, unop x{d})\n", .{ r.nodes_proven, r.binop_instances, r.unop_instances });
    try appendFmt(allocator, buf, "  refinements:       {d}\n", .{r.refinements_proven});
    try appendFmt(allocator, buf, "  structural-only:   {d}\n", .{r.nodes_structural});
    try appendFmt(allocator, buf, "  stack-effect:      {d} checks\n", .{r.stack_effect_checked});
    try appendFmt(allocator, buf, "  differential:      {d}/{d} cases vs real codegen\n", .{ corpus.cases_passed, corpus.cases_total });
    if (report.ok()) {
        try appendFmt(allocator, buf, "  result:            PASS\n", .{});
    } else {
        try appendFmt(allocator, buf, "  result:            FAIL ({d} divergence)\n", .{report.failureCount()});
        try appendSpecCheckFailuresText(allocator, buf, report);
    }
}

fn appendSpecCheckFailuresText(allocator: std.mem.Allocator, buf: *std.ArrayList(u8), report: SpecCheckReport) !void {
    for (report.check.failures.items) |f| {
        try appendFmt(allocator, buf, "    {s} {s}: {s}\n", .{ f.code.code(), f.where, f.message });
    }
    for (report.corpus.failures.items) |f| {
        try appendFmt(allocator, buf, "    {s} {s}: {s}\n", .{ zts.semantics.SpecCode.lowering_divergence.code(), f.where, f.message });
    }
}

fn writeSpecCheckJson(allocator: std.mem.Allocator, buf: *std.ArrayList(u8), report: SpecCheckReport) !void {
    const cov = zts.semantics.coverage();
    const sh = zts.semantics.semanticsHash();
    const ir_h = zts.semantics.irTableHash();
    const op_h = zts.semantics.opcodeTableHash();
    const r = report.check;
    const corpus = report.corpus;
    try appendFmt(allocator, buf, "{{\"semanticsHash\":\"{s}\",\"irTableHash\":\"{s}\",\"opcodeTableHash\":\"{s}\",", .{ sh, ir_h, op_h });
    try appendFmt(allocator, buf, "\"nodes\":{{\"classified\":{d},\"reachable\":{d},\"specified\":{d},\"translationValidated\":{d},\"trusted\":{d},\"unreachable\":{d},\"total\":{d}}},", .{ cov.nodes_classified, cov.nodes_reachable, cov.nodes_specified, cov.nodes_translation_validated, cov.nodes_trusted, cov.nodes_unreachable, cov.nodes_total });
    try appendFmt(allocator, buf, "\"opcodes\":{{\"classified\":{d},\"reachable\":{d},\"specified\":{d},\"translationValidated\":{d},\"trusted\":{d},\"unreachable\":{d},\"total\":{d}}},", .{ cov.opcodes_classified, cov.opcodes_reachable, cov.opcodes_specified, cov.opcodes_translation_validated, cov.opcodes_trusted, cov.opcodes_unreachable, cov.opcodes_total });
    try appendFmt(allocator, buf, "\"valueProofs\":{d},\"binopInstances\":{d},\"unopInstances\":{d},\"refinements\":{d},\"structural\":{d},\"stackEffectChecks\":{d},", .{ r.nodes_proven, r.binop_instances, r.unop_instances, r.refinements_proven, r.nodes_structural, r.stack_effect_checked });
    try appendFmt(allocator, buf, "\"differential\":{{\"passed\":{d},\"total\":{d}}},", .{ corpus.cases_passed, corpus.cases_total });
    try appendFmt(allocator, buf, "\"ok\":{s},\"failures\":[", .{if (report.ok()) "true" else "false"});
    try appendSpecCheckFailuresJson(allocator, buf, report);
    try appendFmt(allocator, buf, "]}}\n", .{});
}

fn appendJsonFailure(
    allocator: std.mem.Allocator,
    buf: *std.ArrayList(u8),
    first: *bool,
    code: []const u8,
    where: []const u8,
    message: []const u8,
) !void {
    if (!first.*) try buf.append(allocator, ',');
    first.* = false;
    try appendFmt(allocator, buf, "{{\"code\":\"{s}\",\"where\":\"{s}\",\"message\":", .{ code, where });
    try appendJsonString(allocator, buf, message);
    try buf.append(allocator, '}');
}

fn appendSpecCheckFailuresJson(allocator: std.mem.Allocator, buf: *std.ArrayList(u8), report: SpecCheckReport) !void {
    var first = true;
    for (report.check.failures.items) |f| {
        try appendJsonFailure(allocator, buf, &first, f.code.code(), f.where, f.message);
    }
    for (report.corpus.failures.items) |f| {
        try appendJsonFailure(allocator, buf, &first, zts.semantics.SpecCode.lowering_divergence.code(), f.where, f.message);
    }
}

test "spec-check renderers aggregate structural and corpus failures" {
    const allocator = std.testing.allocator;

    var check = zts.semantics_check.CheckResult{ .arena = std.heap.ArenaAllocator.init(allocator) };
    defer check.deinit();
    try check.failures.append(check.arena.allocator(), .{
        .code = .lowering_divergence,
        .where = "binary_op",
        .message = "lowering mismatch",
    });

    var corpus = zts.semantics_corpus.CorpusResult{ .arena = std.heap.ArenaAllocator.init(allocator) };
    defer corpus.deinit();
    corpus.cases_total = 2;
    corpus.cases_passed = 1;
    try corpus.failures.append(corpus.arena.allocator(), .{
        .where = "unary_op",
        .message = "real codegen mismatch",
    });

    const report: SpecCheckReport = .{ .check = &check, .corpus = &corpus };
    try std.testing.expect(!report.ok());
    try std.testing.expectEqual(@as(usize, 2), report.failureCount());

    var json: std.ArrayList(u8) = .empty;
    defer json.deinit(allocator);
    try writeSpecCheckJson(allocator, &json, report);
    try std.testing.expect(std.mem.indexOf(u8, json.items, "\"ok\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, json.items, "\"classified\":42,\"reachable\":42") != null);
    try std.testing.expect(std.mem.indexOf(u8, json.items, "\"classified\":127,\"reachable\":127") != null);
    try std.testing.expect(std.mem.indexOf(u8, json.items, "\"where\":\"binary_op\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json.items, "\"where\":\"unary_op\"") != null);

    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(allocator);
    try writeSpecCheckText(allocator, &text, report);
    try std.testing.expect(std.mem.indexOf(u8, text.items, "nodes classified:  42/42 reachable") != null);
    try std.testing.expect(std.mem.indexOf(u8, text.items, "opcodes classified:127/127 reachable") != null);
    try std.testing.expect(std.mem.indexOf(u8, text.items, "FAIL (2 divergence)") != null);
    try std.testing.expect(std.mem.indexOf(u8, text.items, "binary_op: lowering mismatch") != null);
    try std.testing.expect(std.mem.indexOf(u8, text.items, "unary_op: real codegen mismatch") != null);
}
