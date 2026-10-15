//! Private comparison between legacy stripping and direct type syntax parsing.
//!
//! This module is test-only. It adds no public frontend choice or fallback.

const std = @import("std");
const engine = @import("zts-engine");
const type_env_mod = @import("type_env.zig");
const type_key = @import("type_key.zig");
const type_pool_mod = @import("type_pool.zig");
const module_types = @import("module_types.zig");
const abi_types = @import("abi_types.zig");

const AtomTable = engine.atom_table.AtomTable;
const JsParser = engine.parser.JsParser;
const NodeIndex = engine.parser.NodeIndex;
const Token = engine.parser.Token;
const TokenType = engine.parser.TokenType;
const Tokenizer = engine.parser.Tokenizer;
const TypeSyntax = engine.parser.type_syntax;
const PreparedSource = engine.source_frontend.PreparedSource;
const TypeEnv = type_env_mod.TypeEnv;
const TypeIndex = type_pool_mod.TypeIndex;
const TypePool = type_pool_mod.TypePool;
const TypeTag = type_pool_mod.TypeTag;
const RecordField = type_pool_mod.RecordField;
const FuncParam = type_pool_mod.FuncParam;
const PoolTemplatePart = type_pool_mod.TemplatePart;
const null_type_idx = type_pool_mod.null_type_idx;
const parseTypeExpr = type_pool_mod.parseTypeExpr;

const CompoundFamily = enum {
    record,
    array,
    tuple,
    union_type,
    intersection,
    literal,
    template,
    function,
};

const SemanticQuirk = enum {
    quoted_record_prefix,
    missing_record_colon_prefix,
    missing_record_type_absent,
    record_comment_prefix,
    record_comment_after_field,
    omitted_record_separator,
    readonly_optional_fields,
    mutable_repeated_arrays,
    separated_array_brackets,
    comment_before_array,
    readonly_array_flag,
    tuple_trailing_comma,
    readonly_tuple_erasure,
    grouped_leading_union,
    trailing_union_prefix,
    trailing_intersection_prefix,
    intersection_precedence,
    nullable_shorthand,
    wider_undefined_union,
    numeric_token_prefix,
    nested_optional_parameter,
    any_member_key,
    missing_function_comma,
    missing_function_arrow,
    missing_function_return,
    named_function_parameters,
    escaped_template_slot,
    empty_template_slot,
    empty_template_root,
    multi_part_template,
    literal_values,
};

const AdmissionMode = enum {
    collect,
    compile,
};

const AdmissionKind = enum {
    any_type,
    void_type,
    array_type_alias,
    readonly_array_type_alias,
    optional_parameter,
    nesting_too_deep,
    nominal_base_not_scalar,
};

const AdmissionDiagnostic = struct {
    kind: AdmissionKind,
    span: TypeSyntax.Span,
};

const OutOfSliceReason = enum {
    function_declaration,
    import_declaration,
    export_declaration,
    type_declaration,
    multiple_bindings,
    annotation_count,
    compound_annotation,
    malformed_annotation,
    unsupported_annotation_position,
    assertion_syntax,
    template_literal,
    regex_literal,
    type_comment,
    unsupported_initializer,
    lone_carriage_return,
};

const Verdict = union(enum) {
    equivalent,
    differs: []const u8,
    admission_refused: struct {
        first: AdmissionKind,
        count: usize,
    },
    out_of_slice: OutOfSliceReason,
};

const Preflight = struct {
    diagnostics: std.ArrayListUnmanaged(AdmissionDiagnostic) = .empty,

    fn deinit(self: *Preflight, allocator: std.mem.Allocator) void {
        self.diagnostics.deinit(allocator);
    }
};

const PreflightOutcome = union(enum) {
    eligible: Preflight,
    out_of_slice: OutOfSliceReason,
};

/// Inspect the complete bounded source before either runtime parse starts.
fn preflight(
    allocator: std.mem.Allocator,
    source: []const u8,
    mode: AdmissionMode,
) !PreflightOutcome {
    for (source, 0..) |byte, index| {
        if (byte == '\r' and (index + 1 == source.len or source[index + 1] != '\n')) {
            return .{ .out_of_slice = .lone_carriage_return };
        }
    }
    if (hasUnterminatedSkippedBlockComment(source)) {
        return .{ .out_of_slice = .unsupported_initializer };
    }
    var result = Preflight{};
    var owns_result = true;
    defer if (owns_result) result.deinit(allocator);

    var tokenizer = Tokenizer.init(source);
    var current = tokenizer.next();
    var annotation_count: usize = 0;
    var declaration_count: usize = 0;
    var last_erased_type_span: ?TypeSyntax.Span = null;

    while (current.type != .eof) {
        switch (current.type) {
            .kw_function => return .{ .out_of_slice = .function_declaration },
            .kw_import => return .{ .out_of_slice = .import_declaration },
            .template_literal, .template_head, .template_middle, .template_tail => return .{ .out_of_slice = .template_literal },
            .regex_literal => return .{ .out_of_slice = .regex_literal },
            .kw_let, .kw_const => {},
            .kw_export, .identifier => {
                const declaration_start = current.start;
                if (current.type == .identifier and !isTypeDeclarationWord(current.text(source))) {
                    return .{ .out_of_slice = .unsupported_initializer };
                }
                if (!isDeclarationBoundary(source, declaration_start, last_erased_type_span)) {
                    return .{ .out_of_slice = if (current.type == .kw_export)
                        .export_declaration
                    else
                        .type_declaration };
                }
                var export_span: ?TypeSyntax.Span = null;
                var keyword = current;
                var declaration_cursor = TypeSyntax.Cursor.afterCurrent(tokenizer);
                if (current.type == .kw_export) {
                    export_span = tokenSpan(current);
                    keyword = declaration_cursor.current;
                    declaration_cursor.advance();
                }
                if (keyword.type != .identifier or !isTypeDeclarationWord(keyword.text(source))) {
                    return .{ .out_of_slice = if (current.type == .kw_export)
                        .export_declaration
                    else
                        .unsupported_initializer };
                }
                const declaration_kind: TypeSyntax.DeclarationKind = if (std.mem.eql(
                    u8,
                    keyword.text(source),
                    "structural",
                ))
                    .structural
                else if (std.mem.eql(u8, keyword.text(source), "nominal"))
                    .nominal
                else
                    return .{ .out_of_slice = .type_declaration };

                var declaration_store = TypeSyntax.Store.init(allocator, source);
                defer declaration_store.deinit();
                const parsed = try TypeSyntax.parseDeclarationAndStore(
                    &declaration_store,
                    source,
                    keyword,
                    export_span,
                    declaration_kind,
                    0,
                    &declaration_cursor,
                );
                const erased = switch (parsed) {
                    .not_declaration => return .{ .out_of_slice = .type_declaration },
                    .excluded => |excluded| blk: {
                        switch (excluded.reason) {
                            .implementation_budget, .unsupported_syntax => {
                                return .{ .out_of_slice = .type_declaration };
                            },
                            .nominal_base_not_scalar => {},
                        }
                        var local: std.ArrayListUnmanaged(AdmissionDiagnostic) = .empty;
                        defer local.deinit(allocator);
                        try appendAnyDiagnostics(
                            allocator,
                            &local,
                            source,
                            excluded.raw_span.start,
                            excluded.raw_span.end,
                        );
                        for (local.items) |diagnostic| {
                            try appendDiagnosticAtNewPosition(allocator, &result.diagnostics, diagnostic);
                        }
                        try appendDiagnosticAtNewPosition(allocator, &result.diagnostics, .{
                            .kind = .nominal_base_not_scalar,
                            .span = excluded.raw_span,
                        });
                        while (declaration_cursor.current.type != .eof and
                            declaration_cursor.current.start < excluded.admission_end)
                        {
                            declaration_cursor.advance();
                        }
                        var end = excluded.admission_end;
                        const whitespace_end = skipDeclarationWhitespace(source, excluded.admission_end);
                        if (declaration_cursor.current.type == .semicolon and
                            declaration_cursor.current.start == whitespace_end)
                        {
                            end = declaration_cursor.current.start + declaration_cursor.current.len;
                            declaration_cursor.advance();
                        }
                        break :blk TypeSyntax.Span{ .start = declaration_start, .end = end };
                    },
                    .parsed => |span| blk: {
                        const declaration = declaration_store.declarations.items[0];
                        switch (declaration.body) {
                            .absent => {},
                            .present => |body| if (declaration.kind == .structural) {
                                try appendAdmissionDiagnostics(
                                    allocator,
                                    &result.diagnostics,
                                    source,
                                    body.raw_span,
                                );
                            } else {
                                try appendAnyDiagnostics(
                                    allocator,
                                    &result.diagnostics,
                                    source,
                                    body.raw_span.start,
                                    body.raw_span.end,
                                );
                            },
                        }
                        break :blk span;
                    },
                };
                declaration_count += 1;
                last_erased_type_span = erased;
                tokenizer = declaration_cursor.tokenizer;
                current = declaration_cursor.current;
                continue;
            },
            .colon => return .{ .out_of_slice = .unsupported_annotation_position },
            else => return .{ .out_of_slice = .unsupported_initializer },
        }

        advance(&tokenizer, &current);
        if (current.type != .identifier) {
            return .{ .out_of_slice = .multiple_bindings };
        }
        advance(&tokenizer, &current);

        if (current.type == .colon) {
            annotation_count += 1;
            if (annotation_count > 1) return .{ .out_of_slice = .annotation_count };

            const colon = current;
            var type_cursor = TypeSyntax.Cursor.afterCurrent(tokenizer);
            var syntax_store = TypeSyntax.Store.init(allocator, source);
            defer syntax_store.deinit();
            const parsed = try TypeSyntax.parseAndStore(
                &syntax_store,
                .global(0),
                source,
                colon.start + colon.len,
                &type_cursor,
            );
            var nesting_refusal: ?AdmissionDiagnostic = null;
            const raw_span: TypeSyntax.Span = switch (parsed) {
                .parsed => |value| value.raw_span,
                .excluded => |excluded| blk: {
                    while (type_cursor.current.type != .eof and
                        type_cursor.current.start < excluded.admission_end)
                    {
                        type_cursor.advance();
                    }
                    break :blk excluded.raw_span;
                },
                .failure => |failure| switch (failure) {
                    .nesting_too_deep => |at| blk: {
                        var validation = type_cursor;
                        switch (TypeSyntax.validatePrimitiveAfterDepthRefusal(source, &validation)) {
                            .parsed => type_cursor = validation,
                            .failure => return .{ .out_of_slice = .malformed_annotation },
                        }
                        nesting_refusal = .{
                            .kind = .nesting_too_deep,
                            .span = tokenSpan(at),
                        };
                        break :blk .{
                            .start = colon.start + colon.len,
                            .end = type_cursor.current.start,
                        };
                    },
                    .missing_type, .unmatched_parenthesis, .unsupported_suffix => return .{ .out_of_slice = .malformed_annotation },
                },
            };
            if (nesting_refusal) |diagnostic| {
                if (mode == .compile) {
                    try appendAnyDiagnostics(
                        allocator,
                        &result.diagnostics,
                        source,
                        raw_span.start,
                        diagnostic.span.start,
                    );
                } else {
                    result.diagnostics.clearRetainingCapacity();
                }
                try result.diagnostics.append(allocator, diagnostic);
                if (mode == .compile and result.diagnostics.items.len > 1) {
                    result.diagnostics.items.len = 1;
                }
            } else try appendAdmissionDiagnostics(
                allocator,
                &result.diagnostics,
                source,
                raw_span,
            );
            switch (parsed) {
                .parsed, .failure => {},
                .excluded => |excluded| switch (excluded.reason) {
                    .implementation_budget => return .{ .out_of_slice = .compound_annotation },
                    .malformed_syntax => return .{ .out_of_slice = .malformed_annotation },
                    .unsupported_syntax => if (result.diagnostics.items.len == 0) {
                        if (startsWithTypeComment(source, colon.start + colon.len)) {
                            return .{ .out_of_slice = .type_comment };
                        }
                        return .{ .out_of_slice = .compound_annotation };
                    },
                },
            }

            tokenizer = type_cursor.tokenizer;
            current = type_cursor.current;
        }

        if (current.type == .assign) {
            advance(&tokenizer, &current);
            const refused = scanInitializer(source, &tokenizer, &current);
            if (refused) |reason| return .{ .out_of_slice = reason };
        }

        if (current.type == .semicolon) {
            advance(&tokenizer, &current);
        } else if (current.type != .eof) {
            return .{ .out_of_slice = .unsupported_initializer };
        }
    }

    if (annotation_count != 1 and declaration_count == 0) {
        return .{ .out_of_slice = .annotation_count };
    }
    if (mode == .compile and result.diagnostics.items.len > 1) {
        result.diagnostics.items.len = 1;
    }
    owns_result = false;
    return .{ .eligible = result };
}

fn isDeclarationBoundary(
    source: []const u8,
    start: u32,
    last_erased_type_span: ?TypeSyntax.Span,
) bool {
    if (start == 0) return true;
    const previous_offset = start - 1;
    const previous = if (last_erased_type_span) |span|
        if (previous_offset >= span.start and previous_offset < span.end)
            if (source[previous_offset] == '\n') @as(u8, '\n') else @as(u8, ' ')
        else
            source[previous_offset]
    else
        source[previous_offset];
    return previous == ';' or previous == '{' or previous == '}' or previous == '\n';
}

fn skipDeclarationWhitespace(source: []const u8, start: u32) u32 {
    var offset: usize = @min(@as(usize, start), source.len);
    while (offset < source.len) : (offset += 1) {
        switch (source[offset]) {
            ' ', '\t', '\r', '\n' => {},
            else => break,
        }
    }
    return @intCast(offset);
}

fn hasUnterminatedSkippedBlockComment(source: []const u8) bool {
    var tokenizer = Tokenizer.init(source);
    var previous_end: usize = 0;
    while (tokenizer.pos < source.len) {
        const previous_pos = tokenizer.pos;
        const token = tokenizer.next();
        const token_start = @min(@as(usize, token.start), source.len);
        if (triviaGapHasUnterminatedBlockComment(source, previous_end, token_start)) return true;
        if (token.type == .eof) return false;
        if (tokenizer.pos <= previous_pos) return true;
        previous_end = @min(token_start + token.len, source.len);
    }
    return false;
}

fn triviaGapHasUnterminatedBlockComment(source: []const u8, start: usize, end: usize) bool {
    var offset = @min(start, end);
    while (offset + 1 < end) {
        if (source[offset] == '/' and source[offset + 1] == '/') {
            offset += 2;
            while (offset < end and source[offset] != '\n') offset += 1;
            continue;
        }
        if (source[offset] != '/' or source[offset + 1] != '*') {
            offset += 1;
            continue;
        }
        offset += 2;
        while (offset + 1 < end and !(source[offset] == '*' and source[offset + 1] == '/')) {
            offset += 1;
        }
        if (offset + 1 >= end) return true;
        offset += 2;
    }
    return false;
}

fn advance(tokenizer: *Tokenizer, current: *Token) void {
    current.* = tokenizer.next();
}

fn isTypeDeclarationWord(text: []const u8) bool {
    return std.mem.eql(u8, text, "type") or
        std.mem.eql(u8, text, "structural") or
        std.mem.eql(u8, text, "nominal") or
        std.mem.eql(u8, text, "interface");
}

fn isAnnotationDelimiter(kind: TokenType) bool {
    return kind == .assign or kind == .semicolon or kind == .eof;
}

fn isRemovedRoot(token: Token, source: []const u8) bool {
    return token.type == .kw_void or
        (token.type == .identifier and std.mem.eql(u8, token.text(source), "any"));
}

fn isRemovedSuffix(token: Token) bool {
    return token.type == .identifier or token.type == .kw_void;
}

fn scanInitializer(
    source: []const u8,
    tokenizer: *Tokenizer,
    current: *Token,
) ?OutOfSliceReason {
    var depth: u16 = 0;
    var can_end_expression = false;

    while (current.type != .eof) {
        if (current.type == .semicolon and depth == 0) return null;
        switch (current.type) {
            .number, .string_literal, .true_lit, .false_lit, .null_lit, .undefined_lit => {
                can_end_expression = true;
            },
            .identifier => {
                if (std.mem.eql(u8, current.text(source), "satisfies")) {
                    return .assertion_syntax;
                }
                can_end_expression = true;
            },
            .lparen => {
                depth +|= 1;
                can_end_expression = false;
            },
            .rparen => {
                if (depth > 0) depth -= 1;
                can_end_expression = true;
            },
            .comma,
            .plus,
            .minus,
            .star,
            .slash,
            .percent,
            .star_star,
            .eq_eq,
            .ne_ne,
            .le,
            .ge,
            .ampersand_ampersand,
            .pipe_pipe,
            .question_question,
            .tilde,
            .kw_typeof,
            .kw_void,
            => can_end_expression = false,
            .bang => {
                if (can_end_expression) return .assertion_syntax;
                can_end_expression = false;
            },
            .kw_as => return .assertion_syntax,
            .template_literal, .template_head, .template_middle, .template_tail => return .template_literal,
            .regex_literal => return .regex_literal,
            .colon => return .unsupported_annotation_position,
            else => return .unsupported_initializer,
        }
        advance(tokenizer, current);
    }
    return null;
}

fn appendAdmissionDiagnostics(
    allocator: std.mem.Allocator,
    diagnostics: *std.ArrayListUnmanaged(AdmissionDiagnostic),
    source: []const u8,
    raw_span: TypeSyntax.Span,
) !void {
    const start: usize = raw_span.start;
    const end: usize = @min(@as(usize, raw_span.end), source.len);
    try appendAnyDiagnostics(allocator, diagnostics, source, start, end);
    if (findFirstRemovedForm(source, start, end)) |diagnostic| {
        try diagnostics.append(allocator, diagnostic);
    }
}

fn appendDiagnosticAtNewPosition(
    allocator: std.mem.Allocator,
    diagnostics: *std.ArrayListUnmanaged(AdmissionDiagnostic),
    diagnostic: AdmissionDiagnostic,
) !void {
    for (diagnostics.items) |existing| {
        if (existing.span.start == diagnostic.span.start) return;
    }
    try diagnostics.append(allocator, diagnostic);
}

fn appendAnyDiagnostics(
    allocator: std.mem.Allocator,
    diagnostics: *std.ArrayListUnmanaged(AdmissionDiagnostic),
    source: []const u8,
    start: usize,
    end: usize,
) !void {
    var brace_depth: u16 = 0;
    var cursor = start;
    while (cursor < end) {
        const byte = source[cursor];
        if (byte == '"' or byte == '\'' or byte == '`') {
            cursor = try skipAnyQuoted(allocator, source, cursor, end, byte);
            continue;
        }
        if (byte == '/' and cursor + 1 < end and source[cursor + 1] == '/') {
            cursor += 2;
            while (cursor < end and source[cursor] != '\n') cursor += 1;
            continue;
        }
        if (byte == '/' and cursor + 1 < end and source[cursor + 1] == '*') {
            cursor += 2;
            while (cursor + 1 < end and !(source[cursor] == '*' and source[cursor + 1] == '/')) cursor += 1;
            cursor = @min(cursor + 2, end);
            continue;
        }
        if (byte == '{') brace_depth +|= 1;
        if (byte == '}') brace_depth -|= 1;
        if (isIdentifierStart(byte) and cursor + 3 <= end and
            std.mem.eql(u8, source[cursor .. cursor + 3], "any") and
            (cursor + 3 == end or !isIdentifierContinue(source[cursor + 3])) and
            !(brace_depth > 0 and isObjectTypeMemberKey(source, cursor, end)))
        {
            try diagnostics.append(allocator, .{
                .kind = .any_type,
                .span = .{ .start = @intCast(cursor), .end = @intCast(cursor + 3) },
            });
        }
        cursor += 1;
    }
}

