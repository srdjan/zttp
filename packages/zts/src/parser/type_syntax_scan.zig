//! Admission byte scanners for type syntax: type-only module, quoted region, generic list, call type argument, and endpoint scans.

const std = @import("std");
const retired_types_module = @import("zts-base").module_specifier.retired_types_module;
const token_mod = @import("token.zig");
const TokenType = token_mod.TokenType;
const tokenizer_mod = @import("tokenizer.zig");
const Token = token_mod.Token;
const Tokenizer = tokenizer_mod.Tokenizer;
const store_mod = @import("type_syntax_store.zig");
const TypeOnlyModule = store_mod.TypeOnlyModule;
const TypeOnlyModuleScanOptions = store_mod.TypeOnlyModuleScanOptions;
const TypeOnlyModuleScan = store_mod.TypeOnlyModuleScan;
const TypeOnlyModuleKind = store_mod.TypeOnlyModuleKind;
const TypeOnlyModuleDiagnostic = store_mod.TypeOnlyModuleDiagnostic;
const parser_mod = @import("type_syntax_parser.zig");
const isIdentifierContinue = parser_mod.isIdentifierContinue;
const max_template_levels = parser_mod.max_template_levels;
const TypeOnlyModuleDiagnosticKind = store_mod.TypeOnlyModuleDiagnosticKind;
const max_type_depth = parser_mod.max_type_depth;
const Span = store_mod.Span;
const AdmissionDiagnostic = store_mod.AdmissionDiagnostic;
const AdmissionPosition = store_mod.AdmissionPosition;
const AdmissionPresentation = store_mod.AdmissionPresentation;
const AdmissionSink = store_mod.AdmissionSink;
const AdmissionTypePolicy = store_mod.AdmissionTypePolicy;
const isIdentifierStart = parser_mod.isIdentifierStart;
const AdmissionTypeSpanOptions = store_mod.AdmissionTypeSpanOptions;
const AdmissionKind = store_mod.AdmissionKind;
const AdmissionCollector = store_mod.AdmissionCollector;
const AdmissionObservationHistory = store_mod.AdmissionObservationHistory;
const TypeOnlyModuleRefusalReason = store_mod.TypeOnlyModuleRefusalReason;
const Store = store_mod.Store;
const AdmissionMode = store_mod.AdmissionMode;

const RawTypeOnlyModuleScan = struct {
    module: TypeOnlyModule,
    refused: bool,
    encountered_diagnostic: bool,
};

pub fn scanTypeOnlyModule(
    allocator: std.mem.Allocator,
    options: TypeOnlyModuleScanOptions,
) !TypeOnlyModuleScan {
    const diagnostic_checkpoint = options.diagnostics.items.len;
    errdefer options.diagnostics.items.len = diagnostic_checkpoint;

    const kind: TypeOnlyModuleKind = switch (options.keyword.type) {
        .kw_import => .import_type,
        .kw_export => .export_type,
        else => return .not_type_only,
    };
    const scanned = (try scanRawTypeOnlyModule(
        allocator,
        options.source,
        options.keyword.start,
        kind,
        options.diagnostics,
    )) orelse {
        options.diagnostics.items.len = diagnostic_checkpoint;
        return .not_type_only;
    };
    if (scanned.refused) {
        return .{ .refused = .{
            .reason = .zttp_types,
            .original_location = options.keyword.location(),
            .raw_span = scanned.module.raw_span,
        } };
    }
    if (scanned.encountered_diagnostic) return .{ .excluded = scanned.module };
    return .{ .scanned = scanned.module };
}

pub fn scanRawTypeOnlyModule(
    allocator: std.mem.Allocator,
    source: []const u8,
    start: u32,
    kind: TypeOnlyModuleKind,
    diagnostics: *std.ArrayListUnmanaged(TypeOnlyModuleDiagnostic),
) !?RawTypeOnlyModuleScan {
    const diagnostic_checkpoint = diagnostics.items.len;
    errdefer diagnostics.items.len = diagnostic_checkpoint;
    const keyword = switch (kind) {
        .import_type => "import",
        .export_type => "export",
    };
    var pos: usize = start;
    if (!literalKeywordAt(source, pos, keyword)) return null;
    pos += keyword.len;
    while (pos < source.len and isTypeWhitespace(source[pos])) pos += 1;
    if (!literalKeywordAt(source, pos, "type")) return null;
    pos += "type".len;

    if (kind == .export_type) {
        while (pos < source.len and (source[pos] == ' ' or source[pos] == '\t')) pos += 1;
        if (pos >= source.len or source[pos] != '{') return null;
    }

    var raw_scanner = RawModuleScanner.init(allocator, source, diagnostics);
    defer raw_scanner.deinit();
    const end = try raw_scanner.scanStatementEnd(pos);
    const module: TypeOnlyModule = .{
        .kind = kind,
        .raw_span = .{ .start = start, .end = @intCast(end) },
    };
    const refused = kind == .import_type and containsLegacyTypesImport(module.raw_span.text(source));
    return .{
        .module = module,
        .refused = refused,
        .encountered_diagnostic = raw_scanner.encountered_diagnostic,
    };
}

fn literalKeywordAt(source: []const u8, start: usize, keyword: []const u8) bool {
    if (start > source.len or keyword.len > source.len - start) return false;
    if (start > 0 and isIdentifierContinue(source[start - 1])) return false;
    const end = start + keyword.len;
    if (!std.mem.eql(u8, source[start..end], keyword)) return false;
    return end == source.len or !isIdentifierContinue(source[end]);
}

fn containsLegacyTypesImport(statement: []const u8) bool {
    return std.mem.indexOf(u8, statement, "\"" ++ retired_types_module ++ "\"") != null or
        std.mem.indexOf(u8, statement, "'" ++ retired_types_module ++ "'") != null;
}

const RawTemplateFrames = struct {
    allocator: std.mem.Allocator,
    inline_frames: [max_template_levels]u16 = undefined,
    overflow: std.ArrayListUnmanaged(u16) = .empty,
    len: usize = 0,

    fn init(allocator: std.mem.Allocator) RawTemplateFrames {
        return .{ .allocator = allocator };
    }

    fn deinit(self: *RawTemplateFrames) void {
        self.overflow.deinit(self.allocator);
    }

    fn push(self: *RawTemplateFrames, depth: u16) !void {
        if (self.len < self.inline_frames.len) {
            self.inline_frames[self.len] = depth;
        } else {
            try self.overflow.append(self.allocator, depth);
        }
        self.len += 1;
    }

    fn pop(self: *RawTemplateFrames) void {
        std.debug.assert(self.len > 0);
        self.len -= 1;
        if (self.len >= self.inline_frames.len) self.overflow.items.len -= 1;
    }

    fn top(self: *RawTemplateFrames) *u16 {
        std.debug.assert(self.len > 0);
        if (self.len <= self.inline_frames.len) return &self.inline_frames[self.len - 1];
        return &self.overflow.items[self.len - self.inline_frames.len - 1];
    }
};

const RawModuleScanner = struct {
    allocator: std.mem.Allocator,
    source: []const u8,
    diagnostics: *std.ArrayListUnmanaged(TypeOnlyModuleDiagnostic),
    frames: RawTemplateFrames,
    encountered_diagnostic: bool = false,

    fn init(
        allocator: std.mem.Allocator,
        source: []const u8,
        diagnostics: *std.ArrayListUnmanaged(TypeOnlyModuleDiagnostic),
    ) RawModuleScanner {
        return .{
            .allocator = allocator,
            .source = source,
            .diagnostics = diagnostics,
            .frames = RawTemplateFrames.init(allocator),
        };
    }

    fn deinit(self: *RawModuleScanner) void {
        self.frames.deinit();
    }

    fn recordDiagnostic(
        self: *RawModuleScanner,
        kind: TypeOnlyModuleDiagnosticKind,
        offset: usize,
    ) !void {
        self.encountered_diagnostic = true;
        const exact = std.math.cast(u32, offset) orelse return error.TypeSourceTooLarge;
        for (self.diagnostics.items) |diagnostic| {
            if (diagnostic.offset == exact) return;
        }
        try self.diagnostics.append(self.allocator, .{ .kind = kind, .offset = exact });
    }

    fn scanStatementEnd(self: *RawModuleScanner, start: usize) !usize {
        var pos = start;
        while (pos < self.source.len) {
            switch (self.source[pos]) {
                ';' => return pos + 1,
                '\n' => return pos,
                '\'', '"' => pos = try self.scanOrdinaryString(pos, self.source[pos]),
                '`' => pos = try self.scanTemplate(pos),
                else => pos += 1,
            }
        }
        return pos;
    }

    fn scanOrdinaryString(self: *RawModuleScanner, start: usize, quote: u8) !usize {
        const scanned = scanLegacyPlainQuoted(self.source, start, quote);
        if (scanned.unterminated_line) {
            try self.recordDiagnostic(.unterminated_string, scanned.end);
        }
        return scanned.end;
    }

    fn scanTemplate(self: *RawModuleScanner, start: usize) !usize {
        std.debug.assert(self.frames.len == 0);
        try self.frames.push(0);
        defer self.frames.len = 0;
        defer self.frames.overflow.items.len = 0;

        var pos = start + 1;
        while (pos < self.source.len and self.frames.len > 0) {
            const depth = self.frames.top();
            if (depth.* == 0) {
                if (self.source[pos] == '\\' and pos + 1 < self.source.len) {
                    pos += 2;
                } else if (self.source[pos] == '`') {
                    self.frames.pop();
                    pos += 1;
                } else if (self.source[pos] == '$' and pos + 1 < self.source.len and
                    self.source[pos + 1] == '{')
                {
                    depth.* = 1;
                    pos += 2;
                } else {
                    pos += 1;
                }
                continue;
            }

            switch (self.source[pos]) {
                '\'', '"' => pos = try self.scanOrdinaryString(pos, self.source[pos]),
                '`' => {
                    try self.frames.push(0);
                    pos += 1;
                },
                '\\' => pos += if (pos + 1 < self.source.len) 2 else 1,
                '{' => {
                    if (depth.* == max_type_depth) {
                        try self.recordDiagnostic(.nesting_too_deep, pos);
                        self.frames.pop();
                    } else {
                        depth.* += 1;
                        pos += 1;
                    }
                },
                '}' => {
                    depth.* -= 1;
                    pos += 1;
                },
                else => pos += 1,
            }
        }
        return pos;
    }
};

/// A value copy of every tokenizer field, including its cached token state.
/// The cursor borrows the same source as the parser that created it.
pub const Cursor = struct {
    tokenizer: Tokenizer,
    current: Token,
    consumed: u32,

    /// Start after the parser's current token.
    pub fn afterCurrent(tokenizer: Tokenizer) Cursor {
        var cursor = Cursor{
            .tokenizer = tokenizer,
            .current = undefined,
            .consumed = 0,
        };
        cursor.advance();
        return cursor;
    }

    pub fn init(source: []const u8) Cursor {
        return afterCurrent(Tokenizer.init(source));
    }

    pub fn advance(self: *Cursor) void {
        self.current = self.tokenizer.next();
        self.consumed +|= 1;
    }
};

pub fn scanParenthesizedArrowHeader(
    source: []const u8,
    opener: u32,
    after_opener: Cursor,
) ?u32 {
    if (@as(usize, opener) >= source.len or source[opener] != '(') return null;
    var cursor = after_opener;
    var depth: u16 = 1;
    while (cursor.current.type != .eof) {
        switch (cursor.current.type) {
            .lparen => {
                if (depth == max_type_depth) return null;
                depth += 1;
            },
            .rparen => {
                depth -= 1;
                if (depth == 0) break;
            },
            else => {},
        }
        cursor.advance();
    }
    if (depth != 0) return null;
    cursor.advance();
    if (cursor.current.type == .arrow) return cursor.current.start;
    if (cursor.current.type != .colon) return null;

    const raw_start = skipTypeWhitespace(source, cursor.current.start + cursor.current.len);
    const arrow = switch (scanAdmissionEnd(source, raw_start)) {
        .end => |end| end,
        else => return null,
    };
    if (@as(usize, arrow) + 1 >= source.len or
        source[arrow] != '=' or source[arrow + 1] != '>')
    {
        return null;
    }
    return arrow;
}

pub const GenericListScan = struct {
    span: Span,
    suppressed_diagnostic: bool,
};

pub const AdmissionGenericScan = union(enum) {
    not_matched,
    lexical_nonmatch,
    scanned: GenericListScan,
    nesting_too_deep: u32,
};

pub const AdmissionRawScanOptions = struct {
    source: []const u8,
    start: u32,
    caught: *std.ArrayListUnmanaged(AdmissionDiagnostic),
};

pub const AdmissionQuotedScan = union(enum) {
    complete: u32,
    terminal: AdmissionDiagnostic,
};

pub const AdmissionBraceScan = union(enum) {
    complete: u32,
    nesting_too_deep: u32,
};

pub const ExplicitCallScan = union(enum) {
    not_call,
    excluded,
    scanned: GenericListScan,
};

const LegacyTemplateFrame = struct {
    interpolation_depth: u16 = 0,
    propagate_errors: bool,
};

const LegacyQuoteFailure = union(enum) {
    unterminated_string: u32,
    nesting_too_deep: u32,
};

const LegacyMatchingBracketScan = union(enum) {
    complete: usize,
    nesting_too_deep: u32,
};

const ObservedBracketScan = union(enum) {
    complete: struct { end: usize, closed: bool },
    not_matched,
    nesting_too_deep: u32,
};

pub const AdmissionHeaderProbe = union(enum) {
    matched: u32,
    not_matched,
    nesting_too_deep: AdmissionDiagnostic,
};

pub fn scanAdmissionHeaderProbe(
    allocator: std.mem.Allocator,
    options: struct {
        source: []const u8,
        opener: u32,
        confirmation: enum { return_colon, arrow },
        position: AdmissionPosition,
        caught: *std.ArrayListUnmanaged(AdmissionDiagnostic),
    },
) !AdmissionHeaderProbe {
    const source = options.source;
    if (@as(usize, options.opener) >= source.len or source[options.opener] != '(') {
        return error.InvalidAdmissionSpan;
    }
    const checkpoint = options.caught.items.len;
    errdefer options.caught.items.len = checkpoint;
    var position = options.position;
    var suppressed = false;
    const ending = switch (try scanObservedMatchingBracket(
        allocator,
        source,
        options.opener,
        '(',
        &suppressed,
        options.caught,
        &position,
    )) {
        .complete => |complete| if (complete.closed) complete.end else return .not_matched,
        .not_matched => return .not_matched,
        .nesting_too_deep => |offset| return .{ .nesting_too_deep = .{
            .kind = .nesting_too_deep,
            .span = .{ .start = offset, .end = offset + 1 },
            .presentation = position,
        } },
    };
    var offset = ending;
    while (offset < source.len and isTypeWhitespace(source[offset])) offset += 1;
    if (offset + 1 < source.len and source[offset] == '=' and source[offset + 1] == '>') {
        return .{ .matched = @intCast(offset) };
    }
    if (offset >= source.len or source[offset] != ':') return .not_matched;
    if (options.confirmation == .return_colon) return .{ .matched = @intCast(offset) };
    offset += 1;
    var depth: u16 = 0;
    while (offset < source.len) {
        const byte = source[offset];
        if (byte == '\'' or byte == '"' or byte == '`') {
            offset = (try scanProbeQuote(allocator, source, offset, options.caught, &position)) orelse
                return .not_matched;
            continue;
        }
        if (byte == '=' and offset + 1 < source.len and source[offset + 1] == '>') {
            if (depth == 0) return .{ .matched = @intCast(offset) };
            offset += 2;
            continue;
        }
        switch (byte) {
            '(', '[', '{', '<' => {
                if (depth >= max_type_depth) return .{ .nesting_too_deep = .{
                    .kind = .nesting_too_deep,
                    .span = .{ .start = @intCast(offset), .end = @intCast(offset + 1) },
                    .presentation = position,
                } };
                depth += 1;
            },
            ')', ']', '}' => {
                if (depth == 0) return .not_matched;
                depth -= 1;
            },
            '>' => if (depth > 0) {
                depth -= 1;
            },
            ',', ';' => if (depth == 0) return .not_matched,
            else => {},
        }
        offset += 1;
    }
    return .not_matched;
}

