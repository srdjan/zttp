//! Native source-admission causes and original-source diagnostic rendering.

const std = @import("std");

/// Native failures at the source-admission boundary.
pub const StripError = error{
    UnsupportedAngleBracketAssertion,
    UnsupportedAnyType,
    UnclosedTypeAnnotation,
    UnclosedGeneric,
    UnterminatedString,
    UnterminatedComment,
    NestingTooDeep,
    OutOfMemory,
    UnsupportedAsAssertion,
    UnsupportedSatisfiesAssertion,
    NominalBaseNotScalar,
    InterfaceDeclaration,
    TypeAliasDeclaration,
    DistinctTypeDeclaration,
    LegacyTypesImport,
    DefaultParameter,
    OptionalParameter,
    DefaultExport,
    MutableExport,
    ArrayTypeAlias,
    ReadonlyArrayTypeAlias,
    VoidType,
};

/// Stable source-admission causes and their public remediation messages.
pub const StripDiagnosticKind = enum {
    any_type,
    as_assertion,
    satisfies_assertion,
    unterminated_string,
    nominal_base_not_scalar,
    interface_declaration,
    type_alias_declaration,
    distinct_type_declaration,
    legacy_types_import,
    default_parameter,
    optional_parameter,
    default_export,
    mutable_export,
    array_type_alias,
    readonly_array_type_alias,
    void_type,
    nesting_too_deep,

    pub fn message(self: StripDiagnosticKind) []const u8 {
        return switch (self) {
            .any_type => "'any' type is not supported; use specific types (string, number, object) or union types instead",
            .as_assertion => "'as' type assertion is not supported; use type-safe patterns instead",
            .satisfies_assertion => "'satisfies' type assertion is not supported; use type-safe patterns instead",
            .unterminated_string => "unterminated string literal; close the quote, or write the newline as \\n",
            .nominal_base_not_scalar => "a nominal declaration carries scalar identity only; its base must be `string`, `number`, or `boolean`",
            .interface_declaration => "`interface` is not a declaration form in this profile; write `structural Name = { ... };`",
            .type_alias_declaration => "`type` is not a declaration form in this profile; write `structural Name = ...;`",
            .distinct_type_declaration => "`distinct type` is not a declaration form in this profile; write `nominal Name = string;`",
            .legacy_types_import => "`zttp:types` is not a module in this profile; remove this import because `Proof<T, P>` and `Effects<T, R>` are ambient type names",
            .default_parameter => "default parameters are not part of this profile; replace `name: T = value` with `name: T | undefined`, then resolve `const resolved = name ?? value;` at the start of the body",
            .optional_parameter => "optional parameter shorthand is not part of this profile; replace `name?: T` with `name: T | undefined`",
            .default_export => "default exports are not part of this profile; write a named export, for example `export function handler(...) { ... }`",
            .mutable_export => "mutable exports are not part of this profile; use `export const` for module values and keep reassignment inside a function activation",
            .array_type_alias => "`Array<T>` is not a type spelling in this profile; write `T[]`",
            .readonly_array_type_alias => "`ReadonlyArray<T>` is not a type spelling in this profile; write `readonly T[]`",
            .void_type => "`void` is not a type spelling in this profile; write `undefined`",
            .nesting_too_deep => "type syntax nests too deeply; simplify or split it (nesting limit is 512)",
        };
    }
};

pub const StripDiagnostic = struct {
    line: u32,
    column: u32,
    kind: StripDiagnosticKind,
};

/// A line and column, both with a first index of one.
pub const Position = struct {
    line: u32,
    column: u32,
};

