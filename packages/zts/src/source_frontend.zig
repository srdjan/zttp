//! One source-preparation boundary for every parser consumer.
//!
//! This module owns extension classification, TypeScript stripping, JSX-mode
//! selection, the parser input, and the source-position view. Callers still
//! choose their parser and semantic options, but they cannot independently
//! decide which bytes or syntax mode that parser sees.

const std = @import("std");
const stripper = @import("stripper.zig");
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

    pub fn isTyped(self: SourceKind) bool {
        return self == .typescript or self == .tsx;
    }

    pub fn enablesJsx(self: SourceKind) bool {
        return self == .tsx or self == .legacy_jsx;
    }
};

pub fn classifyPath(path: []const u8) SourceKind {
    if (std.mem.endsWith(u8, path, ".tsx")) return .tsx;
    if (std.mem.endsWith(u8, path, ".ts")) return .typescript;
    if (std.mem.endsWith(u8, path, ".jsx")) return .legacy_jsx;
    if (std.mem.endsWith(u8, path, ".js")) return .legacy_javascript;
    return .virtual_javascript;
}

/// Owned preprocessing result. `original_source` and `path` are borrowed;
/// stripped code, type facts, diagnostics, and source-map edits are owned by
/// `strip_result` when the classified source is typed.
pub const PreparedSource = struct {
    original_source: []const u8,
    path: []const u8,
    kind: SourceKind,
    strip_result: ?stripper.StripResult = null,

    pub fn init(
        allocator: std.mem.Allocator,
        source: []const u8,
        path: []const u8,
        options: stripper.StripOptions,
    ) stripper.StripError!PreparedSource {
        const kind = classifyPath(path);
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
        return result;
    }

    pub fn deinit(self: *PreparedSource) void {
        if (self.strip_result) |*result| result.deinit();
        self.strip_result = null;
    }

    pub fn parserInput(self: *const PreparedSource) []const u8 {
        return if (self.strip_result) |result| result.code else self.original_source;
    }

    pub fn enablesJsx(self: *const PreparedSource) bool {
        return self.kind.enablesJsx();
    }

    pub fn typeMap(self: *PreparedSource) ?*TypeMap {
        return if (self.strip_result) |*result| &result.type_map else null;
    }

    pub fn stripDiagnostics(self: *const PreparedSource) []const stripper.StripDiagnostic {
        return if (self.strip_result) |result| result.diagnostics else &.{};
    }

    pub fn sourceView(self: *const PreparedSource) stripper.SourceView {
        return if (self.strip_result) |*result|
            stripper.SourceView.stripped(self.original_source, result)
        else
            stripper.SourceView.of(self.original_source);
    }
};

test "classifyPath distinguishes typed, legacy, and virtual sources" {
    try std.testing.expectEqual(SourceKind.typescript, classifyPath("handler.ts"));
    try std.testing.expectEqual(SourceKind.typescript, classifyPath("types.d.ts"));
    try std.testing.expectEqual(SourceKind.tsx, classifyPath("view.tsx"));
    try std.testing.expectEqual(SourceKind.legacy_javascript, classifyPath("handler.js"));
    try std.testing.expectEqual(SourceKind.legacy_jsx, classifyPath("view.jsx"));
    try std.testing.expectEqual(SourceKind.virtual_javascript, classifyPath("<eval>"));
}

test "PreparedSource derives stripping and JSX mode from the path" {
    const allocator = std.testing.allocator;

    var typed = try PreparedSource.init(allocator, "const name: string = \"Ada\";", "handler.ts", .{});
    defer typed.deinit();
    try std.testing.expect(typed.typeMap() != null);
    try std.testing.expect(!typed.enablesJsx());
    try std.testing.expect(std.mem.indexOf(u8, typed.parserInput(), ": string") == null);
    try std.testing.expectEqualStrings("const name: string = \"Ada\";", typed.sourceView().text);

    var tsx = try PreparedSource.init(allocator, "const view: string = <div />;", "view.tsx", .{});
    defer tsx.deinit();
    try std.testing.expect(tsx.typeMap() != null);
    try std.testing.expect(tsx.enablesJsx());
    try std.testing.expect(std.mem.indexOf(u8, tsx.parserInput(), "<div />") != null);

    var untyped = try PreparedSource.init(allocator, "const value = 1;", "<eval>", .{});
    defer untyped.deinit();
    try std.testing.expect(untyped.typeMap() == null);
    try std.testing.expect(!untyped.enablesJsx());
    try std.testing.expectEqualStrings(untyped.original_source, untyped.parserInput());
}

test "PreparedSource closes every stripping allocation failure" {
    const Context = struct {
        fn run(allocator: std.mem.Allocator) !void {
            var prepared = try PreparedSource.init(
                allocator,
                "const name: string = \"Ada\";",
                "handler.ts",
                .{},
            );
            defer prepared.deinit();
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Context.run, .{});
}