fn scanProbeQuote(
    allocator: std.mem.Allocator,
    source: []const u8,
    start: usize,
    caught: *std.ArrayListUnmanaged(AdmissionDiagnostic),
    position: *AdmissionPosition,
) !?usize {
    const checkpoint = caught.items.len;
    errdefer caught.items.len = checkpoint;
    var suppressed = false;
    var failure: ?LegacyQuoteFailure = null;
    const ending = try scanLegacyGenericQuotedCore(
        allocator,
        source,
        start,
        source[start],
        true,
        &suppressed,
        caught,
        &failure,
    );
    if (ending == null) try appendLegacyQuoteFailure(allocator, caught, failure orelse
        return error.InvalidAdmissionQuoteResult);
    const context: AdmissionPresentation = .{
        .source = source,
        .offset = @intCast(start),
        .position = position.*,
    };
    for (caught.items[checkpoint..]) |*diagnostic| {
        diagnostic.presentation = try context.positionAt(diagnostic.span.start);
    }
    const observed_end = ending orelse switch (failure.?) {
        .unterminated_string => |offset| offset,
        .nesting_too_deep => |offset| offset,
    };
    position.* = try context.positionAt(@intCast(observed_end));
    return ending;
}

fn scanLegacyPlainQuoted(source: []const u8, start: usize, quote: u8) struct {
    end: usize,
    unterminated_line: bool,
} {
    var pos = start + 1;
    while (pos < source.len) {
        if (source[pos] == quote) return .{ .end = pos + 1, .unterminated_line = false };
        if (source[pos] == '\\' and pos + 1 < source.len) {
            pos += 2;
            continue;
        }
        if (source[pos] == '\n') return .{ .end = pos, .unterminated_line = true };
        pos += 1;
    }
    return .{ .end = source.len, .unterminated_line = false };
}

fn scanLegacyGenericQuoted(
    allocator: std.mem.Allocator,
    source: []const u8,
    start: usize,
    quote: u8,
    propagate_errors: bool,
    suppressed_diagnostic: *bool,
) !?usize {
    var failure: ?LegacyQuoteFailure = null;
    return scanLegacyGenericQuotedCore(
        allocator,
        source,
        start,
        quote,
        propagate_errors,
        suppressed_diagnostic,
        null,
        &failure,
    );
}

fn scanLegacyGenericQuotedCore(
    allocator: std.mem.Allocator,
    source: []const u8,
    start: usize,
    quote: u8,
    propagate_errors: bool,
    suppressed_diagnostic: *bool,
    caught: ?*std.ArrayListUnmanaged(AdmissionDiagnostic),
    failure: *?LegacyQuoteFailure,
) !?usize {
    if (quote != '`') {
        const scanned = scanLegacyPlainQuoted(source, start, quote);
        if (scanned.unterminated_line and propagate_errors) {
            failure.* = .{ .unterminated_string = @intCast(scanned.end) };
            return null;
        }
        if (scanned.unterminated_line) {
            suppressed_diagnostic.* = true;
            if (caught) |items| try items.append(allocator, .{
                .kind = .unterminated_string,
                .span = .{ .start = @intCast(scanned.end), .end = @intCast(scanned.end + 1) },
            });
        }
        return scanned.end;
    }

    var frames: std.ArrayListUnmanaged(LegacyTemplateFrame) = .empty;
    defer frames.deinit(allocator);
    try frames.append(allocator, .{ .propagate_errors = propagate_errors });
    var pos = start + 1;
    while (pos < source.len and frames.items.len > 0) {
        const frame = &frames.items[frames.items.len - 1];
        if (frame.interpolation_depth == 0) {
            if (source[pos] == '`') {
                _ = frames.pop();
                pos += 1;
                continue;
            }
            if (source[pos] == '\\' and pos + 1 < source.len) {
                pos += 2;
                continue;
            }
            if (source[pos] == '$' and pos + 1 < source.len and source[pos + 1] == '{') {
                frame.interpolation_depth = 1;
                pos += 2;
                continue;
            }
            pos += 1;
            continue;
        }

        if (source[pos] == '"' or source[pos] == '\'') {
            const nested = scanLegacyPlainQuoted(source, pos, source[pos]);
            if (nested.unterminated_line) {
                suppressed_diagnostic.* = true;
                if (caught) |items| try items.append(allocator, .{
                    .kind = .unterminated_string,
                    .span = .{ .start = @intCast(nested.end), .end = @intCast(nested.end + 1) },
                });
            }
            pos = nested.end;
            continue;
        }
        if (source[pos] == '`') {
            try frames.append(allocator, .{ .propagate_errors = false });
            pos += 1;
            continue;
        }
        if (source[pos] == '\\' and pos + 1 < source.len) {
            pos += 2;
            continue;
        }
        if (source[pos] == '{') {
            if (frame.interpolation_depth >= max_type_depth) {
                const offset: u32 = @intCast(pos);
                if (frame.propagate_errors) {
                    failure.* = .{ .nesting_too_deep = offset };
                    return null;
                }
                suppressed_diagnostic.* = true;
                if (caught) |items| try items.append(allocator, .{
                    .kind = .nesting_too_deep,
                    .span = .{ .start = offset, .end = offset + 1 },
                });
                _ = frames.pop();
                continue;
            }
            frame.interpolation_depth += 1;
        } else if (source[pos] == '}') {
            frame.interpolation_depth -= 1;
        }
        pos += 1;
    }
    return pos;
}

pub fn scanAdmissionQuotedRegion(
    allocator: std.mem.Allocator,
    options: AdmissionRawScanOptions,
) !AdmissionQuotedScan {
    if (options.source.len > std.math.maxInt(u32)) return error.TypeSourceTooLarge;
    if (@as(usize, options.start) >= options.source.len) return error.InvalidAdmissionSpan;
    const quote = options.source[options.start];
    if (quote != '\'' and quote != '"' and quote != '`') {
        return error.InvalidAdmissionSpan;
    }

    const caught_checkpoint = options.caught.items.len;
    errdefer options.caught.items.len = caught_checkpoint;
    var suppressed_diagnostic = false;
    var failure: ?LegacyQuoteFailure = null;
    const end = try scanLegacyGenericQuotedCore(
        allocator,
        options.source,
        options.start,
        quote,
        true,
        &suppressed_diagnostic,
        options.caught,
        &failure,
    );
    if (end) |complete| return .{ .complete = @intCast(complete) };
    const terminal: AdmissionDiagnostic = switch (failure orelse
        return error.InvalidAdmissionQuoteResult) {
        .unterminated_string => |offset| .{
            .kind = .unterminated_string,
            .span = .{ .start = offset, .end = offset + 1 },
        },
        .nesting_too_deep => |offset| .{
            .kind = .nesting_too_deep,
            .span = .{ .start = offset, .end = offset + 1 },
        },
    };
    return .{ .terminal = terminal };
}

fn appendLegacyQuoteFailure(
    allocator: std.mem.Allocator,
    caught: ?*std.ArrayListUnmanaged(AdmissionDiagnostic),
    failure: LegacyQuoteFailure,
) !void {
    const items = caught orelse return;
    const diagnostic: AdmissionDiagnostic = switch (failure) {
        .unterminated_string => |offset| .{
            .kind = .unterminated_string,
            .span = .{ .start = offset, .end = offset + 1 },
        },
        .nesting_too_deep => |offset| .{
            .kind = .nesting_too_deep,
            .span = .{ .start = offset, .end = offset + 1 },
        },
    };
    try items.append(allocator, diagnostic);
}

fn scanLegacyMatchingBracketCore(
    allocator: std.mem.Allocator,
    source: []const u8,
    start: usize,
    open: u8,
    suppressed_diagnostic: *bool,
    caught: ?*std.ArrayListUnmanaged(AdmissionDiagnostic),
) !LegacyMatchingBracketScan {
    return switch (try scanObservedMatchingBracket(
        allocator,
        source,
        start,
        open,
        suppressed_diagnostic,
        caught,
        null,
    )) {
        .complete => |complete| .{ .complete = complete.end },
        .nesting_too_deep => |offset| .{ .nesting_too_deep = offset },
        .not_matched => error.InvalidAdmissionQuoteResult,
    };
}

fn scanObservedMatchingBracket(
    allocator: std.mem.Allocator,
    source: []const u8,
    start: usize,
    open: u8,
    suppressed_diagnostic: *bool,
    caught: ?*std.ArrayListUnmanaged(AdmissionDiagnostic),
    probe_position: ?*AdmissionPosition,
) !ObservedBracketScan {
    if (source.len > std.math.maxInt(u32)) return error.TypeSourceTooLarge;
    const caught_checkpoint = if (caught) |items| items.items.len else 0;
    errdefer {
        if (caught) |items| items.items.len = caught_checkpoint;
    }
    const close: u8 = switch (open) {
        '(' => ')',
        '[' => ']',
        '{' => '}',
        else => return .{ .complete = .{ .end = start + 1, .closed = true } },
    };
    var depth: u16 = 1;
    var pos = start + 1;
    while (pos < source.len and depth > 0) {
        const byte = source[pos];
        if (byte == '"' or byte == '\'' or byte == '`') {
            if (probe_position) |position| {
                pos = (try scanProbeQuote(allocator, source, pos, caught orelse
                    return error.InvalidAdmissionQuoteResult, position)) orelse return .not_matched;
                continue;
            }
            var failure: ?LegacyQuoteFailure = null;
            pos = (try scanLegacyGenericQuotedCore(
                allocator,
                source,
                pos,
                byte,
                false,
                suppressed_diagnostic,
                caught,
                &failure,
            )) orelse return error.InvalidAdmissionQuoteResult;
            continue;
        }
        if (byte == open) {
            if (depth >= max_type_depth) {
                return .{ .nesting_too_deep = @intCast(pos) };
            }
            depth += 1;
        } else if (byte == close) {
            depth -= 1;
        }
        pos += 1;
    }
    return .{ .complete = .{ .end = pos, .closed = depth == 0 } };
}

fn scanBalancedGenericListCore(
    allocator: std.mem.Allocator,
    source: []const u8,
    start: u32,
    caught: ?*std.ArrayListUnmanaged(AdmissionDiagnostic),
) !AdmissionGenericScan {
    if (source.len > std.math.maxInt(u32)) return error.TypeSourceTooLarge;
    if (@as(usize, start) > source.len) return error.InvalidAdmissionSpan;
    if (@as(usize, start) == source.len or source[start] != '<') return .not_matched;
    const caught_checkpoint = if (caught) |items| items.items.len else 0;
    errdefer {
        if (caught) |items| items.items.len = caught_checkpoint;
    }
    var angle_depth: u16 = 1;
    var suppressed_diagnostic = false;
    var pos: usize = start + 1;
    while (pos < source.len and angle_depth > 0) {
        const byte = source[pos];
        if (byte == '"' or byte == '\'' or byte == '`') {
            var failure: ?LegacyQuoteFailure = null;
            pos = (try scanLegacyGenericQuotedCore(
                allocator,
                source,
                pos,
                byte,
                true,
                &suppressed_diagnostic,
                caught,
                &failure,
            )) orelse {
                try appendLegacyQuoteFailure(
                    allocator,
                    caught,
                    failure orelse return error.InvalidAdmissionQuoteResult,
                );
                return .lexical_nonmatch;
            };
            continue;
        }
        if (byte == '/' and pos + 1 < source.len) {
            if (source[pos + 1] == '/') {
                while (pos < source.len and source[pos] != '\n') pos += 1;
                continue;
            }
            if (source[pos + 1] == '*') {
                pos += 2;
                while (pos + 1 < source.len and !(source[pos] == '*' and source[pos + 1] == '/')) pos += 1;
                if (pos + 1 >= source.len) return .lexical_nonmatch;
                pos += 2;
                continue;
            }
        }
        switch (byte) {
            '<' => {
                if (angle_depth >= max_type_depth) {
                    return .{ .nesting_too_deep = @intCast(pos) };
                }
                angle_depth += 1;
            },
            '>' => if (pos == 0 or source[pos - 1] != '=') {
                angle_depth -= 1;
            },
            '(', '[', '{' => {
                switch (try scanLegacyMatchingBracketCore(
                    allocator,
                    source,
                    pos,
                    byte,
                    &suppressed_diagnostic,
                    caught,
                )) {
                    .complete => |end| pos = end,
                    .nesting_too_deep => |offset| {
                        return .{ .nesting_too_deep = offset };
                    },
                }
                continue;
            },
            else => {},
        }
        pos += 1;
    }
    if (angle_depth != 0) return .not_matched;
    return .{ .scanned = .{
        .span = .{ .start = start, .end = @intCast(pos) },
        .suppressed_diagnostic = suppressed_diagnostic,
    } };
}

pub fn scanAdmissionGenericList(
    allocator: std.mem.Allocator,
    options: AdmissionRawScanOptions,
) !AdmissionGenericScan {
    return scanBalancedGenericListCore(
        allocator,
        options.source,
        options.start,
        options.caught,
    );
}

pub fn scanBalancedGenericList(
    allocator: std.mem.Allocator,
    source: []const u8,
    start: u32,
) !?GenericListScan {
    if (@as(usize, start) >= source.len) return null;
    return switch (try scanBalancedGenericListCore(allocator, source, start, null)) {
        .scanned => |scan| scan,
        .not_matched, .lexical_nonmatch, .nesting_too_deep => null,
    };
}

fn hasRegexShapedGenericSource(source: []const u8, span: Span) bool {
    var pos: usize = span.start + 1;
    const end: usize = span.end - 1;
    while (pos < end) {
        const byte = source[pos];
        if (byte == '"' or byte == '\'' or byte == '`') {
            switch (scanTypeQuoted(source, pos, byte)) {
                .end => |quoted_end| pos = @min(quoted_end, end),
                else => return true,
            }
            continue;
        }
        if (byte == '/') {
            if (pos + 1 < end and source[pos + 1] == '/') {
                pos += 2;
                while (pos < end and source[pos] != '\n') pos += 1;
                continue;
            }
            if (pos + 1 < end and source[pos + 1] == '*') {
                pos += 2;
                while (pos + 1 < end and !(source[pos] == '*' and source[pos + 1] == '/')) pos += 1;
                pos = @min(pos + 2, end);
                continue;
            }
            return true;
        }
        pos += 1;
    }
    return false;
}

pub fn isPrivateGenericListEligible(source: []const u8, scan: GenericListScan) bool {
    return !scan.suppressed_diagnostic and !hasRegexShapedGenericSource(source, scan.span);
}

pub fn isPrivateErasedPrefixListEligible(source: []const u8, scan: GenericListScan) bool {
    return isPrivateGenericListEligible(source, scan) and scan.span.end - scan.span.start >= 2;
}

