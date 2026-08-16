//! Evidence-led classification of model-authored first-draft failures.
//!
//! The classifier uses only the transcript's ordered tool calls, the input
//! mode, and the first compiler diagnostic. It does not infer intent from
//! prose. A transport or harness failure has no model draft to classify and
//! stays in the separate qualification failure taxonomy.

const std = @import("std");
const codegen_types = @import("expert_codegen_types.zig");
const qualification = @import("expert_qualification.zig");
const transcript_mod = @import("transcript.zig");

pub const max_contributors: usize = 3;

pub const Analysis = struct {
    primary: qualification.DraftFailureCause,
    contributor_buf: [max_contributors]qualification.DraftFailureCause = undefined,
    contributor_len: u8 = 0,
    diagnostic_buf: [8]u8 = undefined,
    diagnostic_len: u8 = 0,
    transcript_entry: ?usize = null,
    tool_name: ?ToolKind = null,

    pub fn contributors(self: *const Analysis) []const qualification.DraftFailureCause {
        return self.contributor_buf[0..self.contributor_len];
    }

    pub fn diagnosticCode(self: *const Analysis) ?[]const u8 {
        return if (self.diagnostic_len == 0) null else self.diagnostic_buf[0..self.diagnostic_len];
    }

    pub fn toolName(self: Analysis) ?[]const u8 {
        return if (self.tool_name) |kind| kind.name() else null;
    }

    pub fn asDraftFailure(self: *const Analysis) qualification.DraftFailure {
        return .{
            .primary = self.primary,
            .contributors = self.contributors(),
            .evidence = .{
                .diagnostic_code = self.diagnosticCode(),
                .transcript_entry = self.transcript_entry,
                .tool_name = self.toolName(),
            },
        };
    }

    fn addContributor(self: *Analysis, cause: qualification.DraftFailureCause) void {
        if (cause == self.primary) return;
        for (self.contributors()) |existing| if (existing == cause) return;
        if (self.contributor_len == self.contributor_buf.len) return;
        self.contributor_buf[self.contributor_len] = cause;
        self.contributor_len += 1;
    }

    fn setDiagnostic(self: *Analysis, code: ?[]const u8) void {
        const value = code orelse return;
        const len = @min(value.len, self.diagnostic_buf.len);
        @memcpy(self.diagnostic_buf[0..len], value[0..len]);
        self.diagnostic_len = @intCast(len);
    }
};

const ToolKind = enum {
    query,
    fill_hole,
    propose_change_set,

    fn name(self: ToolKind) []const u8 {
        return switch (self) {
            .query => "zts_expert_query",
            .fill_hole => "zts_expert_fill_hole",
            .propose_change_set => "propose_change_set",
        };
    }
};

const CallEvidence = struct {
    first_query_entry: ?usize = null,
    first_authoring_entry: ?usize = null,
    first_authoring_tool: ?ToolKind = null,
    exact_fact_before_authoring: bool = false,
    first_diagnostic_entry: ?usize = null,
};

fn isCompilerQuery(name: []const u8) bool {
    return std.mem.eql(u8, name, "zts_expert_query") or
        std.mem.startsWith(u8, name, "zts_expert_verify_") or
        std.mem.eql(u8, name, "zts_expert_prove_patch") or
        std.mem.eql(u8, name, "zts_expert_system_proof");
}

fn authoringTool(name: []const u8) ?ToolKind {
    if (std.mem.eql(u8, name, "zts_expert_fill_hole")) return .fill_hole;
    if (std.mem.eql(u8, name, "propose_change_set")) return .propose_change_set;
    return null;
}

fn queryDescribesCode(
    allocator: std.mem.Allocator,
    args_json: []const u8,
    diagnostic_code: ?[]const u8,
) bool {
    const code = diagnostic_code orelse return false;
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, args_json, .{}) catch return false;
    defer parsed.deinit();
    if (parsed.value != .object) return false;
    const operation = parsed.value.object.get("operation") orelse return false;
    const requested_code = parsed.value.object.get("code") orelse return false;
    return operation == .string and requested_code == .string and
        std.mem.eql(u8, operation.string, "describe_rule") and
        std.mem.eql(u8, requested_code.string, code);
}

fn collectEvidence(
    allocator: std.mem.Allocator,
    transcript: *const transcript_mod.Transcript,
    diagnostic_code: ?[]const u8,
) CallEvidence {
    var out: CallEvidence = .{};
    for (transcript.entries.items, 0..) |entry, entry_index| switch (entry) {
        .assistant_tool_use => |calls| for (calls) |call| {
            if (isCompilerQuery(call.name) and out.first_query_entry == null) {
                out.first_query_entry = entry_index;
            }
            if (std.mem.eql(u8, call.name, "zts_expert_query") and
                out.first_authoring_entry == null and
                queryDescribesCode(allocator, call.args_json, diagnostic_code))
            {
                out.exact_fact_before_authoring = true;
            }
            if (authoringTool(call.name)) |kind| {
                if (out.first_authoring_entry == null) {
                    out.first_authoring_entry = entry_index;
                    out.first_authoring_tool = kind;
                }
            }
        },
        .diagnostic_box => if (out.first_diagnostic_entry == null) {
            out.first_diagnostic_entry = entry_index;
        },
        else => {},
    };
    return out;
}

