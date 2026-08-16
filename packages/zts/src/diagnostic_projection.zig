//! Stable, borrowed projection of checker diagnostics for presentation layers.
//!
//! Consumers select the producer with `Source` instead of importing the five
//! checker-specific diagnostic types. The projection owns nothing; callers
//! that retain a message beyond the checker lifetime must copy it.

const std = @import("std");
const bool_checker = @import("bool_checker.zig");
const counterexample = @import("counterexample.zig");
const diagnostic_catalog = @import("diagnostic_catalog.zig");
const flow_checker = @import("flow_checker.zig");
const handler_verifier = @import("handler_verifier.zig");
const strict_checker = @import("strict_checker.zig");
const type_checker = @import("type_checker.zig");
const SourceLocation = @import("zts-engine").parser.SourceLocation;

pub const Source = enum {
    boolean,
    flow,
    verifier,
    strict,
    type,
};

pub const Severity = enum {
    err,
    warning,
    advisory,

    pub fn label(self: Severity) []const u8 {
        return switch (self) {
            .err => "error",
            .warning => "warning",
            .advisory => "advisory",
        };
    }
};

pub const Diagnostic = struct {
    code: []const u8,
    severity: Severity,
    message: []const u8,
    line: u32,
    column: u32,
    /// Half-open byte span of the token this diagnostic points at, in the
    /// bytes the source digest covers. `start == end` means the producer's
    /// location carried no extent (a synthetic or fallback position), and is
    /// reported as a point rather than padded to a width nothing measured.
    start_offset: u32,
    end_offset: u32,
    suggestion: ?[]const u8,
};

pub const CodeEntry = struct {
    source: Source,
    kind: []const u8,
    code: []const u8,
};

pub const FlowWitness = struct {
    property: counterexample.PropertyTag,
    line: u32,
    column: u32,
    summary: []const u8,
    constraints: []const counterexample.WitnessConstraint,
    io_calls: []const counterexample.TrackedIoCall,
};

pub fn code(comptime source: Source, kind: anytype) []const u8 {
    return switch (source) {
        .boolean => booleanCode(kind),
        .flow => flowCode(kind),
        .verifier => verifierCode(kind),
        .strict => strictCode(kind),
        .type => typeCode(kind),
    };
}

pub fn project(comptime source: Source, diagnostic: anytype, ir_view: anytype) ?Diagnostic {
    const location = ir_view.getLoc(diagnostic.node) orelse return null;
    const bytes = location.span();
    return .{
        .code = code(source, diagnostic.kind),
        .severity = projectSeverity(source, diagnostic.severity),
        .message = diagnostic.message,
        .line = location.line,
        .column = location.column,
        .start_offset = bytes.start,
        .end_offset = bytes.end,
        .suggestion = diagnostic.help,
    };
}

fn projectSeverity(comptime source: Source, severity: anytype) Severity {
    return switch (source) {
        .strict => switch (severity) {
            .err => .err,
            .warning => .warning,
            .advisory => .advisory,
        },
        .boolean, .flow, .verifier, .type => switch (severity) {
            .err => .err,
            .warning => .warning,
        },
    };
}

pub fn allCodes() []const CodeEntry {
    return &all_codes;
}

pub fn projectFlowWitness(diagnostic: anytype, ir_view: anytype) ?FlowWitness {
    const property = flow_checker.propertyTagForKind(diagnostic.kind) orelse return null;
    const location = ir_view.getLoc(diagnostic.node) orelse return null;
    const constraints: []const counterexample.WitnessConstraint =
        if (diagnostic.witness) |witness| witness.path_constraints else &.{};
    const io_calls: []const counterexample.TrackedIoCall =
        if (diagnostic.witness) |witness| witness.io_calls else &.{};
    return .{
        .property = property,
        .line = location.line,
        .column = location.column,
        .summary = diagnostic.message,
        .constraints = constraints,
        .io_calls = io_calls,
    };
}

fn booleanCode(kind: bool_checker.DiagnosticKind) []const u8 {
    return diagnostic_catalog.booleanCode(kind);
}

fn typeCode(kind: type_checker.DiagnosticKind) []const u8 {
    return diagnostic_catalog.typeCode(kind);
}

fn verifierCode(kind: handler_verifier.DiagnosticKind) []const u8 {
    return diagnostic_catalog.verifierCode(kind);
}

fn flowCode(kind: flow_checker.DiagnosticKind) []const u8 {
    return diagnostic_catalog.flowCode(kind);
}

fn strictCode(kind: strict_checker.DiagnosticKind) []const u8 {
    return diagnostic_catalog.strictCode(kind);
}