fn scanExplicitCallTypeArgumentsCore(
    allocator: std.mem.Allocator,
    source: []const u8,
    start: u32,
    caught: ?*std.ArrayListUnmanaged(AdmissionDiagnostic),
) !AdmissionGenericScan {
    if (source.len > std.math.maxInt(u32)) return error.TypeSourceTooLarge;
    if (@as(usize, start) > source.len) return error.InvalidAdmissionSpan;
    if (@as(usize, start) == source.len or source[start] != '<') return .not_matched;
    const caught_checkpoint = if (caught) |items| items.items.len else 0;
    errdefer {
        if (caught) |items| items.items.len = caught_checkpoint;
    }
    var angle_depth: u16 = 1;
    var paren_depth: u16 = 0;
    var bracket_depth: u16 = 0;
    var brace_depth: u16 = 0;
    var suppressed_diagnostic = false;
    var pos: usize = start + 1;
    while (pos < source.len) {
        const byte = source[pos];
        if (byte == '"' or byte == '\'' or byte == '`') {
            var failure: ?LegacyQuoteFailure = null;
            pos = (try scanLegacyGenericQuotedCore(
                allocator,
                source,
                pos,
                byte,
                true,
                &suppressed_diagnostic,
                caught,
                &failure,
            )) orelse {
                try appendLegacyQuoteFailure(
                    allocator,
                    caught,
                    failure orelse return error.InvalidAdmissionQuoteResult,
                );
                return .lexical_nonmatch;
            };
            continue;
        }
        if (byte == '/' and pos + 1 < source.len) {
            if (source[pos + 1] == '/') {
                while (pos < source.len and source[pos] != '\n') pos += 1;
                continue;
            }
            if (source[pos + 1] == '*') {
                pos += 2;
                while (pos + 1 < source.len and !(source[pos] == '*' and source[pos + 1] == '/')) pos += 1;
                if (pos + 1 >= source.len) return .lexical_nonmatch;
                pos += 2;
                continue;
            }
        }

        switch (byte) {
            '>' => {
                if (angle_depth == 1) {
                    if (paren_depth != 0 or bracket_depth != 0 or brace_depth != 0 or
                        pos + 1 >= source.len or source[pos + 1] != '(')
                    {
                        return .not_matched;
                    }
                    return .{ .scanned = .{
                        .span = .{ .start = start, .end = @intCast(pos + 1) },
                        .suppressed_diagnostic = suppressed_diagnostic,
                    } };
                }
                angle_depth -= 1;
            },
            '<' => if (!increaseCombinedGenericDepth(
                &angle_depth,
                paren_depth,
                bracket_depth,
                brace_depth,
            )) return .{ .nesting_too_deep = @intCast(pos) },
            '(' => if (!increaseCombinedGenericDepth(
                &paren_depth,
                angle_depth,
                bracket_depth,
                brace_depth,
            )) return .{ .nesting_too_deep = @intCast(pos) },
            ')' => {
                if (paren_depth == 0) return .not_matched;
                paren_depth -= 1;
            },
            '[' => if (!increaseCombinedGenericDepth(
                &bracket_depth,
                angle_depth,
                paren_depth,
                brace_depth,
            )) return .{ .nesting_too_deep = @intCast(pos) },
            ']' => {
                if (bracket_depth == 0) return .not_matched;
                bracket_depth -= 1;
            },
            '{' => if (!increaseCombinedGenericDepth(
                &brace_depth,
                angle_depth,
                paren_depth,
                bracket_depth,
            )) return .{ .nesting_too_deep = @intCast(pos) },
            '}' => {
                if (brace_depth == 0) return .not_matched;
                brace_depth -= 1;
            },
            '=' => {
                if (pos + 1 >= source.len or source[pos + 1] != '>') return .not_matched;
                pos += 2;
                continue;
            },
            '|', '&' => if (pos + 1 < source.len and source[pos + 1] == byte) return .not_matched,
            '?', ':' => if (paren_depth == 0 and bracket_depth == 0 and brace_depth == 0) return .not_matched,
            ';' => if (brace_depth == 0) return .not_matched,
            '-' => if (pos + 1 >= source.len or !std.ascii.isDigit(source[pos + 1])) return .not_matched,
            ' ', '\t', '\n', '\r', ',', '.' => {},
            else => if (!isIdentifierContinue(byte)) return .not_matched,
        }
        pos += 1;
    }
    return .not_matched;
}

pub fn scanAdmissionCallTypeArguments(
    allocator: std.mem.Allocator,
    options: AdmissionRawScanOptions,
) !AdmissionGenericScan {
    return scanExplicitCallTypeArgumentsCore(
        allocator,
        options.source,
        options.start,
        options.caught,
    );
}

pub fn scanExplicitCallTypeArguments(
    allocator: std.mem.Allocator,
    source: []const u8,
    start: u32,
) !ExplicitCallScan {
    if (@as(usize, start) >= source.len) return .not_call;
    return switch (try scanExplicitCallTypeArgumentsCore(allocator, source, start, null)) {
        .scanned => |scan| .{ .scanned = scan },
        .not_matched => .not_call,
        .lexical_nonmatch, .nesting_too_deep => .excluded,
    };
}

pub fn scanAdmissionBraceBody(
    allocator: std.mem.Allocator,
    options: AdmissionRawScanOptions,
) !AdmissionBraceScan {
    if (@as(usize, options.start) >= options.source.len or options.source[options.start] != '{') {
        return error.InvalidAdmissionSpan;
    }
    var suppressed_diagnostic = false;
    return switch (try scanLegacyMatchingBracketCore(
        allocator,
        options.source,
        options.start,
        '{',
        &suppressed_diagnostic,
        options.caught,
    )) {
        .complete => |end| .{ .complete = @intCast(end) },
        .nesting_too_deep => |offset| .{ .nesting_too_deep = offset },
    };
}

fn increaseCombinedGenericDepth(
    depth: *u16,
    other_a: u16,
    other_b: u16,
    other_c: u16,
) bool {
    const total = @as(u32, depth.*) + other_a + other_b + other_c;
    if (total >= max_type_depth) return false;
    depth.* += 1;
    return true;
}

const AdmissionScan = union(enum) {
    end: u32,
    nesting_too_deep: u32,
    unmatched_parenthesis: u32,
    malformed: Span,
    implementation_budget: u32,
};

pub fn scanAdmissionEnd(source: []const u8, raw_start: u32) AdmissionScan {
    var pos: usize = raw_start;
    var paren_depth: u16 = 0;
    var bracket_depth: u16 = 0;
    var angle_depth: u16 = 0;
    var brace_depth: u16 = 0;

    while (pos < source.len) {
        const byte = source[pos];
        if (byte == '"' or byte == '\'' or byte == '`') {
            const quoted = scanTypeQuoted(source, pos, byte);
            switch (quoted) {
                .end => |end| pos = end,
                .nesting_too_deep => |offset| return .{ .nesting_too_deep = offset },
                .malformed => |span| return .{ .malformed = span },
                .implementation_budget => |offset| return .{ .implementation_budget = offset },
            }
            continue;
        }
        if (byte == '/' and pos + 1 < source.len) {
            if (source[pos + 1] == '/') {
                pos += 2;
                while (pos < source.len and source[pos] != '\n') pos += 1;
                continue;
            }
            if (source[pos + 1] == '*') {
                const comment_start = pos;
                pos += 2;
                while (pos + 1 < source.len and !(source[pos] == '*' and source[pos + 1] == '/')) pos += 1;
                if (pos + 1 >= source.len) {
                    return .{ .malformed = .{
                        .start = @intCast(comment_start),
                        .end = @intCast(source.len),
                    } };
                }
                pos += 2;
                continue;
            }
        }

        const at_top = paren_depth == 0 and bracket_depth == 0 and angle_depth == 0 and brace_depth == 0;
        if (byte == '=' and pos + 1 < source.len and source[pos + 1] == '>' and
            (!at_top or isFunctionTypePrefix(source[@as(usize, raw_start)..pos])))
        {
            pos += 2;
            continue;
        }
        if (at_top) {
            if (byte == '=' or byte == ';' or byte == ',' or byte == ')' or byte == '}') {
                return .{ .end = @intCast(pos) };
            }
            if (byte == '{' and !isObjectTypeBraceStart(source, raw_start, pos)) {
                return .{ .end = @intCast(pos) };
            }
        } else if (paren_depth > 0 and bracket_depth == 0 and angle_depth == 0 and brace_depth == 0 and
            (byte == '=' or byte == ';'))
        {
            return .{ .unmatched_parenthesis = @intCast(pos) };
        }

        switch (byte) {
            '(' => if (!increaseAdmissionDepth(&paren_depth, bracket_depth, angle_depth, brace_depth)) {
                return .{ .nesting_too_deep = @intCast(pos) };
            },
            '[' => if (!increaseAdmissionDepth(&bracket_depth, paren_depth, angle_depth, brace_depth)) {
                return .{ .nesting_too_deep = @intCast(pos) };
            },
            '<' => if (!increaseAdmissionDepth(&angle_depth, paren_depth, bracket_depth, brace_depth)) {
                return .{ .nesting_too_deep = @intCast(pos) };
            },
            '{' => if (!increaseAdmissionDepth(&brace_depth, paren_depth, bracket_depth, angle_depth)) {
                return .{ .nesting_too_deep = @intCast(pos) };
            },
            ')' => paren_depth -|= 1,
            ']' => bracket_depth -|= 1,
            '>' => angle_depth -|= 1,
            '}' => brace_depth -|= 1,
            else => {},
        }
        pos += 1;
    }

    if (paren_depth > 0) return .{ .unmatched_parenthesis = @intCast(source.len) };
    if (bracket_depth > 0 or angle_depth > 0 or brace_depth > 0) {
        return .{ .malformed = .{
            .start = raw_start,
            .end = @intCast(source.len),
        } };
    }
    return .{ .end = @intCast(source.len) };
}

pub fn scanDeclarationEnd(source: []const u8, raw_start: u32) AdmissionScan {
    var pos: usize = raw_start;
    var paren_depth: u16 = 0;
    var bracket_depth: u16 = 0;
    var angle_depth: u16 = 0;
    var brace_depth: u16 = 0;

    while (pos < source.len) {
        const byte = source[pos];
        if (byte == '"' or byte == '\'' or byte == '`') {
            switch (scanTypeQuoted(source, pos, byte)) {
                .end => |end| pos = end,
                .nesting_too_deep => |offset| return .{ .nesting_too_deep = offset },
                .malformed => |span| return .{ .malformed = span },
                .implementation_budget => |offset| return .{ .implementation_budget = offset },
            }
            continue;
        }
        if (byte == '/' and pos + 1 < source.len) {
            if (source[pos + 1] == '/') {
                pos += 2;
                while (pos < source.len and source[pos] != '\n') pos += 1;
                continue;
            }
            if (source[pos + 1] == '*') {
                const comment_start = pos;
                pos += 2;
                while (pos + 1 < source.len and !(source[pos] == '*' and source[pos + 1] == '/')) pos += 1;
                if (pos + 1 >= source.len) {
                    return .{ .malformed = .{
                        .start = @intCast(comment_start),
                        .end = @intCast(source.len),
                    } };
                }
                pos += 2;
                continue;
            }
        }

        const at_top = paren_depth == 0 and bracket_depth == 0 and angle_depth == 0 and brace_depth == 0;
        if (at_top and byte == ';') return .{ .end = @intCast(pos) };
        if (at_top and byte == '\n' and !multilineTypeContinues(source, pos)) {
            return .{ .end = @intCast(pos) };
        }

        switch (byte) {
            '(' => if (!increaseAdmissionDepth(&paren_depth, bracket_depth, angle_depth, brace_depth)) {
                return .{ .nesting_too_deep = @intCast(pos) };
            },
            '[' => if (!increaseAdmissionDepth(&bracket_depth, paren_depth, angle_depth, brace_depth)) {
                return .{ .nesting_too_deep = @intCast(pos) };
            },
            '<' => if (!increaseAdmissionDepth(&angle_depth, paren_depth, bracket_depth, brace_depth)) {
                return .{ .nesting_too_deep = @intCast(pos) };
            },
            '{' => if (!increaseAdmissionDepth(&brace_depth, paren_depth, bracket_depth, angle_depth)) {
                return .{ .nesting_too_deep = @intCast(pos) };
            },
            ')' => paren_depth -|= 1,
            ']' => bracket_depth -|= 1,
            '>' => angle_depth -|= 1,
            '}' => brace_depth -|= 1,
            else => {},
        }
        pos += 1;
    }

    if (paren_depth > 0) return .{ .unmatched_parenthesis = @intCast(source.len) };
    if (bracket_depth > 0 or angle_depth > 0 or brace_depth > 0) {
        return .{ .malformed = .{ .start = raw_start, .end = @intCast(source.len) } };
    }
    return .{ .end = @intCast(source.len) };
}

pub const GeneralAdmissionEndpoint = enum {
    variable,
    named_return,
    arrow_return,
    interface_extends,
    assertion,
};

pub const AdmissionEndpointPolicy = union(enum) {
    general: GeneralAdmissionEndpoint,
    parameter,
    declaration,
};

pub const AdmissionCommentFailure = struct {
    opener: u32,
    @"resume": u32,
};

pub const AdmissionEndpointResult = union(enum) {
    complete: Span,
    nesting_too_deep: u32,
    unterminated_comment: AdmissionCommentFailure,
};

pub const AdmissionTemplateScan = union(enum) {
    complete: u32,
    nesting_too_deep: u32,
};

const AdmissionQuoteScan = union(enum) {
    complete: usize,
    nesting_too_deep: u32,
};

fn scanAdmissionQuoted(
    allocator: std.mem.Allocator,
    source: []const u8,
    start: usize,
    quote: u8,
    root_template_failure_propagates: bool,
    caught: *std.ArrayListUnmanaged(AdmissionDiagnostic),
) !AdmissionQuoteScan {
    var suppressed_diagnostic = false;
    var failure: ?LegacyQuoteFailure = null;
    const end = try scanLegacyGenericQuotedCore(
        allocator,
        source,
        start,
        quote,
        root_template_failure_propagates,
        &suppressed_diagnostic,
        caught,
        &failure,
    );
    if (end) |complete| return .{ .complete = complete };
    return switch (failure orelse return error.InvalidAdmissionQuoteResult) {
        .nesting_too_deep => |offset| .{ .nesting_too_deep = offset },
        .unterminated_string => error.InvalidAdmissionQuoteResult,
    };
}

pub fn scanAdmissionTemplate(
    allocator: std.mem.Allocator,
    source: []const u8,
    opener: u32,
    caught: *std.ArrayListUnmanaged(AdmissionDiagnostic),
) !AdmissionTemplateScan {
    if (@as(usize, opener) >= source.len or source[opener] != '`') {
        return error.InvalidAdmissionSpan;
    }
    return switch (try scanAdmissionQuoted(
        allocator,
        source,
        opener,
        '`',
        true,
        caught,
    )) {
        .complete => |end| .{ .complete = @intCast(end) },
        .nesting_too_deep => |offset| .{ .nesting_too_deep = offset },
    };
}

pub const AdmissionEndpointProgress = struct {
    sink: AdmissionSink,
    policy: AdmissionTypePolicy,
    classification_start: u32,
};

pub fn scanAdmissionEndpointWithPresentation(
    allocator: std.mem.Allocator,
    source: []const u8,
    raw_start: u32,
    policy: AdmissionEndpointPolicy,
    caught: *std.ArrayListUnmanaged(AdmissionDiagnostic),
    progress: *AdmissionEndpointProgress,
) !AdmissionEndpointResult {
    if (progress.classification_start != raw_start or progress.sink.presentation == null) {
        return error.InvalidAdmissionPosition;
    }
    return scanAdmissionEndpointCore(allocator, source, raw_start, policy, caught, progress);
}