/// This view borrows the original source bytes for diagnostic display.
pub const SourceView = struct {
    text: []const u8,
    /// Normalize coordinates through byte offsets in the original source.
    normalize_positions: bool = false,
    name: ?[]const u8 = null,

    pub fn of(text: []const u8) SourceView {
        return .{ .text = text };
    }

    pub fn position(self: SourceView, line: u32, column: u32) Position {
        if (self.normalize_positions) return positionOfOffset(self.text, offsetOfPosition(self.text, line, column));
        return .{ .line = line, .column = column };
    }

    pub fn sourceOffset(self: SourceView, parsed_offset: u32) u32 {
        _ = self;
        return parsed_offset;
    }

    /// Write one human diagnostic with its code, source line, and clamped underline.
    /// The underline uses one caret for each UTF-8 code point.
    pub fn writeDiagnostic(self: SourceView, d: HumanDiagnostic, writer: anytype) !void {
        const at = self.position(d.line, d.column);
        try writer.print("{s}{s}", .{ d.scope, d.severity });
        if (d.code) |code| try writer.print("[{s}]", .{code});
        try writer.print(": {s}\n", .{d.message});
        if (self.name) |name| {
            try writer.print("  --> {s}:{d}:{d}\n", .{ name, at.line, at.column });
        } else {
            try writer.print("  --> {d}:{d}\n", .{ at.line, at.column });
        }
        if (self.lineText(at.line)) |raw| {
            const text = std.mem.trimEnd(u8, raw, "\r");
            const start_in_line = alignToCodePoint(text, @min(@as(usize, at.column -| 1), text.len));
            var width: usize = 1;
            if (d.end_offset > d.start_offset) {
                const mapped_start = self.sourceOffset(d.start_offset);
                const mapped_end = self.sourceOffset(d.end_offset);
                if (mapped_end > mapped_start) {
                    const end_in_line = @min(start_in_line + (mapped_end - mapped_start), text.len);
                    width = @max(1, countCodePoints(text[start_in_line..end_in_line]));
                }
            }
            try writer.print("   |\n", .{});
            try writer.print("{d: >3} | {s}\n", .{ at.line, text });
            try writer.print("   | ", .{});
            var cursor: usize = 0;
            while (cursor < start_in_line) {
                const step = codePointLength(text, cursor);
                try writer.writeByte(if (text[cursor] == '\t') '\t' else ' ');
                cursor += step;
            }
            for (0..width) |_| try writer.writeByte('^');
            try writer.writeByte('\n');
        }
        if (d.expected) |expected| try writer.print("   = expected: {s}\n", .{expected});
        if (d.found) |found| try writer.print("   = found: '{s}'\n", .{found});
        if (d.help) |help| try writer.print("   = help: {s}\n", .{help});
        try writer.writeByte('\n');
    }

    pub fn lineText(self: SourceView, number: u32) ?[]const u8 {
        if (number == 0) return null;
        var remaining = self.text;
        var current: u32 = 1;
        while (current < number) : (current += 1) {
            const newline = std.mem.indexOfScalar(u8, remaining, '\n') orelse return null;
            remaining = remaining[newline + 1 ..];
        }
        const end = std.mem.indexOfScalar(u8, remaining, '\n') orelse remaining.len;
        return remaining[0..end];
    }
};

/// The values that SourceView.writeDiagnostic displays.
pub const HumanDiagnostic = struct {
    scope: []const u8 = "",
    severity: []const u8,
    code: ?[]const u8 = null,
    message: []const u8,
    line: u32,
    column: u32,
    start_offset: u32 = 0,
    end_offset: u32 = 0,
    expected: ?[]const u8 = null,
    found: ?[]const u8 = null,
    help: ?[]const u8 = null,
};

fn codePointLength(text: []const u8, index: usize) usize {
    const length = std.unicode.utf8ByteSequenceLength(text[index]) catch return 1;
    return @min(@as(usize, length), text.len - index);
}

fn alignToCodePoint(text: []const u8, index: usize) usize {
    var at = index;
    while (at > 0 and at < text.len and text[at] & 0xC0 == 0x80) at -= 1;
    return at;
}

fn countCodePoints(text: []const u8) usize {
    var count: usize = 0;
    var cursor: usize = 0;
    while (cursor < text.len) : (count += 1) cursor += codePointLength(text, cursor);
    return count;
}

fn offsetOfPosition(text: []const u8, line: u32, column: u32) u32 {
    var current_line: u32 = 1;
    var index: usize = 0;
    while (index < text.len and current_line < line) : (index += 1) {
        if (text[index] == '\n') current_line += 1;
    }
    const offset = index + @as(usize, if (column > 0) column - 1 else 0);
    return @intCast(@min(offset, text.len));
}