fn findFirstRemovedForm(
    source: []const u8,
    start: usize,
    end: usize,
) ?AdmissionDiagnostic {
    var first_removed: ?AdmissionDiagnostic = null;
    var paren_depth: u16 = 0;
    var brace_depth: u16 = 0;
    var cursor = start;
    while (cursor < end) {
        const byte = source[cursor];
        if (byte == '"' or byte == '\'' or byte == '`') {
            cursor = skipAdmissionQuoted(source, cursor, end, byte);
            continue;
        }
        if (byte == '/' and cursor + 1 < end and source[cursor + 1] == '/') {
            cursor += 2;
            while (cursor < end and source[cursor] != '\n') cursor += 1;
            continue;
        }
        if (byte == '/' and cursor + 1 < end and source[cursor + 1] == '*') {
            cursor += 2;
            while (cursor + 1 < end and !(source[cursor] == '*' and source[cursor + 1] == '/')) cursor += 1;
            cursor = @min(cursor + 2, end);
            continue;
        }
        switch (byte) {
            '(' => paren_depth +|= 1,
            ')' => paren_depth -|= 1,
            '{' => brace_depth +|= 1,
            '}' => brace_depth -|= 1,
            '?' => if (first_removed == null and paren_depth > 0 and brace_depth == 0 and
                isOptionalParameterMarker(source, start, cursor, end))
            {
                first_removed = .{
                    .kind = .optional_parameter,
                    .span = .{ .start = @intCast(cursor), .end = @intCast(cursor + 1) },
                };
            },
            else => {},
        }
        if (first_removed != null) return first_removed;
        if (!isIdentifierStart(source[cursor])) {
            cursor += 1;
            continue;
        }
        const ident_start = cursor;
        cursor += 1;
        while (cursor < end and isIdentifierContinue(source[cursor])) cursor += 1;
        const ident = source[ident_start..cursor];
        const span: TypeSyntax.Span = .{ .start = @intCast(ident_start), .end = @intCast(cursor) };
        if (std.mem.eql(u8, ident, "void")) {
            first_removed = .{ .kind = .void_type, .span = span };
        } else if (std.mem.eql(u8, ident, "Array") or std.mem.eql(u8, ident, "ReadonlyArray")) {
            const after = skipTypeTrivia(source, cursor, end);
            if (after < end and source[after] == '<') {
                first_removed = .{
                    .kind = if (std.mem.eql(u8, ident, "Array"))
                        .array_type_alias
                    else
                        .readonly_array_type_alias,
                    .span = span,
                };
            }
        }
        if (first_removed != null) return first_removed;
    }
    return first_removed;
}

fn skipAnyQuoted(
    allocator: std.mem.Allocator,
    source: []const u8,
    start: usize,
    end: usize,
    quote: u8,
) !usize {
    if (quote != '`') return skipAdmissionQuoted(source, start, end, quote);

    var interpolation_depths: std.ArrayListUnmanaged(u32) = .empty;
    defer interpolation_depths.deinit(allocator);
    try interpolation_depths.append(allocator, 0);
    var cursor = start + 1;
    while (cursor < end) {
        if (source[cursor] == '\\' and cursor + 1 < end) {
            cursor += 2;
            continue;
        }
        const level = interpolation_depths.items.len - 1;
        if (interpolation_depths.items[level] == 0) {
            if (source[cursor] == '`') {
                _ = interpolation_depths.pop();
                cursor += 1;
                if (interpolation_depths.items.len == 0) return cursor;
                continue;
            }
            if (source[cursor] == '$' and cursor + 1 < end and source[cursor + 1] == '{') {
                interpolation_depths.items[level] = 1;
                cursor += 2;
                continue;
            }
            cursor += 1;
            continue;
        }
        if (source[cursor] == '"' or source[cursor] == '\'') {
            cursor = skipAdmissionQuoted(source, cursor, end, source[cursor]);
            continue;
        }
        if (source[cursor] == '`') {
            try interpolation_depths.append(allocator, 0);
            cursor += 1;
            continue;
        }
        if (source[cursor] == '{') interpolation_depths.items[level] += 1;
        if (source[cursor] == '}') interpolation_depths.items[level] -= 1;
        cursor += 1;
    }
    return end;
}

fn skipTypeTrivia(source: []const u8, start: usize, end: usize) usize {
    var cursor = start;
    while (cursor < end) {
        if (std.ascii.isWhitespace(source[cursor])) {
            cursor += 1;
            continue;
        }
        if (source[cursor] == '/' and cursor + 1 < end and source[cursor + 1] == '/') {
            cursor += 2;
            while (cursor < end and source[cursor] != '\n') cursor += 1;
            continue;
        }
        if (source[cursor] == '/' and cursor + 1 < end and source[cursor + 1] == '*') {
            cursor += 2;
            while (cursor + 1 < end and !(source[cursor] == '*' and source[cursor + 1] == '/')) cursor += 1;
            cursor = @min(cursor + 2, end);
            continue;
        }
        break;
    }
    return cursor;
}

fn skipAdmissionQuoted(source: []const u8, start: usize, end: usize, quote: u8) usize {
    var cursor = start + 1;
    while (cursor < end) {
        if (source[cursor] == '\\' and cursor + 1 < end) {
            cursor += 2;
            continue;
        }
        if (source[cursor] == quote) return cursor + 1;
        cursor += 1;
    }
    return end;
}

fn isObjectTypeMemberKey(source: []const u8, start: usize, end: usize) bool {
    var cursor = start;
    while (cursor < end and isIdentifierContinue(source[cursor])) cursor += 1;
    while (cursor < end and (source[cursor] == ' ' or source[cursor] == '\t')) cursor += 1;
    if (cursor < end and source[cursor] == '?') {
        cursor += 1;
        while (cursor < end and (source[cursor] == ' ' or source[cursor] == '\t')) cursor += 1;
    }
    return cursor < end and (source[cursor] == ':' or source[cursor] == '(');
}

fn isOptionalParameterMarker(
    source: []const u8,
    start: usize,
    marker: usize,
    end: usize,
) bool {
    var before = marker;
    while (before > start and std.ascii.isWhitespace(source[before - 1])) before -= 1;
    if (before == start or !isIdentifierContinue(source[before - 1])) return false;
    var after = marker + 1;
    while (after < end and std.ascii.isWhitespace(source[after])) after += 1;
    return after < end and source[after] == ':';
}

fn isIdentifierStart(byte: u8) bool {
    return std.ascii.isAlphabetic(byte) or byte == '_' or byte == '$';
}

fn startsWithTypeComment(source: []const u8, start: u32) bool {
    var cursor: usize = @min(@as(usize, start), source.len);
    while (cursor < source.len and std.ascii.isWhitespace(source[cursor])) cursor += 1;
    return cursor + 1 < source.len and source[cursor] == '/' and
        (source[cursor + 1] == '/' or source[cursor + 1] == '*');
}

fn isIdentifierContinue(byte: u8) bool {
    return isIdentifierStart(byte) or std.ascii.isDigit(byte);
}

fn tokenSpan(token: Token) TypeSyntax.Span {
    return .{ .start = token.start, .end = token.start + token.len };
}

fn compare(
    allocator: std.mem.Allocator,
    source: []const u8,
    mode: AdmissionMode,
) !Verdict {
    var checked = switch (try preflight(allocator, source, mode)) {
        .eligible => |eligible| eligible,
        .out_of_slice => |reason| return .{ .out_of_slice = reason },
    };
    defer checked.deinit(allocator);

    if (checked.diagnostics.items.len > 0) {
        if (!try legacyAdmissionMatches(allocator, source, mode, checked.diagnostics.items)) {
            return .{ .differs = "direct and legacy admission diagnostics differ" };
        }
        return .{ .admission_refused = .{
            .first = checked.diagnostics.items[0].kind,
            .count = checked.diagnostics.items.len,
        } };
    }

    var prepared = try PreparedSource.init(allocator, source, "<typed-compare>.ts", .{});
    defer prepared.deinit();

    var legacy_alloc = CountingAllocator.init(allocator);
    var direct_alloc = CountingAllocator.init(allocator);
    var type_alloc = CountingAllocator.init(allocator);

    var legacy_atoms = AtomTable.init(legacy_alloc.allocator());
    defer legacy_atoms.deinit();
    var direct_atoms = AtomTable.init(direct_alloc.allocator());
    defer direct_atoms.deinit();

    var legacy = try JsParser.init(legacy_alloc.allocator(), prepared.parserInput());
    defer legacy.deinit();
    legacy.setAtomTable(&legacy_atoms);

    var direct = try JsParser.initTyped(
        direct_alloc.allocator(),
        type_alloc.allocator(),
        source,
    );
    defer direct.deinit();
    direct.setAtomTable(&direct_atoms);

    var legacy_error: ?anyerror = null;
    const legacy_root = legacy.parse() catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => blk: {
            legacy_error = err;
            break :blk null;
        },
    };
    var direct_error: ?anyerror = null;
    const direct_root = direct.parse() catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => blk: {
            direct_error = err;
            break :blk null;
        },
    };

    if (legacy_root == null or direct_root == null) {
        if (legacy_root != null or direct_root != null) {
            return .{ .differs = "only one runtime parser accepted the source" };
        }
        if (legacy_error != direct_error) {
            return .{ .differs = "runtime parser error tags differ" };
        }
        if (!sameParseErrors(&legacy, &direct)) {
            return .{ .differs = "runtime parser errors differ" };
        }
        if (!legacy_alloc.sameRuntimeShape(direct_alloc)) {
            return .{ .differs = "runtime allocation shapes differ after refusal" };
        }
        return .equivalent;
    }

    if (compareRuntime(
        &legacy,
        legacy_root.?,
        &legacy_atoms,
        &direct,
        direct_root.?,
        &direct_atoms,
    )) |difference| {
        return .{ .differs = difference };
    }
    if (!legacy_alloc.sameRuntimeShape(direct_alloc)) {
        return .{ .differs = "runtime allocation shapes differ" };
    }
    if (direct.type_store.annotations.items.len == 0 and direct.type_store.declarations.items.len == 0) {
        return .{ .differs = "the direct parser retained no type syntax" };
    }
    if (!try compareLowering(allocator, &prepared, &direct.type_store)) {
        return .{ .differs = "direct and legacy type lowering differ" };
    }
    if (type_alloc.alloc_calls == 0) {
        return .{ .differs = "the type store did not use its separate allocator" };
    }
    return .equivalent;
}

fn legacyAdmissionMatches(
    allocator: std.mem.Allocator,
    source: []const u8,
    mode: AdmissionMode,
    direct: []const AdmissionDiagnostic,
) !bool {
    var first: ?engine.stripper.StripDiagnostic = null;
    var prepared = PreparedSource.init(allocator, source, "<typed-compare>.ts", .{
        .diagnostic_out = &first,
        .collect_all_diagnostics = mode == .collect,
    }) catch |err| {
        switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {},
        }
        if (first == null or direct.len != 1) return false;
        return admissionMatchesStrip(source, direct[0], first.?);
    };
    defer prepared.deinit();

    const legacy = prepared.stripDiagnostics();
    if (legacy.len != direct.len) return false;
    for (legacy, direct) |legacy_diagnostic, direct_diagnostic| {
        if (!admissionMatchesStrip(source, direct_diagnostic, legacy_diagnostic)) return false;
    }
    return true;
}

fn admissionMatchesStrip(
    source: []const u8,
    direct: AdmissionDiagnostic,
    legacy: engine.stripper.StripDiagnostic,
) bool {
    const legacy_kind: AdmissionKind = switch (legacy.kind) {
        .any_type => .any_type,
        .void_type => .void_type,
        .array_type_alias => .array_type_alias,
        .readonly_array_type_alias => .readonly_array_type_alias,
        .optional_parameter => .optional_parameter,
        .nesting_too_deep => .nesting_too_deep,
        .nominal_base_not_scalar => .nominal_base_not_scalar,
        else => return false,
    };
    if (legacy_kind != direct.kind) return false;
    const position = positionOf(source, direct.span.start);
    return legacy.line == position.line and legacy.column == position.column;
}

fn positionOf(source: []const u8, offset: u32) struct { line: u32, column: u32 } {
    var line: u32 = 1;
    var column: u32 = 1;
    for (source[0..@min(@as(usize, offset), source.len)]) |byte| {
        if (byte == '\n') {
            line += 1;
            column = 1;
        } else {
            column += 1;
        }
    }
    return .{ .line = line, .column = column };
}

fn sameParseErrors(left: *const JsParser, right: *const JsParser) bool {
    const left_errors = left.errors.getErrors();
    const right_errors = right.errors.getErrors();
    if (left_errors.len != right_errors.len) return false;
    for (left_errors, right_errors) |a, b| {
        if (a.kind != b.kind or !std.meta.eql(a.location, b.location)) return false;
        if (!std.mem.eql(u8, a.message, b.message)) return false;
        if (!equalOptionalText(a.token_text, b.token_text)) return false;
        if (!equalOptionalText(a.expected, b.expected)) return false;
        if (!equalOptionalText(a.suggestion, b.suggestion)) return false;
    }
    return true;
}

fn equalOptionalText(left: ?[]const u8, right: ?[]const u8) bool {
    if (left == null or right == null) return left == null and right == null;
    return std.mem.eql(u8, left.?, right.?);
}

fn compareRuntime(
    left: *const JsParser,
    left_root: NodeIndex,
    left_atoms: *AtomTable,
    right: *const JsParser,
    right_root: NodeIndex,
    right_atoms: *AtomTable,
) ?[]const u8 {
    if (left_root != right_root) return "runtime roots differ";

    if (!equalSlices(engine.parser.NodeTag, left.nodes.tags.items, right.nodes.tags.items)) {
        return "runtime node tags differ";
    }
    if (!equalLocations(left.nodes.locs.items, right.nodes.locs.items)) {
        return "runtime node locations differ";
    }
    if (!equalPayloads(left.nodes.data.items, right.nodes.data.items)) {
        return "runtime node payloads differ";
    }
    if (!equalSlices(u16, left.nodes.binding_name_atoms.items, right.nodes.binding_name_atoms.items)) {
        return "runtime binding atom payloads differ";
    }
    if (!equalSlices(u32, left.nodes.extra.items, right.nodes.extra.items)) {
        return "runtime extra payload lists differ";
    }
    if (!equalSlices(NodeIndex, left.nodes.index_lists.items, right.nodes.index_lists.items)) {
        return "runtime node index lists differ";
    }
    if (!equalConstants(&left.constants, &right.constants)) return "runtime constants differ";
    if (!equalScopes(&left.scopes, &right.scopes)) return "runtime scopes or bindings differ";
    if (!equalAtoms(left_atoms, right_atoms)) return "runtime dynamic atoms differ";
    return null;
}

fn equalSlices(comptime T: type, left: []const T, right: []const T) bool {
    if (left.len != right.len) return false;
    for (left, right) |a, b| {
        if (a != b) return false;
    }
    return true;
}

fn equalLocations(
    left: []const engine.parser.SourceLocation,
    right: []const engine.parser.SourceLocation,
) bool {
    if (left.len != right.len) return false;
    for (left, right) |a, b| {
        if (!std.meta.eql(a, b)) return false;
    }
    return true;
}

fn equalPayloads(
    left: []const engine.parser.DataPayload,
    right: []const engine.parser.DataPayload,
) bool {
    if (left.len != right.len) return false;
    for (left, right) |a, b| {
        if (a.a != b.a or a.b != b.b) return false;
    }
    return true;
}

fn equalConstants(
    left: *const engine.parser.ConstantPool,
    right: *const engine.parser.ConstantPool,
) bool {
    if (left.strings.items.len != right.strings.items.len) return false;
    for (left.strings.items, right.strings.items) |a, b| {
        if (!std.mem.eql(u8, a, b)) return false;
    }
    if (left.floats.items.len != right.floats.items.len) return false;
    for (left.floats.items, right.floats.items) |a, b| {
        if (@as(u64, @bitCast(a)) != @as(u64, @bitCast(b))) return false;
    }
    return true;
}

fn equalScopes(
    left: *const engine.parser.ScopeAnalyzer,
    right: *const engine.parser.ScopeAnalyzer,
) bool {
    if (left.current_scope != right.current_scope or left.next_scope_id != right.next_scope_id) return false;
    if (left.scopes.items.len != right.scopes.items.len) return false;
    for (left.scopes.items, right.scopes.items) |a, b| {
        if (a.id != b.id or a.parent != b.parent or a.kind != b.kind) return false;
        if (a.enclosing_function != b.enclosing_function) return false;
        if (a.max_local_count != b.max_local_count or a.current_local_slot != b.current_local_slot) return false;
        if (a.bindings.items.len != b.bindings.items.len or a.upvalues.items.len != b.upvalues.items.len) return false;
        for (a.bindings.items, b.bindings.items) |ab, bb| {
            if (!std.mem.eql(u8, ab.name, bb.name)) return false;
            if (ab.name_atom != bb.name_atom or ab.slot != bb.slot or ab.kind != bb.kind) return false;
            if (ab.is_const != bb.is_const or ab.is_captured != bb.is_captured) return false;
        }
        for (a.upvalues.items, b.upvalues.items) |au, bu| {
            if (au.source_scope_id != bu.source_scope_id or au.source_slot != bu.source_slot) return false;
            if (au.slot != bu.slot or !equalCapture(au.capture, bu.capture)) return false;
            if (!std.mem.eql(u8, au.name, bu.name)) return false;
        }
    }
    return true;
}

fn equalCapture(
    left: engine.parser.Upvalue.Capture,
    right: engine.parser.Upvalue.Capture,
) bool {
    return switch (left) {
        .local => |slot| switch (right) {
            .local => |other| slot == other,
            else => false,
        },
        .upvalue => |slot| switch (right) {
            .upvalue => |other| slot == other,
            else => false,
        },
    };
}

fn equalAtoms(left: *AtomTable, right: *AtomTable) bool {
    if (left.count() != right.count() or left.next_id != right.next_id) return false;
    var raw = engine.object.Atom.FIRST_DYNAMIC;
    while (raw < left.next_id) : (raw += 1) {
        const atom: engine.object.Atom = @enumFromInt(raw);
        const left_name = left.getName(atom) orelse return false;
        const right_name = right.getName(atom) orelse return false;
        if (!std.mem.eql(u8, left_name, right_name)) return false;
    }
    return true;
}

