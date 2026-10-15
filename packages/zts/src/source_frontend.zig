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

test "PreparedSource characterizes every type map kind" {
    const TypeMapKind = @import("zts-base").type_map.TypeMapKind;
    const source =
        \\structural Box<T> = { value: T } & { meta: string };
        \\nominal UserId = string;
        \\function keep<T>(value: T): Box<T> { return { value: value, meta: "kept" }; }
        \\function isText(value: unknown): value is string { return typeof value === "string"; }
        \\const boxed: Box<string> = keep<Box<string>>({ value: "x", meta: "m" });
        \\const tolerant: string ignored_suffix = "kept";
    ;

    var prepared = try PreparedSource.init(std.testing.allocator, source, "types.ts", .{});
    defer prepared.deinit();

    const type_map = prepared.typeMap().?;
    var seen = std.EnumSet(TypeMapKind).initEmpty();
    var alias_count: usize = 0;
    var distinct_count: usize = 0;
    var variable_count: usize = 0;
    var parameter_count: usize = 0;
    var return_count: usize = 0;
    var guard_count: usize = 0;
    var generic_count: usize = 0;
    var call_argument_count: usize = 0;
    var saw_t_parameter = false;
    var saw_unknown_parameter = false;
    var saw_alias_generic = false;
    var saw_function_generic = false;

    for (type_map.entries.items) |entry| {
        seen.insert(entry.kind);
        switch (entry.kind) {
            .type_alias => {
                alias_count += 1;
                try std.testing.expectEqualStrings("Box", type_map.getNameText(entry).?);
                try std.testing.expectEqualStrings("{ value: T } & { meta: string }", type_map.getTypeText(entry));
                try std.testing.expect(entry.signature_offset == null);
            },
            .distinct_type => {
                distinct_count += 1;
                try std.testing.expectEqualStrings("UserId", type_map.getNameText(entry).?);
                try std.testing.expectEqualStrings("string", type_map.getTypeText(entry));
                try std.testing.expect(entry.signature_offset == null);
            },
            .var_annotation => {
                variable_count += 1;
                const name = type_map.getNameText(entry).?;
                if (std.mem.eql(u8, name, "boxed")) {
                    try std.testing.expectEqualStrings("Box<string>", type_map.getTypeText(entry));
                } else if (std.mem.eql(u8, name, "tolerant")) {
                    try std.testing.expectEqualStrings("string ignored_suffix", type_map.getTypeText(entry));
                } else {
                    return error.TestUnexpectedResult;
                }
                try std.testing.expect(entry.name_ordinal != null);
                try std.testing.expect(entry.signature_offset == null);
            },
            .param_annotation => {
                parameter_count += 1;
                try std.testing.expectEqualStrings("value", type_map.getNameText(entry).?);
                const text = type_map.getTypeText(entry);
                if (std.mem.eql(u8, text, "T")) {
                    saw_t_parameter = true;
                } else if (std.mem.eql(u8, text, "unknown")) {
                    saw_unknown_parameter = true;
                } else {
                    return error.TestUnexpectedResult;
                }
                try std.testing.expect(entry.signature_offset != null);
            },
            .return_annotation => {
                return_count += 1;
                try std.testing.expectEqualStrings("keep", type_map.getNameText(entry).?);
                try std.testing.expectEqualStrings("Box<T> ", type_map.getTypeText(entry));
                try std.testing.expect(entry.signature_offset != null);
            },
            .type_guard_annotation => {
                guard_count += 1;
                try std.testing.expectEqualStrings("isText", type_map.getNameText(entry).?);
                try std.testing.expectEqualStrings("value is string ", type_map.getTypeText(entry));
                try std.testing.expect(entry.signature_offset != null);
            },
            .generic_params => {
                generic_count += 1;
                const name = type_map.getNameText(entry).?;
                const text = type_map.getTypeText(entry);
                if (std.mem.eql(u8, name, "Box")) {
                    saw_alias_generic = true;
                    try std.testing.expectEqualStrings("<T>", text);
                    try std.testing.expect(entry.signature_offset == null);
                } else if (std.mem.eql(u8, name, "keep")) {
                    saw_function_generic = true;
                    try std.testing.expectEqualStrings("T", text);
                    const offset = entry.signature_offset.?;
                    try std.testing.expectEqual(@as(u8, '('), prepared.parserInput()[offset]);
                } else {
                    return error.TestUnexpectedResult;
                }
            },
            .call_type_arguments => {
                call_argument_count += 1;
                try std.testing.expect(type_map.getNameText(entry) == null);
                try std.testing.expectEqualStrings("Box<string>", type_map.getTypeText(entry));
                try std.testing.expect(entry.signature_offset == null);
            },
        }
    }

    inline for (@typeInfo(TypeMapKind).@"enum".fields) |field| {
        const kind: TypeMapKind = @enumFromInt(field.value);
        std.testing.expect(seen.contains(kind)) catch |err| {
            std.debug.print("type map kind '{s}' has no characterization fixture\n", .{@tagName(kind)});
            return err;
        };
    }
    try std.testing.expectEqual(@as(usize, 1), alias_count);
    try std.testing.expectEqual(@as(usize, 1), distinct_count);
    try std.testing.expectEqual(@as(usize, 2), variable_count);
    try std.testing.expectEqual(@as(usize, 2), parameter_count);
    try std.testing.expectEqual(@as(usize, 1), return_count);
    try std.testing.expectEqual(@as(usize, 1), guard_count);
    try std.testing.expectEqual(@as(usize, 2), generic_count);
    try std.testing.expectEqual(@as(usize, 1), call_argument_count);
    try std.testing.expect(saw_t_parameter);
    try std.testing.expect(saw_unknown_parameter);
    try std.testing.expect(saw_alias_generic);
    try std.testing.expect(saw_function_generic);
    try std.testing.expectEqual(source.len, prepared.parserInput().len);
    try std.testing.expectEqualStrings(source, prepared.sourceView().text);
    try std.testing.expectEqualStrings("types.ts", prepared.sourceView().name.?);
    try std.testing.expect(prepared.sourceView().normalize_positions);
}

