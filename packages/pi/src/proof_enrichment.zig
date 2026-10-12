const std = @import("std");
const zts = @import("zts");
const zts_cli = @import("zts_cli");
const transcript_mod = @import("transcript.zig");
const ui_payload = @import("ui_payload.zig");
const TextBuffer = @import("text_buffer.zig").TextBuffer;
const tools_common = @import("tools/common.zig");

const edit_simulate = zts_cli.edit_simulate;
const precompile = zts_cli.precompile;
const contract_diff = zts.contract_diff;
const HandlerProperties = zts.HandlerProperties;

pub const PatchAnalysis = struct {
    stats: ui_payload.ProofStats,
    violations: []ui_payload.ViolationDeltaItem,
    before_properties: ?ui_payload.PropertiesSnapshot,
    after_properties: ?ui_payload.PropertiesSnapshot,
    prove: ?ui_payload.ProveSummary,
    rule_citations: [][]u8,
    unified_diff: []u8,
    hunks: []ui_payload.DiffHunk,

    pub fn deinit(self: *PatchAnalysis, allocator: std.mem.Allocator) void {
        for (self.violations) |*item| item.deinit(allocator);
        allocator.free(self.violations);
        if (self.prove) |*prove| prove.deinit(allocator);
        for (self.rule_citations) |citation| allocator.free(citation);
        allocator.free(self.rule_citations);
        allocator.free(self.unified_diff);
        allocator.free(self.hunks);
        self.* = .{
            .stats = .{ .total = 0, .new = 0, .preexisting = null },
            .violations = &.{},
            .before_properties = null,
            .after_properties = null,
            .prove = null,
            .rule_citations = &.{},
            .unified_diff = &.{},
            .hunks = &.{},
        };
    }
};

pub fn analyzePatch(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    file: []const u8,
    before: ?[]const u8,
    after: []const u8,
    transcript: ?*const transcript_mod.Transcript,
) !PatchAnalysis {
    const absolute_path = try resolveHandlerPath(allocator, workspace_root, file);
    defer allocator.free(absolute_path);

    // zttp:sql handlers need the project SQL schema to analyze. Without it,
    // simulate() on a SQL handler throws MissingSqlSchema and crashes the
    // receipt build after an otherwise successful apply. Root it at the handler:
    // a run started outside the handler's project could otherwise validate
    // queries against a different zttp.json.
    const sql_schema_path = edit_simulate.discoverProjectSqlSchemaPath(allocator, absolute_path);
    defer if (sql_schema_path) |p| allocator.free(p);

    var simulated = try edit_simulate.simulate(allocator, .{
        .file = absolute_path,
        .content = after,
        .before = before,
        .sql_schema_path = sql_schema_path,
    });
    defer simulated.deinit(allocator);

    const violations = try copyViolations(allocator, simulated.violations.items);
    errdefer {
        for (violations) |*item| item.deinit(allocator);
        allocator.free(violations);
    }

    const before_snapshot = try optionalPropertiesSnapshot(allocator, absolute_path, before, sql_schema_path);
    const after_snapshot = if (simulated.properties) |properties|
        propertiesSnapshot(properties)
    else
        try optionalPropertiesSnapshot(allocator, absolute_path, after, sql_schema_path);

    var prove = try optionalProveSummary(allocator, absolute_path, before, after, sql_schema_path);
    errdefer if (prove) |*summary| summary.deinit(allocator);
    const citations = if (transcript) |tr|
        try collectRuleCitations(allocator, tr)
    else
        try allocator.alloc([]u8, 0);
    errdefer {
        for (citations) |citation| allocator.free(citation);
        allocator.free(citations);
    }

    const diff = try buildUnifiedDiff(allocator, before, after);
    errdefer {
        allocator.free(diff.text);
        allocator.free(diff.hunks);
    }

    return .{
        .stats = .{
            .total = simulated.total,
            .new = simulated.new_count,
            .preexisting = simulated.preexisting_count,
        },
        .violations = violations,
        .before_properties = before_snapshot,
        .after_properties = after_snapshot,
        .prove = prove,
        .rule_citations = citations,
        .unified_diff = diff.text,
        .hunks = diff.hunks,
    };
}

