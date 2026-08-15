//! The `zts-tsx-1` source frontend.
//!
//! This module lowers the deliberately small JSX surface to ordinary core
//! calls before the parser sees it. The runtime already defines
//! `h(tag, props, ...children)`, so lowering adds no second execution model.
//! Parsing and rendering are separate: the first pass validates the complete
//! element, and only then can the second pass publish transformed bytes.

const std = @import("std");
const stripper = @import("stripper.zig");

pub const DiagnosticKind = enum {
    mismatched_tag,
    invalid_attribute,
    unclosed_element,
    expression_expected,
};

pub const Diagnostic = struct {
    kind: DiagnosticKind,
    line: u32,
    column: u32,
};

pub const Error = error{
    InvalidTsx,
    SourceTooLarge,
    OutOfMemory,
};

pub const Result = struct {
    allocator: std.mem.Allocator,
    code: []const u8,
    span_edits: []const stripper.SpanEdit,

    pub fn deinit(self: *Result) void {
        self.allocator.free(self.code);
        if (self.span_edits.len > 0) self.allocator.free(self.span_edits);
        self.* = undefined;
    }
};

const Span = struct {
    start: usize,
    end: usize,
};

const Attribute = struct {
    name: ?Span,
    value: union(enum) {
        implicit_true,
        string: Span,
        expression: Span,
        spread: Span,
    },
};

const Child = union(enum) {
    text: Span,
    expression: Span,
    element: *const Element,
};

const Element = struct {
    start: usize,
    end: usize,
    tag: ?Span,
    component: bool,
    attrs: []const Attribute,
    children: []const Child,
};

const max_depth: u8 = 64;