test "PreparedSource distinguishes signatures and shadowed bindings" {
    const source = "function outer(value: number): number { const convert = (value: string): string => value; const item: number = value; { const item: string = convert(\"x\"); } return value; } function next(value: boolean): boolean { return value; }";
    var prepared = try PreparedSource.init(std.testing.allocator, source, "signatures.ts", .{});
    defer prepared.deinit();

    const outer_offset = std.mem.indexOf(u8, source, "(value: number)").?;
    const arrow_offset = std.mem.indexOf(u8, source, "(value: string)").?;
    const next_offset = std.mem.indexOf(u8, source, "(value: boolean)").?;
    var outer_annotations: usize = 0;
    var arrow_annotations: usize = 0;
    var next_annotations: usize = 0;
    var item_annotation_count: usize = 0;
    var item_ordinals = [_]bool{ false, false };

    const type_map = prepared.typeMap().?;
    for (type_map.entries.items) |entry| switch (entry.kind) {
        .param_annotation, .return_annotation => {
            const offset = entry.signature_offset.?;
            try std.testing.expectEqual(@as(u8, '('), prepared.parserInput()[offset]);
            if (offset == outer_offset) outer_annotations += 1;
            if (offset == arrow_offset) arrow_annotations += 1;
            if (offset == next_offset) next_annotations += 1;
        },
        .var_annotation => {
            const name = type_map.getNameText(entry).?;
            if (!std.mem.eql(u8, name, "item")) continue;
            item_annotation_count += 1;
            const ordinal = entry.name_ordinal orelse return error.TestUnexpectedResult;
            if (ordinal >= item_ordinals.len) return error.TestUnexpectedResult;
            item_ordinals[ordinal] = true;
            try std.testing.expect(entry.signature_offset == null);
            const expected_text = if (ordinal == 0) "number" else "string";
            try std.testing.expectEqualStrings(expected_text, type_map.getTypeText(entry));
        },
        else => {},
    };

    try std.testing.expectEqual(@as(usize, 2), outer_annotations);
    try std.testing.expectEqual(@as(usize, 2), arrow_annotations);
    try std.testing.expectEqual(@as(usize, 2), next_annotations);
    try std.testing.expectEqual(@as(usize, 2), item_annotation_count);
    try std.testing.expect(item_ordinals[0]);
    try std.testing.expect(item_ordinals[1]);
}

test "PreparedSource exposes ordered source refusal diagnostics" {
    const source =
        \\interface Legacy { value: string; }
        \\type Alias = string;
        \\distinct type OldId = string;
        \\const unsafe: any = value;
        \\const asserted = value as string;
        \\const checked = value satisfies Alias;
        \\let callback: (value: string) => void = use;
        \\function optional(value?: string): string { return value ?? ""; }
    ;
    const expected = [_]struct { kind: stripper.StripDiagnosticKind, line: u32 }{
        .{ .kind = .interface_declaration, .line = 1 },
        .{ .kind = .type_alias_declaration, .line = 2 },
        .{ .kind = .distinct_type_declaration, .line = 3 },
        .{ .kind = .any_type, .line = 4 },
        .{ .kind = .as_assertion, .line = 5 },
        .{ .kind = .satisfies_assertion, .line = 6 },
        .{ .kind = .void_type, .line = 7 },
        .{ .kind = .optional_parameter, .line = 8 },
    };

    var prepared = try PreparedSource.init(std.testing.allocator, source, "refused.ts", .{
        .collect_all_diagnostics = true,
        .report_errors = false,
    });
    defer prepared.deinit();

    const diagnostics = prepared.stripDiagnostics();
    try std.testing.expectEqual(expected.len, diagnostics.len);
    for (expected, diagnostics) |want, got| {
        try std.testing.expectEqual(want.kind, got.kind);
        try std.testing.expectEqual(want.line, got.line);
        try std.testing.expect(got.column > 0);
    }
}

test "PreparedSource leaves parser-owned syntax unchanged" {
    const source = "const folded = comptime(1);\nconst view = <div />;";
    var prepared = try PreparedSource.init(std.testing.allocator, source, "parser-owned.ts", .{});
    defer prepared.deinit();

    try std.testing.expectEqualStrings(source, prepared.parserInput());
    try std.testing.expectEqual(@as(usize, 0), prepared.typeMap().?.count());
    try std.testing.expectEqual(@as(usize, 0), prepared.stripDiagnostics().len);
}