pub fn positionOfOffset(text: []const u8, offset: u32) Position {
    const limit = @min(@as(usize, offset), text.len);
    var line: u32 = 1;
    var line_start: usize = 0;
    for (text[0..limit], 0..) |byte, index| {
        if (byte == '\n') {
            line += 1;
            line_start = index + 1;
        }
    }
    return .{ .line = line, .column = @intCast(limit - line_start + 1) };
}

test "writeDiagnostic names the code and file and underlines the span" {
    const source = "let a = 1;\nlet b = oops + 2;\n";
    const start = std.mem.indexOf(u8, source, "oops").?;
    var view = SourceView.of(source);
    view.name = "demo.ts";
    const text = try renderForTest(view, .{
        .scope = "type ",
        .severity = "error",
        .code = "ZTS105",
        .message = "bad operand",
        .line = 2,
        .column = 9,
        .start_offset = @intCast(start),
        .end_offset = @intCast(start + 4),
        .help = "use a number",
    });
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings(
        "type error[ZTS105]: bad operand\n" ++
            "  --> demo.ts:2:9\n" ++
            "   |\n" ++
            "  2 | let b = oops + 2;\n" ++
            "   |         ^^^^\n" ++
            "   = help: use a number\n\n",
        text,
    );
}

test "writeDiagnostic keeps the underline aligned on a multi-byte line" {
    // "héllo" holds a two-byte character and "✓" a three-byte one, so the
    // byte column of `oops` is larger than the number of characters before it.
    const source = "const s = \"héllo ✓\"; oops;\n";
    const start = std.mem.indexOf(u8, source, "oops").?;
    const text = try renderForTest(SourceView.of(source), .{
        .severity = "error",
        .message = "m",
        .line = 1,
        .column = @intCast(start + 1),
        .start_offset = @intCast(start),
        .end_offset = @intCast(start + 4),
    });
    defer std.testing.allocator.free(text);
    // 21 characters precede `oops`.
    try std.testing.expect(std.mem.indexOf(u8, text, "   | " ++ " " ** 21 ++ "^^^^\n") != null);
}

test "writeDiagnostic counts a multi-byte span in characters" {
    const source = "x = \"日本語\";\n";
    const start = std.mem.indexOf(u8, source, "日").?;
    const text = try renderForTest(SourceView.of(source), .{
        .severity = "error",
        .message = "m",
        .line = 1,
        .column = @intCast(start + 1),
        .start_offset = @intCast(start),
        .end_offset = @intCast(start + 9),
    });
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "   | " ++ " " ** 5 ++ "^^^\n") != null);
}

test "writeDiagnostic clamps a span that crosses a line end" {
    const source = "abcdef\nghijkl\n";
    const text = try renderForTest(SourceView.of(source), .{
        .severity = "error",
        .message = "m",
        .line = 1,
        .column = 4,
        .start_offset = 3,
        .end_offset = 11,
    });
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "   | " ++ " " ** 3 ++ "^^^\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "^^^^") == null);
}

test "writeDiagnostic draws one caret for a zero-width span" {
    const source = "abcdef\n";
    const text = try renderForTest(SourceView.of(source), .{
        .severity = "warning",
        .message = "m",
        .line = 1,
        .column = 3,
        .start_offset = 2,
        .end_offset = 2,
    });
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "   | " ++ " " ** 2 ++ "^\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "^^") == null);
}

test "writeDiagnostic draws a caret for a position past the line end" {
    const text = try renderForTest(SourceView.of("ab\n"), .{
        .severity = "error",
        .message = "m",
        .line = 1,
        .column = 40,
    });
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "   | " ++ " " ** 2 ++ "^\n") != null);
}

test "writeDiagnostic with no source line still names the position" {
    const text = try renderForTest(SourceView.of(""), .{
        .severity = "error",
        .code = "ZTS999",
        .message = "m",
        .line = 3,
        .column = 2,
    });
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("error[ZTS999]: m\n  --> 3:2\n\n", text);
}

fn renderForTest(view: SourceView, d: HumanDiagnostic) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    errdefer aw.deinit();
    try view.writeDiagnostic(d, &aw.writer);
    return aw.toOwnedSlice();
}