const Parser = struct {
    allocator: std.mem.Allocator,
    source: []const u8,
    diagnostic_out: ?*?Diagnostic,

    fn fail(self: *const Parser, kind: DiagnosticKind, offset: usize) Error {
        if (self.diagnostic_out) |out| {
            var line: u32 = 1;
            var column: u32 = 1;
            for (self.source[0..@min(offset, self.source.len)]) |byte| {
                if (byte == '\n') {
                    line += 1;
                    column = 1;
                } else {
                    column += 1;
                }
            }
            out.* = .{ .kind = kind, .line = line, .column = column };
        }
        return error.InvalidTsx;
    }

    fn parseElement(self: *Parser, at: usize, depth: u8) Error!*const Element {
        if (depth >= max_depth) return self.fail(.unclosed_element, at);
        if (at >= self.source.len or self.source[at] != '<') return self.fail(.unclosed_element, at);

        var pos = at + 1;
        var tag: ?Span = null;
        var component = false;
        const fragment = pos < self.source.len and self.source[pos] == '>';
        if (fragment) {
            pos += 1;
        } else {
            const tag_start = pos;
            pos = self.scanTagName(pos) orelse return self.fail(.unclosed_element, pos);
            tag = .{ .start = tag_start, .end = pos };
            component = std.ascii.isUpper(self.source[tag_start]);
        }

        var attrs: std.ArrayListUnmanaged(Attribute) = .empty;
        if (!fragment) {
            while (true) {
                pos = skipWhitespace(self.source, pos);
                if (pos >= self.source.len) return self.fail(.unclosed_element, at);
                if (self.source[pos] == '>') {
                    pos += 1;
                    break;
                }
                if (self.source[pos] == '/' and pos + 1 < self.source.len and self.source[pos + 1] == '>') {
                    pos += 2;
                    const node = try self.allocator.create(Element);
                    node.* = .{
                        .start = at,
                        .end = pos,
                        .tag = tag,
                        .component = component,
                        .attrs = try attrs.toOwnedSlice(self.allocator),
                        .children = &.{},
                    };
                    return node;
                }

                if (self.source[pos] == '{') {
                    const close = self.findClosingBrace(pos) orelse return self.fail(.unclosed_element, pos);
                    var inner = skipWhitespace(self.source, pos + 1);
                    if (inner + 3 > close or !std.mem.eql(u8, self.source[inner .. inner + 3], "...")) {
                        return self.fail(.invalid_attribute, pos);
                    }
                    inner = skipWhitespace(self.source, inner + 3);
                    const end = trimWhitespaceEnd(self.source, inner, close);
                    if (inner == end) return self.fail(.expression_expected, pos);
                    try attrs.append(self.allocator, .{
                        .name = null,
                        .value = .{ .spread = .{ .start = inner, .end = end } },
                    });
                    pos = close + 1;
                    continue;
                }

                const name_start = pos;
                pos = scanAttributeName(self.source, pos) orelse return self.fail(.invalid_attribute, pos);
                const name = Span{ .start = name_start, .end = pos };
                pos = skipWhitespace(self.source, pos);
                if (pos >= self.source.len or self.source[pos] != '=') {
                    try attrs.append(self.allocator, .{ .name = name, .value = .implicit_true });
                    continue;
                }
                pos = skipWhitespace(self.source, pos + 1);
                if (pos >= self.source.len) return self.fail(.invalid_attribute, pos);
                if (self.source[pos] == '\'' or self.source[pos] == '"') {
                    const end = scanQuoted(self.source, pos) orelse return self.fail(.invalid_attribute, pos);
                    try attrs.append(self.allocator, .{
                        .name = name,
                        .value = .{ .string = .{ .start = pos, .end = end } },
                    });
                    pos = end;
                } else if (self.source[pos] == '{') {
                    const close = self.findClosingBrace(pos) orelse return self.fail(.unclosed_element, pos);
                    const start = skipWhitespace(self.source, pos + 1);
                    const end = trimWhitespaceEnd(self.source, start, close);
                    if (start == end) return self.fail(.expression_expected, pos);
                    try attrs.append(self.allocator, .{
                        .name = name,
                        .value = .{ .expression = .{ .start = start, .end = end } },
                    });
                    pos = close + 1;
                } else {
                    return self.fail(.invalid_attribute, pos);
                }
            }
        }

        var children: std.ArrayListUnmanaged(Child) = .empty;
        while (pos < self.source.len) {
            if (self.source[pos] == '<') {
                if (pos + 1 < self.source.len and self.source[pos + 1] == '/') {
                    const close_start = pos;
                    pos += 2;
                    if (fragment) {
                        pos = skipWhitespace(self.source, pos);
                        if (pos >= self.source.len or self.source[pos] != '>') {
                            return self.fail(.mismatched_tag, close_start);
                        }
                        pos += 1;
                    } else {
                        const close_name_start = pos;
                        pos = self.scanTagName(pos) orelse return self.fail(.mismatched_tag, close_start);
                        const expected = tag.?;
                        if (!std.mem.eql(
                            u8,
                            self.source[expected.start..expected.end],
                            self.source[close_name_start..pos],
                        )) return self.fail(.mismatched_tag, close_start);
                        pos = skipWhitespace(self.source, pos);
                        if (pos >= self.source.len or self.source[pos] != '>') {
                            return self.fail(.mismatched_tag, close_start);
                        }
                        pos += 1;
                    }
                    const node = try self.allocator.create(Element);
                    node.* = .{
                        .start = at,
                        .end = pos,
                        .tag = tag,
                        .component = component,
                        .attrs = try attrs.toOwnedSlice(self.allocator),
                        .children = try children.toOwnedSlice(self.allocator),
                    };
                    return node;
                }
                const nested = try self.parseElement(pos, depth + 1);
                try children.append(self.allocator, .{ .element = nested });
                pos = nested.end;
                continue;
            }
            if (self.source[pos] == '{') {
                const open = pos;
                const close = self.findClosingBrace(open) orelse return self.fail(.unclosed_element, open);
                const start = skipWhitespace(self.source, open + 1);
                const end = trimWhitespaceEnd(self.source, start, close);
                if (start == end) return self.fail(.expression_expected, open);
                try children.append(self.allocator, .{ .expression = .{ .start = start, .end = end } });
                pos = close + 1;
                continue;
            }

            const raw_start = pos;
            while (pos < self.source.len and self.source[pos] != '<' and self.source[pos] != '{') : (pos += 1) {}
            const start = skipWhitespace(self.source, raw_start);
            const end = trimWhitespaceEnd(self.source, start, pos);
            if (start < end) try children.append(self.allocator, .{ .text = .{ .start = start, .end = end } });
        }
        return self.fail(.unclosed_element, at);
    }

    fn scanTagName(self: *const Parser, at: usize) ?usize {
        if (at >= self.source.len or !isIdentStart(self.source[at])) return null;
        var pos = at + 1;
        while (pos < self.source.len and isTagContinue(self.source[pos])) : (pos += 1) {}
        return pos;
    }

    fn findClosingBrace(self: *const Parser, open: usize) ?usize {
        var depth: u32 = 1;
        var pos = open + 1;
        while (pos < self.source.len) {
            if (scanLexicalUnit(self.source, pos)) |end| {
                pos = end;
                continue;
            }
            switch (self.source[pos]) {
                '{' => depth += 1,
                '}' => {
                    depth -= 1;
                    if (depth == 0) return pos;
                },
                else => {},
            }
            pos += 1;
        }
        return null;
    }
};