fn compareLowering(
    allocator: std.mem.Allocator,
    prepared: *PreparedSource,
    direct_store: *const TypeSyntax.Store,
) !bool {
    var legacy_pool = TypePool.init(allocator);
    defer legacy_pool.deinit(allocator);
    try legacy_pool.ensureHealthy();
    var legacy_env = TypeEnv.init(allocator, &legacy_pool);
    defer legacy_env.deinit();
    try legacy_pool.ensureHealthy();
    try legacy_env.ensureHealthy();
    module_types.populateModuleTypes(&legacy_env, &legacy_pool, allocator);
    abi_types.populateHandlerAbiTypes(&legacy_env, &legacy_pool, allocator);
    legacy_env.populateFromTypeMap(prepared.typeMap() orelse return false);
    try legacy_pool.ensureHealthy();
    try legacy_env.ensureHealthy();

    var direct_pool = TypePool.init(allocator);
    defer direct_pool.deinit(allocator);
    try direct_pool.ensureHealthy();
    var direct_env = TypeEnv.init(allocator, &direct_pool);
    defer direct_env.deinit();
    try direct_pool.ensureHealthy();
    try direct_env.ensureHealthy();
    module_types.populateModuleTypes(&direct_env, &direct_pool, allocator);
    abi_types.populateHandlerAbiTypes(&direct_env, &direct_pool, allocator);
    try lowerSyntaxStore(allocator, direct_store, &direct_pool, &direct_env);
    const type_map = prepared.typeMap() orelse return false;

    var declaration_index: usize = 0;
    for (type_map.entries.items) |entry| {
        if (entry.kind != .type_alias and entry.kind != .distinct_type) continue;
        if (declaration_index >= direct_store.declarations.items.len) return false;
        const declaration = direct_store.declarations.items[declaration_index];
        if (declaration.source_order != @as(u32, @intCast(declaration_index))) return false;
        const expected_kind: TypeSyntax.DeclarationKind = if (entry.kind == .type_alias)
            .structural
        else
            .nominal;
        if (declaration.kind != expected_kind) return false;
        const legacy_name = type_map.getNameText(entry) orelse return false;
        if (!std.mem.eql(u8, legacy_name, declaration.name_span.text(direct_store.source))) return false;
        const legacy_body = std.mem.trim(u8, type_map.getTypeText(entry), " \t\r\n");
        switch (declaration.body) {
            .absent => if (legacy_body.len != 0) return false,
            .present => |body| if (!std.mem.eql(
                u8,
                legacy_body,
                body.raw_span.text(direct_store.source),
            )) return false,
        }
        declaration_index += 1;
    }
    if (declaration_index != direct_store.declarations.items.len) return false;

    if (legacy_env.type_aliases.count() != direct_env.type_aliases.count()) return false;
    var legacy_aliases = legacy_env.type_aliases.iterator();
    while (legacy_aliases.next()) |entry| {
        const direct_alias = direct_env.getTypeAlias(entry.key_ptr.*) orelse return false;
        if (!try orderedTypeEqual(
            allocator,
            &legacy_pool,
            entry.value_ptr.*,
            &direct_pool,
            direct_alias,
        )) return false;
        if (legacy_env.isNonContractiveType(entry.value_ptr.*) !=
            direct_env.isNonContractiveType(direct_alias)) return false;
        if (legacy_env.isNonContractiveAlias(entry.key_ptr.*) !=
            direct_env.isNonContractiveAlias(entry.key_ptr.*)) return false;
    }
    var direct_aliases = direct_env.type_aliases.iterator();
    while (direct_aliases.next()) |entry| {
        if (legacy_env.getTypeAlias(entry.key_ptr.*) == null) return false;
    }

    var annotation_index: usize = 0;
    for (type_map.entries.items) |entry| {
        if (entry.kind != .var_annotation) continue;
        if (annotation_index >= direct_store.annotations.items.len) return false;
        const name = type_map.getNameText(entry) orelse continue;
        const ordinal = entry.name_ordinal orelse continue;
        const legacy_idx = legacy_env.getVarTypeByNameOrdinal(name, ordinal) orelse return false;
        const direct_annotation = direct_store.annotations.items[annotation_index];
        const direct_idx = direct_env.getVarTypeByBinding(
            direct_annotation.binding.scope_id,
            direct_annotation.binding.name_atom,
        ) orelse return false;
        if (!try orderedTypeEqual(allocator, &legacy_pool, legacy_idx, &direct_pool, direct_idx)) {
            return false;
        }
        if (!try supplementaryTypeKeyEqual(
            allocator,
            &legacy_pool,
            legacy_idx,
            &direct_pool,
            direct_idx,
        )) return false;
        annotation_index += 1;
    }
    return annotation_index == direct_store.annotations.items.len;
}

fn supplementaryTypeKeyEqual(
    allocator: std.mem.Allocator,
    left_pool: *TypePool,
    left_index: TypeIndex,
    right_pool: *TypePool,
    right_index: TypeIndex,
) !bool {
    const legacy_key = comparisonTypeKey(left_pool, allocator, left_index);
    const direct_key = comparisonTypeKey(right_pool, allocator, right_index);
    if (legacy_key) |left| {
        const right = direct_key catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => return false,
        };
        return std.mem.eql(u8, left, right);
    } else |left_error| {
        switch (left_error) {
            error.OutOfMemory => return left_error,
            else => {},
        }
        _ = direct_key catch |right_error| {
            switch (right_error) {
                error.OutOfMemory => return right_error,
                else => {},
            }
            return left_error == right_error;
        };
        return false;
    }
}

fn comparisonTypeKey(
    pool: *TypePool,
    allocator: std.mem.Allocator,
    index: TypeIndex,
) type_key.KeyError![]const u8 {
    return type_key.typeKey(pool, allocator, index) catch |err| switch (err) {
        // The allocating writer reports an allocation refusal as WriteFailed.
        // This private comparator normalizes that operational failure.
        error.WriteFailed => return error.OutOfMemory,
        else => return err,
    };
}

fn lowerSyntaxStore(
    allocator: std.mem.Allocator,
    store: *const TypeSyntax.Store,
    pool: *TypePool,
    env: *TypeEnv,
) !void {
    try pool.ensureHealthy();
    try env.ensureHealthy();
    try store.validate();

    const lowered = try allocator.alloc(TypeIndex, store.nodes.items.len);
    defer allocator.free(lowered);
    @memset(lowered, null_type_idx);

    for (store.declarations.items) |declaration| {
        const present = switch (declaration.body) {
            .absent => continue,
            .present => |body| body,
        };
        const type_idx = try lowerOwnedRoot(
            allocator,
            store,
            pool,
            env,
            lowered,
            present.root,
            present.node_range,
            present.raw_span,
        );
        const name = declaration.name_span.text(store.source);
        switch (declaration.kind) {
            .structural => env.putTypeAlias(name, type_idx),
            .nominal => {
                if (type_idx != null_type_idx) {
                    const nominal = pool.addNominalAlias(allocator, type_idx, name);
                    if (nominal != null_type_idx) env.putTypeAlias(name, nominal);
                }
            },
        }
        try pool.ensureHealthy();
        try env.ensureHealthy();
    }
    env.finishTypeAliasPopulation();
    try env.ensureHealthy();

    for (store.annotations.items) |annotation| {
        const type_idx = try lowerOwnedRoot(
            allocator,
            store,
            pool,
            env,
            lowered,
            annotation.root,
            annotation.node_range,
            annotation.raw_span,
        );
        try env.bindVarType(annotation.binding.scope_id, annotation.binding.name_atom, type_idx);
    }
    try pool.ensureHealthy();
    try env.ensureHealthy();
}

fn lowerOwnedRoot(
    allocator: std.mem.Allocator,
    store: *const TypeSyntax.Store,
    pool: *TypePool,
    env: *TypeEnv,
    lowered: []TypeIndex,
    root: TypeSyntax.Child,
    node_range: TypeSyntax.Range,
    raw_span: TypeSyntax.Span,
) !TypeIndex {
    const exact = std.mem.trim(u8, raw_span.text(store.source), " \t\r\n");
    if (env.getTypeAlias(exact)) |type_idx| return type_idx;
    try lowerOwnedRange(allocator, store, pool, lowered, node_range);
    return env.finishParsedTypeRoot(try loweredChild(lowered, root, lowered.len));
}

fn lowerOwnedRange(
    allocator: std.mem.Allocator,
    store: *const TypeSyntax.Store,
    pool: *TypePool,
    lowered: []TypeIndex,
    node_range: TypeSyntax.Range,
) !void {
    const start: usize = node_range.start;
    const end = std.math.add(usize, start, node_range.count) catch return error.InvalidTypeRange;
    if (end > store.nodes.items.len or end > lowered.len) return error.InvalidTypeRange;
    for (store.nodes.items[start..end], start..) |node, index| {
        lowered[index] = switch (node.data) {
            .primitive => |primitive| primitiveIndex(pool, primitive),
            .named_reference => |span| pool.addRef(allocator, span.text(store.source)),
            .group => |child| try loweredChild(lowered, child, index),
            .readonly_modifier => |child| blk: {
                const inner = try loweredChild(lowered, child, index);
                if (pool.getTag(inner) == .t_array and !pool.isReadonlyArray(inner)) {
                    break :blk pool.addReadonlyArray(allocator, pool.getArrayElement(inner));
                }
                if (pool.getTag(inner) == .t_ref or pool.getTag(inner) == .t_generic_app) {
                    const base = pool.addRef(allocator, "Readonly");
                    break :blk pool.addGenericApp(allocator, base, &.{inner});
                }
                break :blk inner;
            },
            .record => |range| blk: {
                const fields = store.fieldSlice(range) orelse return error.InvalidTypeRange;
                var result: std.ArrayListUnmanaged(RecordField) = .empty;
                defer result.deinit(allocator);
                try result.ensureTotalCapacity(allocator, fields.len);
                for (fields) |field| {
                    const name = pool.addName(allocator, field.name.text(store.source));
                    result.appendAssumeCapacity(.{
                        .name_start = name.start,
                        .name_len = name.len,
                        .type_idx = try loweredChild(lowered, field.type_child, index),
                        .optional = field.optional,
                        .readonly = field.readonly,
                    });
                }
                break :blk pool.addRecord(allocator, result.items);
            },
            .array => |child| blk: {
                const element = try loweredChild(lowered, child, index);
                if (element == null_type_idx) break :blk null_type_idx;
                break :blk pool.addArray(allocator, element);
            },
            .tuple => |range| blk: {
                const elements = store.memberSlice(range) orelse return error.InvalidTypeRange;
                var result: std.ArrayListUnmanaged(TypeIndex) = .empty;
                defer result.deinit(allocator);
                try result.ensureTotalCapacity(allocator, elements.len);
                for (elements) |element| {
                    const child = try loweredChild(lowered, element, index);
                    if (child == null_type_idx) break;
                    result.appendAssumeCapacity(child);
                }
                break :blk pool.addTuple(allocator, result.items);
            },
            .function => |function| blk: {
                const params = store.paramSlice(function.params) orelse return error.InvalidTypeRange;
                var result: std.ArrayListUnmanaged(FuncParam) = .empty;
                defer result.deinit(allocator);
                try result.ensureTotalCapacity(allocator, params.len);
                for (params) |parameter| {
                    const name = pool.addName(allocator, parameter.name.text(store.source));
                    result.appendAssumeCapacity(.{
                        .name_start = name.start,
                        .name_len = name.len,
                        .type_idx = try loweredChild(lowered, parameter.type_child, index),
                        .optional = parameter.optional,
                    });
                }
                break :blk pool.addFunctionWithReturn(
                    allocator,
                    result.items,
                    try loweredChild(lowered, function.ret, index),
                );
            },
            .union_type => |range| try lowerJoin(allocator, store, pool, lowered, index, range, true),
            .intersection => |range| try lowerJoin(allocator, store, pool, lowered, index, range, false),
            .literal_string => |span| pool.addLiteralString(allocator, span.text(store.source)),
            .literal_number => |value| pool.addLiteralNumber(allocator, value),
            .literal_bool => |value| pool.addLiteralBool(allocator, value),
            .template => |range| blk: {
                const parts = store.templatePartSlice(range) orelse return error.InvalidTypeRange;
                var result: std.ArrayListUnmanaged(PoolTemplatePart) = .empty;
                defer result.deinit(allocator);
                try result.ensureTotalCapacity(allocator, parts.len);
                for (parts) |part| switch (part) {
                    .literal => |span| {
                        const name = pool.addName(allocator, span.text(store.source));
                        result.appendAssumeCapacity(.{
                            .kind = .literal,
                            .name_start = name.start,
                            .name_len = name.len,
                        });
                    },
                    .type_slot => |child| result.appendAssumeCapacity(.{
                        .kind = .type_slot,
                        .type_idx = try loweredChild(lowered, child, index),
                    }),
                };
                break :blk pool.addTemplateLiteral(allocator, result.items);
            },
        };
        try pool.ensureHealthy();
    }
}

fn loweredChild(lowered: []const TypeIndex, child: TypeSyntax.Child, parent: usize) !TypeIndex {
    return switch (child) {
        .absent => null_type_idx,
        .present => |index| if (@as(usize, index) < parent and @as(usize, index) < lowered.len)
            lowered[index]
        else
            error.InvalidTypeChild,
    };
}

fn lowerJoin(
    allocator: std.mem.Allocator,
    store: *const TypeSyntax.Store,
    pool: *TypePool,
    lowered: []const TypeIndex,
    parent: usize,
    range: TypeSyntax.Range,
    is_union: bool,
) !TypeIndex {
    const children = store.memberSlice(range) orelse return error.InvalidTypeRange;
    var members: std.ArrayListUnmanaged(TypeIndex) = .empty;
    defer members.deinit(allocator);
    try members.ensureTotalCapacity(allocator, children.len);
    for (children, 0..) |child, member_index| {
        const member = try loweredChild(lowered, child, parent);
        if (member == null_type_idx) {
            if (member_index == 0) return null_type_idx;
            break;
        }
        members.appendAssumeCapacity(member);
    }
    if (is_union and members.items.len == 2) {
        if (pool.getTag(members.items[1]) == .t_undefined) {
            return pool.addNullable(allocator, members.items[0]);
        }
        if (pool.getTag(members.items[0]) == .t_undefined) {
            return pool.addNullable(allocator, members.items[1]);
        }
    }
    return if (is_union)
        pool.addUnion(allocator, members.items)
    else
        pool.addIntersection(allocator, members.items);
}

fn primitiveIndex(pool: *const TypePool, primitive: TypeSyntax.Primitive) TypeIndex {
    return switch (primitive) {
        .unknown => pool.idx_unknown,
        .never => pool.idx_never,
        .undefined => pool.idx_undefined,
        .null => pool.idx_null,
        .boolean => pool.idx_boolean,
        .number => pool.idx_number,
        .string => pool.idx_string,
        .bytes => pool.idx_bytes,
    };
}

const TypePair = struct {
    left: TypeIndex,
    right: TypeIndex,
};

fn orderedTypeEqual(
    allocator: std.mem.Allocator,
    left_pool: *const TypePool,
    left_root: TypeIndex,
    right_pool: *const TypePool,
    right_root: TypeIndex,
) !bool {
    try left_pool.ensureHealthy();
    try right_pool.ensureHealthy();
    var pending: std.ArrayListUnmanaged(TypePair) = .empty;
    defer pending.deinit(allocator);
    try pending.append(allocator, .{ .left = left_root, .right = right_root });

    while (pending.pop()) |pair| {
        if (pair.left == null_type_idx or pair.right == null_type_idx) {
            if (pair.left != pair.right) return false;
            continue;
        }
        const left_nominal = left_pool.isNominal(pair.left);
        const right_nominal = right_pool.isNominal(pair.right);
        if (left_nominal != right_nominal) return false;
        if (left_nominal and !std.mem.eql(
            u8,
            left_pool.nominalName(pair.left),
            right_pool.nominalName(pair.right),
        )) return false;
        const left_tag = left_pool.getTag(pair.left) orelse return false;
        const right_tag = right_pool.getTag(pair.right) orelse return false;
        if (left_tag != right_tag) return false;
        switch (left_tag) {
            .t_boolean,
            .t_number,
            .t_string,
            .t_null,
            .t_bytes,
            .t_undefined,
            .t_void,
            .t_never,
            .t_unknown_type,
            .t_error,
            => {},
            .t_record => {
                const left = left_pool.getRecordFields(pair.left);
                const right = right_pool.getRecordFields(pair.right);
                if (left.len != right.len) return false;
                for (left, right) |a, b| {
                    if (!std.mem.eql(
                        u8,
                        left_pool.getName(a.name_start, a.name_len),
                        right_pool.getName(b.name_start, b.name_len),
                    )) return false;
                    if (a.optional != b.optional or a.readonly != b.readonly) return false;
                    try pending.append(allocator, .{ .left = a.type_idx, .right = b.type_idx });
                }
            },
            .t_array => {
                if (left_pool.isReadonlyArray(pair.left) != right_pool.isReadonlyArray(pair.right)) return false;
                try pending.append(allocator, .{
                    .left = left_pool.getArrayElement(pair.left),
                    .right = right_pool.getArrayElement(pair.right),
                });
            },
            .t_tuple => {
                const left = left_pool.getTupleElements(pair.left);
                const right = right_pool.getTupleElements(pair.right);
                if (left.len != right.len) return false;
                for (left, right) |a, b| try pending.append(allocator, .{ .left = a, .right = b });
            },
            .t_function => {
                const left = left_pool.getFunctionInfo(pair.left);
                const right = right_pool.getFunctionInfo(pair.right);
                if (left.params.len != right.params.len) return false;
                for (left.params, right.params) |a, b| {
                    if (!std.mem.eql(
                        u8,
                        left_pool.getName(a.name_start, a.name_len),
                        right_pool.getName(b.name_start, b.name_len),
                    )) return false;
                    if (a.optional != b.optional) return false;
                    try pending.append(allocator, .{ .left = a.type_idx, .right = b.type_idx });
                }
                try pending.append(allocator, .{ .left = left.ret, .right = right.ret });
            },
            .t_union => {
                const left = left_pool.getUnionMembers(pair.left);
                const right = right_pool.getUnionMembers(pair.right);
                if (left.len != right.len) return false;
                for (left, right) |a, b| try pending.append(allocator, .{ .left = a, .right = b });
            },
            .t_intersection => {
                const left = left_pool.getIntersectionMembers(pair.left);
                const right = right_pool.getIntersectionMembers(pair.right);
                if (left.len != right.len) return false;
                for (left, right) |a, b| try pending.append(allocator, .{ .left = a, .right = b });
            },
            .t_literal_string => {
                const left = left_pool.getLiteralStringValue(pair.left) orelse return false;
                const right = right_pool.getLiteralStringValue(pair.right) orelse return false;
                if (!std.mem.eql(u8, left, right)) return false;
            },
            .t_literal_number, .t_literal_bool => {
                const left = left_pool.getData(pair.left) orelse return false;
                const right = right_pool.getData(pair.right) orelse return false;
                if (!std.meta.eql(left, right)) return false;
            },
            .t_template_literal => {
                const left = left_pool.getTemplateParts(pair.left);
                const right = right_pool.getTemplateParts(pair.right);
                if (left.len != right.len) return false;
                for (left, right) |a, b| {
                    if (a.kind != b.kind) return false;
                    switch (a.kind) {
                        .literal => if (!std.mem.eql(
                            u8,
                            left_pool.getName(a.name_start, a.name_len),
                            right_pool.getName(b.name_start, b.name_len),
                        )) return false,
                        .type_slot => try pending.append(allocator, .{
                            .left = a.type_idx,
                            .right = b.type_idx,
                        }),
                    }
                }
            },
            .t_nullable => try pending.append(allocator, .{
                .left = left_pool.getNullableInner(pair.left),
                .right = right_pool.getNullableInner(pair.right),
            }),
            .t_ref => if (!std.mem.eql(
                u8,
                left_pool.getRefName(pair.left),
                right_pool.getRefName(pair.right),
            )) return false,
            .t_generic_app => {
                const left = left_pool.getGenericAppInfo(pair.left);
                const right = right_pool.getGenericAppInfo(pair.right);
                if (left.args.len != right.args.len) return false;
                try pending.append(allocator, .{ .left = left.base, .right = right.base });
                for (left.args, right.args) |left_arg, right_arg| {
                    try pending.append(allocator, .{ .left = left_arg, .right = right_arg });
                }
            },
            .t_dict, .t_generic_param => return false,
        }
    }
    return true;
}