pub fn loadProveSummaryForPatch(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    file: []const u8,
    before: ?[]const u8,
    after: []const u8,
) !?ui_payload.ProveSummary {
    const absolute_path = try resolveHandlerPath(allocator, workspace_root, file);
    defer allocator.free(absolute_path);
    // Root the SQL schema lookup at the handler.
    const sql_schema_path = edit_simulate.discoverProjectSqlSchemaPath(allocator, absolute_path);
    defer if (sql_schema_path) |p| allocator.free(p);
    return computeProveSummary(allocator, absolute_path, before, after, sql_schema_path);
}

pub fn formatProveSummary(
    allocator: std.mem.Allocator,
    summary: ?ui_payload.ProveSummary,
) ![]u8 {
    if (summary == null) return allocator.dupe(u8, "prove: unavailable\n");

    const value = summary.?;
    var buf = TextBuffer.init(allocator);
    defer buf.deinit();
    const w = buf.writer();

    try w.print(
        "classification: {s}\nproof_level: {s}\nrecommendation: {s}\n",
        .{ value.classification, value.proof_level, value.recommendation },
    );
    if (value.counterexample) |counterexample| {
        try w.print("counterexample: {s}\n", .{counterexample});
    }
    if (value.laws_used.len > 0) {
        try w.writeAll("laws_used:\n");
        for (value.laws_used) |law| {
            try w.print("- {s}\n", .{law});
        }
    }

    return buf.toOwnedSlice();
}

// Property drift gate. pi's PropertiesSnapshot must mirror every boolean handler
// property the engine tracks, so a new proof dimension added to the engine (like
// cost_bounded) cannot silently miss the expert surface - the proof card, the
// /ledger proven-path ratio, and the persona all read this snapshot. If this
// fails, add the missing field to ui_payload.PropertiesSnapshot (the mapper
// below copies it automatically) and teach the persona about the new property.
comptime {
    for (@typeInfo(HandlerProperties).@"struct".fields) |field| {
        if (field.type != bool) continue;
        if (!@hasField(ui_payload.PropertiesSnapshot, field.name)) {
            @compileError("pi PropertiesSnapshot is missing engine handler property '" ++
                field.name ++ "'; add it to ui_payload.PropertiesSnapshot so the expert surfaces it");
        }
    }
}

/// Map the engine's HandlerProperties onto pi's PropertiesSnapshot. Every
/// snapshot field is copied from the identically-named engine field by a
/// compile-time walk, so the mapper cannot drift: a snapshot field with no
/// engine counterpart fails to compile here, and a new engine property is caught
/// by the drift gate above.
pub fn propertiesSnapshot(properties: HandlerProperties) ui_payload.PropertiesSnapshot {
    var snap: ui_payload.PropertiesSnapshot = undefined;
    inline for (@typeInfo(ui_payload.PropertiesSnapshot).@"struct".fields) |field| {
        @field(snap, field.name) = @field(properties, field.name);
    }
    return snap;
}

fn loadPropertiesSnapshot(
    allocator: std.mem.Allocator,
    absolute_path: []const u8,
    source: ?[]const u8,
    sql_schema_path: ?[]const u8,
) !?ui_payload.PropertiesSnapshot {
    const content = source orelse return null;
    var result = try precompile.runCheckOnlyFromSourceWithOptions(allocator, content, absolute_path, .{
        .sql_schema_path = sql_schema_path,
        .json_mode = true,
    });
    defer result.deinit(allocator);

    if (result.properties) |properties| {
        return propertiesSnapshot(properties);
    }
    return null;
}

fn optionalPropertiesSnapshot(
    allocator: std.mem.Allocator,
    absolute_path: []const u8,
    source: ?[]const u8,
    sql_schema_path: ?[]const u8,
) !?ui_payload.PropertiesSnapshot {
    return loadPropertiesSnapshot(allocator, absolute_path, source, sql_schema_path) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => null,
    };
}