pub fn scanAdmissionEndpointCore(
    allocator: std.mem.Allocator,
    source: []const u8,
    raw_start: u32,
    policy: AdmissionEndpointPolicy,
    caught: *std.ArrayListUnmanaged(AdmissionDiagnostic),
    progress: ?*AdmissionEndpointProgress,
) !AdmissionEndpointResult {
    const caught_seed_count = caught.items.len;
    if (@as(usize, raw_start) > source.len) return error.InvalidAdmissionSpan;
    var pos: usize = raw_start;
    var paren_depth: u16 = 0;
    var bracket_depth: u16 = 0;
    var angle_depth: u16 = 0;
    var brace_depth: u16 = 0;

    while (pos < source.len) {
        const byte = source[pos];
        if (byte == '"' or byte == '\'' or byte == '`') {
            switch (try scanAdmissionQuoted(allocator, source, pos, byte, false, caught)) {
                .complete => |end| pos = end,
                .nesting_too_deep => |offset| return .{ .nesting_too_deep = offset },
            }
            continue;
        }
        if (byte == '/' and pos + 1 < source.len) {
            if (source[pos + 1] == '/') {
                pos += 2;
                while (pos < source.len and source[pos] != '\n') pos += 1;
                continue;
            }
            if (source[pos + 1] == '*') {
                const comment_start = pos;
                pos += 2;
                while (pos + 1 < source.len and !(source[pos] == '*' and source[pos + 1] == '/')) pos += 1;
                if (pos + 1 >= source.len) {
                    return .{ .unterminated_comment = .{
                        .opener = @intCast(comment_start),
                        .@"resume" = @intCast(pos),
                    } };
                }
                pos += 2;
                continue;
            }
        }

        const all_top = paren_depth == 0 and bracket_depth == 0 and
            angle_depth == 0 and brace_depth == 0;
        switch (policy) {
            .general => |general| {
                if (all_top and byte == '=' and pos + 1 < source.len and source[pos + 1] == '>' and
                    isFunctionTypePrefix(source[@as(usize, raw_start)..pos]))
                {
                    pos += 2;
                    const tracks_whitespace = switch (general) {
                        .variable, .named_return, .arrow_return => true,
                        .interface_extends, .assertion => false,
                    };
                    if (tracks_whitespace) if (progress) |current| {
                        try classifyTypeSpanPrefix(source, .{
                            .span = .{ .start = current.classification_start, .end = @intCast(pos) },
                            .policy = current.policy,
                            .caught_lexical = caught.items[caught_seed_count..],
                        }, current.sink);
                        caught.items.len = caught_seed_count;
                        if (current.sink.shouldStop()) return error.AdmissionRefused;
                        const context = try current.sink.presentation.?.trackedWhitespaceAt(@intCast(pos));
                        current.sink.presentation = context;
                        current.classification_start = context.offset;
                        pos = context.offset;
                    };
                    continue;
                }
                if (all_top) {
                    const stops = switch (general) {
                        .variable => byte == ',' or byte == ')' or byte == ';' or
                            byte == '=' or byte == '}',
                        .named_return => byte == ';' or byte == '=',
                        .arrow_return => byte == '=' and pos + 1 < source.len and
                            source[pos + 1] == '>',
                        .interface_extends => byte == ';',
                        .assertion => byte == ';' or byte == ',' or byte == ')' or
                            byte == ']' or byte == '}',
                    };
                    if (stops) return .{ .complete = .{ .start = raw_start, .end = @intCast(pos) } };
                    if (byte == '{') {
                        const object_context_start: u32 = if (general == .interface_extends) 0 else raw_start;
                        if (general != .assertion and
                            !isObjectTypeBraceStart(source, object_context_start, pos))
                        {
                            return .{ .complete = .{ .start = raw_start, .end = @intCast(pos) } };
                        }
                    }
                }
            },
            .parameter => {
                if (byte == ')' and paren_depth == 0) {
                    return .{ .complete = .{ .start = raw_start, .end = @intCast(pos) } };
                }
                if (byte == ',' and all_top) {
                    return .{ .complete = .{ .start = raw_start, .end = @intCast(pos) } };
                }
                if (byte == '=' and (pos + 1 >= source.len or source[pos + 1] != '>') and
                    paren_depth == 0 and angle_depth == 0)
                {
                    return .{ .complete = .{ .start = raw_start, .end = @intCast(pos) } };
                }
            },
            .declaration => {
                if (all_top and byte == ';') {
                    return .{ .complete = .{ .start = raw_start, .end = @intCast(pos) } };
                }
                if (all_top and byte == '\n' and !multilineTypeContinues(source, pos)) {
                    return .{ .complete = .{ .start = raw_start, .end = @intCast(pos) } };
                }
            },
        }

        switch (byte) {
            '(' => if (!increaseAdmissionDepth(&paren_depth, bracket_depth, angle_depth, brace_depth)) {
                return .{ .nesting_too_deep = @intCast(pos) };
            },
            '[' => if (!increaseAdmissionDepth(&bracket_depth, paren_depth, angle_depth, brace_depth)) {
                return .{ .nesting_too_deep = @intCast(pos) };
            },
            '<' => if (!increaseAdmissionDepth(&angle_depth, paren_depth, bracket_depth, brace_depth)) {
                return .{ .nesting_too_deep = @intCast(pos) };
            },
            '{' => if (!increaseAdmissionDepth(&brace_depth, paren_depth, bracket_depth, angle_depth)) {
                return .{ .nesting_too_deep = @intCast(pos) };
            },
            ')' => paren_depth -|= 1,
            ']' => bracket_depth -|= 1,
            '>' => angle_depth -|= 1,
            '}' => brace_depth -|= 1,
            else => {},
        }
        pos += 1;
    }
    return .{ .complete = .{ .start = raw_start, .end = @intCast(source.len) } };
}

fn multilineTypeContinues(source: []const u8, newline: usize) bool {
    var before = newline;
    while (before > 0 and isTypeWhitespace(source[before - 1])) before -= 1;
    if (before > 0) switch (source[before - 1]) {
        '|', '&', '=', '<', ',', '(', '[', ':', '?', '.' => return true,
        '>' => {
            var operator_before = before - 1;
            while (operator_before > 0 and isTypeWhitespace(source[operator_before - 1])) {
                operator_before -= 1;
            }
            if (operator_before > 0 and source[operator_before - 1] == '=') return true;
        },
        else => {},
    };
    var after = newline + 1;
    while (after < source.len and isTypeWhitespace(source[after])) after += 1;
    if (after >= source.len) return false;
    return switch (source[after]) {
        '|', '&', '?', ':', '>', ')', ']', '[', '.', '=', '<', ',' => true,
        else => false,
    };
}

const QuotedScan = union(enum) {
    end: usize,
    nesting_too_deep: u32,
    malformed: Span,
    implementation_budget: u32,
};

pub fn scanTypeQuoted(source: []const u8, start: usize, quote: u8) QuotedScan {
    if (quote != '`') return scanPlainTypeQuoted(source, start, quote);

    var interpolation_depths: [max_template_levels]u16 = @splat(0);
    var template_level: usize = 1;
    var pos = start + 1;
    while (pos < source.len) {
        if (source[pos] == '\\' and pos + 1 < source.len) {
            pos += 2;
            continue;
        }
        const level: usize = template_level - 1;
        if (interpolation_depths[level] == 0) {
            if (source[pos] == '`') {
                template_level -= 1;
                pos += 1;
                if (template_level == 0) return .{ .end = pos };
                continue;
            }
            if (source[pos] == '$' and pos + 1 < source.len and source[pos + 1] == '{') {
                interpolation_depths[level] = 1;
                pos += 2;
                continue;
            }
            pos += 1;
            continue;
        }

        if (source[pos] == '"' or source[pos] == '\'') {
            const nested = scanPlainTypeQuoted(source, pos, source[pos]);
            switch (nested) {
                .end => |end| pos = end,
                .nesting_too_deep => |offset| return .{ .nesting_too_deep = offset },
                .malformed => |span| return .{ .malformed = span },
                .implementation_budget => |offset| return .{ .implementation_budget = offset },
            }
            continue;
        }
        if (source[pos] == '`') {
            if (template_level == max_template_levels) {
                return .{ .implementation_budget = @intCast(pos) };
            }
            interpolation_depths[template_level] = 0;
            template_level += 1;
            pos += 1;
            continue;
        }
        if (source[pos] == '/' and pos + 1 < source.len and source[pos + 1] == '/') {
            pos += 2;
            while (pos < source.len and source[pos] != '\n') pos += 1;
            continue;
        }
        if (source[pos] == '/' and pos + 1 < source.len and source[pos + 1] == '*') {
            const comment_start = pos;
            pos += 2;
            while (pos + 1 < source.len and !(source[pos] == '*' and source[pos + 1] == '/')) pos += 1;
            if (pos + 1 >= source.len) {
                return .{ .malformed = .{ .start = @intCast(comment_start), .end = @intCast(source.len) } };
            }
            pos += 2;
            continue;
        }
        if (source[pos] == '{') {
            if (interpolation_depths[level] == max_type_depth) {
                return .{ .nesting_too_deep = @intCast(pos) };
            }
            interpolation_depths[level] += 1;
        } else if (source[pos] == '}') {
            interpolation_depths[level] -= 1;
        }
        pos += 1;
    }
    return .{ .malformed = .{ .start = @intCast(start), .end = @intCast(source.len) } };
}

fn scanPlainTypeQuoted(source: []const u8, start: usize, quote: u8) QuotedScan {
    var pos = start + 1;
    while (pos < source.len) {
        if (source[pos] == '\\' and pos + 1 < source.len) {
            pos += 2;
            continue;
        }
        if (source[pos] == quote) return .{ .end = pos + 1 };
        if (source[pos] == '\n') break;
        pos += 1;
    }
    return .{ .malformed = .{ .start = @intCast(start), .end = @intCast(pos) } };
}

fn increaseAdmissionDepth(
    depth: *u16,
    other_a: u16,
    other_b: u16,
    other_c: u16,
) bool {
    const total = @as(u32, depth.*) + other_a + other_b + other_c;
    if (total >= max_type_depth) return false;
    depth.* += 1;
    return true;
}

pub fn skipTypeWhitespace(source: []const u8, start: u32) u32 {
    var pos: usize = @min(@as(usize, start), source.len);
    while (pos < source.len and isTypeWhitespace(source[pos])) pos += 1;
    return @intCast(pos);
}

pub fn containsOnlyTypeWhitespace(source: []const u8, start: u32, end: u32) bool {
    const first = @min(@as(usize, start), source.len);
    const last = @min(@as(usize, end), source.len);
    if (first > last) return false;
    for (source[first..last]) |byte| if (!isTypeWhitespace(byte)) return false;
    return true;
}

pub fn looksLikeTypeStart(source: []const u8, start: u32) bool {
    if (@as(usize, start) >= source.len) return false;
    const byte = source[start];
    return isIdentifierStart(byte) or byte == '{' or byte == '(' or byte == '[' or
        byte == '<' or byte == '\'' or byte == '"' or byte == '`';
}

fn isObjectTypeBraceStart(source: []const u8, raw_start: u32, brace: usize) bool {
    var pos = brace;
    while (pos > raw_start and isTypeWhitespace(source[pos - 1])) pos -= 1;
    if (pos == raw_start) return true;
    const previous = source[pos - 1];
    switch (previous) {
        ':', '|', '&', '(', '[', '<', ',', '=' => return true,
        else => {},
    }
    if (!isIdentifierContinue(previous)) return false;
    var ident_start = pos - 1;
    while (ident_start > raw_start and isIdentifierContinue(source[ident_start - 1])) ident_start -= 1;
    return std.mem.eql(u8, source[ident_start..pos], "readonly");
}

fn isFunctionTypePrefix(raw: []const u8) bool {
    const text = std.mem.trim(u8, raw, " \t\r\n");
    if (text.len < 2 or text[0] != '(' or text[text.len - 1] != ')') return false;
    const params = std.mem.trim(u8, text[1 .. text.len - 1], " \t\r\n");
    if (params.len == 0) return true;

    var paren_depth: usize = 0;
    var bracket_depth: usize = 0;
    var brace_depth: usize = 0;
    var angle_depth: usize = 0;
    var pos: usize = 0;
    while (pos < params.len) : (pos += 1) {
        const at_top = paren_depth == 0 and bracket_depth == 0 and brace_depth == 0 and angle_depth == 0;
        switch (params[pos]) {
            '(' => paren_depth += 1,
            '[' => bracket_depth += 1,
            '{' => brace_depth += 1,
            '<' => angle_depth += 1,
            ')' => paren_depth -|= 1,
            ']' => bracket_depth -|= 1,
            '}' => brace_depth -|= 1,
            '>' => angle_depth -|= 1,
            ':', ',' => if (at_top) return true,
            '.' => if (at_top and pos + 2 < params.len and std.mem.eql(u8, params[pos..][0..3], "...")) return true,
            else => {},
        }
    }
    return false;
}

pub fn advanceCursorTo(cursor: *Cursor, offset: u32) void {
    while (cursor.current.type != .eof and cursor.current.start < offset) {
        const token_end = cursor.current.start + cursor.current.len;
        if (offset < token_end) {
            if (operatorSuffixToken(cursor.current, cursor.tokenizer.source, offset)) |suffix| {
                cursor.current = suffix;
                return;
            }
        }
        cursor.advance();
    }
}

fn operatorSuffixToken(token: Token, source: []const u8, offset: u32) ?Token {
    const token_end = token.start + token.len;
    if (offset <= token.start or offset >= token_end) return null;
    const suffix = source[offset..token_end];
    const token_type: token_mod.TokenType = if (std.mem.eql(u8, suffix, "="))
        .assign
    else if (std.mem.eql(u8, suffix, ">"))
        .gt
    else if (std.mem.eql(u8, suffix, ">="))
        .ge
    else if (std.mem.eql(u8, suffix, ">>"))
        .gt_gt
    else if (std.mem.eql(u8, suffix, ">>="))
        .gt_gt_assign
    else if (std.mem.eql(u8, suffix, ">>>"))
        .gt_gt_gt
    else if (std.mem.eql(u8, suffix, ">>>="))
        .gt_gt_gt_assign
    else
        return null;
    return .{
        .type = token_type,
        .start = offset,
        .len = token_end - offset,
        .line = token.line,
        .column = token.column + offset - token.start,
    };
}

pub fn tokenAtOffset(source: []const u8, offset: u32) Token {
    var cursor = Cursor.init(source);
    while (cursor.current.type != .eof and cursor.current.start < offset) cursor.advance();
    return cursor.current;
}

pub fn tokenSpan(token: Token) Span {
    return .{ .start = token.start, .end = token.start + token.len };
}

pub fn tokenIsDeclarationName(token: Token, source: []const u8) bool {
    const text = token.text(source);
    if (text.len == 0 or !isIdentifierStart(text[0])) return false;
    for (text[1..]) |byte| if (!isIdentifierContinue(byte)) return false;
    return true;
}

pub fn trimWhitespaceEnd(source: []const u8, start: u32, end: u32) u32 {
    var result = @min(@as(usize, end), source.len);
    const first = @min(@as(usize, start), result);
    while (result > first and isTypeWhitespace(source[result - 1])) result -= 1;
    return @intCast(result);
}

pub fn spanContainsOnlyTypeWhitespace(source: []const u8, span: Span) bool {
    if (span.start >= span.end or @as(usize, span.end) > source.len) return false;
    for (source[span.start..span.end]) |byte| {
        if (!isTypeWhitespace(byte)) return false;
    }
    return true;
}

pub fn isTypeWhitespace(byte: u8) bool {
    return byte == ' ' or byte == '\t' or byte == '\r' or byte == '\n';
}

pub fn classifyTypeSpan(
    source: []const u8,
    options: AdmissionTypeSpanOptions,
    sink: AdmissionSink,
) !void {
    if (options.removed_span) |span| {
        if (span.start > span.end or @as(usize, span.end) > source.len or
            span.start > options.span.start or span.end != options.span.end)
        {
            return error.InvalidAdmissionSpan;
        }
    }
    try classifyTypeSpanPrefix(source, options, sink);
    if (sink.shouldStop()) return;

    switch (options.policy) {
        .general_type, .parameter_type, .removed_only => try classifyFirstRemovedTypeInSpan(
            source,
            options.removed_span orelse options.span,
            sink.physicalPositions(),
        ),
        .any_only => {},
    }
}