const CountingAllocator = struct {
    backing: std.mem.Allocator,
    alloc_calls: usize = 0,
    resize_calls: usize = 0,
    remap_calls: usize = 0,
    free_calls: usize = 0,
    live_bytes: usize = 0,

    fn init(backing: std.mem.Allocator) CountingAllocator {
        return .{ .backing = backing };
    }

    fn allocator(self: *CountingAllocator) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = countAlloc,
                .resize = countResize,
                .remap = countRemap,
                .free = countFree,
            },
        };
    }

    fn sameRuntimeShape(self: CountingAllocator, other: CountingAllocator) bool {
        return self.alloc_calls == other.alloc_calls and
            self.resize_calls == other.resize_calls and
            self.remap_calls == other.remap_calls and
            self.free_calls == other.free_calls and
            self.live_bytes == other.live_bytes;
    }

    fn countAlloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        const result = self.backing.rawAlloc(len, alignment, ra) orelse return null;
        self.alloc_calls += 1;
        self.live_bytes += len;
        return result;
    }

    fn countResize(
        ctx: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        ra: usize,
    ) bool {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        if (!self.backing.rawResize(memory, alignment, new_len, ra)) return false;
        self.resize_calls += 1;
        self.live_bytes = self.live_bytes - memory.len + new_len;
        return true;
    }

    fn countRemap(
        ctx: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        ra: usize,
    ) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        const result = self.backing.rawRemap(memory, alignment, new_len, ra) orelse return null;
        self.remap_calls += 1;
        self.live_bytes = self.live_bytes - memory.len + new_len;
        return result;
    }

    fn countFree(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ra: usize) void {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.free_calls += 1;
        self.live_bytes -= memory.len;
        self.backing.rawFree(memory, alignment, ra);
    }
};

fn expectEquivalent(source: []const u8) !void {
    const verdict = try compare(std.testing.allocator, source, .collect);
    switch (verdict) {
        .equivalent => {},
        else => return error.TestUnexpectedResult,
    }
}

fn expectDirectAbsentPrefix(annotation: []const u8, expected_prefix: []const u8) !void {
    const allocator = std.testing.allocator;
    const source = try std.fmt.allocPrint(allocator, "{s} = value;", .{annotation});
    defer allocator.free(source);
    var store = TypeSyntax.Store.init(allocator, source);
    defer store.deinit();
    var cursor = TypeSyntax.Cursor.init(source);
    const parsed = switch (try TypeSyntax.parseAndStore(
        &store,
        .global(300),
        source,
        0,
        &cursor,
    )) {
        .parsed => |value| value,
        .failure, .excluded => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqualStrings(expected_prefix, parsed.semantic_span.text(source));

    var pool = TypePool.init(allocator);
    defer pool.deinit(allocator);
    var env = TypeEnv.init(allocator, &pool);
    defer env.deinit();
    try lowerSyntaxStore(allocator, &store, &pool, &env);
    try std.testing.expectEqual(
        null_type_idx,
        env.getVarTypeByBinding(0, 300) orelse return error.TestUnexpectedResult,
    );
    try pool.ensureHealthy();
    try env.ensureHealthy();
}

const DeclarationCase = enum {
    structural_alias,
    nominal_alias,
    exported_structural_alias,
    exported_nominal_alias,
    root_boundary,
    root_leading_space_refusal,
    after_newline_refusal,
    after_semicolon_refusal,
    block_left_aligned,
    block_indented_refusal,
    runtime_structural_collision,
    runtime_nominal_collision,
    empty_body_no_alias,
    present_absent_body_null_alias,
    exact_eager_alias,
    forward_deferred_ref,
    nested_deferred_ref,
    suffixed_deferred_ref,
    last_write_alias,
    builtin_before_source,
    abi_before_source,
    primitive_alias_declaration_root,
    primitive_alias_annotation_root,
    primitive_alias_nominal_base,
    primitive_alias_nested_child,
    readonly_named_root,
    readonly_named_union,
    readonly_named_intersection,
    readonly_named_nullable,
    readonly_named_record_terminal,
    readonly_named_tuple_terminal,
    named_array_one_suffix,
    grouped_named_array_repeated_suffix,
    nominal_same_name_same_base,
    nominal_different_name_same_base,
    nominal_to_base,
    base_to_nominal,
    nominal_long_name,
    direct_cycle,
    union_cycle,
    intersection_cycle,
    nullable_cycle,
    function_cycle,
    record_guard,
    tuple_guard,
    array_guard,
    final_replacement_contractivity,
    repeated_population_additive,
    contractivity_path_limit,
    resolution_hop_limit,
    ref_structural_compare,
    generic_app_structural_compare,
    nominal_structural_compare,
    generic_declaration_exclusion,
    unsupported_legacy_spelling_refusal,
    invalid_nominal_base_refusal,
};

const DeclarationProbe = union(enum) {
    equivalent,
    out_of_slice: OutOfSliceReason,
    admission_refused: AdmissionKind,
    retained_declarations: usize,
    repeated_population_additive,
    contractivity_path_limit,
};

const DeclarationFixture = struct {
    case: DeclarationCase,
    source: []const u8,
    probe: DeclarationProbe,
};

const long_nominal_name = "N" ++
    "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" ++
    "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" ++
    "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" ++
    "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
const long_nominal_source = "nominal " ++ long_nominal_name ++ " = string;";

const declaration_fixtures = [_]DeclarationFixture{
    .{ .case = .structural_alias, .source = "structural Alias = number; const value: Alias = 1;", .probe = .equivalent },
    .{ .case = .nominal_alias, .source = "nominal UserId = string; const value: UserId = \"x\";", .probe = .equivalent },
    .{ .case = .exported_structural_alias, .source = "export structural Alias = number; const value: Alias = 1;", .probe = .equivalent },
    .{ .case = .exported_nominal_alias, .source = "export nominal UserId = string; const value: UserId = \"x\";", .probe = .equivalent },
    .{ .case = .root_boundary, .source = "structural Alias = number;", .probe = .equivalent },
    .{ .case = .root_leading_space_refusal, .source = " structural Alias = number;", .probe = .{ .out_of_slice = .type_declaration } },
    .{ .case = .after_newline_refusal, .source = "const first = 1;\n  structural Alias = number;", .probe = .{ .out_of_slice = .type_declaration } },
    .{ .case = .after_semicolon_refusal, .source = "const first = 1; structural Alias = number;", .probe = .{ .out_of_slice = .type_declaration } },
    .{ .case = .block_left_aligned, .source = "function outer() {\nstructural Alias = number;\nreturn 1;\n}", .probe = .{ .retained_declarations = 1 } },
    .{ .case = .block_indented_refusal, .source = "function outer() {\n  structural Alias = number;\nreturn 1;\n}", .probe = .{ .retained_declarations = 0 } },
    .{ .case = .runtime_structural_collision, .source = "structural Alias = number; function Alias() { return 1; }", .probe = .{ .retained_declarations = 1 } },
    .{ .case = .runtime_nominal_collision, .source = "nominal Alias = number; function Alias() { return 1; }", .probe = .{ .retained_declarations = 1 } },
    .{ .case = .empty_body_no_alias, .source = "structural Empty =;", .probe = .equivalent },
    .{ .case = .present_absent_body_null_alias, .source = "structural Empty = ();", .probe = .equivalent },
    .{ .case = .exact_eager_alias, .source = "structural A = string;\nstructural B = A;\nstructural A = number;", .probe = .equivalent },
    .{ .case = .forward_deferred_ref, .source = "structural B = A;\nstructural A = string;\nstructural A = number;", .probe = .equivalent },
    .{ .case = .nested_deferred_ref, .source = "structural B = { value: A };\nstructural A = number;", .probe = .equivalent },
    .{ .case = .suffixed_deferred_ref, .source = "structural A = string;\nstructural B = A tolerated_suffix;\nstructural A = number;", .probe = .equivalent },
    .{ .case = .last_write_alias, .source = "structural A = string;\nstructural A = number;", .probe = .equivalent },
    .{ .case = .builtin_before_source, .source = "structural Copy = FetchOptions;", .probe = .equivalent },
    .{ .case = .abi_before_source, .source = "structural Copy = Request;", .probe = .equivalent },
    .{ .case = .primitive_alias_declaration_root, .source = "structural string = number;\nstructural Copy = string;", .probe = .equivalent },
    .{ .case = .primitive_alias_annotation_root, .source = "structural string = number; const value: string = 1;", .probe = .equivalent },
    .{ .case = .primitive_alias_nominal_base, .source = "structural string = number;\nnominal UserId = string;", .probe = .equivalent },
    .{ .case = .primitive_alias_nested_child, .source = "structural string = number;\nstructural Choice = string | boolean;", .probe = .equivalent },
    .{ .case = .readonly_named_root, .source = "structural Items = string[]; const value: readonly Items = \"x\";", .probe = .equivalent },
    .{ .case = .readonly_named_union, .source = "structural Items = string[];\nstructural View = readonly Items | number;", .probe = .equivalent },
    .{ .case = .readonly_named_intersection, .source = "structural Items = string[];\nstructural View = readonly Items & { tag: string };", .probe = .equivalent },
    .{ .case = .readonly_named_nullable, .source = "structural Items = string[];\nstructural View = readonly Items | undefined;", .probe = .equivalent },
    .{ .case = .readonly_named_record_terminal, .source = "structural Items = string[];\nstructural View = { field: readonly Items };", .probe = .equivalent },
    .{ .case = .readonly_named_tuple_terminal, .source = "structural Items = string[];\nstructural View = [readonly Items];", .probe = .equivalent },
    .{ .case = .named_array_one_suffix, .source = "structural Alias = string;\nstructural View = Alias[][];", .probe = .equivalent },
    .{ .case = .grouped_named_array_repeated_suffix, .source = "structural Alias = string;\nstructural View = (Alias)[][];", .probe = .equivalent },
    .{ .case = .nominal_same_name_same_base, .source = "nominal Id = string;\nnominal Id = string;", .probe = .equivalent },
    .{ .case = .nominal_different_name_same_base, .source = "nominal Left = string;\nnominal Right = string;", .probe = .equivalent },
    .{ .case = .nominal_to_base, .source = "nominal Id = string;\nstructural Base = string;", .probe = .equivalent },
    .{ .case = .base_to_nominal, .source = "nominal Id = string;\nstructural Copy = Id;", .probe = .equivalent },
    .{ .case = .nominal_long_name, .source = long_nominal_source, .probe = .equivalent },
    .{ .case = .direct_cycle, .source = "structural A = A;", .probe = .equivalent },
    .{ .case = .union_cycle, .source = "structural A = number | A;", .probe = .equivalent },
    .{ .case = .intersection_cycle, .source = "structural A = number & A;", .probe = .equivalent },
    .{ .case = .nullable_cycle, .source = "structural A = A | undefined;", .probe = .equivalent },
    .{ .case = .function_cycle, .source = "structural A = () => A;", .probe = .equivalent },
    .{ .case = .record_guard, .source = "structural A = { next: A };", .probe = .equivalent },
    .{ .case = .tuple_guard, .source = "structural A = [A];", .probe = .equivalent },
    .{ .case = .array_guard, .source = "structural A = A[];", .probe = .equivalent },
    .{ .case = .final_replacement_contractivity, .source = "structural A = A;\nstructural A = number;", .probe = .equivalent },
    .{ .case = .repeated_population_additive, .source = "structural A = A;", .probe = .repeated_population_additive },
    .{ .case = .contractivity_path_limit, .source = "structural A = A;", .probe = .contractivity_path_limit },
    .{ .case = .resolution_hop_limit, .source = "structural A0 = A1;\nstructural A1 = A2;\nstructural A2 = A3;\nstructural A3 = A4;\nstructural A4 = A5;\nstructural A5 = A6;\nstructural A6 = A7;\nstructural A7 = A8;\nstructural A8 = A9;\nstructural A9 = number;", .probe = .equivalent },
    .{ .case = .ref_structural_compare, .source = "structural A = Missing;", .probe = .equivalent },
    .{ .case = .generic_app_structural_compare, .source = "structural Items = string[];\nstructural View = { field: readonly Items };", .probe = .equivalent },
    .{ .case = .nominal_structural_compare, .source = "nominal Id = string;", .probe = .equivalent },
    .{ .case = .generic_declaration_exclusion, .source = "structural Box<T> = T;", .probe = .{ .out_of_slice = .type_declaration } },
    .{ .case = .unsupported_legacy_spelling_refusal, .source = "type Alias = number;", .probe = .{ .out_of_slice = .type_declaration } },
    .{ .case = .invalid_nominal_base_refusal, .source = "nominal Bad = { value: number };", .probe = .{ .admission_refused = .nominal_base_not_scalar } },
};

fn requireAlias(env: *const TypeEnv, name: []const u8) !TypeIndex {
    return env.getTypeAlias(name) orelse error.TestUnexpectedResult;
}

fn expectRefName(pool: *const TypePool, index: TypeIndex, name: []const u8) !void {
    try std.testing.expectEqual(TypeTag.t_ref, pool.getTag(index) orelse return error.TestUnexpectedResult);
    try std.testing.expectEqualStrings(name, pool.getRefName(index));
}

fn expectImplicitReadonlyApp(pool: *const TypePool, index: TypeIndex) !void {
    try std.testing.expectEqual(TypeTag.t_generic_app, pool.getTag(index) orelse return error.TestUnexpectedResult);
    const app = pool.getGenericAppInfo(index);
    try expectRefName(pool, app.base, "Readonly");
    try std.testing.expectEqual(@as(usize, 1), app.args.len);
    try expectRefName(pool, app.args[0], "Items");
}

fn assertDeclarationSemanticProperty(case: DeclarationCase, source: []const u8) !void {
    var parser = try JsParser.initTyped(std.testing.allocator, std.testing.allocator, source);
    defer parser.deinit();
    _ = try parser.parse();
    try parser.type_store.validate();
    try std.testing.expect(parser.type_store.declarations.items.len > 0);

    var pool = TypePool.init(std.testing.allocator);
    defer pool.deinit(std.testing.allocator);
    var env = TypeEnv.init(std.testing.allocator, &pool);
    defer env.deinit();
    module_types.populateModuleTypes(&env, &pool, std.testing.allocator);
    abi_types.populateHandlerAbiTypes(&env, &pool, std.testing.allocator);
    try lowerSyntaxStore(std.testing.allocator, &parser.type_store, &pool, &env);
    try pool.ensureHealthy();
    try env.ensureHealthy();

    switch (case) {
        .structural_alias, .root_boundary => {
            try std.testing.expectEqual(pool.idx_number, try requireAlias(&env, "Alias"));
        },
        .nominal_alias, .exported_nominal_alias => {
            const alias = try requireAlias(&env, "UserId");
            try std.testing.expect(pool.isNominal(alias));
            try std.testing.expectEqualStrings("UserId", pool.nominalName(alias));
            if (case == .exported_nominal_alias) {
                try std.testing.expect(parser.type_store.declarations.items[0].export_span != null);
            }
        },
        .exported_structural_alias => {
            try std.testing.expect(parser.type_store.declarations.items[0].export_span != null);
            try std.testing.expectEqual(pool.idx_number, try requireAlias(&env, "Alias"));
        },
        .empty_body_no_alias => try std.testing.expect(env.getTypeAlias("Empty") == null),
        .present_absent_body_null_alias => {
            const alias = env.getTypeAlias("Empty");
            try std.testing.expect(alias != null);
            try std.testing.expectEqual(null_type_idx, alias.?);
        },
        .exact_eager_alias => {
            try std.testing.expectEqual(pool.idx_number, try requireAlias(&env, "A"));
            try std.testing.expectEqual(pool.idx_string, try requireAlias(&env, "B"));
        },
        .forward_deferred_ref, .suffixed_deferred_ref => {
            const alias = try requireAlias(&env, "B");
            try expectRefName(&pool, alias, "A");
            try std.testing.expectEqual(pool.idx_number, env.resolveRef(alias));
        },
        .nested_deferred_ref => {
            const fields = pool.getRecordFields(try requireAlias(&env, "B"));
            try std.testing.expectEqual(@as(usize, 1), fields.len);
            try expectRefName(&pool, fields[0].type_idx, "A");
        },
        .last_write_alias => try std.testing.expectEqual(pool.idx_number, try requireAlias(&env, "A")),
        .builtin_before_source => try std.testing.expectEqual(
            try requireAlias(&env, "FetchOptions"),
            try requireAlias(&env, "Copy"),
        ),
        .abi_before_source => try std.testing.expectEqual(
            try requireAlias(&env, "Request"),
            try requireAlias(&env, "Copy"),
        ),
        .primitive_alias_declaration_root => {
            try std.testing.expectEqual(pool.idx_number, try requireAlias(&env, "string"));
            try std.testing.expectEqual(pool.idx_number, try requireAlias(&env, "Copy"));
        },
        .primitive_alias_annotation_root => {
            const annotation = parser.type_store.annotations.items[0];
            try std.testing.expectEqual(
                pool.idx_number,
                env.getVarTypeByBinding(annotation.binding.scope_id, annotation.binding.name_atom) orelse
                    return error.TestUnexpectedResult,
            );
        },
        .primitive_alias_nominal_base => {
            const alias = try requireAlias(&env, "UserId");
            try std.testing.expect(pool.isNominal(alias));
            try std.testing.expectEqual(TypeTag.t_number, pool.getTag(alias) orelse return error.TestUnexpectedResult);
        },
        .primitive_alias_nested_child => {
            const members = pool.getUnionMembers(try requireAlias(&env, "Choice"));
            try std.testing.expectEqualSlices(TypeIndex, &.{ pool.idx_string, pool.idx_boolean }, members);
        },
        .readonly_named_root => {
            const annotation = parser.type_store.annotations.items[0];
            const index = env.getVarTypeByBinding(annotation.binding.scope_id, annotation.binding.name_atom) orelse
                return error.TestUnexpectedResult;
            try std.testing.expectEqual(TypeTag.t_array, pool.getTag(index) orelse return error.TestUnexpectedResult);
            try std.testing.expect(pool.isReadonlyArray(index));
        },
        .readonly_named_union => {
            const members = pool.getUnionMembers(try requireAlias(&env, "View"));
            try std.testing.expectEqual(@as(usize, 2), members.len);
            try std.testing.expect(pool.isReadonlyArray(members[0]));
        },
        .readonly_named_intersection => {
            const members = pool.getIntersectionMembers(try requireAlias(&env, "View"));
            try std.testing.expectEqual(@as(usize, 2), members.len);
            try std.testing.expect(pool.isReadonlyArray(members[0]));
        },
        .readonly_named_nullable => {
            const nullable = try requireAlias(&env, "View");
            try std.testing.expectEqual(TypeTag.t_nullable, pool.getTag(nullable) orelse return error.TestUnexpectedResult);
            try std.testing.expect(pool.isReadonlyArray(pool.getNullableInner(nullable)));
        },
        .readonly_named_record_terminal, .generic_app_structural_compare => {
            const fields = pool.getRecordFields(try requireAlias(&env, "View"));
            try std.testing.expectEqual(@as(usize, 1), fields.len);
            try expectImplicitReadonlyApp(&pool, fields[0].type_idx);
        },
        .readonly_named_tuple_terminal => {
            const elements = pool.getTupleElements(try requireAlias(&env, "View"));
            try std.testing.expectEqual(@as(usize, 1), elements.len);
            try expectImplicitReadonlyApp(&pool, elements[0]);
        },
        .named_array_one_suffix => {
            const view = try requireAlias(&env, "View");
            try std.testing.expectEqual(TypeTag.t_array, pool.getTag(view) orelse return error.TestUnexpectedResult);
            try expectRefName(&pool, pool.getArrayElement(view), "Alias");
            const body = parser.type_store.declarations.items[1].body.present;
            try std.testing.expectEqualStrings("Alias[]", source[body.raw_span.start..body.semantic_prefix_end]);
        },
        .grouped_named_array_repeated_suffix => {
            const outer = try requireAlias(&env, "View");
            try std.testing.expectEqual(TypeTag.t_array, pool.getTag(outer) orelse return error.TestUnexpectedResult);
            const inner = pool.getArrayElement(outer);
            try std.testing.expectEqual(TypeTag.t_array, pool.getTag(inner) orelse return error.TestUnexpectedResult);
            try expectRefName(&pool, pool.getArrayElement(inner), "Alias");
            const body = parser.type_store.declarations.items[1].body.present;
            try std.testing.expectEqual(body.raw_span.end, body.semantic_prefix_end);
        },
        .nominal_same_name_same_base => {
            const first = pool.addNominalAlias(std.testing.allocator, pool.idx_string, "Id");
            const second = pool.addNominalAlias(std.testing.allocator, pool.idx_string, "Id");
            try pool.ensureHealthy();
            try std.testing.expect(env.isAssignableTo(first, second));
            try std.testing.expect(env.isAssignableTo(second, first));
        },
        .nominal_different_name_same_base => {
            const left = try requireAlias(&env, "Left");
            const right = try requireAlias(&env, "Right");
            try std.testing.expect(!env.isAssignableTo(left, right));
            try std.testing.expect(!env.isAssignableTo(right, left));
        },
        .nominal_to_base => try std.testing.expect(env.isAssignableTo(
            try requireAlias(&env, "Id"),
            pool.idx_string,
        )),
        .base_to_nominal => try std.testing.expect(!env.isAssignableTo(
            pool.idx_string,
            try requireAlias(&env, "Id"),
        )),
        .nominal_long_name => {
            try std.testing.expect(long_nominal_name.len > std.math.maxInt(u8));
            const alias = try requireAlias(&env, long_nominal_name);
            try std.testing.expectEqual(@as(usize, std.math.maxInt(u8)), pool.nominalName(alias).len);
        },
        .direct_cycle, .union_cycle, .intersection_cycle, .nullable_cycle, .function_cycle => {
            try std.testing.expect(env.isNonContractiveAlias("A"));
        },
        .record_guard, .tuple_guard, .array_guard => {
            try std.testing.expect(!env.isNonContractiveAlias("A"));
        },
        .final_replacement_contractivity => {
            try std.testing.expectEqual(pool.idx_number, try requireAlias(&env, "A"));
            try std.testing.expect(!env.isNonContractiveAlias("A"));
        },
        .resolution_hop_limit => {
            const a0 = try requireAlias(&env, "A0");
            try expectRefName(&pool, env.resolveRef(a0), "A9");
            try std.testing.expectEqual(pool.idx_number, env.resolveRef(try requireAlias(&env, "A1")));
        },
        .ref_structural_compare => try expectRefName(&pool, try requireAlias(&env, "A"), "Missing"),
        .nominal_structural_compare => {
            const alias = try requireAlias(&env, "Id");
            try std.testing.expect(pool.isNominal(alias));
            try std.testing.expectEqualStrings("Id", pool.nominalName(alias));
        },
        .repeated_population_additive, .contractivity_path_limit => {
            try std.testing.expect(env.isNonContractiveAlias("A"));
        },
        .root_leading_space_refusal,
        .after_newline_refusal,
        .after_semicolon_refusal,
        .block_left_aligned,
        .block_indented_refusal,
        .runtime_structural_collision,
        .runtime_nominal_collision,
        .generic_declaration_exclusion,
        .unsupported_legacy_spelling_refusal,
        .invalid_nominal_base_refusal,
        => return error.TestUnexpectedResult,
    }
}

fn assertRepeatedPopulationIsAdditive() !void {
    var pool = TypePool.init(std.testing.allocator);
    defer pool.deinit(std.testing.allocator);
    var env = TypeEnv.init(std.testing.allocator, &pool);
    defer env.deinit();
    env.putTypeAlias("A", pool.addRef(std.testing.allocator, "A"));
    env.finishTypeAliasPopulation();
    try pool.ensureHealthy();
    try env.ensureHealthy();
    try std.testing.expect(env.isNonContractiveAlias("A"));
    env.putTypeAlias("A", pool.idx_number);
    env.putTypeAlias("B", pool.addRef(std.testing.allocator, "B"));
    env.finishTypeAliasPopulation();
    try pool.ensureHealthy();
    try env.ensureHealthy();
    try std.testing.expect(env.isNonContractiveAlias("A"));
    try std.testing.expect(env.isNonContractiveAlias("B"));
}

fn assertContractivityPathBoundary(alias_count: usize, expected: bool) !void {
    var pool = TypePool.init(std.testing.allocator);
    defer pool.deinit(std.testing.allocator);
    var env = TypeEnv.init(std.testing.allocator, &pool);
    defer env.deinit();
    var names: [32][4]u8 = undefined;
    var lengths: [32]usize = undefined;
    for (0..alias_count) |index| {
        const name = try std.fmt.bufPrint(&names[index], "A{}", .{index});
        lengths[index] = name.len;
    }
    for (0..alias_count) |index| {
        const name = names[index][0..lengths[index]];
        const next_index = (index + 1) % alias_count;
        const next = names[next_index][0..lengths[next_index]];
        env.putTypeAlias(name, pool.addRef(std.testing.allocator, next));
    }
    env.finishTypeAliasPopulation();
    try pool.ensureHealthy();
    try env.ensureHealthy();
    try std.testing.expectEqual(expected, env.isNonContractiveAlias("A0"));
}

fn assertRetainedRuntimeFunction(
    parser: *const JsParser,
    source: []const u8,
    expected_kind: TypeSyntax.DeclarationKind,
    expected_scope: u16,
) !void {
    try std.testing.expectEqual(@as(usize, 1), parser.type_store.declarations.items.len);
    const declaration = parser.type_store.declarations.items[0];
    try std.testing.expectEqual(expected_kind, declaration.kind);
    try std.testing.expectEqual(expected_scope, declaration.authored_scope);
    try std.testing.expectEqualStrings("Alias", declaration.name_span.text(source));

    const view = engine.parser.IrView.fromIRStore(&parser.nodes, &parser.constants);
    var function_index: ?NodeIndex = null;
    var return_index: ?NodeIndex = null;
    for (parser.nodes.tags.items, 0..) |tag, index| switch (tag) {
        .function_decl => {
            try std.testing.expect(function_index == null);
            function_index = @intCast(index);
        },
        .return_stmt => {
            try std.testing.expect(return_index == null);
            return_index = @intCast(index);
        },
        else => {},
    };
    const function = function_index orelse return error.TestUnexpectedResult;
    const return_statement = return_index orelse return error.TestUnexpectedResult;
    const expected_function_offset = std.mem.indexOf(u8, source, "function") orelse
        return error.TestUnexpectedResult;
    const expected_return_offset = std.mem.indexOf(u8, source, "return") orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u32, @intCast(expected_function_offset)), parser.nodes.getLoc(function).offset);
    try std.testing.expectEqual(@as(u32, @intCast(expected_return_offset)), parser.nodes.getLoc(return_statement).offset);
    const function_data = view.getFunctionOfDecl(function) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(engine.parser.NodeTag.block, view.getTag(function_data.body).?);
    try std.testing.expect(view.subtreeContains(function_data.body, return_statement));
}