fn computeProveSummary(
    allocator: std.mem.Allocator,
    absolute_path: []const u8,
    before: ?[]const u8,
    after: []const u8,
    sql_schema_path: ?[]const u8,
) !?ui_payload.ProveSummary {
    const before_source = before orelse return null;

    var before_result = try precompile.runCheckOnlyFromSourceWithOptions(allocator, before_source, absolute_path, .{
        .sql_schema_path = sql_schema_path,
        .json_mode = true,
    });
    defer before_result.deinit(allocator);

    var after_result = try precompile.runCheckOnlyFromSourceWithOptions(allocator, after, absolute_path, .{
        .sql_schema_path = sql_schema_path,
        .json_mode = true,
    });
    defer after_result.deinit(allocator);

    if (before_result.contract) |*before_contract| {
        if (after_result.contract) |*after_contract| {
            var diff = try contract_diff.diffContracts(allocator, before_contract, after_contract);
            defer diff.deinit(allocator);
            const classification = diff.classify();
            const recommendation = try contract_diff.generateRecommendation(allocator, classification, &diff, null);
            defer allocator.free(recommendation);
            const laws = try allocator.alloc([]u8, diff.laws_used.items.len);
            errdefer allocator.free(laws);
            var i: usize = 0;
            errdefer {
                while (i > 0) {
                    i -= 1;
                    allocator.free(laws[i]);
                }
                allocator.free(laws);
            }
            while (i < diff.laws_used.items.len) : (i += 1) {
                laws[i] = try allocator.dupe(u8, diff.laws_used.items[i]);
            }

            return .{
                .classification = try allocator.dupe(u8, classification.toString()),
                .proof_level = try allocator.dupe(u8, zts.ContractProof.level(after_contract).toString()),
                .recommendation = try allocator.dupe(u8, recommendation),
                .counterexample = if (diff.canonical_counterexample) |counterexample|
                    try allocator.dupe(u8, counterexample)
                else
                    null,
                .laws_used = laws,
            };
        }
    }

    return null;
}

fn optionalProveSummary(
    allocator: std.mem.Allocator,
    absolute_path: []const u8,
    before: ?[]const u8,
    after: []const u8,
    sql_schema_path: ?[]const u8,
) !?ui_payload.ProveSummary {
    return computeProveSummary(allocator, absolute_path, before, after, sql_schema_path) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => null,
    };
}

fn resolveHandlerPath(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    file: []const u8,
) ![]u8 {
    const root = try normalizeWorkspaceRoot(allocator, workspace_root);
    defer allocator.free(root);
    return tools_common.resolveInsideWorkspace(allocator, root, file);
}

fn normalizeWorkspaceRoot(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
) ![]u8 {
    if (std.fs.path.isAbsolute(workspace_root)) {
        return std.fs.path.resolve(allocator, &.{workspace_root});
    }

    const cwd_real = tools_common.realCwd(allocator) catch {
        return std.fs.path.resolve(allocator, &.{workspace_root});
    };
    defer allocator.free(cwd_real);

    return std.fs.path.resolve(allocator, &.{ cwd_real, workspace_root });
}

fn collectRuleCitations(
    allocator: std.mem.Allocator,
    transcript: *const transcript_mod.Transcript,
) ![][]u8 {
    const start = blk: {
        var i = transcript.len();
        while (i > 0) {
            i -= 1;
            switch (transcript.at(i).*) {
                .user_text => break :blk i,
                else => {},
            }
        }
        break :blk 0;
    };

    var set: std.StringHashMapUnmanaged(void) = .empty;
    defer {
        var it = set.iterator();
        while (it.next()) |entry| allocator.free(entry.key_ptr.*);
        set.deinit(allocator);
    }

    var i = start;
    while (i < transcript.len()) : (i += 1) {
        const entry = transcript.at(i);
        switch (entry.*) {
            .model_text => |body| try scanRuleCodes(allocator, body, &set),
            else => {},
        }
    }

    const out = try allocator.alloc([]u8, set.count());
    errdefer allocator.free(out);
    var it = set.iterator();
    var index: usize = 0;
    while (it.next()) |entry| : (index += 1) {
        out[index] = try allocator.dupe(u8, entry.key_ptr.*);
    }
    std.mem.sort([]u8, out, {}, lessThanString);
    return out;
}