pub fn classifyTypeSpanPrefix(
    source: []const u8,
    options: AdmissionTypeSpanOptions,
    sink: AdmissionSink,
) !void {
    const span = options.span;
    if (span.start > span.end or @as(usize, span.end) > source.len) {
        return error.InvalidAdmissionSpan;
    }
    try validateCaughtAdmissionDiagnostics(source, options);
    if (sink.shouldStop()) return;

    switch (options.policy) {
        .general_type, .any_only => try classifyAnyInTypeSpan(
            source,
            span,
            true,
            options.caught_lexical,
            sink,
        ),
        .parameter_type => try classifyAnyInTypeSpan(
            source,
            span,
            false,
            options.caught_lexical,
            sink,
        ),
        .removed_only => for (options.caught_lexical) |diagnostic| {
            try sink.recordCaught(diagnostic);
            if (sink.shouldStop()) return;
        },
    }
}

fn validateCaughtAdmissionDiagnostics(
    source: []const u8,
    options: AdmissionTypeSpanOptions,
) !void {
    var previous_offset: ?u32 = null;
    for (options.caught_lexical) |diagnostic| {
        switch (diagnostic.kind) {
            .unterminated_string, .nesting_too_deep => {},
            else => return error.InvalidCaughtAdmissionDiagnostic,
        }
        if (diagnostic.span.start > diagnostic.span.end or
            @as(usize, diagnostic.span.end) > source.len)
        {
            return error.InvalidCaughtAdmissionDiagnostic;
        }
        const inside = diagnostic.span.start >= options.span.start and
            diagnostic.span.start < options.span.end and
            diagnostic.span.end <= options.span.end;
        const exact_end = diagnostic.span.start == options.span.end and
            @as(usize, options.span.end) < source.len and
            diagnostic.span.end == (std.math.add(u32, options.span.end, 1) catch 0) and
            switch (diagnostic.kind) {
                .unterminated_string => source[options.span.end] == '\n',
                .nesting_too_deep => source[options.span.end] == '{',
                else => false,
            };
        if (!inside and !exact_end) return error.InvalidCaughtAdmissionDiagnostic;
        if (previous_offset) |previous| {
            if (diagnostic.span.start < previous) {
                return error.InvalidCaughtAdmissionDiagnostic;
            }
        }
        previous_offset = diagnostic.span.start;
    }
}

fn classifyAnyInTypeSpan(
    source: []const u8,
    span: Span,
    exclude_object_keys: bool,
    caught_lexical: []const AdmissionDiagnostic,
    sink: AdmissionSink,
) !void {
    const end: usize = span.end;
    var pos: usize = span.start;
    var brace_depth: usize = 0;
    var caught_index: usize = 0;
    while (pos < end) {
        try emitCaughtAdmissionThrough(
            caught_lexical,
            &caught_index,
            @intCast(pos),
            sink,
        );
        if (sink.shouldStop()) return;
        const byte = source[pos];
        if (byte == '\'' or byte == '"' or byte == '`') {
            pos = try skipAdmissionAnyQuoted(
                sink.collector.allocator,
                source,
                pos,
                end,
                byte,
            );
            continue;
        }
        if (byte == '/' and pos + 1 < end) {
            if (source[pos + 1] == '/') {
                pos += 2;
                while (pos < end and source[pos] != '\n') pos += 1;
                continue;
            }
            if (source[pos + 1] == '*') {
                pos += 2;
                while (pos + 1 < end and !(source[pos] == '*' and source[pos + 1] == '/')) {
                    pos += 1;
                }
                pos = if (pos + 1 < end) pos + 2 else end;
                continue;
            }
        }
        if (byte == '{') {
            brace_depth += 1;
            pos += 1;
            continue;
        }
        if (byte == '}') {
            brace_depth -|= 1;
            pos += 1;
            continue;
        }
        if (pos + "any".len > end or
            !std.mem.eql(u8, source[pos .. pos + "any".len], "any") or
            (pos + "any".len < end and isIdentifierContinue(source[pos + "any".len])))
        {
            pos += 1;
            continue;
        }
        const identifier_start = pos;
        pos += "any".len;
        if (exclude_object_keys and brace_depth > 0 and
            isAdmissionObjectMemberKey(source, pos, end))
        {
            continue;
        }
        try sink.recordRecoverable(.{
            .kind = .any_type,
            .span = .{ .start = @intCast(identifier_start), .end = @intCast(pos) },
        });
        if (sink.shouldStop()) return;
    }
    try emitCaughtAdmissionThrough(
        caught_lexical,
        &caught_index,
        span.end,
        sink,
    );
}

fn emitCaughtAdmissionThrough(
    caught_lexical: []const AdmissionDiagnostic,
    index: *usize,
    offset: u32,
    sink: AdmissionSink,
) !void {
    while (index.* < caught_lexical.len and caught_lexical[index.*].span.start <= offset) {
        try sink.recordCaught(caught_lexical[index.*]);
        index.* += 1;
        if (sink.shouldStop()) return;
    }
}

fn classifyFirstRemovedTypeInSpan(
    source: []const u8,
    span: Span,
    sink: AdmissionSink,
) !void {
    const end: usize = span.end;
    var pos: usize = span.start;
    var paren_depth: usize = 0;
    var brace_depth: usize = 0;
    while (pos < end) {
        const byte = source[pos];
        if (byte == '\'' or byte == '"' or byte == '`') {
            pos = skipAdmissionRemovedQuoted(source, pos, end, byte);
            continue;
        }
        if (byte == '/' and pos + 1 < end) {
            if (source[pos + 1] == '/') {
                pos += 2;
                while (pos < end and source[pos] != '\n') pos += 1;
                continue;
            }
            if (source[pos + 1] == '*') {
                pos += 2;
                while (pos + 1 < end and !(source[pos] == '*' and source[pos + 1] == '/')) {
                    pos += 1;
                }
                pos = if (pos + 1 < end) pos + 2 else end;
                continue;
            }
        }
        switch (byte) {
            '(' => {
                paren_depth += 1;
                pos += 1;
                continue;
            },
            ')' => {
                paren_depth -|= 1;
                pos += 1;
                continue;
            },
            '{' => {
                brace_depth += 1;
                pos += 1;
                continue;
            },
            '}' => {
                brace_depth -|= 1;
                pos += 1;
                continue;
            },
            '?' => {
                if (paren_depth > 0 and brace_depth == 0 and
                    isAdmissionOptionalParameter(source, span.start, pos, end))
                {
                    try sink.recordRecoverable(.{
                        .kind = .optional_parameter,
                        .span = .{ .start = @intCast(pos), .end = @intCast(pos + 1) },
                    });
                    return;
                }
                pos += 1;
                continue;
            },
            else => {},
        }
        if (!isIdentifierStart(byte)) {
            pos += 1;
            continue;
        }

        const identifier_start = pos;
        pos += 1;
        while (pos < end and isIdentifierContinue(source[pos])) pos += 1;
        const identifier = source[identifier_start..pos];
        var kind: ?AdmissionKind = null;
        if (std.mem.eql(u8, identifier, "void")) {
            kind = .void_type;
        } else if (std.mem.eql(u8, identifier, "Array") or
            std.mem.eql(u8, identifier, "ReadonlyArray"))
        {
            const after = skipAdmissionTypeTrivia(source, pos, end);
            if (after < end and source[after] == '<') {
                kind = if (identifier.len == "Array".len)
                    .array_type_alias
                else
                    .readonly_array_type_alias;
            }
        }
        if (kind) |diagnostic_kind| {
            try sink.recordRecoverable(.{
                .kind = diagnostic_kind,
                .span = .{ .start = @intCast(identifier_start), .end = @intCast(pos) },
            });
            return;
        }
    }
}

fn isAdmissionOptionalParameter(
    source: []const u8,
    span_start: u32,
    question: usize,
    end: usize,
) bool {
    var before = question;
    while (before > span_start and std.ascii.isWhitespace(source[before - 1])) before -= 1;
    if (before == span_start or !isIdentifierContinue(source[before - 1])) return false;
    var after = question + 1;
    while (after < end and std.ascii.isWhitespace(source[after])) after += 1;
    return after < end and source[after] == ':';
}

fn skipAdmissionAnyQuoted(
    allocator: std.mem.Allocator,
    source: []const u8,
    start: usize,
    end: usize,
    quote: u8,
) !usize {
    const bounded = source[0..end];
    if (quote != '`') return scanLegacyPlainQuoted(bounded, start, quote).end;
    var suppressed_diagnostic = false;
    return (try scanLegacyGenericQuoted(
        allocator,
        bounded,
        start,
        quote,
        false,
        &suppressed_diagnostic,
    )) orelse end;
}

fn skipAdmissionRemovedQuoted(source: []const u8, start: usize, end: usize, quote: u8) usize {
    var pos = start + 1;
    while (pos < end) {
        if (source[pos] == '\\' and pos + 1 < end) {
            pos += 2;
            continue;
        }
        if (source[pos] == quote) return pos + 1;
        pos += 1;
    }
    return end;
}

fn skipAdmissionTypeTrivia(source: []const u8, start: usize, end: usize) usize {
    var pos = start;
    while (pos < end) {
        if (std.ascii.isWhitespace(source[pos])) {
            pos += 1;
            continue;
        }
        if (source[pos] == '/' and pos + 1 < end and source[pos + 1] == '/') {
            pos += 2;
            while (pos < end and source[pos] != '\n') pos += 1;
            continue;
        }
        if (source[pos] == '/' and pos + 1 < end and source[pos + 1] == '*') {
            pos += 2;
            while (pos + 1 < end and !(source[pos] == '*' and source[pos + 1] == '/')) {
                pos += 1;
            }
            pos = if (pos + 1 < end) pos + 2 else end;
            continue;
        }
        break;
    }
    return pos;
}

fn isAdmissionObjectMemberKey(source: []const u8, identifier_end: usize, end: usize) bool {
    var pos = identifier_end;
    while (pos < end and (source[pos] == ' ' or source[pos] == '\t')) pos += 1;
    if (pos < end and source[pos] == '?') {
        pos += 1;
        while (pos < end and (source[pos] == ' ' or source[pos] == '\t')) pos += 1;
    }
    return pos < end and (source[pos] == ':' or source[pos] == '(');
}

pub fn isScalarNominalBase(text: []const u8) bool {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    return std.mem.eql(u8, trimmed, "string") or
        std.mem.eql(u8, trimmed, "number") or
        std.mem.eql(u8, trimmed, "boolean");
}