test "declaration semantic census observes every case" {
    try std.testing.expectEqual(std.meta.fields(DeclarationCase).len, declaration_fixtures.len);
    var seen = std.EnumSet(DeclarationCase).initEmpty();
    for (declaration_fixtures) |fixture| {
        try std.testing.expect(fixture.source.len > 0);
        try std.testing.expect(!seen.contains(fixture.case));
        switch (fixture.probe) {
            .equivalent => {
                try assertDeclarationSemanticProperty(fixture.case, fixture.source);
                try expectEquivalent(fixture.source);
            },
            .out_of_slice => |expected| switch (try compare(std.testing.allocator, fixture.source, .collect)) {
                .out_of_slice => |actual| try std.testing.expectEqual(expected, actual),
                else => return error.TestUnexpectedResult,
            },
            .admission_refused => |expected| switch (try compare(std.testing.allocator, fixture.source, .collect)) {
                .admission_refused => |actual| try std.testing.expectEqual(expected, actual.first),
                else => return error.TestUnexpectedResult,
            },
            .retained_declarations => |expected| {
                var parser = try JsParser.initTyped(
                    std.testing.allocator,
                    std.testing.allocator,
                    fixture.source,
                );
                defer parser.deinit();
                switch (fixture.case) {
                    .block_left_aligned => {
                        _ = try parser.parse();
                        try assertRetainedRuntimeFunction(&parser, fixture.source, .structural, 2);
                    },
                    .runtime_structural_collision => {
                        _ = try parser.parse();
                        try assertRetainedRuntimeFunction(&parser, fixture.source, .structural, 0);
                    },
                    .runtime_nominal_collision => {
                        _ = try parser.parse();
                        try assertRetainedRuntimeFunction(&parser, fixture.source, .nominal, 0);
                    },
                    .block_indented_refusal => {
                        try std.testing.expectError(error.ParseError, parser.parse());
                        try std.testing.expectEqual(@as(usize, 0), parser.type_store.declarations.items.len);
                        const errors = parser.errors.getErrors();
                        try std.testing.expectEqual(@as(usize, 1), errors.len);
                        try std.testing.expectEqual(engine.parser.ErrorKind.missing_semicolon, errors[0].kind);
                        const structural = std.mem.indexOf(u8, fixture.source, "structural") orelse
                            return error.TestUnexpectedResult;
                        try std.testing.expectEqual(@as(u32, @intCast(structural)), errors[0].location.offset);
                        try std.testing.expectEqual(
                            @as(u32, @intCast(structural + "structural".len)),
                            errors[0].location.end_offset,
                        );
                    },
                    else => return error.TestUnexpectedResult,
                }
                try std.testing.expectEqual(expected, parser.type_store.declarations.items.len);
                try parser.type_store.validate();
            },
            .repeated_population_additive => {
                try assertDeclarationSemanticProperty(fixture.case, fixture.source);
                try expectEquivalent(fixture.source);
                try assertRepeatedPopulationIsAdditive();
            },
            .contractivity_path_limit => {
                try assertDeclarationSemanticProperty(fixture.case, fixture.source);
                try expectEquivalent(fixture.source);
                try assertContractivityPathBoundary(31, true);
                try assertContractivityPathBoundary(32, false);
            },
        }
        seen.insert(fixture.case);
    }
    try std.testing.expectEqual(std.meta.fields(DeclarationCase).len, seen.count());
}

test "declaration bodies admit numeric leading and blank-line continuations" {
    const sources = [_][]const u8{
        "structural Numeric = 1;",
        "structural LeadingUnion = | number;",
        "structural LeadingIntersection = & number;",
        "structural Union = number |\n\n string;",
        "structural Intersection = number &\n\n { value: string };",
    };
    for (sources) |source| try expectEquivalent(source);
}

test "spaced function arrow continuation absorbs the next runtime line" {
    const source = "structural A = number = >\nconst value = 1;";
    inline for (.{ AdmissionMode.collect, AdmissionMode.compile }) |mode| {
        switch (try compare(std.testing.allocator, source, mode)) {
            .equivalent => {},
            else => return error.TestUnexpectedResult,
        }
    }

    var parser = try JsParser.initTyped(std.testing.allocator, std.testing.allocator, source);
    defer parser.deinit();
    _ = try parser.parse();
    try std.testing.expectEqual(@as(usize, 1), parser.type_store.declarations.items.len);
    const body = switch (parser.type_store.declarations.items[0].body) {
        .absent => return error.TestUnexpectedResult,
        .present => |present| present,
    };
    try std.testing.expectEqualStrings("number = >\nconst value = 1", body.raw_span.text(source));
    try std.testing.expectEqualStrings(source, parser.type_store.declarations.items[0].full_span.text(source));
    var runtime_variables: usize = 0;
    for (parser.nodes.tags.items) |tag| if (tag == .var_decl) {
        runtime_variables += 1;
    };
    try std.testing.expectEqual(@as(usize, 0), runtime_variables);
}

test "comment-separated declaration terminator remains a runtime semicolon" {
    const source = "structural A = number\n/*c*/;";
    inline for (.{ AdmissionMode.collect, AdmissionMode.compile }) |mode| {
        switch (try compare(std.testing.allocator, source, mode)) {
            .out_of_slice => |reason| try std.testing.expectEqual(OutOfSliceReason.unsupported_initializer, reason),
            else => return error.TestUnexpectedResult,
        }
    }

    var parser = try JsParser.initTyped(std.testing.allocator, std.testing.allocator, source);
    defer parser.deinit();
    try std.testing.expectError(error.ParseError, parser.parse());
    try std.testing.expectEqual(@as(usize, 1), parser.type_store.declarations.items.len);
    try std.testing.expect(parser.type_store.declarations.items[0].terminator_span == null);
    const errors = parser.errors.getErrors();
    try std.testing.expectEqual(@as(usize, 1), errors.len);
    try std.testing.expectEqual(engine.parser.ErrorKind.unsupported_feature, errors[0].kind);
    const semicolon = std.mem.indexOfScalar(u8, source, ';') orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u32, @intCast(semicolon)), errors[0].location.offset);
    try std.testing.expectEqual(@as(u32, 2), errors[0].location.line);
    try std.testing.expectEqual(@as(u32, 6), errors[0].location.column);
}

test "nominal refusal recovery preserves a comment-separated semicolon" {
    const separated = "nominal Bad = void\n/*c*/;";
    inline for (.{ AdmissionMode.collect, AdmissionMode.compile }) |mode| {
        switch (try preflight(std.testing.allocator, separated, mode)) {
            .out_of_slice => |reason| try std.testing.expectEqual(OutOfSliceReason.unsupported_initializer, reason),
            .eligible => |eligible| {
                var unexpected = eligible;
                unexpected.deinit(std.testing.allocator);
                return error.TestUnexpectedResult;
            },
        }
    }

    const empty = "nominal Bad =\n;";
    inline for (.{ AdmissionMode.collect, AdmissionMode.compile }) |mode| {
        var checked = switch (try preflight(std.testing.allocator, empty, mode)) {
            .eligible => |eligible| eligible,
            .out_of_slice => return error.TestUnexpectedResult,
        };
        defer checked.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(usize, 1), checked.diagnostics.items.len);
        try std.testing.expectEqual(AdmissionKind.nominal_base_not_scalar, checked.diagnostics.items[0].kind);
    }
}

test "unterminated trailing declaration comment stays outside the private slice" {
    const source = "structural A = number;/*";
    inline for (.{ AdmissionMode.collect, AdmissionMode.compile }) |mode| {
        switch (try preflight(std.testing.allocator, source, mode)) {
            .out_of_slice => |reason| try std.testing.expectEqual(OutOfSliceReason.unsupported_initializer, reason),
            .eligible => |eligible| {
                var unexpected = eligible;
                unexpected.deinit(std.testing.allocator);
                return error.TestUnexpectedResult;
            },
        }
        switch (try compare(std.testing.allocator, source, mode)) {
            .out_of_slice => |reason| try std.testing.expectEqual(OutOfSliceReason.unsupported_initializer, reason),
            else => return error.TestUnexpectedResult,
        }
    }
}

test "declaration names admit identifier-shaped keyword tokens" {
    const names = [_][]const u8{ "true", "null", "undefined", "function" };
    for (names) |name| {
        const source = try std.fmt.allocPrint(
            std.testing.allocator,
            "structural {s} = number;\nconst value: {s} = 1;",
            .{ name, name },
        );
        defer std.testing.allocator.free(source);
        try expectEquivalent(source);
    }
}

test "declaration exclusions ignore diagnostics from earlier syntax" {
    const Fixture = struct { source: []const u8, reason: OutOfSliceReason };
    const unsupported = [_]Fixture{
        .{ .source = "const first: number any = 1;\nstructural Later = Named<string>;", .reason = .type_declaration },
        .{ .source = "nominal Bad = number any;\nstructural Later = Named<string>;", .reason = .type_declaration },
        .{ .source = "nominal Bad = number any;\nfunction later() { return 1; }", .reason = .function_declaration },
        .{ .source = "structural Later = Named<any>;", .reason = .type_declaration },
    };
    for (unsupported) |fixture| {
        inline for (.{ AdmissionMode.collect, AdmissionMode.compile }) |mode| {
            switch (try compare(std.testing.allocator, fixture.source, mode)) {
                .out_of_slice => |reason| try std.testing.expectEqual(fixture.reason, reason),
                else => return error.TestUnexpectedResult,
            }
            switch (try preflight(std.testing.allocator, fixture.source, mode)) {
                .out_of_slice => |reason| try std.testing.expectEqual(fixture.reason, reason),
                .eligible => |eligible| {
                    var unexpected = eligible;
                    unexpected.deinit(std.testing.allocator);
                    return error.TestUnexpectedResult;
                },
            }
        }
    }

    var budget: std.ArrayListUnmanaged(u8) = .empty;
    defer budget.deinit(std.testing.allocator);
    try budget.appendSlice(std.testing.allocator, "const first: number any = 1;\nstructural Later = ");
    for (0..TypeSyntax.max_parser_frames + 1) |_| {
        try budget.appendSlice(std.testing.allocator, "readonly ");
    }
    try budget.appendSlice(std.testing.allocator, "number;");
    inline for (.{ AdmissionMode.collect, AdmissionMode.compile }) |mode| {
        switch (try compare(std.testing.allocator, budget.items, mode)) {
            .out_of_slice => |reason| try std.testing.expectEqual(OutOfSliceReason.type_declaration, reason),
            else => return error.TestUnexpectedResult,
        }
    }
}

test "declaration header comments stay outside the private slice" {
    const sources = [_][]const u8{
        "structural /*c*/ A = number;",
        "structural A /*c*/ = number;",
    };
    for (sources) |source| {
        inline for (.{ AdmissionMode.collect, AdmissionMode.compile }) |mode| {
            switch (try preflight(std.testing.allocator, source, mode)) {
                .out_of_slice => |reason| try std.testing.expectEqual(OutOfSliceReason.type_declaration, reason),
                .eligible => |eligible| {
                    var unexpected = eligible;
                    unexpected.deinit(std.testing.allocator);
                    return error.TestUnexpectedResult;
                },
            }
        }
    }
}

test "nominal declaration admission preserves diagnostic order and deduplication" {
    const Fixture = struct {
        source: []const u8,
        expected: []const AdmissionKind,
    };
    const fixtures = [_]Fixture{
        .{ .source = "nominal Bad = void;", .expected = &.{.nominal_base_not_scalar} },
        .{ .source = "nominal Bad = Array<string>;", .expected = &.{.nominal_base_not_scalar} },
        .{ .source = "nominal Bad = ReadonlyArray<string>;", .expected = &.{.nominal_base_not_scalar} },
        .{ .source = "nominal Bad = (value?: string) => number;", .expected = &.{.nominal_base_not_scalar} },
        .{ .source = "nominal Bad = any;", .expected = &.{.any_type} },
        .{ .source = "nominal Bad = number any;", .expected = &.{ .any_type, .nominal_base_not_scalar } },
        .{ .source = "nominal Bad =;", .expected = &.{.nominal_base_not_scalar} },
        .{ .source = "nominal Bad;", .expected = &.{.nominal_base_not_scalar} },
    };
    for (fixtures) |fixture| {
        var checked = switch (try preflight(std.testing.allocator, fixture.source, .collect)) {
            .eligible => |eligible| eligible,
            .out_of_slice => return error.TestUnexpectedResult,
        };
        defer checked.deinit(std.testing.allocator);
        try std.testing.expectEqual(fixture.expected.len, checked.diagnostics.items.len);
        for (fixture.expected, checked.diagnostics.items) |expected, actual| {
            try std.testing.expectEqual(expected, actual.kind);
        }
    }

    switch (try preflight(
        std.testing.allocator,
        "nominal Bad = number any;\nstructural Later = Named<string>;",
        .compile,
    )) {
        .out_of_slice => |reason| try std.testing.expectEqual(OutOfSliceReason.type_declaration, reason),
        .eligible => |eligible| {
            var unexpected = eligible;
            unexpected.deinit(std.testing.allocator);
            return error.TestUnexpectedResult;
        },
    }

    var compile_checked = switch (try preflight(
        std.testing.allocator,
        "nominal Bad = number any;",
        .compile,
    )) {
        .eligible => |eligible| eligible,
        .out_of_slice => return error.TestUnexpectedResult,
    };
    defer compile_checked.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), compile_checked.diagnostics.items.len);
    try std.testing.expectEqual(AdmissionKind.any_type, compile_checked.diagnostics.items[0].kind);

    var spaced = switch (try preflight(std.testing.allocator, "nominal Bad   ;", .collect)) {
        .eligible => |eligible| eligible,
        .out_of_slice => return error.TestUnexpectedResult,
    };
    defer spaced.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), spaced.diagnostics.items.len);
    try std.testing.expectEqual(AdmissionKind.nominal_base_not_scalar, spaced.diagnostics.items[0].kind);
    const position = positionOf("nominal Bad   ;", spaced.diagnostics.items[0].span.start);
    try std.testing.expectEqual(@as(u32, 1), position.line);
    try std.testing.expectEqual(@as(u32, 15), position.column);
}