/// Classify one observed model-authored draft that did not pass unchanged.
/// Callers must not invoke this for transport or harness failures, because
/// those runs contain no draft from which an authoring diagnosis can be made.
pub fn analyze(
    allocator: std.mem.Allocator,
    mode: codegen_types.InputMode,
    transcript: *const transcript_mod.Transcript,
    diagnostic_code: ?[]const u8,
) Analysis {
    const evidence = collectEvidence(allocator, transcript, diagnostic_code);
    const wrong_route = switch (mode) {
        .whole_file => evidence.first_authoring_tool == .fill_hole,
        .holes => evidence.first_authoring_tool != .fill_hole,
    };
    const bad_order = if (evidence.first_authoring_entry) |authoring|
        evidence.first_query_entry == null or authoring < evidence.first_query_entry.?
    else
        true;
    const missing_fact = diagnostic_code != null and !evidence.exact_fact_before_authoring;

    const primary: qualification.DraftFailureCause = if (wrong_route)
        .wrong_route
    else if (bad_order)
        .bad_tool_order
    else if (missing_fact)
        .missing_fact
    else
        .source_shape;

    var out: Analysis = .{
        .primary = primary,
        .transcript_entry = switch (primary) {
            .wrong_route, .bad_tool_order => evidence.first_authoring_entry,
            .missing_fact, .source_shape => evidence.first_diagnostic_entry,
        },
        .tool_name = switch (primary) {
            .wrong_route, .bad_tool_order => evidence.first_authoring_tool,
            .missing_fact, .source_shape => null,
        },
    };
    out.setDiagnostic(diagnostic_code);
    if (wrong_route) out.addContributor(.wrong_route);
    if (bad_order) out.addContributor(.bad_tool_order);
    if (missing_fact) out.addContributor(.missing_fact);
    out.addContributor(.source_shape);
    return out;
}

fn appendToolCall(
    transcript: *transcript_mod.Transcript,
    name: []const u8,
    args_json: []const u8,
) !void {
    const calls = [_]@import("turn.zig").ToolCall{.{
        .id = name,
        .name = name,
        .args_json = args_json,
    }};
    try transcript.append(std.testing.allocator, .{ .assistant_tool_use = &calls });
}

test "failure classifier distinguishes route order fact and source shape" {
    var wrong_route: transcript_mod.Transcript = .{};
    defer wrong_route.deinit(std.testing.allocator);
    try appendToolCall(&wrong_route, "zts_expert_query", "{\"operation\":\"holes\"}");
    try appendToolCall(&wrong_route, "propose_change_set", "{}");
    try std.testing.expectEqual(
        qualification.DraftFailureCause.wrong_route,
        analyze(std.testing.allocator, .holes, &wrong_route, "ZTS001").primary,
    );

    var bad_order: transcript_mod.Transcript = .{};
    defer bad_order.deinit(std.testing.allocator);
    try appendToolCall(&bad_order, "propose_change_set", "{}");
    try appendToolCall(&bad_order, "zts_expert_query", "{\"operation\":\"describe_rule\",\"code\":\"ZTS001\"}");
    try std.testing.expectEqual(
        qualification.DraftFailureCause.bad_tool_order,
        analyze(std.testing.allocator, .whole_file, &bad_order, "ZTS001").primary,
    );

    var missing_fact: transcript_mod.Transcript = .{};
    defer missing_fact.deinit(std.testing.allocator);
    try appendToolCall(&missing_fact, "zts_expert_query", "{\"operation\":\"modules\"}");
    try appendToolCall(&missing_fact, "propose_change_set", "{}");
    try std.testing.expectEqual(
        qualification.DraftFailureCause.missing_fact,
        analyze(std.testing.allocator, .whole_file, &missing_fact, "ZTS001").primary,
    );

    var source_shape: transcript_mod.Transcript = .{};
    defer source_shape.deinit(std.testing.allocator);
    try appendToolCall(
        &source_shape,
        "zts_expert_query",
        "{\"operation\":\"describe_rule\",\"code\":\"ZTS001\"}",
    );
    try appendToolCall(&source_shape, "propose_change_set", "{}");
    const analysis = analyze(std.testing.allocator, .whole_file, &source_shape, "ZTS001");
    try std.testing.expectEqual(qualification.DraftFailureCause.source_shape, analysis.primary);
    try std.testing.expectEqualStrings("ZTS001", analysis.diagnosticCode().?);
}
