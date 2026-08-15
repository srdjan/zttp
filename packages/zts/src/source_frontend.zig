//! One source-preparation boundary for every parser consumer.
//!
//! This module owns extension classification, TypeScript stripping, TSX
//! lowering, the parser input, and the source-position view. Callers still
//! choose their parser and semantic options, but they cannot independently
//! decide which bytes the core parser sees.

const std = @import("std");
const stripper = @import("stripper.zig");
const tsx_lowerer = @import("tsx_lowerer.zig");
const TypeMap = @import("zts-base").type_map.TypeMap;

/// Current source classifications. The two legacy rows are explicit so the
/// model-minimal cutover can refuse them at this single boundary instead of
/// rediscovering extension policy in every caller. A path with no recognized
/// source extension remains available for in-memory and generated snippets.
pub const SourceKind = enum {
    typescript,
    tsx,
    legacy_javascript,
    legacy_jsx,
    virtual_javascript,
    unsupported,

    pub fn isTyped(self: SourceKind) bool {
        return self == .typescript or self == .tsx;
    }

    pub fn isSupportedFile(self: SourceKind) bool {
        return self == .typescript or self == .tsx;
    }
};

pub fn classifyPath(path: []const u8) SourceKind {
    if (std.mem.endsWith(u8, path, ".tsx")) return .tsx;
    if (std.mem.endsWith(u8, path, ".ts")) return .typescript;
    if (std.mem.endsWith(u8, path, ".jsx")) return .legacy_jsx;
    if (std.mem.endsWith(u8, path, ".js")) return .legacy_javascript;
    if (path.len >= 2 and path[0] == '<' and path[path.len - 1] == '>') return .virtual_javascript;
    return .unsupported;
}

pub const PrepareDiagnostic = tsx_lowerer.Diagnostic;
pub const PrepareDiagnosticKind = tsx_lowerer.DiagnosticKind;
pub const PrepareError = stripper.StripError || tsx_lowerer.Error || error{UnsupportedSourceExtension};

/// Owned preprocessing result. `original_source` and `path` are borrowed;
/// stripped code, type facts, diagnostics, and source-map edits are owned by
/// `strip_result` when the classified source is typed.
pub const PreparedSource = struct {
    original_source: []const u8,
    path: []const u8,
    kind: SourceKind,
    strip_result: ?stripper.StripResult = null,
    lower_result: ?tsx_lowerer.Result = null,

    pub fn init(
        allocator: std.mem.Allocator,
        source: []const u8,
        path: []const u8,
        options: stripper.StripOptions,
    ) PrepareError!PreparedSource {
        return initWithDiagnostic(allocator, source, path, options, null);
    }

    pub fn initWithDiagnostic(
        allocator: std.mem.Allocator,
        source: []const u8,
        path: []const u8,
        options: stripper.StripOptions,
        diagnostic_out: ?*?PrepareDiagnostic,
    ) PrepareError!PreparedSource {
        if (diagnostic_out) |out| out.* = null;
        const kind = classifyPath(path);
        switch (kind) {
            .legacy_javascript, .legacy_jsx, .unsupported => return error.UnsupportedSourceExtension,
            .typescript, .tsx, .virtual_javascript => {},
        }
        var result = PreparedSource{
            .original_source = source,
            .path = path,
            .kind = kind,
        };
        if (kind.isTyped()) {
            var derived_options = options;
            derived_options.tsx_mode = kind == .tsx;
            result.strip_result = try stripper.strip(allocator, source, derived_options);
        }
        if (kind == .tsx) {
            var lower_diagnostic: ?tsx_lowerer.Diagnostic = null;
            result.lower_result = tsx_lowerer.lower(
                allocator,
                result.strip_result.?.code,
                &lower_diagnostic,
            ) catch |err| {
                if (lower_diagnostic) |diagnostic| {
                    const at = result.strip_result.?.sourcePosition(source, diagnostic.line, diagnostic.column);
                    if (diagnostic_out) |out| out.* = .{
                        .kind = diagnostic.kind,
                        .line = at.line,
                        .column = at.column,
                    };
                }
                result.deinit();
                return err;
            };
        }
        return result;
    }

    pub fn deinit(self: *PreparedSource) void {
        if (self.lower_result) |*result| result.deinit();
        self.lower_result = null;
        if (self.strip_result) |*result| result.deinit();
        self.strip_result = null;
    }

    pub fn parserInput(self: *const PreparedSource) []const u8 {
        if (self.lower_result) |result| return result.code;
        return if (self.strip_result) |result| result.code else self.original_source;
    }

    pub fn typeMap(self: *PreparedSource) ?*TypeMap {
        return if (self.strip_result) |*result| &result.type_map else null;
    }

    pub fn stripDiagnostics(self: *const PreparedSource) []const stripper.StripDiagnostic {
        return if (self.strip_result) |result| result.diagnostics else &.{};
    }

    pub fn sourceView(self: *const PreparedSource) stripper.SourceView {
        if (self.lower_result) |*lowered| {
            return stripper.SourceView.transformed(
                self.original_source,
                &self.strip_result.?,
                lowered.code,
                lowered.span_edits,
            );
        }
        if (self.strip_result) |*result| return stripper.SourceView.stripped(self.original_source, result);
        return stripper.SourceView.of(self.original_source);
    }
};