test "declaration comparison closes every allocation failure" {
    const Context = struct {
        fn run(allocator: std.mem.Allocator) !void {
            const source =
                "structural Loop = Loop;\n" ++
                "nominal Identifier = string;\n" ++
                "const value: Identifier = \"x\";";
            switch (try compare(allocator, source, .collect)) {
                .equivalent => {},
                else => return error.TestUnexpectedResult,
            }
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Context.run, .{});
}

test "direct primitive slice matches every legacy primitive" {
    const primitives = [_][]const u8{
        "unknown",
        "never",
        "undefined",
        "null",
        "boolean",
        "number",
        "string",
        "Bytes",
    };
    for (primitives) |primitive| {
        for ([_][]const u8{ "", "(((" }) |opening| {
            const closing: []const u8 = if (opening.len == 0) "" else ")))";
            const source = try std.fmt.allocPrint(
                std.testing.allocator,
                "const value: {s}{s}{s} = seed;",
                .{ opening, primitive, closing },
            );
            defer std.testing.allocator.free(source);
            try expectEquivalent(source);
        }
    }
}

test "simple structural declaration is runtime neutral and lowers directly" {
    try expectEquivalent("structural Alias = number; const value: Alias = 1;");
    try expectEquivalent("structural Alias = number;");
}

test "simple nominal declaration is runtime neutral and lowers directly" {
    try expectEquivalent("nominal UserId = string; const value: UserId = \"x\";");
}

test "direct compound slice matches an ordered record with arrays" {
    try expectEquivalent(
        "const value: { readonly id?: number; tags: string[][] } = input;",
    );
}

test "direct compound families and semantic quirks match ordered legacy types" {
    const Fixture = struct {
        annotation: []const u8,
        family: ?CompoundFamily = null,
        quirk: SemanticQuirk,
    };
    const fixtures = [_]Fixture{
        .{ .annotation = "{ \"x\": number }", .quirk = .quoted_record_prefix },
        .{ .annotation = "{ x number }", .quirk = .missing_record_colon_prefix },
        .{ .annotation = "{ x: }", .quirk = .missing_record_type_absent },
        .{ .annotation = "{ /*c*/ x: number }", .quirk = .record_comment_prefix },
        .{ .annotation = "{ x: number /*c*/ }", .quirk = .record_comment_after_field },
        .{ .annotation = "{ x: number y: string }", .quirk = .omitted_record_separator },
        .{
            .annotation = "{ readonly id?: number; name: string }",
            .family = .record,
            .quirk = .readonly_optional_fields,
        },
        .{ .annotation = "number[][]", .family = .array, .quirk = .mutable_repeated_arrays },
        .{ .annotation = "number [ ]", .quirk = .separated_array_brackets },
        .{ .annotation = "number /*c*/ []", .quirk = .comment_before_array },
        .{ .annotation = "readonly number[]", .quirk = .readonly_array_flag },
        .{ .annotation = "[string, number,]", .family = .tuple, .quirk = .tuple_trailing_comma },
        .{ .annotation = "readonly [string, number]", .quirk = .readonly_tuple_erasure },
        .{ .annotation = "(| number | string)", .family = .union_type, .quirk = .grouped_leading_union },
        .{ .annotation = "number |", .quirk = .trailing_union_prefix },
        .{ .annotation = "{ x: number } &", .quirk = .trailing_intersection_prefix },
        .{
            .annotation = "string | number & boolean",
            .family = .intersection,
            .quirk = .intersection_precedence,
        },
        .{ .annotation = "string | undefined", .quirk = .nullable_shorthand },
        .{ .annotation = "string | number | undefined", .quirk = .wider_undefined_union },
        .{ .annotation = "string | 1.5", .quirk = .numeric_token_prefix },
        .{ .annotation = "{ cb: (x?: number) => number }", .quirk = .nested_optional_parameter },
        .{ .annotation = "{ any: number }", .quirk = .any_member_key },
        .{ .annotation = "(x: number y: string) => number", .quirk = .missing_function_comma },
        .{ .annotation = "(x: number) number", .quirk = .missing_function_arrow },
        .{ .annotation = "(x: number) =>", .quirk = .missing_function_return },
        .{
            .annotation = "(left: string, right: number) => boolean",
            .family = .function,
            .quirk = .named_function_parameters,
        },
        .{ .annotation = "`\\${string}`", .quirk = .escaped_template_slot },
        .{ .annotation = "`x${}`", .quirk = .empty_template_slot },
        .{ .annotation = "``", .quirk = .empty_template_root },
        .{
            .annotation = "`pre-${string}-mid-${number}-post`",
            .family = .template,
            .quirk = .multi_part_template,
        },
        .{ .annotation = "\"GET\"", .family = .literal, .quirk = .literal_values },
    };
    try std.testing.expectEqual(
        @as(usize, @typeInfo(SemanticQuirk).@"enum".fields.len),
        fixtures.len,
    );

    var families = std.EnumSet(CompoundFamily).initEmpty();
    var quirks = std.EnumSet(SemanticQuirk).initEmpty();
    for (fixtures) |fixture| {
        const source = try legacyAnnotationSource(std.testing.allocator, fixture.annotation);
        defer std.testing.allocator.free(source);
        try expectEquivalent(source);
        quirks.insert(fixture.quirk);
        if (fixture.family) |family| families.insert(family);
    }
    inline for (@typeInfo(CompoundFamily).@"enum".fields) |field| {
        try std.testing.expect(families.contains(@enumFromInt(field.value)));
    }
    inline for (@typeInfo(SemanticQuirk).@"enum".fields) |field| {
        try std.testing.expect(quirks.contains(@enumFromInt(field.value)));
    }

    for ([_][]const u8{
        "number [] []",
        "string | 200",
        "string | 0x10",
        "string | 1_000",
        "(200)",
        "true",
    }) |annotation| {
        const source = try legacyAnnotationSource(std.testing.allocator, annotation);
        defer std.testing.allocator.free(source);
        try expectEquivalent(source);
    }
}

test "direct compound boundaries preserve legacy structure before key comparison" {
    const allocator = std.testing.allocator;
    var function: std.ArrayListUnmanaged(u8) = .empty;
    defer function.deinit(allocator);
    try function.appendSlice(allocator, "const value: (");
    for (0..15) |index| {
        if (index > 0) try function.appendSlice(allocator, ", ");
        var name: [32]u8 = undefined;
        try function.appendSlice(allocator, try std.fmt.bufPrint(&name, "p{d}: number", .{index}));
    }
    try function.appendSlice(allocator, ") => string = undefined;");
    try expectEquivalent(function.items);

    inline for (.{ 63, 64 }) |layers| {
        const source = "const value: number" ++ "[]" ** layers ++ " = undefined;";
        try expectEquivalent(source);
    }

    for ([_][]const u8{
        "const value: undefined | undefined = undefined;",
        "const value: (undefined & undefined) | string = undefined;",
        "const value: number | | string = undefined;",
        "const value: number | | | string = undefined;",
        "const value: number & & string = undefined;",
        "const value: [()][] = undefined;",
        "const value: { x }[] = undefined;",
        "const value: [[()]][] = undefined;",
        "const value: { outer: { x }[]; tail: number }[] = undefined;",
    }) |source| try expectEquivalent(source);
}

test "nested semantic absence stops before later syntax" {
    try expectDirectAbsentPrefix("((())) | Unsupported", "((()))");
    try expectDirectAbsentPrefix("((()))[] | string", "((()))");

    var annotation: std.ArrayListUnmanaged(u8) = .empty;
    defer annotation.deinit(std.testing.allocator);
    try annotation.appendSlice(std.testing.allocator, "((())) | ((");
    for (0..16) |index| {
        if (index > 0) try annotation.appendSlice(std.testing.allocator, ", ");
        var name: [32]u8 = undefined;
        try annotation.appendSlice(
            std.testing.allocator,
            try std.fmt.bufPrint(&name, "p{d}: number", .{index}),
        );
    }
    try annotation.appendSlice(std.testing.allocator, ") => number)");
    try expectDirectAbsentPrefix(annotation.items, "((()))");
}

test "direct function lowering propagates the packed parameter capacity error" {
    const allocator = std.testing.allocator;
    var source: std.ArrayListUnmanaged(u8) = .empty;
    defer source.deinit(allocator);
    try source.appendSlice(allocator, "(");
    for (0..16) |index| {
        if (index > 0) try source.appendSlice(allocator, ", ");
        var name: [32]u8 = undefined;
        try source.appendSlice(allocator, try std.fmt.bufPrint(&name, "p{d}: number", .{index}));
    }
    try source.appendSlice(allocator, ") => string = value;");

    var store = TypeSyntax.Store.init(allocator, source.items);
    defer store.deinit();
    var cursor = TypeSyntax.Cursor.init(source.items);
    switch (try TypeSyntax.parseAndStore(&store, .global(300), source.items, 0, &cursor)) {
        .parsed => {},
        .failure, .excluded => return error.TestUnexpectedResult,
    }
    var pool = TypePool.init(allocator);
    defer pool.deinit(allocator);
    var env = TypeEnv.init(allocator, &pool);
    defer env.deinit();
    try std.testing.expectError(
        error.TypePoolCapacityExceeded,
        lowerSyntaxStore(allocator, &store, &pool, &env),
    );
    try std.testing.expectError(error.TypePoolCapacityExceeded, pool.ensureHealthy());
}

test "private compound budgets decline before legacy preparation" {
    const Budget = enum { frames, templates };
    inline for (std.meta.tags(Budget)) |budget| {
        var source: std.ArrayListUnmanaged(u8) = .empty;
        defer source.deinit(std.testing.allocator);
        try source.appendSlice(std.testing.allocator, "const value: ");
        switch (budget) {
            .frames => {
                for (0..TypeSyntax.max_parser_frames + 1) |_| {
                    try source.appendSlice(std.testing.allocator, "readonly ");
                }
                try source.appendSlice(std.testing.allocator, "number = 1;");
            },
            .templates => {
                try source.append(std.testing.allocator, '`');
                for (0..TypeSyntax.max_template_levels) |_| {
                    try source.appendSlice(std.testing.allocator, "${`");
                }
                try source.appendSlice(std.testing.allocator, "value");
                for (0..TypeSyntax.max_template_levels) |_| {
                    try source.appendSlice(std.testing.allocator, "`}");
                }
                try source.appendSlice(std.testing.allocator, "` = 1;");
            },
        }
        const verdict = try compare(std.testing.allocator, source.items, .collect);
        switch (verdict) {
            .out_of_slice => |reason| try std.testing.expectEqual(
                OutOfSliceReason.compound_annotation,
                reason,
            ),
            else => return error.TestUnexpectedResult,
        }
    }
}

test "function backtracking removes every provisional syntax item" {
    const source = "(number: string | boolean, number) = value;";
    var store = TypeSyntax.Store.init(std.testing.allocator, source);
    defer store.deinit();
    var cursor = TypeSyntax.Cursor.init(source);
    switch (try TypeSyntax.parseAndStore(&store, .global(300), source, 0, &cursor)) {
        .parsed => {},
        .failure, .excluded => return error.TestUnexpectedResult,
    }
    try std.testing.expectEqual(@as(usize, 0), store.params.items.len);
    try std.testing.expectEqual(@as(usize, 0), store.members.items.len);
    for (store.nodes.items) |node| switch (node.data) {
        .primitive => |primitive| try std.testing.expectEqual(TypeSyntax.Primitive.number, primitive),
        else => {},
    };
    try expectEquivalent("const value: (number: string | boolean, number) = undefined;");
}

test "compound syntax keeps complete field and parameter spans" {
    const source = "{ readonly id?: number; cb: (arg: string) => boolean } = value;";
    var store = TypeSyntax.Store.init(std.testing.allocator, source);
    defer store.deinit();
    var cursor = TypeSyntax.Cursor.init(source);
    const parsed = switch (try TypeSyntax.parseAndStore(
        &store,
        .global(300),
        source,
        0,
        &cursor,
    )) {
        .parsed => |value| value,
        .failure, .excluded => return error.TestUnexpectedResult,
    };
    const root = switch (parsed.root) {
        .present => |index| store.node(index) orelse return error.TestUnexpectedResult,
        .absent => return error.TestUnexpectedResult,
    };
    const fields = switch (root.data) {
        .record => |range| store.fieldSlice(range) orelse return error.TestUnexpectedResult,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(@as(usize, 2), fields.len);
    try std.testing.expectEqualStrings("readonly id?: number", fields[0].span.text(source));
    try std.testing.expectEqualStrings("cb: (arg: string) => boolean", fields[1].span.text(source));
    const function = switch (fields[1].type_child) {
        .present => |index| store.node(index) orelse return error.TestUnexpectedResult,
        .absent => return error.TestUnexpectedResult,
    };
    const params = switch (function.data) {
        .function => |value| store.paramSlice(value.params) orelse return error.TestUnexpectedResult,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(@as(usize, 1), params.len);
    try std.testing.expectEqualStrings("arg: string", params[0].span.text(source));
}

test "bare groups keep consumed spans and lower as absent children" {
    try expectEquivalent("const value: {value:();tail:number} = undefined;");
    try expectEquivalent("const value: (value:())=>number = undefined;");

    const record_source = "{value:();tail:number} = value;";
    var record_store = TypeSyntax.Store.init(std.testing.allocator, record_source);
    defer record_store.deinit();
    var record_cursor = TypeSyntax.Cursor.init(record_source);
    const record_parsed = switch (try TypeSyntax.parseAndStore(
        &record_store,
        .global(300),
        record_source,
        0,
        &record_cursor,
    )) {
        .parsed => |value| value,
        .failure, .excluded => return error.TestUnexpectedResult,
    };
    const record_node = switch (record_parsed.root) {
        .present => |index| record_store.node(index) orelse return error.TestUnexpectedResult,
        .absent => return error.TestUnexpectedResult,
    };
    const fields = switch (record_node.data) {
        .record => |range| record_store.fieldSlice(range) orelse return error.TestUnexpectedResult,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqualStrings("value:()", fields[0].span.text(record_source));
    const field_group = switch (fields[0].type_child) {
        .present => |index| record_store.node(index) orelse return error.TestUnexpectedResult,
        .absent => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(TypeSyntax.NodeTag.group, field_group.tag);
    try std.testing.expectEqualStrings("()", field_group.semantic_span.text(record_source));
    switch (field_group.data) {
        .group => |child| switch (child) {
            .absent => {},
            .present => return error.TestUnexpectedResult,
        },
        else => return error.TestUnexpectedResult,
    }

    var record_pool = TypePool.init(std.testing.allocator);
    defer record_pool.deinit(std.testing.allocator);
    var record_env = TypeEnv.init(std.testing.allocator, &record_pool);
    defer record_env.deinit();
    try lowerSyntaxStore(std.testing.allocator, &record_store, &record_pool, &record_env);
    const lowered_record = record_env.getVarTypeByBinding(0, 300) orelse
        return error.TestUnexpectedResult;
    const lowered_fields = record_pool.getRecordFields(lowered_record);
    try std.testing.expectEqual(@as(usize, 2), lowered_fields.len);
    try std.testing.expectEqual(null_type_idx, lowered_fields[0].type_idx);

    const function_source = "(value:())=>number = value;";
    var function_store = TypeSyntax.Store.init(std.testing.allocator, function_source);
    defer function_store.deinit();
    var function_cursor = TypeSyntax.Cursor.init(function_source);
    const function_parsed = switch (try TypeSyntax.parseAndStore(
        &function_store,
        .global(300),
        function_source,
        0,
        &function_cursor,
    )) {
        .parsed => |value| value,
        .failure, .excluded => return error.TestUnexpectedResult,
    };
    const function_node = switch (function_parsed.root) {
        .present => |index| function_store.node(index) orelse return error.TestUnexpectedResult,
        .absent => return error.TestUnexpectedResult,
    };
    const params = switch (function_node.data) {
        .function => |value| function_store.paramSlice(value.params) orelse return error.TestUnexpectedResult,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqualStrings("value:()", params[0].span.text(function_source));
    const parameter_group = switch (params[0].type_child) {
        .present => |index| function_store.node(index) orelse return error.TestUnexpectedResult,
        .absent => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(TypeSyntax.NodeTag.group, parameter_group.tag);
    try std.testing.expectEqualStrings("()", parameter_group.semantic_span.text(function_source));
    switch (parameter_group.data) {
        .group => |child| switch (child) {
            .absent => {},
            .present => return error.TestUnexpectedResult,
        },
        else => return error.TestUnexpectedResult,
    }

    var function_pool = TypePool.init(std.testing.allocator);
    defer function_pool.deinit(std.testing.allocator);
    var function_env = TypeEnv.init(std.testing.allocator, &function_pool);
    defer function_env.deinit();
    try lowerSyntaxStore(std.testing.allocator, &function_store, &function_pool, &function_env);
    const lowered_function = function_env.getVarTypeByBinding(0, 300) orelse
        return error.TestUnexpectedResult;
    const lowered_info = function_pool.getFunctionInfo(lowered_function);
    try std.testing.expectEqual(@as(usize, 1), lowered_info.params.len);
    try std.testing.expectEqual(null_type_idx, lowered_info.params[0].type_idx);
}

test "direct primitive slice binds a grouped and suffixed annotation" {
    const source = "const text: (((string))) tolerated_suffix = input;";
    try expectEquivalent(source);

    var parser = try JsParser.initTyped(std.testing.allocator, std.testing.allocator, source);
    defer parser.deinit();
    var atoms = AtomTable.init(std.testing.allocator);
    defer atoms.deinit();
    parser.setAtomTable(&atoms);
    _ = try parser.parse();

    const annotation = parser.type_store.annotations.items[0];
    try std.testing.expectEqual(@as(u16, @intCast(@intFromEnum(try atoms.intern("text")))), annotation.binding.name_atom);
    try std.testing.expectEqual(@as(u16, 0), annotation.binding.scope_id);
}

test "direct parser reports missing and unmatched primitive locations" {
    const cases = [_]struct {
        source: []const u8,
        offset: u32,
        end_offset: u32,
    }{
        .{ .source = "const value: = 1;", .offset = 13, .end_offset = 14 },
        .{ .source = "let n: (number;", .offset = 14, .end_offset = 15 },
    };
    for (cases) |case| {
        var parser = try JsParser.initTyped(std.testing.allocator, std.testing.allocator, case.source);
        defer parser.deinit();
        try std.testing.expectError(error.ParseError, parser.parse());
        const errors = parser.errors.getErrors();
        try std.testing.expectEqual(@as(usize, 1), errors.len);
        try std.testing.expectEqual(case.offset, errors[0].location.offset);
        try std.testing.expectEqual(case.end_offset, errors[0].location.end_offset);
    }

    const legacy_shape = try compare(std.testing.allocator, "let n: (number;", .collect);
    try std.testing.expectEqual(OutOfSliceReason.malformed_annotation, legacy_shape.out_of_slice);
}

test "direct type depth admits 512 and refuses opener 513" {
    var source: std.ArrayListUnmanaged(u8) = .empty;
    defer source.deinit(std.testing.allocator);
    try source.appendSlice(std.testing.allocator, "const value: ");
    try source.appendNTimes(std.testing.allocator, '(', TypeSyntax.max_type_depth);
    try source.appendSlice(std.testing.allocator, "number");
    try source.appendNTimes(std.testing.allocator, ')', TypeSyntax.max_type_depth);
    try source.appendSlice(std.testing.allocator, " = 1;");
    try expectEquivalent(source.items);

    var refused: std.ArrayListUnmanaged(u8) = .empty;
    defer refused.deinit(std.testing.allocator);
    try refused.appendSlice(std.testing.allocator, "const value: ");
    try refused.appendNTimes(std.testing.allocator, '(', TypeSyntax.max_type_depth + 1);
    try refused.appendSlice(std.testing.allocator, "number");
    try refused.appendNTimes(std.testing.allocator, ')', TypeSyntax.max_type_depth + 1);
    try refused.appendSlice(std.testing.allocator, " any = 1;");
    const verdict = try compare(std.testing.allocator, refused.items, .collect);
    switch (verdict) {
        .admission_refused => |refusal| {
            try std.testing.expectEqual(AdmissionKind.nesting_too_deep, refusal.first);
            try std.testing.expectEqual(@as(usize, 1), refusal.count);
        },
        else => return error.TestUnexpectedResult,
    }

    var earlier_any: std.ArrayListUnmanaged(u8) = .empty;
    defer earlier_any.deinit(std.testing.allocator);
    try earlier_any.appendSlice(std.testing.allocator, "const value: any | ");
    try earlier_any.appendNTimes(std.testing.allocator, '(', TypeSyntax.max_type_depth + 1);
    try earlier_any.appendSlice(std.testing.allocator, "number = 1;");
    const ordered = try compare(std.testing.allocator, earlier_any.items, .collect);
    switch (ordered) {
        .out_of_slice => |reason| try std.testing.expectEqual(
            OutOfSliceReason.malformed_annotation,
            reason,
        ),
        else => return error.TestUnexpectedResult,
    }
    const compile_ordered = try compare(std.testing.allocator, earlier_any.items, .compile);
    switch (compile_ordered) {
        .out_of_slice => |reason| try std.testing.expectEqual(
            OutOfSliceReason.malformed_annotation,
            reason,
        ),
        else => return error.TestUnexpectedResult,
    }

    try refused.appendSlice(std.testing.allocator, " function excluded() {}");
    const excluded = try compare(std.testing.allocator, refused.items, .collect);
    switch (excluded) {
        .out_of_slice => |reason| try std.testing.expectEqual(
            OutOfSliceReason.function_declaration,
            reason,
        ),
        else => return error.TestUnexpectedResult,
    }
}

test "direct parser keeps the binding token for a missing semicolon" {
    const source = "let value: string";
    var parser = try JsParser.initTyped(std.testing.allocator, std.testing.allocator, source);
    defer parser.deinit();
    var atoms = AtomTable.init(std.testing.allocator);
    defer atoms.deinit();
    parser.setAtomTable(&atoms);
    try std.testing.expectError(error.MissingSemicolon, parser.parse());
    const errors = parser.errors.getErrors();
    try std.testing.expectEqual(@as(usize, 1), errors.len);
    try std.testing.expectEqual(engine.parser.ErrorKind.missing_semicolon, errors[0].kind);
    try std.testing.expectEqual(@as(u32, 4), errors[0].location.offset);
    try std.testing.expectEqual(@as(u32, 9), errors[0].location.end_offset);
    try expectEquivalent(source);
}

test "depth refusals keep only complete primitive annotations eligible" {
    const cases = [_]struct {
        body: []const u8,
        closed: bool,
    }{
        .{ .body = "number | string", .closed = true },
        .{ .body = "number", .closed = false },
    };
    for (cases) |case| {
        var source: std.ArrayListUnmanaged(u8) = .empty;
        defer source.deinit(std.testing.allocator);
        try source.appendSlice(std.testing.allocator, "const value: ");
        try source.appendNTimes(std.testing.allocator, '(', TypeSyntax.max_type_depth + 1);
        try source.appendSlice(std.testing.allocator, case.body);
        if (case.closed) {
            try source.appendNTimes(std.testing.allocator, ')', TypeSyntax.max_type_depth + 1);
        }
        try source.appendSlice(std.testing.allocator, " = 1;");
        const verdict = try compare(std.testing.allocator, source.items, .collect);
        switch (verdict) {
            .out_of_slice => |reason| try std.testing.expectEqual(
                OutOfSliceReason.malformed_annotation,
                reason,
            ),
            else => return error.TestUnexpectedResult,
        }
    }
}

test "runtime any and quoted removed names are not admission refusals" {
    try expectEquivalent(
        "const any = \"void\"; const value: string = any; const text = \"any\";",
    );

    const runtime_void = try compare(
        std.testing.allocator,
        "const value: number = void 0;",
        .collect,
    );
    switch (runtime_void) {
        .equivalent => {},
        else => return error.TestUnexpectedResult,
    }
}

test "annotation refusals preserve legacy order and stage precedence" {
    const root_any = try compare(std.testing.allocator, "const value: any = 1;", .collect);
    try std.testing.expectEqual(AdmissionKind.any_type, root_any.admission_refused.first);
    const root_void = try compare(std.testing.allocator, "const value: void = 1;", .collect);
    try std.testing.expectEqual(AdmissionKind.void_type, root_void.admission_refused.first);

    var checked = switch (try preflight(
        std.testing.allocator,
        "const value: number void any = 1;",
        .collect,
    )) {
        .eligible => |value| value,
        .out_of_slice => return error.TestUnexpectedResult,
    };
    defer checked.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), checked.diagnostics.items.len);
    try std.testing.expectEqual(AdmissionKind.any_type, checked.diagnostics.items[0].kind);
    try std.testing.expectEqual(AdmissionKind.void_type, checked.diagnostics.items[1].kind);

    const compile_verdict = try compare(
        std.testing.allocator,
        "const broken = ; const value: number void any = 1;",
        .compile,
    );
    try std.testing.expectEqual(AdmissionKind.any_type, compile_verdict.admission_refused.first);
    try std.testing.expectEqual(@as(usize, 1), compile_verdict.admission_refused.count);
    const collect_verdict = try compare(
        std.testing.allocator,
        "const broken = ; const value: number void any = 1;",
        .collect,
    );
    try std.testing.expectEqual(AdmissionKind.any_type, collect_verdict.admission_refused.first);
    try std.testing.expectEqual(@as(usize, 2), collect_verdict.admission_refused.count);

    const crlf = try compare(std.testing.allocator, "const value:\r\n any = 1;", .collect);
    try std.testing.expectEqual(AdmissionKind.any_type, crlf.admission_refused.first);

    const suffix_any = try compare(
        std.testing.allocator,
        "const value: number many = 1;",
        .collect,
    );
    try std.testing.expectEqual(AdmissionKind.any_type, suffix_any.admission_refused.first);
    try std.testing.expectEqual(@as(usize, 1), suffix_any.admission_refused.count);

    const aliases = [_]struct {
        source: []const u8,
        kind: AdmissionKind,
    }{
        .{ .source = "const value: number Array<string> = 1;", .kind = .array_type_alias },
        .{ .source = "const value: number ReadonlyArray<string> = 1;", .kind = .readonly_array_type_alias },
    };
    for (aliases) |case| {
        const verdict = try compare(std.testing.allocator, case.source, .collect);
        try std.testing.expectEqual(case.kind, verdict.admission_refused.first);
        try std.testing.expectEqual(@as(usize, 1), verdict.admission_refused.count);
    }

    const any_array = try compare(
        std.testing.allocator,
        "const value: any Array<string> = 1;",
        .collect,
    );
    try std.testing.expectEqual(AdmissionKind.any_type, any_array.admission_refused.first);
    try std.testing.expectEqual(@as(usize, 2), any_array.admission_refused.count);

    try expectEquivalent("const value: `outer${`any`}` = undefined;");
}

test "out of slice census covers every private reason" {
    const fixtures = [_]struct {
        reason: OutOfSliceReason,
        source: []const u8,
    }{
        .{ .reason = .function_declaration, .source = "function f() {} const x: number = 1;" },
        .{ .reason = .import_declaration, .source = "import { x } from \"m\"; const y: number = 1;" },
        .{ .reason = .export_declaration, .source = "export const x: number = 1;" },
        .{ .reason = .type_declaration, .source = "structural X<T> = T; const x: number = 1;" },
        .{ .reason = .multiple_bindings, .source = "const { x } = y; const z: number = 1;" },
        .{ .reason = .annotation_count, .source = "const x: number = 1; const y: number = 2;" },
        .{ .reason = .compound_annotation, .source = "const x: Named<number> = y;" },
        .{ .reason = .malformed_annotation, .source = "const x: (number = 1;" },
        .{ .reason = .unsupported_annotation_position, .source = "const x = a: b; const y: number = 1;" },
        .{ .reason = .assertion_syntax, .source = "const x: number = y as number;" },
        .{ .reason = .template_literal, .source = "const x: string = `x`;" },
        .{ .reason = .regex_literal, .source = "const x: unknown = /x/;" },
        .{ .reason = .type_comment, .source = "const x: /* comment */ number = 1;" },
        .{ .reason = .unsupported_initializer, .source = "const x: number = value.member;" },
        .{ .reason = .lone_carriage_return, .source = "const value:\r any = 1;" },
    };
    var seen = std.EnumSet(OutOfSliceReason).initEmpty();
    for (fixtures) |fixture| {
        const verdict = try compare(std.testing.allocator, fixture.source, .collect);
        try std.testing.expectEqual(fixture.reason, verdict.out_of_slice);
        try std.testing.expect(!seen.contains(fixture.reason));
        seen.insert(fixture.reason);
    }
    inline for (@typeInfo(OutOfSliceReason).@"enum".fields) |field| {
        const reason: OutOfSliceReason = @enumFromInt(field.value);
        try std.testing.expect(seen.contains(reason));
    }
}

test "preflight closes diagnostics before a later exclusion" {
    const Context = struct {
        fn run(allocator: std.mem.Allocator) !void {
            const outcome = try preflight(
                allocator,
                "const value: number any = 1; function f() {}",
                .collect,
            );
            switch (outcome) {
                .eligible => |eligible| {
                    var owned = eligible;
                    defer owned.deinit(allocator);
                    return error.TestUnexpectedResult;
                },
                .out_of_slice => |reason| try std.testing.expectEqual(
                    OutOfSliceReason.function_declaration,
                    reason,
                ),
            }
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Context.run, .{});
}

test "primitive comparison declines ambiguous angle tokens" {
    const sources = [_][]const u8{
        "const value: number = f<string>(seed);",
        "const value: number = f<any>(seed);",
        "const value: number = seed < other;",
        "const value: number = seed > other;",
    };
    for (sources) |source| {
        const verdict = try compare(std.testing.allocator, source, .collect);
        try std.testing.expectEqual(OutOfSliceReason.unsupported_initializer, verdict.out_of_slice);
    }
}

test "admission comparison closes every allocation failure" {
    const Context = struct {
        fn run(allocator: std.mem.Allocator) !void {
            const verdict = try compare(allocator, "const value: any = 1;", .collect);
            try std.testing.expectEqual(AdmissionKind.any_type, verdict.admission_refused.first);
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Context.run, .{});
}

test "successful compound comparison closes every allocation failure" {
    const Context = struct {
        fn run(allocator: std.mem.Allocator) !void {
            const source =
                "const value: { pair: [number, string]; choice: number | string; " ++
                "cb: (x: number) => `v${string}` } & { tags: string[] } = undefined;";
            const verdict = try compare(allocator, source, .collect);
            switch (verdict) {
                .equivalent => {},
                else => return error.TestUnexpectedResult,
            }
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Context.run, .{});
}

test "direct parser and lowering close every allocation failure" {
    const ParserContext = struct {
        fn run(type_allocator: std.mem.Allocator) !void {
            const source =
                "const value: { readonly id?: number; tags: string[][]; cb: (x: number) => `v${string}` } = input;";
            var parser = try JsParser.initTyped(std.testing.allocator, type_allocator, source);
            defer parser.deinit();
            var atoms = AtomTable.init(std.testing.allocator);
            defer atoms.deinit();
            parser.setAtomTable(&atoms);
            _ = try parser.parse();
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, ParserContext.run, .{});

    const SharedParserContext = struct {
        fn run(allocator: std.mem.Allocator) !void {
            const source = "const value: number = make(1.25);";
            var atoms = AtomTable.init(std.testing.allocator);
            defer atoms.deinit();
            var parser = try JsParser.initTyped(allocator, allocator, source);
            defer parser.deinit();
            parser.setAtomTable(&atoms);
            _ = try parser.parse();
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, SharedParserContext.run, .{});

    const LowerContext = struct {
        fn run(allocator: std.mem.Allocator) !void {
            var pool = TypePool.init(allocator);
            defer pool.deinit(allocator);
            try pool.ensureHealthy();
            var env = TypeEnv.init(allocator, &pool);
            defer env.deinit();
            try pool.ensureHealthy();
            try env.ensureHealthy();

            const source =
                "{ pair: [number, string]; choice: number | string; " ++
                "cb: (x: number) => `v${string}` } & { tags: string[] } = value;";
            var store = TypeSyntax.Store.init(allocator, source);
            defer store.deinit();
            var cursor = TypeSyntax.Cursor.init(source);
            switch (try TypeSyntax.parseAndStore(&store, .global(300), source, 0, &cursor)) {
                .parsed => {},
                .failure, .excluded => return error.TestUnexpectedResult,
            }
            try lowerSyntaxStore(allocator, &store, &pool, &env);
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, LowerContext.run, .{});
}

test "runtime comparison includes constants locations and complete empty upvalue state" {
    try expectEquivalent(
        "const seed = \"x\"; const value: number = make(1.25 + 2 * 3); let copy = seed;",
    );
}

fn legacyAnnotationSource(allocator: std.mem.Allocator, annotation: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "const value: {s} = undefined;", .{annotation});
}

fn legacyValueTypeText(prepared: *PreparedSource) ?[]const u8 {
    const type_map = prepared.typeMap() orelse return null;
    for (type_map.entries.items) |entry| {
        if (entry.kind != .var_annotation) continue;
        const name = type_map.getNameText(entry) orelse continue;
        if (std.mem.eql(u8, name, "value")) return type_map.getTypeText(entry);
    }
    return null;
}

fn expectLegacyTypeText(annotation: []const u8) !void {
    const allocator = std.testing.allocator;
    const source = try legacyAnnotationSource(allocator, annotation);
    defer allocator.free(source);

    var prepared = try PreparedSource.init(allocator, source, "legacy-baseline.ts", .{});
    defer prepared.deinit();
    const type_map = prepared.typeMap().?;
    try std.testing.expectEqual(@as(usize, 1), type_map.entries.items.len);
    try std.testing.expectEqualStrings(annotation, legacyValueTypeText(&prepared).?);
}

fn expectLegacyColonRetained(annotation: []const u8) !void {
    const allocator = std.testing.allocator;
    const source = try legacyAnnotationSource(allocator, annotation);
    defer allocator.free(source);

    var prepared = try PreparedSource.init(allocator, source, "legacy-baseline.ts", .{});
    defer prepared.deinit();
    try std.testing.expectEqual(@as(usize, 0), prepared.typeMap().?.entries.items.len);
    try std.testing.expectEqualStrings(source, prepared.parserInput());
}

fn parseLegacyAnnotation(pool: *TypePool, annotation: []const u8) !TypeIndex {
    try expectLegacyTypeText(annotation);
    const idx = parseTypeExpr(pool, std.testing.allocator, annotation);
    try pool.ensureHealthy();
    return idx;
}

fn expectTag(pool: *const TypePool, idx: TypeIndex, tag: TypeTag) !void {
    try std.testing.expectEqual(tag, pool.getTag(idx).?);
}

fn expectLiteralNumber(pool: *const TypePool, idx: TypeIndex, value: i16) !void {
    try expectTag(pool, idx, .t_literal_number);
    const data = pool.getData(idx).?;
    try std.testing.expectEqual(value, @as(i16, @bitCast(data.a)));
}

test "legacy compound preparation preserves exact admitted type text" {
    const annotations = [_][]const u8{
        "{ \"x\": number }",
        "{ x number }",
        "{ x: }",
        "{ /*c*/ x: number }",
        "{ x: number /*c*/ }",
        "{ x: number y: string }",
        "number |",
        "{ x: number } &",
        "(x: number y: string) => number",
        "(x: number) number",
        "(x: number) =>",
        "(number)",
        "() => number",
        "number [ ]",
        "number /*c*/ []",
        "{ cb: (x?: number) => number }",
        "{ any: number }",
        "string | 200",
        "string | 1.5",
        "string | 0x10",
        "string | 1_000",
        "true",
        "`\\${string}`",
        "`x${}`",
        "\"GET\"",
        "(200)",
        "(| number | string)",
        "readonly number[]",
        "[string, number]",
        "readonly [string, number]",
        "``",
    };
    try std.testing.expectEqual(@as(usize, 31), annotations.len);
    var observed: usize = 0;
    for (annotations) |annotation| {
        try expectLegacyTypeText(annotation);
        observed += 1;
    }
    try std.testing.expectEqual(annotations.len, observed);
}

test "legacy preparation retains a colon when the root is not an annotation" {
    const annotations = [_][]const u8{
        "| number | string",
        "& { x: number }",
        "1.5",
        "0x10",
        "1e3",
        "1_000",
        "32768",
        "/*c*/ number",
    };
    try std.testing.expectEqual(@as(usize, 8), annotations.len);
    var observed: usize = 0;
    for (annotations) |annotation| {
        try expectLegacyColonRetained(annotation);
        observed += 1;
    }
    try std.testing.expectEqual(annotations.len, observed);
}

test "legacy preparation keeps root refusal context separate from record context" {
    const allocator = std.testing.allocator;
    const cases = [_]struct {
        annotation: []const u8,
        expected: anyerror,
    }{
        .{ .annotation = "(x?: number) => number", .expected = error.OptionalParameter },
        .{ .annotation = "{ value: any }", .expected = error.UnsupportedAnyType },
    };
    try std.testing.expectEqual(@as(usize, 2), cases.len);
    var observed: usize = 0;
    for (cases) |case| {
        const source = try legacyAnnotationSource(allocator, case.annotation);
        defer allocator.free(source);
        var unexpected = PreparedSource.init(allocator, source, "legacy-baseline.ts", .{}) catch |err| {
            try std.testing.expectEqual(case.expected, err);
            observed += 1;
            continue;
        };
        unexpected.deinit();
        return error.TestUnexpectedResult;
    }
    try std.testing.expectEqual(cases.len, observed);
}

test "legacy compound family and semantic quirk census is exhaustive" {
    const allocator = std.testing.allocator;
    var pool = TypePool.init(allocator);
    defer pool.deinit(allocator);
    var families = std.EnumSet(CompoundFamily).initEmpty();
    var quirks = std.EnumSet(SemanticQuirk).initEmpty();

    const quoted = try parseLegacyAnnotation(&pool, "{ \"x\": number }");
    try expectTag(&pool, quoted, .t_record);
    try std.testing.expectEqual(@as(usize, 0), pool.getRecordFields(quoted).len);
    try std.testing.expectEqualStrings("R0", try type_key.typeKey(&pool, allocator, quoted));
    quirks.insert(.quoted_record_prefix);

    const missing_colon = try parseLegacyAnnotation(&pool, "{ x number }");
    try expectTag(&pool, missing_colon, .t_record);
    try std.testing.expectEqual(@as(usize, 0), pool.getRecordFields(missing_colon).len);
    quirks.insert(.missing_record_colon_prefix);

    const missing_type = try parseLegacyAnnotation(&pool, "{ x: }");
    const missing_fields = pool.getRecordFields(missing_type);
    try std.testing.expectEqual(@as(usize, 1), missing_fields.len);
    try std.testing.expectEqualStrings("x", pool.getName(missing_fields[0].name_start, missing_fields[0].name_len));
    try std.testing.expectEqual(null_type_idx, missing_fields[0].type_idx);
    try std.testing.expectError(error.AbsentType, type_key.typeKey(&pool, allocator, missing_type));
    quirks.insert(.missing_record_type_absent);

    const comment_prefix = try parseLegacyAnnotation(&pool, "{ /*c*/ x: number }");
    try expectTag(&pool, comment_prefix, .t_record);
    try std.testing.expectEqual(@as(usize, 0), pool.getRecordFields(comment_prefix).len);
    quirks.insert(.record_comment_prefix);

    const comment_after = try parseLegacyAnnotation(&pool, "{ x: number /*c*/ }");
    const comment_after_fields = pool.getRecordFields(comment_after);
    try std.testing.expectEqual(@as(usize, 1), comment_after_fields.len);
    try std.testing.expectEqualStrings("x", pool.getName(comment_after_fields[0].name_start, comment_after_fields[0].name_len));
    try std.testing.expectEqual(pool.idx_number, comment_after_fields[0].type_idx);
    quirks.insert(.record_comment_after_field);

    const omitted_separator = try parseLegacyAnnotation(&pool, "{ x: number y: string }");
    const omitted_fields = pool.getRecordFields(omitted_separator);
    try std.testing.expectEqual(@as(usize, 2), omitted_fields.len);
    try std.testing.expectEqualStrings("x", pool.getName(omitted_fields[0].name_start, omitted_fields[0].name_len));
    try std.testing.expectEqual(pool.idx_number, omitted_fields[0].type_idx);
    try std.testing.expectEqualStrings("y", pool.getName(omitted_fields[1].name_start, omitted_fields[1].name_len));
    try std.testing.expectEqual(pool.idx_string, omitted_fields[1].type_idx);
    try std.testing.expect((try type_key.typeKey(&pool, allocator, omitted_separator)).len > 0);
    quirks.insert(.omitted_record_separator);

    const readonly_optional = try parseLegacyAnnotation(&pool, "{ readonly id?: number; name: string }");
    const readonly_fields = pool.getRecordFields(readonly_optional);
    try std.testing.expectEqual(@as(usize, 2), readonly_fields.len);
    try std.testing.expectEqualStrings("id", pool.getName(readonly_fields[0].name_start, readonly_fields[0].name_len));
    try std.testing.expect(readonly_fields[0].readonly);
    try std.testing.expect(readonly_fields[0].optional);
    try std.testing.expectEqual(pool.idx_number, readonly_fields[0].type_idx);
    try std.testing.expectEqualStrings("name", pool.getName(readonly_fields[1].name_start, readonly_fields[1].name_len));
    try std.testing.expect(!readonly_fields[1].readonly);
    try std.testing.expect(!readonly_fields[1].optional);
    try std.testing.expectEqual(pool.idx_string, readonly_fields[1].type_idx);
    families.insert(.record);
    quirks.insert(.readonly_optional_fields);

    for ([_][]const u8{ "number[][]", "number [] []" }) |annotation| {
        const repeated_array = try parseLegacyAnnotation(&pool, annotation);
        try expectTag(&pool, repeated_array, .t_array);
        try std.testing.expect(!pool.isReadonlyArray(repeated_array));
        const inner_array = pool.getArrayElement(repeated_array);
        try expectTag(&pool, inner_array, .t_array);
        try std.testing.expect(!pool.isReadonlyArray(inner_array));
        try std.testing.expectEqual(pool.idx_number, pool.getArrayElement(inner_array));
    }
    families.insert(.array);
    quirks.insert(.mutable_repeated_arrays);

    try std.testing.expectEqual(pool.idx_number, try parseLegacyAnnotation(&pool, "number [ ]"));
    quirks.insert(.separated_array_brackets);
    try std.testing.expectEqual(pool.idx_number, try parseLegacyAnnotation(&pool, "number /*c*/ []"));
    quirks.insert(.comment_before_array);

    const readonly_array = try parseLegacyAnnotation(&pool, "readonly number[]");
    try expectTag(&pool, readonly_array, .t_array);
    try std.testing.expect(pool.isReadonlyArray(readonly_array));
    try std.testing.expectEqual(pool.idx_number, pool.getArrayElement(readonly_array));
    quirks.insert(.readonly_array_flag);

    const trailing_tuple = try parseLegacyAnnotation(&pool, "[string, number,]");
    try expectTag(&pool, trailing_tuple, .t_tuple);
    try std.testing.expectEqualSlices(
        TypeIndex,
        &.{ pool.idx_string, pool.idx_number },
        pool.getTupleElements(trailing_tuple),
    );
    families.insert(.tuple);
    quirks.insert(.tuple_trailing_comma);

    const readonly_tuple = try parseLegacyAnnotation(&pool, "readonly [string, number]");
    try expectTag(&pool, readonly_tuple, .t_tuple);
    try std.testing.expectEqualSlices(
        TypeIndex,
        &.{ pool.idx_string, pool.idx_number },
        pool.getTupleElements(readonly_tuple),
    );
    quirks.insert(.readonly_tuple_erasure);

    const grouped_union = try parseLegacyAnnotation(&pool, "(| number | string)");
    try expectTag(&pool, grouped_union, .t_union);
    try std.testing.expectEqualSlices(
        TypeIndex,
        &.{ pool.idx_number, pool.idx_string },
        pool.getUnionMembers(grouped_union),
    );
    quirks.insert(.grouped_leading_union);

    try std.testing.expectEqual(pool.idx_number, try parseLegacyAnnotation(&pool, "number |"));
    quirks.insert(.trailing_union_prefix);

    const trailing_intersection = try parseLegacyAnnotation(&pool, "{ x: number } &");
    const trailing_fields = pool.getRecordFields(trailing_intersection);
    try std.testing.expectEqual(@as(usize, 1), trailing_fields.len);
    try std.testing.expectEqualStrings("x", pool.getName(trailing_fields[0].name_start, trailing_fields[0].name_len));
    try std.testing.expectEqual(pool.idx_number, trailing_fields[0].type_idx);
    quirks.insert(.trailing_intersection_prefix);

    const mixed = try parseLegacyAnnotation(&pool, "string | number & boolean");
    try expectTag(&pool, mixed, .t_union);
    const mixed_members = pool.getUnionMembers(mixed);
    try std.testing.expectEqual(@as(usize, 2), mixed_members.len);
    try std.testing.expectEqual(pool.idx_string, mixed_members[0]);
    try expectTag(&pool, mixed_members[1], .t_intersection);
    try std.testing.expectEqualSlices(
        TypeIndex,
        &.{ pool.idx_number, pool.idx_boolean },
        pool.getIntersectionMembers(mixed_members[1]),
    );
    families.insert(.union_type);
    families.insert(.intersection);
    quirks.insert(.intersection_precedence);

    const nullable = try parseLegacyAnnotation(&pool, "string | undefined");
    try expectTag(&pool, nullable, .t_nullable);
    try std.testing.expectEqual(pool.idx_string, pool.getNullableInner(nullable));
    try std.testing.expect((try type_key.typeKey(&pool, allocator, nullable)).len > 0);
    quirks.insert(.nullable_shorthand);

    const wide_undefined = try parseLegacyAnnotation(&pool, "string | number | undefined");
    try expectTag(&pool, wide_undefined, .t_union);
    try std.testing.expectEqualSlices(
        TypeIndex,
        &.{ pool.idx_string, pool.idx_number, pool.idx_undefined },
        pool.getUnionMembers(wide_undefined),
    );
    quirks.insert(.wider_undefined_union);

    const numeric_cases = [_]struct { annotation: []const u8, value: i16 }{
        .{ .annotation = "string | 200", .value = 200 },
        .{ .annotation = "string | 1.5", .value = 1 },
        .{ .annotation = "string | 0x10", .value = 0 },
        .{ .annotation = "string | 1_000", .value = 1 },
    };
    var numeric_count: usize = 0;
    for (numeric_cases) |case| {
        const numeric = try parseLegacyAnnotation(&pool, case.annotation);
        const numeric_members = pool.getUnionMembers(numeric);
        try std.testing.expectEqual(@as(usize, 2), numeric_members.len);
        try std.testing.expectEqual(pool.idx_string, numeric_members[0]);
        try expectLiteralNumber(&pool, numeric_members[1], case.value);
        numeric_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 4), numeric_count);
    quirks.insert(.numeric_token_prefix);

    const nested_optional = try parseLegacyAnnotation(&pool, "{ cb: (x?: number) => number }");
    const nested_fields = pool.getRecordFields(nested_optional);
    try std.testing.expectEqual(@as(usize, 1), nested_fields.len);
    const nested_function = pool.getFunctionInfo(nested_fields[0].type_idx);
    try std.testing.expectEqual(@as(usize, 1), nested_function.params.len);
    try std.testing.expectEqualStrings("x", pool.getName(nested_function.params[0].name_start, nested_function.params[0].name_len));
    try std.testing.expect(nested_function.params[0].optional);
    try std.testing.expectEqual(pool.idx_number, nested_function.params[0].type_idx);
    try std.testing.expectEqual(pool.idx_number, nested_function.ret);
    quirks.insert(.nested_optional_parameter);

    const any_key = try parseLegacyAnnotation(&pool, "{ any: number }");
    const any_fields = pool.getRecordFields(any_key);
    try std.testing.expectEqual(@as(usize, 1), any_fields.len);
    try std.testing.expectEqualStrings("any", pool.getName(any_fields[0].name_start, any_fields[0].name_len));
    try std.testing.expectEqual(pool.idx_number, any_fields[0].type_idx);
    quirks.insert(.any_member_key);

    const missing_comma = try parseLegacyAnnotation(&pool, "(x: number y: string) => number");
    const comma_info = pool.getFunctionInfo(missing_comma);
    try std.testing.expectEqual(@as(usize, 2), comma_info.params.len);
    try std.testing.expectEqualStrings("x", pool.getName(comma_info.params[0].name_start, comma_info.params[0].name_len));
    try std.testing.expectEqual(pool.idx_number, comma_info.params[0].type_idx);
    try std.testing.expectEqualStrings("y", pool.getName(comma_info.params[1].name_start, comma_info.params[1].name_len));
    try std.testing.expectEqual(pool.idx_string, comma_info.params[1].type_idx);
    try std.testing.expectEqual(pool.idx_number, comma_info.ret);
    quirks.insert(.missing_function_comma);

    const missing_arrow = try parseLegacyAnnotation(&pool, "(x: number) number");
    try expectTag(&pool, missing_arrow, .t_function);
    try std.testing.expectEqual(null_type_idx, pool.getFunctionInfo(missing_arrow).ret);
    try std.testing.expectError(error.AbsentType, type_key.typeKey(&pool, allocator, missing_arrow));
    quirks.insert(.missing_function_arrow);

    const missing_return = try parseLegacyAnnotation(&pool, "(x: number) =>");
    try expectTag(&pool, missing_return, .t_function);
    try std.testing.expectEqual(null_type_idx, pool.getFunctionInfo(missing_return).ret);
    try std.testing.expectError(error.AbsentType, type_key.typeKey(&pool, allocator, missing_return));
    quirks.insert(.missing_function_return);

    const named_function = try parseLegacyAnnotation(&pool, "(left: string, right: number) => boolean");
    const named_info = pool.getFunctionInfo(named_function);
    try std.testing.expectEqual(@as(usize, 2), named_info.params.len);
    try std.testing.expectEqualStrings("left", pool.getName(named_info.params[0].name_start, named_info.params[0].name_len));
    try std.testing.expect(!named_info.params[0].optional);
    try std.testing.expectEqual(pool.idx_string, named_info.params[0].type_idx);
    try std.testing.expectEqualStrings("right", pool.getName(named_info.params[1].name_start, named_info.params[1].name_len));
    try std.testing.expect(!named_info.params[1].optional);
    try std.testing.expectEqual(pool.idx_number, named_info.params[1].type_idx);
    try std.testing.expectEqual(pool.idx_boolean, named_info.ret);
    try std.testing.expect((try type_key.typeKey(&pool, allocator, named_function)).len > 0);
    families.insert(.function);
    quirks.insert(.named_function_parameters);

    const escaped_template = try parseLegacyAnnotation(&pool, "`\\${string}`");
    const escaped_parts = pool.getTemplateParts(escaped_template);
    try std.testing.expectEqual(@as(usize, 2), escaped_parts.len);
    try std.testing.expectEqual(.literal, escaped_parts[0].kind);
    try std.testing.expectEqualStrings("\\", pool.getName(escaped_parts[0].name_start, escaped_parts[0].name_len));
    try std.testing.expectEqual(.type_slot, escaped_parts[1].kind);
    try std.testing.expectEqual(pool.idx_string, escaped_parts[1].type_idx);
    quirks.insert(.escaped_template_slot);

    const empty_slot = try parseLegacyAnnotation(&pool, "`x${}`");
    const empty_parts = pool.getTemplateParts(empty_slot);
    try std.testing.expectEqual(@as(usize, 2), empty_parts.len);
    try std.testing.expectEqual(.literal, empty_parts[0].kind);
    try std.testing.expectEqualStrings("x", pool.getName(empty_parts[0].name_start, empty_parts[0].name_len));
    try std.testing.expectEqual(.type_slot, empty_parts[1].kind);
    try std.testing.expectEqual(null_type_idx, empty_parts[1].type_idx);
    try std.testing.expectError(error.AbsentType, type_key.typeKey(&pool, allocator, empty_slot));
    quirks.insert(.empty_template_slot);

    try std.testing.expectEqual(null_type_idx, try parseLegacyAnnotation(&pool, "``"));
    quirks.insert(.empty_template_root);

    const multipart = try parseLegacyAnnotation(&pool, "`pre-${string}-mid-${number}-post`");
    const multipart_parts = pool.getTemplateParts(multipart);
    try std.testing.expectEqual(@as(usize, 5), multipart_parts.len);
    try std.testing.expectEqual(.literal, multipart_parts[0].kind);
    try std.testing.expectEqualStrings("pre-", pool.getName(multipart_parts[0].name_start, multipart_parts[0].name_len));
    try std.testing.expectEqual(.type_slot, multipart_parts[1].kind);
    try std.testing.expectEqual(pool.idx_string, multipart_parts[1].type_idx);
    try std.testing.expectEqual(.literal, multipart_parts[2].kind);
    try std.testing.expectEqualStrings("-mid-", pool.getName(multipart_parts[2].name_start, multipart_parts[2].name_len));
    try std.testing.expectEqual(.type_slot, multipart_parts[3].kind);
    try std.testing.expectEqual(pool.idx_number, multipart_parts[3].type_idx);
    try std.testing.expectEqual(.literal, multipart_parts[4].kind);
    try std.testing.expectEqualStrings("-post", pool.getName(multipart_parts[4].name_start, multipart_parts[4].name_len));
    try std.testing.expect((try type_key.typeKey(&pool, allocator, multipart)).len > 0);
    families.insert(.template);
    quirks.insert(.multi_part_template);

    const string_literal = try parseLegacyAnnotation(&pool, "\"GET\"");
    try expectTag(&pool, string_literal, .t_literal_string);
    try std.testing.expectEqualStrings("GET", pool.getLiteralStringValue(string_literal).?);
    const boolean_literal = try parseLegacyAnnotation(&pool, "true");
    try expectTag(&pool, boolean_literal, .t_literal_bool);
    try std.testing.expectEqual(@as(u16, 1), pool.getData(boolean_literal).?.a);
    families.insert(.literal);
    quirks.insert(.literal_values);

    try pool.ensureHealthy();
    try std.testing.expectEqual(@as(usize, 8), @typeInfo(CompoundFamily).@"enum".fields.len);
    try std.testing.expectEqual(@as(usize, 31), @typeInfo(SemanticQuirk).@"enum".fields.len);
    inline for (@typeInfo(CompoundFamily).@"enum".fields) |field| {
        const family: CompoundFamily = @enumFromInt(field.value);
        try std.testing.expect(families.contains(family));
    }
    inline for (@typeInfo(SemanticQuirk).@"enum".fields) |field| {
        const quirk: SemanticQuirk = @enumFromInt(field.value);
        try std.testing.expect(quirks.contains(quirk));
    }
}

test "legacy admitted function types preserve the packed parameter boundary" {
    const allocator = std.testing.allocator;
    inline for (.{ 15, 16 }) |count| {
        var annotation: std.ArrayList(u8) = .empty;
        defer annotation.deinit(allocator);
        try annotation.append(allocator, '(');
        for (0..count) |i| {
            if (i > 0) try annotation.appendSlice(allocator, ", ");
            var name_buffer: [32]u8 = undefined;
            const parameter = try std.fmt.bufPrint(&name_buffer, "p{d}: number", .{i});
            try annotation.appendSlice(allocator, parameter);
        }
        try annotation.appendSlice(allocator, ") => string");
        try expectLegacyTypeText(annotation.items);

        var pool = TypePool.init(allocator);
        defer pool.deinit(allocator);
        const idx = parseTypeExpr(&pool, allocator, annotation.items);
        if (count == 16) {
            try std.testing.expectEqual(null_type_idx, idx);
            try std.testing.expectError(error.TypePoolCapacityExceeded, pool.ensureHealthy());
        } else {
            try pool.ensureHealthy();
            try expectTag(&pool, idx, .t_function);
            const info = pool.getFunctionInfo(idx);
            try std.testing.expectEqual(@as(usize, count), info.params.len);
            for (info.params, 0..) |parameter, i| {
                var name_buffer: [8]u8 = undefined;
                const name = try std.fmt.bufPrint(&name_buffer, "p{d}", .{i});
                try std.testing.expectEqualStrings(name, pool.getName(parameter.name_start, parameter.name_len));
                try std.testing.expectEqual(pool.idx_number, parameter.type_idx);
                try std.testing.expect(!parameter.optional);
            }
            try std.testing.expectEqual(pool.idx_string, info.ret);
            try std.testing.expect((try type_key.typeKey(&pool, allocator, idx)).len > 0);
        }
    }
}

test "legacy deep arrays separate admission and canonical key depth" {
    const allocator = std.testing.allocator;
    inline for (.{ 63, 64 }) |layers| {
        const annotation = "number" ++ "[]" ** layers;
        var pool = TypePool.init(allocator);
        defer pool.deinit(allocator);
        const idx = try parseLegacyAnnotation(&pool, annotation);
        var element = idx;
        for (0..layers) |_| {
            try expectTag(&pool, element, .t_array);
            try std.testing.expect(!pool.isReadonlyArray(element));
            element = pool.getArrayElement(element);
        }
        try std.testing.expectEqual(pool.idx_number, element);
        try pool.ensureHealthy();
        if (layers == 64) {
            try std.testing.expectError(error.TypeKeyTooDeep, type_key.typeKey(&pool, allocator, idx));
        } else {
            const key = try type_key.typeKey(&pool, allocator, idx);
            try std.testing.expectEqualStrings("Am" ** layers ++ "n", key);
        }
    }
}