const Renderer = struct {
    allocator: std.mem.Allocator,
    source: []const u8,
    output: std.ArrayListUnmanaged(u8) = .empty,
    edits: std.ArrayListUnmanaged(stripper.SpanEdit) = .empty,
    parser: *Parser,

    fn deinit(self: *Renderer) void {
        self.output.deinit(self.allocator);
        self.edits.deinit(self.allocator);
    }

    fn lowerRange(self: *Renderer, start: usize, end: usize) Error!void {
        var pos = start;
        var copy_start = start;
        while (pos < end) {
            if (scanLexicalUnit(self.source, pos)) |after| {
                pos = @min(after, end);
                continue;
            }
            if (self.source[pos] == '<' and looksLikeJsxStart(self.source, start, pos)) {
                if (copy_start < pos) try self.output.appendSlice(self.allocator, self.source[copy_start..pos]);
                const element = try self.parser.parseElement(pos, 0);
                try self.renderElement(element);
                pos = element.end;
                copy_start = pos;
                continue;
            }
            pos += 1;
        }
        if (copy_start < end) try self.output.appendSlice(self.allocator, self.source[copy_start..end]);
    }

    fn renderElement(self: *Renderer, element: *const Element) Error!void {
        var pending: std.ArrayListUnmanaged(u8) = .empty;
        defer pending.deinit(self.allocator);
        var cursor = element.start;

        try pending.appendSlice(self.allocator, "h(");
        if (element.tag) |tag| {
            if (element.component) {
                try pending.appendSlice(self.allocator, self.source[tag.start..tag.end]);
            } else {
                try appendQuoted(&pending, self.allocator, self.source[tag.start..tag.end]);
            }
        } else {
            try pending.appendSlice(self.allocator, "null");
        }
        try pending.appendSlice(self.allocator, ", ");

        if (element.attrs.len == 0) {
            try pending.appendSlice(self.allocator, "null");
        } else {
            try pending.append(self.allocator, '{');
            for (element.attrs, 0..) |attr, index| {
                if (index > 0) try pending.appendSlice(self.allocator, ", ");
                switch (attr.value) {
                    .spread => |expr| {
                        try pending.appendSlice(self.allocator, "...(");
                        try self.flushGenerated(&pending, cursor, expr.start);
                        try self.lowerRange(expr.start, expr.end);
                        cursor = expr.end;
                        try pending.append(self.allocator, ')');
                    },
                    .implicit_true => {
                        try appendQuoted(&pending, self.allocator, self.source[attr.name.?.start..attr.name.?.end]);
                        try pending.appendSlice(self.allocator, ": true");
                    },
                    .string => |value| {
                        try appendQuoted(&pending, self.allocator, self.source[attr.name.?.start..attr.name.?.end]);
                        try pending.appendSlice(self.allocator, ": ");
                        try self.flushGenerated(&pending, cursor, value.start);
                        try self.output.appendSlice(self.allocator, self.source[value.start..value.end]);
                        cursor = value.end;
                    },
                    .expression => |expr| {
                        try appendQuoted(&pending, self.allocator, self.source[attr.name.?.start..attr.name.?.end]);
                        try pending.appendSlice(self.allocator, ": (");
                        try self.flushGenerated(&pending, cursor, expr.start);
                        try self.lowerRange(expr.start, expr.end);
                        cursor = expr.end;
                        try pending.append(self.allocator, ')');
                    },
                }
            }
            try pending.append(self.allocator, '}');
        }

        for (element.children) |child| {
            try pending.appendSlice(self.allocator, ", ");
            switch (child) {
                .text => |text| try appendQuoted(&pending, self.allocator, self.source[text.start..text.end]),
                .expression => |expr| {
                    try pending.append(self.allocator, '(');
                    try self.flushGenerated(&pending, cursor, expr.start);
                    try self.lowerRange(expr.start, expr.end);
                    cursor = expr.end;
                    try pending.append(self.allocator, ')');
                },
                .element => |nested| {
                    try self.flushGenerated(&pending, cursor, nested.start);
                    try self.renderElement(nested);
                    cursor = nested.end;
                },
            }
        }
        try pending.append(self.allocator, ')');
        try self.flushGenerated(&pending, cursor, element.end);
    }

    fn flushGenerated(
        self: *Renderer,
        pending: *std.ArrayListUnmanaged(u8),
        source_start: usize,
        source_end: usize,
    ) Error!void {
        if (pending.items.len == 0 and source_start == source_end) return;
        const output_start = self.output.items.len;
        try self.output.appendSlice(self.allocator, pending.items);
        pending.clearRetainingCapacity();
        const output_end = self.output.items.len;
        try self.edits.append(self.allocator, .{
            .stripped_start = @intCast(output_start),
            .stripped_end = @intCast(output_end),
            .source_start = @intCast(source_start),
            .source_end = @intCast(source_end),
        });
    }
};