test "explicit call scanner keeps legacy operator and touching filters" {
    const refused = [_][]const u8{
        "id<T && U>(value)",
        "id<T || U>(value)",
        "id<T ? U>(value)",
        "id<T : U>(value)",
        "id<T = U>(value)",
        "id<T> (value)",
    };
    for (refused) |source| {
        switch (try scanExplicitCallTypeArguments(
            std.testing.allocator,
            source,
            2,
        )) {
            .not_call => {},
            .excluded, .scanned => return error.TestUnexpectedResult,
        }
    }

    const accepted = "id<(value: string) => number>(value)";
    const scanned = switch (try scanExplicitCallTypeArguments(
        std.testing.allocator,
        accepted,
        2,
    )) {
        .scanned => |value| value,
        .not_call, .excluded => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqualStrings(
        "<(value: string) => number>",
        scanned.span.text(accepted),
    );
}

test "admission generic scanner separates lexical nonmatches from shape nonmatches" {
    const quoted_source = "function f<\"open\n>(x: number): number { return x; }\n";
    const list_start: u32 = @intCast(std.mem.indexOfScalar(u8, quoted_source, '<').?);
    var caught: std.ArrayListUnmanaged(AdmissionDiagnostic) = .empty;
    defer caught.deinit(std.testing.allocator);

    switch (try scanAdmissionGenericList(std.testing.allocator, .{
        .source = quoted_source,
        .start = list_start,
        .caught = &caught,
    })) {
        .lexical_nonmatch => {},
        .not_matched, .scanned, .nesting_too_deep => return error.TestUnexpectedResult,
    }
    try std.testing.expectEqual(@as(usize, 1), caught.items.len);
    try std.testing.expectEqual(AdmissionKind.unterminated_string, caught.items[0].kind);
    try std.testing.expectEqual(Span{ .start = 16, .end = 17 }, caught.items[0].span);
    try std.testing.expect((try scanBalancedGenericList(
        std.testing.allocator,
        quoted_source,
        list_start,
    )) == null);

    caught.clearRetainingCapacity();
    const comment_source = "function f<T /* unfinished\n";
    switch (try scanAdmissionGenericList(std.testing.allocator, .{
        .source = comment_source,
        .start = @intCast(std.mem.indexOfScalar(u8, comment_source, '<').?),
        .caught = &caught,
    })) {
        .lexical_nonmatch => {},
        .not_matched, .scanned, .nesting_too_deep => return error.TestUnexpectedResult,
    }
    try std.testing.expectEqual(@as(usize, 0), caught.items.len);

    switch (try scanAdmissionGenericList(std.testing.allocator, .{
        .source = "value",
        .start = 5,
        .caught = &caught,
    })) {
        .not_matched => {},
        .lexical_nonmatch, .scanned, .nesting_too_deep => return error.TestUnexpectedResult,
    }
    try std.testing.expectError(
        error.InvalidAdmissionSpan,
        scanAdmissionGenericList(std.testing.allocator, .{
            .source = "value",
            .start = 6,
            .caught = &caught,
        }),
    );
    try std.testing.expect((try scanBalancedGenericList(
        std.testing.allocator,
        "value",
        6,
    )) == null);
    try std.testing.expectError(
        error.InvalidAdmissionSpan,
        scanAdmissionCallTypeArguments(std.testing.allocator, .{
            .source = "value",
            .start = 6,
            .caught = &caught,
        }),
    );
    switch (try scanExplicitCallTypeArguments(std.testing.allocator, "value", 6)) {
        .not_call => {},
        .excluded, .scanned => return error.TestUnexpectedResult,
    }
}

test "admission raw scanners restore caught rows on allocation failure" {
    const Scanner = enum { balanced, call, brace };
    const Case = struct {
        scanner: Scanner,
        source: []const u8,
    };
    const cases = [_]Case{
        .{
            .scanner = .balanced,
            .source = "<`a${\"open\n 1}tail`, `second${value}`>",
        },
        .{
            .scanner = .call,
            .source = "<`a${\"open\n 1}tail`, `second${value}`>(value)",
        },
        .{
            .scanner = .brace,
            .source = "{ `a${\"open\n 1}tail`, `second${value}` }",
        },
    };
    const Context = struct {
        fn run(
            allocator: std.mem.Allocator,
            case: Case,
            observed_failures: *usize,
        ) !void {
            var caught: std.ArrayListUnmanaged(AdmissionDiagnostic) = .empty;
            defer caught.deinit(std.testing.allocator);
            try caught.ensureTotalCapacity(std.testing.allocator, 4);
            const seed: AdmissionDiagnostic = .{
                .kind = .nesting_too_deep,
                .span = .{ .start = 0, .end = 1 },
            };
            caught.appendAssumeCapacity(seed);
            const entry_len = caught.items.len;

            switch (case.scanner) {
                .balanced => switch (scanAdmissionGenericList(allocator, .{
                    .source = case.source,
                    .start = 0,
                    .caught = &caught,
                }) catch |err| return observeRawScanFailure(
                    err,
                    observed_failures,
                    entry_len,
                    seed,
                    &caught,
                )) {
                    .scanned => {},
                    .not_matched, .lexical_nonmatch, .nesting_too_deep => {
                        return error.TestUnexpectedResult;
                    },
                },
                .call => switch (scanAdmissionCallTypeArguments(allocator, .{
                    .source = case.source,
                    .start = 0,
                    .caught = &caught,
                }) catch |err| return observeRawScanFailure(
                    err,
                    observed_failures,
                    entry_len,
                    seed,
                    &caught,
                )) {
                    .scanned => {},
                    .not_matched, .lexical_nonmatch, .nesting_too_deep => {
                        return error.TestUnexpectedResult;
                    },
                },
                .brace => switch (scanAdmissionBraceBody(allocator, .{
                    .source = case.source,
                    .start = 0,
                    .caught = &caught,
                }) catch |err| return observeRawScanFailure(
                    err,
                    observed_failures,
                    entry_len,
                    seed,
                    &caught,
                )) {
                    .complete => {},
                    .nesting_too_deep => return error.TestUnexpectedResult,
                },
            }
            try std.testing.expectEqual(entry_len + 1, caught.items.len);
            try std.testing.expectEqual(
                AdmissionKind.unterminated_string,
                caught.items[entry_len].kind,
            );
        }

        fn observeRawScanFailure(
            err: anyerror,
            observed_failures: *usize,
            entry_len: usize,
            seed: AdmissionDiagnostic,
            caught: *const std.ArrayListUnmanaged(AdmissionDiagnostic),
        ) !void {
            switch (err) {
                error.OutOfMemory => observed_failures.* += 1,
                else => return err,
            }
            try std.testing.expectEqual(entry_len, caught.items.len);
            try std.testing.expectEqualDeep(seed, caught.items[0]);
            return error.OutOfMemory;
        }
    };
    var observed_failures = @as([cases.len]usize, @splat(0));
    for (cases, 0..) |case, index| {
        try std.testing.checkAllAllocationFailures(
            std.testing.allocator,
            Context.run,
            .{ case, &observed_failures[index] },
        );
        try std.testing.expect(observed_failures[index] > 0);
    }
}

test "admission sink retains merged emission order and collector encounters" {
    const source = "any void \"open\n";
    const caught: AdmissionDiagnostic = .{
        .kind = .unterminated_string,
        .span = .{ .start = 14, .end = 15 },
    };
    var collector = AdmissionCollector.init(std.testing.allocator, .collect);
    defer collector.deinit();
    var history = AdmissionObservationHistory.init(std.testing.allocator);
    defer history.deinit();
    const sink = AdmissionSink.init(&collector, &history);

    try classifyTypeSpan(source, .{
        .span = .{ .start = 0, .end = @intCast(source.len) },
        .policy = .general_type,
        .caught_lexical = &.{caught},
    }, sink);

    const expected = [_]AdmissionDiagnostic{
        .{ .kind = .any_type, .span = .{ .start = 0, .end = 3 } },
        caught,
        .{ .kind = .void_type, .span = .{ .start = 4, .end = 8 } },
    };
    try std.testing.expectEqual(expected.len, history.items().len);
    try std.testing.expectEqual(expected.len, collector.items().len);
    for (expected, history.items(), collector.items()) |expected_diagnostic, observed, selected| {
        try std.testing.expectEqual(expected_diagnostic.kind, observed.kind);
        try std.testing.expectEqual(expected_diagnostic.span, observed.span);
        try std.testing.expectEqual(expected_diagnostic.kind, selected.kind);
        try std.testing.expectEqual(expected_diagnostic.span, selected.span);
    }

    try sink.recordRecoverable(.{
        .kind = .array_type_alias,
        .span = .{ .start = 4, .end = 9 },
    });
    try std.testing.expectEqual(@as(usize, 3), history.items().len);
    try std.testing.expectEqual(@as(u64, 4), collector.generation());
    try std.testing.expectEqual(@as(usize, 3), collector.items().len);
}

test "compile caught observations preserve later hard selection" {
    const any_source = "\"open\nany void";
    var any_collector = AdmissionCollector.init(std.testing.allocator, .compile);
    defer any_collector.deinit();
    var any_history = AdmissionObservationHistory.init(std.testing.allocator);
    defer any_history.deinit();
    try classifyTypeSpan(any_source, .{
        .span = .{ .start = 0, .end = @intCast(any_source.len) },
        .policy = .general_type,
        .caught_lexical = &.{.{
            .kind = .unterminated_string,
            .span = .{ .start = 5, .end = 6 },
        }},
    }, AdmissionSink.init(&any_collector, &any_history));
    try std.testing.expectEqual(@as(u64, 1), any_collector.generation());
    try std.testing.expectEqual(@as(usize, 1), any_collector.items().len);
    try std.testing.expectEqual(AdmissionKind.any_type, any_collector.items()[0].kind);
    try std.testing.expectEqual(@as(usize, 2), any_history.items().len);
    try std.testing.expectEqual(AdmissionKind.unterminated_string, any_history.items()[0].kind);
    try std.testing.expectEqual(AdmissionKind.any_type, any_history.items()[1].kind);

    const removed_source = "void \"open\n";
    var removed_collector = AdmissionCollector.init(std.testing.allocator, .compile);
    defer removed_collector.deinit();
    var removed_history = AdmissionObservationHistory.init(std.testing.allocator);
    defer removed_history.deinit();
    try classifyTypeSpan(removed_source, .{
        .span = .{ .start = 0, .end = @intCast(removed_source.len) },
        .policy = .removed_only,
        .caught_lexical = &.{.{
            .kind = .unterminated_string,
            .span = .{ .start = 10, .end = 11 },
        }},
    }, AdmissionSink.init(&removed_collector, &removed_history));
    try std.testing.expectEqual(@as(u64, 1), removed_collector.generation());
    try std.testing.expectEqual(@as(usize, 1), removed_collector.items().len);
    try std.testing.expectEqual(AdmissionKind.void_type, removed_collector.items()[0].kind);
    try std.testing.expectEqual(@as(usize, 2), removed_history.items().len);
    try std.testing.expectEqual(AdmissionKind.unterminated_string, removed_history.items()[0].kind);
    try std.testing.expectEqual(AdmissionKind.void_type, removed_history.items()[1].kind);
}

fn expectTypeSpanDiagnostics(
    source: []const u8,
    options: AdmissionTypeSpanOptions,
    expected: []const AdmissionDiagnostic,
) !void {
    var collector = AdmissionCollector.init(std.testing.allocator, .collect);
    defer collector.deinit();
    try classifyTypeSpan(source, options, AdmissionSink.init(&collector, null));
    try std.testing.expectEqual(expected.len, collector.items().len);
    for (expected, collector.items()) |expected_diagnostic, actual| {
        try std.testing.expectEqual(expected_diagnostic.kind, actual.kind);
        try std.testing.expectEqual(expected_diagnostic.span, actual.span);
    }
}

test "bounded admission policies preserve legacy any and removed spelling order" {
    const source = "{ any: string; value: many; alias: Array<string>; later: Many }";
    const span: Span = .{ .start = 0, .end = @intCast(source.len) };

    const Case = struct {
        policy: AdmissionTypePolicy,
        expected: []const AdmissionDiagnostic,
    };
    const cases = [_]Case{
        .{
            .policy = .general_type,
            .expected = &.{
                .{ .kind = .any_type, .span = .{ .start = 23, .end = 26 } },
                .{ .kind = .any_type, .span = .{ .start = 58, .end = 61 } },
                .{ .kind = .array_type_alias, .span = .{ .start = 35, .end = 40 } },
            },
        },
        .{
            .policy = .parameter_type,
            .expected = &.{
                .{ .kind = .any_type, .span = .{ .start = 2, .end = 5 } },
                .{ .kind = .any_type, .span = .{ .start = 23, .end = 26 } },
                .{ .kind = .any_type, .span = .{ .start = 58, .end = 61 } },
                .{ .kind = .array_type_alias, .span = .{ .start = 35, .end = 40 } },
            },
        },
        .{
            .policy = .any_only,
            .expected = &.{
                .{ .kind = .any_type, .span = .{ .start = 23, .end = 26 } },
                .{ .kind = .any_type, .span = .{ .start = 58, .end = 61 } },
            },
        },
        .{
            .policy = .removed_only,
            .expected = &.{.{
                .kind = .array_type_alias,
                .span = .{ .start = 35, .end = 40 },
            }},
        },
    };
    for (cases) |case| {
        try expectTypeSpanDiagnostics(source, .{
            .span = span,
            .policy = case.policy,
        }, case.expected);
    }

    var compiled = AdmissionCollector.init(std.testing.allocator, .compile);
    defer compiled.deinit();
    try classifyTypeSpan(source, .{
        .span = span,
        .policy = .general_type,
    }, AdmissionSink.init(&compiled, null));
    try std.testing.expectEqual(@as(usize, 1), compiled.items().len);
    try std.testing.expectEqual(AdmissionKind.any_type, compiled.items()[0].kind);
    try std.testing.expectEqual(@as(u32, 23), compiled.items()[0].span.start);

    const prefix_source = "any void";
    var prefix_collector = AdmissionCollector.init(std.testing.allocator, .collect);
    defer prefix_collector.deinit();
    try classifyTypeSpanPrefix(prefix_source, .{
        .span = .{ .start = 0, .end = @intCast(prefix_source.len) },
        .policy = .general_type,
    }, AdmissionSink.init(&prefix_collector, null));
    try std.testing.expectEqual(@as(usize, 1), prefix_collector.items().len);
    try std.testing.expectEqual(AdmissionKind.any_type, prefix_collector.items()[0].kind);

    const suffix_source = "const value: number many = 1;";
    try expectTypeSpanDiagnostics(
        suffix_source,
        .{ .span = .{ .start = 13, .end = 24 }, .policy = .general_type },
        &.{.{ .kind = .any_type, .span = .{ .start = 21, .end = 24 } }},
    );

    const nominal_body = "void | many";
    try expectTypeSpanDiagnostics(
        nominal_body,
        .{
            .span = .{ .start = 0, .end = @intCast(nominal_body.len) },
            .policy = .any_only,
        },
        &.{.{ .kind = .any_type, .span = .{ .start = 8, .end = 11 } }},
    );

    const optional_function = "(value?: string) => number";
    try expectTypeSpanDiagnostics(optional_function, .{
        .span = .{ .start = 0, .end = @intCast(optional_function.len) },
        .policy = .removed_only,
    }, &.{.{ .kind = .optional_parameter, .span = .{ .start = 6, .end = 7 } }});

    const optional_record = "{ value?: string }";
    try expectTypeSpanDiagnostics(optional_record, .{
        .span = .{ .start = 0, .end = @intCast(optional_record.len) },
        .policy = .removed_only,
    }, &.{});

    const control_whitespace = [_][]const u8{
        "Array\x0b<number>",
        "ReadonlyArray\x0c<number>",
    };
    const control_kinds = [_]AdmissionKind{ .array_type_alias, .readonly_array_type_alias };
    for (control_whitespace, control_kinds) |control, expected_kind| {
        const name_end: u32 = if (expected_kind == .array_type_alias) 5 else 13;
        try expectTypeSpanDiagnostics(control, .{
            .span = .{ .start = 0, .end = @intCast(control.len) },
            .policy = .removed_only,
        }, &.{.{ .kind = expected_kind, .span = .{ .start = 0, .end = name_end } }});
    }
}

test "bounded admission classifier keeps strings comments and templates opaque" {
    const source = "\"any\" | `Array<void>` | /* any */ ReadonlyArray<string>";
    try expectTypeSpanDiagnostics(source, .{
        .span = .{ .start = 0, .end = @intCast(source.len) },
        .policy = .general_type,
    }, &.{.{
        .kind = .readonly_array_type_alias,
        .span = .{ .start = 34, .end = 47 },
    }});

    const line_comment_source = "// any Array<void>\nvoid";
    try expectTypeSpanDiagnostics(line_comment_source, .{
        .span = .{ .start = 0, .end = @intCast(line_comment_source.len) },
        .policy = .general_type,
    }, &.{.{ .kind = .void_type, .span = .{ .start = 19, .end = 23 } }});

    const malformed_before = "any \"open\n void";
    try expectTypeSpanDiagnostics(malformed_before, .{
        .span = .{ .start = 0, .end = @intCast(malformed_before.len) },
        .policy = .general_type,
        .caught_lexical = &.{.{
            .kind = .unterminated_string,
            .span = .{ .start = 9, .end = 10 },
        }},
    }, &.{
        .{ .kind = .any_type, .span = .{ .start = 0, .end = 3 } },
        .{ .kind = .unterminated_string, .span = .{ .start = 9, .end = 10 } },
    });

    const malformed_after = "\"open\nany void";
    try expectTypeSpanDiagnostics(malformed_after, .{
        .span = .{ .start = 0, .end = @intCast(malformed_after.len) },
        .policy = .general_type,
        .caught_lexical = &.{.{
            .kind = .unterminated_string,
            .span = .{ .start = 5, .end = 6 },
        }},
    }, &.{
        .{ .kind = .unterminated_string, .span = .{ .start = 5, .end = 6 } },
        .{ .kind = .any_type, .span = .{ .start = 6, .end = 9 } },
    });
    var malformed_compile = AdmissionCollector.init(std.testing.allocator, .compile);
    defer malformed_compile.deinit();
    try classifyTypeSpan(malformed_after, .{
        .span = .{ .start = 0, .end = @intCast(malformed_after.len) },
        .policy = .general_type,
        .caught_lexical = &.{.{
            .kind = .unterminated_string,
            .span = .{ .start = 5, .end = 6 },
        }},
    }, AdmissionSink.init(&malformed_compile, null));
    try std.testing.expectEqual(@as(u64, 1), malformed_compile.generation());
    try std.testing.expectEqual(@as(usize, 1), malformed_compile.items().len);
    try std.testing.expectEqual(AdmissionKind.any_type, malformed_compile.items()[0].kind);
    try std.testing.expectEqual(Span{ .start = 6, .end = 9 }, malformed_compile.items()[0].span);

    const removed_after = "void \"open\n";
    const removed_options: AdmissionTypeSpanOptions = .{
        .span = .{ .start = 0, .end = @intCast(removed_after.len) },
        .policy = .removed_only,
        .caught_lexical = &.{.{
            .kind = .unterminated_string,
            .span = .{ .start = 10, .end = 11 },
        }},
    };
    try expectTypeSpanDiagnostics(removed_after, removed_options, &.{
        .{ .kind = .unterminated_string, .span = .{ .start = 10, .end = 11 } },
        .{ .kind = .void_type, .span = .{ .start = 0, .end = 4 } },
    });
    var removed_compile = AdmissionCollector.init(std.testing.allocator, .compile);
    defer removed_compile.deinit();
    try classifyTypeSpan(
        removed_after,
        removed_options,
        AdmissionSink.init(&removed_compile, null),
    );
    try std.testing.expectEqual(@as(u64, 1), removed_compile.generation());
    try std.testing.expectEqual(@as(usize, 1), removed_compile.items().len);
    try std.testing.expectEqual(AdmissionKind.void_type, removed_compile.items()[0].kind);
    try std.testing.expectEqual(Span{ .start = 0, .end = 4 }, removed_compile.items()[0].span);

    var invalid_collector = AdmissionCollector.init(std.testing.allocator, .collect);
    defer invalid_collector.deinit();
    try std.testing.expectError(
        error.InvalidAdmissionSpan,
        classifyTypeSpan(
            source,
            .{
                .span = .{ .start = 0, .end = @intCast(source.len + 1) },
                .policy = .general_type,
            },
            AdmissionSink.init(&invalid_collector, null),
        ),
    );
}

test "type-only module refusal retains its computed raw span" {
    const source = "import type { Spec } from \"" ++ retired_types_module ++ "\";\nconst live = 1;";
    var diagnostics: std.ArrayListUnmanaged(TypeOnlyModuleDiagnostic) = .empty;
    defer diagnostics.deinit(std.testing.allocator);
    const refusal = switch (try scanTypeOnlyModule(std.testing.allocator, .{
        .source = source,
        .keyword = Cursor.init(source).current,
        .diagnostics = &diagnostics,
    })) {
        .refused => |refusal| refusal,
        .not_type_only, .excluded, .scanned => return error.TestExpectedTypeOnlyModule,
    };
    try std.testing.expectEqual(TypeOnlyModuleRefusalReason.zttp_types, refusal.reason);
    try std.testing.expectEqual(@as(u32, 0), refusal.original_location.offset);
    try std.testing.expectEqual(Span{ .start = 0, .end = 39 }, refusal.raw_span);
    try std.testing.expectEqual(@as(usize, 0), diagnostics.items.len);
}

test "type-only module records require the exact raw scanner result" {
    const source = "import type { A } from \"./a\";\nconst live = 1;";
    const cursor = Cursor.init(source);
    var diagnostics: std.ArrayListUnmanaged(TypeOnlyModuleDiagnostic) = .empty;
    defer diagnostics.deinit(std.testing.allocator);
    const module = switch (try scanTypeOnlyModule(std.testing.allocator, .{
        .source = source,
        .keyword = cursor.current,
        .diagnostics = &diagnostics,
    })) {
        .scanned => |module| module,
        .not_type_only, .refused, .excluded => return error.TestExpectedTypeOnlyModule,
    };
    try std.testing.expectEqual(@as(usize, 0), diagnostics.items.len);
    const semicolon = std.mem.indexOfScalar(u8, source, ';') orelse
        return error.TestExpectedTypeOnlyModule;
    try std.testing.expectEqual(TypeOnlyModuleKind.import_type, module.kind);
    try std.testing.expectEqual(
        Span{ .start = 0, .end = @intCast(semicolon + 1) },
        module.raw_span,
    );

    var forged_store = Store.init(std.testing.allocator, source);
    defer forged_store.deinit();
    var missing_semicolon = module;
    missing_semicolon.raw_span.end -= 1;
    try std.testing.expectError(
        error.InvalidTypeOnlyModule,
        forged_store.appendTypeOnlyModule(missing_semicolon),
    );
    var wrong_kind = module;
    wrong_kind.kind = .export_type;
    try std.testing.expectError(
        error.InvalidTypeOnlyModule,
        forged_store.appendTypeOnlyModule(wrong_kind),
    );
    try std.testing.expectEqual(@as(usize, 0), forged_store.type_only_modules.items.len);

    var store = Store.init(std.testing.allocator, source);
    defer store.deinit();
    try store.appendTypeOnlyModule(module);
    try store.validate();
    try std.testing.expectEqual(@as(usize, 1), store.type_only_modules.items.len);
    try std.testing.expectError(error.InvalidTypeSourceOrder, store.appendTypeOnlyModule(module));
    try std.testing.expectEqual(@as(usize, 1), store.type_only_modules.items.len);

    store.type_only_modules.items[0].kind = .export_type;
    try std.testing.expectError(error.InvalidTypeOnlyModule, store.validate());
    store.type_only_modules.items[0] = module;
    store.type_only_modules.items[0].raw_span.end -= 1;
    try std.testing.expectError(error.InvalidTypeOnlyModule, store.validate());
}

test "recovered type-only module validates its exact diagnostic-bearing record" {
    const source = "import type \"open\nconst live = 1;";
    var diagnostics: std.ArrayListUnmanaged(TypeOnlyModuleDiagnostic) = .empty;
    defer diagnostics.deinit(std.testing.allocator);
    const module = switch (try scanTypeOnlyModule(std.testing.allocator, .{
        .source = source,
        .keyword = Cursor.init(source).current,
        .diagnostics = &diagnostics,
    })) {
        .excluded => |excluded| excluded,
        .not_type_only, .refused, .scanned => return error.TestExpectedTypeOnlyModule,
    };
    const newline: u32 = @intCast(std.mem.indexOfScalar(u8, source, '\n').?);
    try std.testing.expectEqual(
        TypeOnlyModule{ .kind = .import_type, .raw_span = .{ .start = 0, .end = newline } },
        module,
    );
    try std.testing.expectEqual(@as(usize, 1), diagnostics.items.len);
    try std.testing.expectEqual(TypeOnlyModuleDiagnosticKind.unterminated_string, diagnostics.items[0].kind);

    var store = Store.init(std.testing.allocator, source);
    defer store.deinit();
    try store.appendTypeOnlyModule(module);
    try store.validate();
    try std.testing.expectEqual(@as(usize, 1), store.type_only_modules.items.len);
    try std.testing.expectEqual(module, store.type_only_modules.items[0]);

    var forged_store = Store.init(std.testing.allocator, source);
    defer forged_store.deinit();
    var wrong_kind = module;
    wrong_kind.kind = .export_type;
    try std.testing.expectError(
        error.InvalidTypeOnlyModule,
        forged_store.appendTypeOnlyModule(wrong_kind),
    );
    var changed_endpoint = module;
    changed_endpoint.raw_span.end -= 1;
    try std.testing.expectError(
        error.InvalidTypeOnlyModule,
        forged_store.appendTypeOnlyModule(changed_endpoint),
    );
    try std.testing.expectEqual(@as(usize, 0), forged_store.type_only_modules.items.len);

    var failing = std.testing.FailingAllocator.init(
        std.testing.allocator,
        .{ .fail_index = 0 },
    );
    var failing_store = Store.init(failing.allocator(), source);
    defer failing_store.deinit();
    try std.testing.expectError(
        error.OutOfMemory,
        failing_store.appendTypeOnlyModule(module),
    );
    try std.testing.expect(failing.has_induced_failure);
    try std.testing.expectEqual(@as(usize, 0), failing_store.type_only_modules.items.len);

    const refused_source =
        "import type { Spec } from \"" ++ retired_types_module ++ "\";";
    var refused_diagnostics: std.ArrayListUnmanaged(TypeOnlyModuleDiagnostic) = .empty;
    defer refused_diagnostics.deinit(std.testing.allocator);
    const refusal = switch (try scanTypeOnlyModule(std.testing.allocator, .{
        .source = refused_source,
        .keyword = Cursor.init(refused_source).current,
        .diagnostics = &refused_diagnostics,
    })) {
        .refused => |refused| refused,
        .not_type_only, .excluded, .scanned => return error.TestExpectedTypeOnlyModule,
    };
    var refused_store = Store.init(std.testing.allocator, refused_source);
    defer refused_store.deinit();
    try std.testing.expectError(
        error.InvalidTypeOnlyModule,
        refused_store.appendTypeOnlyModule(.{
            .kind = .import_type,
            .raw_span = refusal.raw_span,
        }),
    );
    try std.testing.expectEqual(@as(usize, 0), refused_store.type_only_modules.items.len);
}

test "type-only module scanner preserves quoted and template statement ends" {
    const sources = [_][]const u8{
        "import type { A } from \"./a;b\";tail",
        "import type `head;${\"middle;\"}tail`;tail",
        "import type \"open\\\nclosed\";tail",
    };
    for (sources) |source| {
        var diagnostics: std.ArrayListUnmanaged(TypeOnlyModuleDiagnostic) = .empty;
        defer diagnostics.deinit(std.testing.allocator);
        const cursor = Cursor.init(source);
        const module = switch (try scanTypeOnlyModule(std.testing.allocator, .{
            .source = source,
            .keyword = cursor.current,
            .diagnostics = &diagnostics,
        })) {
            .scanned => |module| module,
            .not_type_only, .refused, .excluded => return error.TestExpectedTypeOnlyModule,
        };
        const semicolon = std.mem.lastIndexOfScalar(u8, source[0 .. source.len - "tail".len], ';') orelse
            return error.TestExpectedTypeOnlyModule;
        try std.testing.expectEqual(@as(u32, @intCast(semicolon + 1)), module.raw_span.end);
        try std.testing.expectEqual(@as(usize, 0), diagnostics.items.len);
    }
}

test "type-only module exclusion survives deduplication across diagnostic kinds" {
    const source = "import type \"open\n";
    const fault = std.mem.indexOfScalar(u8, source, '\n') orelse return error.TestUnexpectedResult;
    const prior: TypeOnlyModuleDiagnostic = .{
        .kind = .nesting_too_deep,
        .offset = @intCast(fault),
    };
    var diagnostics: std.ArrayListUnmanaged(TypeOnlyModuleDiagnostic) = .empty;
    defer diagnostics.deinit(std.testing.allocator);
    try diagnostics.append(std.testing.allocator, prior);
    const cursor = Cursor.init(source);
    const module = switch (try scanTypeOnlyModule(std.testing.allocator, .{
        .source = source,
        .keyword = cursor.current,
        .diagnostics = &diagnostics,
    })) {
        .excluded => |module| module,
        .not_type_only, .refused, .scanned => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(@as(u32, @intCast(fault)), module.raw_span.end);
    try std.testing.expectEqual(@as(usize, 1), diagnostics.items.len);
    try std.testing.expect(std.meta.eql(prior, diagnostics.items[0]));
}

test "admission endpoints retain producer specific delimiters" {
    const source = "number, (value: string) => string { body }; next\n";
    var caught: std.ArrayListUnmanaged(AdmissionDiagnostic) = .empty;
    defer caught.deinit(std.testing.allocator);

    const variable = try scanAdmissionEndpointCore(
        std.testing.allocator,
        source,
        0,
        .{ .general = .variable },
        &caught,
        null,
    );
    try std.testing.expectEqual(@as(u32, 6), variable.complete.end);

    const function_start: u32 = @intCast(std.mem.indexOfScalar(u8, source, '(').?);
    const named = try scanAdmissionEndpointCore(
        std.testing.allocator,
        source,
        function_start,
        .{ .general = .named_return },
        &caught,
        null,
    );
    const body_start: u32 = @intCast(std.mem.indexOfScalar(u8, source, '{').?);
    try std.testing.expectEqual(body_start, named.complete.end);

    const arrow_start: u32 = @intCast(std.mem.indexOf(u8, source, "string { body }").?);
    const arrow = try scanAdmissionEndpointCore(
        std.testing.allocator,
        source,
        arrow_start,
        .{ .general = .arrow_return },
        &caught,
        null,
    );
    try std.testing.expectEqual(body_start, arrow.complete.end);

    const unmatched = "(string; any), next";
    const continued = try scanAdmissionEndpointCore(
        std.testing.allocator,
        unmatched,
        0,
        .{ .general = .variable },
        &caught,
        null,
    );
    try std.testing.expectEqual(
        @as(u32, @intCast(std.mem.indexOfScalar(u8, unmatched, ',').?)),
        continued.complete.end,
    );
}

test "admission endpoint reports only committed unfinished comments" {
    const source = "number /* unfinished";
    var caught: std.ArrayListUnmanaged(AdmissionDiagnostic) = .empty;
    defer caught.deinit(std.testing.allocator);
    const result = try scanAdmissionEndpointCore(
        std.testing.allocator,
        source,
        0,
        .{ .general = .variable },
        &caught,
        null,
    );
    const failure = switch (result) {
        .unterminated_comment => |failure| failure,
        else => return error.TestExpectedUnterminatedComment,
    };
    try std.testing.expectEqual(@as(u32, 7), failure.opener);
    try std.testing.expectEqual(@as(u32, @intCast(source.len - 1)), failure.@"resume");
    try std.testing.expectEqual(@as(usize, 0), caught.items.len);

    const bare = "/*";
    const bare_result = try scanAdmissionEndpointCore(
        std.testing.allocator,
        bare,
        0,
        .{ .general = .variable },
        &caught,
        null,
    );
    const bare_failure = switch (bare_result) {
        .unterminated_comment => |bare_comment| bare_comment,
        else => return error.TestExpectedUnterminatedComment,
    };
    try std.testing.expectEqual(@as(u32, 0), bare_failure.opener);
    try std.testing.expectEqual(@as(u32, @intCast(bare.len)), bare_failure.@"resume");

    const interface_body = "interface X extends { field: /* unfinished";
    const extends_end: u32 = @intCast(std.mem.indexOf(u8, interface_body, "extends").? + "extends".len);
    const body_start: u32 = @intCast(std.mem.indexOfScalar(u8, interface_body, '{').?);
    const interface_result = try scanAdmissionEndpointCore(
        std.testing.allocator,
        interface_body,
        extends_end,
        .{ .general = .interface_extends },
        &caught,
        null,
    );
    try std.testing.expectEqual(
        Span{ .start = extends_end, .end = body_start },
        interface_result.complete,
    );

    const quoted = "\"/* unfinished\";";
    const quoted_result = try scanAdmissionEndpointCore(
        std.testing.allocator,
        quoted,
        0,
        .{ .general = .variable },
        &caught,
        null,
    );
    const semicolon: u32 = @intCast(std.mem.indexOfScalar(u8, quoted, ';').?);
    try std.testing.expectEqual(Span{ .start = 0, .end = semicolon }, quoted_result.complete);

    const template = "`/* unfinished`;";
    const template_result = try scanAdmissionEndpointCore(
        std.testing.allocator,
        template,
        0,
        .{ .general = .variable },
        &caught,
        null,
    );
    const template_semicolon: u32 = @intCast(std.mem.indexOfScalar(u8, template, ';').?);
    try std.testing.expectEqual(
        Span{ .start = 0, .end = template_semicolon },
        template_result.complete,
    );
}

test "parameter endpoint follows legacy delimiter depth rules" {
    const source = "{ value: string; nested: number } = fallback, next)";
    var caught: std.ArrayListUnmanaged(AdmissionDiagnostic) = .empty;
    defer caught.deinit(std.testing.allocator);

    const result = try scanAdmissionEndpointCore(
        std.testing.allocator,
        source,
        0,
        .parameter,
        &caught,
        null,
    );
    const equals: u32 = @intCast(std.mem.indexOfScalar(u8, source, '=').?);
    try std.testing.expectEqual(equals, result.complete.end);

    const inside_brace = "{ value = fallback }, next)";
    const nested_result = try scanAdmissionEndpointCore(
        std.testing.allocator,
        inside_brace,
        0,
        .parameter,
        &caught,
        null,
    );
    try std.testing.expectEqual(
        @as(u32, @intCast(std.mem.indexOfScalar(u8, inside_brace, '=').?)),
        nested_result.complete.end,
    );
}

test "return endpoints preserve semicolon and unmatched brace distinctions" {
    var caught: std.ArrayListUnmanaged(AdmissionDiagnostic) = .empty;
    defer caught.deinit(std.testing.allocator);

    const arrow_source = "string; any => value";
    const arrow = try scanAdmissionEndpointCore(
        std.testing.allocator,
        arrow_source,
        0,
        .{ .general = .arrow_return },
        &caught,
        null,
    );
    try std.testing.expectEqual(
        @as(u32, @intCast(std.mem.indexOf(u8, arrow_source, "=>").?)),
        arrow.complete.end,
    );

    const unmatched = "string } ; body";
    const semicolon: u32 = @intCast(std.mem.indexOfScalar(u8, unmatched, ';').?);
    const named = try scanAdmissionEndpointCore(
        std.testing.allocator,
        unmatched,
        0,
        .{ .general = .named_return },
        &caught,
        null,
    );
    try std.testing.expectEqual(semicolon, named.complete.end);
    const interface = try scanAdmissionEndpointCore(
        std.testing.allocator,
        unmatched,
        0,
        .{ .general = .interface_extends },
        &caught,
        null,
    );
    try std.testing.expectEqual(semicolon, interface.complete.end);

    const full_interface = "interface X extends { field: any }";
    const extends_end: u32 = @intCast(std.mem.indexOf(u8, full_interface, "extends").? + "extends".len);
    const body_start: u32 = @intCast(std.mem.indexOfScalar(u8, full_interface, '{').?);
    const full_result = try scanAdmissionEndpointCore(
        std.testing.allocator,
        full_interface,
        extends_end,
        .{ .general = .interface_extends },
        &caught,
        null,
    );
    try std.testing.expectEqual(body_start, full_result.complete.end);
}

test "assertion endpoint keeps object braces and stops at expression delimiters" {
    const source = "{ field: string }, after";
    var caught: std.ArrayListUnmanaged(AdmissionDiagnostic) = .empty;
    defer caught.deinit(std.testing.allocator);
    const result = try scanAdmissionEndpointCore(
        std.testing.allocator,
        source,
        0,
        .{ .general = .assertion },
        &caught,
        null,
    );
    try std.testing.expectEqual(
        @as(u32, @intCast(std.mem.indexOfScalar(u8, source, ',').?)),
        result.complete.end,
    );
}

test "admission quoted region preserves complete and terminal boundaries" {
    var caught: std.ArrayListUnmanaged(AdmissionDiagnostic) = .empty;
    defer caught.deinit(std.testing.allocator);

    const closed = "\"closed\" tail";
    switch (try scanAdmissionQuotedRegion(std.testing.allocator, .{
        .source = closed,
        .start = 0,
        .caught = &caught,
    })) {
        .complete => |end| try std.testing.expectEqual(@as(u32, 8), end),
        .terminal => return error.TestUnexpectedResult,
    }
    try std.testing.expectEqual(@as(usize, 0), caught.items.len);

    const eof = "\"open";
    switch (try scanAdmissionQuotedRegion(std.testing.allocator, .{
        .source = eof,
        .start = 0,
        .caught = &caught,
    })) {
        .complete => |end| try std.testing.expectEqual(@as(u32, eof.len), end),
        .terminal => return error.TestUnexpectedResult,
    }

    const line = "\"open\nrest";
    switch (try scanAdmissionQuotedRegion(std.testing.allocator, .{
        .source = line,
        .start = 0,
        .caught = &caught,
    })) {
        .terminal => |diagnostic| {
            try std.testing.expectEqual(AdmissionKind.unterminated_string, diagnostic.kind);
            try std.testing.expectEqual(Span{ .start = 5, .end = 6 }, diagnostic.span);
        },
        .complete => return error.TestUnexpectedResult,
    }
    try std.testing.expectEqual(@as(usize, 0), caught.items.len);
    try std.testing.expectError(
        error.InvalidAdmissionSpan,
        scanAdmissionQuotedRegion(std.testing.allocator, .{
            .source = "value",
            .start = 0,
            .caught = &caught,
        }),
    );
    try std.testing.expectError(
        error.InvalidAdmissionSpan,
        scanAdmissionQuotedRegion(std.testing.allocator, .{
            .source = "\"value\"",
            .start = 7,
            .caught = &caught,
        }),
    );
}

test "admission quoted region restores caught rows on allocation failure" {
    const prefix = "`outer${\"first\n";
    const nested_count = comptime std.ArrayListUnmanaged(LegacyTemplateFrame).growCapacity(1);
    const source = prefix ++ (@as([(nested_count) * ("`nested${").len]u8, @bitCast(@as([nested_count][("`nested${").len]u8, @splat(("`nested${").*))))) ++ "value" ++ (@as([(nested_count) * ("}`").len]u8, @bitCast(@as([nested_count][("}`").len]u8, @splat(("}`").*))))) ++ "}`";
    var observed_failures: usize = 0;
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        struct {
            fn run(
                allocator: std.mem.Allocator,
                text: []const u8,
                failures: *usize,
            ) !void {
                var caught: std.ArrayListUnmanaged(AdmissionDiagnostic) = .empty;
                defer caught.deinit(allocator);
                const seed: AdmissionDiagnostic = .{
                    .kind = .nesting_too_deep,
                    .span = .{ .start = 0, .end = 1 },
                };
                try caught.append(allocator, seed);
                const entry_len = caught.items.len;
                _ = scanAdmissionQuotedRegion(allocator, .{
                    .source = text,
                    .start = 0,
                    .caught = &caught,
                }) catch |err| switch (err) {
                    error.OutOfMemory => {
                        failures.* += 1;
                        try std.testing.expectEqual(entry_len, caught.items.len);
                        try std.testing.expectEqualDeep(seed, caught.items[0]);
                        return err;
                    },
                    else => return err,
                };
                try std.testing.expect(caught.items.len > entry_len);
            }
        }.run,
        .{ source, &observed_failures },
    );
    try std.testing.expect(observed_failures > 0);

    const seed: AdmissionDiagnostic = .{
        .kind = .nesting_too_deep,
        .span = .{ .start = 0, .end = 1 },
    };
    var calibration = std.testing.FailingAllocator.init(std.testing.allocator, .{
        .fail_index = std.math.maxInt(usize),
        .resize_fail_index = std.math.maxInt(usize),
    });
    var prefix_caught: std.ArrayListUnmanaged(AdmissionDiagnostic) = .empty;
    defer prefix_caught.deinit(calibration.allocator());
    try prefix_caught.append(calibration.allocator(), seed);
    switch (try scanAdmissionQuotedRegion(calibration.allocator(), .{
        .source = prefix,
        .start = 0,
        .caught = &prefix_caught,
    })) {
        .complete => |end| try std.testing.expectEqual(@as(u32, prefix.len), end),
        .terminal => return error.TestUnexpectedResult,
    }
    try std.testing.expectEqual(@as(usize, 2), prefix_caught.items.len);
    try std.testing.expectEqual(AdmissionKind.unterminated_string, prefix_caught.items[1].kind);

    var post_caught_failure = std.testing.FailingAllocator.init(std.testing.allocator, .{
        .fail_index = calibration.alloc_index,
        .resize_fail_index = calibration.resize_index,
    });
    var full_caught: std.ArrayListUnmanaged(AdmissionDiagnostic) = .empty;
    defer full_caught.deinit(post_caught_failure.allocator());
    try full_caught.append(post_caught_failure.allocator(), seed);
    try std.testing.expectError(
        error.OutOfMemory,
        scanAdmissionQuotedRegion(post_caught_failure.allocator(), .{
            .source = source,
            .start = 0,
            .caught = &full_caught,
        }),
    );
    try std.testing.expect(post_caught_failure.has_induced_failure);
    try std.testing.expectEqual(@as(usize, 1), full_caught.items.len);
    try std.testing.expectEqualDeep(seed, full_caught.items[0]);
}

test "admission quoted core preserves caught events" {
    const source = "`outer${\"open\n${value}} tail`";
    var caught: std.ArrayListUnmanaged(AdmissionDiagnostic) = .empty;
    defer caught.deinit(std.testing.allocator);

    const result = try scanAdmissionTemplate(std.testing.allocator, source, 0, &caught);
    try std.testing.expectEqual(@as(u32, source.len), result.complete);
    try std.testing.expectEqual(@as(usize, 1), caught.items.len);
    try std.testing.expectEqual(AdmissionKind.unterminated_string, caught.items[0].kind);
    try std.testing.expectEqual(@as(u8, '\n'), source[@as(usize, caught.items[0].span.start)]);
}

test "admission template scanner reports allocator failure" {
    const source = "`outer${\"open\n`nested${value}`}`";
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        struct {
            fn run(allocator: std.mem.Allocator, text: []const u8) !void {
                var caught: std.ArrayListUnmanaged(AdmissionDiagnostic) = .empty;
                defer caught.deinit(allocator);
                _ = try scanAdmissionTemplate(allocator, text, 0, &caught);
            }
        }.run,
        .{source},
    );
}

