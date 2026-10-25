//! Stderr printing helpers for the precompile tool: the debug print, the parse error
//! rendering, and the plain-language handler read failure text.

const std = @import("std");
const builtin = @import("builtin");
const zts = @import("zts");

/// Stderr diagnostic print. On freestanding/wasm there is no stderr and
/// `std.debug.print` pulls a threaded IO stack that does not compile, so the
/// call is comptime-elided. Native builds behave exactly like `std.debug.print`.
pub fn debugPrint(comptime fmt: []const u8, args: anytype) void {
    if (comptime builtin.target.os.tag != .freestanding) {
        std.debug.print(fmt, args);
    }
}

/// Print a TypeScript admission failure with `file:line:column` and a remediation
/// message when parsing supplied a structured diagnostic, falling back to
/// the bare error name when it did not (OOM and other location-free failures).
/// Render parse errors for a person: the ZTS code, `file:line:column`, the
/// source line, and an underline. Positions refer to the original source.
/// Caller owns the result.
fn renderParseErrors(
    allocator: std.mem.Allocator,
    view: zts.SourceView,
    errors: []const zts.ParseError,
) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    try zts.DiagnosticProjection.writeParseErrors(view, errors, &aw.writer);
    return aw.toOwnedSlice();
}

/// Print `renderParseErrors` to stderr. A rendering failure falls back to the
/// position and message, so a parse failure is never reported as nothing.
pub fn printParseErrors(
    allocator: std.mem.Allocator,
    view: zts.SourceView,
    errors: []const zts.ParseError,
) void {
    if (renderParseErrors(allocator, view, errors)) |text| {
        defer allocator.free(text);
        debugPrint("{s}", .{text});
    } else |_| {
        for (errors) |parse_error| {
            debugPrint("{s}:{d}:{d}: {s}\n", .{
                view.name orelse "<source>",
                parse_error.location.line,
                parse_error.location.column,
                parse_error.message,
            });
        }
    }
}

pub fn debugPrintStripError(path: []const u8, err: anyerror, diag: ?zts.StripDiagnostic) void {
    if (diag) |d| {
        debugPrint("{s}:{d}:{d}: {s}\n", .{ path, d.line, d.column, d.kind.message() });
    } else {
        debugPrint("TypeScript strip error in {s}: {}\n", .{ path, err });
    }
}

/// Plain reason for the common handler-read failures. Any other error keeps
/// its Zig error name, so no failure is hidden. Only the text output uses
/// this: the `--json` message and the ZTS000 diagnostic keep `@errorName`.
pub fn readFailureReason(err: anyerror) []const u8 {
    return switch (err) {
        error.FileNotFound => "no such file",
        error.AccessDenied => "permission denied",
        error.IsDir => "is a directory",
        else => @errorName(err),
    };
}

test "readFailureReason gives plain text for common read errors and keeps other names" {
    try std.testing.expectEqualStrings("no such file", readFailureReason(error.FileNotFound));
    try std.testing.expectEqualStrings("permission denied", readFailureReason(error.AccessDenied));
    try std.testing.expectEqualStrings("is a directory", readFailureReason(error.IsDir));
    try std.testing.expectEqualStrings("FileTooBig", readFailureReason(error.FileTooBig));
}

fn parseFailureText(allocator: std.mem.Allocator, source: []const u8, path: []const u8) ![]u8 {
    var frontend: zts.DirectCheckSource = undefined;
    try frontend.initCompileInPlace(allocator, allocator, source, path);
    defer frontend.deinit();
    switch (frontend.parse_outcome) {
        .parser_refused => {},
        else => return error.TestExpectedParseFailure,
    }
    return renderParseErrors(allocator, frontend.sourceView(), frontend.parserErrors());
}

test "parse failure text names the code, file, line, and underline" {
    // These are the paths that printed `file:line:col: message` alone:
    // `check`, `gen-tests`, and compile all render through printParseErrors.
    const allocator = std.testing.allocator;
    const text = try parseFailureText(allocator, "const a = 1;\nconst b = while;\n", "demo.ts");
    defer allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "error[ZTS") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "  --> demo.ts:2:") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "  2 | const b = while;\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "^") != null);
}

test "parse failure text underlines the unsupported keyword and keeps its suggestion" {
    const allocator = std.testing.allocator;
    const text = try parseFailureText(allocator, "let n = 0;\nwhile (n < 3) { n = n + 1; }\n", "loop.ts");
    defer allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "error[ZTS001]") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "  --> loop.ts:2:1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "  2 | while (n < 3) { n = n + 1; }\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "   | ^^^^^\n") != null);
}

test "parse failure text counts characters on a multi-byte line" {
    const allocator = std.testing.allocator;
    const text = try parseFailureText(allocator, "const s = \"é✓\"; while (s) {}\n", "wide.ts");
    defer allocator.free(text);
    // Sixteen characters precede `while`, though the line holds twenty bytes
    // before it.
    try std.testing.expect(std.mem.indexOf(u8, text, "   | " ++ &@as([16:0]u8, @splat(' ')) ++ "^^^^^\n") != null);
}