fn Kind(comptime source: Source) type {
    return switch (source) {
        .boolean => bool_checker.DiagnosticKind,
        .flow => flow_checker.DiagnosticKind,
        .verifier => handler_verifier.DiagnosticKind,
        .strict => strict_checker.DiagnosticKind,
        .type => type_checker.DiagnosticKind,
    };
}

const code_count = blk: {
    var count: usize = 0;
    for (std.meta.fields(Source)) |source_field| {
        const source: Source = @enumFromInt(source_field.value);
        count += std.meta.fields(Kind(source)).len;
    }
    break :blk count;
};

const all_codes: [code_count]CodeEntry = blk: {
    var entries: [code_count]CodeEntry = undefined;
    var index: usize = 0;
    for (std.meta.fields(Source)) |source_field| {
        const source: Source = @enumFromInt(source_field.value);
        const DiagnosticKind = Kind(source);
        for (std.meta.fields(DiagnosticKind)) |kind_field| {
            const kind: DiagnosticKind = @enumFromInt(kind_field.value);
            entries[index] = .{
                .source = source,
                .kind = kind_field.name,
                .code = code(source, kind),
            };
            index += 1;
        }
    }
    break :blk entries;
};

test "checker diagnostic codes are globally unique" {
    try std.testing.expectEqual(@as(usize, 69), allCodes().len);

    var seen: std.StringHashMapUnmanaged(CodeEntry) = .empty;
    defer seen.deinit(std.testing.allocator);

    for (allCodes()) |entry| {
        if (seen.get(entry.code)) |owner| {
            std.debug.print(
                "{s} names both {s}.{s} and {s}.{s}\n",
                .{ entry.code, @tagName(owner.source), owner.kind, @tagName(entry.source), entry.kind },
            );
            return error.DuplicateDiagnosticCode;
        }
        try seen.put(std.testing.allocator, entry.code, entry);
    }
}

test "project returns a borrowed diagnostic with source location" {
    const FakeIrView = struct {
        fn getLoc(_: @This(), node: u32) ?SourceLocation {
            if (node != 7) return null;
            return .{ .line = 11, .column = 13, .offset = 40, .end_offset = 43 };
        }
    };
    const diagnostic: bool_checker.Diagnostic = .{
        .severity = .warning,
        .kind = .tautological_comparison,
        .node = 7,
        .message = "comparison is constant",
        .help = "remove the comparison",
    };

    const projected = project(.boolean, diagnostic, FakeIrView{}).?;
    try std.testing.expectEqualStrings("ZTS107", projected.code);
    try std.testing.expectEqual(Severity.warning, projected.severity);
    try std.testing.expectEqualStrings("comparison is constant", projected.message);
    try std.testing.expectEqual(@as(u32, 11), projected.line);
    try std.testing.expectEqual(@as(u32, 13), projected.column);
    try std.testing.expectEqual(@as(u32, 40), projected.start_offset);
    try std.testing.expectEqual(@as(u32, 43), projected.end_offset);
    try std.testing.expectEqualStrings("remove the comparison", projected.suggestion.?);

    var missing = diagnostic;
    missing.node = 8;
    try std.testing.expect(project(.boolean, missing, FakeIrView{}) == null);
}

test "projectFlowWitness isolates persistence inputs" {
    const Location = struct { line: u32, column: u32 };
    const FakeIrView = struct {
        fn getLoc(_: @This(), node: u32) ?Location {
            if (node != 9) return null;
            return .{ .line = 17, .column = 4 };
        }
    };
    const diagnostic: flow_checker.Diagnostic = .{
        .severity = .err,
        .kind = .secret_in_response,
        .node = 9,
        .message = "secret reaches response",
        .help = "redact the value",
    };

    const projected = projectFlowWitness(diagnostic, FakeIrView{}).?;
    try std.testing.expectEqual(counterexample.PropertyTag.no_secret_leakage, projected.property);
    try std.testing.expectEqual(@as(u32, 17), projected.line);
    try std.testing.expectEqual(@as(u32, 4), projected.column);
    try std.testing.expectEqualStrings("secret reaches response", projected.summary);
    try std.testing.expectEqual(@as(usize, 0), projected.constraints.len);
    try std.testing.expectEqual(@as(usize, 0), projected.io_calls.len);
}

test "stable severities preserve wire order and labels" {
    const expected = [_][]const u8{ "error", "warning", "advisory" };
    inline for (std.meta.fields(Severity), expected) |field, label| {
        const severity: Severity = @enumFromInt(field.value);
        try std.testing.expectEqualStrings(label, severity.label());
    }
}
