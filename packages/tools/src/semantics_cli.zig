const std = @import("std");
const writeAllFd = @import("precompile_util.zig").writeAllFd;
const zts = @import("zts");

const zts_file_io = zts.file_io;

fn isHelpToken(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "help");
}

pub fn runSpecHashCommand(allocator: std.mem.Allocator, argv: []const []const u8) !void {
    var json_mode = false;
    for (argv) |arg| {
        if (std.mem.eql(u8, arg, "--json")) {
            json_mode = true;
        } else if (isHelpToken(arg)) {
            try writeAllFd(std.c.STDOUT_FILENO, "Usage: zts spec-hash [--json]\n");
            return;
        } else {
            return error.InvalidArgument;
        }
    }
    const hash = zts.semantics.semanticsHash();
    if (json_mode) {
        var aw: std.Io.Writer.Allocating = .init(allocator);
        defer aw.deinit();
        try aw.writer.writeAll("{\"semanticsHash\":");
        try zts.writeJsonString(&aw.writer, &hash);
        try aw.writer.writeAll("}\n");
        try writeAllFd(std.c.STDOUT_FILENO, aw.written());
    } else {
        try writeAllFd(std.c.STDOUT_FILENO, &hash);
        try writeAllFd(std.c.STDOUT_FILENO, "\n");
    }
}

