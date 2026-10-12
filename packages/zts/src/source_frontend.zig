//! One source-preparation boundary for every parser consumer.
//!
//! This module owns extension classification, TypeScript stripping, the parser
//! input, and the source-position view.

const std = @import("std");
const stripper = @import("stripper.zig");
const TypeMap = @import("zts-base").type_map.TypeMap;

pub const SourceKind = enum {
    typescript,
    virtual_javascript,
    unsupported,

    pub fn isTyped(self: SourceKind) bool {
        return self == .typescript;
    }

    pub fn isSupportedFile(self: SourceKind) bool {
        return self == .typescript;
    }
};

pub fn classifyPath(path: []const u8) SourceKind {
    if (std.mem.endsWith(u8, path, ".ts")) return .typescript;
    if (path.len >= 2 and path[0] == '<' and path[path.len - 1] == '>') return .virtual_javascript;
    return .unsupported;
}

pub const PrepareError = stripper.StripError || error{UnsupportedSourceExtension};

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
    ) PrepareError!PreparedSource {
        const kind = classifyPath(path);
        switch (kind) {
            .unsupported => return error.UnsupportedSourceExtension,
            .typescript, .virtual_javascript => {},
        }
        var result = PreparedSource{
            .original_source = source,
            .path = path,
            .kind = kind,
        };
        if (kind.isTyped()) result.strip_result = try stripper.strip(allocator, source, options);
        return result;
    }

    pub fn deinit(self: *PreparedSource) void {
        if (self.strip_result) |*result| result.deinit();
        self.strip_result = null;
    }

    pub fn parserInput(self: *const PreparedSource) []const u8 {
        return if (self.strip_result) |result| result.code else self.original_source;
    }

    pub fn typeMap(self: *PreparedSource) ?*TypeMap {
        return if (self.strip_result) |*result| &result.type_map else null;
    }

    pub fn stripDiagnostics(self: *const PreparedSource) []const stripper.StripDiagnostic {
        return if (self.strip_result) |result| result.diagnostics else &.{};
    }

    pub fn sourceView(self: *const PreparedSource) stripper.SourceView {
        var view = if (self.strip_result) |*result|
            stripper.SourceView.stripped(self.original_source, result)
        else
            stripper.SourceView.of(self.original_source);
        view.name = self.path;
        return view;
    }
};

test "classifyPath supports TypeScript and refuses legacy source extensions" {
    try std.testing.expectEqual(SourceKind.typescript, classifyPath("handler.ts"));
    try std.testing.expectEqual(SourceKind.typescript, classifyPath("types.d.ts"));
    try std.testing.expectEqual(SourceKind.unsupported, classifyPath("view.tsx"));
    try std.testing.expectEqual(SourceKind.unsupported, classifyPath("handler.js"));
    try std.testing.expectEqual(SourceKind.unsupported, classifyPath("view.jsx"));
    try std.testing.expectEqual(SourceKind.virtual_javascript, classifyPath("<eval>"));
    try std.testing.expectEqual(SourceKind.unsupported, classifyPath("handler.mts"));
}

test "PreparedSource refuses unsupported file extensions" {
    const cases = [_][]const u8{ "handler.js", "handler.jsx", "handler.tsx", "handler.txt" };
    for (cases) |path| {
        try std.testing.expectError(
            error.UnsupportedSourceExtension,
            PreparedSource.init(std.testing.allocator, "const value = 1;", path, .{}),
        );
    }
}

test "PreparedSource strips TypeScript and preserves virtual source" {
    const allocator = std.testing.allocator;

    var typed = try PreparedSource.init(allocator, "const name: string = \"Ada\";", "handler.ts", .{});
    defer typed.deinit();
    try std.testing.expect(typed.typeMap() != null);
    try std.testing.expect(std.mem.indexOf(u8, typed.parserInput(), ": string") == null);
    try std.testing.expectEqualStrings("const name: string = \"Ada\";", typed.sourceView().text);

    var virtual = try PreparedSource.init(allocator, "const value = 1;", "<eval>", .{});
    defer virtual.deinit();
    try std.testing.expect(virtual.typeMap() == null);
    try std.testing.expectEqualStrings(virtual.original_source, virtual.parserInput());
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
