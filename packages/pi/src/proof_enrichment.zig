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
    for (@typeInfo(HandlerProperties).@"struct".field_names) |field| {
        if (@FieldType(HandlerProperties, field) != bool) continue;
        if (!@hasField(ui_payload.PropertiesSnapshot, field)) {
            @compileError("pi PropertiesSnapshot is missing engine handler property '" ++
                field ++ "'; add it to ui_payload.PropertiesSnapshot so the expert surfaces it");
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
    inline for (@typeInfo(ui_payload.PropertiesSnapshot).@"struct".field_names) |field| {
        @field(snap, field) = @field(properties, field);
    }
    return snap;
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
            var diff = try contract_diff.diffContractsFromSources(allocator, before_contract, after_contract, before_source, after);
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

test "buildUnifiedDiff emits empty diff for identical content" {
    const diff = try buildUnifiedDiff(testing.allocator, "same\n", "same\n");
    defer testing.allocator.free(diff.text);
    defer testing.allocator.free(diff.hunks);

    try testing.expectEqual(@as(usize, 0), diff.text.len);
    try testing.expectEqual(@as(usize, 0), diff.hunks.len);
}