pub fn runSpecRenderCommand(allocator: std.mem.Allocator, argv: []const []const u8) !void {
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
        } else if (isHelpToken(arg)) {
            try writeAllFd(std.c.STDOUT_FILENO, "Usage: zts spec-render [--out <path> | --check <path>]\n");
            return;
        } else {
            return error.InvalidArgument;
        }
    }

    const rendered = try zts.renderSpecTs(allocator);
    defer allocator.free(rendered);

    if (check_path) |path| {
        // Drift gate: the committed artifact must match the current registry.
        const existing = zts_file_io.readFile(allocator, path, 1 << 20) catch {
            const msg = "spec-render --check: cannot read the spec artifact\n";
            writeAllFd(std.c.STDERR_FILENO, msg) catch {};
            std.process.exit(2);
        };
        defer allocator.free(existing);
        if (!std.mem.eql(u8, existing, rendered)) {
            const msg = "spec-render --check: the committed spec is stale; run `zts spec-render --out <path>`\n";
            writeAllFd(std.c.STDERR_FILENO, msg) catch {};
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

pub fn runSpecCheckCommand(allocator: std.mem.Allocator, argv: []const []const u8) !void {
    var json_mode = false;
    for (argv) |arg| {
        if (std.mem.eql(u8, arg, "--json")) {
            json_mode = true;
        } else if (isHelpToken(arg)) {
            try writeAllFd(std.c.STDOUT_FILENO, "Usage: zts spec-check [--json]\n");
            return;
        } else {
            return error.InvalidArgument;
        }
    }

    var result = zts.semantics_check.runCheck(allocator) catch {
        const msg = "spec-check: internal error\n";
        writeAllFd(std.c.STDERR_FILENO, msg) catch {};
        std.process.exit(2);
    };
    defer result.deinit();

    // Mechanism 4: the differential corpus runs the registry's denotations
    // against the real compiler's output.
    var corpus = zts.semantics_corpus.runCorpus(allocator) catch {
        const msg = "spec-check: corpus internal error\n";
        writeAllFd(std.c.STDERR_FILENO, msg) catch {};
        std.process.exit(2);
    };
    defer corpus.deinit();

    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    const report: SpecCheckReport = .{ .check = &result, .corpus = &corpus };
    if (json_mode) {
        try writeSpecCheckJson(&aw.writer, report);
    } else {
        try writeSpecCheckText(&aw.writer, report);
    }
    if (aw.written().len > 0) {
        try writeAllFd(std.c.STDOUT_FILENO, aw.written());
    }

    const all_ok = report.ok();

    // exit 0 conform, 1 divergence (2 for internal error handled above).
    if (!all_ok) std.process.exit(1);
}

fn writeSpecCheckText(writer: anytype, report: SpecCheckReport) !void {
    const cov = zts.semantics.coverage();
    const sh = zts.semantics.semanticsHash();
    const r = report.check;
    const corpus = report.corpus;
    try writer.writeAll("zts semantics spec-check\n");
    try writer.print("  semantics hash:    {s}\n", .{sh});
    try writer.print("  nodes classified:  {d}/{d} reachable\n", .{ cov.nodes_classified, cov.nodes_reachable });
    try writer.print("    assurance:       {d} specified, {d} translation-validated, {d} trusted, {d} unreachable\n", .{ cov.nodes_specified, cov.nodes_translation_validated, cov.nodes_trusted, cov.nodes_unreachable });
    try writer.print("  opcodes classified:{d}/{d} reachable\n", .{ cov.opcodes_classified, cov.opcodes_reachable });
    try writer.print("    assurance:       {d} specified, {d} translation-validated, {d} trusted, {d} unreachable\n", .{ cov.opcodes_specified, cov.opcodes_translation_validated, cov.opcodes_trusted, cov.opcodes_unreachable });
    try writer.print("  value proofs:      {d} (binop x{d}, unop x{d})\n", .{ r.nodes_proven, r.binop_instances, r.unop_instances });
    try writer.print("  refinements:       {d}\n", .{r.refinements_proven});
    try writer.print("  structural-only:   {d}\n", .{r.nodes_structural});
    try writer.print("  stack-effect:      {d} checks\n", .{r.stack_effect_checked});
    try writer.print("  differential:      {d}/{d} cases vs real codegen\n", .{ corpus.cases_passed, corpus.cases_total });
    if (report.ok()) {
        try writer.writeAll("  result:            PASS\n");
    } else {
        try writer.print("  result:            FAIL ({d} divergence)\n", .{report.failureCount()});
        try appendSpecCheckFailuresText(writer, report);
    }
}

fn appendSpecCheckFailuresText(writer: anytype, report: SpecCheckReport) !void {
    for (report.check.failures.items) |f| {
        try writer.print("    {s} {s}: {s}\n", .{ f.code.code(), f.where, f.message });
    }
    for (report.corpus.failures.items) |f| {
        try writer.print("    {s} {s}: {s}\n", .{ zts.semantics.SpecCode.lowering_divergence.code(), f.where, f.message });
    }
}

fn writeSpecCheckJson(writer: anytype, report: SpecCheckReport) !void {
    const cov = zts.semantics.coverage();
    const sh = zts.semantics.semanticsHash();
    const ir_h = zts.semantics.irTableHash();
    const op_h = zts.semantics.opcodeTableHash();
    const r = report.check;
    const corpus = report.corpus;
    try writer.writeAll("{\"semanticsHash\":");
    try zts.writeJsonString(writer, &sh);
    try writer.writeAll(",\"irTableHash\":");
    try zts.writeJsonString(writer, &ir_h);
    try writer.writeAll(",\"opcodeTableHash\":");
    try zts.writeJsonString(writer, &op_h);
    try writer.print(",\"nodes\":{{\"classified\":{d},\"reachable\":{d},\"specified\":{d},\"translationValidated\":{d},\"trusted\":{d},\"unreachable\":{d},\"total\":{d}}},", .{ cov.nodes_classified, cov.nodes_reachable, cov.nodes_specified, cov.nodes_translation_validated, cov.nodes_trusted, cov.nodes_unreachable, cov.nodes_total });
    try writer.print("\"opcodes\":{{\"classified\":{d},\"reachable\":{d},\"specified\":{d},\"translationValidated\":{d},\"trusted\":{d},\"unreachable\":{d},\"total\":{d}}},", .{ cov.opcodes_classified, cov.opcodes_reachable, cov.opcodes_specified, cov.opcodes_translation_validated, cov.opcodes_trusted, cov.opcodes_unreachable, cov.opcodes_total });
    try writer.print("\"valueProofs\":{d},\"binopInstances\":{d},\"unopInstances\":{d},\"refinements\":{d},\"structural\":{d},\"stackEffectChecks\":{d},", .{ r.nodes_proven, r.binop_instances, r.unop_instances, r.refinements_proven, r.nodes_structural, r.stack_effect_checked });
    try writer.print("\"differential\":{{\"passed\":{d},\"total\":{d}}},", .{ corpus.cases_passed, corpus.cases_total });
    try writer.print("\"ok\":{s},\"failures\":[", .{if (report.ok()) "true" else "false"});
    try appendSpecCheckFailuresJson(writer, report);
    try writer.writeAll("]}\n");
}

fn appendJsonFailure(
    writer: anytype,
    first: *bool,
    code: []const u8,
    where: []const u8,
    message: []const u8,
) !void {
    if (!first.*) try writer.writeByte(',');
    first.* = false;
    try writer.writeAll("{\"code\":");
    try zts.writeJsonString(writer, code);
    try writer.writeAll(",\"where\":");
    try zts.writeJsonString(writer, where);
    try writer.writeAll(",\"message\":");
    try zts.writeJsonString(writer, message);
    try writer.writeByte('}');
}

fn appendSpecCheckFailuresJson(writer: anytype, report: SpecCheckReport) !void {
    var first = true;
    for (report.check.failures.items) |f| {
        try appendJsonFailure(writer, &first, f.code.code(), f.where, f.message);
    }
    for (report.corpus.failures.items) |f| {
        try appendJsonFailure(writer, &first, zts.semantics.SpecCode.lowering_divergence.code(), f.where, f.message);
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
        .where = "unary_op\t\"quote\"",
        .message = "real codegen\rmismatch\x01",
    });

    const report: SpecCheckReport = .{ .check = &check, .corpus = &corpus };
    try std.testing.expect(!report.ok());
    try std.testing.expectEqual(@as(usize, 2), report.failureCount());

    var json_aw: std.Io.Writer.Allocating = .init(allocator);
    defer json_aw.deinit();
    try writeSpecCheckJson(&json_aw.writer, report);
    const json = json_aw.written();
    try std.testing.expect(std.mem.find(u8, json, "\"ok\":false") != null);
    try std.testing.expect(std.mem.find(u8, json, "\"classified\":42,\"reachable\":42") != null);
    try std.testing.expect(std.mem.find(u8, json, "\"classified\":127,\"reachable\":127") != null);
    try std.testing.expect(std.mem.find(u8, json, "\"where\":\"binary_op\"") != null);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    defer parsed.deinit();
    const failures = parsed.value.object.get("failures").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), failures.len);
    try std.testing.expectEqualStrings("unary_op\t\"quote\"", failures[1].object.get("where").?.string);
    try std.testing.expectEqualStrings("real codegen\rmismatch\x01", failures[1].object.get("message").?.string);

    var text_aw: std.Io.Writer.Allocating = .init(allocator);
    defer text_aw.deinit();
    try writeSpecCheckText(&text_aw.writer, report);
    const text = text_aw.written();
    try std.testing.expect(std.mem.find(u8, text, "nodes classified:  42/42 reachable") != null);
    try std.testing.expect(std.mem.find(u8, text, "opcodes classified:127/127 reachable") != null);
    try std.testing.expect(std.mem.find(u8, text, "FAIL (2 divergence)") != null);
    try std.testing.expect(std.mem.find(u8, text, "binary_op: lowering mismatch") != null);
}