test "classifyPath distinguishes typed, legacy, and virtual sources" {
    try std.testing.expectEqual(SourceKind.typescript, classifyPath("handler.ts"));
    try std.testing.expectEqual(SourceKind.typescript, classifyPath("types.d.ts"));
    try std.testing.expectEqual(SourceKind.tsx, classifyPath("view.tsx"));
    try std.testing.expectEqual(SourceKind.legacy_javascript, classifyPath("handler.js"));
    try std.testing.expectEqual(SourceKind.legacy_jsx, classifyPath("view.jsx"));
    try std.testing.expectEqual(SourceKind.virtual_javascript, classifyPath("<eval>"));
    try std.testing.expectEqual(SourceKind.unsupported, classifyPath("handler.mts"));
}

test "PreparedSource refuses legacy and unknown file extensions" {
    try std.testing.expectError(
        error.UnsupportedSourceExtension,
        PreparedSource.init(std.testing.allocator, "const value = 1;", "handler.js", .{}),
    );
    try std.testing.expectError(
        error.UnsupportedSourceExtension,
        PreparedSource.init(std.testing.allocator, "const view = <div />;", "handler.jsx", .{}),
    );
    try std.testing.expectError(
        error.UnsupportedSourceExtension,
        PreparedSource.init(std.testing.allocator, "const value = 1;", "handler.txt", .{}),
    );
}

test "PreparedSource derives stripping and lowers TSX before parsing" {
    const allocator = std.testing.allocator;

    var typed = try PreparedSource.init(allocator, "const name: string = \"Ada\";", "handler.ts", .{});
    defer typed.deinit();
    try std.testing.expect(typed.typeMap() != null);
    try std.testing.expect(std.mem.indexOf(u8, typed.parserInput(), ": string") == null);
    try std.testing.expectEqualStrings("const name: string = \"Ada\";", typed.sourceView().text);

    var tsx = try PreparedSource.init(allocator, "const view: string = <div />;", "view.tsx", .{});
    defer tsx.deinit();
    try std.testing.expect(tsx.typeMap() != null);
    try std.testing.expect(std.mem.indexOf(u8, tsx.parserInput(), "<div />") == null);
    try std.testing.expect(std.mem.indexOf(u8, tsx.parserInput(), "h(\"div\", null)") != null);

    var untyped = try PreparedSource.init(allocator, "const value = 1;", "<eval>", .{});
    defer untyped.deinit();
    try std.testing.expect(untyped.typeMap() == null);
    try std.testing.expectEqualStrings(untyped.original_source, untyped.parserInput());
}

test "PreparedSource reports malformed TSX in original coordinates" {
    var diagnostic: ?PrepareDiagnostic = null;
    try std.testing.expectError(
        error.InvalidTsx,
        PreparedSource.initWithDiagnostic(
            std.testing.allocator,
            "const view: string = (\n  <div><span /></section>\n);",
            "view.tsx",
            .{},
            &diagnostic,
        ),
    );
    try std.testing.expectEqual(PrepareDiagnosticKind.mismatched_tag, diagnostic.?.kind);
    try std.testing.expectEqual(@as(u32, 2), diagnostic.?.line);
    try std.testing.expectEqual(@as(u32, 16), diagnostic.?.column);
}

test "PreparedSource maps a post-TSX diagnostic back to authored source" {
    const source = "const view = <div />; const value = missing;";
    var prepared = try PreparedSource.init(std.testing.allocator, source, "view.tsx", .{});
    defer prepared.deinit();
    const parsed_at = std.mem.indexOf(u8, prepared.parserInput(), "missing").?;
    const source_at = std.mem.indexOf(u8, source, "missing").?;
    const mapped = prepared.sourceView().position(1, @intCast(parsed_at + 1));
    try std.testing.expectEqual(@as(u32, 1), mapped.line);
    try std.testing.expectEqual(@as(u32, @intCast(source_at + 1)), mapped.column);
}

test "PreparedSource maps an expression inside lowered TSX" {
    const source = "const view = <div>{missing}</div>;";
    var prepared = try PreparedSource.init(std.testing.allocator, source, "view.tsx", .{});
    defer prepared.deinit();
    const parsed_at = std.mem.indexOf(u8, prepared.parserInput(), "missing").?;
    const source_at = std.mem.indexOf(u8, source, "missing").?;
    const mapped = prepared.sourceView().position(1, @intCast(parsed_at + 1));
    try std.testing.expectEqual(@as(u32, @intCast(source_at + 1)), mapped.column);
}

test "PreparedSource closes every stripping allocation failure" {
    const Context = struct {
        fn run(allocator: std.mem.Allocator) !void {
            var prepared = try PreparedSource.init(
                allocator,
                "const name: string = \"Ada\"; const view = <div>{name}</div>;",
                "handler.tsx",
                .{},
            );
            defer prepared.deinit();
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Context.run, .{});
}