pub fn lower(
    allocator: std.mem.Allocator,
    source: []const u8,
    diagnostic_out: ?*?Diagnostic,
) Error!Result {
    if (source.len > std.math.maxInt(u32)) return error.SourceTooLarge;
    if (diagnostic_out) |out| out.* = null;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var parser = Parser{
        .allocator = arena.allocator(),
        .source = source,
        .diagnostic_out = diagnostic_out,
    };
    var renderer = Renderer{
        .allocator = allocator,
        .source = source,
        .parser = &parser,
    };
    errdefer renderer.deinit();

    try renderer.lowerRange(0, source.len);
    const code = try renderer.output.toOwnedSlice(allocator);
    errdefer allocator.free(code);
    const edits = try renderer.edits.toOwnedSlice(allocator);
    return .{ .allocator = allocator, .code = code, .span_edits = edits };
}

fn looksLikeJsxStart(source: []const u8, range_start: usize, at: usize) bool {
    if (at + 1 >= source.len) return false;
    const next = source[at + 1];
    if (next != '>' and !isIdentStart(next)) return false;

    var prev = at;
    while (prev > range_start and std.ascii.isWhitespace(source[prev - 1])) : (prev -= 1) {}
    if (prev == range_start) return true;
    const byte = source[prev - 1];
    if (std.mem.indexOfScalar(u8, "=([{,:;!?&|+*-/%", byte) != null) return true;
    if (byte == '>' and prev >= 2 and source[prev - 2] == '=') return true;

    var word_start = prev;
    while (word_start > range_start and isIdentContinue(source[word_start - 1])) : (word_start -= 1) {}
    return std.mem.eql(u8, source[word_start..prev], "return");
}

fn scanLexicalUnit(source: []const u8, at: usize) ?usize {
    if (at >= source.len) return null;
    if (source[at] == '\'' or source[at] == '"' or source[at] == '`') return scanQuoted(source, at) orelse source.len;
    if (source[at] != '/' or at + 1 >= source.len) return null;
    if (source[at + 1] == '/') {
        var pos = at + 2;
        while (pos < source.len and source[pos] != '\n') : (pos += 1) {}
        return pos;
    }
    if (source[at + 1] == '*') {
        var pos = at + 2;
        while (pos + 1 < source.len) : (pos += 1) {
            if (source[pos] == '*' and source[pos + 1] == '/') return pos + 2;
        }
        return source.len;
    }
    return null;
}

fn scanQuoted(source: []const u8, at: usize) ?usize {
    const quote = source[at];
    var pos = at + 1;
    while (pos < source.len) : (pos += 1) {
        if (source[pos] == '\\') {
            pos += 1;
            continue;
        }
        if (source[pos] == quote) return pos + 1;
    }
    return null;
}

fn scanAttributeName(source: []const u8, at: usize) ?usize {
    if (at >= source.len or !isIdentStart(source[at])) return null;
    var pos = at + 1;
    while (pos < source.len and (isIdentContinue(source[pos]) or source[pos] == '-')) : (pos += 1) {}
    return pos;
}