test "removed types retain physical positions after parameter presentation changes" {
    const source = ": /*x*/ any, y: void";
    var collector = AdmissionCollector.init(std.testing.allocator, .collect);
    defer collector.deinit();
    collector.source = source;
    var history = AdmissionObservationHistory.init(std.testing.allocator);
    defer history.deinit();
    history.source = source;
    var sink = AdmissionSink.init(&collector, &history);
    sink.presentation = try (AdmissionPresentation{ .source = source }).declinedParameterColon(0);
    try classifyTypeSpan(source, .{
        .span = .{ .start = 15, .end = @intCast(source.len) },
        .policy = .parameter_type,
    }, sink);
    try std.testing.expectEqual(@as(usize, 1), collector.items().len);
    const diagnostic = collector.items()[0];
    try std.testing.expectEqual(AdmissionKind.void_type, diagnostic.kind);
    try std.testing.expectEqualDeep(Span{ .start = 16, .end = 20 }, diagnostic.span);
    try std.testing.expectEqualDeep(AdmissionPosition{ .line = 1, .column = 17 }, diagnostic.presentation.?);
    try std.testing.expectEqualDeep(diagnostic, history.last().?);
}

test "function type presentation preserves caller seeds and stops compile selection" {
    const source = "(x: any) =>\r any";
    const seed: AdmissionDiagnostic = .{
        .kind = .unterminated_string,
        .span = .{ .start = 0, .end = 1 },
    };
    for ([_]AdmissionMode{ .collect, .compile }) |mode| {
        var collector = AdmissionCollector.init(std.testing.allocator, mode);
        defer collector.deinit();
        collector.source = source;
        var history = AdmissionObservationHistory.init(std.testing.allocator);
        defer history.deinit();
        history.source = source;
        var caught: std.ArrayListUnmanaged(AdmissionDiagnostic) = .empty;
        defer caught.deinit(std.testing.allocator);
        try caught.append(std.testing.allocator, seed);
        var sink = AdmissionSink.init(&collector, &history);
        sink.presentation = .{ .source = source };
        var progress: AdmissionEndpointProgress = .{
            .sink = sink,
            .policy = .general_type,
            .classification_start = 0,
        };
        if (mode == .compile) {
            try std.testing.expectError(error.AdmissionRefused, scanAdmissionEndpointWithPresentation(
                std.testing.allocator,
                source,
                0,
                .{ .general = .variable },
                &caught,
                &progress,
            ));
            try std.testing.expectEqual(@as(u32, 0), progress.classification_start);
            try std.testing.expectEqual(@as(usize, 1), collector.items().len);
        } else {
            const span = switch (try scanAdmissionEndpointWithPresentation(
                std.testing.allocator,
                source,
                0,
                .{ .general = .variable },
                &caught,
                &progress,
            )) {
                .complete => |span| span,
                else => return error.TestUnexpectedResult,
            };
            try std.testing.expectEqualDeep(Span{ .start = 0, .end = source.len }, span);
            try std.testing.expectEqual(@as(u32, 13), progress.classification_start);
            try classifyTypeSpan(source, .{
                .span = .{ .start = progress.classification_start, .end = span.end },
                .policy = .general_type,
                .caught_lexical = caught.items[1..],
                .removed_span = span,
            }, progress.sink);
            try std.testing.expectEqual(@as(usize, 2), collector.items().len);
            try std.testing.expectEqualDeep(AdmissionPosition{ .line = 1, .column = 13 }, collector.items()[1].presentation.?);
        }
        try std.testing.expectEqual(@as(usize, 1), caught.items.len);
        try std.testing.expectEqualDeep(seed, caught.items[0]);
        try std.testing.expectEqual(collector.items().len, history.items().len);
        try std.testing.expectEqualDeep(AdmissionPosition{ .line = 1, .column = 5 }, collector.items()[0].presentation.?);
    }
}