fn scanRuleCodes(
    allocator: std.mem.Allocator,
    text: []const u8,
    set: *std.StringHashMapUnmanaged(void),
) !void {
    var i: usize = 0;
    while (i + 6 <= text.len) : (i += 1) {
        if (!std.mem.eql(u8, text[i .. i + 3], "ZTS")) continue;
        if (!std.ascii.isDigit(text[i + 3]) or !std.ascii.isDigit(text[i + 4]) or !std.ascii.isDigit(text[i + 5])) {
            continue;
        }
        const code = text[i .. i + 6];
        if (set.contains(code)) continue;
        try set.put(allocator, try allocator.dupe(u8, code), {});
    }
}

pub const UnifiedDiff = struct {
    text: []u8,
    hunks: []ui_payload.DiffHunk,
};

pub fn buildUnifiedDiff(
    allocator: std.mem.Allocator,
    before: ?[]const u8,
    after: []const u8,
) !UnifiedDiff {
    const before_text = before orelse "";
    if (std.mem.eql(u8, before_text, after)) {
        return .{
            .text = try allocator.alloc(u8, 0),
            .hunks = try allocator.alloc(ui_payload.DiffHunk, 0),
        };
    }

    const before_line_count = lineCount(before_text);
    const after_line_count = lineCount(after);
    var buf = TextBuffer.init(allocator);
    defer buf.deinit();
    const w = buf.writer();

    try w.print(
        "@@ -{d},{d} +{d},{d} @@\n",
        .{
            if (before_line_count == 0) @as(u32, 0) else @as(u32, 1),
            before_line_count,
            if (after_line_count == 0) @as(u32, 0) else @as(u32, 1),
            after_line_count,
        },
    );
    try appendPrefixedLines(w, '-', before_text);
    try appendPrefixedLines(w, '+', after);

    const hunks = try allocator.alloc(ui_payload.DiffHunk, 1);
    errdefer allocator.free(hunks);
    hunks[0] = .{
        .old_start = if (before_line_count == 0) 0 else 1,
        .old_count = before_line_count,
        .new_start = if (after_line_count == 0) 0 else 1,
        .new_count = after_line_count,
    };
    return .{
        .text = try buf.toOwnedSlice(),
        .hunks = hunks,
    };
}

fn appendPrefixedLines(
    w: *std.Io.Writer,
    prefix: u8,
    text: []const u8,
) !void {
    if (text.len == 0) return;
    var start: usize = 0;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (text[i] != '\n') continue;
        try w.writeByte(prefix);
        try w.writeAll(text[start .. i + 1]);
        start = i + 1;
    }
    if (start < text.len) {
        try w.writeByte(prefix);
        try w.writeAll(text[start..]);
        try w.writeByte('\n');
    }
}

fn lineCount(text: []const u8) u32 {
    if (text.len == 0) return 0;
    var count: u32 = @intCast(std.mem.count(u8, text, "\n"));
    if (text[text.len - 1] != '\n') count += 1;
    return count;
}

fn copyViolations(
    allocator: std.mem.Allocator,
    violations: []const edit_simulate.SimulatedViolation,
) ![]ui_payload.ViolationDeltaItem {
    const out = try allocator.alloc(ui_payload.ViolationDeltaItem, violations.len);
    errdefer allocator.free(out);
    for (out) |*item| item.* = undefined;
    var i: usize = 0;
    errdefer {
        while (i > 0) {
            i -= 1;
            out[i].deinit(allocator);
        }
        allocator.free(out);
    }
    while (i < violations.len) : (i += 1) {
        const stable_key = try stableViolationKey(allocator, violations[i].code, violations[i].message);
        defer allocator.free(stable_key);
        out[i] = try ui_payload.ViolationDeltaItem.init(
            allocator,
            stable_key,
            violations[i].code,
            violations[i].severity,
            violations[i].message,
            violations[i].line,
            violations[i].column,
            violations[i].introduced_by_patch,
        );
    }
    return out;
}