fn isIdentStart(byte: u8) bool {
    return std.ascii.isAlphabetic(byte) or byte == '_' or byte == '$';
}

fn isIdentContinue(byte: u8) bool {
    return isIdentStart(byte) or std.ascii.isDigit(byte);
}

fn isTagContinue(byte: u8) bool {
    return isIdentContinue(byte) or byte == '.' or byte == '-';
}

fn skipWhitespace(source: []const u8, at: usize) usize {
    var pos = at;
    while (pos < source.len and std.ascii.isWhitespace(source[pos])) : (pos += 1) {}
    return pos;
}

fn trimWhitespaceEnd(source: []const u8, start: usize, at: usize) usize {
    var end = at;
    while (end > start and std.ascii.isWhitespace(source[end - 1])) : (end -= 1) {}
    return end;
}

fn appendQuoted(list: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, text: []const u8) Error!void {
    const hex = "0123456789abcdef";
    try list.append(allocator, '"');
    for (text) |byte| switch (byte) {
        '"' => try list.appendSlice(allocator, "\\\""),
        '\\' => try list.appendSlice(allocator, "\\\\"),
        '\n' => try list.appendSlice(allocator, "\\n"),
        '\r' => try list.appendSlice(allocator, "\\r"),
        '\t' => try list.appendSlice(allocator, "\\t"),
        0...8, 11...12, 14...0x1f => {
            try list.appendSlice(allocator, "\\u00");
            try list.append(allocator, hex[byte >> 4]);
            try list.append(allocator, hex[byte & 0x0f]);
        },
        else => try list.append(allocator, byte),
    };
    try list.append(allocator, '"');
}

test "lowers elements components fragments attributes and nested expressions" {
    const source =
        \\const card = <Card title="Hello" disabled {...props}>
        \\  <span class={kind}>Hi {name}</span>
        \\  <>{items.map((item) => <Item value={item} />)}</>
        \\</Card>;
    ;
    var result = try lower(std.testing.allocator, source, null);
    defer result.deinit();

    try std.testing.expectEqualStrings(
        "const card = h(Card, {\"title\": \"Hello\", \"disabled\": true, ...(props)}, h(\"span\", {\"class\": (kind)}, \"Hi\", (name)), h(null, null, (items.map((item) => h(Item, {\"value\": (item)})))));",
        result.code,
    );
    try std.testing.expect(result.span_edits.len > 0);
}

test "does not lower comparisons strings comments or templates" {
    const source =
        \\const smaller = a < b;
        \\const text = "<div>";
        \\// <span />
        \\const template = `<p>${value}</p>`;
        \\const view = condition ? <Ok /> : <No />;
    ;
    var result = try lower(std.testing.allocator, source, null);
    defer result.deinit();
    try std.testing.expect(std.mem.indexOf(u8, result.code, "a < b") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.code, "\"<div>\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.code, "// <span />") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.code, "`<p>${value}</p>`") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.code, "h(Ok, null)") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.code, "h(No, null)") != null);
}

test "preserves UTF-8 text while lowering an element" {
    const source = "function App() { return <p>Caf\xc3\xa9</p>; }";
    var result = try lower(std.testing.allocator, source, null);
    defer result.deinit();

    try std.testing.expectEqualStrings(
        "function App() { return h(\"p\", null, \"Caf\xc3\xa9\"); }",
        result.code,
    );
}

test "reports a mismatched closing tag at the authored location" {
    var diagnostic: ?Diagnostic = null;
    try std.testing.expectError(
        error.InvalidTsx,
        lower(std.testing.allocator, "const x = (\n  <div><span /></section>\n);", &diagnostic),
    );
    try std.testing.expectEqual(DiagnosticKind.mismatched_tag, diagnostic.?.kind);
    try std.testing.expectEqual(@as(u32, 2), diagnostic.?.line);
    try std.testing.expectEqual(@as(u32, 16), diagnostic.?.column);
}

test "closes every lowering allocation failure" {
    const Context = struct {
        fn run(allocator: std.mem.Allocator) !void {
            var result = try lower(allocator, "const x = <div title={name}><span>Hi</span></div>;", null);
            defer result.deinit();
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Context.run, .{});
}