test "function type presentation propagates allocation failure after chunk publication" {
    const first_capacity = comptime std.ArrayListUnmanaged(AdmissionDiagnostic).growCapacity(1);
    const source = "(x: any) =>\r " ++ (@as([(first_capacity) * ("any | ").len]u8, @bitCast(@as([first_capacity][("any | ").len]u8, @splat(("any | ").*))))) ++ "any";
    var observed_post_publication_failures: usize = 0;
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn run(allocator: std.mem.Allocator, text: []const u8, failure_count: *usize) !void {
            var collector = AdmissionCollector.init(allocator, .collect);
            defer collector.deinit();
            collector.source = text;
            var history = AdmissionObservationHistory.init(allocator);
            defer history.deinit();
            history.source = text;
            var caught: std.ArrayListUnmanaged(AdmissionDiagnostic) = .empty;
            defer caught.deinit(allocator);
            var sink = AdmissionSink.init(&collector, &history);
            sink.presentation = .{ .source = text };
            var progress: AdmissionEndpointProgress = .{
                .sink = sink,
                .policy = .general_type,
                .classification_start = 0,
            };
            const span = switch (try scanAdmissionEndpointWithPresentation(
                allocator,
                text,
                0,
                .{ .general = .variable },
                &caught,
                &progress,
            )) {
                .complete => |span| span,
                else => return error.TestUnexpectedResult,
            };
            classifyTypeSpan(text, .{
                .span = .{ .start = progress.classification_start, .end = span.end },
                .policy = .general_type,
                .caught_lexical = caught.items,
                .removed_span = span,
            }, progress.sink) catch |err| {
                switch (err) {
                    error.OutOfMemory => {
                        if (progress.classification_start == 13 and collector.items().len > 0 and history.items().len > 0) {
                            try std.testing.expectEqualDeep(AdmissionPosition{ .line = 1, .column = 5 }, collector.items()[0].presentation.?);
                            try std.testing.expectEqualDeep(collector.items()[0], history.items()[0]);
                            failure_count.* += 1;
                        }
                    },
                    else => {},
                }
                return err;
            };
            const capacity = comptime std.ArrayListUnmanaged(AdmissionDiagnostic).growCapacity(1);
            try std.testing.expectEqual(capacity + 2, collector.items().len);
            try std.testing.expectEqual(capacity + 2, history.items().len);
            try std.testing.expectEqualDeep(AdmissionPosition{ .line = 1, .column = 13 + 6 * capacity }, history.last().?.presentation.?);
        }
    }.run, .{ source, &observed_post_publication_failures });
    try std.testing.expect(observed_post_publication_failures > 0);
}

test "classification rejects invalid removed spans before publishing the tail" {
    const source = "void any";
    const invalid = [_]Span{
        .{ .start = 4, .end = 3 },
        .{ .start = 0, .end = 9 },
        .{ .start = 6, .end = 8 },
        .{ .start = 0, .end = 7 },
    };
    for (invalid) |span| {
        var collector = AdmissionCollector.init(std.testing.allocator, .collect);
        defer collector.deinit();
        var history = AdmissionObservationHistory.init(std.testing.allocator);
        defer history.deinit();
        try std.testing.expectError(error.InvalidAdmissionSpan, classifyTypeSpan(source, .{
            .span = .{ .start = 5, .end = 8 },
            .policy = .general_type,
            .removed_span = span,
        }, AdmissionSink.init(&collector, &history)));
        try std.testing.expectEqual(@as(usize, 0), collector.items().len);
        try std.testing.expectEqual(@as(usize, 0), history.items().len);
        try std.testing.expectEqual(@as(u64, 0), collector.generation());
    }
    try std.testing.expectEqual(@as(usize, 4), invalid.len);
    var collector = AdmissionCollector.init(std.testing.allocator, .collect);
    defer collector.deinit();
    try classifyTypeSpan(source, .{
        .span = .{ .start = 5, .end = 8 },
        .policy = .general_type,
        .removed_span = .{ .start = 0, .end = 8 },
    }, AdmissionSink.init(&collector, null));
    try std.testing.expectEqual(@as(usize, 2), collector.items().len);
    try std.testing.expectEqual(AdmissionKind.any_type, collector.items()[0].kind);
    try std.testing.expectEqual(AdmissionKind.void_type, collector.items()[1].kind);
}