fn stableViolationKey(
    allocator: std.mem.Allocator,
    code: []const u8,
    message: []const u8,
) ![]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(code);
    hasher.update("\x00");
    hasher.update(message);
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    hasher.final(&digest);

    const out = try allocator.alloc(u8, digest.len * 2);
    @memcpy(out, &std.fmt.bytesToHex(digest, .lower));
    return out;
}

fn lessThanString(_: void, a: []u8, b: []u8) bool {
    return std.mem.lessThan(u8, a, b);
}

const testing = std.testing;
const IsolatedTmp = @import("test_support/tmp.zig").IsolatedTmp;

fn initTmp(allocator: std.mem.Allocator) !IsolatedTmp {
    return IsolatedTmp.init(allocator, "proof-enrichment");
}

test "propertiesSnapshot maps full handler properties surface" {
    const snapshot = propertiesSnapshot(.{
        .pure = true,
        .read_only = false,
        .stateless = true,
        .retry_safe = true,
        .deterministic = true,
        .has_egress = false,
        .no_secret_leakage = true,
        .no_credential_leakage = true,
        .input_validated = true,
        .pii_contained = true,
        .idempotent = true,
        .max_io_depth = 2,
        .injection_safe = true,
        .state_isolated = true,
        .fault_covered = false,
        .result_safe = true,
        .optional_safe = false,
        .cost_bounded = true,
        .post_only = true,
    });

    try testing.expect(snapshot.stateless);
    try testing.expectEqual(@as(?u32, 2), snapshot.max_io_depth);
    try testing.expect(snapshot.result_safe);
    try testing.expect(!snapshot.optional_safe);
    // The Cost Contracts dimension and post_only must round-trip through the
    // comptime field copy, not be silently dropped as they were before #6.
    try testing.expect(snapshot.cost_bounded);
    try testing.expect(snapshot.post_only);
}

test "resolveHandlerPath rejects absolute paths outside workspace" {
    try testing.expectError(
        error.PathOutsideWorkspace,
        resolveHandlerPath(testing.allocator, "/tmp/zttp-proof-workspace", "/etc/passwd"),
    );
}

test "analyzePatch returns prove classification and rule citations" {
    const workspace_root = try tools_common.workspaceRoot(testing.allocator);
    defer testing.allocator.free(workspace_root);

    var transcript: transcript_mod.Transcript = .{};
    defer transcript.deinit(testing.allocator);
    try transcript.append(testing.allocator, .{ .user_text = "make handler additive" });
    try transcript.append(testing.allocator, .{ .model_text = "Preserve ZTS204 and add a new route without breaking the old one." });

    var analysis = try analyzePatch(
        testing.allocator,
        workspace_root,
        "handler.ts",
        "function handler(req: Request): Response { return Response.json({ ok: true }); }",
        "import { env } from \"zttp:env\";\nfunction handler(req: Request): Response { return Response.json({ ok: true, region: env(\"REGION\") }); }",
        &transcript,
    );
    defer analysis.deinit(testing.allocator);

    try testing.expectEqual(@as(u32, 0), analysis.stats.new);
    try testing.expect(analysis.after_properties != null);
    try testing.expect(analysis.prove != null);
    try testing.expectEqualStrings("additive", analysis.prove.?.classification);
    try testing.expectEqual(@as(usize, 1), analysis.rule_citations.len);
    try testing.expectEqualStrings("ZTS204", analysis.rule_citations[0]);
    try testing.expect(analysis.hunks.len == 1);
}

test "buildUnifiedDiff emits empty diff for identical content" {
    const diff = try buildUnifiedDiff(testing.allocator, "same\n", "same\n");
    defer testing.allocator.free(diff.text);
    defer testing.allocator.free(diff.hunks);

    try testing.expectEqual(@as(usize, 0), diff.text.len);
    try testing.expectEqual(@as(usize, 0), diff.hunks.len);
}
