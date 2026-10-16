//! Private comparison between legacy stripping and direct type syntax parsing.
//!
//! This module is test-only. It adds no public frontend choice or fallback.

const std = @import("std");
const engine = @import("zts-engine");
const retired_types_module = @import("zts-base").module_specifier.retired_types_module;
const type_env_mod = @import("type_env.zig");
const type_key = @import("type_key.zig");
const type_pool_mod = @import("type_pool.zig");
const type_syntax_lowering = @import("type_syntax_lowering.zig");
const module_types = @import("module_types.zig");
const abi_types = @import("abi_types.zig");
const effect_inference = @import("effect_inference.zig");
const function_specs = @import("function_specs.zig");
const handler_verifier_mod = @import("handler_verifier.zig");
const pipeline_mod = @import("pipeline.zig");
const handler_contract_mod = @import("zts-contracts").handler_contract;
const contract_types = @import("zts-contracts").contract_types;
const strict_checker_mod = @import("strict_checker.zig");
const type_checker_mod = @import("type_checker.zig");

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
const null_type_idx = type_pool_mod.null_type_idx;
const parseTypeExpr = type_pool_mod.parseTypeExpr;

fn serializeContractForConsumerTest(
    allocator: std.mem.Allocator,
    contract: *const contract_types.HandlerContract,
) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try handler_contract_mod.writeContractJson(contract, &output.writer);
    return output.toOwnedSlice();
}

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
    var has_erased_prefix = false;
    var last_erased_type_span: ?TypeSyntax.Span = null;

    while (current.type != .eof) {
        if (TypeSyntax.tokenStartsGenericList(source, current)) {
            const scanned = (try TypeSyntax.scanBalancedGenericList(
                allocator,
                source,
                current.start,
            )) orelse return .{ .out_of_slice = .unsupported_initializer };
            if (!TypeSyntax.isPrivateErasedPrefixListEligible(source, scanned) or
                TypeSyntax.rawLooksLikeComparison(source, current.start))
            {
                return .{ .out_of_slice = .unsupported_initializer };
            }
            var opener_tokenizer = tokenizer;
            var opener = current;
            while (opener.type != .eof and opener.start < scanned.span.end) {
                advance(&opener_tokenizer, &opener);
            }
            if (opener.type != .lbrace or !try scanPreflightErasedPrefix(
                allocator,
                source,
                &tokenizer,
                &current,
                &result.diagnostics,
                .statement_block,
            )) {
                return .{ .out_of_slice = .unsupported_initializer };
            }
            has_erased_prefix = true;
            if (current.type == .semicolon) advance(&tokenizer, &current);
            continue;
        }
        switch (current.type) {
            .kw_function => {
                if (!try scanPreflightGenericFunction(
                    allocator,
                    source,
                    &tokenizer,
                    &current,
                    &result.diagnostics,
                )) return .{ .out_of_slice = .function_declaration };
                continue;
            },
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
                        if (excluded.generic_list_span) |list| {
                            if (findFirstRemovedForm(
                                source,
                                @as(usize, list.start + 1),
                                @as(usize, list.end - 1),
                            )) |diagnostic| {
                                try appendDiagnosticAtNewPosition(
                                    allocator,
                                    &result.diagnostics,
                                    diagnostic,
                                );
                            }
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
                        if (declaration.generic_owner) |owner_index| {
                            const list = declaration_store.generic_owners.items[owner_index].list_span;
                            if (findFirstRemovedForm(
                                source,
                                @as(usize, list.start + 1),
                                @as(usize, list.end - 1),
                            )) |diagnostic| {
                                try appendDiagnosticAtNewPosition(
                                    allocator,
                                    &result.diagnostics,
                                    diagnostic,
                                );
                            }
                        }
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
            const initializer_prefix = current;
            advance(&tokenizer, &current);
            const refused = try scanInitializer(
                allocator,
                source,
                &tokenizer,
                &current,
                initializer_prefix,
                &result.diagnostics,
                &has_erased_prefix,
            );
            if (refused) |reason| return .{ .out_of_slice = reason };
        }

        if (current.type == .semicolon) {
            advance(&tokenizer, &current);
        } else if (current.type != .eof) {
            return .{ .out_of_slice = .unsupported_initializer };
        }
    }

    if (annotation_count != 1 and declaration_count == 0 and !has_erased_prefix) {
        return .{ .out_of_slice = .annotation_count };
    }
    if (mode == .compile and result.diagnostics.items.len > 1) {
        result.diagnostics.items.len = 1;
    }
    owns_result = false;
    return .{ .eligible = result };
}

fn scanPreflightGenericFunction(
    allocator: std.mem.Allocator,
    source: []const u8,
    tokenizer: *Tokenizer,
    current: *Token,
    diagnostics: *std.ArrayListUnmanaged(AdmissionDiagnostic),
) !bool {
    if (!try scanPreflightGenericFunctionHeader(
        allocator,
        source,
        tokenizer,
        current,
        diagnostics,
    )) return false;
    var function_depth: u16 = 1;
    while (function_depth > 0) {
        if (current.type == .eof) return false;
        if (current.type == .rbrace) {
            function_depth -= 1;
            advance(tokenizer, current);
            continue;
        }
        if (current.type == .kw_function) {
            if (function_depth >= TypeSyntax.max_type_depth) return false;
            if (!try scanPreflightGenericFunctionHeader(
                allocator,
                source,
                tokenizer,
                current,
                diagnostics,
            )) return false;
            function_depth += 1;
            continue;
        }
        if (current.type == .kw_const or current.type == .kw_let) {
            advance(tokenizer, current);
            if (current.type != .identifier) return false;
            advance(tokenizer, current);
            if (current.type == .colon or current.type != .assign) return false;
            const initializer_prefix = current.*;
            advance(tokenizer, current);
            if (try scanInitializer(
                allocator,
                source,
                tokenizer,
                current,
                initializer_prefix,
                diagnostics,
                null,
            )) |_| return false;
            if (current.type != .semicolon) return false;
            advance(tokenizer, current);
            continue;
        }
        if (current.type == .kw_return) {
            const initializer_prefix = current.*;
            advance(tokenizer, current);
            if (try scanInitializer(
                allocator,
                source,
                tokenizer,
                current,
                initializer_prefix,
                diagnostics,
                null,
            )) |_| return false;
            if (current.type != .semicolon) return false;
            advance(tokenizer, current);
            continue;
        }
        return false;
    }
    return true;
}

fn scanPreflightGenericFunctionHeader(
    allocator: std.mem.Allocator,
    source: []const u8,
    tokenizer: *Tokenizer,
    current: *Token,
    diagnostics: *std.ArrayListUnmanaged(AdmissionDiagnostic),
) !bool {
    const keyword = current.*;
    advance(tokenizer, current);
    if (current.type != .identifier) return false;
    const name = current.*;
    const name_gap = source[@as(usize, keyword.start + keyword.len)..@as(usize, name.start)];
    if (std.mem.trim(u8, name_gap, " \t\r\n").len != 0) return false;
    advance(tokenizer, current);
    if (!TypeSyntax.tokenStartsGenericList(source, current.*) or
        name.start + name.len != current.start) return false;
    const scanned = (try TypeSyntax.scanBalancedGenericList(
        allocator,
        source,
        current.start,
    )) orelse return false;
    if (!TypeSyntax.isPrivateGenericListEligible(source, scanned)) return false;
    if (findFirstRemovedForm(
        source,
        @as(usize, scanned.span.start + 1),
        @as(usize, scanned.span.end - 1),
    )) |diagnostic| {
        try appendDiagnosticAtNewPosition(allocator, diagnostics, diagnostic);
    }

    while (current.type != .eof and current.start < scanned.span.end) {
        advance(tokenizer, current);
    }
    if (current.type != .lparen) return false;
    const gap = source[@as(usize, scanned.span.end)..@as(usize, current.start)];
    if (std.mem.trim(u8, gap, " \t\r\n").len != 0) return false;

    advance(tokenizer, current);
    if (current.type != .rparen) while (true) {
        if (current.type != .identifier) return false;
        advance(tokenizer, current);
        if (current.type == .rparen) break;
        if (current.type != .comma) return false;
        advance(tokenizer, current);
    };
    advance(tokenizer, current);
    if (current.type != .lbrace) return false;
    advance(tokenizer, current);
    return true;
}

fn scanPreflightGenericArrow(
    allocator: std.mem.Allocator,
    source: []const u8,
    tokenizer: *Tokenizer,
    current: *Token,
    previous: Token,
    diagnostics: *std.ArrayListUnmanaged(AdmissionDiagnostic),
) !bool {
    if (!TypeSyntax.isPrivateArrowPrefixEligible(source, previous, current.start)) return false;
    const scanned = (try TypeSyntax.scanBalancedGenericList(
        allocator,
        source,
        current.start,
    )) orelse return false;
    if (!TypeSyntax.isPrivateGenericListEligible(source, scanned)) return false;
    if (findFirstRemovedForm(
        source,
        @as(usize, scanned.span.start + 1),
        @as(usize, scanned.span.end - 1),
    )) |diagnostic| try appendDiagnosticAtNewPosition(allocator, diagnostics, diagnostic);

    while (current.type != .eof and current.start < scanned.span.end) {
        advance(tokenizer, current);
    }
    if (current.type != .lparen) return false;
    const gap = source[@as(usize, scanned.span.end)..@as(usize, current.start)];
    if (std.mem.trim(u8, gap, " \t\r\n").len != 0) return false;
    advance(tokenizer, current);
    if (current.type != .rparen) while (true) {
        if (current.type != .identifier) return false;
        advance(tokenizer, current);
        if (current.type == .rparen) break;
        if (current.type != .comma) return false;
        advance(tokenizer, current);
    };
    advance(tokenizer, current);
    if (current.type != .arrow) return false;
    advance(tokenizer, current);
    if (current.type == .lbrace) return false;
    return try scanPreflightArrowBodyExpression(
        allocator,
        source,
        tokenizer,
        current,
        diagnostics,
    );
}

fn scanPreflightArrowBodyExpression(
    allocator: std.mem.Allocator,
    source: []const u8,
    tokenizer: *Tokenizer,
    current: *Token,
    diagnostics: *std.ArrayListUnmanaged(AdmissionDiagnostic),
) !bool {
    switch (current.type) {
        .identifier, .number, .string_literal, .true_lit, .false_lit, .null_lit, .undefined_lit => advance(tokenizer, current),
        else => return false,
    }
    if (TypeSyntax.tokenStartsGenericList(source, current.*)) {
        switch (try scanPreflightExplicitCall(
            allocator,
            source,
            tokenizer,
            current,
            diagnostics,
        )) {
            .scanned => {},
            .not_call, .excluded => return false,
        }
    }
    if (current.type == .lparen) {
        var depth: u16 = 1;
        advance(tokenizer, current);
        while (current.type != .eof and depth > 0) {
            switch (current.type) {
                .lparen => depth +|= 1,
                .rparen => depth -= 1,
                .identifier,
                .number,
                .string_literal,
                .true_lit,
                .false_lit,
                .null_lit,
                .undefined_lit,
                .comma,
                => {},
                else => return false,
            }
            advance(tokenizer, current);
        }
        if (depth != 0) return false;
    }
    return current.type == .semicolon or current.type == .comma or
        current.type == .rparen or current.type == .rbrace;
}

const PreflightExplicitCall = enum {
    not_call,
    excluded,
    scanned,
};

fn scanPreflightExplicitCall(
    allocator: std.mem.Allocator,
    source: []const u8,
    tokenizer: *Tokenizer,
    current: *Token,
    diagnostics: *std.ArrayListUnmanaged(AdmissionDiagnostic),
) !PreflightExplicitCall {
    if (!TypeSyntax.rawLooksLikeComparison(source, current.start)) return .not_call;
    const scanned = switch (try TypeSyntax.scanExplicitCallTypeArguments(
        allocator,
        source,
        current.start,
    )) {
        .not_call => return .not_call,
        .excluded => return .excluded,
        .scanned => |value| value,
    };
    if (!TypeSyntax.isPrivateGenericListEligible(source, scanned)) return .excluded;
    if (findFirstRemovedForm(
        source,
        @as(usize, scanned.span.start + 1),
        @as(usize, scanned.span.end - 1),
    )) |diagnostic| try appendDiagnosticAtNewPosition(allocator, diagnostics, diagnostic);
    while (current.type != .eof and current.start < scanned.span.end) {
        advance(tokenizer, current);
    }
    if (current.type != .lparen or current.start != scanned.span.end) return .excluded;
    return .scanned;
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
    allocator: std.mem.Allocator,
    source: []const u8,
    tokenizer: *Tokenizer,
    current: *Token,
    initial_previous: Token,
    diagnostics: *std.ArrayListUnmanaged(AdmissionDiagnostic),
    has_erased_prefix: ?*bool,
) !?OutOfSliceReason {
    var depth: u16 = 0;
    var can_end_expression = false;
    var previous = initial_previous;

    while (current.type != .eof) {
        if (current.type == .semicolon and depth == 0) return null;
        if (TypeSyntax.tokenStartsGenericList(source, current.*)) {
            if (!can_end_expression) {
                var arrow_tokenizer = tokenizer.*;
                var arrow_current = current.*;
                if (try scanPreflightGenericArrow(
                    allocator,
                    source,
                    &arrow_tokenizer,
                    &arrow_current,
                    previous,
                    diagnostics,
                )) {
                    tokenizer.* = arrow_tokenizer;
                    current.* = arrow_current;
                    can_end_expression = true;
                    continue;
                }
                if (try scanPreflightErasedPrefix(
                    allocator,
                    source,
                    tokenizer,
                    current,
                    diagnostics,
                    .root_expression,
                )) {
                    if (has_erased_prefix) |flag| flag.* = true;
                    can_end_expression = true;
                    continue;
                }
                return .unsupported_initializer;
            }
            switch (try scanPreflightExplicitCall(
                allocator,
                source,
                tokenizer,
                current,
                diagnostics,
            )) {
                .scanned => {
                    depth +|= 1;
                    can_end_expression = false;
                    advance(tokenizer, current);
                    continue;
                },
                .excluded => return .unsupported_initializer,
                .not_call => {},
            }
            can_end_expression = false;
            advance(tokenizer, current);
            continue;
        }
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
            .gt,
            .le,
            .ge,
            .lt_lt,
            .gt_gt,
            .gt_gt_gt,
            .ampersand_ampersand,
            .pipe_pipe,
            .question_question,
            .assign,
            .plus_assign,
            .minus_assign,
            .star_assign,
            .slash_assign,
            .percent_assign,
            .ampersand_assign,
            .pipe_assign,
            .caret_assign,
            .lt_lt_assign,
            .gt_gt_assign,
            .gt_gt_gt_assign,
            .star_star_assign,
            .ampersand_ampersand_assign,
            .pipe_pipe_assign,
            .question_question_assign,
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
        previous = current.*;
        advance(tokenizer, current);
    }
    return null;
}

const ErasedPrefixPreflightContext = enum {
    root_expression,
    nested_group,
    statement_block,
};

const ErasedPrefixPreflightFrame = struct {
    state: enum {
        group_value,
        nested_number,
        group_close,
        object_key,
        object_colon,
        object_value,
        object_close,
        block_const,
        block_name,
        block_assign,
        block_value,
        block_semicolon,
        block_close,
    },
    allow_arrow: bool = false,
};

fn scanPreflightErasedPrefix(
    allocator: std.mem.Allocator,
    source: []const u8,
    tokenizer: *Tokenizer,
    current: *Token,
    diagnostics: *std.ArrayListUnmanaged(AdmissionDiagnostic),
    context: ErasedPrefixPreflightContext,
) !bool {
    var local_tokenizer = tokenizer.*;
    var local = current.*;
    var frames: [TypeSyntax.max_type_depth]ErasedPrefixPreflightFrame = undefined;
    var depth: usize = 0;
    if (!try pushPreflightErasedPrefixFrame(
        allocator,
        source,
        &local_tokenizer,
        &local,
        diagnostics,
        frames[0..],
        &depth,
        context,
    )) return false;

    while (depth > 0) {
        const frame = &frames[depth - 1];
        switch (frame.state) {
            .nested_number => {
                if (local.type != .number) return false;
                advance(&local_tokenizer, &local);
                frame.state = .group_close;
            },
            .group_value => {
                if (local.type == .number) {
                    advance(&local_tokenizer, &local);
                    frame.state = .group_close;
                } else if (TypeSyntax.tokenStartsGenericList(source, local)) {
                    frame.state = .group_close;
                    if (!try pushPreflightErasedPrefixFrame(
                        allocator,
                        source,
                        &local_tokenizer,
                        &local,
                        diagnostics,
                        frames[0..],
                        &depth,
                        .nested_group,
                    )) return false;
                } else if (local.type == .lparen and frame.allow_arrow) {
                    advance(&local_tokenizer, &local);
                    if (local.type != .identifier) return false;
                    const parameter = local.text(source);
                    advance(&local_tokenizer, &local);
                    if (local.type != .rparen) return false;
                    advance(&local_tokenizer, &local);
                    if (local.type != .arrow) return false;
                    advance(&local_tokenizer, &local);
                    if (local.type != .identifier or !std.mem.eql(u8, parameter, local.text(source))) {
                        return false;
                    }
                    advance(&local_tokenizer, &local);
                    frame.state = .group_close;
                } else return false;
            },
            .group_close => {
                if (local.type != .rparen) return false;
                advance(&local_tokenizer, &local);
                depth -= 1;
            },
            .object_key => {
                if (local.type != .identifier) return false;
                advance(&local_tokenizer, &local);
                frame.state = .object_colon;
            },
            .object_colon => {
                if (local.type != .colon) return false;
                advance(&local_tokenizer, &local);
                frame.state = .object_value;
            },
            .object_value => {
                if (local.type == .number) {
                    advance(&local_tokenizer, &local);
                    frame.state = .object_close;
                } else if (TypeSyntax.tokenStartsGenericList(source, local)) {
                    frame.state = .object_close;
                    if (!try pushPreflightErasedPrefixFrame(
                        allocator,
                        source,
                        &local_tokenizer,
                        &local,
                        diagnostics,
                        frames[0..],
                        &depth,
                        .nested_group,
                    )) return false;
                } else return false;
            },
            .object_close => {
                if (local.type != .rbrace) return false;
                advance(&local_tokenizer, &local);
                depth -= 1;
            },
            .block_const => {
                if (local.type != .kw_const) return false;
                advance(&local_tokenizer, &local);
                frame.state = .block_name;
            },
            .block_name => {
                if (local.type != .identifier) return false;
                advance(&local_tokenizer, &local);
                frame.state = .block_assign;
            },
            .block_assign => {
                if (local.type != .assign) return false;
                advance(&local_tokenizer, &local);
                frame.state = .block_value;
            },
            .block_value => {
                if (local.type != .number) return false;
                advance(&local_tokenizer, &local);
                frame.state = .block_semicolon;
            },
            .block_semicolon => {
                if (local.type != .semicolon) return false;
                advance(&local_tokenizer, &local);
                frame.state = .block_close;
            },
            .block_close => {
                if (local.type != .rbrace) return false;
                advance(&local_tokenizer, &local);
                depth -= 1;
            },
        }
    }
    tokenizer.* = local_tokenizer;
    current.* = local;
    return true;
}

fn pushPreflightErasedPrefixFrame(
    allocator: std.mem.Allocator,
    source: []const u8,
    tokenizer: *Tokenizer,
    current: *Token,
    diagnostics: *std.ArrayListUnmanaged(AdmissionDiagnostic),
    frames: []ErasedPrefixPreflightFrame,
    depth: *usize,
    context: ErasedPrefixPreflightContext,
) !bool {
    if (depth.* == frames.len or
        !TypeSyntax.tokenStartsGenericList(source, current.*) or
        TypeSyntax.rawLooksLikeComparison(source, current.start))
    {
        return false;
    }
    const scanned = (try TypeSyntax.scanBalancedGenericList(
        allocator,
        source,
        current.start,
    )) orelse return false;
    if (!TypeSyntax.isPrivateErasedPrefixListEligible(source, scanned)) return false;
    while (current.type != .eof and current.start < scanned.span.end) advance(tokenizer, current);
    const required_opener: ?TokenType = switch (context) {
        .root_expression => null,
        .nested_group => .lparen,
        .statement_block => .lbrace,
    };
    if (required_opener) |expected| {
        if (current.type != expected) return false;
    } else if (current.type != .lparen and current.type != .lbrace) return false;
    const gap = source[@as(usize, scanned.span.end)..@as(usize, current.start)];
    if (std.mem.trim(u8, gap, " \t\r\n").len != 0) return false;
    if (findFirstRemovedForm(
        source,
        @as(usize, scanned.span.start + 1),
        @as(usize, scanned.span.end - 1),
    )) |diagnostic| try appendDiagnosticAtNewPosition(allocator, diagnostics, diagnostic);
    frames[depth.*] = .{
        .state = switch (context) {
            .statement_block => .block_const,
            .nested_group => .nested_number,
            .root_expression => if (current.type == .lparen)
                .group_value
            else
                .object_key,
        },
        .allow_arrow = context == .root_expression and current.type == .lparen,
    };
    depth.* += 1;
    advance(tokenizer, current);
    return true;
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
    if (prepared.stripDiagnostics().len != 0) {
        return .{ .differs = "legacy preparation produced unmodeled diagnostics" };
    }

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
    if (direct.type_store.annotations.items.len == 0 and
        direct.type_store.declarations.items.len == 0 and
        direct.type_store.erased_type_prefixes.items.len == 0)
    {
        return .{ .differs = "the direct parser retained no type syntax" };
    }
    if (!try compareLowering(allocator, &prepared, &direct)) {
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
    direct: *const JsParser,
) !bool {
    const direct_store = &direct.type_store;
    var legacy_pool = TypePool.init(allocator);
    defer legacy_pool.deinit(allocator);
    try legacy_pool.ensureHealthy();
    var legacy_env = TypeEnv.init(allocator, &legacy_pool);
    defer legacy_env.deinit();
    try legacy_pool.ensureHealthy();
    try legacy_env.ensureHealthy();
    module_types.populateModuleTypes(&legacy_env, &legacy_pool, allocator);
    abi_types.populateHandlerAbiTypes(&legacy_env, &legacy_pool, allocator);
    try legacy_env.populateFromTypeMap(prepared.typeMap() orelse return false);
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
    try lowerSyntaxStore(
        allocator,
        direct_store,
        &direct_pool,
        &direct_env,
        engine.parser.IrView.fromIRStore(&direct.nodes, &direct.constants),
    );
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
        var legacy_generic_list: ?[]const u8 = null;
        for (type_map.entries.items) |candidate| {
            if (candidate.kind == .generic_params and candidate.name_start == entry.name_start and
                candidate.name_end == entry.name_end)
            {
                legacy_generic_list = type_map.getTypeText(candidate);
                break;
            }
        }
        if ((legacy_generic_list != null) != (declaration.generic_owner != null)) return false;
        if (legacy_generic_list) |legacy_list| {
            const owner = direct_store.generic_owners.items[declaration.generic_owner.?];
            if (!std.mem.eql(u8, legacy_list, owner.list_span.text(direct_store.source))) return false;
        }
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
    if (legacy_env.generic_aliases.count() != direct_env.generic_aliases.count()) return false;
    var legacy_generic_aliases = legacy_env.generic_aliases.iterator();
    while (legacy_generic_aliases.next()) |entry| {
        const direct_alias = direct_env.generic_aliases.get(entry.key_ptr.*) orelse return false;
        if (entry.value_ptr.param_count != direct_alias.param_count) return false;
        for (
            entry.value_ptr.param_names[0..entry.value_ptr.param_count],
            direct_alias.param_names[0..direct_alias.param_count],
        ) |legacy_name, direct_name| {
            if (!std.mem.eql(u8, legacy_name, direct_name)) return false;
        }
        if (!try orderedTypeEqual(
            allocator,
            &legacy_pool,
            entry.value_ptr.body,
            &direct_pool,
            direct_alias.body,
        )) return false;
    }
    var direct_generic_aliases = direct_env.generic_aliases.iterator();
    while (direct_generic_aliases.next()) |entry| {
        if (legacy_env.generic_aliases.get(entry.key_ptr.*) == null) return false;
    }

    if (legacy_env.call_type_args.count() != direct_env.call_type_args.count()) return false;
    var legacy_calls = legacy_env.call_type_args.iterator();
    while (legacy_calls.next()) |entry| {
        const direct_call = direct_env.call_type_args.get(entry.key_ptr.*) orelse return false;
        if (entry.value_ptr.count != direct_call.count) return false;
        for (
            entry.value_ptr.args[0..entry.value_ptr.count],
            direct_call.args[0..direct_call.count],
        ) |legacy_argument, direct_argument| {
            if (!try orderedTypeEqual(
                allocator,
                &legacy_pool,
                legacy_argument,
                &direct_pool,
                direct_argument,
            )) return false;
        }
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

fn expectOrderedPrefixStoreLowering(
    allocator: std.mem.Allocator,
    prepared: *PreparedSource,
    store: *const TypeSyntax.Store,
    view: engine.parser.IrView,
) !void {
    var legacy_pool = TypePool.init(allocator);
    defer legacy_pool.deinit(allocator);
    var legacy_env = TypeEnv.init(allocator, &legacy_pool);
    defer legacy_env.deinit();
    module_types.populateModuleTypes(&legacy_env, &legacy_pool, allocator);
    abi_types.populateHandlerAbiTypes(&legacy_env, &legacy_pool, allocator);
    try legacy_env.populateFromTypeMap(prepared.typeMap() orelse
        return error.TestUnexpectedResult);
    try legacy_pool.ensureHealthy();
    try legacy_env.ensureHealthy();

    var direct_pool = TypePool.init(allocator);
    defer direct_pool.deinit(allocator);
    var direct_env = TypeEnv.init(allocator, &direct_pool);
    defer direct_env.deinit();
    module_types.populateModuleTypes(&direct_env, &direct_pool, allocator);
    abi_types.populateHandlerAbiTypes(&direct_env, &direct_pool, allocator);
    try lowerSyntaxStore(allocator, store, &direct_pool, &direct_env, view);
    try direct_pool.ensureHealthy();
    try direct_env.ensureHealthy();

    try std.testing.expectEqual(legacy_pool.nodes.items.len, direct_pool.nodes.items.len);
    for (0..legacy_pool.nodes.items.len) |index| {
        const type_index: TypeIndex = @intCast(index);
        try std.testing.expect(try orderedTypeEqual(
            allocator,
            &legacy_pool,
            type_index,
            &direct_pool,
            type_index,
        ));
    }
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
    ir_view: engine.parser.IrView,
) !void {
    return lowerSyntaxStoreInternal(allocator, store, pool, env, ir_view);
}

fn lowerSyntaxStoreWithoutRuntimeOwners(
    allocator: std.mem.Allocator,
    store: *const TypeSyntax.Store,
    pool: *TypePool,
    env: *TypeEnv,
) !void {
    return lowerSyntaxStoreInternal(allocator, store, pool, env, null);
}

fn lowerSyntaxStoreInternal(
    allocator: std.mem.Allocator,
    store: *const TypeSyntax.Store,
    pool: *TypePool,
    env: *TypeEnv,
    ir_view: ?engine.parser.IrView,
) !void {
    try pool.ensureHealthy();
    try env.ensureHealthy();
    var application_bases = if (ir_view) |view|
        try store.planApplicationBasesWithIr(allocator, view)
    else
        try store.planApplicationBases(allocator);
    defer application_bases.deinit();

    const lowered = try allocator.alloc(TypeIndex, store.nodes.items.len);
    defer allocator.free(lowered);
    @memset(lowered, null_type_idx);

    for (store.declarations.items, 0..) |_, declaration_index| {
        try env.populateParsedDeclaration(
            store,
            &application_bases,
            lowered,
            declaration_index,
        );
    }
    env.finishTypeAliasPopulation();
    try env.ensureHealthy();

    var transient_owner_index: usize = 0;
    var transient_prefix_index: usize = 0;
    while (true) {
        while (transient_owner_index < store.generic_owners.items.len) {
            const owner = store.generic_owners.items[transient_owner_index];
            const runtime_identity = switch (owner.identity) {
                .function, .arrow => true,
                .structural_declaration, .nominal_declaration => false,
            };
            if (runtime_identity and std.meta.activeTag(owner.compatibility) == .declaration_parameters) break;
            transient_owner_index += 1;
        }
        while (transient_prefix_index < store.erased_type_prefixes.items.len and
            std.meta.activeTag(store.erased_type_prefixes.items[transient_prefix_index].compatibility) !=
                .legacy_parameter_projection)
        {
            transient_prefix_index += 1;
        }
        const syntax_owner = if (transient_owner_index < store.generic_owners.items.len)
            store.generic_owners.items[transient_owner_index]
        else
            null;
        const prefix = if (transient_prefix_index < store.erased_type_prefixes.items.len)
            store.erased_type_prefixes.items[transient_prefix_index]
        else
            null;
        if (syntax_owner == null and prefix == null) break;

        if (prefix == null or
            (syntax_owner != null and syntax_owner.?.list_span.start < prefix.?.list_span.start))
        {
            try lowerTransientGenericProjection(
                allocator,
                store,
                pool,
                env,
                &application_bases,
                syntax_owner.?.projected_parameters,
            );
            transient_owner_index += 1;
        } else {
            const projection = switch (prefix.?.compatibility) {
                .legacy_parameter_projection => |value| value,
                .ignored_parameters => unreachable,
            };
            try lowerTransientGenericProjection(
                allocator,
                store,
                pool,
                env,
                &application_bases,
                projection.projected_parameters,
            );
            transient_prefix_index += 1;
        }
    }

    const view = ir_view;
    var explicit_index: usize = 0;
    var compatibility_index: usize = 0;
    while (true) {
        while (compatibility_index < store.generic_owners.items.len and
            std.meta.activeTag(store.generic_owners.items[compatibility_index].compatibility) != .legacy_call_arguments)
        {
            compatibility_index += 1;
        }
        const explicit = if (explicit_index < store.explicit_call_arguments.items.len)
            store.explicit_call_arguments.items[explicit_index]
        else
            null;
        const compatibility_owner = if (compatibility_index < store.generic_owners.items.len)
            store.generic_owners.items[compatibility_index]
        else
            null;
        if (explicit == null and compatibility_owner == null) break;

        if (compatibility_owner == null or
            (explicit != null and explicit.?.list_span.start <= compatibility_owner.?.list_span.start))
        {
            const syntax_call = explicit.?;
            const runtime_view = view orelse return error.RuntimeOwnerRequired;
            try lowerCallArgumentRange(
                allocator,
                store,
                pool,
                env,
                lowered,
                &application_bases,
                runtime_view,
                syntax_call.owner,
                .call,
                syntax_call.semantic_fragments,
            );
            explicit_index += 1;
            continue;
        }

        const syntax_owner = compatibility_owner.?;
        const arguments = switch (syntax_owner.compatibility) {
            .legacy_call_arguments => |value| value,
            .declaration_parameters, .ignored_declaration_parameters => return error.InvalidGenericOwner,
        };
        const owner, const expected_tag = switch (syntax_owner.identity) {
            .function => |node| .{ node, engine.parser.NodeTag.function_expr },
            .arrow => |node| .{ node, engine.parser.NodeTag.arrow_function },
            .structural_declaration, .nominal_declaration => return error.InvalidGenericOwner,
        };
        const runtime_view = view orelse return error.RuntimeOwnerRequired;
        try lowerCallArgumentRange(
            allocator,
            store,
            pool,
            env,
            lowered,
            &application_bases,
            runtime_view,
            owner,
            expected_tag,
            arguments.semantic_fragments,
        );
        compatibility_index += 1;
    }

    for (store.annotations.items) |annotation| {
        const type_idx = try lowerOwnedRoot(
            allocator,
            store,
            pool,
            env,
            lowered,
            &application_bases,
            annotation.root,
            annotation.node_range,
            annotation.raw_span,
        );
        try env.bindVarType(annotation.binding.scope_id, annotation.binding.name_atom, type_idx);
    }
    try pool.ensureHealthy();
    try env.ensureHealthy();
}

fn lowerTransientGenericProjection(
    allocator: std.mem.Allocator,
    store: *const TypeSyntax.Store,
    pool: *TypePool,
    env: *TypeEnv,
    application_bases: *const TypeSyntax.Store.ApplicationBasePlan,
    projected_range: TypeSyntax.Range,
) !void {
    const projected = store.projectedGenericParameterSlice(projected_range) orelse
        return error.InvalidTypeRange;
    if (projected.len == 0) return;
    var inputs: [type_env_mod.MAX_TYPE_PARAMS]type_env_mod.ParsedGenericInput = undefined;
    for (projected, 0..) |parameter, index| {
        inputs[index] = .{ .name = parameter.name_span.text(store.source) };
    }
    var scope = try env.beginParsedGenerics(inputs[0..projected.len]);
    for (projected, 0..) |parameter, index| {
        if (index >= scope.count) break;
        const fragment_index = parameter.bound_fragment orelse continue;
        inputs[index].constraint = lowerGenericSemanticFragment(
            allocator,
            store,
            pool,
            env,
            &scope,
            application_bases,
            fragment_index,
            true,
        ) catch |err| return env.closeParsedScopeAfterError(&scope, err);
    }
    env.installParsedConstraints(&scope, inputs[0..projected.len]) catch |err|
        return env.closeParsedScopeAfterError(&scope, err);
    try env.endParsedGenerics(&scope);
}

fn lowerCallArgumentRange(
    allocator: std.mem.Allocator,
    store: *const TypeSyntax.Store,
    pool: *TypePool,
    env: *TypeEnv,
    lowered: []TypeIndex,
    application_bases: *const TypeSyntax.Store.ApplicationBasePlan,
    view: engine.parser.IrView,
    owner: NodeIndex,
    expected_tag: engine.parser.NodeTag,
    range: TypeSyntax.Range,
) !void {
    const tag = view.getTag(owner) orelse return error.InvalidGenericOwner;
    if (tag != expected_tag) return error.InvalidGenericOwner;
    const location = view.getLoc(owner) orelse return error.InvalidGenericOwner;
    const fragments = store.semanticFragmentSlice(range) orelse return error.InvalidTypeRange;
    var indices: [type_env_mod.MAX_TYPE_PARAMS]TypeIndex = undefined;
    for (fragments, 0..) |fragment, index| {
        indices[index] = try lowerOwnedRoot(
            allocator,
            store,
            pool,
            env,
            lowered,
            application_bases,
            fragment.root,
            fragment.node_range,
            fragment.raw_span,
        );
    }
    try env.putParsedCallTypeArgs(location.offset, indices[0..fragments.len]);
}

fn parserIrView(parser: *const JsParser) engine.parser.IrView {
    return engine.parser.IrView.fromIRStore(&parser.nodes, &parser.constants);
}

fn lowerGenericSemanticFragment(
    allocator: std.mem.Allocator,
    store: *const TypeSyntax.Store,
    pool: *TypePool,
    env: *TypeEnv,
    owner: *const type_env_mod.ParsedGenericScope,
    application_bases: *const TypeSyntax.Store.ApplicationBasePlan,
    fragment_index: u32,
    is_bound: bool,
) !TypeIndex {
    const fragment = store.semantic_fragments.items[fragment_index];
    const lowered = try allocator.alloc(TypeIndex, store.nodes.items.len);
    defer allocator.free(lowered);
    @memset(lowered, null_type_idx);
    const exact = fragment.raw_span.text(store.source);
    if (is_bound and std.mem.eql(u8, std.mem.trim(u8, exact, " \t\r\n"), "DictKey")) {
        return env.finishParsedBoundRoot(owner, exact, null_type_idx);
    }
    if (env.getTypeAlias(std.mem.trim(u8, exact, " \t\r\n"))) |type_idx| return type_idx;
    if (try env.resolveParsedGenericParam(owner, std.mem.trim(u8, exact, " \t\r\n"))) |type_idx| {
        return type_idx;
    }
    try type_syntax_lowering.lowerOwnedRange(
        allocator,
        store,
        pool,
        lowered,
        application_bases,
        fragment.node_range,
    );
    const root = try type_syntax_lowering.loweredChild(lowered, fragment.root, lowered.len);
    return if (is_bound)
        env.finishParsedBoundRoot(owner, exact, root)
    else
        env.finishParsedGenericRoot(owner, exact, root);
}

fn lowerOwnedRoot(
    allocator: std.mem.Allocator,
    store: *const TypeSyntax.Store,
    pool: *TypePool,
    env: *TypeEnv,
    lowered: []TypeIndex,
    application_bases: *const TypeSyntax.Store.ApplicationBasePlan,
    root: TypeSyntax.Child,
    node_range: TypeSyntax.Range,
    raw_span: TypeSyntax.Span,
) !TypeIndex {
    const exact = std.mem.trim(u8, raw_span.text(store.source), " \t\r\n");
    if (env.getTypeAlias(exact)) |type_idx| return type_idx;
    try type_syntax_lowering.lowerOwnedRange(allocator, store, pool, lowered, application_bases, node_range);
    return env.finishParsedTypeRoot(try type_syntax_lowering.loweredChild(lowered, root, lowered.len));
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
            .t_ref, .t_generic_param => if (!std.mem.eql(
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
            .t_dict => {
                try pending.append(allocator, .{
                    .left = left_pool.getDictKey(pair.left),
                    .right = right_pool.getDictKey(pair.right),
                });
                try pending.append(allocator, .{
                    .left = left_pool.getDictValue(pair.left),
                    .right = right_pool.getDictValue(pair.right),
                });
            },
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
        .differs => |reason| {
            std.debug.print("equivalence verdict: differs: {s}\n", .{reason});
            return error.TestUnexpectedResult;
        },
        .admission_refused => |refusal| {
            std.debug.print(
                "equivalence verdict: admission_refused: {s}, count={}\n",
                .{ @tagName(refusal.first), refusal.count },
            );
            return error.TestUnexpectedResult;
        },
        .out_of_slice => |reason| {
            std.debug.print("equivalence verdict: out_of_slice: {s}\n", .{@tagName(reason)});
            return error.TestUnexpectedResult;
        },
    }
}

fn expectFirstFunctionSliceRecords(parser: *const JsParser, source: []const u8) !void {
    try std.testing.expectEqual(@as(usize, 1), parser.type_store.annotations.items.len);
    try std.testing.expectEqual(@as(usize, 1), parser.type_store.parameter_annotations.items.len);
    try std.testing.expectEqual(@as(usize, 1), parser.type_store.function_signatures.items.len);
    try std.testing.expectEqual(@as(usize, 0), parser.type_store.type_only_modules.items.len);
    try std.testing.expectEqual(@as(usize, 0), parser.type_store.erased_type_prefixes.items.len);

    const view = engine.parser.IrView.fromIRStore(&parser.nodes, &parser.constants);
    try parser.type_store.validateRuntimeOwners(std.testing.allocator, view);

    var seed_declaration: ?NodeIndex = null;
    var function_declaration: ?NodeIndex = null;
    for (parser.nodes.tags.items, 0..) |tag, index| switch (tag) {
        .var_decl => {
            try std.testing.expect(seed_declaration == null);
            seed_declaration = @intCast(index);
        },
        .function_decl => {
            try std.testing.expect(function_declaration == null);
            function_declaration = @intCast(index);
        },
        else => {},
    };

    const seed = view.getVarDecl(seed_declaration orelse return error.TestUnexpectedResult) orelse
        return error.TestUnexpectedResult;
    try std.testing.expect(std.meta.eql(
        seed.binding,
        parser.type_store.annotations.items[0].binding,
    ));

    const signature = parser.type_store.function_signatures.items[0];
    try std.testing.expectEqual(engine.parser.NodeTag.function_expr, view.getTag(signature.owner).?);
    const wrapper = function_declaration orelse return error.TestUnexpectedResult;
    try parser.type_store.validateFunctionDeclarationWrapper(signature.owner, wrapper, view);

    const function = view.getFunction(signature.owner) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u8, 1), function.params_count);
    const parameter = parser.type_store.parameter_annotations.items[0];
    try std.testing.expectEqual(parameter.owner.pattern, view.getListIndex(function.params_start, 0));
    try std.testing.expect(std.meta.eql(
        parameter.owner.binding,
        view.paramBinding(parameter.owner.pattern).?,
    ));
    try std.testing.expectEqualStrings("string", parameter.value.raw_span.text(source));

    const return_syntax = signature.return_syntax orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(TypeSyntax.LegacyReturnKind.ordinary, return_syntax.legacy_return_kind);
    try std.testing.expect(return_syntax.legacy_ordinary_prefix == null);
    const return_value = switch (return_syntax.structure) {
        .value => |value| value,
        .predicate => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqualStrings("string ", return_value.raw_span.text(source));
    const opener = std.mem.indexOf(u8, source, "(value") orelse return error.TestUnexpectedResult;
    const body = std.mem.indexOf(u8, source, "{ return") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u32, @intCast(opener)), signature.source_span.start);
    try std.testing.expectEqual(@as(u32, @intCast(body)), signature.source_span.end);
}

fn expectFirstFunctionSliceLowering(parser: *const JsParser) !void {
    const store = &parser.type_store;
    var pool = TypePool.init(std.testing.allocator);
    defer pool.deinit(std.testing.allocator);
    var env = TypeEnv.init(std.testing.allocator, &pool);
    defer env.deinit();
    var application_bases = try store.planApplicationBasesWithIr(
        std.testing.allocator,
        parserIrView(parser),
    );
    defer application_bases.deinit();
    const lowered = try std.testing.allocator.alloc(TypeIndex, store.nodes.items.len);
    defer std.testing.allocator.free(lowered);
    @memset(lowered, null_type_idx);

    const annotation = store.annotations.items[0];
    const number = try lowerOwnedRoot(
        std.testing.allocator,
        store,
        &pool,
        &env,
        lowered,
        &application_bases,
        annotation.root,
        annotation.node_range,
        annotation.raw_span,
    );
    const parameter = store.parameter_annotations.items[0].value;
    const parameter_string = try lowerOwnedRoot(
        std.testing.allocator,
        store,
        &pool,
        &env,
        lowered,
        &application_bases,
        parameter.root,
        parameter.node_range,
        parameter.raw_span,
    );
    const return_syntax = store.function_signatures.items[0].return_syntax orelse
        return error.TestUnexpectedResult;
    const return_value = switch (return_syntax.structure) {
        .value => |value| value,
        .predicate => return error.TestUnexpectedResult,
    };
    const return_string = try lowerOwnedRoot(
        std.testing.allocator,
        store,
        &pool,
        &env,
        lowered,
        &application_bases,
        return_value.root,
        return_value.node_range,
        return_value.raw_span,
    );
    try std.testing.expectEqual(TypeTag.t_number, pool.getTag(number).?);
    try std.testing.expectEqual(TypeTag.t_string, pool.getTag(parameter_string).?);
    try std.testing.expectEqual(TypeTag.t_string, pool.getTag(return_string).?);
}

fn expectFunctionSliceRuntimeParity(
    runtime_allocator: std.mem.Allocator,
    source: []const u8,
    direct: *const JsParser,
    direct_root: NodeIndex,
    direct_atoms: *AtomTable,
) !void {
    var prepared = try PreparedSource.init(runtime_allocator, source, "<function-slice>.ts", .{});
    defer prepared.deinit();
    try std.testing.expectEqual(@as(usize, 0), prepared.stripDiagnostics().len);

    try expectFunctionSliceRuntimeParityPrepared(
        runtime_allocator,
        &prepared,
        direct,
        direct_root,
        direct_atoms,
    );
}

fn expectFunctionSliceRuntimeParityPrepared(
    runtime_allocator: std.mem.Allocator,
    prepared: *PreparedSource,
    direct: *const JsParser,
    direct_root: NodeIndex,
    direct_atoms: *AtomTable,
) !void {
    try std.testing.expectEqual(@as(usize, 0), prepared.stripDiagnostics().len);

    var legacy_atoms = AtomTable.init(runtime_allocator);
    defer legacy_atoms.deinit();
    var legacy = try JsParser.init(runtime_allocator, prepared.parserInput());
    defer legacy.deinit();
    legacy.setAtomTable(&legacy_atoms);

    const legacy_root = try legacy.parse();
    if (compareRuntime(
        &legacy,
        legacy_root,
        &legacy_atoms,
        direct,
        direct_root,
        direct_atoms,
    )) |difference| {
        std.debug.print("function slice runtime parity failed: {s}\n", .{difference});
        return error.TestUnexpectedResult;
    }
}

fn expectRuntimeParityAndShape(
    source: []const u8,
    direct: *const JsParser,
    direct_root: NodeIndex,
    direct_atoms: *AtomTable,
    direct_alloc: CountingAllocator,
) !void {
    var prepared = try PreparedSource.init(
        std.testing.allocator,
        source,
        "<typed-runtime-parity>.ts",
        .{},
    );
    defer prepared.deinit();
    try std.testing.expectEqual(@as(usize, 0), prepared.stripDiagnostics().len);

    var legacy_alloc = CountingAllocator.init(std.testing.allocator);
    const legacy_allocator = legacy_alloc.allocator();
    var legacy_atoms = AtomTable.init(legacy_allocator);
    defer legacy_atoms.deinit();
    var legacy = try JsParser.init(legacy_allocator, prepared.parserInput());
    defer legacy.deinit();
    legacy.setAtomTable(&legacy_atoms);

    const legacy_root = try legacy.parse();
    if (compareRuntime(
        &legacy,
        legacy_root,
        &legacy_atoms,
        direct,
        direct_root,
        direct_atoms,
    )) |difference| {
        std.debug.print("typed runtime parity failed: {s}\n", .{difference});
        return error.TestUnexpectedResult;
    }
    try std.testing.expect(legacy_alloc.sameRuntimeShape(direct_alloc));
}

const ObjectPrefixAllocationObservations = struct {
    failures: usize = 0,
    post_seed_rollbacks: usize = 0,
};

fn runProjectedPrefixTypeAllocationSweep(
    type_allocator: std.mem.Allocator,
    observed: *ObjectPrefixAllocationObservations,
) !void {
    const source =
        "const seed: number = 1;\n" ++
        "const value = <T>(<U>(1));";
    const prefix_offset = std.math.cast(
        u32,
        std.mem.indexOf(u8, source, "<T>") orelse return error.TestUnexpectedResult,
    ) orelse return error.TestUnexpectedResult;
    var runtime_count = CountingAllocator.init(std.testing.allocator);
    const runtime_allocator = runtime_count.allocator();
    var atoms = AtomTable.init(runtime_allocator);
    defer atoms.deinit();
    var parser = try JsParser.initTyped(runtime_allocator, type_allocator, source);
    defer parser.deinit();
    parser.setAtomTable(&atoms);
    const root = parser.parse() catch |err| switch (err) {
        error.OutOfMemory => {
            observed.failures += 1;
            try std.testing.expectEqual(@as(u16, 0), parser.scopes.current_scope);
            if (parser.current.start >= prefix_offset) {
                observed.post_seed_rollbacks += 1;
                try expectStoreCheckpoint(&parser.type_store, seedCheckpoint());
                try parser.type_store.validate();
            } else {
                try expectStoreCheckpoint(
                    &parser.type_store,
                    std.mem.zeroes(TypeSyntax.Store.Checkpoint),
                );
            }
            return err;
        },
        else => return err,
    };

    try expectRuntimeParityAndShape(
        source,
        &parser,
        root,
        &atoms,
        runtime_count,
    );
    try parser.type_store.validateRuntimeOwners(
        std.testing.allocator,
        parserIrView(&parser),
    );
    var expected = seedCheckpoint();
    expected.projected_generic_parameters = 2;
    expected.erased_type_prefixes = 2;
    try expectStoreCheckpoint(&parser.type_store, expected);
    try std.testing.expect(parser.type_store.nodes.items.len > 0);
    try std.testing.expect(parser.type_store.annotations.items.len > 0);
    try std.testing.expect(parser.type_store.projected_generic_parameters.items.len > 0);
    try std.testing.expect(parser.type_store.erased_type_prefixes.items.len > 0);
}

fn runObjectPrefixTypeAllocationSweep(
    type_allocator: std.mem.Allocator,
    observed: *ObjectPrefixAllocationObservations,
) !void {
    const source =
        "const seed: number = 1;\n" ++
        "const value = <T>{ id: 1 };";
    const prefix_offset = std.math.cast(
        u32,
        std.mem.indexOf(u8, source, "<T>") orelse return error.TestUnexpectedResult,
    ) orelse return error.TestUnexpectedResult;
    var runtime_count = CountingAllocator.init(std.testing.allocator);
    const runtime_allocator = runtime_count.allocator();
    var atoms = AtomTable.init(runtime_allocator);
    defer atoms.deinit();
    var parser = try JsParser.initTyped(runtime_allocator, type_allocator, source);
    defer parser.deinit();
    parser.setAtomTable(&atoms);
    const root = parser.parse() catch |err| switch (err) {
        error.OutOfMemory => {
            observed.failures += 1;
            try std.testing.expectEqual(@as(u16, 0), parser.scopes.current_scope);
            const after_seed = parser.current.start >= prefix_offset;
            if (after_seed) {
                observed.post_seed_rollbacks += 1;
                try expectStoreCheckpoint(&parser.type_store, seedCheckpoint());
                try parser.type_store.validate();
            } else {
                try expectStoreCheckpoint(
                    &parser.type_store,
                    std.mem.zeroes(TypeSyntax.Store.Checkpoint),
                );
            }
            return err;
        },
        else => return err,
    };

    try expectRuntimeParityAndShape(
        source,
        &parser,
        root,
        &atoms,
        runtime_count,
    );
    try parser.type_store.validateRuntimeOwners(
        std.testing.allocator,
        parserIrView(&parser),
    );
    var expected = seedCheckpoint();
    expected.erased_type_prefixes = 1;
    try expectStoreCheckpoint(&parser.type_store, expected);
    try std.testing.expect(parser.type_store.nodes.items.len > 0);
    try std.testing.expect(parser.type_store.annotations.items.len > 0);
    try std.testing.expect(parser.type_store.erased_type_prefixes.items.len > 0);
}

fn expectFirstTypeOnlyModuleEquivalent(source: []const u8) !void {
    var prepared = try PreparedSource.init(
        std.testing.allocator,
        source,
        "<type-only-module>.ts",
        .{},
    );
    defer prepared.deinit();
    try std.testing.expectEqual(@as(usize, 0), prepared.stripDiagnostics().len);

    var legacy_alloc = CountingAllocator.init(std.testing.allocator);
    var direct_alloc = CountingAllocator.init(std.testing.allocator);
    var legacy_atoms = AtomTable.init(legacy_alloc.allocator());
    defer legacy_atoms.deinit();
    var legacy = try JsParser.init(legacy_alloc.allocator(), prepared.parserInput());
    defer legacy.deinit();
    legacy.setAtomTable(&legacy_atoms);
    const legacy_root = try legacy.parse();

    var direct_atoms = AtomTable.init(direct_alloc.allocator());
    defer direct_atoms.deinit();
    var direct = try JsParser.initTyped(direct_alloc.allocator(), std.testing.allocator, source);
    defer direct.deinit();
    direct.setAtomTable(&direct_atoms);
    const direct_root = try direct.parse();

    if (compareRuntime(
        &legacy,
        legacy_root,
        &legacy_atoms,
        &direct,
        direct_root,
        &direct_atoms,
    )) |difference| {
        std.debug.print("type-only module runtime parity failed: {s}\n", .{difference});
        return error.TestUnexpectedResult;
    }
    try std.testing.expect(legacy_alloc.sameRuntimeShape(direct_alloc));

    try std.testing.expectEqual(@as(usize, 1), direct.type_store.type_only_modules.items.len);
    const module = direct.type_store.type_only_modules.items[0];
    try std.testing.expectEqual(TypeSyntax.TypeOnlyModuleKind.import_type, module.kind);
    try std.testing.expectEqualStrings(
        "import type { A } from \"./a\";",
        module.raw_span.text(source),
    );
    const semicolon = std.mem.indexOfScalar(u8, source, ';') orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u32, 0), module.raw_span.start);
    try std.testing.expectEqual(@as(u32, @intCast(semicolon + 1)), module.raw_span.end);

    try std.testing.expectEqual(@as(usize, 1), direct.type_store.annotations.items.len);
    const annotation = direct.type_store.annotations.items[0];
    try std.testing.expectEqualStrings("number", annotation.raw_span.text(source));
    const annotation_root = switch (annotation.root) {
        .absent => return error.TestUnexpectedResult,
        .present => |index| direct.type_store.node(index) orelse return error.TestUnexpectedResult,
    };
    const primitive = switch (annotation_root.data) {
        .primitive => |primitive| primitive,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(TypeSyntax.Primitive.number, primitive);
    const view = parserIrView(&direct);
    var live_declaration: ?NodeIndex = null;
    for (direct.nodes.tags.items, direct.nodes.locs.items, 0..) |tag, loc, index| {
        if (tag == .var_decl and std.mem.startsWith(u8, source[loc.offset..], "const live")) {
            if (live_declaration != null) return error.TestUnexpectedResult;
            live_declaration = @intCast(index);
        }
    }
    const live = view.getVarDecl(live_declaration orelse return error.TestUnexpectedResult) orelse
        return error.TestUnexpectedResult;
    try std.testing.expect(std.meta.eql(live.binding, annotation.binding));
    try direct.type_store.validateRuntimeOwners(std.testing.allocator, view);
}

const ExpectedTypeOnlyModule = struct {
    kind: TypeSyntax.TypeOnlyModuleKind,
    raw: []const u8,
};

fn expectTypeOnlyModuleCase(
    source: []const u8,
    expected_modules: []const ExpectedTypeOnlyModule,
    expect_runtime_success: bool,
) !void {
    var prepared = try PreparedSource.init(
        std.testing.allocator,
        source,
        "<type-only-module-matrix>.ts",
        .{},
    );
    defer prepared.deinit();
    try std.testing.expectEqual(@as(usize, 0), prepared.stripDiagnostics().len);

    var legacy_alloc = CountingAllocator.init(std.testing.allocator);
    var direct_alloc = CountingAllocator.init(std.testing.allocator);
    var type_alloc = CountingAllocator.init(std.testing.allocator);
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
        error.OutOfMemory => return err,
        else => blk: {
            legacy_error = err;
            break :blk null;
        },
    };
    var direct_error: ?anyerror = null;
    const direct_root = direct.parse() catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => blk: {
            direct_error = err;
            break :blk null;
        },
    };

    try std.testing.expectEqual(expect_runtime_success, legacy_root != null);
    try std.testing.expectEqual(expect_runtime_success, direct_root != null);
    if (expect_runtime_success) {
        if (compareRuntime(
            &legacy,
            legacy_root.?,
            &legacy_atoms,
            &direct,
            direct_root.?,
            &direct_atoms,
        )) |difference| {
            std.debug.print("type-only module matrix runtime parity failed: {s}\n", .{difference});
            return error.TestUnexpectedResult;
        }
    } else {
        try std.testing.expect(legacy_error == direct_error);
        try std.testing.expect(sameParseErrors(&legacy, &direct));
    }
    try std.testing.expect(legacy_alloc.sameRuntimeShape(direct_alloc));

    try std.testing.expectEqual(expected_modules.len, direct.type_store.type_only_modules.items.len);
    for (expected_modules, direct.type_store.type_only_modules.items) |expected, actual| {
        try std.testing.expectEqual(expected.kind, actual.kind);
        try std.testing.expectEqualStrings(expected.raw, actual.raw_span.text(source));
    }
    try direct.type_store.validate();
    if (expect_runtime_success) {
        const view = parserIrView(&direct);
        try direct.type_store.validateRuntimeOwners(std.testing.allocator, view);
        for (direct.type_store.function_signatures.items) |signature| {
            try std.testing.expectEqual(
                engine.parser.NodeTag.function_expr,
                view.getTag(signature.owner) orelse return error.TestUnexpectedResult,
            );
        }
    }
    if (expected_modules.len > 0) try std.testing.expect(type_alloc.alloc_calls > 0);
}

fn expectTypeOnlyModuleRefusal(
    source: []const u8,
    expected_offset: u32,
) !void {
    var atoms = AtomTable.init(std.testing.allocator);
    defer atoms.deinit();
    var parser = try JsParser.initTyped(std.testing.allocator, std.testing.allocator, source);
    defer parser.deinit();
    parser.setAtomTable(&atoms);

    try std.testing.expectError(error.TypeOnlyModuleRefused, parser.parse());
    const refusal = parser.type_only_module_refusal orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(TypeSyntax.TypeOnlyModuleRefusalReason.zttp_types, refusal.reason);
    try std.testing.expectEqual(expected_offset, refusal.original_location.offset);
    const position = positionOf(source, expected_offset);
    try std.testing.expectEqual(position.line, refusal.original_location.line);
    try std.testing.expectEqual(position.column, refusal.original_location.column);
    try std.testing.expectEqual(@as(usize, 0), parser.errors.getErrors().len);
}

const ModuleAllocationObservations = struct {
    failures: usize = 0,
    post_seed_failures: usize = 0,
};

fn runCleanModuleTypeAllocationSweep(
    type_allocator: std.mem.Allocator,
    source: []const u8,
    second_offset: u32,
    observed: *ModuleAllocationObservations,
) !void {
    var atoms = AtomTable.init(std.testing.allocator);
    defer atoms.deinit();
    var parser = try JsParser.initTyped(std.testing.allocator, type_allocator, source);
    defer parser.deinit();
    parser.setAtomTable(&atoms);
    const root = parser.parse() catch |err| switch (err) {
        error.OutOfMemory => {
            observed.failures += 1;
            const after_seed = parser.current.start >= second_offset;
            var expected = std.mem.zeroes(TypeSyntax.Store.Checkpoint);
            expected.type_only_modules = if (after_seed) 1 else 0;
            try std.testing.expect(std.meta.eql(expected, parser.type_store.checkpoint()));
            if (!after_seed) return err;
            const seed = parser.type_store.type_only_modules.items[0];
            try std.testing.expect(seed.raw_span.end <= second_offset);
            try std.testing.expectEqualStrings(
                "import type { Seed } from \"./seed\";",
                seed.raw_span.text(source),
            );
            observed.post_seed_failures += 1;
            try parser.type_store.validate();
            return err;
        },
        else => return err,
    };

    try expectFunctionSliceRuntimeParity(std.testing.allocator, source, &parser, root, &atoms);
    try std.testing.expectEqual(@as(usize, 2), parser.type_store.type_only_modules.items.len);
    try parser.type_store.validateRuntimeOwners(std.testing.allocator, parserIrView(&parser));
}

fn runExcludedModuleTypeAllocationSweep(
    type_allocator: std.mem.Allocator,
    source: []const u8,
    second_offset: u32,
    observed: *ModuleAllocationObservations,
) !void {
    var parser = try JsParser.initTyped(std.testing.allocator, type_allocator, source);
    defer parser.deinit();
    _ = parser.parse() catch |err| switch (err) {
        error.OutOfMemory => {
            observed.failures += 1;
            const after_seed = parser.current.start >= second_offset;
            var expected = std.mem.zeroes(TypeSyntax.Store.Checkpoint);
            expected.type_only_modules = if (after_seed) 1 else 0;
            try std.testing.expect(std.meta.eql(expected, parser.type_store.checkpoint()));
            if (after_seed) {
                const seed = parser.type_store.type_only_modules.items[0];
                try std.testing.expect(seed.raw_span.end <= second_offset);
                try std.testing.expectEqualStrings(
                    "import type { Seed } from \"./seed\";",
                    seed.raw_span.text(source),
                );
                observed.post_seed_failures += 1;
                try parser.type_store.validate();
            }
            return err;
        },
        error.TypeOnlyModuleLexicallyExcluded => {
            try std.testing.expectEqual(@as(usize, 1), parser.type_store.type_only_modules.items.len);
            try std.testing.expect(parser.type_only_module_exclusion != null);
            try std.testing.expectEqual(@as(usize, 1), parser.type_only_module_diagnostics.items.len);
            return;
        },
        else => return err,
    };
    return error.TestUnexpectedResult;
}

fn expectFirstFunctionSliceEquivalent(source: []const u8) !void {
    var direct_atoms = AtomTable.init(std.testing.allocator);
    defer direct_atoms.deinit();
    var direct = try JsParser.initTyped(std.testing.allocator, std.testing.allocator, source);
    defer direct.deinit();
    direct.setAtomTable(&direct_atoms);

    const direct_root = try direct.parse();
    try expectFunctionSliceRuntimeParity(
        std.testing.allocator,
        source,
        &direct,
        direct_root,
        &direct_atoms,
    );
    try expectFirstFunctionSliceRecords(&direct, source);
    try expectFirstFunctionSliceLowering(&direct);
}

fn expectFirstPredicateArrowLowering(parser: *const JsParser) !void {
    const store = &parser.type_store;
    var pool = TypePool.init(std.testing.allocator);
    defer pool.deinit(std.testing.allocator);
    var env = TypeEnv.init(std.testing.allocator, &pool);
    defer env.deinit();
    var application_bases = try store.planApplicationBasesWithIr(
        std.testing.allocator,
        parserIrView(parser),
    );
    defer application_bases.deinit();
    const lowered = try std.testing.allocator.alloc(TypeIndex, store.nodes.items.len);
    defer std.testing.allocator.free(lowered);
    @memset(lowered, null_type_idx);

    const marker = store.parameter_annotations.items[0].value;
    const marker_type = try lowerOwnedRoot(
        std.testing.allocator,
        store,
        &pool,
        &env,
        lowered,
        &application_bases,
        marker.root,
        marker.node_range,
        marker.raw_span,
    );
    const return_syntax = store.function_signatures.items[0].return_syntax orelse
        return error.TestUnexpectedResult;
    const narrowed = switch (return_syntax.structure) {
        .predicate => |predicate| predicate.narrowed,
        .value => return error.TestUnexpectedResult,
    };
    const narrowed_type = try lowerOwnedRoot(
        std.testing.allocator,
        store,
        &pool,
        &env,
        lowered,
        &application_bases,
        narrowed.root,
        narrowed.node_range,
        narrowed.raw_span,
    );
    try std.testing.expectEqual(TypeTag.t_unknown_type, pool.getTag(marker_type).?);
    try std.testing.expectEqual(TypeTag.t_string, pool.getTag(narrowed_type).?);
}

fn expectOrderedTypeValueTags(
    parser: *const JsParser,
    values: []const TypeSyntax.TypeValue,
    expected: []const TypeTag,
) !void {
    try std.testing.expectEqual(values.len, expected.len);
    const store = &parser.type_store;
    var pool = TypePool.init(std.testing.allocator);
    defer pool.deinit(std.testing.allocator);
    var env = TypeEnv.init(std.testing.allocator, &pool);
    defer env.deinit();
    var legacy_pool = TypePool.init(std.testing.allocator);
    defer legacy_pool.deinit(std.testing.allocator);
    var legacy_env = TypeEnv.init(std.testing.allocator, &legacy_pool);
    defer legacy_env.deinit();
    var application_bases = try store.planApplicationBasesWithIr(
        std.testing.allocator,
        parserIrView(parser),
    );
    defer application_bases.deinit();
    const lowered = try std.testing.allocator.alloc(TypeIndex, store.nodes.items.len);
    defer std.testing.allocator.free(lowered);
    @memset(lowered, null_type_idx);

    for (values, expected) |value, expected_tag| {
        try std.testing.expect(value.node_range.count > 0);
        const type_idx = try lowerOwnedRoot(
            std.testing.allocator,
            store,
            &pool,
            &env,
            lowered,
            &application_bases,
            value.root,
            value.node_range,
            value.raw_span,
        );
        try pool.ensureHealthy();
        try env.ensureHealthy();
        try std.testing.expectEqual(expected_tag, pool.getTag(type_idx).?);
        const legacy_type = legacy_env.resolveType(value.raw_span.text(store.source));
        try legacy_pool.ensureHealthy();
        try legacy_env.ensureHealthy();
        try std.testing.expect(try orderedTypeEqual(
            std.testing.allocator,
            &legacy_pool,
            legacy_type,
            &pool,
            type_idx,
        ));
    }
}

fn seedCheckpoint() TypeSyntax.Store.Checkpoint {
    return .{
        .nodes = 1,
        .members = 0,
        .fields = 0,
        .params = 0,
        .template_parts = 0,
        .annotations = 1,
        .declarations = 0,
        .generic_parameters = 0,
        .projected_generic_parameters = 0,
        .semantic_fragments = 0,
        .generic_owners = 0,
        .authored_call_arguments = 0,
        .explicit_call_arguments = 0,
        .parameter_annotations = 0,
        .function_signatures = 0,
        .type_only_modules = 0,
        .erased_type_prefixes = 0,
    };
}

fn nominalGenericSeedCheckpoint() TypeSyntax.Store.Checkpoint {
    return .{
        .nodes = 1,
        .members = 0,
        .fields = 0,
        .params = 0,
        .template_parts = 0,
        .annotations = 0,
        .declarations = 1,
        .generic_parameters = 1,
        .projected_generic_parameters = 1,
        .semantic_fragments = 0,
        .generic_owners = 1,
        .authored_call_arguments = 0,
        .explicit_call_arguments = 0,
        .parameter_annotations = 0,
        .function_signatures = 0,
        .type_only_modules = 0,
        .erased_type_prefixes = 0,
    };
}

fn twoAnnotationCheckpoint() TypeSyntax.Store.Checkpoint {
    var checkpoint = seedCheckpoint();
    checkpoint.nodes = 2;
    checkpoint.annotations = 2;
    return checkpoint;
}

fn expectStoreCheckpoint(
    store: *const TypeSyntax.Store,
    expected: TypeSyntax.Store.Checkpoint,
) !void {
    try std.testing.expect(std.meta.eql(expected, store.checkpoint()));
}

const HeaderAllocationCase = enum {
    mixed,
    tab,
};

fn runHeaderTypeAllocation(
    type_allocator: std.mem.Allocator,
    case: HeaderAllocationCase,
    observed_failures: *usize,
    observed_post_seed_rollbacks: *usize,
) !void {
    const source = switch (case) {
        .mixed => "const seed: number = 1;\n" ++
            "const guard = (candidate, marker: unknown): candidate is string => typeof candidate === \"string\";",
        .tab => "const seed: number = 1;\n" ++
            "const guard = (value: unknown): value\tis\tstring => true;",
    };
    var atoms = AtomTable.init(std.testing.allocator);
    defer atoms.deinit();
    var parser = try JsParser.initTyped(std.testing.allocator, type_allocator, source);
    defer parser.deinit();
    parser.setAtomTable(&atoms);
    const guard_offset: u32 = @intCast(std.mem.indexOf(u8, source, "const guard") orelse
        return error.TestUnexpectedResult);
    const root = parser.parse() catch |err| {
        switch (err) {
            error.OutOfMemory => {},
            else => return err,
        }
        observed_failures.* += 1;
        try std.testing.expectEqual(@as(u16, 0), parser.scopes.current_scope);
        if (parser.current.start >= guard_offset) {
            try expectStoreCheckpoint(&parser.type_store, seedCheckpoint());
            observed_post_seed_rollbacks.* += 1;
            try parser.type_store.validate();
        } else {
            try expectStoreCheckpoint(&parser.type_store, std.mem.zeroes(TypeSyntax.Store.Checkpoint));
        }
        return err;
    };

    try expectFunctionSliceRuntimeParity(std.testing.allocator, source, &parser, root, &atoms);
    const view = parserIrView(&parser);
    try parser.type_store.validateRuntimeOwners(std.testing.allocator, view);
    try std.testing.expect(parser.type_store.nodes.items.len > 0);
    try std.testing.expect(parser.type_store.annotations.items.len > 0);
    try std.testing.expect(parser.type_store.parameter_annotations.items.len > 0);
    try std.testing.expect(parser.type_store.function_signatures.items.len > 0);
    const return_syntax = parser.type_store.function_signatures.items[0].return_syntax orelse
        return error.TestUnexpectedResult;
    const predicate = switch (return_syntax.structure) {
        .predicate => |actual| actual,
        .value => return error.TestUnexpectedResult,
    };
    try std.testing.expect(predicate.narrowed.node_range.count > 0);
    switch (case) {
        .mixed => {
            const values = [_]TypeSyntax.TypeValue{
                parser.type_store.parameter_annotations.items[0].value,
                predicate.narrowed,
            };
            try expectOrderedTypeValueTags(&parser, &values, &.{ .t_unknown_type, .t_string });
        },
        .tab => {
            const compatibility = return_syntax.legacy_ordinary_prefix orelse
                return error.TestUnexpectedResult;
            try std.testing.expect(compatibility.node_range.count > 0);
            const values = [_]TypeSyntax.TypeValue{
                parser.type_store.parameter_annotations.items[0].value,
                predicate.narrowed,
                compatibility,
            };
            try expectOrderedTypeValueTags(
                &parser,
                &values,
                &.{ .t_unknown_type, .t_string, .t_ref },
            );
        },
    }
}

const GenericArrowAllocationCase = enum {
    dedicated,
    legacy_call,
};

const GenericArrowAllocationObservations = struct {
    failures: usize = 0,
    post_seed_rollbacks: usize = 0,
    successes: usize = 0,
};

fn runGenericArrowTypeAllocation(
    type_allocator: std.mem.Allocator,
    case: GenericArrowAllocationCase,
    observations: *GenericArrowAllocationObservations,
) !void {
    const source = switch (case) {
        .dedicated => "const seed: number = 1; const id=<T>(value: T): T => value;",
        .legacy_call => "const seed: number = 1; const id = // note\n<T>(value: T): T => value;",
    };
    var runtime_count = CountingAllocator.init(std.testing.allocator);
    const runtime_allocator = runtime_count.allocator();
    var atoms = AtomTable.init(runtime_allocator);
    defer atoms.deinit();
    var parser = try JsParser.initTyped(runtime_allocator, type_allocator, source);
    defer parser.deinit();
    parser.setAtomTable(&atoms);
    const arrow_offset: u32 = @intCast(std.mem.indexOf(u8, source, "const id") orelse
        return error.TestUnexpectedResult);
    const root = parser.parse() catch |err| {
        switch (err) {
            error.OutOfMemory => {},
            else => return err,
        }
        observations.failures += 1;
        try std.testing.expectEqual(@as(u16, 0), parser.scopes.current_scope);
        if (parser.current.start >= arrow_offset) {
            try expectStoreCheckpoint(&parser.type_store, seedCheckpoint());
            observations.post_seed_rollbacks += 1;
        } else {
            try expectStoreCheckpoint(
                &parser.type_store,
                std.mem.zeroes(TypeSyntax.Store.Checkpoint),
            );
        }
        try parser.type_store.validate();
        return err;
    };

    observations.successes += 1;
    try expectRuntimeParityAndShape(source, &parser, root, &atoms, runtime_count);
    try parser.type_store.validateRuntimeOwners(std.testing.allocator, parserIrView(&parser));
    try std.testing.expect(parser.type_store.nodes.items.len > 0);
    try std.testing.expect(parser.type_store.annotations.items.len > 0);
    try std.testing.expect(parser.type_store.generic_parameters.items.len > 0);
    try std.testing.expect(parser.type_store.projected_generic_parameters.items.len > 0);
    try std.testing.expect(parser.type_store.generic_owners.items.len > 0);
    try std.testing.expect(parser.type_store.parameter_annotations.items.len > 0);
    try std.testing.expect(parser.type_store.function_signatures.items.len > 0);
    switch (case) {
        .dedicated => {
            try std.testing.expectEqual(
                @as(usize, 0),
                parser.type_store.authored_call_arguments.items.len,
            );
            try std.testing.expectEqual(@as(usize, 0), parser.type_store.semantic_fragments.items.len);
        },
        .legacy_call => {
            try std.testing.expect(parser.type_store.authored_call_arguments.items.len > 0);
            try std.testing.expect(parser.type_store.semantic_fragments.items.len > 0);
        },
    }
}

const NamedFunctionCommentAllocationCase = enum {
    before_name,
    after_list,
};

const NamedFunctionCommentAllocationObservations = struct {
    failures: usize = 0,
    post_seed_rollbacks: usize = 0,
    successes: usize = 0,
};

fn runNamedFunctionCommentTypeAllocation(
    type_allocator: std.mem.Allocator,
    case: NamedFunctionCommentAllocationCase,
    observations: *NamedFunctionCommentAllocationObservations,
) !void {
    const source = switch (case) {
        .before_name => "const seed: number = 1; function /* note */ identity<T>(value) { return value; }",
        .after_list => "const seed: number = 1; function identity<T>/* note */(value) { return value; }",
    };
    var runtime_count = CountingAllocator.init(std.testing.allocator);
    const runtime_allocator = runtime_count.allocator();
    var atoms = AtomTable.init(runtime_allocator);
    defer atoms.deinit();
    var parser = try JsParser.initTyped(runtime_allocator, type_allocator, source);
    defer parser.deinit();
    parser.setAtomTable(&atoms);
    const function_offset: u32 = @intCast(std.mem.indexOf(u8, source, "function") orelse
        return error.TestUnexpectedResult);
    const root = parser.parse() catch |err| {
        switch (err) {
            error.OutOfMemory => {},
            else => return err,
        }
        observations.failures += 1;
        try std.testing.expectEqual(@as(u16, 0), parser.scopes.current_scope);
        if (parser.current.start >= function_offset) {
            try expectStoreCheckpoint(&parser.type_store, seedCheckpoint());
            observations.post_seed_rollbacks += 1;
        } else {
            try expectStoreCheckpoint(
                &parser.type_store,
                std.mem.zeroes(TypeSyntax.Store.Checkpoint),
            );
        }
        try parser.type_store.validate();
        return err;
    };

    observations.successes += 1;
    try expectRuntimeParityAndShape(source, &parser, root, &atoms, runtime_count);
    try parser.type_store.validateRuntimeOwners(std.testing.allocator, parserIrView(&parser));
    try std.testing.expectEqual(@as(usize, 1), parser.type_store.generic_owners.items.len);
    try std.testing.expectEqual(@as(usize, 0), parser.type_store.function_signatures.items.len);
    switch (case) {
        .before_name => switch (parser.type_store.generic_owners.items[0].compatibility) {
            .legacy_call_arguments => {},
            else => return error.TestUnexpectedResult,
        },
        .after_list => switch (parser.type_store.generic_owners.items[0].compatibility) {
            .ignored_declaration_parameters => {},
            else => return error.TestUnexpectedResult,
        },
    }
}

fn countRuntimeTag(parser: *const JsParser, tag: engine.parser.NodeTag) usize {
    var count: usize = 0;
    for (parser.nodes.tags.items) |actual| {
        if (actual == tag) count += 1;
    }
    return count;
}

test "first function signature slice preserves runtime and ordered type lowering" {
    const source =
        "const seed: number = 1;\n" ++
        "function identity(value: string): string { return value; }\n";
    try expectFirstFunctionSliceEquivalent(source);
}

test "first type-only module slice preserves runtime and direct syntax" {
    const source =
        "import type { A } from \"./a\";\n" ++
        "const live: number = 1;";
    try expectFirstTypeOnlyModuleEquivalent(source);
}

test "first erased object prefix preserves runtime and exact ownership" {
    const source = "const value = <T>{ id: 1 };";
    var runtime_count = CountingAllocator.init(std.testing.allocator);
    const runtime_allocator = runtime_count.allocator();
    var atoms = AtomTable.init(runtime_allocator);
    defer atoms.deinit();
    var parser = try JsParser.initTyped(runtime_allocator, std.testing.allocator, source);
    defer parser.deinit();
    parser.setAtomTable(&atoms);
    const root = try parser.parse();

    try expectRuntimeParityAndShape(
        source,
        &parser,
        root,
        &atoms,
        runtime_count,
    );

    const view = parserIrView(&parser);
    try parser.type_store.validateRuntimeOwners(std.testing.allocator, view);
    try std.testing.expectEqual(@as(usize, 1), parser.type_store.erased_type_prefixes.items.len);
    try std.testing.expectEqual(@as(usize, 0), parser.type_store.nodes.items.len);
    try std.testing.expectEqual(@as(usize, 0), parser.type_store.generic_parameters.items.len);
    try std.testing.expectEqual(
        @as(usize, 0),
        parser.type_store.projected_generic_parameters.items.len,
    );
    try std.testing.expectEqual(@as(usize, 0), parser.type_store.semantic_fragments.items.len);
    try std.testing.expectEqual(@as(usize, 0), parser.type_store.generic_owners.items.len);
    try std.testing.expectEqual(@as(usize, 0), parser.type_store.authored_call_arguments.items.len);
    try std.testing.expectEqual(@as(usize, 0), parser.type_store.explicit_call_arguments.items.len);
    try std.testing.expectEqual(@as(usize, 0), parser.type_store.parameter_annotations.items.len);
    try std.testing.expectEqual(@as(usize, 0), parser.type_store.function_signatures.items.len);
    try std.testing.expectEqual(@as(usize, 0), parser.type_store.type_only_modules.items.len);

    const prefix = &parser.type_store.erased_type_prefixes.items[0];
    try std.testing.expectEqualStrings("<T>", prefix.list_span.text(source));
    try std.testing.expectEqualStrings(
        "<T>",
        prefix.capture_spans.actual_erased_span.text(source),
    );
    try std.testing.expectEqualStrings(
        "T",
        prefix.capture_spans.legacy_recorded_span.text(source),
    );
    try std.testing.expectEqualStrings("{ id: 1 }", prefix.operand_span.text(source));
    switch (prefix.compatibility) {
        .ignored_parameters => {},
        .legacy_parameter_projection => return error.TestUnexpectedResult,
    }
    const object = switch (prefix.owner) {
        .expression => |node| node,
        .block => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(engine.parser.NodeTag.object_literal, view.getTag(object).?);
    try std.testing.expectEqual(prefix.operand_span.start, view.getLoc(object).?.offset);

    var declaration: ?NodeIndex = null;
    for (parser.nodes.tags.items, 0..) |tag, index| {
        if (tag == .var_decl) declaration = @intCast(index);
    }
    const variable = declaration orelse return error.TestUnexpectedResult;
    const var_decl = view.getVarDecl(variable) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(object, var_decl.init);

    const original_owner = prefix.owner;
    prefix.owner = .{ .expression = variable };
    try std.testing.expectError(
        error.InvalidErasedTypePrefix,
        parser.type_store.validateRuntimeOwners(std.testing.allocator, view),
    );
    prefix.owner = .{ .expression = engine.parser.null_node };
    try std.testing.expectError(
        error.InvalidErasedTypePrefix,
        parser.type_store.validateRuntimeOwners(std.testing.allocator, view),
    );
    prefix.owner = original_owner;

    const original_operand = prefix.operand_span;
    prefix.operand_span.end -= 1;
    try std.testing.expectError(
        error.InvalidErasedTypePrefix,
        parser.type_store.validateRuntimeOwners(std.testing.allocator, view),
    );
    prefix.operand_span = original_operand;
    const original_capture = prefix.capture_spans.actual_erased_span;
    prefix.capture_spans.actual_erased_span.start += 1;
    try std.testing.expectError(
        error.InvalidGenericOwner,
        parser.type_store.validateRuntimeOwners(std.testing.allocator, view),
    );
    prefix.capture_spans.actual_erased_span = original_capture;

    const original_legacy_capture = prefix.capture_spans.legacy_recorded_span;
    prefix.capture_spans.legacy_recorded_span.end =
        prefix.capture_spans.legacy_recorded_span.start;
    try std.testing.expectError(
        error.InvalidErasedTypePrefix,
        parser.type_store.validateRuntimeOwners(std.testing.allocator, view),
    );
    prefix.capture_spans.legacy_recorded_span = original_legacy_capture;
    try parser.type_store.validateRuntimeOwners(std.testing.allocator, view);

    const completed_prefix = prefix.*;
    const checkpoint = parser.type_store.checkpoint();
    var pending = try parser.type_store.reserveErasedTypePrefix(.{
        .list_span = completed_prefix.list_span,
        .capture_spans = completed_prefix.capture_spans,
        .policy = .ignored_parameters,
    });
    pending.capture_spans.legacy_recorded_span.end =
        pending.capture_spans.legacy_recorded_span.start;
    try std.testing.expectError(
        error.InvalidErasedTypePrefix,
        parser.type_store.finishErasedTypePrefix(&pending, .{
            .owner = .{ .expression = object },
            .operand_span = completed_prefix.operand_span,
            .view = view,
        }),
    );
    parser.type_store.cancelErasedTypePrefix(&pending);
    try expectStoreCheckpoint(&parser.type_store, checkpoint);
    try parser.type_store.validateRuntimeOwners(std.testing.allocator, view);
}

test "failed erased object prefix restores the earlier syntax checkpoint" {
    const source = "const seed: number = 1; const value = <T>{ id: };";
    var parser = try JsParser.initTyped(std.testing.allocator, std.testing.allocator, source);
    defer parser.deinit();
    try std.testing.expectError(error.UnexpectedToken, parser.parse());
    try std.testing.expectEqual(TokenType.rbrace, parser.current.type);
    try std.testing.expectEqual(@as(u16, 0), parser.scopes.current_scope);
    try expectStoreCheckpoint(&parser.type_store, seedCheckpoint());
    try parser.type_store.validate();
}

test "erased object prefix type allocation failures restore the typed seed" {
    var observed: ObjectPrefixAllocationObservations = .{};
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        runObjectPrefixTypeAllocationSweep,
        .{&observed},
    );
    try std.testing.expect(observed.failures > 0);
    try std.testing.expect(observed.post_seed_rollbacks > 0);
}

test "projected erased prefix allocation failures restore the typed seed" {
    var observed: ObjectPrefixAllocationObservations = .{};
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        runProjectedPrefixTypeAllocationSweep,
        .{&observed},
    );
    try std.testing.expect(observed.failures > 0);
    try std.testing.expect(observed.post_seed_rollbacks > 0);
}

test "erased prefix matrix preserves runtime ownership and projection order" {
    const ExpectedPrefix = struct {
        actual: []const u8,
        legacy: []const u8,
        operand: []const u8,
        owner_tag: engine.parser.NodeTag,
        block_owner: bool = false,
        projected_count: u32,
        projected_name: ?[]const u8 = null,
    };
    const Case = struct {
        source: []const u8,
        prefixes: []const ExpectedPrefix,
    };
    const cases = [_]Case{
        .{
            .source = "const value = <T>{ id: 1 };",
            .prefixes = &.{.{ .actual = "<T>", .legacy = "T", .operand = "{ id: 1 }", .owner_tag = .object_literal, .projected_count = 0 }},
        },
        .{
            .source = "const value = (<T>{ id: 1 });",
            .prefixes = &.{.{ .actual = "<T>", .legacy = "T", .operand = "{ id: 1 }", .owner_tag = .object_literal, .projected_count = 0 }},
        },
        .{
            .source = "const value = <T>(1);",
            .prefixes = &.{.{ .actual = "<T>", .legacy = "T", .operand = "(1)", .owner_tag = .lit_int, .projected_count = 1, .projected_name = "T" }},
        },
        .{
            .source = "<T>{ const inner = 1; } const live: number = 1;",
            .prefixes = &.{.{ .actual = "<T>", .legacy = "T", .operand = "{ const inner = 1; }", .owner_tag = .block, .block_owner = true, .projected_count = 0 }},
        },
        .{
            .source = "const value = <>{ id: 1 };",
            .prefixes = &.{.{ .actual = "<>", .legacy = "", .operand = "{ id: 1 }", .owner_tag = .object_literal, .projected_count = 0 }},
        },
        .{
            .source = "const value = <>(1);",
            .prefixes = &.{.{ .actual = "<>", .legacy = "", .operand = "(1)", .owner_tag = .lit_int, .projected_count = 0 }},
        },
        .{
            .source = "const value = (<> (1));",
            .prefixes = &.{.{ .actual = "<> ", .legacy = ">", .operand = "(1)", .owner_tag = .lit_int, .projected_count = 1, .projected_name = ">" }},
        },
        .{
            .source = "const value = <T>(<U>(1));",
            .prefixes = &.{
                .{ .actual = "<T>", .legacy = "T", .operand = "(<U>(1))", .owner_tag = .lit_int, .projected_count = 1, .projected_name = "T" },
                .{ .actual = "<U>", .legacy = "U", .operand = "(1)", .owner_tag = .lit_int, .projected_count = 1, .projected_name = "U" },
            },
        },
        .{
            .source = "const value = <T>{ id: <U>(1) };",
            .prefixes = &.{
                .{ .actual = "<T>", .legacy = "T", .operand = "{ id: <U>(1) }", .owner_tag = .object_literal, .projected_count = 0 },
                .{ .actual = "<U>", .legacy = "U", .operand = "(1)", .owner_tag = .lit_int, .projected_count = 1, .projected_name = "U" },
            },
        },
        .{
            .source = "const value = <T>((x) => x);",
            .prefixes = &.{.{ .actual = "<T>", .legacy = "T", .operand = "((x) => x)", .owner_tag = .arrow_function, .projected_count = 1, .projected_name = "T" }},
        },
    };

    for (cases) |case| {
        var runtime_count = CountingAllocator.init(std.testing.allocator);
        const runtime_allocator = runtime_count.allocator();
        var atoms = AtomTable.init(runtime_allocator);
        defer atoms.deinit();
        var parser = try JsParser.initTyped(runtime_allocator, std.testing.allocator, case.source);
        defer parser.deinit();
        parser.setAtomTable(&atoms);
        const root = try parser.parse();

        try expectRuntimeParityAndShape(
            case.source,
            &parser,
            root,
            &atoms,
            runtime_count,
        );
        try expectEquivalent(case.source);

        const view = parserIrView(&parser);
        try parser.type_store.validateRuntimeOwners(std.testing.allocator, view);
        try std.testing.expectEqual(case.prefixes.len, parser.type_store.erased_type_prefixes.items.len);
        try std.testing.expectEqual(@as(usize, 0), parser.type_store.generic_parameters.items.len);
        try std.testing.expectEqual(@as(usize, 0), parser.type_store.generic_owners.items.len);
        try std.testing.expectEqual(@as(usize, 0), parser.type_store.authored_call_arguments.items.len);
        try std.testing.expectEqual(@as(usize, 0), parser.type_store.explicit_call_arguments.items.len);
        try std.testing.expectEqual(@as(usize, 0), parser.type_store.semantic_fragments.items.len);
        try std.testing.expectEqual(@as(usize, 0), parser.type_store.parameter_annotations.items.len);
        try std.testing.expectEqual(@as(usize, 0), parser.type_store.function_signatures.items.len);
        var projected_total: usize = 0;
        for (case.prefixes, parser.type_store.erased_type_prefixes.items) |expected, prefix| {
            try std.testing.expectEqualStrings(expected.actual, prefix.capture_spans.actual_erased_span.text(case.source));
            try std.testing.expectEqualStrings(expected.legacy, prefix.capture_spans.legacy_recorded_span.text(case.source));
            try std.testing.expectEqualStrings(expected.operand, prefix.operand_span.text(case.source));
            const owner = switch (prefix.owner) {
                .expression => |runtime_node| blk: {
                    try std.testing.expect(!expected.block_owner);
                    break :blk runtime_node;
                },
                .block => |runtime_node| blk: {
                    try std.testing.expect(expected.block_owner);
                    break :blk runtime_node;
                },
            };
            try std.testing.expectEqual(expected.owner_tag, view.getTag(owner).?);
            switch (prefix.compatibility) {
                .ignored_parameters => try std.testing.expectEqual(@as(u32, 0), expected.projected_count),
                .legacy_parameter_projection => |projection| {
                    try std.testing.expectEqual(expected.projected_count, projection.projected_parameters.count);
                    try std.testing.expectEqual(@as(u32, 0), projection.semantic_fragments.count);
                    if (expected.projected_name) |name| {
                        const parameters = parser.type_store.projectedGenericParameterSlice(
                            projection.projected_parameters,
                        ) orelse return error.TestUnexpectedResult;
                        try std.testing.expectEqual(@as(usize, 1), parameters.len);
                        try std.testing.expectEqualStrings(name, parameters[0].name_span.text(case.source));
                    }
                    projected_total += @intCast(projection.projected_parameters.count);
                },
            }
        }
        try std.testing.expectEqual(projected_total, parser.type_store.projected_generic_parameters.items.len);

        var prepared = try PreparedSource.init(
            std.testing.allocator,
            case.source,
            "<erased-prefix-matrix>.ts",
            .{},
        );
        defer prepared.deinit();
        try std.testing.expect(try compareLowering(std.testing.allocator, &prepared, &parser));
        try expectOrderedPrefixStoreLowering(
            std.testing.allocator,
            &prepared,
            &parser.type_store,
            view,
        );
    }
}

test "uncharacterized erased prefix operands stay outside private comparison" {
    const sources = [_][]const u8{
        "const value = <T>{ first: 1, second: 2 };",
        "const value = <T>(name);",
        "const value = <T>((left) => right);",
        "<T>{ const first = 1; const second = 2; }",
        "const value = <T>{ id: \"one\" };",
        "const value = <T>(<U>(<V>(1)));",
        "const value = <T>{ id: <U>(<V>(1)) };",
    };
    for (sources) |source| switch (try compare(std.testing.allocator, source, .collect)) {
        .out_of_slice => |reason| try std.testing.expectEqual(
            OutOfSliceReason.unsupported_initializer,
            reason,
        ),
        else => return error.TestUnexpectedResult,
    };
}

test "erased prefix preflight retains removed type diagnostics" {
    const cases = [_]struct { source: []const u8, expected: AdmissionKind }{
        .{ .source = "const value = <void>(1);", .expected = .void_type },
        .{ .source = "const value = <T>(<void>(1));", .expected = .void_type },
        .{ .source = "<void>{ const value = 1; }", .expected = .void_type },
    };
    const modes = [_]AdmissionMode{ .collect, .compile };
    for (cases) |case| for (modes) |mode| {
        switch (try compare(std.testing.allocator, case.source, mode)) {
            .admission_refused => |refusal| {
                try std.testing.expectEqual(case.expected, refusal.first);
                try std.testing.expectEqual(@as(usize, 1), refusal.count);
            },
            else => return error.TestUnexpectedResult,
        }
    };
    try std.testing.expectEqual(@as(usize, 3), cases.len);
    try std.testing.expectEqual(@as(usize, 2), modes.len);

    const accepted_names = [_][]const u8{
        "const value = <any>(1);",
        "const value = <T>(<any>(1));",
        "<any>{ const value = 1; }",
    };
    for (accepted_names) |source| for (modes) |mode| {
        switch (try compare(std.testing.allocator, source, mode)) {
            .equivalent => {},
            else => return error.TestUnexpectedResult,
        }
    };
    try std.testing.expectEqual(@as(usize, 3), accepted_names.len);
}

test "spaced erased prefixes preserve assignment and general captures" {
    const cases = [_]struct {
        source: []const u8,
        actual: []const u8,
        legacy: []const u8,
        projected: bool,
    }{
        .{ .source = "const value = <T> (1);", .actual = "<T>", .legacy = "T", .projected = true },
        .{ .source = "const value = <> (1);", .actual = "<>", .legacy = "", .projected = true },
        .{ .source = "const value = (<T> { id: 1 });", .actual = "<T> ", .legacy = "T>", .projected = false },
    };
    for (cases) |case| {
        var runtime_count = CountingAllocator.init(std.testing.allocator);
        const runtime_allocator = runtime_count.allocator();
        var atoms = AtomTable.init(runtime_allocator);
        defer atoms.deinit();
        var parser = try JsParser.initTyped(runtime_allocator, std.testing.allocator, case.source);
        defer parser.deinit();
        parser.setAtomTable(&atoms);
        const root = try parser.parse();
        try expectRuntimeParityAndShape(
            case.source,
            &parser,
            root,
            &atoms,
            runtime_count,
        );

        const view = parserIrView(&parser);
        try parser.type_store.validateRuntimeOwners(std.testing.allocator, view);
        try std.testing.expectEqual(@as(usize, 1), parser.type_store.erased_type_prefixes.items.len);
        const prefix = &parser.type_store.erased_type_prefixes.items[0];
        try std.testing.expectEqualStrings(case.actual, prefix.capture_spans.actual_erased_span.text(case.source));
        try std.testing.expectEqualStrings(case.legacy, prefix.capture_spans.legacy_recorded_span.text(case.source));
        switch (prefix.compatibility) {
            .legacy_parameter_projection => try std.testing.expect(case.projected),
            .ignored_parameters => try std.testing.expect(!case.projected),
        }
        if (std.mem.eql(u8, case.source, "const value = <> (1);")) {
            const compatibility = prefix.compatibility;
            prefix.compatibility = .ignored_parameters;
            try std.testing.expectError(
                error.InvalidErasedTypePrefix,
                parser.type_store.validateRuntimeOwners(std.testing.allocator, view),
            );
            prefix.compatibility = compatibility;
            try parser.type_store.validateRuntimeOwners(std.testing.allocator, view);
        }
    }
}

test "adjacent erased prefix lists remain outside direct admission" {
    const cases = [_][]const u8{
        "const value = (<T><U>(1));",
        "const value = (<T><U>{ id: 1 });",
        "<T><U>{ const value = 1; }",
        "const value = <T><U>(1);",
        "const value = <T><U>{ id: 1 };",
    };
    for (cases) |source| {
        var prepared = try PreparedSource.init(
            std.testing.allocator,
            source,
            "<adjacent-erased-prefix-refusal>.ts",
            .{},
        );
        defer prepared.deinit();
        var legacy_count = CountingAllocator.init(std.testing.allocator);
        var direct_count = CountingAllocator.init(std.testing.allocator);
        var legacy_atoms = AtomTable.init(legacy_count.allocator());
        defer legacy_atoms.deinit();
        var direct_atoms = AtomTable.init(direct_count.allocator());
        defer direct_atoms.deinit();
        var legacy = try JsParser.init(legacy_count.allocator(), prepared.parserInput());
        defer legacy.deinit();
        legacy.setAtomTable(&legacy_atoms);
        var direct = try JsParser.initTyped(
            direct_count.allocator(),
            std.testing.allocator,
            source,
        );
        defer direct.deinit();
        direct.setAtomTable(&direct_atoms);

        try std.testing.expectError(error.UnexpectedToken, legacy.parse());
        try std.testing.expectError(error.UnexpectedToken, direct.parse());
        const first_list: u32 = @intCast(std.mem.indexOfScalar(u8, source, '<') orelse
            return error.TestUnexpectedResult);
        try std.testing.expectEqual(first_list, legacy.current.start);
        try std.testing.expectEqual(first_list, direct.current.start);
        try std.testing.expectEqualStrings("<", legacy.current.text(prepared.parserInput()));
        try std.testing.expectEqualStrings("<", direct.current.text(source));
        try std.testing.expect(sameParseErrors(&legacy, &direct));
        try std.testing.expect(equalAtoms(&legacy_atoms, &direct_atoms));
        try std.testing.expect(legacy_count.sameRuntimeShape(direct_count));
        try expectStoreCheckpoint(
            &direct.type_store,
            std.mem.zeroes(TypeSyntax.Store.Checkpoint),
        );
    }
}

test "direct erased prefix projection retains bounds and valid empty ranges" {
    const cases = [_]struct {
        source: []const u8,
        projected: u32,
        expected_bounds: []const []const u8,
    }{
        .{ .source = "const value = <T extends string>(1);", .projected = 1, .expected_bounds = &.{"string"} },
        .{ .source = "const value = <T extends { id: string }>(1);", .projected = 1, .expected_bounds = &.{"{ id: string }"} },
        .{ .source = "const value = <T extends string, U extends number>(1);", .projected = 2, .expected_bounds = &.{ "string", "number" } },
        .{ .source = "const value = <>(1);", .projected = 0, .expected_bounds = &.{} },
    };
    for (cases) |case| {
        var prepared = try PreparedSource.init(
            std.testing.allocator,
            case.source,
            "<direct-prefix-projection>.ts",
            .{},
        );
        defer prepared.deinit();
        var atoms = AtomTable.init(std.testing.allocator);
        defer atoms.deinit();
        var runtime = try JsParser.init(std.testing.allocator, prepared.parserInput());
        defer runtime.deinit();
        runtime.setAtomTable(&atoms);
        _ = try runtime.parse();

        const view = parserIrView(&runtime);
        var expression_owner: ?NodeIndex = null;
        for (runtime.nodes.tags.items, 0..) |tag, index| {
            if (tag != .var_decl) continue;
            const declaration = view.getVarDecl(@intCast(index)) orelse continue;
            expression_owner = declaration.init;
        }
        const owner = expression_owner orelse return error.TestUnexpectedResult;
        const list_start: u32 = @intCast(std.mem.indexOfScalar(u8, case.source, '<') orelse
            return error.TestUnexpectedResult);
        const scanned = (try TypeSyntax.scanBalancedGenericList(
            std.testing.allocator,
            case.source,
            list_start,
        )) orelse return error.TestUnexpectedResult;
        const operand_start: u32 = @intCast(std.mem.indexOfScalarPos(
            u8,
            case.source,
            @intCast(scanned.span.end),
            '(',
        ) orelse return error.TestUnexpectedResult);
        const operand_end: u32 = @intCast((std.mem.indexOfScalarPos(
            u8,
            case.source,
            @intCast(operand_start),
            ')',
        ) orelse return error.TestUnexpectedResult) + 1);

        var store = TypeSyntax.Store.init(std.testing.allocator, case.source);
        defer store.deinit();
        var pending = try store.reserveErasedTypePrefix(.{
            .list_span = scanned.span,
            .capture_spans = .{
                .actual_erased_span = scanned.span,
                .legacy_recorded_span = .{
                    .start = scanned.span.start + 1,
                    .end = scanned.span.end - 1,
                },
            },
            .policy = .legacy_parameter_projection,
        });
        try store.finishErasedTypePrefix(&pending, .{
            .owner = .{ .expression = owner },
            .operand_span = .{ .start = operand_start, .end = operand_end },
            .view = view,
        });
        try store.validateRuntimeOwners(std.testing.allocator, view);
        const projection = switch (store.erased_type_prefixes.items[0].compatibility) {
            .legacy_parameter_projection => |value| value,
            .ignored_parameters => return error.TestUnexpectedResult,
        };
        try std.testing.expectEqual(case.projected, projection.projected_parameters.count);
        try std.testing.expectEqual(
            @as(u32, @intCast(case.expected_bounds.len)),
            projection.semantic_fragments.count,
        );
        if (case.projected == 0) {
            try store.generic_owners.append(std.testing.allocator, .{
                .identity = .{ .function = owner },
                .list_span = scanned.span,
                .capture_spans = .{
                    .actual_erased_span = scanned.span,
                    .legacy_recorded_span = scanned.span,
                },
                .authored_parameters = .{ .start = 0, .count = 0 },
                .projected_parameters = .{ .start = 0, .count = 0 },
                .compatibility = .ignored_declaration_parameters,
            });
            try std.testing.expectError(error.InvalidTypeSourceOrder, store.validate());
            store.generic_owners.items.len -= 1;
            try store.validateRuntimeOwners(std.testing.allocator, view);
        }
        if (case.expected_bounds.len != 0) {
            const fragment_start: usize = @intCast(projection.semantic_fragments.start);
            const fragment_end = fragment_start + @as(usize, @intCast(projection.semantic_fragments.count));
            if (fragment_end > store.semantic_fragments.items.len) return error.TestUnexpectedResult;
            const fragments = store.semantic_fragments.items[fragment_start..fragment_end];
            for (case.expected_bounds, fragments) |expected, fragment| {
                try std.testing.expectEqualStrings(expected, fragment.raw_span.text(case.source));
            }

            const parameter_index: usize = @intCast(projection.projected_parameters.start);
            const original_reference = store.projected_generic_parameters.items[parameter_index].bound_fragment;
            store.projected_generic_parameters.items[parameter_index].bound_fragment = null;
            try std.testing.expectError(
                error.UnownedSemanticFragment,
                store.validateRuntimeOwners(std.testing.allocator, view),
            );
            store.projected_generic_parameters.items[parameter_index].bound_fragment = original_reference;

            try store.explicit_call_arguments.append(std.testing.allocator, .{
                .owner = owner,
                .list_span = scanned.span,
                .capture_spans = .{
                    .actual_erased_span = scanned.span,
                    .legacy_recorded_span = scanned.span,
                },
                .authored_arguments = .{
                    .start = @intCast(store.authored_call_arguments.items.len),
                    .count = 0,
                },
                .semantic_fragments = projection.semantic_fragments,
            });
            try std.testing.expectError(
                error.SharedSemanticFragment,
                store.validateRuntimeOwners(std.testing.allocator, view),
            );
            store.explicit_call_arguments.items.len -= 1;
            try store.validateRuntimeOwners(std.testing.allocator, view);

            if (case.expected_bounds.len == 2) {
                const second_index = parameter_index + 1;
                const second_reference = store.projected_generic_parameters.items[second_index].bound_fragment;
                store.projected_generic_parameters.items[second_index].bound_fragment = original_reference;
                try std.testing.expectError(
                    error.InvalidErasedTypePrefix,
                    store.validateRuntimeOwners(std.testing.allocator, view),
                );
                store.projected_generic_parameters.items[second_index].bound_fragment = second_reference;
                try store.validateRuntimeOwners(std.testing.allocator, view);
            }
        }

        var pool = TypePool.init(std.testing.allocator);
        defer pool.deinit(std.testing.allocator);
        var env = TypeEnv.init(std.testing.allocator, &pool);
        defer env.deinit();
        try lowerSyntaxStore(std.testing.allocator, &store, &pool, &env, view);
        try std.testing.expectEqual(@as(usize, 0), env.generic_scopes.items.len);
        try expectOrderedPrefixStoreLowering(
            std.testing.allocator,
            &prepared,
            &store,
            view,
        );
    }
}

test "prefix projections merge with callable generic parameters in source order" {
    const source =
        "const before = <P>(1); " ++
        "function identity<T>(value) { return value; } " ++
        "const empty = <>(1); " ++
        "const after = <Q>(2);";
    var runtime_count = CountingAllocator.init(std.testing.allocator);
    const runtime_allocator = runtime_count.allocator();
    var atoms = AtomTable.init(runtime_allocator);
    defer atoms.deinit();
    var parser = try JsParser.initTyped(runtime_allocator, std.testing.allocator, source);
    defer parser.deinit();
    parser.setAtomTable(&atoms);
    const root = try parser.parse();
    try expectRuntimeParityAndShape(source, &parser, root, &atoms, runtime_count);

    const view = parserIrView(&parser);
    try parser.type_store.validateRuntimeOwners(std.testing.allocator, view);
    try std.testing.expectEqual(@as(usize, 3), parser.type_store.erased_type_prefixes.items.len);
    try std.testing.expectEqual(@as(usize, 1), parser.type_store.generic_owners.items.len);
    const before = switch (parser.type_store.erased_type_prefixes.items[0].compatibility) {
        .legacy_parameter_projection => |projection| projection.projected_parameters,
        .ignored_parameters => return error.TestUnexpectedResult,
    };
    const empty = switch (parser.type_store.erased_type_prefixes.items[1].compatibility) {
        .legacy_parameter_projection => |projection| projection.projected_parameters,
        .ignored_parameters => return error.TestUnexpectedResult,
    };
    const after = switch (parser.type_store.erased_type_prefixes.items[2].compatibility) {
        .legacy_parameter_projection => |projection| projection.projected_parameters,
        .ignored_parameters => return error.TestUnexpectedResult,
    };
    const callable = parser.type_store.generic_owners.items[0].projected_parameters;
    try std.testing.expectEqual(TypeSyntax.Range{ .start = 0, .count = 1 }, before);
    try std.testing.expectEqual(TypeSyntax.Range{ .start = 1, .count = 1 }, callable);
    try std.testing.expectEqual(TypeSyntax.Range{ .start = 2, .count = 0 }, empty);
    try std.testing.expectEqual(TypeSyntax.Range{ .start = 2, .count = 1 }, after);

    var prepared = try PreparedSource.init(
        std.testing.allocator,
        source,
        "<mixed-prefix-projection-order>.ts",
        .{},
    );
    defer prepared.deinit();
    try expectOrderedPrefixStoreLowering(
        std.testing.allocator,
        &prepared,
        &parser.type_store,
        view,
    );

    const original = parser.type_store.erased_type_prefixes.items[2].compatibility;
    var overlap = switch (original) {
        .legacy_parameter_projection => |projection| projection,
        .ignored_parameters => return error.TestUnexpectedResult,
    };
    overlap.projected_parameters.start = 1;
    parser.type_store.erased_type_prefixes.items[2].compatibility =
        .{ .legacy_parameter_projection = overlap };
    try std.testing.expectError(
        error.InvalidErasedTypePrefix,
        parser.type_store.validateRuntimeOwners(std.testing.allocator, view),
    );
    var gap = overlap;
    gap.projected_parameters.start = 3;
    parser.type_store.erased_type_prefixes.items[2].compatibility =
        .{ .legacy_parameter_projection = gap };
    try std.testing.expectError(
        error.InvalidTypeRange,
        parser.type_store.validateRuntimeOwners(std.testing.allocator, view),
    );
    parser.type_store.erased_type_prefixes.items[2].compatibility = original;
    try parser.type_store.validateRuntimeOwners(std.testing.allocator, view);

    const original_empty = parser.type_store.erased_type_prefixes.items[1].compatibility;
    var misplaced_empty = switch (original_empty) {
        .legacy_parameter_projection => |projection| projection,
        .ignored_parameters => return error.TestUnexpectedResult,
    };
    misplaced_empty.projected_parameters.start = 1;
    parser.type_store.erased_type_prefixes.items[1].compatibility =
        .{ .legacy_parameter_projection = misplaced_empty };
    try std.testing.expectError(
        error.InvalidGenericOwner,
        parser.type_store.validateRuntimeOwners(std.testing.allocator, view),
    );
    parser.type_store.erased_type_prefixes.items[1].compatibility = original_empty;
    try parser.type_store.validateRuntimeOwners(std.testing.allocator, view);
}

test "recovered erased block removes nested syntax and retains progress" {
    const source =
        "const seed: number = 1; " ++
        "<T>{ const nested: number = 1; const broken = ; const inner_after: number = 2; } " ++
        "const after: number = 3;";
    const broken = std.mem.indexOf(u8, source, "const broken = ; ") orelse
        return error.TestUnexpectedResult;
    const control_source = try std.mem.concat(
        std.testing.allocator,
        u8,
        &.{ source[0..broken], source[broken + "const broken = ; ".len ..] },
    );
    defer std.testing.allocator.free(control_source);

    var runtime_count = CountingAllocator.init(std.testing.allocator);
    const runtime_allocator = runtime_count.allocator();
    var control_atoms = AtomTable.init(runtime_allocator);
    defer control_atoms.deinit();
    var control = try JsParser.initTyped(runtime_allocator, std.testing.allocator, control_source);
    defer control.deinit();
    control.setAtomTable(&control_atoms);
    const control_root = try control.parse();
    try expectRuntimeParityAndShape(
        control_source,
        &control,
        control_root,
        &control_atoms,
        runtime_count,
    );
    try std.testing.expectEqual(@as(usize, 1), control.type_store.erased_type_prefixes.items.len);
    try control.type_store.validateRuntimeOwners(std.testing.allocator, parserIrView(&control));

    var atoms = AtomTable.init(std.testing.allocator);
    defer atoms.deinit();
    var parser = try JsParser.initTyped(std.testing.allocator, std.testing.allocator, source);
    defer parser.deinit();
    parser.setAtomTable(&atoms);
    try std.testing.expectError(error.ParseError, parser.parse());
    try std.testing.expectEqual(TokenType.eof, parser.current.type);
    try std.testing.expectEqual(@as(u16, 0), parser.scopes.current_scope);
    try expectStoreCheckpoint(&parser.type_store, twoAnnotationCheckpoint());
    try std.testing.expectEqual(@as(usize, 0), parser.type_store.erased_type_prefixes.items.len);
    try parser.type_store.validate();

    const view = parserIrView(&parser);
    const block_offset: u32 = @intCast(std.mem.indexOfScalar(u8, source, '{') orelse
        return error.TestUnexpectedResult);
    const inner_after_offset: u32 = @intCast(std.mem.indexOf(u8, source, "const inner_after") orelse
        return error.TestUnexpectedResult);
    const after_offset: u32 = @intCast(std.mem.indexOf(u8, source, "const after") orelse
        return error.TestUnexpectedResult);
    var block_node: ?NodeIndex = null;
    var inner_after_node: ?NodeIndex = null;
    var after_node: ?NodeIndex = null;
    for (parser.nodes.tags.items, parser.nodes.locs.items, 0..) |tag, loc, index| {
        if (tag == .block and loc.offset == block_offset) block_node = @intCast(index);
        if (tag == .var_decl and loc.offset == inner_after_offset) inner_after_node = @intCast(index);
        if (tag == .var_decl and loc.offset == after_offset) after_node = @intCast(index);
    }
    const block = view.getBlock(block_node orelse return error.TestUnexpectedResult) orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u16, 2), block.stmts_count);
    const last_statement = view.getListIndex(block.stmts_start, block.stmts_count - 1);
    try std.testing.expectEqual(inner_after_node orelse return error.TestUnexpectedResult, last_statement);
    const inner_after = view.getVarDecl(last_statement) orelse return error.TestUnexpectedResult;
    const after = view.getVarDecl(after_node orelse return error.TestUnexpectedResult) orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings(
        "inner_after",
        atoms.getName(@enumFromInt(inner_after.binding.name_atom)) orelse return error.TestUnexpectedResult,
    );
    try std.testing.expectEqualStrings(
        "after",
        atoms.getName(@enumFromInt(after.binding.name_atom)) orelse return error.TestUnexpectedResult,
    );
    try std.testing.expect(std.meta.eql(after.binding, parser.type_store.annotations.items[1].binding));
    try std.testing.expectEqualStrings(
        "number",
        parser.type_store.annotations.items[1].raw_span.text(source),
    );
}

test "erased prefix relationships reject invalid intervals and owner swaps" {
    {
        const source = "const value = <T>(<U>(1));";
        var runtime_count = CountingAllocator.init(std.testing.allocator);
        const runtime_allocator = runtime_count.allocator();
        var atoms = AtomTable.init(runtime_allocator);
        defer atoms.deinit();
        var parser = try JsParser.initTyped(runtime_allocator, std.testing.allocator, source);
        defer parser.deinit();
        parser.setAtomTable(&atoms);
        const root = try parser.parse();
        try expectRuntimeParityAndShape(source, &parser, root, &atoms, runtime_count);
        const view = parserIrView(&parser);
        try parser.type_store.validateRuntimeOwners(std.testing.allocator, view);
        const prefixes = parser.type_store.erased_type_prefixes.items;
        try std.testing.expectEqual(@as(usize, 2), prefixes.len);
        const outer_owner = switch (prefixes[0].owner) {
            .expression => |runtime_node| runtime_node,
            .block => return error.TestUnexpectedResult,
        };
        const inner_owner = switch (prefixes[1].owner) {
            .expression => |runtime_node| runtime_node,
            .block => return error.TestUnexpectedResult,
        };
        try std.testing.expectEqual(outer_owner, inner_owner);

        const original_inner = prefixes[1].operand_span;
        prefixes[1].operand_span = prefixes[0].operand_span;
        try std.testing.expectError(
            error.InvalidErasedTypePrefix,
            parser.type_store.validateRuntimeOwners(std.testing.allocator, view),
        );
        prefixes[1].operand_span = original_inner;
        const original_outer = prefixes[0].operand_span;
        prefixes[0].operand_span.end = original_inner.end;
        try std.testing.expectError(
            error.InvalidErasedTypePrefix,
            parser.type_store.validateRuntimeOwners(std.testing.allocator, view),
        );
        prefixes[0].operand_span = original_outer;
        try parser.type_store.validateRuntimeOwners(std.testing.allocator, view);
    }
    {
        const source = "const left = <T>(1); const right = <U>(2);";
        var runtime_count = CountingAllocator.init(std.testing.allocator);
        const runtime_allocator = runtime_count.allocator();
        var atoms = AtomTable.init(runtime_allocator);
        defer atoms.deinit();
        var parser = try JsParser.initTyped(runtime_allocator, std.testing.allocator, source);
        defer parser.deinit();
        parser.setAtomTable(&atoms);
        const root = try parser.parse();
        try expectRuntimeParityAndShape(source, &parser, root, &atoms, runtime_count);
        const view = parserIrView(&parser);
        try parser.type_store.validateRuntimeOwners(std.testing.allocator, view);
        const prefixes = parser.type_store.erased_type_prefixes.items;
        const left_owner = prefixes[0].owner;
        const right_owner = prefixes[1].owner;
        prefixes[0].owner = right_owner;
        prefixes[1].owner = left_owner;
        try std.testing.expectError(
            error.InvalidErasedTypePrefix,
            parser.type_store.validateRuntimeOwners(std.testing.allocator, view),
        );
        prefixes[0].owner = left_owner;
        prefixes[1].owner = right_owner;
        try parser.type_store.validateRuntimeOwners(std.testing.allocator, view);
    }
}

test "type-only module refusal retains its original location" {
    const source = "import type { Spec } from \"" ++ retired_types_module ++ "\";";
    var atoms = AtomTable.init(std.testing.allocator);
    defer atoms.deinit();
    var parser = try JsParser.initTyped(std.testing.allocator, std.testing.allocator, source);
    defer parser.deinit();
    parser.setAtomTable(&atoms);

    try std.testing.expectError(error.TypeOnlyModuleRefused, parser.parse());
    const refusal = parser.type_only_module_refusal orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(TypeSyntax.TypeOnlyModuleRefusalReason.zttp_types, refusal.reason);
    try std.testing.expectEqual(@as(u32, 0), refusal.original_location.offset);
    try std.testing.expectEqual(@as(u32, 6), refusal.original_location.end_offset);
    try std.testing.expectEqual(@as(u32, 1), refusal.original_location.line);
    try std.testing.expectEqual(@as(u32, 1), refusal.original_location.column);
    try std.testing.expectEqual(@as(usize, 0), parser.type_store.type_only_modules.items.len);
    try std.testing.expectEqual(@as(usize, 0), parser.errors.getErrors().len);
}

test "type-only module matrix preserves public runtime admission and exact records" {
    const Case = struct {
        source: []const u8,
        modules: []const ExpectedTypeOnlyModule,
        runtime_success: bool,
    };
    const cases = [_]Case{
        .{
            .source = "function helper(): number { import type { A } from \"./a\"; return 1; }\n" ++
                "function handler(req: Request): Response { return Response.text(\"ok\"); }\n",
            .modules = &.{},
            .runtime_success = false,
        },
        .{
            .source = "function helper(): number { export type { A }; return 1; }\n" ++
                "function handler(req: Request): Response { return Response.text(\"ok\"); }\n",
            .modules = &.{},
            .runtime_success = false,
        },
        .{
            .source = "{ import type { A } from \"./a\"; const live = 1; }\n" ++
                "function handler(req: Request): Response { return Response.text(\"ok\"); }\n",
            .modules = &.{},
            .runtime_success = false,
        },
        .{
            .source = "import type { A } from \"./a;b\";\n" ++
                "const live: number = 1;\n" ++
                "function handler(req: Request): Response { return Response.text(\"ok\"); }\n",
            .modules = &.{.{ .kind = .import_type, .raw = "import type { A } from \"./a;b\";" }},
            .runtime_success = true,
        },
        .{
            .source = "import type { A } /* ; */ from \"./a\";\n" ++
                "function handler(req: Request): Response { return Response.text(\"ok\"); }\n",
            .modules = &.{.{ .kind = .import_type, .raw = "import type { A } /* ;" }},
            .runtime_success = false,
        },
        .{
            .source = "import /* gap */ type { A } from \"./a\";\n" ++
                "function handler(req: Request): Response { return Response.text(\"ok\"); }\n",
            .modules = &.{},
            .runtime_success = false,
        },
        .{
            .source = "export type { Spec } from \"" ++ retired_types_module ++ "\";\n" ++
                "function handler(req: Request): Response { return Response.text(\"ok\"); }\n",
            .modules = &.{.{
                .kind = .export_type,
                .raw = "export type { Spec } from \"" ++ retired_types_module ++ "\";",
            }},
            .runtime_success = true,
        },
        .{
            .source = "export type { A }   \n" ++
                "const live: number = 1;\n" ++
                "function handler(req: Request): Response { return Response.text(\"ok\"); }\n",
            .modules = &.{.{ .kind = .export_type, .raw = "export type { A }   " }},
            .runtime_success = true,
        },
        .{
            .source = "export type\n" ++
                "{ A };\n" ++
                "function handler(req: Request): Response { return Response.text(\"ok\"); }\n",
            .modules = &.{},
            .runtime_success = false,
        },
        .{
            .source = "import\n" ++
                "type { A } from \"./a\";\n" ++
                "function handler(req: Request): Response { return Response.text(\"ok\"); }\n",
            .modules = &.{.{ .kind = .import_type, .raw = "import\ntype { A } from \"./a\";" }},
            .runtime_success = true,
        },
        .{
            .source = "import type nonsense;\n" ++
                "function handler(req: Request): Response { return Response.text(\"ok\"); }\n",
            .modules = &.{.{ .kind = .import_type, .raw = "import type nonsense;" }},
            .runtime_success = true,
        },
        .{
            .source = "export type { broken nonsense };\n" ++
                "function handler(req: Request): Response { return Response.text(\"ok\"); }\n",
            .modules = &.{.{ .kind = .export_type, .raw = "export type { broken nonsense };" }},
            .runtime_success = true,
        },
        .{
            .source = "function helper(): number {\n" ++
                "  import type { A } from \"./a\";\n" ++
                "  return 1;\n" ++
                "}\n" ++
                "function handler(req: Request): Response { return Response.text(\"ok\"); }\n",
            .modules = &.{},
            .runtime_success = false,
        },
        .{
            .source = "function helper(): number {\n" ++
                "  export type { A };\n" ++
                "  return 1;\n" ++
                "}\n" ++
                "function handler(req: Request): Response { return Response.text(\"ok\"); }\n",
            .modules = &.{},
            .runtime_success = false,
        },
        .{
            .source = "{\n" ++
                "  import type { A } from \"./a\";\n" ++
                "  const live = 1;\n" ++
                "}\n" ++
                "function handler(req: Request): Response { return Response.text(\"ok\"); }\n",
            .modules = &.{},
            .runtime_success = false,
        },
        .{
            .source = "{import type { A } from \"./a\";}\n" ++
                "function handler(req: Request): Response { return Response.text(\"ok\"); }\n",
            .modules = &.{.{ .kind = .import_type, .raw = "import type { A } from \"./a\";" }},
            .runtime_success = true,
        },
        .{
            .source = "function helper(): number {import type { A } from \"./a\";return 1;}\n" ++
                "function handler(req: Request): Response { return Response.text(\"ok\"); }\n",
            .modules = &.{.{ .kind = .import_type, .raw = "import type { A } from \"./a\";" }},
            .runtime_success = true,
        },
        .{
            .source = "function helper(): number {export type { A };return 1;}\n" ++
                "function handler(req: Request): Response { return Response.text(\"ok\"); }\n",
            .modules = &.{.{ .kind = .export_type, .raw = "export type { A };" }},
            .runtime_success = true,
        },
        .{
            .source = "{\n" ++
                "import type { A } from \"./a\";\n" ++
                "}\n" ++
                "function handler(req: Request): Response { return Response.text(\"ok\"); }\n",
            .modules = &.{.{ .kind = .import_type, .raw = "import type { A } from \"./a\";" }},
            .runtime_success = true,
        },
        .{
            .source = "function helper(): number {\n" ++
                "import type { A } from \"./a\";\n" ++
                "return 1;\n" ++
                "}\n" ++
                "function handler(req: Request): Response { return Response.text(\"ok\"); }\n",
            .modules = &.{.{ .kind = .import_type, .raw = "import type { A } from \"./a\";" }},
            .runtime_success = true,
        },
        .{
            .source = "function helper(): number {\n" ++
                "export type { A };\n" ++
                "return 1;\n" ++
                "}\n" ++
                "function handler(req: Request): Response { return Response.text(\"ok\"); }\n",
            .modules = &.{.{ .kind = .export_type, .raw = "export type { A };" }},
            .runtime_success = true,
        },
        .{
            .source = " import type { A } from \"./a\";\n" ++
                "function handler(req: Request): Response { return Response.text(\"ok\"); }\n",
            .modules = &.{},
            .runtime_success = false,
        },
        .{
            .source = "const live: number = 1;import type { A } from \"./a\";\n" ++
                "function handler(req: Request): Response { return Response.text(\"ok\"); }\n",
            .modules = &.{.{ .kind = .import_type, .raw = "import type { A } from \"./a\";" }},
            .runtime_success = true,
        },
        .{
            .source = "const live: number = 1; import type { A } from \"./a\";\n" ++
                "function handler(req: Request): Response { return Response.text(\"ok\"); }\n",
            .modules = &.{},
            .runtime_success = false,
        },
        .{
            .source = "import type { A } from \"./a\";export type { B };\n" ++
                "function handler(req: Request): Response { return Response.text(\"ok\"); }\n",
            .modules = &.{.{ .kind = .import_type, .raw = "import type { A } from \"./a\";" }},
            .runtime_success = false,
        },
    };

    for (cases) |case| {
        try expectTypeOnlyModuleCase(case.source, case.modules, case.runtime_success);
    }
    try std.testing.expectEqual(@as(usize, 25), cases.len);
}

test "type-only module matrix retains import-only zttp refusal locations" {
    const sources = [_][]const u8{
        "import type { Spec } from \"" ++ retired_types_module ++ "\";\n" ++
            "function handler(req: Request): Response { return Response.text(\"ok\"); }\n",
        "import type { A } /* \"" ++ retired_types_module ++ "\" */ from \"./a\";\n" ++
            "function handler(req: Request): Response { return Response.text(\"ok\"); }\n",
    };
    for (sources) |source| try expectTypeOnlyModuleRefusal(source, 0);
    try std.testing.expectEqual(@as(usize, 2), sources.len);
}

test "type-only module rich source retains declarations and live binding" {
    const source =
        "import type { A } from \"./a\";\n" ++
        "export type { B }\n" ++
        "export structural Shape = { value: string };\n" ++
        "export nominal Id = string;\n" ++
        "const live: number = 1;\n" ++
        "function handler(req: Request): Response { return Response.text(\"ok\"); }\n";
    try expectTypeOnlyModuleCase(source, &.{
        .{ .kind = .import_type, .raw = "import type { A } from \"./a\";" },
        .{ .kind = .export_type, .raw = "export type { B }" },
    }, true);

    var atoms = AtomTable.init(std.testing.allocator);
    defer atoms.deinit();
    var parser = try JsParser.initTyped(std.testing.allocator, std.testing.allocator, source);
    defer parser.deinit();
    parser.setAtomTable(&atoms);
    _ = try parser.parse();
    try std.testing.expectEqual(@as(usize, 2), parser.type_store.declarations.items.len);
    try std.testing.expectEqual(TypeSyntax.DeclarationKind.structural, parser.type_store.declarations.items[0].kind);
    try std.testing.expectEqual(TypeSyntax.DeclarationKind.nominal, parser.type_store.declarations.items[1].kind);
    for (parser.type_store.declarations.items) |declaration| {
        const export_span = declaration.export_span orelse return error.TestUnexpectedResult;
        try std.testing.expectEqualStrings("export", export_span.text(source));
    }
    try std.testing.expectEqual(@as(usize, 1), parser.type_store.annotations.items.len);
    const annotation = parser.type_store.annotations.items[0];
    try std.testing.expectEqualStrings("number", annotation.raw_span.text(source));
    const view = parserIrView(&parser);
    var live_declaration: ?NodeIndex = null;
    var handler_declaration: ?NodeIndex = null;
    for (parser.nodes.tags.items, parser.nodes.locs.items, 0..) |tag, loc, index| {
        if (tag == .var_decl and std.mem.startsWith(u8, source[loc.offset..], "const live")) {
            try std.testing.expect(live_declaration == null);
            live_declaration = @intCast(index);
        }
        if (tag == .function_decl) {
            try std.testing.expect(handler_declaration == null);
            handler_declaration = @intCast(index);
        }
    }
    const live = view.getVarDecl(live_declaration orelse return error.TestUnexpectedResult) orelse
        return error.TestUnexpectedResult;
    try std.testing.expect(std.meta.eql(live.binding, annotation.binding));
    try std.testing.expectEqual(@as(usize, 1), parser.type_store.function_signatures.items.len);
    try std.testing.expectEqual(@as(usize, 1), parser.type_store.parameter_annotations.items.len);
    const wrapper = handler_declaration orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(engine.parser.NodeTag.function_decl, view.getTag(wrapper).?);
    const handler = view.getVarDecl(wrapper) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("handler", atoms.getName(@enumFromInt(handler.binding.name_atom)).?);
    const signature = parser.type_store.function_signatures.items[0];
    try std.testing.expectEqual(handler.init, signature.owner);
    try std.testing.expectEqual(engine.parser.NodeTag.function_expr, view.getTag(signature.owner).?);
    const function = view.getFunction(signature.owner) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u8, 1), function.params_count);
    const parameter = parser.type_store.parameter_annotations.items[0];
    try std.testing.expectEqual(@as(u32, 0), signature.parameters.start);
    try std.testing.expectEqual(@as(u32, 1), signature.parameters.count);
    try std.testing.expectEqual(parameter.owner.pattern, view.getListIndex(function.params_start, 0));
    try std.testing.expect(std.meta.eql(parameter.owner.binding, view.paramBinding(parameter.owner.pattern).?));
    try std.testing.expectEqualStrings("req", atoms.getName(@enumFromInt(parameter.owner.binding.name_atom)).?);
    try std.testing.expectEqualStrings("Request", parameter.value.raw_span.text(source));
    const parameter_root = switch (parameter.value.root) {
        .present => |index| parser.type_store.nodes.items[index],
        .absent => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(TypeSyntax.NodeTag.named_reference, parameter_root.tag);
    try std.testing.expectEqualStrings("Request", parameter_root.data.named_reference.text(source));
    const return_syntax = signature.return_syntax orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("Response ", return_syntax.raw_span.text(source));
    const return_value = switch (return_syntax.structure) {
        .value => |value| value,
        .predicate => return error.TestUnexpectedResult,
    };
    const return_root = switch (return_value.root) {
        .present => |index| parser.type_store.nodes.items[index],
        .absent => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(TypeSyntax.NodeTag.named_reference, return_root.tag);
    try std.testing.expectEqualStrings("Response", return_root.data.named_reference.text(source));
    try parser.type_store.validateRuntimeOwners(std.testing.allocator, view);
}

test "type-only module matrix preserves module-only and leading erasures" {
    try expectTypeOnlyModuleCase(
        "import type { A } from \"./a\";",
        &.{.{ .kind = .import_type, .raw = "import type { A } from \"./a\";" }},
        true,
    );
    try expectTypeOnlyModuleCase(
        "export type { A }\nconst live: number = 1;",
        &.{.{ .kind = .export_type, .raw = "export type { A }" }},
        true,
    );
}

test "type-only module scanner leaves the comment semicolon survivor location exact" {
    const source =
        "import type { A } /* ; */ from \"./a\";\n" ++
        "function handler(req: Request): Response { return Response.text(\"ok\"); }\n";
    var parser = try JsParser.initTyped(std.testing.allocator, std.testing.allocator, source);
    defer parser.deinit();
    _ = parser.parse() catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => 0,
    };
    try std.testing.expect(parser.errors.getErrors().len > 0);
    try std.testing.expectEqual(@as(u32, 1), parser.errors.getErrors()[0].location.line);
    try std.testing.expectEqual(@as(u32, 24), parser.errors.getErrors()[0].location.column);
    try std.testing.expectEqualStrings(
        "import type { A } /* ;",
        parser.type_store.type_only_modules.items[0].raw_span.text(source),
    );
}

test "type-only module matrix preserves template spill runtime parity" {
    var source: std.ArrayListUnmanaged(u8) = .empty;
    defer source.deinit(std.testing.allocator);
    try source.appendSlice(std.testing.allocator, "import type ");
    for (0..TypeSyntax.max_template_levels + 1) |_| {
        try source.appendSlice(std.testing.allocator, "`${");
    }
    try source.appendSlice(std.testing.allocator, "value");
    for (0..TypeSyntax.max_template_levels + 1) |_| {
        try source.appendSlice(std.testing.allocator, "}`");
    }
    try source.appendSlice(
        std.testing.allocator,
        ";\nconst live: number = 1;\n",
    );
    const semicolon = std.mem.indexOfScalar(u8, source.items, ';') orelse
        return error.TestUnexpectedResult;
    try expectTypeOnlyModuleCase(source.items, &.{.{
        .kind = .import_type,
        .raw = source.items[0 .. semicolon + 1],
    }}, true);
}

test "type-only module allocation sweeps retain the earlier module" {
    var clean: std.ArrayListUnmanaged(u8) = .empty;
    defer clean.deinit(std.testing.allocator);
    try clean.appendSlice(std.testing.allocator, "import type { Seed } from \"./seed\";\n");
    const clean_second_offset: u32 = @intCast(clean.items.len);
    try clean.appendSlice(std.testing.allocator, "import type ");
    for (0..TypeSyntax.max_template_levels + 1) |_| {
        try clean.appendSlice(std.testing.allocator, "`${");
    }
    try clean.appendSlice(std.testing.allocator, "value");
    for (0..TypeSyntax.max_template_levels + 1) |_| {
        try clean.appendSlice(std.testing.allocator, "}`");
    }
    try clean.appendSlice(std.testing.allocator, ";");

    var clean_observed: ModuleAllocationObservations = .{};
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        runCleanModuleTypeAllocationSweep,
        .{
            clean.items,
            clean_second_offset,
            &clean_observed,
        },
    );
    try std.testing.expect(clean_observed.failures > 0);
    try std.testing.expect(clean_observed.post_seed_failures > 0);

    var excluded: std.ArrayListUnmanaged(u8) = .empty;
    defer excluded.deinit(std.testing.allocator);
    try excluded.appendSlice(std.testing.allocator, "import type { Seed } from \"./seed\";\n");
    const excluded_second_offset: u32 = @intCast(excluded.items.len);
    try excluded.appendSlice(std.testing.allocator, "import type `${");
    try excluded.appendNTimes(std.testing.allocator, '{', TypeSyntax.max_type_depth + 1);
    try excluded.appendSlice(std.testing.allocator, ";tail");

    var excluded_observed: ModuleAllocationObservations = .{};
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        runExcludedModuleTypeAllocationSweep,
        .{
            excluded.items,
            excluded_second_offset,
            &excluded_observed,
        },
    );
    try std.testing.expect(excluded_observed.failures > 0);
    try std.testing.expect(excluded_observed.post_seed_failures > 0);
}

test "typed predicate arrow owns its exact header syntax" {
    const source = "const guard = (candidate, marker: unknown): candidate is string => typeof candidate === \"string\";";
    var atoms = AtomTable.init(std.testing.allocator);
    defer atoms.deinit();
    var parser = try JsParser.initTyped(std.testing.allocator, std.testing.allocator, source);
    defer parser.deinit();
    parser.setAtomTable(&atoms);
    const root = try parser.parse();

    try expectFunctionSliceRuntimeParity(
        std.testing.allocator,
        source,
        &parser,
        root,
        &atoms,
    );

    const view = parserIrView(&parser);
    try parser.type_store.validateRuntimeOwners(std.testing.allocator, view);
    try std.testing.expectEqual(@as(usize, 1), parser.type_store.function_signatures.items.len);
    try std.testing.expectEqual(@as(usize, 1), parser.type_store.parameter_annotations.items.len);
    const signature = &parser.type_store.function_signatures.items[0];
    try std.testing.expectEqual(engine.parser.NodeTag.arrow_function, view.getTag(signature.owner).?);
    const function = view.getFunction(signature.owner) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u8, 2), function.params_count);
    const candidate = view.getListIndex(function.params_start, 0);
    const marker = view.getListIndex(function.params_start, 1);
    const annotation = parser.type_store.parameter_annotations.items[0];
    try std.testing.expectEqual(marker, annotation.owner.pattern);
    try std.testing.expect(std.meta.eql(
        annotation.owner.binding,
        view.paramBinding(marker) orelse return error.TestUnexpectedResult,
    ));
    try std.testing.expectEqualStrings("unknown", annotation.value.raw_span.text(source));

    const return_syntax = if (signature.return_syntax) |*value| value else return error.TestUnexpectedResult;
    try std.testing.expectEqual(TypeSyntax.LegacyReturnKind.type_guard, return_syntax.legacy_return_kind);
    try std.testing.expect(return_syntax.legacy_ordinary_prefix == null);
    const predicate = switch (return_syntax.structure) {
        .predicate => |*value| value,
        .value => return error.TestUnexpectedResult,
    };
    const target = switch (predicate.target) {
        .resolved => |value| value,
        .unresolved => return error.TestUnexpectedResult,
    };
    const candidate_binding = view.paramBinding(candidate) orelse return error.TestUnexpectedResult;
    const marker_binding = view.paramBinding(marker) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(candidate, target.pattern);
    try std.testing.expect(std.meta.eql(target.binding, candidate_binding));
    try std.testing.expectEqualStrings("candidate", predicate.target_span.text(source));
    try std.testing.expectEqualStrings("string", predicate.narrowed.raw_span.text(source));
    try std.testing.expectEqualStrings("candidate is string ", return_syntax.raw_span.text(source));
    const opener = std.mem.indexOfScalar(u8, source, '(') orelse return error.TestUnexpectedResult;
    const body = std.mem.indexOf(u8, source, "typeof") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u32, @intCast(opener)), signature.source_span.start);
    try std.testing.expectEqual(@as(u32, @intCast(body)), signature.source_span.end);

    try expectFirstPredicateArrowLowering(&parser);

    const original_target = predicate.target;
    predicate.target = .{ .resolved = .{
        .pattern = marker,
        .binding = marker_binding,
    } };
    try std.testing.expectError(
        error.InvalidPredicateTarget,
        parser.type_store.validateRuntimeOwners(std.testing.allocator, view),
    );
    predicate.target = .{ .resolved = .{
        .pattern = candidate,
        .binding = marker_binding,
    } };
    try std.testing.expectError(
        error.InvalidPredicateTarget,
        parser.type_store.validateRuntimeOwners(std.testing.allocator, view),
    );
    predicate.target = .unresolved;
    try std.testing.expectError(
        error.InvalidPredicateTarget,
        parser.type_store.validateRuntimeOwners(std.testing.allocator, view),
    );
    predicate.target = original_target;

    const original_target_span = predicate.target_span;
    const marker_location = view.getLoc(marker) orelse return error.TestUnexpectedResult;
    predicate.target_span = .{
        .start = marker_location.offset,
        .end = marker_location.offset + @as(u32, "marker".len),
    };
    try std.testing.expectError(
        error.InvalidReturnSyntax,
        parser.type_store.validateRuntimeOwners(std.testing.allocator, view),
    );
    predicate.target_span = original_target_span;
    try parser.type_store.validateRuntimeOwners(std.testing.allocator, view);
}

test "predicate arrows retain the first repeated parameter as target" {
    const source = "const guard = (candidate, candidate: unknown): candidate is string => typeof candidate === \"string\";";
    var atoms = AtomTable.init(std.testing.allocator);
    defer atoms.deinit();
    var parser = try JsParser.initTyped(std.testing.allocator, std.testing.allocator, source);
    defer parser.deinit();
    parser.setAtomTable(&atoms);
    const root = try parser.parse();
    try expectFunctionSliceRuntimeParity(std.testing.allocator, source, &parser, root, &atoms);

    const view = parserIrView(&parser);
    try parser.type_store.validateRuntimeOwners(std.testing.allocator, view);
    try std.testing.expectEqual(@as(usize, 1), parser.type_store.function_signatures.items.len);
    try std.testing.expectEqual(@as(usize, 1), parser.type_store.parameter_annotations.items.len);
    const signature = parser.type_store.function_signatures.items[0];
    const function = view.getFunction(signature.owner) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u8, 2), function.params_count);
    const first = view.getListIndex(function.params_start, 0);
    const second = view.getListIndex(function.params_start, 1);
    try std.testing.expect(first != second);
    try std.testing.expectEqual(second, parser.type_store.parameter_annotations.items[0].owner.pattern);
    const return_syntax = signature.return_syntax orelse return error.TestUnexpectedResult;
    const target = switch (return_syntax.structure) {
        .predicate => |predicate| switch (predicate.target) {
            .resolved => |target| target,
            .unresolved => return error.TestUnexpectedResult,
        },
        .value => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(first, target.pattern);
    try std.testing.expect(std.meta.eql(target.binding, view.paramBinding(first).?));
    try expectFirstPredicateArrowLowering(&parser);
}

test "ordinary typed arrow owns parameter and return roots" {
    const source = "const echo = (value: string): string => value;";
    var atoms = AtomTable.init(std.testing.allocator);
    defer atoms.deinit();
    var parser = try JsParser.initTyped(std.testing.allocator, std.testing.allocator, source);
    defer parser.deinit();
    parser.setAtomTable(&atoms);
    const root = try parser.parse();
    try expectFunctionSliceRuntimeParity(std.testing.allocator, source, &parser, root, &atoms);

    const view = parserIrView(&parser);
    try parser.type_store.validateRuntimeOwners(std.testing.allocator, view);
    try std.testing.expectEqual(@as(usize, 1), parser.type_store.function_signatures.items.len);
    try std.testing.expectEqual(@as(usize, 1), parser.type_store.parameter_annotations.items.len);
    const signature = parser.type_store.function_signatures.items[0];
    try std.testing.expectEqual(engine.parser.NodeTag.arrow_function, view.getTag(signature.owner).?);
    const return_syntax = signature.return_syntax orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(TypeSyntax.LegacyReturnKind.ordinary, return_syntax.legacy_return_kind);
    try std.testing.expect(return_syntax.legacy_ordinary_prefix == null);
    const return_value = switch (return_syntax.structure) {
        .value => |value| value,
        .predicate => return error.TestUnexpectedResult,
    };
    const values = [_]TypeSyntax.TypeValue{
        parser.type_store.parameter_annotations.items[0].value,
        return_value,
    };
    try expectOrderedTypeValueTags(&parser, &values, &.{ .t_string, .t_string });
}

test "named and arrow returns retain predicate facets" {
    const Shape = enum { mixed, unresolved, quoted, tab };
    const Case = struct {
        source: []const u8,
        owner_tag: engine.parser.NodeTag,
        shape: Shape,
    };
    const cases = [_]Case{
        .{
            .source = "function guard(candidate, marker: unknown): candidate is string { return typeof candidate === \"string\"; }",
            .owner_tag = .function_expr,
            .shape = .mixed,
        },
        .{
            .source = "const guard = (candidate, marker: unknown): candidate is string => typeof candidate === \"string\";",
            .owner_tag = .arrow_function,
            .shape = .mixed,
        },
        .{
            .source = "function guard(value: unknown): missing is string { return true; }",
            .owner_tag = .function_expr,
            .shape = .unresolved,
        },
        .{
            .source = "const guard = (value: unknown): missing is string => true;",
            .owner_tag = .arrow_function,
            .shape = .unresolved,
        },
        .{
            .source = "function guard(value: unknown): \"x is y\" { return true; }",
            .owner_tag = .function_expr,
            .shape = .quoted,
        },
        .{
            .source = "const guard = (value: unknown): \"x is y\" => true;",
            .owner_tag = .arrow_function,
            .shape = .quoted,
        },
        .{
            .source = "function guard(value: unknown): value\tis\tstring { return true; }",
            .owner_tag = .function_expr,
            .shape = .tab,
        },
        .{
            .source = "const guard = (value: unknown): value\tis\tstring => true;",
            .owner_tag = .arrow_function,
            .shape = .tab,
        },
    };

    for (cases) |case| {
        var atoms = AtomTable.init(std.testing.allocator);
        defer atoms.deinit();
        var parser = try JsParser.initTyped(std.testing.allocator, std.testing.allocator, case.source);
        defer parser.deinit();
        parser.setAtomTable(&atoms);
        const root = try parser.parse();
        try expectFunctionSliceRuntimeParity(
            std.testing.allocator,
            case.source,
            &parser,
            root,
            &atoms,
        );

        const view = parserIrView(&parser);
        try parser.type_store.validateRuntimeOwners(std.testing.allocator, view);
        try std.testing.expectEqual(@as(usize, 1), parser.type_store.function_signatures.items.len);
        const signature = parser.type_store.function_signatures.items[0];
        try std.testing.expectEqual(case.owner_tag, view.getTag(signature.owner).?);
        const return_syntax = signature.return_syntax orelse return error.TestUnexpectedResult;
        switch (case.shape) {
            .quoted => {
                try std.testing.expectEqual(TypeSyntax.LegacyReturnKind.type_guard, return_syntax.legacy_return_kind);
                try std.testing.expect(return_syntax.legacy_ordinary_prefix == null);
                const value = switch (return_syntax.structure) {
                    .value => |actual| actual,
                    .predicate => return error.TestUnexpectedResult,
                };
                const node = parser.type_store.node(try syntaxChildIndex(value.root)) orelse
                    return error.TestUnexpectedResult;
                try std.testing.expectEqual(TypeSyntax.NodeTag.literal_string, node.tag);
            },
            .mixed, .unresolved, .tab => {
                const predicate = switch (return_syntax.structure) {
                    .predicate => |actual| actual,
                    .value => return error.TestUnexpectedResult,
                };
                switch (case.shape) {
                    .mixed => {
                        try std.testing.expectEqual(TypeSyntax.LegacyReturnKind.type_guard, return_syntax.legacy_return_kind);
                        try std.testing.expect(return_syntax.legacy_ordinary_prefix == null);
                        const target = switch (predicate.target) {
                            .resolved => |actual| actual,
                            .unresolved => return error.TestUnexpectedResult,
                        };
                        const function = view.getFunction(signature.owner) orelse
                            return error.TestUnexpectedResult;
                        try std.testing.expectEqual(
                            view.getListIndex(function.params_start, 0),
                            target.pattern,
                        );
                        try std.testing.expectEqual(@as(usize, 1), parser.type_store.parameter_annotations.items.len);
                    },
                    .unresolved => {
                        try std.testing.expectEqual(TypeSyntax.LegacyReturnKind.type_guard, return_syntax.legacy_return_kind);
                        try std.testing.expect(return_syntax.legacy_ordinary_prefix == null);
                        try std.testing.expectEqualStrings("missing", predicate.target_span.text(case.source));
                        switch (predicate.target) {
                            .unresolved => {},
                            .resolved => return error.TestUnexpectedResult,
                        }
                    },
                    .tab => {
                        try std.testing.expectEqual(TypeSyntax.LegacyReturnKind.ordinary, return_syntax.legacy_return_kind);
                        const compatibility = return_syntax.legacy_ordinary_prefix orelse
                            return error.TestUnexpectedResult;
                        try std.testing.expectEqualStrings("value\tis\tstring ", return_syntax.raw_span.text(case.source));
                        try std.testing.expectEqualStrings(return_syntax.raw_span.text(case.source), compatibility.raw_span.text(case.source));
                        const values = [_]TypeSyntax.TypeValue{ predicate.narrowed, compatibility };
                        try expectOrderedTypeValueTags(&parser, &values, &.{ .t_string, .t_ref });
                    },
                    .quoted => unreachable,
                }
            },
        }
    }
    try std.testing.expectEqual(@as(usize, 8), cases.len);
}

test "ordinary predicates parse whole grammar compatibility roots" {
    const Case = struct {
        source: []const u8,
        compatibility_tag: TypeSyntax.NodeTag,
        lowered_tag: TypeTag,
    };
    const cases = [_]Case{
        .{
            .source = "function byReadonly(readonly: unknown): readonly\tis\tstring { return true; }",
            .compatibility_tag = .readonly_modifier,
            .lowered_tag = .t_ref,
        },
        .{
            .source = "function byPrimitive(string: unknown): string\tis\tnumber { return true; }",
            .compatibility_tag = .primitive,
            .lowered_tag = .t_string,
        },
    };
    for (cases) |case| {
        var atoms = AtomTable.init(std.testing.allocator);
        defer atoms.deinit();
        var parser = try JsParser.initTyped(std.testing.allocator, std.testing.allocator, case.source);
        defer parser.deinit();
        parser.setAtomTable(&atoms);
        const root = try parser.parse();
        try expectFunctionSliceRuntimeParity(
            std.testing.allocator,
            case.source,
            &parser,
            root,
            &atoms,
        );

        const view = parserIrView(&parser);
        try parser.type_store.validateRuntimeOwners(std.testing.allocator, view);
        const return_syntax = parser.type_store.function_signatures.items[0].return_syntax orelse
            return error.TestUnexpectedResult;
        const predicate = switch (return_syntax.structure) {
            .predicate => |actual| actual,
            .value => return error.TestUnexpectedResult,
        };
        const compatibility = return_syntax.legacy_ordinary_prefix orelse
            return error.TestUnexpectedResult;
        const compatibility_node = parser.type_store.node(try syntaxChildIndex(compatibility.root)) orelse
            return error.TestUnexpectedResult;
        try std.testing.expectEqual(case.compatibility_tag, compatibility_node.tag);
        if (compatibility_node.tag == .readonly_modifier) {
            const child = switch (compatibility_node.data) {
                .readonly_modifier => |actual| actual,
                else => unreachable,
            };
            const child_node = parser.type_store.node(try syntaxChildIndex(child)) orelse
                return error.TestUnexpectedResult;
            try std.testing.expectEqual(TypeSyntax.NodeTag.named_reference, child_node.tag);
            const child_span = switch (child_node.data) {
                .named_reference => |span| span,
                else => unreachable,
            };
            try std.testing.expectEqualStrings("is", child_span.text(case.source));
        } else {
            const primitive = switch (compatibility_node.data) {
                .primitive => |actual| actual,
                else => unreachable,
            };
            try std.testing.expectEqual(TypeSyntax.Primitive.string, primitive);
        }
        const values = [_]TypeSyntax.TypeValue{ predicate.narrowed, compatibility };
        const narrowed_tag: TypeTag = if (case.compatibility_tag == .primitive) .t_number else .t_string;
        try expectOrderedTypeValueTags(&parser, &values, &.{ narrowed_tag, case.lowered_tag });
    }
    try std.testing.expectEqual(@as(usize, 2), cases.len);
}

test "empty predicate narrowing retains the untrimmed whitespace tail" {
    const Case = struct {
        source: []const u8,
        expected_raw: []const u8,
        expected_narrowed: []const u8,
        kind: TypeSyntax.LegacyReturnKind,
        empty: bool,
    };
    const cases = [_]Case{
        .{ .source = "function guard(value: unknown): value is { return true; }", .expected_raw = "value is ", .expected_narrowed = " ", .kind = .type_guard, .empty = true },
        .{ .source = "const guard = (value: unknown): value is => true;", .expected_raw = "value is ", .expected_narrowed = " ", .kind = .type_guard, .empty = true },
        .{ .source = "function guard(value: unknown): value\tis\t{ return true; }", .expected_raw = "value\tis\t", .expected_narrowed = "\t", .kind = .ordinary, .empty = true },
        .{ .source = "const guard = (value: unknown): value\tis\t=> true;", .expected_raw = "value\tis\t", .expected_narrowed = "\t", .kind = .ordinary, .empty = true },
        .{ .source = "function guard(value: unknown): value is string   { return true; }", .expected_raw = "value is string   ", .expected_narrowed = "string", .kind = .type_guard, .empty = false },
        .{ .source = "const guard = (value: unknown): value is string   => true;", .expected_raw = "value is string   ", .expected_narrowed = "string", .kind = .type_guard, .empty = false },
    };
    for (cases) |case| {
        var atoms = AtomTable.init(std.testing.allocator);
        defer atoms.deinit();
        var parser = try JsParser.initTyped(std.testing.allocator, std.testing.allocator, case.source);
        defer parser.deinit();
        parser.setAtomTable(&atoms);
        const root = try parser.parse();
        try expectFunctionSliceRuntimeParity(
            std.testing.allocator,
            case.source,
            &parser,
            root,
            &atoms,
        );

        const view = parserIrView(&parser);
        try parser.type_store.validateRuntimeOwners(std.testing.allocator, view);
        const return_syntax = parser.type_store.function_signatures.items[0].return_syntax orelse
            return error.TestUnexpectedResult;
        try std.testing.expectEqual(case.kind, return_syntax.legacy_return_kind);
        try std.testing.expectEqualStrings(case.expected_raw, return_syntax.raw_span.text(case.source));
        const predicate = switch (return_syntax.structure) {
            .predicate => |actual| actual,
            .value => return error.TestUnexpectedResult,
        };
        try std.testing.expectEqualStrings(case.expected_narrowed, predicate.narrowed.raw_span.text(case.source));
        if (case.empty) {
            switch (predicate.narrowed.root) {
                .absent => {},
                .present => return error.TestUnexpectedResult,
            }
            try std.testing.expectEqual(@as(u32, 0), predicate.narrowed.node_range.count);
            try std.testing.expectEqual(return_syntax.raw_span.end, predicate.narrowed.admission_end);
            try std.testing.expectEqual(predicate.narrowed.raw_span.end, predicate.narrowed.semantic_prefix_end);
        } else {
            try std.testing.expect(predicate.narrowed.node_range.count > 0);
        }
        if (case.kind == .ordinary) {
            const compatibility = return_syntax.legacy_ordinary_prefix orelse
                return error.TestUnexpectedResult;
            try std.testing.expect(compatibility.node_range.count > 0);
            try std.testing.expectEqualStrings(case.expected_raw, compatibility.raw_span.text(case.source));
        } else {
            try std.testing.expect(return_syntax.legacy_ordinary_prefix == null);
        }
    }
    try std.testing.expectEqual(@as(usize, 6), cases.len);
}

test "nested return function type selects the outer arrow" {
    const source = "const make = (): (value: string) => string => (value: string): string => value;";
    var atoms = AtomTable.init(std.testing.allocator);
    defer atoms.deinit();
    var parser = try JsParser.initTyped(std.testing.allocator, std.testing.allocator, source);
    defer parser.deinit();
    parser.setAtomTable(&atoms);
    const root = try parser.parse();
    try expectFunctionSliceRuntimeParity(std.testing.allocator, source, &parser, root, &atoms);

    const view = parserIrView(&parser);
    try parser.type_store.validateRuntimeOwners(std.testing.allocator, view);
    try std.testing.expectEqual(@as(usize, 2), parser.type_store.function_signatures.items.len);
    const outer = parser.type_store.function_signatures.items[0];
    const inner = parser.type_store.function_signatures.items[1];
    try std.testing.expect(outer.source_span.start < inner.source_span.start);
    try std.testing.expectEqual(engine.parser.NodeTag.arrow_function, view.getTag(outer.owner).?);
    try std.testing.expectEqual(engine.parser.NodeTag.arrow_function, view.getTag(inner.owner).?);
    const outer_return = outer.return_syntax orelse return error.TestUnexpectedResult;
    const outer_value = switch (outer_return.structure) {
        .value => |value| value,
        .predicate => return error.TestUnexpectedResult,
    };
    const outer_root = parser.type_store.node(try syntaxChildIndex(outer_value.root)) orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqual(TypeSyntax.NodeTag.function, outer_root.tag);
    try std.testing.expectEqual(@as(u32, 0), outer.parameters.count);
    try std.testing.expectEqual(@as(u32, 1), inner.parameters.count);
    try std.testing.expect(inner.return_syntax != null);
}

test "arrow lookahead keeps grouped controls outside signatures" {
    {
        const source = "const choice = true ? (1) : (2);";
        var atoms = AtomTable.init(std.testing.allocator);
        defer atoms.deinit();
        var parser = try JsParser.initTyped(std.testing.allocator, std.testing.allocator, source);
        defer parser.deinit();
        parser.setAtomTable(&atoms);
        const root = try parser.parse();
        try expectFunctionSliceRuntimeParity(std.testing.allocator, source, &parser, root, &atoms);
        try std.testing.expectEqual(@as(usize, 0), parser.type_store.function_signatures.items.len);
        try std.testing.expectEqual(@as(usize, 0), parser.type_store.parameter_annotations.items.len);
    }

    {
        const source = "const make = (): (value: string) => string;";
        var parser = try JsParser.initTyped(std.testing.allocator, std.testing.allocator, source);
        defer parser.deinit();
        try std.testing.expectError(error.UnexpectedToken, parser.parse());
        const errors = parser.errors.getErrors();
        try std.testing.expectEqual(@as(usize, 1), errors.len);
        try std.testing.expectEqual(engine.parser.ErrorKind.unexpected_token, errors[0].kind);
        try std.testing.expectEqualStrings("unexpected ')'", errors[0].message);
        try std.testing.expectEqual(@as(u32, 15), errors[0].location.offset);
        try std.testing.expectEqual(@as(u32, 1), errors[0].location.line);
        try std.testing.expectEqual(@as(u32, 16), errors[0].location.column);
        try std.testing.expect(errors[0].expected == null);
        try std.testing.expect(errors[0].suggestion == null);
        try std.testing.expectEqual(@as(usize, 0), parser.type_store.function_signatures.items.len);
        try std.testing.expectEqual(@as(usize, 0), parser.type_store.parameter_annotations.items.len);
    }
}

test "predicate target validation rejects external runtime identity" {
    const source =
        "function left(value: unknown): value is string { return true; }\n" ++
        "const right = (value: unknown): value is string => true;\n";
    var atoms = AtomTable.init(std.testing.allocator);
    defer atoms.deinit();
    var parser = try JsParser.initTyped(std.testing.allocator, std.testing.allocator, source);
    defer parser.deinit();
    parser.setAtomTable(&atoms);
    const root = try parser.parse();
    try expectFunctionSliceRuntimeParity(std.testing.allocator, source, &parser, root, &atoms);

    const view = parserIrView(&parser);
    try parser.type_store.validateRuntimeOwners(std.testing.allocator, view);
    try std.testing.expectEqual(@as(usize, 2), parser.type_store.function_signatures.items.len);
    const left_signature = parser.type_store.function_signatures.items[0];
    const right_signature = parser.type_store.function_signatures.items[1];
    const left_function = view.getFunction(left_signature.owner) orelse return error.TestUnexpectedResult;
    const right_function = view.getFunction(right_signature.owner) orelse return error.TestUnexpectedResult;
    const left_pattern = view.getListIndex(left_function.params_start, 0);
    const right_pattern = view.getListIndex(right_function.params_start, 0);
    const left_binding = view.paramBinding(left_pattern) orelse return error.TestUnexpectedResult;
    const right_binding = view.paramBinding(right_pattern) orelse return error.TestUnexpectedResult;
    const return_syntax = if (parser.type_store.function_signatures.items[0].return_syntax) |*value|
        value
    else
        return error.TestUnexpectedResult;
    const predicate = switch (return_syntax.structure) {
        .predicate => |*actual| actual,
        .value => return error.TestUnexpectedResult,
    };
    const original = predicate.target;

    predicate.target = .{ .resolved = .{ .pattern = right_pattern, .binding = right_binding } };
    try std.testing.expectError(
        error.InvalidPredicateTarget,
        parser.type_store.validateRuntimeOwners(std.testing.allocator, view),
    );
    predicate.target = .{ .resolved = .{ .pattern = left_pattern, .binding = right_binding } };
    try std.testing.expectError(
        error.InvalidPredicateTarget,
        parser.type_store.validateRuntimeOwners(std.testing.allocator, view),
    );
    predicate.target = .unresolved;
    try std.testing.expectError(
        error.InvalidPredicateTarget,
        parser.type_store.validateRuntimeOwners(std.testing.allocator, view),
    );
    predicate.target = original;
    try std.testing.expect(std.meta.eql(left_binding, switch (original) {
        .resolved => |target| target.binding,
        .unresolved => return error.TestUnexpectedResult,
    }));
    try parser.type_store.validateRuntimeOwners(std.testing.allocator, view);
}

test "predicate compatibility range cannot own narrowing nodes" {
    const source = "const guard = (value: unknown): value\tis\tstring => true;";
    var atoms = AtomTable.init(std.testing.allocator);
    defer atoms.deinit();
    var parser = try JsParser.initTyped(std.testing.allocator, std.testing.allocator, source);
    defer parser.deinit();
    parser.setAtomTable(&atoms);
    const root = try parser.parse();
    try expectFunctionSliceRuntimeParity(std.testing.allocator, source, &parser, root, &atoms);

    const view = parserIrView(&parser);
    try parser.type_store.validateRuntimeOwners(std.testing.allocator, view);
    const return_syntax = if (parser.type_store.function_signatures.items[0].return_syntax) |*value|
        value
    else
        return error.TestUnexpectedResult;
    const predicate = switch (return_syntax.structure) {
        .predicate => |actual| actual,
        .value => return error.TestUnexpectedResult,
    };
    const compatibility = if (return_syntax.legacy_ordinary_prefix) |*value|
        value
    else
        return error.TestUnexpectedResult;
    const original_root = compatibility.root;
    const original_range = compatibility.node_range;
    compatibility.root = predicate.narrowed.root;
    compatibility.node_range = predicate.narrowed.node_range;
    try std.testing.expectError(
        error.OverlappingTypeNodeOwnership,
        parser.type_store.validateRuntimeOwners(std.testing.allocator, view),
    );
    compatibility.root = original_root;
    compatibility.node_range = original_range;
    try parser.type_store.validateRuntimeOwners(std.testing.allocator, view);
}

test "recovered predicate blocks retain surrounding annotations" {
    const cases = [_]struct { source: []const u8, owner_tag: engine.parser.NodeTag }{
        .{ .source = "const seed: number = 1;\n" ++
            "function guard(value: unknown): value is string {\n" ++
            "  const broken = ;\n" ++
            "  return true;\n" ++
            "}\n" ++
            "const after: number = 2;\n", .owner_tag = .function_expr },
        .{ .source = "const seed: number = 1;\n" ++
            "const guard = (value: unknown): value is string => {\n" ++
            "  const broken = ;\n" ++
            "  return true;\n" ++
            "};\n" ++
            "const after: number = 2;\n", .owner_tag = .arrow_function },
    };
    for (cases) |case| {
        const source = case.source;
        var atoms = AtomTable.init(std.testing.allocator);
        defer atoms.deinit();
        var parser = try JsParser.initTyped(std.testing.allocator, std.testing.allocator, source);
        defer parser.deinit();
        parser.setAtomTable(&atoms);
        try std.testing.expectError(error.ParseError, parser.parse());
        try std.testing.expectEqual(TokenType.eof, parser.current.type);
        try std.testing.expectEqual(@as(u16, 0), parser.scopes.current_scope);
        try expectStoreCheckpoint(&parser.type_store, twoAnnotationCheckpoint());
        const view = parserIrView(&parser);
        try parser.type_store.validateRuntimeOwners(std.testing.allocator, view);
        const seed_node = try runtimeNodeAt(&parser, .var_decl, 0);
        const after_offset: u32 = @intCast(std.mem.indexOf(u8, source, "const after").?);
        const opener_offset: u32 = @intCast(std.mem.indexOf(u8, source, "(value").?);
        var after_node: ?NodeIndex = null;
        var function_node: ?NodeIndex = null;
        for (parser.nodes.tags.items, parser.nodes.locs.items, 0..) |tag, loc, index| {
            if (tag == .var_decl and loc.offset == after_offset) {
                try std.testing.expect(after_node == null);
                after_node = @intCast(index);
            }
            if (tag == case.owner_tag and loc.offset == opener_offset) {
                try std.testing.expect(function_node == null);
                function_node = @intCast(index);
            }
        }
        const after = view.getVarDecl(after_node orelse return error.TestUnexpectedResult) orelse
            return error.TestUnexpectedResult;
        const seed_owner = parser.type_store.annotations.items[0].runtime_owner orelse
            return error.TestUnexpectedResult;
        const after_owner = parser.type_store.annotations.items[1].runtime_owner orelse
            return error.TestUnexpectedResult;
        try std.testing.expectEqual(seed_node, seed_owner.declaration);
        try std.testing.expectEqual(@as(u32, 0), seed_owner.declaration_start);
        try std.testing.expectEqual(after_node.?, after_owner.declaration);
        try std.testing.expectEqual(after_offset, after_owner.declaration_start);
        try std.testing.expect(std.meta.eql(after.binding, parser.type_store.annotations.items[1].binding));
        try std.testing.expect(!std.meta.eql(after.binding, parser.type_store.annotations.items[0].binding));
        try std.testing.expectEqualStrings("number", parser.type_store.annotations.items[1].raw_span.text(source));
        const function = view.getFunction(function_node orelse return error.TestUnexpectedResult) orelse
            return error.TestUnexpectedResult;
        try std.testing.expectEqual(engine.parser.NodeTag.block, view.getTag(function.body).?);
        const block = view.getBlock(function.body) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqual(@as(u16, 1), block.stmts_count);
        const retained_return = view.getListIndex(block.stmts_start, 0);
        try std.testing.expectEqual(engine.parser.NodeTag.return_stmt, view.getTag(retained_return).?);
        try std.testing.expectEqual(
            @as(u32, @intCast(std.mem.indexOf(u8, source, "return true").?)),
            view.getLoc(retained_return).?.offset,
        );
        const value = view.getOptValue(retained_return) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqual(engine.parser.NodeTag.lit_bool, view.getTag(value).?);
        try std.testing.expectEqual(true, view.getBoolValue(value).?);
    }
    try std.testing.expectEqual(@as(usize, 2), cases.len);
}

test "nested function signatures publish in header order" {
    const source =
        "const seed: number = 1;\n" ++
        "function outer(value: string): string {\n" ++
        "  function inner(count: number): number { return count; }\n" ++
        "  return value;\n" ++
        "}\n";
    var atoms = AtomTable.init(std.testing.allocator);
    defer atoms.deinit();
    var parser = try JsParser.initTyped(std.testing.allocator, std.testing.allocator, source);
    defer parser.deinit();
    parser.setAtomTable(&atoms);
    const root = try parser.parse();
    try expectFunctionSliceRuntimeParity(
        std.testing.allocator,
        source,
        &parser,
        root,
        &atoms,
    );
    const view = engine.parser.IrView.fromIRStore(&parser.nodes, &parser.constants);
    try parser.type_store.validateRuntimeOwners(std.testing.allocator, view);
    try std.testing.expectEqual(@as(usize, 2), parser.type_store.function_signatures.items.len);
    try std.testing.expectEqual(@as(usize, 2), parser.type_store.parameter_annotations.items.len);
    const outer = parser.type_store.function_signatures.items[0];
    const inner = parser.type_store.function_signatures.items[1];
    try std.testing.expectEqual(@as(u32, 0), outer.parameters.start);
    try std.testing.expectEqual(@as(u32, 1), outer.parameters.count);
    try std.testing.expectEqual(@as(u32, 1), inner.parameters.start);
    try std.testing.expectEqual(@as(u32, 1), inner.parameters.count);
    try std.testing.expect(outer.source_span.start < inner.source_span.start);
    try std.testing.expectEqual(
        @as(u32, @intCast(std.mem.indexOf(u8, source, "(value").?)),
        outer.source_span.start,
    );
    try std.testing.expectEqual(
        @as(u32, @intCast(std.mem.indexOf(u8, source, "(count").?)),
        inner.source_span.start,
    );
}

test "generic-only function creates no function signature" {
    const source = "function identity<T>(value) { return value; }\n";
    var parser = try JsParser.initTyped(std.testing.allocator, std.testing.allocator, source);
    defer parser.deinit();
    _ = try parser.parse();
    try parser.type_store.validate();
    try std.testing.expectEqual(@as(usize, 1), parser.type_store.generic_owners.items.len);
    try std.testing.expectEqual(@as(usize, 0), parser.type_store.parameter_annotations.items.len);
    try std.testing.expectEqual(@as(usize, 0), parser.type_store.function_signatures.items.len);
}

test "recovered typed function body retains only prior syntax" {
    const source =
        "const seed: number = 1;\n" ++
        "function identity(value: string): string {\n" ++
        "  const broken = ;\n" ++
        "  return value;\n" ++
        "}\n";
    var parser = try JsParser.initTyped(std.testing.allocator, std.testing.allocator, source);
    defer parser.deinit();
    try std.testing.expectError(error.ParseError, parser.parse());
    try std.testing.expectEqual(TokenType.eof, parser.current.type);
    try parser.type_store.validate();
    try std.testing.expectEqual(@as(usize, 1), parser.type_store.nodes.items.len);
    try std.testing.expectEqual(@as(usize, 1), parser.type_store.annotations.items.len);
    try std.testing.expectEqual(@as(usize, 0), parser.type_store.parameter_annotations.items.len);
    try std.testing.expectEqual(@as(usize, 0), parser.type_store.function_signatures.items.len);
    try std.testing.expectEqual(@as(usize, 1), countRuntimeTag(&parser, .function_expr));
    try std.testing.expectEqual(@as(usize, 1), countRuntimeTag(&parser, .function_decl));
    try std.testing.expectEqual(@as(usize, 1), countRuntimeTag(&parser, .return_stmt));
    const view = engine.parser.IrView.fromIRStore(&parser.nodes, &parser.constants);
    var function_node: ?NodeIndex = null;
    for (parser.nodes.tags.items, 0..) |tag, index| {
        if (tag == .function_expr) function_node = @intCast(index);
    }
    const function = view.getFunction(function_node orelse return error.TestUnexpectedResult) orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqual(engine.parser.NodeTag.block, view.getTag(function.body).?);
}

test "recovered outer body removes completed inner function syntax" {
    const source =
        "const seed: number = 1;\n" ++
        "function outer(value: string): string {\n" ++
        "  function inner(count: number): number { return count; }\n" ++
        "  const broken = ;\n" ++
        "  return value;\n" ++
        "}\n" ++
        "const after = 2;\n";
    var parser = try JsParser.initTyped(std.testing.allocator, std.testing.allocator, source);
    defer parser.deinit();
    try std.testing.expectError(error.ParseError, parser.parse());
    try std.testing.expectEqual(TokenType.eof, parser.current.type);
    try parser.type_store.validate();
    try std.testing.expectEqual(@as(usize, 1), parser.type_store.nodes.items.len);
    try std.testing.expectEqual(@as(usize, 1), parser.type_store.annotations.items.len);
    try std.testing.expectEqual(@as(usize, 0), parser.type_store.parameter_annotations.items.len);
    try std.testing.expectEqual(@as(usize, 0), parser.type_store.function_signatures.items.len);
    try std.testing.expectEqual(@as(usize, 2), countRuntimeTag(&parser, .function_expr));
    try std.testing.expectEqual(@as(usize, 2), countRuntimeTag(&parser, .function_decl));
    try std.testing.expectEqual(@as(usize, 2), countRuntimeTag(&parser, .return_stmt));
    try std.testing.expectEqual(@as(usize, 2), countRuntimeTag(&parser, .var_decl));
}

test "function signature validation rejects wrong runtime tags" {
    const source =
        "const seed: number = 1;\n" ++
        "function identity(value: string): string { return value; }\n";
    var parser = try JsParser.initTyped(std.testing.allocator, std.testing.allocator, source);
    defer parser.deinit();
    _ = try parser.parse();
    const view = engine.parser.IrView.fromIRStore(&parser.nodes, &parser.constants);
    const signature = &parser.type_store.function_signatures.items[0];
    const original_owner = signature.owner;
    const original_pattern = parser.type_store.parameter_annotations.items[0].owner.pattern;
    var variable: ?NodeIndex = null;
    var wrapper: ?NodeIndex = null;
    var block: ?NodeIndex = null;
    for (parser.nodes.tags.items, 0..) |tag, index| switch (tag) {
        .var_decl => variable = @intCast(index),
        .function_decl => wrapper = @intCast(index),
        .block => if (block == null) {
            block = @intCast(index);
        },
        else => {},
    };
    const wrong_owners = [_]NodeIndex{
        variable orelse return error.TestUnexpectedResult,
        wrapper orelse return error.TestUnexpectedResult,
        block orelse return error.TestUnexpectedResult,
        engine.parser.null_node,
    };
    for (wrong_owners) |wrong| {
        signature.owner = wrong;
        try std.testing.expectError(
            error.InvalidFunctionSignatureOwner,
            parser.type_store.validateRuntimeOwners(std.testing.allocator, view),
        );
    }
    signature.owner = original_owner;
    parser.type_store.parameter_annotations.items[0].owner.pattern = wrapper.?;
    try std.testing.expectError(
        error.InvalidFunctionParameterOwner,
        parser.type_store.validateRuntimeOwners(std.testing.allocator, view),
    );
    parser.type_store.parameter_annotations.items[0].owner.pattern = original_pattern;
    try std.testing.expectError(
        error.InvalidFunctionSignatureOwner,
        parser.type_store.validateFunctionDeclarationWrapper(original_owner, variable.?, view),
    );
    try std.testing.expectError(
        error.InvalidFunctionSignatureOwner,
        parser.type_store.validateFunctionDeclarationWrapper(original_owner, block.?, view),
    );
    try parser.type_store.validateRuntimeOwners(std.testing.allocator, view);
}

test "function signature type allocation failures preserve published seed syntax" {
    const source =
        "const seed: number = 1;\n" ++
        "function identity(value: string): string { return value; }\n";
    const Context = struct {
        fn run(
            type_allocator: std.mem.Allocator,
            observed_type_failures: *usize,
            observed_seed_rollbacks: *usize,
        ) !void {
            const function_start: u32 = @intCast(std.mem.indexOf(u8, source, "function identity") orelse
                return error.TestUnexpectedResult);
            var atoms = AtomTable.init(std.testing.allocator);
            defer atoms.deinit();
            var parser = try JsParser.initTyped(std.testing.allocator, type_allocator, source);
            defer parser.deinit();
            parser.setAtomTable(&atoms);
            const root = parser.parse() catch |err| {
                switch (err) {
                    error.OutOfMemory => {},
                    else => return err,
                }
                observed_type_failures.* += 1;
                try std.testing.expectEqual(@as(u16, 0), parser.scopes.current_scope);
                if (parser.current.start < function_start) {
                    try expectStoreCheckpoint(
                        &parser.type_store,
                        std.mem.zeroes(TypeSyntax.Store.Checkpoint),
                    );
                } else {
                    try expectStoreCheckpoint(&parser.type_store, seedCheckpoint());
                    observed_seed_rollbacks.* += 1;
                    try parser.type_store.validateRuntimeOwners(
                        std.testing.allocator,
                        parserIrView(&parser),
                    );
                }
                return err;
            };
            try expectFunctionSliceRuntimeParity(
                std.testing.allocator,
                source,
                &parser,
                root,
                &atoms,
            );
            try expectFirstFunctionSliceRecords(&parser, source);
            try std.testing.expect(parser.type_store.nodes.items.len > 0);
            try std.testing.expect(parser.type_store.annotations.items.len > 0);
            try std.testing.expect(parser.type_store.parameter_annotations.items.len > 0);
            try std.testing.expect(parser.type_store.function_signatures.items.len > 0);
        }
    };
    var observed_type_failures: usize = 0;
    var observed_seed_rollbacks: usize = 0;
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        Context.run,
        .{ &observed_type_failures, &observed_seed_rollbacks },
    );
    try std.testing.expect(observed_type_failures > 0);
    try std.testing.expect(observed_seed_rollbacks > 0);
}

test "predicate header type allocation failures restore the seed checkpoint" {
    const cases = [_]HeaderAllocationCase{ .mixed, .tab };
    for (cases) |case| {
        var observed_failures: usize = 0;
        var observed_post_seed_rollbacks: usize = 0;
        try std.testing.checkAllAllocationFailures(
            std.testing.allocator,
            runHeaderTypeAllocation,
            .{ case, &observed_failures, &observed_post_seed_rollbacks },
        );
        try std.testing.expect(observed_failures > 0);
        try std.testing.expect(observed_post_seed_rollbacks > 0);
    }
    try std.testing.expectEqual(@as(usize, 2), cases.len);
}

test "typed generic arrow allocation failures restore every store array" {
    const cases = [_]GenericArrowAllocationCase{ .dedicated, .legacy_call };
    for (cases) |case| {
        var observations: GenericArrowAllocationObservations = .{};
        try std.testing.checkAllAllocationFailures(
            std.testing.allocator,
            runGenericArrowTypeAllocation,
            .{ case, &observations },
        );
        try std.testing.expect(observations.failures > 0);
        try std.testing.expect(observations.post_seed_rollbacks > 0);
        try std.testing.expect(observations.successes > 0);
    }
    try std.testing.expectEqual(@as(usize, 2), cases.len);
}

test "named function comment allocation failures follow source progress" {
    const cases = [_]NamedFunctionCommentAllocationCase{ .before_name, .after_list };
    for (cases) |case| {
        var observations: NamedFunctionCommentAllocationObservations = .{};
        try std.testing.checkAllAllocationFailures(
            std.testing.allocator,
            runNamedFunctionCommentTypeAllocation,
            .{ case, &observations },
        );
        try std.testing.expect(observations.failures > 0);
        try std.testing.expect(observations.post_seed_rollbacks > 0);
        try std.testing.expect(observations.successes > 0);
    }
    try std.testing.expectEqual(@as(usize, 2), cases.len);
}

test "function signature validation rejects swapped return-only owners" {
    const source =
        "function left(): number { return 1; }\n" ++
        "function right(): string { return \"x\"; }\n";
    var parser = try JsParser.initTyped(std.testing.allocator, std.testing.allocator, source);
    defer parser.deinit();
    _ = try parser.parse();
    const view = engine.parser.IrView.fromIRStore(&parser.nodes, &parser.constants);
    try parser.type_store.validateRuntimeOwners(std.testing.allocator, view);
    try std.testing.expectEqual(@as(usize, 2), parser.type_store.function_signatures.items.len);
    try std.testing.expectEqual(@as(usize, 0), parser.type_store.parameter_annotations.items.len);
    const signatures = parser.type_store.function_signatures.items;
    try std.testing.expectEqual(@as(u32, 0), signatures[0].parameters.count);
    try std.testing.expectEqual(@as(u32, 0), signatures[1].parameters.count);
    const left = signatures[0].owner;
    const right = signatures[1].owner;
    try std.testing.expect(left != right);
    signatures[0].owner = right;
    signatures[1].owner = left;
    try std.testing.expectError(
        error.InvalidFunctionSignatureOwner,
        parser.type_store.validateRuntimeOwners(std.testing.allocator, view),
    );
    signatures[0].owner = left;
    signatures[1].owner = right;
    try parser.type_store.validateRuntimeOwners(std.testing.allocator, view);
}

test "function signature validation rejects reassigned parameter owners" {
    {
        const source = "function pair(a: string, b: number): number { return b; }\n";
        var parser = try JsParser.initTyped(std.testing.allocator, std.testing.allocator, source);
        defer parser.deinit();
        _ = try parser.parse();
        const view = engine.parser.IrView.fromIRStore(&parser.nodes, &parser.constants);
        try parser.type_store.validateRuntimeOwners(std.testing.allocator, view);
        try std.testing.expectEqual(@as(usize, 2), parser.type_store.parameter_annotations.items.len);
        const parameters = parser.type_store.parameter_annotations.items;
        const first_owner = parameters[0].owner;
        const second_owner = parameters[1].owner;
        parameters[0].owner = second_owner;
        parameters[1].owner = first_owner;
        try std.testing.expectError(
            error.InvalidFunctionParameterOwner,
            parser.type_store.validateRuntimeOwners(std.testing.allocator, view),
        );
        parameters[0].owner = first_owner;
        parameters[1].owner = second_owner;
        try parser.type_store.validateRuntimeOwners(std.testing.allocator, view);
    }

    {
        const source = "function f(a, b: number): number { return b; }\n";
        var parser = try JsParser.initTyped(std.testing.allocator, std.testing.allocator, source);
        defer parser.deinit();
        _ = try parser.parse();
        const view = engine.parser.IrView.fromIRStore(&parser.nodes, &parser.constants);
        try parser.type_store.validateRuntimeOwners(std.testing.allocator, view);
        try std.testing.expectEqual(@as(usize, 1), parser.type_store.parameter_annotations.items.len);
        const signature = parser.type_store.function_signatures.items[0];
        const function = view.getFunction(signature.owner) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqual(@as(u8, 2), function.params_count);
        const first_pattern = view.getListIndex(function.params_start, 0);
        const first_binding = view.paramBinding(first_pattern) orelse return error.TestUnexpectedResult;
        const parameter = &parser.type_store.parameter_annotations.items[0];
        const original_owner = parameter.owner;
        parameter.owner = .{ .pattern = first_pattern, .binding = first_binding };
        try std.testing.expectError(
            error.InvalidFunctionParameterOwner,
            parser.type_store.validateRuntimeOwners(std.testing.allocator, view),
        );
        parameter.owner = original_owner;
        try parser.type_store.validateRuntimeOwners(std.testing.allocator, view);
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
    try lowerSyntaxStoreWithoutRuntimeOwners(allocator, &store, &pool, &env);
    try std.testing.expectEqual(
        null_type_idx,
        env.getVarTypeByBinding(0, 300) orelse return error.TestUnexpectedResult,
    );
    try pool.ensureHealthy();
    try env.ensureHealthy();
}

const ApplicationCase = enum {
    ambient_proof,
    nested_closers,
    optional_comma,
    absent_first_argument,
    absent_later_argument,
    absent_first_before_close,
    absent_later_before_close,
    dict_exact_arity,
    dict_wrong_arity,
    readonly_record_nested,
    readonly_tuple_nested,
    ungrouped_array_suffix,
    grouped_array_suffix,
};

const ApplicationFixture = struct {
    case: ApplicationCase,
    source: []const u8,
};

const application_fixtures = [_]ApplicationFixture{
    .{ .case = .ambient_proof, .source = "const value: Proof<Response, \"pure\"> = undefined;" },
    .{ .case = .nested_closers, .source = "const value: Outer<Middle<Inner<string>>> = undefined;" },
    .{ .case = .optional_comma, .source = "const value: Outer<string number> = undefined;" },
    .{ .case = .absent_first_argument, .source = "const value: Outer<(), string> = undefined;" },
    .{ .case = .absent_later_argument, .source = "const value: Outer<string, (), number> = undefined;" },
    .{ .case = .absent_first_before_close, .source = "const value: Outer<()> = undefined;" },
    .{ .case = .absent_later_before_close, .source = "const value: Outer<string, ()> = undefined;" },
    .{ .case = .dict_exact_arity, .source = "const value: Dict<string, number> = undefined;" },
    .{ .case = .dict_wrong_arity, .source = "const value: Dict<string> = undefined;" },
    .{
        .case = .readonly_record_nested,
        .source = "const value: { item: Readonly<{ id: number }> } = undefined;",
    },
    .{
        .case = .readonly_tuple_nested,
        .source = "const value: [Readonly<{ id: number }>] = undefined;",
    },
    .{ .case = .ungrouped_array_suffix, .source = "const value: Outer<string>[] = undefined;" },
    .{ .case = .grouped_array_suffix, .source = "const value: (Outer<string>)[] = undefined;" },
};

const GenericAliasCase = enum {
    complete_record,
    spaced_list,
    empty_list,
    present_null_body,
    absent_body,
    ignored_constraint,
    ignored_default,
    eight_item_projection,
    ninth_item_unprojected,
    generic_then_plain,
    plain_then_generic,
    ambient_replacement,
    alias_before_parameter,
    duplicate_parameter,
    nested_substitution,
    nested_application_projection,
    default_comparison,
    constraint_closer,
    default_less_than,
    constraint_less_than,
    wrapped_constraint_less_than,
    nested_arrow_default,
    quoted_equals,
    adjacent_alias_equals,
    adjacent_annotation_equals,
};

const GenericAliasFixture = struct {
    case: GenericAliasCase,
    source: []const u8,
};

const generic_alias_fixtures = [_]GenericAliasFixture{
    .{
        .case = .complete_record,
        .source = "structural Box<T extends string = boolean> = { value: T };\n" ++
            "const value: Box<number> = undefined;",
    },
    .{ .case = .spaced_list, .source = "structural Box <T> = { value: T };\nconst value: Box<number> = undefined;" },
    .{ .case = .empty_list, .source = "structural Box<> = number;\nconst value: Box<> = undefined;" },
    .{ .case = .present_null_body, .source = "structural Empty<T> = ();" },
    .{ .case = .absent_body, .source = "structural Empty<T> =;" },
    .{ .case = .ignored_constraint, .source = "structural Box<T extends string> = { value: T };\nconst value: Box<number> = undefined;" },
    .{ .case = .ignored_default, .source = "structural Box<T = string> = { value: T };\nconst value: Box<number> = undefined;" },
    .{ .case = .eight_item_projection, .source = "structural Wide<A,B,C,D,E,F,G,H> = H;\nconst value: Wide<string,string,string,string,string,string,string,number> = undefined;" },
    .{ .case = .ninth_item_unprojected, .source = "structural Many<A,B,C,D,E,F,G,H,I> = I;" },
    .{ .case = .generic_then_plain, .source = "structural Both<T> = T;\nstructural Both = number;" },
    .{ .case = .plain_then_generic, .source = "structural Both = number;\nstructural Both<T> = T;" },
    .{ .case = .ambient_replacement, .source = "structural Proof<T> = { value: T };\nconst value: Proof<number> = undefined;" },
    .{ .case = .alias_before_parameter, .source = "structural T = number;\nstructural Box<T> = T;\nconst value: Box<string> = undefined;" },
    .{ .case = .duplicate_parameter, .source = "structural Box<T,T> = T;\nconst value: Box<string,number> = undefined;" },
    .{ .case = .nested_substitution, .source = "structural Box<T> = { values: T[] };\nconst value: Box<number> = undefined;" },
    .{ .case = .nested_application_projection, .source = "structural Inner<T> = { value: T };\nstructural Outer<U> = Inner<U>;\nconst value: Outer<number> = undefined;" },
    .{ .case = .default_comparison, .source = "structural Box<T = (left > right)> = number;\nconst value: Box<string> = undefined;" },
    .{ .case = .constraint_closer, .source = "structural Box<T extends { value: Missing > }> = number;\nconst value: Box<string> = undefined;" },
    .{ .case = .default_less_than, .source = "structural Box<T = (left < right)> = number;\nconst value: Box<> = undefined;" },
    .{ .case = .constraint_less_than, .source = "structural Box<T extends { value: Missing < } = boolean> = number;\nconst value: Box<> = undefined;" },
    .{ .case = .wrapped_constraint_less_than, .source = "structural Box<T extends Wrap<{ value: Missing < }, string> = boolean> = number;\nconst value: Box<> = undefined;" },
    .{ .case = .nested_arrow_default, .source = "structural Box<T = Wrap<(x: string) => number, string>> = number;\nconst value: Box<string,number> = undefined;" },
    .{ .case = .quoted_equals, .source = "structural Box<T extends \"a=b\" = boolean> = number;\nconst value: Box<string> = undefined;" },
    .{ .case = .adjacent_alias_equals, .source = "structural Box<T>=T;\nconst value: Box<number> = undefined;" },
    .{ .case = .adjacent_annotation_equals, .source = "structural Box<T> = T;\nconst value:Box<number>=undefined;" },
};

const GenericProjectionCase = enum {
    blank_piece_before_limit,
    nonempty_empty_name,
    quoted_comma,
    comment_comma,
    authored_empty_piece,
    malformed_tail,
    nested_arrow_default,
    quoted_equals_metadata,
    arrow_constraint_metadata,
    commented_equals_metadata,
};

const GenericProjectionFixture = struct {
    case: GenericProjectionCase,
    source: []const u8,
};

const generic_projection_fixtures = [_]GenericProjectionFixture{
    .{ .case = .blank_piece_before_limit, .source = "structural Box<A, ,B,C,D,E,F,G,H,I> = A;" },
    .{ .case = .nonempty_empty_name, .source = "structural Box<=string,T extends number> = T;" },
    .{ .case = .quoted_comma, .source = "structural Box<T extends \"a,b\"> = T;" },
    .{ .case = .comment_comma, .source = "structural Box<T /*,*/> = T;" },
    .{ .case = .authored_empty_piece, .source = "structural Box<T,,U> = T;" },
    .{ .case = .malformed_tail, .source = "structural Box<T nonsense> = T;" },
    .{ .case = .nested_arrow_default, .source = "structural Box<T=Wrap<(x:string)=>number,string>> = number;\nconst value: Box<string,number> = undefined;" },
    .{ .case = .quoted_equals_metadata, .source = "structural Box<T extends \"a=b\" = boolean> = number;\nconst value: Box<string> = undefined;" },
    .{ .case = .arrow_constraint_metadata, .source = "structural Box<T extends (x:string)=>number = boolean> = number;\nconst value: Box<string> = undefined;" },
    .{ .case = .commented_equals_metadata, .source = "structural Box<T extends Wrap<string /* = */> = boolean> = number;\nconst value: Box<string> = undefined;" },
};

const GenericFragmentCase = enum {
    exact_dict_key,
    default_suffixed_dict_key,
    numeric_prefix,
    leading_union,
    leading_intersection,
    any_name,
    partial_string,
    nested_application,
};

const generic_fragment_fixtures = [_]struct { case: GenericFragmentCase, source: []const u8 }{
    .{ .case = .exact_dict_key, .source = "DictKey" },
    .{ .case = .default_suffixed_dict_key, .source = "DictKey = string" },
    .{ .case = .numeric_prefix, .source = "1.5" },
    .{ .case = .leading_union, .source = "| number" },
    .{ .case = .leading_intersection, .source = "& number" },
    .{ .case = .any_name, .source = "any" },
    .{ .case = .partial_string, .source = "\"partial" },
    .{ .case = .nested_application, .source = "Outer<string>" },
};

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
    generic_declaration,
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
    .{ .case = .generic_declaration, .source = "structural Box<T> = T;", .probe = .equivalent },
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

const SyntaxApplicationView = struct {
    arguments: []const TypeSyntax.Child,
};

fn syntaxChildIndex(child: TypeSyntax.Child) !TypeSyntax.NodeIndex {
    return switch (child) {
        .absent => return error.TestUnexpectedResult,
        .present => |index| index,
    };
}

fn expectSyntaxApplication(
    store: *const TypeSyntax.Store,
    child: TypeSyntax.Child,
    base_name: []const u8,
    argument_count: usize,
) !SyntaxApplicationView {
    const index = try syntaxChildIndex(child);
    const node = store.node(index) orelse return error.TestUnexpectedResult;
    const application = switch (node.data) {
        .generic_application => |value| value,
        else => return error.TestUnexpectedResult,
    };
    const base_index = try syntaxChildIndex(application.base);
    try std.testing.expect(base_index < index);
    const base = store.node(base_index) orelse return error.TestUnexpectedResult;
    const base_span = switch (base.data) {
        .named_reference => |span| span,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqualStrings(base_name, base_span.text(store.source));
    const arguments = store.memberSlice(application.arguments) orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqual(argument_count, arguments.len);
    var previous_start = base.semantic_span.end;
    for (arguments) |argument| {
        const argument_index = try syntaxChildIndex(argument);
        try std.testing.expect(argument_index < index);
        const argument_node = store.node(argument_index) orelse return error.TestUnexpectedResult;
        try std.testing.expect(argument_node.semantic_span.start >= previous_start);
        previous_start = argument_node.semantic_span.start;
    }
    return .{ .arguments = arguments };
}

fn expectPoolGenericApplication(
    pool: *const TypePool,
    index: TypeIndex,
    base_name: []const u8,
    argument_count: usize,
) !void {
    try std.testing.expectEqual(
        TypeTag.t_generic_app,
        pool.getTag(index) orelse return error.TestUnexpectedResult,
    );
    const application = pool.getGenericAppInfo(index);
    try expectRefName(pool, application.base, base_name);
    try std.testing.expectEqual(argument_count, application.args.len);
}

fn assertApplicationSemanticProperty(case: ApplicationCase, source: []const u8) !void {
    var parser = try JsParser.initTyped(std.testing.allocator, std.testing.allocator, source);
    defer parser.deinit();
    _ = try parser.parse();
    try parser.type_store.validate();
    try std.testing.expectEqual(@as(usize, 1), parser.type_store.annotations.items.len);
    const annotation = parser.type_store.annotations.items[0];

    for (parser.type_store.nodes.items, 0..) |node, index| {
        if (node.tag != .generic_application) continue;
        try std.testing.expect(node.semantic_span.start >= annotation.raw_span.start);
        try std.testing.expect(node.semantic_span.end <= annotation.raw_span.end);
        const application = node.data.generic_application;
        const base_index = switch (application.base) {
            .absent => return error.TestUnexpectedResult,
            .present => |value| value,
        };
        try std.testing.expect(@as(usize, base_index) < index);
        const arguments = parser.type_store.memberSlice(application.arguments) orelse
            return error.TestUnexpectedResult;
        for (arguments) |argument| switch (argument) {
            .absent => return error.TestUnexpectedResult,
            .present => |value| try std.testing.expect(@as(usize, value) < index),
        };
    }

    var pool = TypePool.init(std.testing.allocator);
    defer pool.deinit(std.testing.allocator);
    var env = TypeEnv.init(std.testing.allocator, &pool);
    defer env.deinit();
    module_types.populateModuleTypes(&env, &pool, std.testing.allocator);
    abi_types.populateHandlerAbiTypes(&env, &pool, std.testing.allocator);
    try lowerSyntaxStore(std.testing.allocator, &parser.type_store, &pool, &env, parserIrView(&parser));
    try pool.ensureHealthy();
    try env.ensureHealthy();
    const lowered = env.getVarTypeByBinding(annotation.binding.scope_id, annotation.binding.name_atom) orelse
        return error.TestUnexpectedResult;

    switch (case) {
        .ambient_proof => {
            _ = try expectSyntaxApplication(&parser.type_store, annotation.root, "Proof", 2);
            try std.testing.expectEqual(
                TypeTag.t_intersection,
                pool.getTag(lowered) orelse return error.TestUnexpectedResult,
            );
            const members = pool.getIntersectionMembers(lowered);
            try std.testing.expectEqual(@as(usize, 2), members.len);
            var found_marker = false;
            for (members) |member| {
                for (pool.getRecordFields(member)) |field| {
                    if (!std.mem.eql(
                        u8,
                        pool.getName(field.name_start, field.name_len),
                        type_env_mod.proof_marker_field,
                    )) continue;
                    const marker = pool.getLiteralStringValue(field.type_idx) orelse
                        return error.TestUnexpectedResult;
                    try std.testing.expectEqualStrings("pure", marker);
                    found_marker = true;
                }
            }
            try std.testing.expect(found_marker);
        },
        .nested_closers => {
            const outer = try expectSyntaxApplication(&parser.type_store, annotation.root, "Outer", 1);
            const middle = try expectSyntaxApplication(&parser.type_store, outer.arguments[0], "Middle", 1);
            _ = try expectSyntaxApplication(&parser.type_store, middle.arguments[0], "Inner", 1);
            try expectPoolGenericApplication(&pool, lowered, "Outer", 1);
            const outer_pool = pool.getGenericAppInfo(lowered);
            try expectPoolGenericApplication(&pool, outer_pool.args[0], "Middle", 1);
            const middle_pool = pool.getGenericAppInfo(outer_pool.args[0]);
            try expectPoolGenericApplication(&pool, middle_pool.args[0], "Inner", 1);
            try std.testing.expectEqual(pool.idx_string, pool.getGenericAppInfo(middle_pool.args[0]).args[0]);
        },
        .optional_comma => {
            const application = try expectSyntaxApplication(
                &parser.type_store,
                annotation.root,
                "Outer",
                2,
            );
            const first = parser.type_store.node(try syntaxChildIndex(application.arguments[0])) orelse
                return error.TestUnexpectedResult;
            const second = parser.type_store.node(try syntaxChildIndex(application.arguments[1])) orelse
                return error.TestUnexpectedResult;
            try std.testing.expectEqual(TypeSyntax.Primitive.string, first.data.primitive);
            try std.testing.expectEqual(TypeSyntax.Primitive.number, second.data.primitive);
            try expectPoolGenericApplication(&pool, lowered, "Outer", 2);
            const lowered_application = pool.getGenericAppInfo(lowered);
            try std.testing.expectEqualSlices(
                TypeIndex,
                &.{ pool.idx_string, pool.idx_number },
                lowered_application.args,
            );
        },
        .absent_first_argument, .absent_later_argument, .absent_first_before_close, .absent_later_before_close => {
            const retained: usize = switch (case) {
                .absent_first_argument, .absent_first_before_close => 0,
                else => 1,
            };
            _ = try expectSyntaxApplication(&parser.type_store, annotation.root, "Outer", retained);
            try expectPoolGenericApplication(&pool, lowered, "Outer", retained);
            if (retained == 1) {
                try std.testing.expectEqual(pool.idx_string, pool.getGenericAppInfo(lowered).args[0]);
            }
            const expected = switch (case) {
                .absent_first_argument => "Outer<()",
                .absent_later_argument => "Outer<string, ()",
                .absent_first_before_close => "Outer<()>",
                .absent_later_before_close => "Outer<string, ()>",
                else => return error.TestUnexpectedResult,
            };
            try std.testing.expectEqualStrings(
                expected,
                source[annotation.raw_span.start..annotation.semantic_prefix_end],
            );
        },
        .dict_exact_arity => {
            _ = try expectSyntaxApplication(&parser.type_store, annotation.root, "Dict", 2);
            try std.testing.expectEqual(
                TypeTag.t_dict,
                pool.getTag(lowered) orelse return error.TestUnexpectedResult,
            );
            try std.testing.expectEqual(pool.idx_string, pool.getDictKey(lowered));
            try std.testing.expectEqual(pool.idx_number, pool.getDictValue(lowered));
        },
        .dict_wrong_arity => {
            _ = try expectSyntaxApplication(&parser.type_store, annotation.root, "Dict", 1);
            try expectPoolGenericApplication(&pool, lowered, "Dict", 1);
            try std.testing.expectEqual(pool.idx_string, pool.getGenericAppInfo(lowered).args[0]);
        },
        .readonly_record_nested => {
            const root = parser.type_store.node(try syntaxChildIndex(annotation.root)) orelse
                return error.TestUnexpectedResult;
            const fields = parser.type_store.fieldSlice(root.data.record) orelse
                return error.TestUnexpectedResult;
            try std.testing.expectEqual(@as(usize, 1), fields.len);
            const application = try expectSyntaxApplication(
                &parser.type_store,
                fields[0].type_child,
                "Readonly",
                1,
            );
            const argument = parser.type_store.node(try syntaxChildIndex(application.arguments[0])) orelse
                return error.TestUnexpectedResult;
            try std.testing.expectEqual(TypeSyntax.NodeTag.record, argument.tag);
            const lowered_fields = pool.getRecordFields(lowered);
            try std.testing.expectEqual(@as(usize, 1), lowered_fields.len);
            const inner_fields = pool.getRecordFields(lowered_fields[0].type_idx);
            try std.testing.expectEqual(@as(usize, 1), inner_fields.len);
            try std.testing.expect(inner_fields[0].readonly);
        },
        .readonly_tuple_nested => {
            const root = parser.type_store.node(try syntaxChildIndex(annotation.root)) orelse
                return error.TestUnexpectedResult;
            const elements = parser.type_store.memberSlice(root.data.tuple) orelse
                return error.TestUnexpectedResult;
            try std.testing.expectEqual(@as(usize, 1), elements.len);
            const application = try expectSyntaxApplication(
                &parser.type_store,
                elements[0],
                "Readonly",
                1,
            );
            const argument = parser.type_store.node(try syntaxChildIndex(application.arguments[0])) orelse
                return error.TestUnexpectedResult;
            try std.testing.expectEqual(TypeSyntax.NodeTag.record, argument.tag);
            const lowered_elements = pool.getTupleElements(lowered);
            try std.testing.expectEqual(@as(usize, 1), lowered_elements.len);
            const inner_fields = pool.getRecordFields(lowered_elements[0]);
            try std.testing.expectEqual(@as(usize, 1), inner_fields.len);
            try std.testing.expect(inner_fields[0].readonly);
        },
        .ungrouped_array_suffix => {
            _ = try expectSyntaxApplication(&parser.type_store, annotation.root, "Outer", 1);
            try expectPoolGenericApplication(&pool, lowered, "Outer", 1);
            try std.testing.expectEqualStrings("Outer<string>[]", annotation.raw_span.text(source));
            try std.testing.expectEqualStrings(
                "Outer<string>",
                source[annotation.raw_span.start..annotation.semantic_prefix_end],
            );
        },
        .grouped_array_suffix => {
            const array = parser.type_store.node(try syntaxChildIndex(annotation.root)) orelse
                return error.TestUnexpectedResult;
            try std.testing.expectEqual(TypeSyntax.NodeTag.array, array.tag);
            const group = parser.type_store.node(try syntaxChildIndex(array.data.array)) orelse
                return error.TestUnexpectedResult;
            try std.testing.expectEqual(TypeSyntax.NodeTag.group, group.tag);
            _ = try expectSyntaxApplication(&parser.type_store, group.data.group.child, "Outer", 1);
            try std.testing.expectEqual(
                TypeTag.t_array,
                pool.getTag(lowered) orelse return error.TestUnexpectedResult,
            );
            try expectPoolGenericApplication(&pool, pool.getArrayElement(lowered), "Outer", 1);
            try std.testing.expectEqual(annotation.raw_span.end, annotation.semantic_prefix_end);
        },
    }
}

fn assertGenericAliasSemanticProperty(case: GenericAliasCase, source: []const u8) !void {
    var parser = try JsParser.initTyped(std.testing.allocator, std.testing.allocator, source);
    defer parser.deinit();
    _ = try parser.parse();
    try parser.type_store.validate();

    var pool = TypePool.init(std.testing.allocator);
    defer pool.deinit(std.testing.allocator);
    var env = TypeEnv.init(std.testing.allocator, &pool);
    defer env.deinit();
    try lowerSyntaxStore(std.testing.allocator, &parser.type_store, &pool, &env, parserIrView(&parser));
    try pool.ensureHealthy();
    try env.ensureHealthy();

    const value_type = if (parser.type_store.annotations.items.len == 0)
        null
    else blk: {
        const annotation = parser.type_store.annotations.items[0];
        break :blk env.getVarTypeByBinding(annotation.binding.scope_id, annotation.binding.name_atom);
    };
    switch (case) {
        .complete_record, .spaced_list, .ignored_constraint, .ignored_default => {
            const owner = parser.type_store.generic_owners.items[0];
            const authored = parser.type_store.genericParameterSlice(owner.authored_parameters) orelse
                return error.TestUnexpectedResult;
            const projected = parser.type_store.projectedGenericParameterSlice(owner.projected_parameters) orelse
                return error.TestUnexpectedResult;
            try std.testing.expectEqual(@as(usize, 1), authored.len);
            try std.testing.expectEqual(@as(usize, 1), projected.len);
            try std.testing.expectEqualStrings("T", projected[0].name_span.text(source));
            try std.testing.expectEqual(@as(usize, 0), parser.type_store.semantic_fragments.items.len);
            if (case == .complete_record) {
                const recognized = authored[0].recognized orelse return error.TestUnexpectedResult;
                try std.testing.expect(recognized.extends_span != null);
                try std.testing.expect(recognized.constraint_span != null);
                try std.testing.expect(recognized.equals_span != null);
                try std.testing.expect(recognized.default_span != null);
                try std.testing.expectEqualStrings(
                    "string = boolean",
                    (projected[0].legacy_bound_span orelse return error.TestUnexpectedResult).text(source),
                );
            }
            const fields = pool.getRecordFields(value_type orelse return error.TestUnexpectedResult);
            try std.testing.expectEqual(@as(usize, 1), fields.len);
            try std.testing.expectEqual(pool.idx_number, fields[0].type_idx);
        },
        .empty_list => {
            const owner = parser.type_store.generic_owners.items[0];
            try std.testing.expectEqual(@as(u32, 0), owner.authored_parameters.count);
            try std.testing.expectEqual(@as(u32, 0), owner.projected_parameters.count);
            const alias = env.generic_aliases.get("Box") orelse return error.TestUnexpectedResult;
            try std.testing.expectEqual(@as(u8, 0), alias.param_count);
            try std.testing.expectEqual(pool.idx_number, value_type orelse return error.TestUnexpectedResult);
        },
        .present_null_body => {
            const alias = env.generic_aliases.get("Empty") orelse return error.TestUnexpectedResult;
            try std.testing.expectEqual(null_type_idx, alias.body);
        },
        .absent_body => try std.testing.expect(env.generic_aliases.get("Empty") == null),
        .eight_item_projection => {
            const alias = env.generic_aliases.get("Wide") orelse return error.TestUnexpectedResult;
            try std.testing.expectEqual(@as(u8, 8), alias.param_count);
            try std.testing.expectEqualStrings("H", alias.param_names[7]);
            try std.testing.expectEqual(pool.idx_number, value_type orelse return error.TestUnexpectedResult);
        },
        .ninth_item_unprojected => {
            const alias = env.generic_aliases.get("Many") orelse return error.TestUnexpectedResult;
            try std.testing.expectEqual(@as(u8, 8), alias.param_count);
            try expectRefName(&pool, alias.body, "I");
        },
        .generic_then_plain, .plain_then_generic => {
            try std.testing.expectEqual(pool.idx_number, env.getTypeAlias("Both") orelse return error.TestUnexpectedResult);
            const alias = env.generic_aliases.get("Both") orelse return error.TestUnexpectedResult;
            try std.testing.expectEqual(@as(u8, 1), alias.param_count);
        },
        .ambient_replacement => {
            const alias = env.generic_aliases.get("Proof") orelse return error.TestUnexpectedResult;
            try std.testing.expectEqual(@as(u8, 1), alias.param_count);
            const fields = pool.getRecordFields(value_type orelse return error.TestUnexpectedResult);
            try std.testing.expectEqualStrings("value", pool.getName(fields[0].name_start, fields[0].name_len));
            try std.testing.expectEqual(pool.idx_number, fields[0].type_idx);
        },
        .alias_before_parameter => {
            const alias = env.generic_aliases.get("Box") orelse return error.TestUnexpectedResult;
            try std.testing.expectEqual(pool.idx_number, alias.body);
            try std.testing.expectEqual(pool.idx_number, value_type orelse return error.TestUnexpectedResult);
        },
        .duplicate_parameter => {
            const alias = env.generic_aliases.get("Box") orelse return error.TestUnexpectedResult;
            try std.testing.expectEqual(@as(u8, 2), alias.param_count);
            try std.testing.expectEqual(pool.idx_string, value_type orelse return error.TestUnexpectedResult);
        },
        .nested_substitution => {
            const fields = pool.getRecordFields(value_type orelse return error.TestUnexpectedResult);
            try std.testing.expectEqual(TypeTag.t_array, pool.getTag(fields[0].type_idx).?);
            try std.testing.expectEqual(pool.idx_number, pool.getArrayElement(fields[0].type_idx));
        },
        .nested_application_projection => {
            const fields = pool.getRecordFields(value_type orelse return error.TestUnexpectedResult);
            try std.testing.expectEqual(pool.idx_number, fields[0].type_idx);
        },
        .default_comparison => {
            const owner = parser.type_store.generic_owners.items[0];
            try std.testing.expectEqualStrings(
                "<T = (left > right)>",
                owner.list_span.text(source),
            );
            try std.testing.expectEqual(pool.idx_number, value_type orelse return error.TestUnexpectedResult);
        },
        .constraint_closer => {
            const owner = parser.type_store.generic_owners.items[0];
            try std.testing.expectEqualStrings(
                "<T extends { value: Missing > }>",
                owner.list_span.text(source),
            );
            try std.testing.expectEqual(pool.idx_number, value_type orelse return error.TestUnexpectedResult);
        },
        .default_less_than, .constraint_less_than, .wrapped_constraint_less_than => {
            const owner = parser.type_store.generic_owners.items[0];
            const authored = parser.type_store.genericParameterSlice(owner.authored_parameters) orelse
                return error.TestUnexpectedResult;
            try std.testing.expectEqual(@as(usize, 1), authored.len);
            try std.testing.expectEqual(@as(u32, 0), owner.projected_parameters.count);
            const recognized = authored[0].recognized orelse return error.TestUnexpectedResult;
            switch (case) {
                .default_less_than => try std.testing.expectEqualStrings(
                    "(left < right)",
                    (recognized.default_span orelse return error.TestUnexpectedResult).text(source),
                ),
                .constraint_less_than => try std.testing.expectEqualStrings(
                    "{ value: Missing < }",
                    (recognized.constraint_span orelse return error.TestUnexpectedResult).text(source),
                ),
                .wrapped_constraint_less_than => try std.testing.expectEqualStrings(
                    "Wrap<{ value: Missing < }, string>",
                    (recognized.constraint_span orelse return error.TestUnexpectedResult).text(source),
                ),
                else => unreachable,
            }
            if (case != .default_less_than) {
                try std.testing.expectEqualStrings(
                    "boolean",
                    (recognized.default_span orelse return error.TestUnexpectedResult).text(source),
                );
            }
            try std.testing.expectEqual(pool.idx_number, value_type orelse return error.TestUnexpectedResult);
        },
        .nested_arrow_default => {
            const owner = parser.type_store.generic_owners.items[0];
            try std.testing.expectEqual(@as(u32, 1), owner.authored_parameters.count);
            try std.testing.expectEqual(@as(u32, 2), owner.projected_parameters.count);
            try std.testing.expectEqual(pool.idx_number, value_type orelse return error.TestUnexpectedResult);
        },
        .quoted_equals => {
            const owner = parser.type_store.generic_owners.items[0];
            const authored = parser.type_store.genericParameterSlice(owner.authored_parameters) orelse
                return error.TestUnexpectedResult;
            const recognized = authored[0].recognized orelse return error.TestUnexpectedResult;
            try std.testing.expectEqualStrings(
                "\"a=b\"",
                (recognized.constraint_span orelse return error.TestUnexpectedResult).text(source),
            );
            try std.testing.expectEqualStrings(
                "boolean",
                (recognized.default_span orelse return error.TestUnexpectedResult).text(source),
            );
            try std.testing.expectEqual(pool.idx_number, value_type orelse return error.TestUnexpectedResult);
        },
        .adjacent_alias_equals => {
            const alias = env.generic_aliases.get("Box") orelse return error.TestUnexpectedResult;
            try std.testing.expectEqual(TypeTag.t_generic_param, pool.getTag(alias.body).?);
            try std.testing.expectEqual(pool.idx_number, value_type orelse return error.TestUnexpectedResult);
        },
        .adjacent_annotation_equals => {
            const annotation = parser.type_store.annotations.items[0];
            try std.testing.expectEqualStrings("Box<number>", annotation.raw_span.text(source));
            try std.testing.expectEqual(pool.idx_number, value_type orelse return error.TestUnexpectedResult);
        },
    }
}

fn assertGenericProjectionProperty(case: GenericProjectionCase, source: []const u8) !void {
    var parser = try JsParser.initTyped(std.testing.allocator, std.testing.allocator, source);
    defer parser.deinit();
    _ = try parser.parse();
    try parser.type_store.validate();
    const owner = parser.type_store.generic_owners.items[0];
    const authored = parser.type_store.genericParameterSlice(owner.authored_parameters) orelse
        return error.TestUnexpectedResult;
    const projected = parser.type_store.projectedGenericParameterSlice(owner.projected_parameters) orelse
        return error.TestUnexpectedResult;
    switch (case) {
        .blank_piece_before_limit => {
            try std.testing.expectEqual(@as(usize, 8), projected.len);
            try std.testing.expectEqualStrings("H", projected[7].name_span.text(source));
        },
        .nonempty_empty_name => {
            try std.testing.expectEqual(@as(usize, 2), authored.len);
            try std.testing.expectEqual(@as(usize, 2), projected.len);
            try std.testing.expectEqualStrings("=string", projected[0].raw_span.text(source));
            try std.testing.expectEqualStrings("", projected[0].name_span.text(source));
            try std.testing.expectEqualStrings("T", projected[1].name_span.text(source));
        },
        .quoted_comma => {
            try std.testing.expectEqual(@as(usize, 1), authored.len);
            try std.testing.expectEqual(@as(usize, 2), projected.len);
        },
        .comment_comma => {
            try std.testing.expectEqual(@as(usize, 1), authored.len);
            try std.testing.expectEqual(@as(usize, 2), projected.len);
            try std.testing.expectEqualStrings("*/", projected[1].name_span.text(source));
        },
        .authored_empty_piece => {
            try std.testing.expectEqual(@as(usize, 3), authored.len);
            try std.testing.expectEqualStrings("", authored[1].trimmed_span.text(source));
            try std.testing.expectEqual(@as(usize, 2), projected.len);
        },
        .malformed_tail => {
            try std.testing.expectEqual(@as(usize, 1), authored.len);
            try std.testing.expect(authored[0].recognized == null);
            try std.testing.expectEqualStrings("T", projected[0].name_span.text(source));
        },
        .nested_arrow_default => {
            try std.testing.expectEqual(@as(usize, 1), authored.len);
            try std.testing.expectEqual(@as(usize, 2), projected.len);
            try std.testing.expectEqualStrings("T", projected[0].name_span.text(source));
            try std.testing.expectEqualStrings("string>", projected[1].name_span.text(source));
            const recognized = authored[0].recognized orelse return error.TestUnexpectedResult;
            try std.testing.expectEqualStrings(
                "Wrap<(x:string)=>number,string>",
                (recognized.default_span orelse return error.TestUnexpectedResult).text(source),
            );
        },
        .quoted_equals_metadata => {
            try std.testing.expectEqual(@as(usize, 1), authored.len);
            const recognized = authored[0].recognized orelse return error.TestUnexpectedResult;
            try std.testing.expectEqualStrings(
                "\"a=b\"",
                (recognized.constraint_span orelse return error.TestUnexpectedResult).text(source),
            );
            try std.testing.expectEqualStrings(
                "boolean",
                (recognized.default_span orelse return error.TestUnexpectedResult).text(source),
            );
        },
        .arrow_constraint_metadata => {
            const recognized = authored[0].recognized orelse return error.TestUnexpectedResult;
            try std.testing.expectEqualStrings(
                "(x:string)=>number",
                (recognized.constraint_span orelse return error.TestUnexpectedResult).text(source),
            );
            try std.testing.expectEqualStrings(
                "boolean",
                (recognized.default_span orelse return error.TestUnexpectedResult).text(source),
            );
        },
        .commented_equals_metadata => {
            const recognized = authored[0].recognized orelse return error.TestUnexpectedResult;
            try std.testing.expectEqualStrings(
                "Wrap<string /* = */>",
                (recognized.constraint_span orelse return error.TestUnexpectedResult).text(source),
            );
            try std.testing.expectEqualStrings(
                "boolean",
                (recognized.default_span orelse return error.TestUnexpectedResult).text(source),
            );
        },
    }
}

fn assertGenericFragmentProperty(case: GenericFragmentCase, source: []const u8) !void {
    const owned_source = try std.fmt.allocPrint(std.testing.allocator, "<{s}>(", .{source});
    defer std.testing.allocator.free(owned_source);
    var store = TypeSyntax.Store.init(std.testing.allocator, owned_source);
    defer store.deinit();
    var nodes = engine.parser.IRStore.init(std.testing.allocator);
    defer nodes.deinit();
    var constants = engine.parser.ConstantPool.init(std.testing.allocator);
    defer constants.deinit();
    const lparen: u32 = @intCast(source.len + 2);
    const call = try nodes.add(.{
        .tag = .call,
        .loc = .{ .line = 1, .column = lparen + 1, .offset = lparen, .end_offset = lparen + 1 },
        .data = .{ .call = .{
            .callee = engine.parser.null_node,
            .args_start = engine.parser.null_node,
            .args_count = 0,
        } },
    });
    const view = engine.parser.IrView.fromIRStore(&nodes, &constants);
    var pending = try store.reserveExplicitCall(.{
        .list_span = .{ .start = 0, .end = lparen },
        .capture_spans = .{
            .actual_erased_span = .{ .start = 0, .end = lparen },
            .legacy_recorded_span = .{ .start = 1, .end = lparen - 1 },
        },
    });
    const fragment_index = pending.final_record.semantic_fragments.start;
    try store.finishExplicitCall(&pending, call, view);
    try store.validateRuntimeOwners(std.testing.allocator, view);
    var application_bases = try store.planApplicationBasesWithIr(std.testing.allocator, view);
    defer application_bases.deinit();

    var pool = TypePool.init(std.testing.allocator);
    defer pool.deinit(std.testing.allocator);
    var env = TypeEnv.init(std.testing.allocator, &pool);
    defer env.deinit();
    env.putTypeAlias("DictKey", pool.idx_boolean);
    var owner = try env.beginParsedGenerics(&.{.{ .name = "T" }});
    const lowered = try lowerGenericSemanticFragment(
        std.testing.allocator,
        &store,
        &pool,
        &env,
        &owner,
        &application_bases,
        fragment_index,
        true,
    );
    try env.endParsedGenerics(&owner);
    const fragment = store.semantic_fragments.items[fragment_index];
    switch (case) {
        .exact_dict_key => try std.testing.expectEqual(TypeTag.t_union, pool.getTag(lowered).?),
        .default_suffixed_dict_key => try expectRefName(&pool, lowered, "DictKey"),
        .numeric_prefix => {
            try std.testing.expectEqualStrings(
                "1",
                owned_source[fragment.raw_span.start..fragment.semantic_prefix_end],
            );
            try std.testing.expectEqual(TypeTag.t_literal_number, pool.getTag(lowered).?);
        },
        .leading_union => try std.testing.expectEqual(pool.idx_number, lowered),
        .leading_intersection => try std.testing.expectEqual(pool.idx_number, lowered),
        .any_name => try expectRefName(&pool, lowered, "any"),
        .partial_string => {
            try std.testing.expectEqual(fragment.raw_span.end, fragment.semantic_prefix_end);
            try std.testing.expectEqual(TypeTag.t_literal_string, pool.getTag(lowered).?);
        },
        .nested_application => try expectPoolGenericApplication(&pool, lowered, "Outer", 1),
    }
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
    try lowerSyntaxStore(std.testing.allocator, &parser.type_store, &pool, &env, parserIrView(&parser));
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
        .generic_declaration => {
            const alias = env.generic_aliases.get("Box") orelse return error.TestUnexpectedResult;
            try std.testing.expectEqual(@as(u8, 1), alias.param_count);
            try std.testing.expectEqualStrings("T", alias.param_names[0]);
            try std.testing.expectEqual(TypeTag.t_generic_param, pool.getTag(alias.body).?);
        },
        .root_leading_space_refusal,
        .after_newline_refusal,
        .after_semicolon_refusal,
        .block_left_aligned,
        .block_indented_refusal,
        .runtime_structural_collision,
        .runtime_nominal_collision,
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

test "generic application semantic census observes every case" {
    try std.testing.expectEqual(std.meta.fields(ApplicationCase).len, application_fixtures.len);
    var seen = std.EnumSet(ApplicationCase).initEmpty();
    for (application_fixtures) |fixture| {
        try std.testing.expect(fixture.source.len > 0);
        try std.testing.expect(!seen.contains(fixture.case));
        try assertApplicationSemanticProperty(fixture.case, fixture.source);
        try expectEquivalent(fixture.source);
        seen.insert(fixture.case);
    }
    try std.testing.expectEqual(std.meta.fields(ApplicationCase).len, seen.count());
}

test "structural generic alias census observes every case" {
    try std.testing.expectEqual(std.meta.fields(GenericAliasCase).len, generic_alias_fixtures.len);
    var seen = std.EnumSet(GenericAliasCase).initEmpty();
    for (generic_alias_fixtures) |fixture| {
        errdefer std.debug.print(
            "structural generic alias case failed: {s}\n{s}\n",
            .{ @tagName(fixture.case), fixture.source },
        );
        try std.testing.expect(!seen.contains(fixture.case));
        try assertGenericAliasSemanticProperty(fixture.case, fixture.source);
        try expectEquivalent(fixture.source);
        seen.insert(fixture.case);
    }
    try std.testing.expectEqual(std.meta.fields(GenericAliasCase).len, seen.count());
}

test "generic parameter projection census observes every case" {
    try std.testing.expectEqual(std.meta.fields(GenericProjectionCase).len, generic_projection_fixtures.len);
    var seen = std.EnumSet(GenericProjectionCase).initEmpty();
    for (generic_projection_fixtures) |fixture| {
        errdefer std.debug.print(
            "generic parameter projection case failed: {s}\n{s}\n",
            .{ @tagName(fixture.case), fixture.source },
        );
        try std.testing.expect(!seen.contains(fixture.case));
        try assertGenericProjectionProperty(fixture.case, fixture.source);
        try expectEquivalent(fixture.source);
        seen.insert(fixture.case);
    }
    try std.testing.expectEqual(std.meta.fields(GenericProjectionCase).len, seen.count());
}

test "untyped generic function declaration retains its owner before runtime equivalence" {
    const source = "const seed: number = 1; function identity<T>(value) { return value; }";
    var parser = try JsParser.initTyped(std.testing.allocator, std.testing.allocator, source);
    defer parser.deinit();
    _ = try parser.parse();
    try parser.type_store.validate();

    try std.testing.expectEqual(@as(usize, 1), parser.type_store.annotations.items.len);
    try std.testing.expectEqual(@as(usize, 1), parser.type_store.generic_owners.items.len);
    try std.testing.expectEqual(@as(usize, 0), parser.type_store.semantic_fragments.items.len);
    const owner = parser.type_store.generic_owners.items[0];
    const view = parserIrView(&parser);
    const expected_paren = std.mem.indexOf(u8, source, "(value)") orelse
        return error.TestUnexpectedResult;
    switch (owner.identity) {
        .function => |node| {
            try std.testing.expectEqual(engine.parser.NodeTag.function_expr, view.getTag(node).?);
            try std.testing.expectEqual(@as(u32, @intCast(expected_paren)), view.getLoc(node).?.offset);
        },
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expectEqualStrings("<T>", owner.list_span.text(source));
    const authored = parser.type_store.genericParameterSlice(owner.authored_parameters) orelse
        return error.TestUnexpectedResult;
    const projected = parser.type_store.projectedGenericParameterSlice(owner.projected_parameters) orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 1), authored.len);
    try std.testing.expectEqual(@as(usize, 1), projected.len);
    try std.testing.expectEqualStrings("T", authored[0].trimmed_span.text(source));
    try std.testing.expectEqualStrings("T", projected[0].name_span.text(source));
    try std.testing.expect(projected[0].bound_fragment == null);

    var pool = TypePool.init(std.testing.allocator);
    defer pool.deinit(std.testing.allocator);
    var env = TypeEnv.init(std.testing.allocator, &pool);
    defer env.deinit();
    const prior_nodes = pool.nodes.items.len;
    const prior_signatures = env.fn_signatures.count();
    try lowerSyntaxStore(std.testing.allocator, &parser.type_store, &pool, &env, parserIrView(&parser));
    try std.testing.expectEqual(prior_nodes + 1, pool.nodes.items.len);
    try std.testing.expectEqual(TypeTag.t_generic_param, pool.getTag(@intCast(prior_nodes)).?);
    try std.testing.expectEqualStrings("T", pool.getRefName(@intCast(prior_nodes)));
    try std.testing.expectEqual(@as(usize, 0), env.generic_scopes.items.len);
    try std.testing.expectEqual(prior_signatures, env.fn_signatures.count());
    const annotation = parser.type_store.annotations.items[0];
    try std.testing.expectEqual(
        pool.idx_number,
        env.getVarTypeByBinding(annotation.binding.scope_id, annotation.binding.name_atom) orelse
            return error.TestUnexpectedResult,
    );

    try expectEquivalent(source);
}

test "generic-only function and explicit call use final runtime owners" {
    const source =
        "function identity<T>(value) { return value; }\n" ++
        "const result: string = identity<string>(\"ok\");\n";
    var atoms = AtomTable.init(std.testing.allocator);
    defer atoms.deinit();
    var parser = try JsParser.initTyped(std.testing.allocator, std.testing.allocator, source);
    defer parser.deinit();
    parser.setAtomTable(&atoms);
    const root = try parser.parse();
    var prepared = try PreparedSource.init(std.testing.allocator, source, "<function-call-slice>.ts", .{});
    defer prepared.deinit();
    try expectFunctionSliceRuntimeParityPrepared(
        std.testing.allocator,
        &prepared,
        &parser,
        root,
        &atoms,
    );

    try parser.type_store.validate();
    const view = parserIrView(&parser);
    try parser.type_store.validateRuntimeOwners(std.testing.allocator, view);
    try std.testing.expectEqual(@as(usize, 1), parser.type_store.generic_owners.items.len);
    try std.testing.expectEqual(@as(usize, 1), parser.type_store.explicit_call_arguments.items.len);
    try std.testing.expectEqual(@as(usize, 1), parser.type_store.annotations.items.len);
    try std.testing.expectEqual(@as(usize, 0), parser.type_store.function_signatures.items.len);

    const generic_owner = parser.type_store.generic_owners.items[0];
    const function_owner = switch (generic_owner.identity) {
        .function => |node| node,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(engine.parser.NodeTag.function_expr, view.getTag(function_owner).?);
    var wrapper: ?NodeIndex = null;
    var result_declaration: ?NodeIndex = null;
    for (parser.nodes.tags.items, 0..) |tag, index| switch (tag) {
        .function_decl => wrapper = @intCast(index),
        .var_decl => result_declaration = @intCast(index),
        else => {},
    };
    const function_wrapper = wrapper orelse return error.TestUnexpectedResult;
    const wrapper_data = view.getVarDecl(function_wrapper) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(function_owner, wrapper_data.init);
    try parser.type_store.validateFunctionDeclarationWrapper(
        function_owner,
        function_wrapper,
        view,
    );

    const syntax_call = parser.type_store.explicit_call_arguments.items[0];
    try std.testing.expectEqual(engine.parser.NodeTag.call, view.getTag(syntax_call.owner).?);
    try std.testing.expectEqual(
        syntax_call.list_span.end,
        view.getLoc(syntax_call.owner).?.offset,
    );
    const result = view.getVarDecl(result_declaration orelse return error.TestUnexpectedResult) orelse
        return error.TestUnexpectedResult;
    try std.testing.expect(std.meta.eql(
        result.binding,
        parser.type_store.annotations.items[0].binding,
    ));
    try std.testing.expect(try compareLowering(std.testing.allocator, &prepared, &parser));

    var pool = TypePool.init(std.testing.allocator);
    defer pool.deinit(std.testing.allocator);
    var env = TypeEnv.init(std.testing.allocator, &pool);
    defer env.deinit();
    const prior_nodes = pool.nodes.items.len;
    try lowerSyntaxStore(
        std.testing.allocator,
        &parser.type_store,
        &pool,
        &env,
        view,
    );
    try std.testing.expectEqual(TypeTag.t_generic_param, pool.getTag(@intCast(prior_nodes)).?);
    try std.testing.expectEqualStrings("T", pool.getRefName(@intCast(prior_nodes)));
    const call_arguments = env.getCallTypeArgs(syntax_call.list_span.end) orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u8, 1), call_arguments.count);
    try std.testing.expectEqual(pool.idx_string, call_arguments.args[0]);
    try std.testing.expectEqual(
        pool.idx_string,
        env.getVarTypeByBinding(result.binding.scope_id, result.binding.name_atom) orelse
            return error.TestUnexpectedResult,
    );
}

const NamedFunctionCommentCase = enum {
    before_block,
    before_line,
    after_block,
    after_line,
};

fn namedFunctionCommentSource(case: NamedFunctionCommentCase) []const u8 {
    return switch (case) {
        .before_block => "function /* arbitrary // <text> */ identity<T>(value) { return value; }",
        .before_line => "function // arbitrary /* text */\nidentity<T>(value) { return value; }",
        .after_block => "function identity<T>/* arbitrary // <text> */(value) { return value; }",
        .after_line => "function identity<T>// arbitrary /* text */\n(value) { return value; }",
    };
}

fn expectNamedFunctionCommentCompatibility(case: NamedFunctionCommentCase) !void {
    const source = namedFunctionCommentSource(case);
    var runtime_count = CountingAllocator.init(std.testing.allocator);
    var type_count = CountingAllocator.init(std.testing.allocator);
    const runtime_allocator = runtime_count.allocator();
    var atoms = AtomTable.init(runtime_allocator);
    defer atoms.deinit();
    var parser = try JsParser.initTyped(runtime_allocator, type_count.allocator(), source);
    defer parser.deinit();
    parser.setAtomTable(&atoms);
    const root = try parser.parse();

    try expectRuntimeParityAndShape(source, &parser, root, &atoms, runtime_count);

    const store = &parser.type_store;
    const view = parserIrView(&parser);
    try store.validateRuntimeOwners(std.testing.allocator, view);
    try std.testing.expectEqual(@as(usize, 1), store.generic_owners.items.len);
    try std.testing.expectEqual(@as(usize, 1), store.generic_parameters.items.len);
    try std.testing.expectEqual(@as(usize, 1), store.projected_generic_parameters.items.len);
    try std.testing.expectEqual(@as(usize, 0), store.function_signatures.items.len);
    const owner = store.generic_owners.items[0];
    try std.testing.expectEqualStrings("<T>", owner.list_span.text(source));
    try std.testing.expectEqualStrings("<T>", owner.capture_spans.actual_erased_span.text(source));
    const projected = store.projectedGenericParameterSlice(owner.projected_parameters) orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 1), projected.len);
    try std.testing.expectEqualStrings("T", projected[0].name_span.text(source));

    const function_owner = switch (owner.identity) {
        .function => |node| node,
        else => return error.TestUnexpectedResult,
    };
    const opener: u32 = @intCast(std.mem.indexOf(u8, source, "(value)") orelse
        return error.TestUnexpectedResult);
    try std.testing.expectEqual(engine.parser.NodeTag.function_expr, view.getTag(function_owner).?);
    try std.testing.expectEqual(opener, view.getLoc(function_owner).?.offset);
    var wrapper: ?NodeIndex = null;
    for (parser.nodes.tags.items, 0..) |tag, index| {
        if (tag != .function_decl) continue;
        if (wrapper != null) return error.TestUnexpectedResult;
        wrapper = @intCast(index);
    }
    const declaration = wrapper orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(
        function_owner,
        (view.getVarDecl(declaration) orelse return error.TestUnexpectedResult).init,
    );
    try store.validateFunctionDeclarationWrapper(function_owner, declaration, view);

    switch (case) {
        .before_block, .before_line => {
            try std.testing.expectEqualStrings(
                "T",
                owner.capture_spans.legacy_recorded_span.text(source),
            );
            const ranges = switch (owner.compatibility) {
                .legacy_call_arguments => |ranges| ranges,
                else => return error.TestUnexpectedResult,
            };
            const authored = store.authoredCallArgumentSlice(ranges.authored_arguments) orelse
                return error.TestUnexpectedResult;
            const fragments = store.semanticFragmentSlice(ranges.semantic_fragments) orelse
                return error.TestUnexpectedResult;
            try std.testing.expectEqual(@as(usize, 1), authored.len);
            try std.testing.expectEqual(@as(usize, 1), fragments.len);
            try std.testing.expectEqualStrings("T", authored[0].full_span.text(source));
            try std.testing.expectEqualStrings("T", fragments[0].raw_span.text(source));
        },
        .after_block, .after_line => {
            try std.testing.expectEqualStrings(
                "T",
                owner.capture_spans.legacy_recorded_span.text(source),
            );
            switch (owner.compatibility) {
                .ignored_declaration_parameters => {},
                else => return error.TestUnexpectedResult,
            }
            try std.testing.expectEqual(@as(usize, 0), store.authored_call_arguments.items.len);
            try std.testing.expectEqual(@as(usize, 0), store.semantic_fragments.items.len);
        },
    }
    var prepared = try PreparedSource.init(std.testing.allocator, source, "<named-capture-provenance>.ts", .{});
    defer prepared.deinit();
    const legacy_map = prepared.typeMap() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 1), legacy_map.entries.items.len);
    const legacy_entry = legacy_map.entries.items[0];
    try std.testing.expectEqual(owner.capture_spans.legacy_recorded_span.start, legacy_entry.source_start);
    try std.testing.expectEqual(owner.capture_spans.legacy_recorded_span.end, legacy_entry.source_end);
    try std.testing.expectEqualStrings("T", legacy_map.getTypeText(legacy_entry));
    switch (case) {
        .before_block, .before_line => try std.testing.expectEqual(.call_type_arguments, legacy_entry.kind),
        .after_block, .after_line => {
            try std.testing.expectEqual(.generic_params, legacy_entry.kind);
            try std.testing.expect(legacy_entry.signature_offset == null);
        },
    }
}

test "untyped named function comment gaps retain final compatibility owners" {
    const cases = [_]NamedFunctionCommentCase{
        .before_block,
        .before_line,
        .after_block,
        .after_line,
    };
    for (cases) |case| try expectNamedFunctionCommentCompatibility(case);
    try std.testing.expectEqual(@as(usize, 4), cases.len);
}

fn expectNamedFunctionRawRefusalParity(
    source: []const u8,
    refusal_offset: u32,
    expected_token: []const u8,
) !void {
    var prepared = try PreparedSource.init(
        std.testing.allocator,
        source,
        "<named-function-comment>.ts",
        .{},
    );
    defer prepared.deinit();
    try std.testing.expectEqual(@as(usize, 0), prepared.stripDiagnostics().len);

    var legacy_atoms = AtomTable.init(std.testing.allocator);
    defer legacy_atoms.deinit();
    var legacy = try JsParser.init(std.testing.allocator, prepared.parserInput());
    defer legacy.deinit();
    legacy.setAtomTable(&legacy_atoms);
    try std.testing.expectError(error.UnexpectedToken, legacy.parse());

    var direct_atoms = AtomTable.init(std.testing.allocator);
    defer direct_atoms.deinit();
    var direct = try JsParser.initTyped(
        std.testing.allocator,
        std.testing.allocator,
        source,
    );
    defer direct.deinit();
    direct.setAtomTable(&direct_atoms);
    try std.testing.expectError(error.UnexpectedToken, direct.parse());

    try std.testing.expect(sameParseErrors(&legacy, &direct));
    try std.testing.expectEqual(refusal_offset, legacy.current.start);
    try std.testing.expectEqual(refusal_offset, direct.current.start);
    const errors = direct.errors.getErrors();
    try std.testing.expectEqual(@as(usize, 1), errors.len);
    try std.testing.expectEqual(engine.parser.ErrorKind.expected_token, errors[0].kind);
    try std.testing.expectEqualStrings("unexpected token", errors[0].message);
    try std.testing.expectEqualStrings(
        expected_token,
        errors[0].expected orelse return error.TestUnexpectedResult,
    );
    const position = positionOf(source, refusal_offset);
    try std.testing.expectEqual(refusal_offset, errors[0].location.offset);
    try std.testing.expectEqual(position.line, errors[0].location.line);
    try std.testing.expectEqual(position.column, errors[0].location.column);
    try std.testing.expectEqual(@as(u16, 0), direct.scopes.current_scope);
    try expectStoreCheckpoint(
        &direct.type_store,
        std.mem.zeroes(TypeSyntax.Store.Checkpoint),
    );
    try direct.type_store.validate();
}

test "typed named function comment gaps retain raw refusal locations" {
    const sources = [_][]const u8{
        "function /* gap */ identity<T>(value: T): T { return value; }",
        "function // gap\nidentity<T>(value: T): T { return value; }",
        "function identity<T>/* gap */(value: T): T { return value; }",
        "function identity<T>// gap\n(value: T): T { return value; }",
    };
    for (sources) |source| {
        const colon: u32 = @intCast(std.mem.indexOf(u8, source, ": T") orelse
            return error.TestUnexpectedResult);
        try expectNamedFunctionRawRefusalParity(source, colon, "')'");
    }
    try std.testing.expectEqual(@as(usize, 4), sources.len);
}

test "two named function comment gaps retain the raw generic refusal" {
    const source =
        "function /* before */ identity<T>/* after */(value) { return value; }";
    const list_start: u32 = @intCast(std.mem.indexOfScalar(u8, source, '<') orelse
        return error.TestUnexpectedResult);
    try expectNamedFunctionRawRefusalParity(source, list_start, "'('");
}

test "named function comments retain rejected call grammar" {
    const sources = [_][]const u8{
        "function /* gap */ identity<T = string>(value) { return value; }",
        "function /* gap */ identity<T || U>(value) { return value; }",
        "function /* gap */ identity<T + U>(value) { return value; }",
    };
    for (sources) |source| {
        const list_start: u32 = @intCast(std.mem.indexOfScalar(u8, source, '<') orelse
            return error.TestUnexpectedResult);
        try expectNamedFunctionRawRefusalParity(source, list_start, "'('");
    }
    try std.testing.expectEqual(@as(usize, 3), sources.len);
}

test "generic owner validation rejects exchanged function nodes" {
    const source =
        "function left<T>(value) { return value; }\n" ++
        "function right<U>(value) { return value; }\n";
    var parser = try JsParser.initTyped(std.testing.allocator, std.testing.allocator, source);
    defer parser.deinit();
    _ = try parser.parse();
    const view = parserIrView(&parser);
    try parser.type_store.validateRuntimeOwners(std.testing.allocator, view);
    const owners = parser.type_store.generic_owners.items;
    try std.testing.expectEqual(@as(usize, 2), owners.len);
    const left = owners[0].identity;
    const right = owners[1].identity;
    owners[0].identity = right;
    owners[1].identity = left;
    try std.testing.expectError(
        error.InvalidGenericOwner,
        parser.type_store.validateRuntimeOwners(std.testing.allocator, view),
    );
    owners[0].identity = left;
    owners[1].identity = right;
    try parser.type_store.validateRuntimeOwners(std.testing.allocator, view);

    const original_capture = owners[0].capture_spans.actual_erased_span;
    const right_node = switch (right) {
        .function => |runtime_node| runtime_node,
        else => return error.TestUnexpectedResult,
    };
    owners[0].capture_spans.actual_erased_span.end =
        (view.getLoc(right_node) orelse return error.TestUnexpectedResult).offset;
    owners[0].identity = right;
    try std.testing.expectError(
        error.InvalidGenericOwner,
        parser.type_store.validateRuntimeOwners(std.testing.allocator, view),
    );
    owners[0].capture_spans.actual_erased_span = original_capture;
    owners[0].identity = left;
    try parser.type_store.validateRuntimeOwners(std.testing.allocator, view);
}

test "ignored and legacy-call policies retain syntax without generic declaration lowering" {
    {
        const source = "nominal UserId<T> = string;";
        const name_start: u32 = @intCast(std.mem.indexOf(u8, source, "UserId") orelse
            return error.TestUnexpectedResult);
        const list_start: u32 = @intCast(std.mem.indexOfScalar(u8, source, '<') orelse
            return error.TestUnexpectedResult);
        const list_end: u32 = @intCast((std.mem.indexOfScalar(u8, source, '>') orelse
            return error.TestUnexpectedResult) + 1);
        const equals_start: u32 = @intCast(std.mem.indexOfScalar(u8, source, '=') orelse
            return error.TestUnexpectedResult);
        const body_start: u32 = @intCast(std.mem.indexOf(u8, source, "string") orelse
            return error.TestUnexpectedResult);
        const terminator_start: u32 = @intCast(std.mem.indexOfScalar(u8, source, ';') orelse
            return error.TestUnexpectedResult);

        var store = TypeSyntax.Store.init(std.testing.allocator, source);
        defer store.deinit();
        var pending = try store.reserveGenericOwner(.{
            .list_span = .{ .start = list_start, .end = list_end },
            .capture_spans = .{
                .actual_erased_span = .{ .start = list_start, .end = list_end },
                .legacy_recorded_span = .{ .start = list_start, .end = list_end },
            },
            .policy = .ignored,
        });
        try store.nodes.append(std.testing.allocator, .{
            .tag = .primitive,
            .semantic_span = .{ .start = body_start, .end = terminator_start },
            .data = .{ .primitive = .string },
        });
        try store.declarations.append(std.testing.allocator, .{
            .kind = .nominal,
            .export_span = null,
            .keyword_span = .{ .start = 0, .end = @intCast("nominal".len) },
            .name_span = .{ .start = name_start, .end = name_start + @as(u32, @intCast("UserId".len)) },
            .equals_span = .{ .start = equals_start, .end = equals_start + 1 },
            .terminator_span = .{ .start = terminator_start, .end = terminator_start + 1 },
            .body = .{ .present = .{
                .root = .{ .present = 0 },
                .node_range = .{ .start = 0, .count = 1 },
                .raw_span = .{ .start = body_start, .end = terminator_start },
                .admission_end = terminator_start,
                .semantic_prefix_end = terminator_start,
            } },
            .generic_owner = 0,
            .full_span = .{ .start = 0, .end = @intCast(source.len) },
            .source_order = 0,
            .authored_scope = 0,
        });
        try store.finishGenericOwner(
            &pending,
            .{ .declaration = .{ .kind = .nominal, .index = 0 } },
        );
        try store.validate();
        const owner = store.generic_owners.items[0];
        switch (owner.compatibility) {
            .ignored_declaration_parameters => {},
            else => return error.TestUnexpectedResult,
        }
        const projected = store.projectedGenericParameterSlice(owner.projected_parameters) orelse
            return error.TestUnexpectedResult;
        try std.testing.expectEqual(@as(usize, 1), projected.len);
        try std.testing.expect(projected[0].bound_fragment == null);

        var pool = TypePool.init(std.testing.allocator);
        defer pool.deinit(std.testing.allocator);
        var env = TypeEnv.init(std.testing.allocator, &pool);
        defer env.deinit();
        try lowerSyntaxStoreWithoutRuntimeOwners(std.testing.allocator, &store, &pool, &env);
        const alias = env.getTypeAlias("UserId") orelse return error.TestUnexpectedResult;
        try std.testing.expect(pool.isNominal(alias));
        try std.testing.expectEqual(@as(usize, 0), env.generic_scopes.items.len);
    }
    {
        const source = "<string>(";
        var store = TypeSyntax.Store.init(std.testing.allocator, source);
        defer store.deinit();
        var nodes = engine.parser.IRStore.init(std.testing.allocator);
        defer nodes.deinit();
        var constants = engine.parser.ConstantPool.init(std.testing.allocator);
        defer constants.deinit();
        const function = try nodes.add(.{
            .tag = .function_expr,
            .loc = .{ .line = 1, .column = 9, .offset = 8, .end_offset = 9 },
            .data = .{ .function = .{
                .scope_id = 0,
                .name_atom = 0,
                .params_start = engine.parser.null_node,
                .params_count = 0,
                .body = engine.parser.null_node,
                .flags = .{},
            } },
        });
        const view = engine.parser.IrView.fromIRStore(&nodes, &constants);
        var pending = try store.reserveGenericOwner(.{
            .list_span = .{ .start = 0, .end = 8 },
            .capture_spans = .{
                .actual_erased_span = .{ .start = 0, .end = 8 },
                .legacy_recorded_span = .{ .start = 0, .end = 8 },
            },
            .policy = .legacy_call,
        });
        try store.finishGenericOwner(&pending, .{ .runtime = .{
            .owner = function,
            .view = view,
        } });
        try store.validateRuntimeOwners(std.testing.allocator, view);
        const owner = store.generic_owners.items[0];
        const projected = store.projectedGenericParameterSlice(owner.projected_parameters) orelse
            return error.TestUnexpectedResult;
        try std.testing.expectEqual(@as(usize, 1), projected.len);
        try std.testing.expect(projected[0].bound_fragment == null);

        var pool = TypePool.init(std.testing.allocator);
        defer pool.deinit(std.testing.allocator);
        var env = TypeEnv.init(std.testing.allocator, &pool);
        defer env.deinit();
        try lowerSyntaxStore(std.testing.allocator, &store, &pool, &env, view);
        const arguments = env.getCallTypeArgs(8) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqual(@as(u8, 1), arguments.count);
        try std.testing.expectEqual(pool.idx_string, arguments.args[0]);
        try std.testing.expectEqual(@as(usize, 0), env.generic_scopes.items.len);
    }
}

const NominalGenericExpectation = struct {
    declaration_index: usize,
    name: []const u8,
    list: []const u8,
    base: TypeSyntax.Primitive,
    constraint: ?[]const u8 = null,
    authored_default: ?[]const u8 = null,
    legacy_bound: ?[]const u8 = null,
};

fn expectNominalGenericOwner(
    store: *const TypeSyntax.Store,
    expected: NominalGenericExpectation,
) !void {
    const declaration = store.declarations.items[expected.declaration_index];
    try std.testing.expectEqual(TypeSyntax.DeclarationKind.nominal, declaration.kind);
    try std.testing.expectEqual(@as(u32, @intCast(expected.declaration_index)), declaration.source_order);
    try std.testing.expectEqualStrings(expected.name, declaration.name_span.text(store.source));
    const owner_index = declaration.generic_owner orelse return error.TestUnexpectedResult;
    const owner = store.generic_owners.items[owner_index];
    switch (owner.identity) {
        .nominal_declaration => |index| try std.testing.expectEqual(
            @as(u32, @intCast(expected.declaration_index)),
            index,
        ),
        else => return error.TestUnexpectedResult,
    }
    switch (owner.compatibility) {
        .ignored_declaration_parameters => {},
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expectEqualStrings(expected.list, owner.list_span.text(store.source));
    try std.testing.expect(std.meta.eql(owner.list_span, owner.capture_spans.actual_erased_span));
    try std.testing.expect(std.meta.eql(owner.list_span, owner.capture_spans.legacy_recorded_span));
    const authored = store.genericParameterSlice(owner.authored_parameters) orelse
        return error.TestUnexpectedResult;
    const projected = store.projectedGenericParameterSlice(owner.projected_parameters) orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 1), authored.len);
    try std.testing.expectEqual(@as(usize, 1), projected.len);
    const recognized = authored[0].recognized orelse return error.TestUnexpectedResult;
    if (expected.constraint) |constraint| {
        const span = recognized.constraint_span orelse return error.TestUnexpectedResult;
        try std.testing.expectEqualStrings(constraint, span.text(store.source));
    } else {
        try std.testing.expect(recognized.constraint_span == null);
    }
    if (expected.authored_default) |authored_default| {
        const span = recognized.default_span orelse return error.TestUnexpectedResult;
        try std.testing.expectEqualStrings(authored_default, span.text(store.source));
    } else {
        try std.testing.expect(recognized.default_span == null);
    }
    if (expected.legacy_bound) |legacy_bound| {
        const span = projected[0].legacy_bound_span orelse return error.TestUnexpectedResult;
        try std.testing.expectEqualStrings(legacy_bound, span.text(store.source));
    } else {
        try std.testing.expect(projected[0].legacy_bound_span == null);
    }
    try std.testing.expect(projected[0].bound_fragment == null);
    const body = switch (declaration.body) {
        .present => |value| value,
        .absent => return error.TestUnexpectedResult,
    };
    const root_index = switch (body.root) {
        .present => |index| index,
        .absent => return error.TestUnexpectedResult,
    };
    const root = store.node(root_index) orelse return error.TestUnexpectedResult;
    const primitive = switch (root.data) {
        .primitive => |value| value,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(expected.base, primitive);
}

test "nominal generic source owns the exact declaration without generic semantics" {
    const source = "nominal Id<T> = string;";
    try expectEquivalent(source);

    var parser = try JsParser.initTyped(std.testing.allocator, std.testing.allocator, source);
    defer parser.deinit();
    _ = try parser.parse();
    try parser.type_store.validate();
    try std.testing.expectEqual(@as(usize, 1), parser.type_store.declarations.items.len);
    try std.testing.expectEqual(@as(usize, 1), parser.type_store.generic_owners.items.len);
    try std.testing.expectEqual(@as(usize, 0), parser.type_store.semantic_fragments.items.len);
    try expectNominalGenericOwner(&parser.type_store, .{
        .declaration_index = 0,
        .name = "Id",
        .list = "<T>",
        .base = .string,
    });

    var pool = TypePool.init(std.testing.allocator);
    defer pool.deinit(std.testing.allocator);
    var env = TypeEnv.init(std.testing.allocator, &pool);
    defer env.deinit();
    module_types.populateModuleTypes(&env, &pool, std.testing.allocator);
    abi_types.populateHandlerAbiTypes(&env, &pool, std.testing.allocator);
    try lowerSyntaxStore(
        std.testing.allocator,
        &parser.type_store,
        &pool,
        &env,
        parserIrView(&parser),
    );
    const alias = env.getTypeAlias("Id") orelse return error.TestUnexpectedResult;
    try std.testing.expect(pool.isNominal(alias));
    try std.testing.expectEqualStrings("Id", pool.nominalName(alias));
    try std.testing.expectEqual(pool.idx_string, pool.unwrapNominal(alias));
    try std.testing.expectEqual(@as(usize, 0), env.generic_scopes.items.len);
}

test "nominal generic scalar matrix retains ignored bounds and declaration order" {
    const source =
        "nominal Text<T> = string;\n" ++
        "nominal Count<T extends string> = number;\n" ++
        "nominal Flag<T = number> = boolean;\n" ++
        "nominal Both<T extends string = boolean> = string;\n";
    try expectEquivalent(source);

    var parser = try JsParser.initTyped(std.testing.allocator, std.testing.allocator, source);
    defer parser.deinit();
    _ = try parser.parse();
    try parser.type_store.validate();
    try std.testing.expectEqual(@as(usize, 4), parser.type_store.declarations.items.len);
    try std.testing.expectEqual(@as(usize, 4), parser.type_store.generic_owners.items.len);
    try std.testing.expectEqual(@as(usize, 4), parser.type_store.generic_parameters.items.len);
    try std.testing.expectEqual(@as(usize, 4), parser.type_store.projected_generic_parameters.items.len);
    try std.testing.expectEqual(@as(usize, 0), parser.type_store.semantic_fragments.items.len);
    try expectNominalGenericOwner(&parser.type_store, .{
        .declaration_index = 0,
        .name = "Text",
        .list = "<T>",
        .base = .string,
    });
    try expectNominalGenericOwner(&parser.type_store, .{
        .declaration_index = 1,
        .name = "Count",
        .list = "<T extends string>",
        .base = .number,
        .constraint = "string",
        .legacy_bound = "string",
    });
    try expectNominalGenericOwner(&parser.type_store, .{
        .declaration_index = 2,
        .name = "Flag",
        .list = "<T = number>",
        .base = .boolean,
        .authored_default = "number",
    });
    try expectNominalGenericOwner(&parser.type_store, .{
        .declaration_index = 3,
        .name = "Both",
        .list = "<T extends string = boolean>",
        .base = .string,
        .constraint = "string",
        .authored_default = "boolean",
        .legacy_bound = "string = boolean",
    });
    for (parser.type_store.projected_generic_parameters.items) |parameter| {
        try std.testing.expect(parameter.bound_fragment == null);
    }

    var pool = TypePool.init(std.testing.allocator);
    defer pool.deinit(std.testing.allocator);
    var env = TypeEnv.init(std.testing.allocator, &pool);
    defer env.deinit();
    module_types.populateModuleTypes(&env, &pool, std.testing.allocator);
    abi_types.populateHandlerAbiTypes(&env, &pool, std.testing.allocator);
    try lowerSyntaxStore(
        std.testing.allocator,
        &parser.type_store,
        &pool,
        &env,
        parserIrView(&parser),
    );
    const names = [_][]const u8{ "Text", "Count", "Flag", "Both" };
    const bases = [_]TypeIndex{ pool.idx_string, pool.idx_number, pool.idx_boolean, pool.idx_string };
    for (names, bases) |name, base| {
        const alias = env.getTypeAlias(name) orelse return error.TestUnexpectedResult;
        try std.testing.expect(pool.isNominal(alias));
        try std.testing.expectEqualStrings(name, pool.nominalName(alias));
        try std.testing.expectEqual(base, pool.unwrapNominal(alias));
    }
    try std.testing.expectEqual(@as(usize, 0), env.generic_scopes.items.len);
}

test "nominal generic base refusal retains preflight diagnostic" {
    const source = "nominal Id<T> = T;";
    inline for (.{ AdmissionMode.collect, AdmissionMode.compile }) |mode| {
        var checked = switch (try preflight(std.testing.allocator, source, mode)) {
            .eligible => |eligible| eligible,
            .out_of_slice => return error.TestUnexpectedResult,
        };
        defer checked.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(usize, 1), checked.diagnostics.items.len);
        try std.testing.expectEqual(
            AdmissionKind.nominal_base_not_scalar,
            checked.diagnostics.items[0].kind,
        );
        try std.testing.expectEqualStrings("T", checked.diagnostics.items[0].span.text(source));
    }
    switch (try compare(std.testing.allocator, source, .collect)) {
        .admission_refused => |refusal| {
            try std.testing.expectEqual(AdmissionKind.nominal_base_not_scalar, refusal.first);
            try std.testing.expectEqual(@as(usize, 1), refusal.count);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "nominal generic type allocation failures restore the published seed" {
    const source =
        "nominal Seed<S> = number;\n" ++
        "nominal Id<T extends string = boolean> = string;\n";
    const Context = struct {
        fn run(
            type_allocator: std.mem.Allocator,
            observed_failures: *usize,
            observed_post_seed_rollbacks: *usize,
        ) !void {
            var atoms = AtomTable.init(std.testing.allocator);
            defer atoms.deinit();
            var parser = try JsParser.initTyped(std.testing.allocator, type_allocator, source);
            defer parser.deinit();
            parser.setAtomTable(&atoms);
            const root = parser.parse() catch |err| switch (err) {
                error.OutOfMemory => {
                    observed_failures.* += 1;
                    try std.testing.expectEqual(@as(u16, 0), parser.scopes.current_scope);
                    const checkpoint = parser.type_store.checkpoint();
                    const second_declaration = std.mem.indexOf(u8, source, "nominal Id") orelse
                        return error.TestUnexpectedResult;
                    if (parser.current.start >= second_declaration) {
                        observed_post_seed_rollbacks.* += 1;
                        try std.testing.expect(std.meta.eql(checkpoint, nominalGenericSeedCheckpoint()));
                        try parser.type_store.validate();
                    } else {
                        try std.testing.expect(std.meta.eql(
                            checkpoint,
                            std.mem.zeroes(TypeSyntax.Store.Checkpoint),
                        ));
                    }
                    return error.OutOfMemory;
                },
                else => return err,
            };

            try expectFunctionSliceRuntimeParity(std.testing.allocator, source, &parser, root, &atoms);
            try parser.type_store.validate();
            const checkpoint = parser.type_store.checkpoint();
            try std.testing.expect(checkpoint.nodes >= 2);
            try std.testing.expect(checkpoint.declarations >= 2);
            try std.testing.expect(checkpoint.generic_parameters >= 2);
            try std.testing.expect(checkpoint.projected_generic_parameters >= 2);
            try std.testing.expect(checkpoint.generic_owners >= 2);
            try std.testing.expectEqual(@as(usize, 0), checkpoint.semantic_fragments);
            try expectNominalGenericOwner(&parser.type_store, .{
                .declaration_index = 0,
                .name = "Seed",
                .list = "<S>",
                .base = .number,
            });
            try expectNominalGenericOwner(&parser.type_store, .{
                .declaration_index = 1,
                .name = "Id",
                .list = "<T extends string = boolean>",
                .base = .string,
                .constraint = "string",
                .authored_default = "boolean",
                .legacy_bound = "string = boolean",
            });
        }
    };
    var observed_failures: usize = 0;
    var observed_post_seed_rollbacks: usize = 0;
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        Context.run,
        .{ &observed_failures, &observed_post_seed_rollbacks },
    );
    try std.testing.expect(observed_failures > 0);
    try std.testing.expect(observed_post_seed_rollbacks > 0);
}

test "nominal generic list diagnostics precede scalar base refusal" {
    const cases = [_]struct { source: []const u8, diagnostics: []const AdmissionDiagnostic }{
        .{ .source = "nominal Id<T extends void> = T;", .diagnostics = &.{
            .{ .kind = .void_type, .span = .{ .start = 21, .end = 25 } },
            .{ .kind = .nominal_base_not_scalar, .span = .{ .start = 29, .end = 30 } },
        } },
        .{ .source = "nominal Id<T extends void>;", .diagnostics = &.{
            .{ .kind = .void_type, .span = .{ .start = 21, .end = 25 } },
            .{ .kind = .nominal_base_not_scalar, .span = .{ .start = 26, .end = 26 } },
        } },
        .{ .source = "nominal Id<T extends void> = ;", .diagnostics = &.{
            .{ .kind = .void_type, .span = .{ .start = 21, .end = 25 } },
            .{ .kind = .nominal_base_not_scalar, .span = .{ .start = 29, .end = 29 } },
        } },
        .{ .source = "nominal Id<T extends any> = T;", .diagnostics = &.{
            .{ .kind = .nominal_base_not_scalar, .span = .{ .start = 28, .end = 29 } },
        } },
        .{ .source = "nominal Id<T extends void> = any;", .diagnostics = &.{
            .{ .kind = .void_type, .span = .{ .start = 21, .end = 25 } },
            .{ .kind = .any_type, .span = .{ .start = 29, .end = 32 } },
        } },
    };
    var observed: usize = 0;
    for (cases) |case| {
        inline for (.{ AdmissionMode.collect, AdmissionMode.compile }) |mode| {
            const expected = if (mode == .collect) case.diagnostics else case.diagnostics[0..1];
            var checked = switch (try preflight(std.testing.allocator, case.source, mode)) {
                .eligible => |eligible| eligible,
                .out_of_slice => return error.TestUnexpectedResult,
            };
            defer checked.deinit(std.testing.allocator);
            try std.testing.expectEqual(expected.len, checked.diagnostics.items.len);
            for (expected, checked.diagnostics.items) |wanted, actual| {
                try std.testing.expect(std.meta.eql(wanted, actual));
            }
            switch (try compare(std.testing.allocator, case.source, mode)) {
                .admission_refused => |refusal| {
                    try std.testing.expectEqual(expected[0].kind, refusal.first);
                    try std.testing.expectEqual(expected.len, refusal.count);
                },
                else => return error.TestUnexpectedResult,
            }
        }
        observed += 1;
    }
    try std.testing.expectEqual(@as(usize, 5), cases.len);
    try std.testing.expectEqual(cases.len, observed);
}

test "first generic function slice accepts only its bounded source shape" {
    const whitespace_source =
        "const seed: number = 1; function identity<T> \t\r\n(value) { return value; }";
    var whitespace_parser = try JsParser.initTyped(
        std.testing.allocator,
        std.testing.allocator,
        whitespace_source,
    );
    defer whitespace_parser.deinit();
    _ = try whitespace_parser.parse();
    try expectEquivalent(whitespace_source);
    try std.testing.expectEqual(@as(usize, 1), whitespace_parser.type_store.generic_owners.items.len);
    const whitespace_owner = whitespace_parser.type_store.generic_owners.items[0];
    try std.testing.expect(std.meta.eql(
        whitespace_owner.list_span,
        whitespace_owner.capture_spans.actual_erased_span,
    ));
    try std.testing.expectEqualStrings(
        "T",
        whitespace_owner.capture_spans.legacy_recorded_span.text(whitespace_source),
    );

    const Exclusion = struct {
        source: []const u8,
        reason: OutOfSliceReason,
    };
    const exclusions = [_]Exclusion{
        .{ .source = "const seed: number = 1; function identity<T>(value) { const inner: any = value; return value; }", .reason = .function_declaration },
        .{ .source = "const seed: number = 1; function identity<T>(value: number) { return value; }", .reason = .function_declaration },
        .{ .source = "const seed: number = 1; function /* gap */ identity<T>(value) { return value; }", .reason = .function_declaration },
        .{ .source = "const seed: number = 1; function // gap\nidentity<T>(value) { return value; }", .reason = .function_declaration },
        .{ .source = "const seed: number = 1; function identity<T>/* gap */(value) { return value; }", .reason = .function_declaration },
        .{ .source = "const seed: number = 1; function identity<T>// gap\n(value) { return value; }", .reason = .function_declaration },
        .{ .source = "const seed: number = 1; function identity<T>>(value) { return value; }", .reason = .function_declaration },
    };
    for (exclusions) |fixture| switch (try compare(std.testing.allocator, fixture.source, .collect)) {
        .out_of_slice => |reason| try std.testing.expectEqual(fixture.reason, reason),
        else => return error.TestUnexpectedResult,
    };

    const residual_closer_exclusions = exclusions[exclusions.len - 1 ..];
    for (residual_closer_exclusions) |fixture| {
        var parser = try JsParser.initTyped(std.testing.allocator, std.testing.allocator, fixture.source);
        defer parser.deinit();
        try std.testing.expectError(error.UnexpectedToken, parser.parse());
        try std.testing.expectEqual(@as(usize, 0), parser.type_store.generic_owners.items.len);
        try std.testing.expectEqual(@as(usize, 0), parser.type_store.generic_parameters.items.len);
        try std.testing.expectEqual(@as(usize, 0), parser.type_store.projected_generic_parameters.items.len);
    }
}

test "first generic function slice excludes unsafe generic list scans" {
    const Context = struct {
        fn expectExcluded(source: []const u8) !void {
            switch (try compare(std.testing.allocator, source, .collect)) {
                .out_of_slice => |reason| try std.testing.expectEqual(
                    OutOfSliceReason.function_declaration,
                    reason,
                ),
                else => return error.TestUnexpectedResult,
            }

            var parser = try JsParser.initTyped(std.testing.allocator, std.testing.allocator, source);
            defer parser.deinit();
            try std.testing.expectError(error.UnexpectedToken, parser.parse());
            try std.testing.expectEqual(@as(usize, 0), parser.type_store.generic_owners.items.len);
            try std.testing.expectEqual(@as(usize, 0), parser.type_store.generic_parameters.items.len);
            try std.testing.expectEqual(
                @as(usize, 0),
                parser.type_store.projected_generic_parameters.items.len,
            );
            const generic_start = std.mem.indexOfScalar(u8, source, '<') orelse
                return error.TestUnexpectedResult;
            const errors = parser.errors.getErrors();
            try std.testing.expect(errors.len > 0);
            try std.testing.expectEqual(@as(u32, @intCast(generic_start)), errors[0].location.offset);
        }
    };

    try Context.expectExcluded(
        "const seed: number = 1; function identity<T = /,/, U>(value) { return value; }",
    );

    var balanced_template: std.ArrayListUnmanaged(u8) = .empty;
    defer balanced_template.deinit(std.testing.allocator);
    try balanced_template.appendSlice(
        std.testing.allocator,
        "const seed: number = 1; function identity<T = ",
    );
    for (0..TypeSyntax.max_type_depth + 1) |_| {
        try balanced_template.appendSlice(std.testing.allocator, "`${");
    }
    try balanced_template.appendSlice(std.testing.allocator, "string");
    for (0..TypeSyntax.max_type_depth + 1) |_| {
        try balanced_template.appendSlice(std.testing.allocator, "}`");
    }
    try balanced_template.appendSlice(
        std.testing.allocator,
        ", U>(value) { return value; }",
    );
    try Context.expectExcluded(balanced_template.items);
}

const GenericArrowCompatibilityExpectation = enum {
    declaration_parameters,
    legacy_call_arguments,
};

const GenericArrowExpectation = struct {
    list: []const u8,
    actual_capture: []const u8,
    legacy_capture: []const u8,
    projected_name: []const u8,
    compatibility: GenericArrowCompatibilityExpectation,
    authored_argument: []const u8 = "T",
};

fn expectGenericArrowOrderedProjection(
    parser: *const JsParser,
    expected: GenericArrowExpectation,
) !void {
    var pool = TypePool.init(std.testing.allocator);
    defer pool.deinit(std.testing.allocator);
    var env = TypeEnv.init(std.testing.allocator, &pool);
    defer env.deinit();
    const prior_nodes = pool.nodes.items.len;
    try lowerSyntaxStore(
        std.testing.allocator,
        &parser.type_store,
        &pool,
        &env,
        parserIrView(parser),
    );
    try std.testing.expectEqual(prior_nodes + 1, pool.nodes.items.len);
    try std.testing.expectEqual(@as(usize, 0), env.generic_scopes.items.len);

    const owner = parser.type_store.generic_owners.items[0];
    const owner_node = switch (owner.identity) {
        .arrow => |node| node,
        else => return error.TestUnexpectedResult,
    };
    const opener = parserIrView(parser).getLoc(owner_node) orelse
        return error.TestUnexpectedResult;
    switch (expected.compatibility) {
        .declaration_parameters => {
            try std.testing.expectEqual(
                TypeTag.t_generic_param,
                pool.getTag(@intCast(prior_nodes)).?,
            );
            try std.testing.expectEqualStrings(
                expected.projected_name,
                pool.getRefName(@intCast(prior_nodes)),
            );
            try std.testing.expect(env.getCallTypeArgs(opener.offset) == null);
        },
        .legacy_call_arguments => {
            try std.testing.expectEqual(
                TypeTag.t_ref,
                pool.getTag(@intCast(prior_nodes)).?,
            );
            try std.testing.expectEqualStrings("T", pool.getRefName(@intCast(prior_nodes)));
            const arguments = env.getCallTypeArgs(opener.offset) orelse
                return error.TestUnexpectedResult;
            try std.testing.expectEqual(@as(u8, 1), arguments.count);
            try std.testing.expectEqual(@as(TypeIndex, @intCast(prior_nodes)), arguments.args[0]);
            var prepared = try PreparedSource.init(
                std.testing.allocator,
                parser.source,
                "<generic-arrow-call-projection>.ts",
                .{},
            );
            defer prepared.deinit();
            var legacy_pool = TypePool.init(std.testing.allocator);
            defer legacy_pool.deinit(std.testing.allocator);
            var legacy_env = TypeEnv.init(std.testing.allocator, &legacy_pool);
            defer legacy_env.deinit();
            try legacy_env.populateFromTypeMap(prepared.typeMap() orelse return error.TestUnexpectedResult);
            try legacy_pool.ensureHealthy();
            try legacy_env.ensureHealthy();
            const legacy_arguments = legacy_env.getCallTypeArgs(opener.offset) orelse
                return error.TestUnexpectedResult;
            try std.testing.expectEqual(legacy_arguments.count, arguments.count);
            try std.testing.expect(try orderedTypeEqual(
                std.testing.allocator,
                &legacy_pool,
                legacy_arguments.args[0],
                &pool,
                arguments.args[0],
            ));
        },
    }
}

fn expectTypedGenericArrowRecords(
    parser: *const JsParser,
    source: []const u8,
    expected: GenericArrowExpectation,
) !void {
    const store = &parser.type_store;
    const view = parserIrView(parser);
    try store.validateRuntimeOwners(std.testing.allocator, view);
    try std.testing.expectEqual(@as(usize, 1), store.generic_owners.items.len);
    try std.testing.expectEqual(@as(usize, 1), store.generic_parameters.items.len);
    try std.testing.expectEqual(@as(usize, 1), store.projected_generic_parameters.items.len);
    try std.testing.expectEqual(@as(usize, 1), store.parameter_annotations.items.len);
    try std.testing.expectEqual(@as(usize, 1), store.function_signatures.items.len);
    try std.testing.expectEqual(@as(usize, 0), store.type_only_modules.items.len);
    try std.testing.expectEqual(@as(usize, 0), store.erased_type_prefixes.items.len);

    const owner = store.generic_owners.items[0];
    try std.testing.expectEqualStrings(expected.list, owner.list_span.text(source));
    try std.testing.expectEqualStrings(
        expected.actual_capture,
        owner.capture_spans.actual_erased_span.text(source),
    );
    try std.testing.expectEqualStrings(
        expected.legacy_capture,
        owner.capture_spans.legacy_recorded_span.text(source),
    );
    try std.testing.expectEqual(@as(u32, 0), owner.authored_parameters.start);
    try std.testing.expectEqual(@as(u32, 1), owner.authored_parameters.count);
    try std.testing.expectEqual(@as(u32, 0), owner.projected_parameters.start);
    try std.testing.expectEqual(@as(u32, 1), owner.projected_parameters.count);
    const projected = store.projectedGenericParameterSlice(owner.projected_parameters) orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings(expected.projected_name, projected[0].name_span.text(source));

    const owner_node = switch (owner.identity) {
        .arrow => |node| node,
        else => return error.TestUnexpectedResult,
    };
    const signature = store.function_signatures.items[0];
    try std.testing.expectEqual(owner_node, signature.owner);
    try std.testing.expectEqual(engine.parser.NodeTag.arrow_function, view.getTag(owner_node).?);
    const function = view.getFunction(owner_node) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u8, 1), function.params_count);
    try std.testing.expectEqual(@as(u32, 0), signature.parameters.start);
    try std.testing.expectEqual(@as(u32, 1), signature.parameters.count);
    const pattern = view.getListIndex(function.params_start, 0);
    const parameter = store.parameter_annotations.items[0];
    try std.testing.expectEqual(pattern, parameter.owner.pattern);
    try std.testing.expect(std.meta.eql(
        parameter.owner.binding,
        view.paramBinding(pattern) orelse return error.TestUnexpectedResult,
    ));
    try std.testing.expectEqualStrings("T", parameter.value.raw_span.text(source));
    const parameter_root = store.node(try syntaxChildIndex(parameter.value.root)) orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqual(TypeSyntax.NodeTag.named_reference, parameter_root.tag);
    try std.testing.expectEqualStrings("T", parameter_root.semantic_span.text(source));

    const return_syntax = signature.return_syntax orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(TypeSyntax.LegacyReturnKind.ordinary, return_syntax.legacy_return_kind);
    try std.testing.expect(return_syntax.legacy_ordinary_prefix == null);
    const return_value = switch (return_syntax.structure) {
        .value => |value| value,
        .predicate => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqualStrings("T ", return_value.raw_span.text(source));
    const return_root = store.node(try syntaxChildIndex(return_value.root)) orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqual(TypeSyntax.NodeTag.named_reference, return_root.tag);
    try std.testing.expectEqualStrings("T", return_root.semantic_span.text(source));

    const opener = std.mem.indexOf(u8, source, "(value") orelse
        return error.TestUnexpectedResult;
    const body = std.mem.lastIndexOf(u8, source, "value") orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u32, @intCast(opener)), view.getLoc(owner_node).?.offset);
    try std.testing.expectEqual(@as(u32, @intCast(opener)), signature.source_span.start);
    try std.testing.expectEqual(@as(u32, @intCast(body)), signature.source_span.end);

    switch (expected.compatibility) {
        .declaration_parameters => {
            switch (owner.compatibility) {
                .declaration_parameters => {},
                else => return error.TestUnexpectedResult,
            }
            try std.testing.expectEqual(@as(usize, 0), store.authored_call_arguments.items.len);
            try std.testing.expectEqual(@as(usize, 0), store.semantic_fragments.items.len);
        },
        .legacy_call_arguments => {
            const ranges = switch (owner.compatibility) {
                .legacy_call_arguments => |ranges| ranges,
                else => return error.TestUnexpectedResult,
            };
            try std.testing.expectEqual(@as(u32, 0), ranges.authored_arguments.start);
            try std.testing.expectEqual(@as(u32, 1), ranges.authored_arguments.count);
            try std.testing.expectEqual(@as(u32, 0), ranges.semantic_fragments.start);
            try std.testing.expectEqual(@as(u32, 1), ranges.semantic_fragments.count);
            const authored = store.authoredCallArgumentSlice(ranges.authored_arguments) orelse
                return error.TestUnexpectedResult;
            const fragments = store.semanticFragmentSlice(ranges.semantic_fragments) orelse
                return error.TestUnexpectedResult;
            try std.testing.expectEqualStrings(
                expected.authored_argument,
                std.mem.trim(u8, authored[0].full_span.text(source), " \t\r\n"),
            );
            try std.testing.expectEqualStrings("T", fragments[0].raw_span.text(source));
        },
    }
    try expectGenericArrowOrderedProjection(parser, expected);
}

test "typed generic arrows retain final owners and legacy projection windows" {
    const Fixture = struct {
        source: []const u8,
        expected: GenericArrowExpectation,
    };
    const fixtures = [_]Fixture{
        .{
            .source = "const id=<T>(value: T): T => value;",
            .expected = .{
                .list = "<T>",
                .actual_capture = "<T>",
                .legacy_capture = "T",
                .projected_name = "T",
                .compatibility = .declaration_parameters,
            },
        },
        .{
            .source = "const id=(<T> (value: T): T => value);",
            .expected = .{
                .list = "<T>",
                .actual_capture = "<T> ",
                .legacy_capture = "T>",
                .projected_name = "T>",
                .compatibility = .declaration_parameters,
            },
        },
        .{
            .source = "const id = /* gap */ <T> (value: T): T => value;",
            .expected = .{
                .list = "<T>",
                .actual_capture = "<T> ",
                .legacy_capture = "T>",
                .projected_name = "T>",
                .compatibility = .declaration_parameters,
            },
        },
        .{
            .source = "const id = // note\n<T>(value: T): T => value;",
            .expected = .{
                .list = "<T>",
                .actual_capture = "<T>",
                .legacy_capture = "T",
                .projected_name = "T",
                .compatibility = .legacy_call_arguments,
            },
        },
        .{
            .source = "const id = // note=\n<T = string> (value: T): T => value;",
            .expected = .{
                .list = "<T = string>",
                .actual_capture = "<T = string> ",
                .legacy_capture = "T = string>",
                .projected_name = "T",
                .compatibility = .declaration_parameters,
            },
        },
    };

    for (fixtures) |fixture| {
        var runtime_count = CountingAllocator.init(std.testing.allocator);
        const runtime_allocator = runtime_count.allocator();
        var atoms = AtomTable.init(runtime_allocator);
        defer atoms.deinit();
        var parser = try JsParser.initTyped(
            runtime_allocator,
            std.testing.allocator,
            fixture.source,
        );
        defer parser.deinit();
        parser.setAtomTable(&atoms);
        const root = try parser.parse();
        try expectRuntimeParityAndShape(
            fixture.source,
            &parser,
            root,
            &atoms,
            runtime_count,
        );
        try expectTypedGenericArrowRecords(&parser, fixture.source, fixture.expected);
    }
    try std.testing.expectEqual(@as(usize, 5), fixtures.len);
}

test "generic arrow and explicit call retain ordered syntax before equivalence" {
    const source =
        "const seed: number = 1; const id=<T>(value)=>value; const result=id<string>(seed);";
    var parser = try JsParser.initTyped(std.testing.allocator, std.testing.allocator, source);
    defer parser.deinit();
    _ = try parser.parse();
    try parser.type_store.validate();

    try std.testing.expectEqual(@as(usize, 1), parser.type_store.annotations.items.len);
    try std.testing.expectEqual(@as(usize, 1), parser.type_store.generic_owners.items.len);
    try std.testing.expectEqual(@as(usize, 1), parser.type_store.explicit_call_arguments.items.len);
    const owner = parser.type_store.generic_owners.items[0];
    const view = parserIrView(&parser);
    const arrow_paren = std.mem.indexOf(u8, source, "(value)") orelse
        return error.TestUnexpectedResult;
    switch (owner.identity) {
        .arrow => |node| {
            try std.testing.expectEqual(engine.parser.NodeTag.arrow_function, view.getTag(node).?);
            try std.testing.expectEqual(@as(u32, @intCast(arrow_paren)), view.getLoc(node).?.offset);
        },
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expectEqualStrings("<T>", owner.list_span.text(source));
    const projected = parser.type_store.projectedGenericParameterSlice(owner.projected_parameters) orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 1), projected.len);
    try std.testing.expectEqualStrings("T", projected[0].name_span.text(source));

    const call = parser.type_store.explicit_call_arguments.items[0];
    const call_paren = std.mem.indexOf(u8, source, "(seed)") orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqual(engine.parser.NodeTag.call, view.getTag(call.owner).?);
    try std.testing.expectEqual(@as(u32, @intCast(call_paren)), view.getLoc(call.owner).?.offset);
    try std.testing.expectEqualStrings("<string>", call.list_span.text(source));
    const authored = parser.type_store.authoredCallArgumentSlice(call.authored_arguments) orelse
        return error.TestUnexpectedResult;
    const fragments = parser.type_store.semanticFragmentSlice(call.semantic_fragments) orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 1), authored.len);
    try std.testing.expectEqual(@as(usize, 1), fragments.len);
    try std.testing.expectEqualStrings("string", std.mem.trim(
        u8,
        authored[0].full_span.text(source),
        " \t\r\n",
    ));
    try std.testing.expectEqualStrings("string", fragments[0].raw_span.text(source));

    var pool = TypePool.init(std.testing.allocator);
    defer pool.deinit(std.testing.allocator);
    var env = TypeEnv.init(std.testing.allocator, &pool);
    defer env.deinit();
    const prior_nodes = pool.nodes.items.len;
    const prior_signatures = env.fn_signatures.count();
    try lowerSyntaxStore(std.testing.allocator, &parser.type_store, &pool, &env, parserIrView(&parser));
    try std.testing.expectEqual(prior_nodes + 1, pool.nodes.items.len);
    try std.testing.expectEqual(TypeTag.t_generic_param, pool.getTag(@intCast(prior_nodes)).?);
    try std.testing.expectEqualStrings("T", pool.getRefName(@intCast(prior_nodes)));
    try std.testing.expectEqual(prior_signatures, env.fn_signatures.count());
    try std.testing.expectEqual(@as(usize, 0), env.generic_scopes.items.len);
    const lowered_call = env.call_type_args.get(@intCast(call_paren)) orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u8, 1), lowered_call.count);
    try std.testing.expectEqual(pool.idx_string, lowered_call.args[0]);

    try expectEquivalent(source);
}

test "nested generic owners and call retain source reservation order" {
    const source =
        "const seed: number = 1; function outer<T extends string = boolean>(value) { " ++
        "const inner=<U>(item)=>item; return inner<number>(value); }";
    var parser = try JsParser.initTyped(std.testing.allocator, std.testing.allocator, source);
    defer parser.deinit();
    _ = try parser.parse();
    try parser.type_store.validate();

    try std.testing.expectEqual(@as(usize, 2), parser.type_store.generic_owners.items.len);
    try std.testing.expectEqual(@as(usize, 1), parser.type_store.explicit_call_arguments.items.len);
    const outer = parser.type_store.generic_owners.items[0];
    const inner = parser.type_store.generic_owners.items[1];
    const view = parserIrView(&parser);
    switch (outer.identity) {
        .function => |node| try std.testing.expectEqual(
            @as(u32, @intCast(std.mem.indexOf(u8, source, "(value)") orelse return error.TestUnexpectedResult)),
            view.getLoc(node).?.offset,
        ),
        else => return error.TestUnexpectedResult,
    }
    switch (inner.identity) {
        .arrow => |node| try std.testing.expectEqual(
            @as(u32, @intCast(std.mem.indexOf(u8, source, "(item)") orelse return error.TestUnexpectedResult)),
            view.getLoc(node).?.offset,
        ),
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expectEqual(@as(u32, 0), outer.authored_parameters.start);
    try std.testing.expectEqual(outer.authored_parameters.count, inner.authored_parameters.start);
    try std.testing.expectEqual(@as(u32, 0), outer.projected_parameters.start);
    try std.testing.expectEqual(outer.projected_parameters.count, inner.projected_parameters.start);
    const outer_projected = parser.type_store.projectedGenericParameterSlice(outer.projected_parameters) orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 1), outer_projected.len);
    try std.testing.expectEqualStrings(
        "string = boolean",
        (outer_projected[0].legacy_bound_span orelse return error.TestUnexpectedResult).text(source),
    );
    try std.testing.expect(outer_projected[0].bound_fragment != null);
    const call = parser.type_store.explicit_call_arguments.items[0];
    const expected_call = std.mem.indexOf(u8, source, "(value);") orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u32, @intCast(expected_call)), view.getLoc(call.owner).?.offset);

    var pool = TypePool.init(std.testing.allocator);
    defer pool.deinit(std.testing.allocator);
    var env = TypeEnv.init(std.testing.allocator, &pool);
    defer env.deinit();
    const prior_signatures = env.fn_signatures.count();
    try lowerSyntaxStore(std.testing.allocator, &parser.type_store, &pool, &env, parserIrView(&parser));
    try std.testing.expectEqual(@as(usize, 0), env.generic_scopes.items.len);
    try std.testing.expectEqual(prior_signatures, env.fn_signatures.count());
    const lowered_call = env.call_type_args.get(@intCast(expected_call)) orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u8, 1), lowered_call.count);
    try std.testing.expectEqual(pool.idx_number, lowered_call.args[0]);

    try expectEquivalent(source);
}

test "iterative generic function preflight accepts a nonempty nested body" {
    const source =
        "const seed: number = 1; function outer<T>(value) { " ++
        "function inner<U>(item) { return item; } return value; }";
    var parser = try JsParser.initTyped(std.testing.allocator, std.testing.allocator, source);
    defer parser.deinit();
    _ = try parser.parse();
    try parser.type_store.validate();
    try std.testing.expectEqual(@as(usize, 2), parser.type_store.generic_owners.items.len);
    try std.testing.expectEqualStrings(
        "<T>",
        parser.type_store.generic_owners.items[0].list_span.text(source),
    );
    try std.testing.expectEqualStrings(
        "<U>",
        parser.type_store.generic_owners.items[1].list_span.text(source),
    );
    try expectEquivalent(source);
}

test "iterative generic function preflight declines its named depth budget" {
    var source: std.ArrayListUnmanaged(u8) = .empty;
    defer source.deinit(std.testing.allocator);
    try source.appendSlice(std.testing.allocator, "const seed: number = 1; ");
    for (0..TypeSyntax.max_type_depth + 1) |_| {
        try source.appendSlice(std.testing.allocator, "function nested<T>(value) { ");
    }
    try source.appendSlice(std.testing.allocator, "return value; ");
    for (0..TypeSyntax.max_type_depth + 1) |_| {
        try source.appendSlice(std.testing.allocator, "} ");
    }
    switch (try compare(std.testing.allocator, source.items, .collect)) {
        .out_of_slice => |reason| try std.testing.expectEqual(
            OutOfSliceReason.function_declaration,
            reason,
        ),
        else => return error.TestUnexpectedResult,
    }
}

const GenericRuntimeCase = enum {
    assignment_arrow_adjacent,
    assignment_arrow_whitespace,
    leading_empty_arrow_parameter,
    arrow_constraint_default,
    equality_arrow_window,
    general_arrow_spaced,
    comment_arrow_general,
    line_comment_equals_general,
    empty_assignment_arrow,
    empty_general_arrow,
    empty_explicit_call,
    explicit_call_adjacent,
    explicit_call_combined_opener,
    nested_call_closers,
    missing_call_comma,
    missing_call_closer,
    call_semantic_absence_first,
    quoted_call_comma,
    comment_call_comma,
    call_projection_cap,
    spaced_call_comparison,
    logical_comparison_control,
    shift_control,
    comparison_shift_control,
    comparison_unsigned_shift_control,
};

const generic_runtime_fixtures = [_]struct {
    case: GenericRuntimeCase,
    source: []const u8,
}{
    .{ .case = .assignment_arrow_adjacent, .source = "const seed: number = 1; const id=<T>(value)=>value;" },
    .{ .case = .assignment_arrow_whitespace, .source = "const seed: number = 1; const id = <T> (value)=>value;" },
    .{ .case = .leading_empty_arrow_parameter, .source = "const seed: number = 1; const id=<=string,T>(value)=>value;" },
    .{ .case = .arrow_constraint_default, .source = "const seed: number = 1; const id=<T extends string = boolean>(value)=>value;" },
    .{ .case = .equality_arrow_window, .source = "const seed: number = 1; const result=seed === <T> (value)=>value;" },
    .{ .case = .general_arrow_spaced, .source = "const seed: number = 1; const id=(<T> (value)=>value);" },
    .{ .case = .comment_arrow_general, .source = "const seed: number = 1; const id=/* gap */<T> (value)=>value;" },
    .{ .case = .line_comment_equals_general, .source = "const seed: number = 1; const id = // note=\n<T> (value)=>value;" },
    .{ .case = .empty_assignment_arrow, .source = "const seed: number = 1; const id=<>()=>seed;" },
    .{ .case = .empty_general_arrow, .source = "const seed: number = 1; const id=(<> (value)=>value);" },
    .{ .case = .empty_explicit_call, .source = "const seed: number = 1; const id=<T>(value)=>value; const result=id<>(seed);" },
    .{ .case = .explicit_call_adjacent, .source = "const seed: number = 1; const id=<T>(value)=>value; const result=id<string>(seed);" },
    .{ .case = .explicit_call_combined_opener, .source = "const seed: number = 1; const result=id<<string>>(seed);" },
    .{ .case = .nested_call_closers, .source = "const seed: number = 1; const id=<T>(value)=>value; const result=id<Outer<Inner<string>>>(seed);" },
    .{ .case = .missing_call_comma, .source = "const seed: number = 1; const id=<T>(value)=>value; const result=id<string number>(seed);" },
    .{ .case = .missing_call_closer, .source = "const seed: number = 1; const result=id<string(seed);" },
    .{ .case = .call_semantic_absence_first, .source = "const seed: number = 1; const id=<T>(value)=>value; const result=id<(),string>(seed);" },
    .{ .case = .quoted_call_comma, .source = "const seed: number = 1; const id=<T>(value)=>value; const result=id<\"a,b\">(seed);" },
    .{ .case = .comment_call_comma, .source = "const seed: number = 1; const id=<T>(value)=>value; const result=id<string /*,*/>(seed);" },
    .{ .case = .call_projection_cap, .source = "const seed: number = 1; const id=<T>(value)=>value; const result=id<A,B,C,D,E,F,G,H,I>(seed);" },
    .{ .case = .spaced_call_comparison, .source = "const seed: number = 1; const id=<T>(value)=>value; const result=id<string> (seed);" },
    .{ .case = .logical_comparison_control, .source = "const seed: number = 1; const result=seed < value && other > (seed);" },
    .{ .case = .shift_control, .source = "const seed: number = 1; const result=seed << 1;" },
    .{ .case = .comparison_shift_control, .source = "const seed: number = 1; const result=seed < other >> 1;" },
    .{ .case = .comparison_unsigned_shift_control, .source = "const seed: number = 1; const result=seed < other >>> 1;" },
};

test "generic runtime syntax census observes every case" {
    try std.testing.expectEqual(
        std.meta.fields(GenericRuntimeCase).len,
        generic_runtime_fixtures.len,
    );
    var seen = std.EnumSet(GenericRuntimeCase).initEmpty();
    for (generic_runtime_fixtures) |fixture| {
        errdefer std.debug.print(
            "generic runtime syntax case failed: {s}\n{s}\n",
            .{ @tagName(fixture.case), fixture.source },
        );
        try std.testing.expect(!seen.contains(fixture.case));
        var parser = try JsParser.initTyped(
            std.testing.allocator,
            std.testing.allocator,
            fixture.source,
        );
        defer parser.deinit();
        _ = try parser.parse();
        try parser.type_store.validate();
        try expectEquivalent(fixture.source);

        switch (fixture.case) {
            .assignment_arrow_adjacent, .equality_arrow_window => {
                const owner = parser.type_store.generic_owners.items[0];
                const projected = parser.type_store.projectedGenericParameterSlice(owner.projected_parameters) orelse
                    return error.TestUnexpectedResult;
                try std.testing.expectEqual(@as(usize, 1), projected.len);
                try std.testing.expectEqualStrings("T", projected[0].name_span.text(fixture.source));
            },
            .assignment_arrow_whitespace => {
                const owner = parser.type_store.generic_owners.items[0];
                try std.testing.expect(std.meta.eql(
                    owner.list_span,
                    owner.capture_spans.actual_erased_span,
                ));
                try std.testing.expectEqualStrings(
                    "T",
                    owner.capture_spans.legacy_recorded_span.text(fixture.source),
                );
            },
            .leading_empty_arrow_parameter => {
                const owner = parser.type_store.generic_owners.items[0];
                const projected = parser.type_store.projectedGenericParameterSlice(owner.projected_parameters) orelse
                    return error.TestUnexpectedResult;
                try std.testing.expectEqual(@as(usize, 2), projected.len);
                try std.testing.expectEqualStrings("", projected[0].name_span.text(fixture.source));
                try std.testing.expectEqualStrings("T", projected[1].name_span.text(fixture.source));
            },
            .arrow_constraint_default => {
                const owner = parser.type_store.generic_owners.items[0];
                const projected = parser.type_store.projectedGenericParameterSlice(owner.projected_parameters) orelse
                    return error.TestUnexpectedResult;
                try std.testing.expectEqual(@as(usize, 1), projected.len);
                try std.testing.expectEqualStrings("T", projected[0].name_span.text(fixture.source));
                try std.testing.expectEqualStrings(
                    "string = boolean",
                    (projected[0].legacy_bound_span orelse return error.TestUnexpectedResult).text(fixture.source),
                );
                try std.testing.expect(projected[0].bound_fragment != null);
            },
            .general_arrow_spaced => {
                const owner = parser.type_store.generic_owners.items[0];
                const opener = std.mem.indexOf(u8, fixture.source, "(value)") orelse
                    return error.TestUnexpectedResult;
                try std.testing.expectEqual(owner.list_span.start, owner.capture_spans.actual_erased_span.start);
                try std.testing.expectEqual(@as(u32, @intCast(opener)), owner.capture_spans.actual_erased_span.end);
                try std.testing.expectEqualStrings("<T> ", owner.capture_spans.actual_erased_span.text(fixture.source));
            },
            .comment_arrow_general, .line_comment_equals_general => {
                const owner = parser.type_store.generic_owners.items[0];
                const projected = parser.type_store.projectedGenericParameterSlice(owner.projected_parameters) orelse
                    return error.TestUnexpectedResult;
                try std.testing.expectEqual(@as(usize, 1), projected.len);
                try std.testing.expectEqualStrings("T>", projected[0].name_span.text(fixture.source));
            },
            .empty_assignment_arrow => {
                const owner = parser.type_store.generic_owners.items[0];
                try std.testing.expectEqual(@as(u32, 0), owner.authored_parameters.count);
                try std.testing.expectEqual(@as(u32, 0), owner.projected_parameters.count);
                try std.testing.expect(std.meta.eql(
                    owner.list_span,
                    owner.capture_spans.actual_erased_span,
                ));
                try std.testing.expectEqualStrings(
                    "",
                    owner.capture_spans.legacy_recorded_span.text(fixture.source),
                );
            },
            .empty_general_arrow => {
                const owner = parser.type_store.generic_owners.items[0];
                try std.testing.expectEqual(@as(u32, 0), owner.authored_parameters.count);
                const projected = parser.type_store.projectedGenericParameterSlice(owner.projected_parameters) orelse
                    return error.TestUnexpectedResult;
                try std.testing.expectEqual(@as(usize, 1), projected.len);
                try std.testing.expectEqualStrings(">", projected[0].name_span.text(fixture.source));
            },
            .empty_explicit_call => {
                const call = parser.type_store.explicit_call_arguments.items[0];
                try std.testing.expectEqual(@as(u32, 0), call.authored_arguments.count);
                try std.testing.expectEqual(@as(u32, 0), call.semantic_fragments.count);
            },
            .explicit_call_adjacent => {
                const call = parser.type_store.explicit_call_arguments.items[0];
                try std.testing.expectEqual(@as(u32, 1), call.authored_arguments.count);
                try std.testing.expectEqual(@as(u32, 1), call.semantic_fragments.count);
                try std.testing.expect(std.meta.eql(
                    call.list_span,
                    call.capture_spans.actual_erased_span,
                ));
                try std.testing.expectEqualStrings(
                    "string",
                    call.capture_spans.legacy_recorded_span.text(fixture.source),
                );
            },
            .explicit_call_combined_opener => {
                const call = parser.type_store.explicit_call_arguments.items[0];
                const authored = parser.type_store.authoredCallArgumentSlice(call.authored_arguments) orelse
                    return error.TestUnexpectedResult;
                try std.testing.expectEqual(@as(usize, 1), authored.len);
                try std.testing.expectEqualStrings("<string>", authored[0].full_span.text(fixture.source));
                const fragments = parser.type_store.semanticFragmentSlice(call.semantic_fragments) orelse
                    return error.TestUnexpectedResult;
                try std.testing.expectEqual(@as(usize, 1), fragments.len);
                try std.testing.expectEqualStrings("string", fragments[0].raw_span.text(fixture.source));
                const root = parser.type_store.node(try syntaxChildIndex(fragments[0].root)) orelse
                    return error.TestUnexpectedResult;
                try std.testing.expectEqual(TypeSyntax.NodeTag.primitive, root.tag);
                try std.testing.expectEqual(TypeSyntax.Primitive.string, root.data.primitive);
                const lparen = std.mem.indexOf(u8, fixture.source, "(seed)") orelse
                    return error.TestUnexpectedResult;
                try std.testing.expectEqual(
                    @as(u32, @intCast(lparen)),
                    parserIrView(&parser).getLoc(call.owner).?.offset,
                );
            },
            .nested_call_closers => {
                const call = parser.type_store.explicit_call_arguments.items[0];
                const fragments = parser.type_store.semanticFragmentSlice(call.semantic_fragments) orelse
                    return error.TestUnexpectedResult;
                try std.testing.expectEqual(@as(usize, 1), fragments.len);
                const root = parser.type_store.node(try syntaxChildIndex(fragments[0].root)) orelse
                    return error.TestUnexpectedResult;
                try std.testing.expectEqual(TypeSyntax.NodeTag.generic_application, root.tag);
            },
            .missing_call_comma => {
                const call = parser.type_store.explicit_call_arguments.items[0];
                const fragments = parser.type_store.semanticFragmentSlice(call.semantic_fragments) orelse
                    return error.TestUnexpectedResult;
                try std.testing.expectEqual(@as(usize, 1), fragments.len);
                try std.testing.expectEqual(
                    fragments[0].raw_span.start + @as(u32, "string".len),
                    fragments[0].semantic_prefix_end,
                );
            },
            .call_semantic_absence_first => {
                const call = parser.type_store.explicit_call_arguments.items[0];
                const fragments = parser.type_store.semanticFragmentSlice(call.semantic_fragments) orelse
                    return error.TestUnexpectedResult;
                try std.testing.expectEqual(@as(usize, 2), fragments.len);
                const group = parser.type_store.node(try syntaxChildIndex(fragments[0].root)) orelse
                    return error.TestUnexpectedResult;
                try std.testing.expectEqual(TypeSyntax.NodeTag.group, group.tag);
                switch (group.data.group.child) {
                    .absent => {},
                    .present => return error.TestUnexpectedResult,
                }
                try std.testing.expectEqualStrings("string", fragments[1].raw_span.text(fixture.source));
            },
            .quoted_call_comma, .comment_call_comma => {
                const call = parser.type_store.explicit_call_arguments.items[0];
                try std.testing.expectEqual(@as(u32, 1), call.authored_arguments.count);
                try std.testing.expectEqual(@as(u32, 2), call.semantic_fragments.count);
            },
            .call_projection_cap => {
                const call = parser.type_store.explicit_call_arguments.items[0];
                try std.testing.expectEqual(@as(u32, 8), call.semantic_fragments.count);
                try std.testing.expectEqual(@as(u32, 9), call.authored_arguments.count);
            },
            .missing_call_closer,
            .spaced_call_comparison,
            .logical_comparison_control,
            .shift_control,
            .comparison_shift_control,
            .comparison_unsigned_shift_control,
            => {
                try std.testing.expectEqual(
                    @as(usize, 0),
                    parser.type_store.explicit_call_arguments.items.len,
                );
            },
        }
        seen.insert(fixture.case);
    }
    try std.testing.expectEqual(std.meta.fields(GenericRuntimeCase).len, seen.count());
}

test "compound assignment uses the dedicated generic arrow window" {
    const source = "let seed = 1; seed += <T> (value)=>value;";
    var parser = try JsParser.initTyped(std.testing.allocator, std.testing.allocator, source);
    defer parser.deinit();
    _ = try parser.parse();
    try parser.type_store.validate();
    try std.testing.expectEqual(@as(usize, 1), parser.type_store.generic_owners.items.len);
    const owner = parser.type_store.generic_owners.items[0];
    const projected = parser.type_store.projectedGenericParameterSlice(owner.projected_parameters) orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 1), projected.len);
    try std.testing.expectEqualStrings("T", projected[0].name_span.text(source));
}

test "function arrow and call generic names use independent scopes" {
    const source =
        "const seed: number = 1; function outer<T>(value) { " ++
        "const inner=<T>(item)=>item; return inner<T>(value); }";
    var parser = try JsParser.initTyped(std.testing.allocator, std.testing.allocator, source);
    defer parser.deinit();
    _ = try parser.parse();
    try parser.type_store.validate();
    try std.testing.expectEqual(@as(usize, 2), parser.type_store.generic_owners.items.len);
    try std.testing.expectEqual(@as(usize, 1), parser.type_store.explicit_call_arguments.items.len);

    var pool = TypePool.init(std.testing.allocator);
    defer pool.deinit(std.testing.allocator);
    var env = TypeEnv.init(std.testing.allocator, &pool);
    defer env.deinit();
    const prior_nodes = pool.nodes.items.len;
    try lowerSyntaxStore(std.testing.allocator, &parser.type_store, &pool, &env, parserIrView(&parser));
    try std.testing.expectEqual(@as(usize, 0), env.generic_scopes.items.len);
    try std.testing.expectEqual(TypeTag.t_generic_param, pool.getTag(@intCast(prior_nodes)).?);
    try std.testing.expectEqual(TypeTag.t_generic_param, pool.getTag(@intCast(prior_nodes + 1)).?);
    try std.testing.expectEqualStrings("T", pool.getRefName(@intCast(prior_nodes)));
    try std.testing.expectEqualStrings("T", pool.getRefName(@intCast(prior_nodes + 1)));
    const call_paren = std.mem.indexOf(u8, source, "(value);") orelse
        return error.TestUnexpectedResult;
    const call = env.getCallTypeArgs(@intCast(call_paren)) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u8, 1), call.count);
    try std.testing.expectEqual(TypeTag.t_ref, pool.getTag(call.args[0]).?);
    try std.testing.expectEqualStrings("T", pool.getRefName(call.args[0]));
    try expectEquivalent(source);
}

test "nested explicit calls reserve outer records before value arguments" {
    const source = "const seed:number=1; const result=outer<string>(inner<number>(seed));";
    var parser = try JsParser.initTyped(std.testing.allocator, std.testing.allocator, source);
    defer parser.deinit();
    _ = try parser.parse();
    try parser.type_store.validate();
    try std.testing.expectEqual(@as(usize, 2), parser.type_store.explicit_call_arguments.items.len);

    const calls = parser.type_store.explicit_call_arguments.items;
    const outer = calls[0];
    const inner = calls[1];
    const view = parserIrView(&parser);
    const outer_lparen = std.mem.indexOf(u8, source, "(inner") orelse return error.TestUnexpectedResult;
    const inner_lparen = std.mem.indexOf(u8, source, "(seed)") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u32, @intCast(outer_lparen)), view.getLoc(outer.owner).?.offset);
    try std.testing.expectEqual(@as(u32, @intCast(inner_lparen)), view.getLoc(inner.owner).?.offset);
    try std.testing.expectEqual(@as(u32, 0), outer.authored_arguments.start);
    try std.testing.expectEqual(outer.authored_arguments.start + outer.authored_arguments.count, inner.authored_arguments.start);
    try std.testing.expectEqual(@as(u32, 0), outer.semantic_fragments.start);
    try std.testing.expectEqual(outer.semantic_fragments.start + outer.semantic_fragments.count, inner.semantic_fragments.start);
    const outer_fragment = parser.type_store.semantic_fragments.items[outer.semantic_fragments.start];
    const inner_fragment = parser.type_store.semantic_fragments.items[inner.semantic_fragments.start];
    try std.testing.expect(outer_fragment.node_range.start + outer_fragment.node_range.count <= inner_fragment.node_range.start);
    try parser.type_store.validateRuntimeOwners(std.testing.allocator, view);
    calls[0].owner = inner.owner;
    calls[1].owner = outer.owner;
    try std.testing.expectError(
        error.InvalidGenericOwner,
        parser.type_store.validateRuntimeOwners(std.testing.allocator, view),
    );
    calls[0].owner = outer.owner;
    calls[1].owner = inner.owner;
    var wrong_tag: ?NodeIndex = null;
    for (parser.nodes.tags.items, 0..) |tag, index| {
        if (tag == .var_decl) {
            wrong_tag = @intCast(index);
            break;
        }
    }
    calls[0].owner = wrong_tag orelse return error.TestUnexpectedResult;
    try std.testing.expectError(
        error.InvalidGenericOwner,
        parser.type_store.validateRuntimeOwners(std.testing.allocator, view),
    );
    calls[0].owner = outer.owner;
    try parser.type_store.validateRuntimeOwners(std.testing.allocator, view);

    var pool = TypePool.init(std.testing.allocator);
    defer pool.deinit(std.testing.allocator);
    var env = TypeEnv.init(std.testing.allocator, &pool);
    defer env.deinit();
    try lowerSyntaxStore(std.testing.allocator, &parser.type_store, &pool, &env, parserIrView(&parser));
    const lowered_outer = env.getCallTypeArgs(@intCast(outer_lparen)) orelse return error.TestUnexpectedResult;
    const lowered_inner = env.getCallTypeArgs(@intCast(inner_lparen)) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u8, 1), lowered_outer.count);
    try std.testing.expectEqual(@as(u8, 1), lowered_inner.count);
    try std.testing.expectEqual(pool.idx_string, lowered_outer.args[0]);
    try std.testing.expectEqual(pool.idx_number, lowered_inner.args[0]);
    try std.testing.expectEqual(@as(usize, 0), env.generic_scopes.items.len);
    try std.testing.expect(env.getFnSigByName("outer") == null);
    try std.testing.expect(env.getFnSigByName("inner") == null);
    try expectEquivalent(source);
}

test "nested generic arrows reserve outer owners before expression bodies" {
    const source = "const seed:number=1; const outer=<T extends string>(value)=><U extends number>(item)=>item;";
    var parser = try JsParser.initTyped(std.testing.allocator, std.testing.allocator, source);
    defer parser.deinit();
    _ = try parser.parse();
    try parser.type_store.validate();
    try std.testing.expectEqual(@as(usize, 2), parser.type_store.generic_owners.items.len);

    const outer = parser.type_store.generic_owners.items[0];
    const inner = parser.type_store.generic_owners.items[1];
    const outer_lparen = std.mem.indexOf(u8, source, "(value)") orelse return error.TestUnexpectedResult;
    const inner_lparen = std.mem.indexOf(u8, source, "(item)") orelse return error.TestUnexpectedResult;
    const view = parserIrView(&parser);
    const outer_identity = switch (outer.identity) {
        .arrow => |node| view.getLoc(node).?.offset,
        else => return error.TestUnexpectedResult,
    };
    const inner_identity = switch (inner.identity) {
        .arrow => |node| view.getLoc(node).?.offset,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(
        @as(u32, @intCast(outer_lparen)),
        outer_identity,
    );
    try std.testing.expectEqual(
        @as(u32, @intCast(inner_lparen)),
        inner_identity,
    );
    try std.testing.expectEqual(@as(u32, 0), outer.authored_parameters.start);
    try std.testing.expectEqual(outer.authored_parameters.start + outer.authored_parameters.count, inner.authored_parameters.start);
    try std.testing.expectEqual(@as(u32, 0), outer.projected_parameters.start);
    try std.testing.expectEqual(outer.projected_parameters.start + outer.projected_parameters.count, inner.projected_parameters.start);
    const outer_projected = parser.type_store.projected_generic_parameters.items[outer.projected_parameters.start];
    const inner_projected = parser.type_store.projected_generic_parameters.items[inner.projected_parameters.start];
    const outer_fragment = parser.type_store.semantic_fragments.items[
        outer_projected.bound_fragment orelse return error.TestUnexpectedResult
    ];
    const inner_fragment = parser.type_store.semantic_fragments.items[
        inner_projected.bound_fragment orelse return error.TestUnexpectedResult
    ];
    try std.testing.expect(outer_fragment.node_range.count > 0);
    try std.testing.expect(inner_fragment.node_range.count > 0);
    try std.testing.expect(outer_fragment.node_range.start + outer_fragment.node_range.count <= inner_fragment.node_range.start);

    var pool = TypePool.init(std.testing.allocator);
    defer pool.deinit(std.testing.allocator);
    var env = TypeEnv.init(std.testing.allocator, &pool);
    defer env.deinit();
    const prior_nodes = pool.nodes.items.len;
    try lowerSyntaxStore(std.testing.allocator, &parser.type_store, &pool, &env, parserIrView(&parser));
    try std.testing.expectEqual(TypeTag.t_generic_param, pool.getTag(@intCast(prior_nodes)).?);
    try std.testing.expectEqual(TypeTag.t_generic_param, pool.getTag(@intCast(prior_nodes + 1)).?);
    try std.testing.expectEqualStrings("T", pool.getRefName(@intCast(prior_nodes)));
    try std.testing.expectEqualStrings("U", pool.getRefName(@intCast(prior_nodes + 1)));
    try std.testing.expectEqual(@as(usize, 0), env.generic_scopes.items.len);
    try std.testing.expect(env.getFnSigByName("outer") == null);
}

test "explicit call applications instantiate the completed generic alias namespace" {
    const source =
        "const seed: number = 1;\nstructural Box<T> = { value: T };\n" ++
        "const id=<U>(value)=>value; const result=id<Box<number>>(seed);";
    var parser = try JsParser.initTyped(std.testing.allocator, std.testing.allocator, source);
    defer parser.deinit();
    _ = try parser.parse();
    try parser.type_store.validate();
    try std.testing.expectEqual(@as(usize, 1), parser.type_store.explicit_call_arguments.items.len);

    var pool = TypePool.init(std.testing.allocator);
    defer pool.deinit(std.testing.allocator);
    var env = TypeEnv.init(std.testing.allocator, &pool);
    defer env.deinit();
    try lowerSyntaxStore(std.testing.allocator, &parser.type_store, &pool, &env, parserIrView(&parser));
    const call_paren = std.mem.indexOf(u8, source, "(seed);") orelse
        return error.TestUnexpectedResult;
    const call = env.getCallTypeArgs(@intCast(call_paren)) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u8, 1), call.count);
    try std.testing.expectEqual(TypeTag.t_record, pool.getTag(call.args[0]).?);
    const fields = pool.getRecordFields(call.args[0]);
    try std.testing.expectEqual(@as(usize, 1), fields.len);
    try std.testing.expectEqualStrings(
        "value",
        pool.getName(fields[0].name_start, fields[0].name_len),
    );
    try std.testing.expectEqual(pool.idx_number, fields[0].type_idx);
    try expectEquivalent(source);
}

test "line comment arrows keep the whole-source preflight boundary" {
    const sources = [_][]const u8{
        "const seed: number = 1; const id = // note\n<T>(value: T): T => value;",
        "const seed: number = 1; const id = // note\n<T> (value: T): T => value;",
    };
    for (sources) |source| switch (try compare(std.testing.allocator, source, .collect)) {
        .out_of_slice => |reason| try std.testing.expectEqual(
            OutOfSliceReason.unsupported_initializer,
            reason,
        ),
        else => return error.TestUnexpectedResult,
    };

    var parser = try JsParser.initTyped(
        std.testing.allocator,
        std.testing.allocator,
        sources[1],
    );
    defer parser.deinit();
    try std.testing.expectError(error.UnexpectedToken, parser.parse());
    try std.testing.expectEqual(@as(usize, 0), parser.type_store.generic_owners.items.len);
    try std.testing.expectEqual(@as(usize, 0), parser.type_store.parameter_annotations.items.len);
    try std.testing.expectEqual(@as(usize, 0), parser.type_store.function_signatures.items.len);
    try parser.type_store.validate();
}

test "nested legacy-call line-comment arrow retains captures and semantic projection" {
    const source = "const id = // note\n<<T>>(value: T): T => value;";
    var runtime_count = CountingAllocator.init(std.testing.allocator);
    var type_count = CountingAllocator.init(std.testing.allocator);
    const runtime_allocator = runtime_count.allocator();
    var atoms = AtomTable.init(runtime_allocator);
    defer atoms.deinit();
    var parser = try JsParser.initTyped(runtime_allocator, type_count.allocator(), source);
    defer parser.deinit();
    parser.setAtomTable(&atoms);

    const root = try parser.parse();
    try expectRuntimeParityAndShape(source, &parser, root, &atoms, runtime_count);
    try expectTypedGenericArrowRecords(&parser, source, .{
        .list = "<<T>>",
        .actual_capture = "<<T>>",
        .legacy_capture = "<T>",
        .projected_name = "T",
        .compatibility = .legacy_call_arguments,
        .authored_argument = "<T>",
    });
}

test "comparison-shaped generic arrow candidates require explicit call grammar" {
    const sources = [_][]const u8{
        "const id = // word\n<T = string>(value: T): T => value;",
        "const id = // word\n<T || U>(value: T): T => value;",
        "const id = // word\n<T + U>(value: T): T => value;",
    };
    for (sources) |source| {
        var parser = try JsParser.initTyped(std.testing.allocator, std.testing.allocator, source);
        defer parser.deinit();
        try std.testing.expectError(error.UnexpectedToken, parser.parse());
        try std.testing.expectEqual(@as(usize, 0), parser.type_store.generic_parameters.items.len);
        try std.testing.expectEqual(
            @as(usize, 0),
            parser.type_store.projected_generic_parameters.items.len,
        );
        try std.testing.expectEqual(@as(usize, 0), parser.type_store.semantic_fragments.items.len);
        try std.testing.expectEqual(@as(usize, 0), parser.type_store.generic_owners.items.len);
        try std.testing.expectEqual(@as(usize, 0), parser.type_store.parameter_annotations.items.len);
        try std.testing.expectEqual(@as(usize, 0), parser.type_store.function_signatures.items.len);
        try std.testing.expectEqual(@as(usize, 0), parser.type_store.erased_type_prefixes.items.len);
        try parser.type_store.validate();
    }
    try std.testing.expectEqual(@as(usize, 3), sources.len);
}

test "generic arrow lookahead selects an outer arrow after a function return type" {
    const source = "const make=<T>(): (value: T) => T => (value: T): T => value;";
    var runtime_count = CountingAllocator.init(std.testing.allocator);
    const runtime_allocator = runtime_count.allocator();
    var atoms = AtomTable.init(runtime_allocator);
    defer atoms.deinit();
    var parser = try JsParser.initTyped(runtime_allocator, std.testing.allocator, source);
    defer parser.deinit();
    parser.setAtomTable(&atoms);
    const root = try parser.parse();
    try expectRuntimeParityAndShape(source, &parser, root, &atoms, runtime_count);

    const view = parserIrView(&parser);
    try parser.type_store.validateRuntimeOwners(std.testing.allocator, view);
    try std.testing.expectEqual(@as(usize, 1), parser.type_store.generic_owners.items.len);
    try std.testing.expectEqual(@as(usize, 2), parser.type_store.function_signatures.items.len);
    const outer = parser.type_store.function_signatures.items[0];
    const inner = parser.type_store.function_signatures.items[1];
    const owner = switch (parser.type_store.generic_owners.items[0].identity) {
        .arrow => |node| node,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(outer.owner, owner);
    try std.testing.expect(outer.owner != inner.owner);
    try std.testing.expect(outer.source_span.start < inner.source_span.start);
    const outer_return = outer.return_syntax orelse return error.TestUnexpectedResult;
    const outer_value = switch (outer_return.structure) {
        .value => |value| value,
        .predicate => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqualStrings("(value: T) => T ", outer_value.raw_span.text(source));
    const outer_root = parser.type_store.node(try syntaxChildIndex(outer_value.root)) orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqual(TypeSyntax.NodeTag.function, outer_root.tag);

    const missing_outer = "const make=<T>(): (value: T) => T;";
    var control = try JsParser.initTyped(
        std.testing.allocator,
        std.testing.allocator,
        missing_outer,
    );
    defer control.deinit();
    try std.testing.expectError(error.UnexpectedToken, control.parse());
    try std.testing.expectEqual(@as(usize, 0), control.type_store.generic_owners.items.len);
    try std.testing.expectEqual(@as(usize, 0), control.type_store.parameter_annotations.items.len);
    try std.testing.expectEqual(@as(usize, 0), control.type_store.function_signatures.items.len);
    try control.type_store.validate();
}

test "first runtime token generic arrows have a defined previous token" {
    const sources = [_][]const u8{
        "<T>(value)=>value;",
        "/* leading */ <T>(value)=>value;",
    };
    for (sources) |source| {
        var parser = try JsParser.initTyped(std.testing.allocator, std.testing.allocator, source);
        defer parser.deinit();
        _ = try parser.parse();
        try parser.type_store.validate();
        try std.testing.expectEqual(@as(usize, 1), parser.type_store.generic_owners.items.len);
        try std.testing.expectEqualStrings(
            "<T>",
            parser.type_store.generic_owners.items[0].list_span.text(source),
        );
    }
}

test "generic owner projection removes one pair from its recorded window" {
    const cases = [_]struct {
        source: []const u8,
        projected_name: ?[]const u8,
    }{
        .{ .source = "const seed:number=1; function identity<<T>>(value){return value;}", .projected_name = "T" },
        .{ .source = "const seed:number=1; const id=<<T>>(value)=>value;", .projected_name = "T" },
        .{ .source = "const seed:number=1; function identity<<>>(value){return value;}", .projected_name = null },
        .{ .source = "const seed:number=1; const id=<<>>(value)=>value;", .projected_name = null },
        .{ .source = "const seed:number=1;\nstructural Box<<T>> = number;", .projected_name = "<T>" },
    };
    var observed: usize = 0;
    for (cases) |case| {
        errdefer std.debug.print("generic owner window failed: {s}\n", .{case.source});
        var parser = try JsParser.initTyped(std.testing.allocator, std.testing.allocator, case.source);
        defer parser.deinit();
        _ = try parser.parse();
        try expectEquivalent(case.source);
        try parser.type_store.validate();
        try std.testing.expectEqual(@as(usize, 1), parser.type_store.generic_owners.items.len);
        const owner = parser.type_store.generic_owners.items[0];
        if (std.mem.indexOf(u8, case.source, "structural") != null) {
            try std.testing.expect(std.meta.eql(
                owner.list_span,
                owner.capture_spans.actual_erased_span,
            ));
            try std.testing.expect(std.meta.eql(
                owner.list_span,
                owner.capture_spans.legacy_recorded_span,
            ));
        }
        const projected = parser.type_store.projectedGenericParameterSlice(owner.projected_parameters) orelse
            return error.TestUnexpectedResult;
        const expected_count: usize = if (case.projected_name != null) 1 else 0;
        try std.testing.expectEqual(expected_count, projected.len);
        if (case.projected_name) |name| {
            try std.testing.expectEqualStrings(name, projected[0].name_span.text(case.source));
        }

        var pool = TypePool.init(std.testing.allocator);
        defer pool.deinit(std.testing.allocator);
        var env = TypeEnv.init(std.testing.allocator, &pool);
        defer env.deinit();
        const prior_nodes = pool.nodes.items.len;
        try lowerSyntaxStore(std.testing.allocator, &parser.type_store, &pool, &env, parserIrView(&parser));
        try std.testing.expectEqual(prior_nodes + expected_count, pool.nodes.items.len);
        if (case.projected_name) |name| {
            try std.testing.expectEqual(TypeTag.t_generic_param, pool.getTag(@intCast(prior_nodes)).?);
            try std.testing.expectEqualStrings(name, pool.getRefName(@intCast(prior_nodes)));
        }
        try std.testing.expectEqual(@as(usize, 0), env.generic_scopes.items.len);
        try std.testing.expectEqual(@as(u32, 0), env.fn_signatures.count());
        observed += 1;
    }
    try std.testing.expectEqual(@as(usize, 5), cases.len);
    try std.testing.expectEqual(cases.len, observed);
}

test "empty function owner lowering skips only a zero projected list" {
    const empty_source = "const id=<>()=>undefined;";
    var empty_parser = try JsParser.initTyped(
        std.testing.allocator,
        std.testing.allocator,
        empty_source,
    );
    defer empty_parser.deinit();
    _ = try empty_parser.parse();
    try empty_parser.type_store.validate();
    try std.testing.expectEqual(
        @as(u32, 0),
        empty_parser.type_store.generic_owners.items[0].projected_parameters.count,
    );

    var empty_pool = TypePool.init(std.testing.allocator);
    defer empty_pool.deinit(std.testing.allocator);
    var empty_failing = std.testing.FailingAllocator.init(
        std.testing.allocator,
        .{ .fail_index = 0 },
    );
    var empty_env = TypeEnv.init(std.testing.allocator, &empty_pool);
    defer empty_env.deinit();
    empty_env.generic_scopes.deinit(std.testing.allocator);
    empty_env.generic_scopes = .empty;
    empty_env.allocator = empty_failing.allocator();
    defer empty_env.allocator = std.testing.allocator;
    try lowerSyntaxStore(
        std.testing.allocator,
        &empty_parser.type_store,
        &empty_pool,
        &empty_env,
        parserIrView(&empty_parser),
    );
    try std.testing.expect(!empty_failing.has_induced_failure);
    try std.testing.expectEqual(@as(usize, 0), empty_failing.alloc_index);

    const compact_source = "const id=<=string>()=>undefined;";
    var compact_parser = try JsParser.initTyped(
        std.testing.allocator,
        std.testing.allocator,
        compact_source,
    );
    defer compact_parser.deinit();
    _ = try compact_parser.parse();
    try compact_parser.type_store.validate();
    const compact_owner = compact_parser.type_store.generic_owners.items[0];
    const compact_projected = compact_parser.type_store.projectedGenericParameterSlice(
        compact_owner.projected_parameters,
    ) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 1), compact_projected.len);
    try std.testing.expectEqualStrings("", compact_projected[0].name_span.text(compact_source));

    var compact_pool = TypePool.init(std.testing.allocator);
    defer compact_pool.deinit(std.testing.allocator);
    var compact_failing = std.testing.FailingAllocator.init(
        std.testing.allocator,
        .{ .fail_index = 0 },
    );
    var compact_env = TypeEnv.init(std.testing.allocator, &compact_pool);
    defer compact_env.deinit();
    compact_env.generic_scopes.deinit(std.testing.allocator);
    compact_env.generic_scopes = .empty;
    compact_env.allocator = compact_failing.allocator();
    defer compact_env.allocator = std.testing.allocator;
    try std.testing.expectError(
        error.OutOfMemory,
        lowerSyntaxStore(
            std.testing.allocator,
            &compact_parser.type_store,
            &compact_pool,
            &compact_env,
            parserIrView(&compact_parser),
        ),
    );
    try std.testing.expect(compact_failing.has_induced_failure);
    try std.testing.expectEqual(@as(usize, 0), compact_failing.alloc_index);
}

test "comparison-shaped return prefix remains outside private generic arrow coverage" {
    const source =
        "const seed: number = 1; function outer<T>(value) { return <U>(item)=>item; }";
    switch (try compare(std.testing.allocator, source, .collect)) {
        .out_of_slice => |reason| try std.testing.expectEqual(
            OutOfSliceReason.function_declaration,
            reason,
        ),
        else => return error.TestUnexpectedResult,
    }
}

test "explicit call depth exclusion does not fall back to comparison admission" {
    var source: std.ArrayListUnmanaged(u8) = .empty;
    defer source.deinit(std.testing.allocator);
    try source.appendSlice(std.testing.allocator, "const seed: number = 1; const result=id<");
    try source.appendNTimes(std.testing.allocator, '<', TypeSyntax.max_type_depth);
    try source.append(std.testing.allocator, 'T');
    try source.appendNTimes(std.testing.allocator, '>', TypeSyntax.max_type_depth + 1);
    try source.appendSlice(std.testing.allocator, "(seed);");
    switch (try compare(std.testing.allocator, source.items, .collect)) {
        .out_of_slice => |reason| try std.testing.expectEqual(
            OutOfSliceReason.unsupported_initializer,
            reason,
        ),
        else => return error.TestUnexpectedResult,
    }

    try expectEquivalent("const seed: number = 1; const result=seed << 1;");
}

test "function bounds stop at the compact legacy parameter count" {
    const source =
        "const seed: number = 1; function ignored<T, =string, U extends 1>() { return seed; }";
    var parser = try JsParser.initTyped(std.testing.allocator, std.testing.allocator, source);
    defer parser.deinit();
    _ = try parser.parse();
    try parser.type_store.validate();

    try std.testing.expectEqual(@as(usize, 1), parser.type_store.generic_owners.items.len);
    const owner = parser.type_store.generic_owners.items[0];
    const projected = parser.type_store.projectedGenericParameterSlice(owner.projected_parameters) orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 3), projected.len);
    try std.testing.expectEqualStrings("T", projected[0].name_span.text(source));
    try std.testing.expectEqualStrings("", projected[1].name_span.text(source));
    try std.testing.expectEqualStrings("U", projected[2].name_span.text(source));
    try std.testing.expectEqualStrings(
        "1",
        (projected[2].legacy_bound_span orelse return error.TestUnexpectedResult).text(source),
    );
    try std.testing.expect(projected[2].bound_fragment == null);
    try std.testing.expectEqual(@as(usize, 0), parser.type_store.semantic_fragments.items.len);

    var pool = TypePool.init(std.testing.allocator);
    defer pool.deinit(std.testing.allocator);
    var env = TypeEnv.init(std.testing.allocator, &pool);
    defer env.deinit();
    const prior_nodes = pool.nodes.items.len;
    try lowerSyntaxStore(std.testing.allocator, &parser.type_store, &pool, &env, parserIrView(&parser));
    try std.testing.expectEqual(prior_nodes + 2, pool.nodes.items.len);
    try std.testing.expectEqual(TypeTag.t_generic_param, pool.getTag(@intCast(prior_nodes)).?);
    try std.testing.expectEqual(TypeTag.t_generic_param, pool.getTag(@intCast(prior_nodes + 1)).?);
    try std.testing.expectEqualStrings("T", pool.getRefName(@intCast(prior_nodes)));
    try std.testing.expectEqualStrings("U", pool.getRefName(@intCast(prior_nodes + 1)));
    try expectEquivalent(source);

    const unsupported =
        "const seed: number = 1; function ignored<T, =string, U extends ?>() { return seed; }";
    var unsupported_parser = try JsParser.initTyped(
        std.testing.allocator,
        std.testing.allocator,
        unsupported,
    );
    defer unsupported_parser.deinit();
    _ = try unsupported_parser.parse();
    try unsupported_parser.type_store.validate();
    const unsupported_owner = unsupported_parser.type_store.generic_owners.items[0];
    const unsupported_projected = unsupported_parser.type_store.projectedGenericParameterSlice(
        unsupported_owner.projected_parameters,
    ) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings(
        "?",
        (unsupported_projected[2].legacy_bound_span orelse return error.TestUnexpectedResult).text(unsupported),
    );
    try std.testing.expect(unsupported_projected[2].bound_fragment == null);
    try std.testing.expectEqual(@as(usize, 0), unsupported_parser.type_store.semantic_fragments.items.len);
}

test "recovered generic function body error removes its owner and retains earlier syntax" {
    const source =
        "const seed: number = 1; function identity<T>(value) { const broken = ; return value; }";
    var parser = try JsParser.initTyped(std.testing.allocator, std.testing.allocator, source);
    defer parser.deinit();
    try std.testing.expectError(error.ParseError, parser.parse());
    try std.testing.expectEqual(@as(usize, 1), parser.type_store.annotations.items.len);
    try std.testing.expectEqual(@as(usize, 0), parser.type_store.generic_parameters.items.len);
    try std.testing.expectEqual(@as(usize, 0), parser.type_store.projected_generic_parameters.items.len);
    try std.testing.expectEqual(@as(usize, 0), parser.type_store.semantic_fragments.items.len);
    try std.testing.expectEqual(@as(usize, 0), parser.type_store.generic_owners.items.len);
    try parser.type_store.validate();

    var pool = TypePool.init(std.testing.allocator);
    defer pool.deinit(std.testing.allocator);
    var env = TypeEnv.init(std.testing.allocator, &pool);
    defer env.deinit();
    try lowerSyntaxStore(std.testing.allocator, &parser.type_store, &pool, &env, parserIrView(&parser));
    const annotation = parser.type_store.annotations.items[0];
    try std.testing.expectEqual(
        pool.idx_number,
        env.getVarTypeByBinding(annotation.binding.scope_id, annotation.binding.name_atom) orelse
            return error.TestUnexpectedResult,
    );
}

test "recovered generic arrow wrappers remove current and nested type syntax" {
    const sources = [_][]const u8{
        "const seed: number = 1; " ++
            "const id=<T>(value: T): T => { " ++
            "const nested=<U>(item: U): U => item; const broken = ; return value; }; " ++
            "const after = 2;",
        "const seed: number = 1; " ++
            "export const id=<T>(value: T): T => { " ++
            "const nested=<U>(item: U): U => item; const broken = ; return value; }; " ++
            "const after = 2;",
    };
    for (sources) |source| {
        const broken = std.mem.indexOf(u8, source, "const broken = ; ") orelse
            return error.TestUnexpectedResult;
        const control_source = try std.mem.concat(
            std.testing.allocator,
            u8,
            &.{ source[0..broken], source[broken + "const broken = ; ".len ..] },
        );
        defer std.testing.allocator.free(control_source);
        var runtime_count = CountingAllocator.init(std.testing.allocator);
        const runtime_allocator = runtime_count.allocator();
        var control_atoms = AtomTable.init(runtime_allocator);
        defer control_atoms.deinit();
        var control = try JsParser.initTyped(runtime_allocator, std.testing.allocator, control_source);
        defer control.deinit();
        control.setAtomTable(&control_atoms);
        const control_root = try control.parse();
        try expectRuntimeParityAndShape(
            control_source,
            &control,
            control_root,
            &control_atoms,
            runtime_count,
        );
        try std.testing.expectEqual(@as(usize, 2), control.type_store.generic_owners.items.len);
        try std.testing.expectEqual(@as(usize, 2), control.type_store.function_signatures.items.len);
        try control.type_store.validateRuntimeOwners(std.testing.allocator, parserIrView(&control));

        var parser = try JsParser.initTyped(std.testing.allocator, std.testing.allocator, source);
        defer parser.deinit();
        try std.testing.expectError(error.ParseError, parser.parse());
        try std.testing.expectEqual(TokenType.eof, parser.current.type);
        try std.testing.expectEqual(@as(u16, 0), parser.scopes.current_scope);
        try expectStoreCheckpoint(&parser.type_store, seedCheckpoint());
        try parser.type_store.validate();
        const view = parserIrView(&parser);
        const after_offset = std.mem.indexOf(u8, source, "const after") orelse
            return error.TestUnexpectedResult;
        const outer_opener = std.mem.indexOf(u8, source, "(value") orelse
            return error.TestUnexpectedResult;
        var after_node: ?NodeIndex = null;
        var outer_node: ?NodeIndex = null;
        for (parser.nodes.tags.items, parser.nodes.locs.items, 0..) |tag, loc, index| {
            if (tag == .var_decl and loc.offset == after_offset) {
                try std.testing.expect(after_node == null);
                after_node = @intCast(index);
            }
            if (tag == .arrow_function and loc.offset == outer_opener) {
                try std.testing.expect(outer_node == null);
                outer_node = @intCast(index);
            }
        }
        try std.testing.expect(after_node != null);
        const outer = view.getFunction(outer_node orelse return error.TestUnexpectedResult) orelse
            return error.TestUnexpectedResult;
        try std.testing.expectEqual(engine.parser.NodeTag.block, view.getTag(outer.body).?);
        const body = view.getBlock(outer.body) orelse return error.TestUnexpectedResult;
        try std.testing.expect(body.stmts_count > 0);
        const retained_return = view.getListIndex(body.stmts_start, body.stmts_count - 1);
        try std.testing.expectEqual(engine.parser.NodeTag.return_stmt, view.getTag(retained_return).?);
        try std.testing.expectEqual(
            @as(u32, @intCast(std.mem.indexOf(u8, source, "return value").?)),
            view.getLoc(retained_return).?.offset,
        );
    }
}

test "enclosing expression transactions remove completed nested calls" {
    const prefix =
        "const seed: number=1; const id=<T>(value)=>value; " ++
        "const prior=id<number>(seed); ";
    const tails = [_][]const u8{
        "outer(inner<string>(seed), ;",
        "inner<string>(seed) + ;",
    };
    for (tails) |tail| {
        const source = try std.mem.concat(std.testing.allocator, u8, &.{ prefix, tail });
        defer std.testing.allocator.free(source);
        var parser = try JsParser.initTyped(std.testing.allocator, std.testing.allocator, source);
        defer parser.deinit();
        try std.testing.expectError(error.UnexpectedToken, parser.parse());
        try std.testing.expectEqual(TokenType.semicolon, parser.current.type);
        try std.testing.expectEqual(@as(usize, 1), parser.type_store.annotations.items.len);
        try std.testing.expectEqual(@as(usize, 1), parser.type_store.generic_owners.items.len);
        try std.testing.expectEqual(@as(usize, 1), parser.type_store.explicit_call_arguments.items.len);
        try std.testing.expectEqual(@as(usize, 1), parser.type_store.authored_call_arguments.items.len);
        try std.testing.expectEqual(@as(usize, 1), parser.type_store.semantic_fragments.items.len);
        const retained = parser.type_store.explicit_call_arguments.items[0];
        try std.testing.expectEqualStrings("<number>", retained.list_span.text(source));
        try parser.type_store.validate();
    }
}

const FinalNodeRollbackCase = struct {
    source: []const u8,
    target_tag: engine.parser.NodeTag,
    target_offset: u32,
    control_annotations: usize = 1,
    control_owners: usize,
    control_calls: usize,
    control_signatures: usize = 0,
    control_prefixes: usize = 0,
    retained_nodes: usize = 2,
    retained_owners: usize = 1,
    retained_generic_parameters: usize = 1,
    retained_projected_parameters: usize = 1,
    retained_calls: usize = 1,
    retained_call_arguments: usize = 1,
    retained_fragments: usize = 1,
    retained_parameter_annotations: usize = 0,
    retained_signatures: usize = 0,
    retained_prefixes: usize = 0,
    retained_checkpoint: ?TypeSyntax.Store.Checkpoint = null,
    runtime_parity: bool = false,
    expected_current: union(enum) {
        eof,
        token: struct { kind: TokenType, location: engine.parser.SourceLocation },
    } = .eof,
};

fn expectFinalNodeAllocationRollback(case: FinalNodeRollbackCase) !void {
    var control_atoms = AtomTable.init(std.testing.allocator);
    defer control_atoms.deinit();
    var control = try JsParser.initTyped(std.testing.allocator, std.testing.allocator, case.source);
    defer control.deinit();
    if (case.runtime_parity) control.setAtomTable(&control_atoms);
    const control_root = try control.parse();
    if (case.runtime_parity) {
        try expectFunctionSliceRuntimeParity(
            std.testing.allocator,
            case.source,
            &control,
            control_root,
            &control_atoms,
        );
    }
    try control.type_store.validate();
    try control.type_store.validateRuntimeOwners(
        std.testing.allocator,
        parserIrView(&control),
    );
    try std.testing.expectEqual(case.control_annotations, control.type_store.annotations.items.len);
    try std.testing.expectEqual(case.control_owners, control.type_store.generic_owners.items.len);
    try std.testing.expectEqual(case.control_calls, control.type_store.explicit_call_arguments.items.len);
    try std.testing.expectEqual(case.control_signatures, control.type_store.function_signatures.items.len);
    try std.testing.expectEqual(case.control_prefixes, control.type_store.erased_type_prefixes.items.len);
    try std.testing.expect(case.control_annotations > 1 or case.control_owners > 1 or
        case.control_calls > 1 or
        case.control_signatures > 0 or case.control_prefixes > 0);

    var target_index: ?usize = null;
    var target_count: usize = 0;
    for (control.nodes.tags.items, control.nodes.locs.items, 0..) |tag, loc, index| {
        if (tag == case.target_tag and loc.offset == case.target_offset) {
            target_index = index;
            target_count += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 1), target_count);
    const target = target_index orelse return error.TestUnexpectedResult;

    var parser_atoms = AtomTable.init(std.testing.allocator);
    defer parser_atoms.deinit();
    var parser = try JsParser.initTyped(std.testing.allocator, std.testing.allocator, case.source);
    defer parser.deinit();
    if (case.runtime_parity) parser.setAtomTable(&parser_atoms);
    const stable_node_allocator = parser.nodes.allocator;
    const node_capacity = parser.nodes.tags.capacity;
    try std.testing.expect(node_capacity >= target);
    try parser.nodes.locs.ensureTotalCapacity(stable_node_allocator, node_capacity);
    try parser.nodes.data.ensureTotalCapacity(stable_node_allocator, node_capacity);
    try parser.nodes.binding_name_atoms.ensureTotalCapacity(stable_node_allocator, node_capacity);
    try parser.nodes.extra.ensureTotalCapacity(stable_node_allocator, control.nodes.extra.items.len);
    try parser.nodes.index_lists.ensureTotalCapacity(
        stable_node_allocator,
        control.nodes.index_lists.items.len,
    );
    const filler_count = node_capacity - target;
    const filler_loc: engine.parser.SourceLocation = .{
        .line = 1,
        .column = 1,
        .offset = 0,
    };
    for (0..filler_count) |_| {
        _ = try parser.nodes.add(engine.parser.Node.litUndefined(filler_loc));
    }

    var failing = std.testing.FailingAllocator.init(
        std.testing.allocator,
        .{ .fail_index = 0 },
    );
    failing.resize_fail_index = 0;
    parser.nodes.allocator = failing.allocator();
    defer parser.nodes.allocator = stable_node_allocator;
    try std.testing.expectError(error.OutOfMemory, parser.parse());
    parser.nodes.allocator = stable_node_allocator;
    try std.testing.expect(failing.has_induced_failure);
    try std.testing.expectEqual(@as(usize, 0), failing.alloc_index);
    try std.testing.expectEqual(node_capacity, parser.nodes.tags.items.len);
    try std.testing.expectEqual(node_capacity, parser.nodes.locs.items.len);
    try std.testing.expectEqual(node_capacity, parser.nodes.data.items.len);
    try std.testing.expectEqual(node_capacity, parser.nodes.binding_name_atoms.items.len);
    try std.testing.expectEqual(target, parser.nodes.tags.items[filler_count..].len);
    for (
        control.nodes.tags.items[0..target],
        control.nodes.locs.items[0..target],
        parser.nodes.tags.items[filler_count..],
        parser.nodes.locs.items[filler_count..],
    ) |expected_tag, expected_loc, actual_tag, actual_loc| {
        try std.testing.expectEqual(expected_tag, actual_tag);
        try std.testing.expect(std.meta.eql(expected_loc, actual_loc));
    }
    try std.testing.expectEqual(case.target_tag, control.nodes.tags.items[target]);
    try std.testing.expectEqual(case.target_offset, control.nodes.locs.items[target].offset);
    switch (case.expected_current) {
        .eof => {
            try std.testing.expectEqual(TokenType.eof, parser.current.type);
            try std.testing.expectEqual(@as(u32, @intCast(case.source.len)), parser.current.start);
        },
        .token => |expected| {
            try std.testing.expectEqual(expected.kind, parser.current.type);
            try std.testing.expect(std.meta.eql(expected.location, parser.current.location()));
        },
    }
    try std.testing.expectEqual(@as(u16, 0), parser.scopes.current_scope);

    try std.testing.expectEqual(case.retained_nodes, parser.type_store.nodes.items.len);
    try std.testing.expectEqual(@as(usize, 1), parser.type_store.annotations.items.len);
    try std.testing.expectEqual(case.retained_owners, parser.type_store.generic_owners.items.len);
    try std.testing.expectEqual(case.retained_generic_parameters, parser.type_store.generic_parameters.items.len);
    try std.testing.expectEqual(case.retained_projected_parameters, parser.type_store.projected_generic_parameters.items.len);
    try std.testing.expectEqual(case.retained_calls, parser.type_store.explicit_call_arguments.items.len);
    try std.testing.expectEqual(case.retained_call_arguments, parser.type_store.authored_call_arguments.items.len);
    try std.testing.expectEqual(case.retained_fragments, parser.type_store.semantic_fragments.items.len);
    try std.testing.expectEqual(
        case.retained_parameter_annotations,
        parser.type_store.parameter_annotations.items.len,
    );
    try std.testing.expectEqual(case.retained_signatures, parser.type_store.function_signatures.items.len);
    try std.testing.expectEqual(case.retained_prefixes, parser.type_store.erased_type_prefixes.items.len);
    if (case.retained_checkpoint) |checkpoint| {
        try expectStoreCheckpoint(&parser.type_store, checkpoint);
    }
    if (case.retained_owners > 0) {
        try std.testing.expectEqualStrings(
            "<P>",
            parser.type_store.generic_owners.items[0].list_span.text(case.source),
        );
    }
    if (case.retained_calls > 0) {
        try std.testing.expectEqualStrings(
            "<number>",
            parser.type_store.explicit_call_arguments.items[0].list_span.text(case.source),
        );
    }
    try parser.type_store.validateRuntimeOwners(
        std.testing.allocator,
        parserIrView(&parser),
    );
}

test "final wrapper node allocation removes only current generic records" {
    const prefix =
        "const seed: number = 1; const priorId=<P>(value)=>value; " ++
        "const prior=priorId<number>(seed); ";
    const variable_source = prefix ++ "const id=<T>(value)=>value;";
    const export_source = prefix ++ "export const result=priorId<string>(seed);";
    const expression_source = prefix ++ "priorId<string>(seed);";
    try expectFinalNodeAllocationRollback(.{
        .source = variable_source,
        .target_tag = .var_decl,
        .target_offset = @intCast(std.mem.lastIndexOf(u8, variable_source, "const id").?),
        .control_owners = 2,
        .control_calls = 1,
    });
    try expectFinalNodeAllocationRollback(.{
        .source = export_source,
        .target_tag = .export_decl,
        .target_offset = @intCast(std.mem.indexOf(u8, export_source, "export").?),
        .control_owners = 1,
        .control_calls = 2,
    });
    try expectFinalNodeAllocationRollback(.{
        .source = expression_source,
        .target_tag = .expr_stmt,
        .target_offset = @intCast(std.mem.lastIndexOf(u8, expression_source, "priorId<string>").?),
        .control_owners = 1,
        .control_calls = 2,
    });
}

test "function and declaration node allocation failures remove pending signatures" {
    const source =
        "const seed: number = 1;\n" ++
        "function identity(value: string): string { return value; }\n";
    const function_offset = std.mem.indexOf(u8, source, "function") orelse
        return error.TestUnexpectedResult;
    const parameter_offset = std.mem.indexOf(u8, source, "(value") orelse
        return error.TestUnexpectedResult;
    const common = FinalNodeRollbackCase{
        .source = source,
        .target_tag = .function_expr,
        .target_offset = @intCast(parameter_offset),
        .control_owners = 0,
        .control_calls = 0,
        .control_signatures = 1,
        .retained_nodes = 1,
        .retained_owners = 0,
        .retained_generic_parameters = 0,
        .retained_projected_parameters = 0,
        .retained_calls = 0,
        .retained_call_arguments = 0,
        .retained_fragments = 0,
    };
    try expectFinalNodeAllocationRollback(common);
    var wrapper = common;
    wrapper.target_tag = .function_decl;
    wrapper.target_offset = @intCast(function_offset);
    try expectFinalNodeAllocationRollback(wrapper);
}

test "named function comment node failures remove pending compatibility owners" {
    const prefix =
        "const seed: number = 1; const priorId=<P>(value)=>value; " ++
        "const prior=priorId<number>(seed); ";
    const sources = [_][]const u8{
        prefix ++ "function /* note */ identity<T>(value) { return value; }",
        prefix ++ "function identity<T>/* note */(value) { return value; }",
    };
    for (sources) |source| {
        const common = FinalNodeRollbackCase{
            .source = source,
            .target_tag = .function_expr,
            .target_offset = @intCast(std.mem.lastIndexOf(u8, source, "(value)") orelse
                return error.TestUnexpectedResult),
            .control_owners = 2,
            .control_calls = 1,
            .runtime_parity = true,
        };
        try expectFinalNodeAllocationRollback(common);
        var wrapper = common;
        wrapper.target_tag = .function_decl;
        wrapper.target_offset = @intCast(std.mem.lastIndexOf(u8, source, "function") orelse
            return error.TestUnexpectedResult);
        try expectFinalNodeAllocationRollback(wrapper);
    }
    try std.testing.expectEqual(@as(usize, 2), sources.len);
}

test "arrow and wrapper allocation failures restore all header arrays" {
    const variable_source =
        "const seed: number = 1;\n" ++
        "const guard = (candidate, marker: unknown): candidate is string => typeof candidate === \"string\";";
    const export_source =
        "const seed: number = 1;\n" ++
        "export const guard = (candidate, marker: unknown): candidate is string => typeof candidate === \"string\";";
    const final_semicolon = std.mem.lastIndexOfScalar(u8, variable_source, ';').?;
    const last_newline = std.mem.lastIndexOfScalar(u8, variable_source, '\n').?;
    const common = FinalNodeRollbackCase{
        .source = variable_source,
        .target_tag = .arrow_function,
        .target_offset = @intCast(std.mem.indexOf(u8, variable_source, "(candidate").?),
        .control_owners = 0,
        .control_calls = 0,
        .control_signatures = 1,
        .retained_nodes = 1,
        .retained_owners = 0,
        .retained_generic_parameters = 0,
        .retained_projected_parameters = 0,
        .retained_calls = 0,
        .retained_call_arguments = 0,
        .retained_fragments = 0,
        .retained_checkpoint = seedCheckpoint(),
        .runtime_parity = true,
        .expected_current = .{ .token = .{
            .kind = .semicolon,
            .location = .{
                .offset = @intCast(final_semicolon),
                .end_offset = @intCast(final_semicolon + 1),
                .line = 2,
                .column = @intCast(final_semicolon - last_newline),
            },
        } },
    };
    try expectFinalNodeAllocationRollback(common);

    var variable = common;
    variable.target_tag = .var_decl;
    variable.target_offset = @intCast(std.mem.indexOf(u8, variable_source, "const guard").?);
    variable.expected_current = .eof;
    try expectFinalNodeAllocationRollback(variable);

    var export_wrapper = common;
    export_wrapper.source = export_source;
    export_wrapper.target_tag = .export_decl;
    export_wrapper.target_offset = @intCast(std.mem.indexOf(u8, export_source, "export").?);
    export_wrapper.expected_current = .eof;
    try expectFinalNodeAllocationRollback(export_wrapper);
}

test "typed generic arrow final node failures restore owner and signature arrays" {
    const variable_source =
        "const seed: number = 1;\n" ++
        "const id=<T>(value: T): T => value;";
    const export_source =
        "const seed: number = 1;\n" ++
        "export const id=<T>(value: T): T => value;";
    const final_semicolon = std.mem.lastIndexOfScalar(u8, variable_source, ';').?;
    const last_newline = std.mem.lastIndexOfScalar(u8, variable_source, '\n').?;
    const common = FinalNodeRollbackCase{
        .source = variable_source,
        .target_tag = .arrow_function,
        .target_offset = @intCast(std.mem.indexOf(u8, variable_source, "(value").?),
        .control_owners = 1,
        .control_calls = 0,
        .control_signatures = 1,
        .retained_nodes = 1,
        .retained_owners = 0,
        .retained_generic_parameters = 0,
        .retained_projected_parameters = 0,
        .retained_calls = 0,
        .retained_call_arguments = 0,
        .retained_fragments = 0,
        .retained_parameter_annotations = 0,
        .retained_signatures = 0,
        .retained_checkpoint = seedCheckpoint(),
        .runtime_parity = true,
        .expected_current = .{ .token = .{
            .kind = .semicolon,
            .location = .{
                .offset = @intCast(final_semicolon),
                .end_offset = @intCast(final_semicolon + 1),
                .line = 2,
                .column = @intCast(final_semicolon - last_newline),
            },
        } },
    };
    try expectFinalNodeAllocationRollback(common);

    var variable = common;
    variable.target_tag = .var_decl;
    variable.target_offset = @intCast(std.mem.indexOf(u8, variable_source, "const id").?);
    variable.expected_current = .eof;
    try expectFinalNodeAllocationRollback(variable);

    var export_wrapper = common;
    export_wrapper.source = export_source;
    export_wrapper.target_tag = .export_decl;
    export_wrapper.target_offset = @intCast(std.mem.indexOf(u8, export_source, "export").?);
    export_wrapper.expected_current = .eof;
    try expectFinalNodeAllocationRollback(export_wrapper);
}

test "erased object prefix node failures restore every store array" {
    const variable_source =
        "const seed: number = 1;\n" ++
        "const value = <T>{ id: 1 };";
    const export_source =
        "const seed: number = 1;\n" ++
        "export const value = <T>{ id: 1 };";
    const final_semicolon = std.mem.lastIndexOfScalar(u8, variable_source, ';').?;
    const last_newline = std.mem.lastIndexOfScalar(u8, variable_source, '\n').?;
    const common = FinalNodeRollbackCase{
        .source = variable_source,
        .target_tag = .object_literal,
        .target_offset = @intCast(std.mem.indexOfScalar(u8, variable_source, '{').?),
        .control_owners = 0,
        .control_calls = 0,
        .control_prefixes = 1,
        .retained_nodes = 1,
        .retained_owners = 0,
        .retained_generic_parameters = 0,
        .retained_projected_parameters = 0,
        .retained_calls = 0,
        .retained_call_arguments = 0,
        .retained_fragments = 0,
        .retained_parameter_annotations = 0,
        .retained_signatures = 0,
        .retained_prefixes = 0,
        .retained_checkpoint = seedCheckpoint(),
        .runtime_parity = true,
        .expected_current = .{ .token = .{
            .kind = .semicolon,
            .location = .{
                .offset = @intCast(final_semicolon),
                .end_offset = @intCast(final_semicolon + 1),
                .line = 2,
                .column = @intCast(final_semicolon - last_newline),
            },
        } },
    };
    try expectFinalNodeAllocationRollback(common);

    var variable = common;
    variable.target_tag = .var_decl;
    variable.target_offset = @intCast(std.mem.indexOf(u8, variable_source, "const value").?);
    variable.expected_current = .eof;
    try expectFinalNodeAllocationRollback(variable);

    var export_wrapper = common;
    export_wrapper.source = export_source;
    export_wrapper.target_tag = .export_decl;
    export_wrapper.target_offset = @intCast(std.mem.indexOf(u8, export_source, "export").?);
    export_wrapper.expected_current = .eof;
    try expectFinalNodeAllocationRollback(export_wrapper);
}

test "diagnostic allocation failure removes arrow and call records from wrappers" {
    const prefix =
        "const seed: number = 1; const priorId=<P>(value)=>value; " ++
        "const prior=priorId<number>(seed); ";
    const Fixture = struct {
        tail: []const u8,
        control_owners: usize,
        control_calls: usize,
    };
    const fixtures = [_]Fixture{
        .{ .tail = "const id=<T>(value)=>value", .control_owners = 2, .control_calls = 1 },
        .{ .tail = "export const id=<T>(value)=>value", .control_owners = 2, .control_calls = 1 },
        .{ .tail = "const result=priorId<string>(seed)", .control_owners = 1, .control_calls = 2 },
        .{ .tail = "export const result=priorId<string>(seed)", .control_owners = 1, .control_calls = 2 },
    };
    for (fixtures) |fixture| {
        const failing_source = try std.mem.concat(std.testing.allocator, u8, &.{ prefix, fixture.tail });
        defer std.testing.allocator.free(failing_source);
        const successful_source = try std.mem.concat(
            std.testing.allocator,
            u8,
            &.{ failing_source, ";" },
        );
        defer std.testing.allocator.free(successful_source);

        var control = try JsParser.initTyped(
            std.testing.allocator,
            std.testing.allocator,
            successful_source,
        );
        defer control.deinit();
        _ = try control.parse();
        try control.type_store.validate();
        try std.testing.expectEqual(fixture.control_owners, control.type_store.generic_owners.items.len);
        try std.testing.expectEqual(fixture.control_calls, control.type_store.explicit_call_arguments.items.len);
        try std.testing.expect(control.type_store.generic_parameters.items.len > 0);
        try std.testing.expect(control.type_store.projected_generic_parameters.items.len > 0);
        try std.testing.expect(control.type_store.authored_call_arguments.items.len > 0);
        try std.testing.expect(control.type_store.semantic_fragments.items.len > 0);

        var parser = try JsParser.initTyped(
            std.testing.allocator,
            std.testing.allocator,
            failing_source,
        );
        defer parser.deinit();
        const stable_error_allocator = parser.errors.allocator;
        var failing = std.testing.FailingAllocator.init(
            std.testing.allocator,
            .{ .fail_index = 0 },
        );
        parser.errors.allocator = failing.allocator();
        defer parser.errors.allocator = stable_error_allocator;
        try std.testing.expectError(error.OutOfMemory, parser.parse());
        parser.errors.allocator = stable_error_allocator;
        try std.testing.expect(failing.has_induced_failure);
        try std.testing.expectEqual(@as(usize, 0), failing.alloc_index);
        try std.testing.expectEqual(@as(usize, 0), parser.errors.getErrors().len);
        try std.testing.expect(parser.errors.outOfMemory());
        try std.testing.expectEqual(TokenType.eof, parser.current.type);
        try std.testing.expectEqual(@as(usize, 1), parser.type_store.annotations.items.len);
        try std.testing.expectEqual(@as(usize, 1), parser.type_store.generic_owners.items.len);
        try std.testing.expectEqual(@as(usize, 1), parser.type_store.generic_parameters.items.len);
        try std.testing.expectEqual(@as(usize, 1), parser.type_store.projected_generic_parameters.items.len);
        try std.testing.expectEqual(@as(usize, 1), parser.type_store.explicit_call_arguments.items.len);
        try std.testing.expectEqual(@as(usize, 1), parser.type_store.authored_call_arguments.items.len);
        try std.testing.expectEqual(@as(usize, 1), parser.type_store.semantic_fragments.items.len);
        try std.testing.expectEqualStrings(
            "<P>",
            parser.type_store.generic_owners.items[0].list_span.text(failing_source),
        );
        try std.testing.expectEqualStrings(
            "<number>",
            parser.type_store.explicit_call_arguments.items[0].list_span.text(failing_source),
        );
        try parser.type_store.validate();
    }
}

test "failed explicit call retains an earlier generic arrow owner" {
    const source =
        "const seed: number = 1; const id=<T>(value)=>value; " ++
        "const result=id<string>(;";
    var parser = try JsParser.initTyped(std.testing.allocator, std.testing.allocator, source);
    defer parser.deinit();
    try std.testing.expectError(error.UnexpectedToken, parser.parse());
    try std.testing.expectEqual(@as(usize, 1), parser.type_store.annotations.items.len);
    try std.testing.expectEqual(@as(usize, 1), parser.type_store.generic_owners.items.len);
    try std.testing.expectEqual(@as(usize, 1), parser.type_store.generic_parameters.items.len);
    try std.testing.expectEqual(@as(usize, 1), parser.type_store.projected_generic_parameters.items.len);
    try std.testing.expectEqual(@as(usize, 0), parser.type_store.authored_call_arguments.items.len);
    try std.testing.expectEqual(@as(usize, 0), parser.type_store.explicit_call_arguments.items.len);
    try parser.type_store.validate();
}

test "generic function publication rejects a swallowed diagnostic allocation failure" {
    const source =
        "const seed: number = 1; function identity<T>(value) { const broken; return value; }";
    var parser = try JsParser.initTyped(std.testing.allocator, std.testing.allocator, source);
    defer parser.deinit();
    const stable_error_allocator = parser.errors.allocator;
    var failing = std.testing.FailingAllocator.init(
        std.testing.allocator,
        .{ .fail_index = 0 },
    );
    parser.errors.allocator = failing.allocator();
    defer parser.errors.allocator = stable_error_allocator;

    try std.testing.expectError(error.OutOfMemory, parser.parse());
    try std.testing.expect(failing.has_induced_failure);
    try std.testing.expectEqual(@as(usize, 0), parser.errors.getErrors().len);
    try std.testing.expect(parser.errors.outOfMemory());
    try std.testing.expectEqual(@as(usize, 1), parser.type_store.annotations.items.len);
    try std.testing.expectEqual(@as(usize, 0), parser.type_store.generic_parameters.items.len);
    try std.testing.expectEqual(@as(usize, 0), parser.type_store.projected_generic_parameters.items.len);
    try std.testing.expectEqual(@as(usize, 0), parser.type_store.semantic_fragments.items.len);
    try std.testing.expectEqual(@as(usize, 0), parser.type_store.generic_owners.items.len);
    try parser.type_store.validate();
}

test "generic parameter projection retains legacy u32 depth arithmetic" {
    var source: std.ArrayListUnmanaged(u8) = .empty;
    defer source.deinit(std.testing.allocator);
    try source.appendSlice(std.testing.allocator, "structural Box<\"");
    try source.appendNTimes(std.testing.allocator, '<', 65_536);
    try source.appendNTimes(std.testing.allocator, '>', 65_535);
    try source.appendSlice(
        std.testing.allocator,
        "\"> = number;\nconst value: Box<> = undefined;",
    );

    var parser = try JsParser.initTyped(std.testing.allocator, std.testing.allocator, source.items);
    defer parser.deinit();
    _ = try parser.parse();
    try parser.type_store.validate();
    const owner = parser.type_store.generic_owners.items[0];
    try std.testing.expectEqual(@as(u32, 1), owner.authored_parameters.count);
    try std.testing.expectEqual(@as(u32, 0), owner.projected_parameters.count);
    try expectEquivalent(source.items);
}

test "generic list private exclusions retain legacy diagnostics and regex defaults" {
    const sources = [_][]const u8{
        "structural Box<T = (\"x\n)> = number;\nconst value: Box<string> = undefined;",
        "structural Box<T = /x> = number; /* tail */\nconst value: Box<string> = undefined;",
    };
    for (sources) |source| switch (try compare(std.testing.allocator, source, .collect)) {
        .out_of_slice => |reason| try std.testing.expectEqual(OutOfSliceReason.type_declaration, reason),
        else => return error.TestUnexpectedResult,
    };
}

test "generic semantic fragment census observes every case" {
    try std.testing.expectEqual(std.meta.fields(GenericFragmentCase).len, generic_fragment_fixtures.len);
    var seen = std.EnumSet(GenericFragmentCase).initEmpty();
    for (generic_fragment_fixtures) |fixture| {
        try std.testing.expect(!seen.contains(fixture.case));
        try assertGenericFragmentProperty(fixture.case, fixture.source);
        seen.insert(fixture.case);
    }
    try std.testing.expectEqual(std.meta.fields(GenericFragmentCase).len, seen.count());
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
        .{ .source = "const first: number any = 1;\nnominal Later = \"unterminated;", .reason = .type_declaration },
        .{ .source = "nominal Bad = number any;\nnominal Later = \"unterminated;", .reason = .type_declaration },
        .{ .source = "nominal Bad = number any;\nfunction later() { return 1; }", .reason = .function_declaration },
        .{ .source = "nominal Later = \"unterminated;", .reason = .type_declaration },
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
        "nominal Bad = number any;\nnominal Later = \"unterminated;",
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
        lowerSyntaxStoreWithoutRuntimeOwners(allocator, &store, &pool, &env),
    );
    try std.testing.expectError(error.TypePoolCapacityExceeded, pool.ensureHealthy());
}

const ApplicationCapacityCase = enum {
    dict,
    inline_readonly,
    ordinary,
};

fn fillPoolToRemainingNodes(
    allocator: std.mem.Allocator,
    pool: *TypePool,
    remaining: usize,
) !void {
    const capacity: usize = null_type_idx;
    if (remaining > capacity) return error.TestUnexpectedResult;
    const target = capacity - remaining;
    if (target < pool.nodes.items.len) return error.TestUnexpectedResult;
    const prior = pool.nodes.items.len;
    try pool.nodes.resize(allocator, target);
    for (pool.nodes.items[prior..]) |*node| {
        node.* = .{ .tag = .t_literal_bool, .data = .{ .a = 0, .b = 0 } };
    }
}

fn lowerDirectCapacityAnnotation(
    allocator: std.mem.Allocator,
    pool: *TypePool,
    env: *TypeEnv,
    source: []const u8,
) !TypeIndex {
    var store = TypeSyntax.Store.init(allocator, source);
    defer store.deinit();
    var cursor = TypeSyntax.Cursor.init(source);
    switch (try TypeSyntax.parseAndStore(&store, .global(300), source, 0, &cursor)) {
        .parsed => {},
        .failure, .excluded => return error.TestUnexpectedResult,
    }
    try lowerSyntaxStoreWithoutRuntimeOwners(allocator, &store, pool, env);
    const annotation = store.annotations.items[0];
    return env.getVarTypeByBinding(annotation.binding.scope_id, annotation.binding.name_atom) orelse
        error.TestUnexpectedResult;
}

fn assertApplicationCapacityShape(
    case: ApplicationCapacityCase,
    pool: *const TypePool,
    result: TypeIndex,
    prior_nodes: usize,
    prior_names: usize,
) !void {
    const expected_node_delta: usize = switch (case) {
        .dict => 1,
        .inline_readonly => 2,
        .ordinary => 3,
    };
    const expected_name_delta: usize = switch (case) {
        .dict => 0,
        .inline_readonly => "id".len,
        .ordinary => "Inner".len + "Outer".len,
    };
    try std.testing.expectEqual(prior_nodes + expected_node_delta, pool.nodes.items.len);
    try std.testing.expectEqual(prior_names + expected_name_delta, pool.names.items.len);

    switch (case) {
        .dict => {
            try std.testing.expectEqual(TypeTag.t_dict, pool.getTag(result).?);
            try std.testing.expectEqual(@as(TypeIndex, @intCast(prior_nodes)), result);
            try std.testing.expectEqual(pool.idx_string, pool.getDictKey(result));
            try std.testing.expectEqual(pool.idx_number, pool.getDictValue(result));
        },
        .inline_readonly => {
            try std.testing.expectEqual(TypeTag.t_record, pool.getTag(result).?);
            try std.testing.expectEqual(
                TypeTag.t_record,
                pool.getTag(@as(TypeIndex, @intCast(prior_nodes))).?,
            );
            try std.testing.expectEqual(@as(TypeIndex, @intCast(prior_nodes + 1)), result);
            const fields = pool.getRecordFields(result);
            try std.testing.expectEqual(@as(usize, 1), fields.len);
            try std.testing.expect(fields[0].readonly);
            try std.testing.expectEqualStrings(
                "id",
                pool.getName(fields[0].name_start, fields[0].name_len),
            );
        },
        .ordinary => {
            try std.testing.expectEqual(TypeTag.t_generic_app, pool.getTag(result).?);
            const application = pool.getGenericAppInfo(result);
            try std.testing.expectEqual(@as(usize, 1), application.args.len);
            const argument: TypeIndex = @intCast(prior_nodes);
            const base: TypeIndex = @intCast(prior_nodes + 1);
            try std.testing.expectEqual(argument, application.args[0]);
            try std.testing.expectEqual(base, application.base);
            try std.testing.expectEqual(@as(TypeIndex, @intCast(prior_nodes + 2)), result);
            try expectRefName(pool, argument, "Inner");
            try expectRefName(pool, base, "Outer");
        },
    }
}

test "application lowering matches legacy compact node capacity and order" {
    const allocator = std.testing.allocator;
    inline for (std.meta.tags(ApplicationCapacityCase)) |case| {
        const type_source = switch (case) {
            .dict => "Dict<string, number>",
            .inline_readonly => "Readonly<{ id: number }>",
            .ordinary => "Outer<Inner>",
        };
        const direct_source = switch (case) {
            .dict => "Dict<string, number> = value;",
            .inline_readonly => "Readonly<{ id: number }> = value;",
            .ordinary => "Outer<Inner> = value;",
        };
        const necessary_nodes: usize = switch (case) {
            .dict => 1,
            .inline_readonly => 2,
            .ordinary => 3,
        };

        {
            var pool = TypePool.init(allocator);
            defer pool.deinit(allocator);
            var env = TypeEnv.init(allocator, &pool);
            defer env.deinit();
            try pool.ensureHealthy();
            try env.ensureHealthy();
            try fillPoolToRemainingNodes(allocator, &pool, necessary_nodes);
            const prior_nodes = pool.nodes.items.len;
            const prior_names = pool.names.items.len;
            const result = parseTypeExpr(&pool, allocator, type_source);
            try pool.ensureHealthy();
            try assertApplicationCapacityShape(case, &pool, result, prior_nodes, prior_names);
        }
        {
            var pool = TypePool.init(allocator);
            defer pool.deinit(allocator);
            var env = TypeEnv.init(allocator, &pool);
            defer env.deinit();
            try pool.ensureHealthy();
            try env.ensureHealthy();
            try fillPoolToRemainingNodes(allocator, &pool, necessary_nodes);
            const prior_nodes = pool.nodes.items.len;
            const prior_names = pool.names.items.len;
            const result = try lowerDirectCapacityAnnotation(
                allocator,
                &pool,
                &env,
                direct_source,
            );
            try pool.ensureHealthy();
            try env.ensureHealthy();
            try assertApplicationCapacityShape(case, &pool, result, prior_nodes, prior_names);
        }
        {
            var pool = TypePool.init(allocator);
            defer pool.deinit(allocator);
            var env = TypeEnv.init(allocator, &pool);
            defer env.deinit();
            try pool.ensureHealthy();
            try env.ensureHealthy();
            try fillPoolToRemainingNodes(allocator, &pool, necessary_nodes - 1);
            _ = parseTypeExpr(&pool, allocator, type_source);
            try std.testing.expectError(error.TypePoolCapacityExceeded, pool.ensureHealthy());
        }
        {
            var pool = TypePool.init(allocator);
            defer pool.deinit(allocator);
            var env = TypeEnv.init(allocator, &pool);
            defer env.deinit();
            try pool.ensureHealthy();
            try env.ensureHealthy();
            try fillPoolToRemainingNodes(allocator, &pool, necessary_nodes - 1);
            try std.testing.expectError(
                error.TypePoolCapacityExceeded,
                lowerDirectCapacityAnnotation(allocator, &pool, &env, direct_source),
            );
            try std.testing.expectError(error.TypePoolCapacityExceeded, pool.ensureHealthy());
        }
    }
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

test "function backtracking retains completed parameter syntax" {
    const source = "(number: string | boolean, number) = value;";
    var store = TypeSyntax.Store.init(std.testing.allocator, source);
    defer store.deinit();
    var cursor = TypeSyntax.Cursor.init(source);
    switch (try TypeSyntax.parseAndStore(&store, .global(300), source, 0, &cursor)) {
        .parsed => {},
        .failure, .excluded => return error.TestUnexpectedResult,
    }
    try std.testing.expectEqual(@as(usize, 1), store.params.items.len);
    try std.testing.expectEqual(@as(usize, 2), store.members.items.len);
    const annotation = store.annotations.items[0];
    const group = store.nodes.items[
        switch (annotation.root) {
            .absent => return error.TestUnexpectedResult,
            .present => |index| index,
        }
    ].data.group;
    try std.testing.expectEqual(@as(u32, 1), group.attempted_params.count);
    const attempted = store.paramSlice(group.attempted_params) orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings(
        "number: string | boolean",
        attempted[0].span.text(source),
    );
    const selected = store.nodes.items[
        switch (group.child) {
            .absent => return error.TestUnexpectedResult,
            .present => |index| index,
        }
    ];
    try std.testing.expectEqual(TypeSyntax.Primitive.number, selected.data.primitive);
    const union_node = store.nodes.items[
        switch (attempted[0].type_child) {
            .absent => return error.TestUnexpectedResult,
            .present => |index| index,
        }
    ].data.union_type;
    const members = store.memberSlice(union_node) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 2), members.len);
    const expected = [_]TypeSyntax.Primitive{ .string, .boolean };
    for (members, expected) |member, primitive| {
        const node = store.nodes.items[
            switch (member) {
                .absent => return error.TestUnexpectedResult,
                .present => |index| index,
            }
        ];
        try std.testing.expectEqual(primitive, node.data.primitive);
    }
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
        .group => |group| switch (group.child) {
            .absent => {},
            .present => return error.TestUnexpectedResult,
        },
        else => return error.TestUnexpectedResult,
    }

    var record_pool = TypePool.init(std.testing.allocator);
    defer record_pool.deinit(std.testing.allocator);
    var record_env = TypeEnv.init(std.testing.allocator, &record_pool);
    defer record_env.deinit();
    try lowerSyntaxStoreWithoutRuntimeOwners(
        std.testing.allocator,
        &record_store,
        &record_pool,
        &record_env,
    );
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
        .group => |group| switch (group.child) {
            .absent => {},
            .present => return error.TestUnexpectedResult,
        },
        else => return error.TestUnexpectedResult,
    }

    var function_pool = TypePool.init(std.testing.allocator);
    defer function_pool.deinit(std.testing.allocator);
    var function_env = TypeEnv.init(std.testing.allocator, &function_pool);
    defer function_env.deinit();
    try lowerSyntaxStoreWithoutRuntimeOwners(
        std.testing.allocator,
        &function_store,
        &function_pool,
        &function_env,
    );
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

    const generic_many = try compare(
        std.testing.allocator,
        "structural Many<A,B,C,D,E,F,G,H> = H;\n" ++
            "const value: Many<string,string,string,string,string,string,string,number> = undefined;",
        .collect,
    );
    try std.testing.expectEqual(AdmissionKind.any_type, generic_many.admission_refused.first);
    try std.testing.expectEqual(@as(usize, 1), generic_many.admission_refused.count);

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
        .{ .reason = .type_declaration, .source = "nominal X = \"unterminated; const x: number = 1;" },
        .{ .reason = .multiple_bindings, .source = "const { x } = y; const z: number = 1;" },
        .{ .reason = .annotation_count, .source = "const x: number = 1; const y: number = 2;" },
        .{ .reason = .compound_annotation, .source = "const x: readonly<number> = y;" },
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

test "primitive comparison preserves admitted calls and comparison operators" {
    const sources = [_][]const u8{
        "const value: number = f<string>(seed);",
        "const value: number = f<any>(seed);",
        "const value: number = seed < other;",
        "const value: number = seed > other;",
    };
    for (sources) |source| {
        try expectEquivalent(source);
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

test "successful generic application comparison closes every allocation failure" {
    const Context = struct {
        fn run(allocator: std.mem.Allocator) !void {
            const source =
                "const value: Proof<Readonly<{ data: Dict<string, number> }>, \"pure\"> = undefined;";
            const verdict = try compare(allocator, source, .collect);
            switch (verdict) {
                .equivalent => {},
                else => return error.TestUnexpectedResult,
            }
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Context.run, .{});
}

test "successful structural generic comparison closes every allocation failure" {
    const Context = struct {
        fn run(allocator: std.mem.Allocator) !void {
            const source =
                "structural Box<T extends string = boolean> = { value: T };\n" ++
                "const value: Box<number> = undefined;";
            const verdict = try compare(allocator, source, .collect);
            switch (verdict) {
                .equivalent => {},
                else => return error.TestUnexpectedResult,
            }
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Context.run, .{});
}

test "successful generic arrow and call comparison closes every allocation failure" {
    const Context = struct {
        fn run(allocator: std.mem.Allocator) !void {
            const source =
                "const seed: number = 1; const id=<T>(value)=>value; " ++
                "const result=id<string>(seed);";
            const verdict = try compare(allocator, source, .collect);
            switch (verdict) {
                .equivalent => {},
                else => return error.TestUnexpectedResult,
            }
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Context.run, .{});
}

test "later semantic fragment rollback closes every allocation failure" {
    const source = "structural Box<T> = T;\n<Outer<number>>(";
    const Later = struct {
        fn run(
            allocator: std.mem.Allocator,
            store: *TypeSyntax.Store,
            prior: TypeSyntax.Store.Checkpoint,
            call: NodeIndex,
            view: engine.parser.IrView,
        ) !void {
            errdefer store.rollback(prior);
            const list_start = std.mem.indexOf(u8, source, "<Outer") orelse
                return error.TestUnexpectedResult;
            const lparen: u32 = @intCast(source.len - 1);
            var pending = try store.reserveExplicitCall(.{
                .list_span = .{ .start = @intCast(list_start), .end = @intCast(source.len - 1) },
                .capture_spans = .{
                    .actual_erased_span = .{ .start = @intCast(list_start), .end = lparen },
                    .legacy_recorded_span = .{ .start = @intCast(list_start + 1), .end = lparen - 1 },
                },
            });
            const fragment_index = pending.final_record.semantic_fragments.start;
            try store.finishExplicitCall(&pending, call, view);
            try store.validateRuntimeOwners(std.testing.allocator, view);
            var application_bases = try store.planApplicationBasesWithIr(
                std.testing.allocator,
                view,
            );
            defer application_bases.deinit();

            var pool = TypePool.init(allocator);
            defer pool.deinit(allocator);
            var env = TypeEnv.init(allocator, &pool);
            defer env.deinit();
            var owner = try env.beginParsedGenerics(&.{.{ .name = "T" }});
            const lowered = lowerGenericSemanticFragment(
                allocator,
                store,
                &pool,
                &env,
                &owner,
                &application_bases,
                fragment_index,
                false,
            ) catch |err| return env.closeParsedScopeAfterError(&owner, err);
            const is_generic_application = pool.getTag(lowered) == TypeTag.t_generic_app;
            try env.endParsedGenerics(&owner);
            try std.testing.expect(is_generic_application);
        }
    };
    const Context = struct {
        fn run(allocator: std.mem.Allocator, observed_later_failures: *usize) !void {
            var store = TypeSyntax.Store.init(allocator, source);
            defer store.deinit();
            var nodes = engine.parser.IRStore.init(std.testing.allocator);
            defer nodes.deinit();
            var constants = engine.parser.ConstantPool.init(std.testing.allocator);
            defer constants.deinit();
            const lparen: u32 = @intCast(source.len - 1);
            const call = try nodes.add(.{
                .tag = .call,
                .loc = .{ .line = 2, .column = 16, .offset = lparen, .end_offset = lparen + 1 },
                .data = .{ .call = .{
                    .callee = engine.parser.null_node,
                    .args_start = engine.parser.null_node,
                    .args_count = 0,
                } },
            });
            const view = engine.parser.IrView.fromIRStore(&nodes, &constants);
            var cursor = TypeSyntax.Cursor.init(source);
            const keyword = cursor.current;
            cursor.advance();
            switch (try TypeSyntax.parseDeclarationAndStore(
                &store,
                source,
                keyword,
                null,
                .structural,
                0,
                &cursor,
            )) {
                .parsed => {},
                .not_declaration, .excluded => return error.TestUnexpectedResult,
            }
            const prior = store.checkpoint();
            try std.testing.expect(prior.generic_parameters > 0);
            try std.testing.expect(prior.projected_generic_parameters > 0);
            try std.testing.expect(prior.generic_owners > 0);

            Later.run(allocator, &store, prior, call, view) catch |err| {
                observed_later_failures.* += 1;
                try std.testing.expect(std.meta.eql(prior, store.checkpoint()));
                try store.validate();
                var application_bases = try store.planApplicationBases(std.testing.allocator);
                application_bases.deinit();
                return err;
            };
            const completed = store.checkpoint();
            try std.testing.expectEqual(prior.semantic_fragments + 1, completed.semantic_fragments);
            try std.testing.expectEqual(prior.authored_call_arguments + 1, completed.authored_call_arguments);
            try std.testing.expectEqual(prior.explicit_call_arguments + 1, completed.explicit_call_arguments);
        }
    };
    var observed_later_failures: usize = 0;
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        Context.run,
        .{&observed_later_failures},
    );
    try std.testing.expect(observed_later_failures > 0);
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
            try lowerSyntaxStoreWithoutRuntimeOwners(allocator, &store, &pool, &env);
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

fn runtimeNodeAt(
    parser: *const JsParser,
    tag: engine.parser.NodeTag,
    offset: u32,
) !NodeIndex {
    var result: ?NodeIndex = null;
    for (parser.nodes.tags.items, parser.nodes.locs.items, 0..) |actual_tag, loc, index| {
        if (actual_tag != tag or loc.offset != offset) continue;
        if (result != null) return error.TestUnexpectedResult;
        result = @intCast(index);
    }
    return result orelse error.TestUnexpectedResult;
}

test "global annotations retain exact repeated declaration owners" {
    const Case = struct {
        source: []const u8,
        first_typed: bool,
        second_typed: bool,
    };
    const cases = [_]Case{
        .{
            .source = "const value: number = 1;\nconst value: string = \"x\";",
            .first_typed = true,
            .second_typed = true,
        },
        .{
            .source = "const value: number = 1;\nconst value = \"x\";",
            .first_typed = true,
            .second_typed = false,
        },
        .{
            .source = "const value = 1;\nconst value: string = 2;",
            .first_typed = false,
            .second_typed = true,
        },
        .{
            .source = "const value: number = \"x\";\nconst value: string = 2;",
            .first_typed = true,
            .second_typed = true,
        },
    };
    for (cases) |case| {
        var runtime_count = CountingAllocator.init(std.testing.allocator);
        const runtime_allocator = runtime_count.allocator();
        var atoms = AtomTable.init(runtime_allocator);
        defer atoms.deinit();
        var parser = try JsParser.initTyped(runtime_allocator, std.testing.allocator, case.source);
        defer parser.deinit();
        parser.setAtomTable(&atoms);
        const root = try parser.parse();
        try expectRuntimeParityAndShape(case.source, &parser, root, &atoms, runtime_count);

        const second_start: u32 = @intCast(std.mem.indexOf(u8, case.source, "\nconst") orelse
            return error.TestUnexpectedResult);
        const declarations = [_]NodeIndex{
            try runtimeNodeAt(&parser, .var_decl, 0),
            try runtimeNodeAt(&parser, .var_decl, second_start + 1),
        };
        const view = parserIrView(&parser);
        try parser.type_store.validateRuntimeOwners(std.testing.allocator, view);
        const first = view.getVarDecl(declarations[0]) orelse return error.TestUnexpectedResult;
        const second = view.getVarDecl(declarations[1]) orelse return error.TestUnexpectedResult;
        try std.testing.expect(std.meta.eql(first.binding, second.binding));

        const expected_count = @as(usize, @intFromBool(case.first_typed)) +
            @as(usize, @intFromBool(case.second_typed));
        try std.testing.expectEqual(expected_count, parser.type_store.annotations.items.len);
        var annotation_index: usize = 0;
        for ([_]bool{ case.first_typed, case.second_typed }, declarations, 0..) |
            typed,
            declaration_node,
            declaration_index,
        | {
            if (!typed) continue;
            const annotation = parser.type_store.annotations.items[annotation_index];
            const owner = annotation.runtime_owner orelse return error.TestUnexpectedResult;
            try std.testing.expectEqual(declaration_node, owner.declaration);
            try std.testing.expectEqual(
                if (declaration_index == 0) @as(u32, 0) else second_start + 1,
                owner.declaration_start,
            );
            const declaration = view.getVarDecl(declaration_node) orelse
                return error.TestUnexpectedResult;
            try std.testing.expect(std.meta.eql(declaration.binding, annotation.binding));
            annotation_index += 1;
        }
        if (expected_count == 2) {
            const left = parser.type_store.annotations.items[0].runtime_owner orelse
                return error.TestUnexpectedResult;
            const right = parser.type_store.annotations.items[1].runtime_owner orelse
                return error.TestUnexpectedResult;
            try std.testing.expect(left.declaration != right.declaration);
        }
    }
    try std.testing.expectEqual(@as(usize, 4), cases.len);
}

test "outer annotation keeps its index across a nested typed initializer" {
    const source =
        "const outer: number = (() => { const inner: string = \"x\"; return 1; })();";
    var runtime_count = CountingAllocator.init(std.testing.allocator);
    const runtime_allocator = runtime_count.allocator();
    var atoms = AtomTable.init(runtime_allocator);
    defer atoms.deinit();
    var parser = try JsParser.initTyped(runtime_allocator, std.testing.allocator, source);
    defer parser.deinit();
    parser.setAtomTable(&atoms);
    const root = try parser.parse();
    try expectRuntimeParityAndShape(source, &parser, root, &atoms, runtime_count);

    const inner_start: u32 = @intCast(std.mem.indexOf(u8, source, "const inner") orelse
        return error.TestUnexpectedResult);
    const outer_node = try runtimeNodeAt(&parser, .var_decl, 0);
    const inner_node = try runtimeNodeAt(&parser, .var_decl, inner_start);
    const view = parserIrView(&parser);
    try parser.type_store.validateRuntimeOwners(std.testing.allocator, view);
    try std.testing.expectEqual(@as(usize, 2), parser.type_store.annotations.items.len);
    const outer_owner = parser.type_store.annotations.items[0].runtime_owner orelse
        return error.TestUnexpectedResult;
    const inner_owner = parser.type_store.annotations.items[1].runtime_owner orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqual(outer_node, outer_owner.declaration);
    try std.testing.expectEqual(@as(u32, 0), outer_owner.declaration_start);
    try std.testing.expectEqual(inner_node, inner_owner.declaration);
    try std.testing.expectEqual(inner_start, inner_owner.declaration_start);
    try std.testing.expect(inner_node < outer_node);
}

test "annotation runtime owners reject missing forged and exchanged declarations" {
    const source = "const value: number = 1;\nconst value: string = \"x\";";
    var runtime_count = CountingAllocator.init(std.testing.allocator);
    const runtime_allocator = runtime_count.allocator();
    var atoms = AtomTable.init(runtime_allocator);
    defer atoms.deinit();
    var parser = try JsParser.initTyped(runtime_allocator, std.testing.allocator, source);
    defer parser.deinit();
    parser.setAtomTable(&atoms);
    const root = try parser.parse();
    try expectRuntimeParityAndShape(source, &parser, root, &atoms, runtime_count);

    const store = &parser.type_store;
    const view = parserIrView(&parser);
    try store.validateRuntimeOwners(std.testing.allocator, view);
    const original = [_]TypeSyntax.Annotation{ store.annotations.items[0], store.annotations.items[1] };
    const first_owner = original[0].runtime_owner orelse return error.TestUnexpectedResult;
    const second_owner = original[1].runtime_owner orelse return error.TestUnexpectedResult;

    store.annotations.items[0].runtime_owner = null;
    try std.testing.expectError(
        error.InvalidAnnotationOwner,
        store.validateRuntimeOwners(std.testing.allocator, view),
    );
    store.annotations.items[0] = original[0];

    store.annotations.items[1].runtime_owner = first_owner;
    try std.testing.expectError(
        error.InvalidAnnotationOwner,
        store.validateRuntimeOwners(std.testing.allocator, view),
    );
    store.annotations.items[1] = original[1];

    const wrong_tag_loc = view.getLoc(root) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(engine.parser.NodeTag.program, view.getTag(root).?);
    try std.testing.expect(wrong_tag_loc.offset < original[0].raw_span.start);
    store.annotations.items[0].runtime_owner = .{
        .declaration = root,
        .declaration_start = wrong_tag_loc.offset,
    };
    try std.testing.expectError(
        error.InvalidAnnotationOwner,
        store.validateRuntimeOwners(std.testing.allocator, view),
    );
    store.annotations.items[0] = original[0];

    store.annotations.items[0].binding.kind = .local;
    try std.testing.expectError(
        error.InvalidAnnotationOwner,
        store.validateRuntimeOwners(std.testing.allocator, view),
    );
    store.annotations.items[0] = original[0];

    store.annotations.items[0].runtime_owner.?.declaration_start += 1;
    try std.testing.expectError(
        error.InvalidAnnotationOwner,
        store.validateRuntimeOwners(std.testing.allocator, view),
    );
    store.annotations.items[0] = original[0];

    const first_node_index: usize = @intCast(first_owner.declaration);
    const original_location = parser.nodes.locs.items[first_node_index];
    const source_end: u32 = @intCast(source.len);
    parser.nodes.locs.items[first_node_index].offset = source_end;
    store.annotations.items[0].runtime_owner.?.declaration_start = source_end;
    try std.testing.expectError(
        error.InvalidAnnotationOwner,
        store.validateRuntimeOwners(std.testing.allocator, view),
    );
    const annotation_start = original[0].raw_span.start;
    parser.nodes.locs.items[first_node_index].offset = annotation_start;
    store.annotations.items[0].runtime_owner.?.declaration_start = annotation_start;
    try std.testing.expectError(
        error.InvalidAnnotationOwner,
        store.validateRuntimeOwners(std.testing.allocator, view),
    );
    parser.nodes.locs.items[first_node_index] = original_location;
    store.annotations.items[0] = original[0];

    store.annotations.items[0].runtime_owner.?.declaration = second_owner.declaration;
    store.annotations.items[1].runtime_owner.?.declaration = first_owner.declaration;
    try std.testing.expectError(
        error.InvalidAnnotationOwner,
        store.validateRuntimeOwners(std.testing.allocator, view),
    );
    store.annotations.items[0] = original[0];
    store.annotations.items[1] = original[1];

    store.annotations.items[0].runtime_owner = null;
    store.annotations.items[0].raw_span.end = source_end + 1;
    try std.testing.expectError(
        error.InvalidTypeSpan,
        store.finishAnnotationOwner(0, first_owner, view),
    );
    try std.testing.expect(store.annotations.items[0].runtime_owner == null);
    store.annotations.items[0] = original[0];
    store.annotations.items[0].runtime_owner = null;
    try std.testing.expectError(
        error.InvalidAnnotationOwner,
        store.finishAnnotationOwner(0, .{
            .declaration = root,
            .declaration_start = wrong_tag_loc.offset,
        }, view),
    );
    try std.testing.expect(store.annotations.items[0].runtime_owner == null);
    try store.finishAnnotationOwner(0, first_owner, view);
    try std.testing.expectError(
        error.InvalidAnnotationOwner,
        store.finishAnnotationOwner(0, first_owner, view),
    );
    try store.validateRuntimeOwners(std.testing.allocator, view);
}

test "variable and export allocation failures remove unfinished annotation owners" {
    const variable_source =
        "const seed: number = 1;\n" ++
        "const value: string = \"x\";";
    const export_source =
        "const seed: number = 1;\n" ++
        "export const value: string = \"x\";";
    const common = FinalNodeRollbackCase{
        .source = variable_source,
        .target_tag = .var_decl,
        .target_offset = @intCast(std.mem.indexOf(u8, variable_source, "const value").?),
        .control_annotations = 2,
        .control_owners = 0,
        .control_calls = 0,
        .retained_nodes = 1,
        .retained_owners = 0,
        .retained_generic_parameters = 0,
        .retained_projected_parameters = 0,
        .retained_calls = 0,
        .retained_call_arguments = 0,
        .retained_fragments = 0,
        .retained_checkpoint = seedCheckpoint(),
        .runtime_parity = true,
    };
    try expectFinalNodeAllocationRollback(common);

    var export_wrapper = common;
    export_wrapper.source = export_source;
    export_wrapper.target_tag = .export_decl;
    export_wrapper.target_offset = @intCast(std.mem.indexOf(u8, export_source, "export").?);
    try expectFinalNodeAllocationRollback(export_wrapper);
}

test "annotation owner census covers every legacy kind" {
    const source =
        "structural Box<T> = { value: T };\n" ++
        "nominal Id = string;\n" ++
        "const seed: number = 1; let label: string = \"x\";\n" ++
        "function id<U>(value: U): U { return value; } " ++
        "function isString(candidate: unknown): candidate is string { return typeof candidate === \"string\"; }\n" ++
        "const result = id<number>(seed);";
    var runtime_count = CountingAllocator.init(std.testing.allocator);
    const runtime_allocator = runtime_count.allocator();
    var atoms = AtomTable.init(runtime_allocator);
    defer atoms.deinit();
    var parser = try JsParser.initTyped(runtime_allocator, std.testing.allocator, source);
    defer parser.deinit();
    parser.setAtomTable(&atoms);
    const root = try parser.parse();
    try expectRuntimeParityAndShape(source, &parser, root, &atoms, runtime_count);

    var prepared = try PreparedSource.init(std.testing.allocator, source, "<owner-census>.ts", .{});
    defer prepared.deinit();
    const legacy_map = prepared.typeMap() orelse return error.TestUnexpectedResult;
    const LegacyKind = @TypeOf(legacy_map.entries.items[0].kind);
    try std.testing.expectEqual(@as(usize, 8), std.meta.fields(LegacyKind).len);
    var observed = std.EnumArray(LegacyKind, usize).initFill(0);
    for (legacy_map.entries.items) |entry| observed.getPtr(entry.kind).* += 1;
    for (std.enums.values(LegacyKind)) |kind| {
        const expected: usize = switch (kind) {
            .type_alias, .distinct_type, .return_annotation, .type_guard_annotation, .call_type_arguments => 1,
            .var_annotation, .param_annotation, .generic_params => 2,
        };
        try std.testing.expectEqual(expected, observed.get(kind));
    }

    const store = &parser.type_store;
    const view = parserIrView(&parser);
    try store.validateRuntimeOwners(std.testing.allocator, view);
    try std.testing.expectEqual(@as(usize, 2), store.declarations.items.len);
    try std.testing.expectEqual(TypeSyntax.DeclarationKind.structural, store.declarations.items[0].kind);
    try std.testing.expectEqual(TypeSyntax.DeclarationKind.nominal, store.declarations.items[1].kind);
    try std.testing.expectEqual(@as(usize, 2), store.annotations.items.len);
    try std.testing.expectEqual(@as(usize, 2), store.parameter_annotations.items.len);
    try std.testing.expectEqual(@as(usize, 2), store.function_signatures.items.len);
    try std.testing.expectEqual(@as(usize, 2), store.generic_owners.items.len);
    try std.testing.expectEqual(@as(usize, 1), store.explicit_call_arguments.items.len);
    try std.testing.expectEqual(@as(usize, 0), store.type_only_modules.items.len);
    try std.testing.expectEqual(@as(usize, 0), store.erased_type_prefixes.items.len);
    try std.testing.expectEqual(@as(u32, 0), switch (store.generic_owners.items[0].identity) {
        .structural_declaration => |index| index,
        else => return error.TestUnexpectedResult,
    });
    try std.testing.expectEqual(store.function_signatures.items[0].owner, switch (store.generic_owners.items[1].identity) {
        .function => |index| index,
        else => return error.TestUnexpectedResult,
    });
    var variable_count: usize = 0;
    var function_count: usize = 0;
    var call_count: usize = 0;
    for (parser.nodes.tags.items, 0..) |tag, index| switch (tag) {
        .var_decl => {
            const declaration = view.getVarDecl(@intCast(index)) orelse return error.TestUnexpectedResult;
            const name = atoms.getName(@enumFromInt(declaration.binding.name_atom)) orelse return error.TestUnexpectedResult;
            if (std.mem.eql(u8, name, "seed") or std.mem.eql(u8, name, "label")) {
                const annotation = store.annotations.items[variable_count];
                try std.testing.expect(std.meta.eql(declaration.binding, annotation.binding));
                try std.testing.expectEqualStrings(if (variable_count == 0) "number" else "string", annotation.raw_span.text(source));
                variable_count += 1;
            } else {
                try std.testing.expectEqualStrings("result", name);
                try std.testing.expectEqual(store.explicit_call_arguments.items[0].owner, declaration.init);
                call_count += 1;
            }
        },
        .function_decl => {
            const declaration = view.getVarDecl(@intCast(index)) orelse return error.TestUnexpectedResult;
            const signature = store.function_signatures.items[function_count];
            try std.testing.expectEqual(signature.owner, declaration.init);
            try std.testing.expectEqual(engine.parser.NodeTag.function_expr, view.getTag(signature.owner).?);
            const function = view.getFunction(signature.owner) orelse return error.TestUnexpectedResult;
            try std.testing.expectEqual(@as(u8, 1), function.params_count);
            const parameter = store.parameter_annotations.items[function_count];
            try std.testing.expectEqual(parameter.owner.pattern, view.getListIndex(function.params_start, 0));
            try std.testing.expect(std.meta.eql(parameter.owner.binding, view.paramBinding(parameter.owner.pattern).?));
            const return_syntax = signature.return_syntax orelse return error.TestUnexpectedResult;
            if (function_count == 0) {
                try std.testing.expectEqual(TypeSyntax.LegacyReturnKind.ordinary, return_syntax.legacy_return_kind);
                try std.testing.expectEqualStrings("U ", return_syntax.raw_span.text(source));
                switch (return_syntax.structure) {
                    .value => {},
                    .predicate => return error.TestUnexpectedResult,
                }
            } else {
                try std.testing.expectEqual(TypeSyntax.LegacyReturnKind.type_guard, return_syntax.legacy_return_kind);
                const predicate = switch (return_syntax.structure) {
                    .predicate => |value| value,
                    .value => return error.TestUnexpectedResult,
                };
                try std.testing.expectEqualStrings("candidate", predicate.target_span.text(source));
                const target = switch (predicate.target) {
                    .resolved => |value| value,
                    .unresolved => return error.TestUnexpectedResult,
                };
                try std.testing.expect(std.meta.eql(parameter.owner, target));
            }
            function_count += 1;
        },
        else => {},
    };
    try std.testing.expectEqual(@as(usize, 2), variable_count);
    try std.testing.expectEqual(@as(usize, 2), function_count);
    try std.testing.expectEqual(@as(usize, 1), call_count);
}

test "shadowed bindings and closure parameters retain their actual owners" {
    const source =
        "const shared: number = 1;\n" ++
        "function outer(value: string): string {\n" ++
        "  const shared: string = value;\n" ++
        "  function inner(value: number): string { return shared; }\n" ++
        "  return shared;\n" ++
        "}";
    var runtime_count = CountingAllocator.init(std.testing.allocator);
    const runtime_allocator = runtime_count.allocator();
    var atoms = AtomTable.init(runtime_allocator);
    defer atoms.deinit();
    var parser = try JsParser.initTyped(runtime_allocator, std.testing.allocator, source);
    defer parser.deinit();
    parser.setAtomTable(&atoms);
    const root = try parser.parse();
    try expectRuntimeParityAndShape(source, &parser, root, &atoms, runtime_count);
    const store = &parser.type_store;
    const view = parserIrView(&parser);
    try store.validateRuntimeOwners(std.testing.allocator, view);
    try std.testing.expectEqual(@as(usize, 2), store.annotations.items.len);
    try std.testing.expectEqual(@as(usize, 2), store.parameter_annotations.items.len);
    try std.testing.expectEqual(@as(usize, 2), store.function_signatures.items.len);
    try std.testing.expect(!std.meta.eql(store.annotations.items[0].binding, store.annotations.items[1].binding));
    try std.testing.expect(!std.meta.eql(store.parameter_annotations.items[0].owner.binding, store.parameter_annotations.items[1].owner.binding));
    var variables: usize = 0;
    for (parser.nodes.tags.items, 0..) |tag, index| {
        if (tag != .var_decl) continue;
        const declaration = view.getVarDecl(@intCast(index)) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqualStrings("shared", atoms.getName(@enumFromInt(declaration.binding.name_atom)).?);
        const annotation = store.annotations.items[variables];
        try std.testing.expect(std.meta.eql(declaration.binding, annotation.binding));
        try std.testing.expectEqualStrings(if (variables == 0) "number" else "string", annotation.raw_span.text(source));
        variables += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), variables);
    for (store.function_signatures.items, 0..) |signature, index| {
        try std.testing.expectEqual(engine.parser.NodeTag.function_expr, view.getTag(signature.owner).?);
        const function = view.getFunction(signature.owner) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqualStrings(if (index == 0) "outer" else "inner", atoms.getName(@enumFromInt(function.name_atom)).?);
        try std.testing.expectEqual(@as(u8, 1), function.params_count);
        const parameter = store.parameter_annotations.items[index];
        try std.testing.expectEqual(parameter.owner.pattern, view.getListIndex(function.params_start, 0));
        try std.testing.expect(std.meta.eql(parameter.owner.binding, view.paramBinding(parameter.owner.pattern).?));
        try std.testing.expectEqualStrings("value", atoms.getName(@enumFromInt(parameter.owner.binding.name_atom)).?);
        try std.testing.expectEqualStrings(if (index == 0) "string" else "number", parameter.value.raw_span.text(source));
    }
    const inner = view.getFunction(store.function_signatures.items[1].owner) orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqual(engine.parser.NodeTag.block, view.getTag(inner.body).?);
    const inner_body = view.getBlock(inner.body) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u16, 1), inner_body.stmts_count);
    const inner_return = view.getListIndex(inner_body.stmts_start, 0);
    try std.testing.expectEqual(engine.parser.NodeTag.return_stmt, view.getTag(inner_return).?);
    const captured_value = view.getOptValue(inner_return) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(engine.parser.NodeTag.identifier, view.getTag(captured_value).?);
    const captured_binding = view.getBinding(captured_value) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(engine.parser.BindingRef.BindingKind.upvalue, captured_binding.kind);
    try std.testing.expectEqual(inner.scope_id, captured_binding.scope_id);
    const local_binding = store.annotations.items[1].binding;
    try std.testing.expectEqual(local_binding.name_atom, captured_binding.name_atom);
    const captures = parser.scopes.getUpvalues(inner.scope_id);
    try std.testing.expectEqual(@as(usize, 1), captures.len);
    try std.testing.expectEqual(@as(u16, captures[0].slot), captured_binding.slot);
    try std.testing.expectEqual(local_binding.scope_id, captures[0].source_scope_id);
    try std.testing.expectEqual(local_binding.slot, @as(u16, captures[0].source_slot));
    try std.testing.expectEqualStrings("shared", captures[0].name);
    switch (captures[0].capture) {
        .local => |slot| try std.testing.expectEqual(local_binding.slot, @as(u16, slot)),
        .upvalue => return error.TestUnexpectedResult,
    }
}

fn expectExactTypePool(left: *const TypePool, right: *const TypePool) !void {
    try std.testing.expectEqual(left.nodes.items.len, right.nodes.items.len);
    for (left.nodes.items, right.nodes.items) |a, b| try std.testing.expect(std.meta.eql(a, b));
    try std.testing.expectEqual(left.fields.items.len, right.fields.items.len);
    for (left.fields.items, right.fields.items) |a, b| try std.testing.expect(std.meta.eql(a, b));
    try std.testing.expectEqual(left.params.items.len, right.params.items.len);
    for (left.params.items, right.params.items) |a, b| try std.testing.expect(std.meta.eql(a, b));
    try std.testing.expectEqualSlices(TypeIndex, left.members.items, right.members.items);
    try std.testing.expectEqualSlices(u8, left.names.items, right.names.items);
    try std.testing.expectEqual(left.template_parts.items.len, right.template_parts.items.len);
    for (left.template_parts.items, right.template_parts.items) |a, b| {
        try std.testing.expect(std.meta.eql(a, b));
    }
    try std.testing.expectEqual(left.idx_boolean, right.idx_boolean);
    try std.testing.expectEqual(left.idx_number, right.idx_number);
    try std.testing.expectEqual(left.idx_string, right.idx_string);
    try std.testing.expectEqual(left.idx_bytes, right.idx_bytes);
    try std.testing.expectEqual(left.idx_null, right.idx_null);
    try std.testing.expectEqual(left.idx_undefined, right.idx_undefined);
    try std.testing.expectEqual(left.idx_void, right.idx_void);
    try std.testing.expectEqual(left.idx_never, right.idx_never);
    try std.testing.expectEqual(left.idx_unknown, right.idx_unknown);
    try std.testing.expectEqual(left.idx_error, right.idx_error);
}

fn expectExactFunctionSignature(
    legacy: type_env_mod.FunctionSig,
    direct: type_env_mod.FunctionSig,
) !void {
    try std.testing.expectEqual(legacy.param_count, direct.param_count);
    try std.testing.expectEqualSlices(
        TypeIndex,
        legacy.param_types[0..legacy.param_count],
        direct.param_types[0..direct.param_count],
    );
    try std.testing.expectEqual(legacy.required_param_count, direct.required_param_count);
    try std.testing.expectEqual(legacy.max_arg_count, direct.max_arg_count);
    try std.testing.expectEqual(legacy.return_type, direct.return_type);
    try std.testing.expectEqual(legacy.type_param_count, direct.type_param_count);
    for (
        legacy.type_params[0..legacy.type_param_count],
        direct.type_params[0..direct.type_param_count],
    ) |legacy_parameter, direct_parameter| {
        try std.testing.expectEqualStrings(legacy_parameter.name, direct_parameter.name);
        try std.testing.expectEqual(legacy_parameter.idx, direct_parameter.idx);
        try std.testing.expectEqual(legacy_parameter.constraint, direct_parameter.constraint);
    }
    try std.testing.expect(std.meta.eql(legacy.type_predicate, direct.type_predicate));
}

fn expectExactFunctionNameMaps(legacy: *const TypeEnv, direct: *const TypeEnv) !void {
    try std.testing.expectEqual(legacy.fn_sigs_by_name.count(), direct.fn_sigs_by_name.count());
    var signatures = legacy.fn_sigs_by_name.iterator();
    while (signatures.next()) |entry| {
        try expectExactFunctionSignature(
            entry.value_ptr.*,
            direct.fn_sigs_by_name.get(entry.key_ptr.*) orelse return error.TestUnexpectedResult,
        );
    }

    try std.testing.expectEqual(
        legacy.source_fn_sigs_by_name.count(),
        direct.source_fn_sigs_by_name.count(),
    );
    var source_signatures = legacy.source_fn_sigs_by_name.iterator();
    while (source_signatures.next()) |entry| {
        try expectExactFunctionSignature(
            entry.value_ptr.*,
            direct.source_fn_sigs_by_name.get(entry.key_ptr.*) orelse
                return error.TestUnexpectedResult,
        );
    }
}

fn expectExactOwnerSignatures(
    legacy_env: *const TypeEnv,
    direct_env: *const TypeEnv,
    legacy_view: engine.parser.IrView,
    direct_view: engine.parser.IrView,
    store: *const TypeSyntax.Store,
) !void {
    try std.testing.expectEqual(
        legacy_env.fn_signatures.count(),
        direct_env.direct_fn_signatures.count(),
    );
    try std.testing.expectEqual(
        legacy_env.source_fn_annotations.count(),
        direct_env.direct_source_fn_annotations.count(),
    );

    var published_count: usize = 0;
    for (store.function_signatures.items) |record| {
        const tag = direct_view.getTag(record.owner) orelse return error.TestUnexpectedResult;
        try std.testing.expect(tag == .function_expr or tag == .arrow_function);
        const legacy_reference = legacy_env.functionTypeRef(legacy_view, record.owner) orelse
            return error.TestUnexpectedResult;
        const direct_reference = direct_env.functionTypeRef(direct_view, record.owner) orelse
            return error.TestUnexpectedResult;
        const legacy_signature = legacy_env.getFunctionSignature(legacy_reference);
        const direct_signature = direct_env.getFunctionSignature(direct_reference);
        if (legacy_signature == null or direct_signature == null) {
            try std.testing.expect(legacy_signature == null);
            try std.testing.expect(direct_signature == null);
            continue;
        }
        const expected_signature = legacy_signature.?;
        const actual_signature = direct_signature.?;
        try expectExactFunctionSignature(expected_signature, actual_signature);
        for (0..expected_signature.param_count) |index| {
            const compact_position: u8 = @intCast(index);
            const legacy_spelling = legacy_env.getFunctionParameterSpelling(
                legacy_reference,
                compact_position,
            );
            const direct_spelling = direct_env.getFunctionParameterSpelling(
                direct_reference,
                compact_position,
            );
            if (legacy_spelling) |spelling| {
                try std.testing.expectEqualStrings(
                    spelling,
                    direct_spelling orelse return error.TestUnexpectedResult,
                );
            } else {
                try std.testing.expect(direct_spelling == null);
            }
        }
        const legacy_return = legacy_env.getFunctionReturnSpelling(legacy_reference);
        const direct_return = direct_env.getFunctionReturnSpelling(direct_reference);
        if (legacy_return) |spelling| {
            try std.testing.expectEqualStrings(
                spelling,
                direct_return orelse return error.TestUnexpectedResult,
            );
        } else {
            try std.testing.expect(direct_return == null);
        }

        const legacy_key = legacy_view.signatureOffset(record.owner) orelse
            return error.TestUnexpectedResult;
        try expectExactFunctionSignature(
            legacy_env.fn_signatures.get(legacy_key) orelse return error.TestUnexpectedResult,
            direct_env.direct_fn_signatures.get(record.owner) orelse
                return error.TestUnexpectedResult,
        );
        published_count += 1;
    }
    try std.testing.expectEqual(published_count, legacy_env.fn_signatures.count());
    try std.testing.expectEqual(published_count, direct_env.direct_fn_signatures.count());

    var direct_signatures = direct_env.direct_fn_signatures.iterator();
    while (direct_signatures.next()) |entry| {
        const owner = entry.key_ptr.*;
        const tag = direct_view.getTag(owner) orelse return error.TestUnexpectedResult;
        try std.testing.expect(tag == .function_expr or tag == .arrow_function);
        var found = false;
        for (store.function_signatures.items) |record| {
            if (record.owner != owner) continue;
            found = true;
            break;
        }
        try std.testing.expect(found);
        const legacy_key = legacy_view.signatureOffset(owner) orelse
            return error.TestUnexpectedResult;
        try expectExactFunctionSignature(
            legacy_env.fn_signatures.get(legacy_key) orelse return error.TestUnexpectedResult,
            entry.value_ptr.*,
        );
    }
}

const DirectGenericConsumerCase = enum {
    interleaved,
    compound_prefix,
    duplicate_parameters,
    generic_arrow,
    empty_callable,
    generic_only,
    ignored_callable,
    ignored_prefix,
    empty_prefix,
};

fn expectDirectGenericConsumer(
    source: []const u8,
    case: DirectGenericConsumerCase,
) !void {
    var prepared = try PreparedSource.init(
        std.testing.allocator,
        source,
        "<u12-phase-two>.ts",
        .{},
    );
    defer prepared.deinit();
    try std.testing.expectEqual(@as(usize, 0), prepared.stripDiagnostics().len);

    var legacy_count = CountingAllocator.init(std.testing.allocator);
    var direct_count = CountingAllocator.init(std.testing.allocator);
    var type_count = CountingAllocator.init(std.testing.allocator);
    var legacy_atoms = AtomTable.init(legacy_count.allocator());
    defer legacy_atoms.deinit();
    var direct_atoms = AtomTable.init(direct_count.allocator());
    defer direct_atoms.deinit();
    var legacy = try JsParser.init(legacy_count.allocator(), prepared.parserInput());
    defer legacy.deinit();
    legacy.setAtomTable(&legacy_atoms);
    var direct = try JsParser.initTyped(
        direct_count.allocator(),
        type_count.allocator(),
        source,
    );
    defer direct.deinit();
    direct.setAtomTable(&direct_atoms);
    const legacy_root = try legacy.parse();
    const direct_root = try direct.parse();
    const legacy_view = parserIrView(&legacy);
    const direct_view = parserIrView(&direct);
    try std.testing.expect(compareRuntime(
        &legacy,
        legacy_root,
        &legacy_atoms,
        &direct,
        direct_root,
        &direct_atoms,
    ) == null);
    try std.testing.expect(legacy_count.sameRuntimeShape(direct_count));

    var legacy_pool = TypePool.init(std.testing.allocator);
    defer legacy_pool.deinit(std.testing.allocator);
    var direct_pool = TypePool.init(std.testing.allocator);
    defer direct_pool.deinit(std.testing.allocator);
    var legacy_env = TypeEnv.init(std.testing.allocator, &legacy_pool);
    defer legacy_env.deinit();
    var direct_env = TypeEnv.init(std.testing.allocator, &direct_pool);
    defer direct_env.deinit();
    const prior_nodes = direct_pool.nodes.items.len;
    const prior_names = direct_env.name_storage.items.len;
    try legacy_env.populateSourceTypes(.{ .legacy = prepared.typeMap().? });
    try direct_env.populateSourceTypes(.{ .direct = .{
        .store = &direct.type_store,
        .ir_view = direct_view,
        .atoms = &direct_atoms,
    } });
    try expectExactTypePool(&legacy_pool, &direct_pool);
    try expectExactFunctionNameMaps(&legacy_env, &direct_env);
    try expectExactOwnerSignatures(
        &legacy_env,
        &direct_env,
        legacy_view,
        direct_view,
        &direct.type_store,
    );
    try legacy_pool.ensureHealthy();
    try direct_pool.ensureHealthy();
    try legacy_env.ensureHealthy();
    try direct_env.ensureHealthy();
    try std.testing.expectEqual(@as(usize, 0), direct_env.generic_scopes.items.len);

    switch (case) {
        .interleaved => {
            try std.testing.expectEqual(prior_nodes + 3, direct_pool.nodes.items.len);
            for ([_][]const u8{ "P", "T", "Q" }, 0..) |name, index| {
                const type_index: TypeIndex = @intCast(prior_nodes + index);
                try std.testing.expectEqual(TypeTag.t_generic_param, direct_pool.getTag(type_index).?);
                try std.testing.expectEqualStrings(name, direct_pool.getRefName(type_index));
            }
            try std.testing.expectEqual(@as(usize, 3), direct.type_store.erased_type_prefixes.items.len);
            try std.testing.expectEqual(@as(usize, 1), direct.type_store.generic_owners.items.len);
            const owner = switch (direct.type_store.generic_owners.items[0].identity) {
                .function => |node| node,
                else => return error.TestUnexpectedResult,
            };
            const reference = direct_env.functionTypeRef(direct_view, owner) orelse
                return error.TestUnexpectedResult;
            const signature = direct_env.getFunctionSignature(reference) orelse
                return error.TestUnexpectedResult;
            try std.testing.expectEqual(@as(u8, 1), signature.type_param_count);
            try std.testing.expectEqualStrings("T", signature.type_params[0].name);
            try std.testing.expectEqual(@as(TypeIndex, @intCast(prior_nodes + 1)), signature.type_params[0].idx);
            try std.testing.expectEqual(direct_pool.idx_string, signature.type_params[0].constraint);
            try std.testing.expectEqual(@as(u8, 1), signature.param_count);
            try std.testing.expectEqual(signature.type_params[0].idx, signature.param_types[0]);
            try std.testing.expectEqual(signature.type_params[0].idx, signature.return_type);
            try std.testing.expectEqual(@as(usize, 2), direct_env.direct_accumulator_events);
        },
        .compound_prefix => {
            try std.testing.expectEqual(prior_nodes + 2, direct_pool.nodes.items.len);
            const parameter: TypeIndex = @intCast(prior_nodes);
            const bound: TypeIndex = @intCast(prior_nodes + 1);
            try std.testing.expectEqual(TypeTag.t_generic_param, direct_pool.getTag(parameter).?);
            try std.testing.expectEqualStrings("P", direct_pool.getRefName(parameter));
            try std.testing.expectEqual(TypeTag.t_record, direct_pool.getTag(bound).?);
            const fields = direct_pool.getRecordFields(bound);
            try std.testing.expectEqual(@as(usize, 1), fields.len);
            try std.testing.expectEqual(direct_pool.idx_string, fields[0].type_idx);
            try std.testing.expectEqual(@as(usize, 0), direct_env.direct_fn_signatures.count());
        },
        .duplicate_parameters => {
            try std.testing.expectEqual(prior_nodes + 2, direct_pool.nodes.items.len);
            const owner = switch (direct.type_store.generic_owners.items[0].identity) {
                .function => |node| node,
                else => return error.TestUnexpectedResult,
            };
            const reference = direct_env.functionTypeRef(direct_view, owner) orelse
                return error.TestUnexpectedResult;
            const signature = direct_env.getFunctionSignature(reference) orelse
                return error.TestUnexpectedResult;
            try std.testing.expectEqual(@as(u8, 2), signature.type_param_count);
            try std.testing.expectEqualStrings("T", signature.type_params[0].name);
            try std.testing.expectEqualStrings("T", signature.type_params[1].name);
            try std.testing.expect(signature.type_params[0].idx != signature.type_params[1].idx);
            try std.testing.expectEqual(direct_pool.idx_string, signature.type_params[0].constraint);
            try std.testing.expectEqual(direct_pool.idx_number, signature.type_params[1].constraint);
            try std.testing.expectEqual(signature.type_params[0].idx, signature.param_types[0]);
            try std.testing.expectEqual(signature.type_params[0].idx, signature.return_type);
        },
        .generic_arrow => {
            try std.testing.expectEqual(prior_nodes + 1, direct_pool.nodes.items.len);
            try std.testing.expectEqual(@as(usize, 1), direct.type_store.generic_owners.items.len);
            const generic_owner = direct.type_store.generic_owners.items[0];
            try std.testing.expect(
                std.meta.activeTag(generic_owner.compatibility) == .declaration_parameters,
            );
            try std.testing.expectEqual(@as(u32, 1), generic_owner.projected_parameters.count);
            const owner = switch (generic_owner.identity) {
                .arrow => |node| node,
                else => return error.TestUnexpectedResult,
            };
            try std.testing.expectEqual(engine.parser.NodeTag.arrow_function, direct_view.getTag(owner).?);
            const reference = direct_env.functionTypeRef(direct_view, owner) orelse
                return error.TestUnexpectedResult;
            const signature = direct_env.getFunctionSignature(reference) orelse
                return error.TestUnexpectedResult;
            try std.testing.expectEqual(@as(u8, 1), signature.type_param_count);
            try std.testing.expectEqualStrings("T", signature.type_params[0].name);
            try std.testing.expectEqual(@as(TypeIndex, @intCast(prior_nodes)), signature.type_params[0].idx);
            try std.testing.expectEqual(direct_pool.idx_string, signature.type_params[0].constraint);
            try std.testing.expectEqual(@as(u8, 1), signature.param_count);
            try std.testing.expectEqual(signature.type_params[0].idx, signature.param_types[0]);
            try std.testing.expectEqual(signature.type_params[0].idx, signature.return_type);
            try std.testing.expectEqual(@as(usize, 0), direct_env.fn_sigs_by_name.count());
            try std.testing.expectEqual(@as(usize, 0), direct_env.source_fn_sigs_by_name.count());
            try std.testing.expectEqual(@as(usize, 0), legacy_env.fn_sigs_by_name.count());
            try std.testing.expectEqual(@as(usize, 0), legacy_env.source_fn_sigs_by_name.count());
        },
        .empty_callable => {
            try std.testing.expectEqual(prior_nodes, direct_pool.nodes.items.len);
            try std.testing.expectEqual(@as(usize, 1), direct.type_store.generic_owners.items.len);
            const generic_owner = direct.type_store.generic_owners.items[0];
            try std.testing.expectEqual(
                @as(u32, 0),
                generic_owner.projected_parameters.count,
            );
            try std.testing.expect(
                std.meta.activeTag(generic_owner.compatibility) == .declaration_parameters,
            );
            const owner = switch (generic_owner.identity) {
                .function => |node| node,
                else => return error.TestUnexpectedResult,
            };
            const reference = direct_env.functionTypeRef(direct_view, owner) orelse
                return error.TestUnexpectedResult;
            const signature = direct_env.getFunctionSignature(reference) orelse
                return error.TestUnexpectedResult;
            try std.testing.expectEqual(@as(u8, 0), signature.type_param_count);
            try std.testing.expectEqual(@as(u8, 1), signature.param_count);
            try std.testing.expectEqual(direct_pool.idx_string, signature.param_types[0]);
            try std.testing.expectEqual(direct_pool.idx_string, signature.return_type);
            try std.testing.expectEqual(@as(usize, 1), direct_env.direct_fn_signatures.count());
        },
        .generic_only => {
            try std.testing.expectEqual(prior_nodes + 1, direct_pool.nodes.items.len);
            try std.testing.expectEqual(TypeTag.t_generic_param, direct_pool.getTag(@intCast(prior_nodes)).?);
            try std.testing.expectEqual(@as(usize, 0), direct_env.direct_fn_signatures.count());
            try std.testing.expectEqual(@as(usize, 0), direct_env.fn_sigs_by_name.count());
            try std.testing.expectEqual(@as(usize, 0), direct_env.direct_accumulator_events);
        },
        .ignored_callable => {
            try std.testing.expectEqual(@as(usize, 0), direct.type_store.erased_type_prefixes.items.len);
            try std.testing.expectEqual(@as(usize, 1), direct.type_store.generic_owners.items.len);
            try std.testing.expectEqual(@as(usize, 1), direct.type_store.generic_parameters.items.len);
            try std.testing.expectEqual(
                @as(usize, 1),
                direct.type_store.projected_generic_parameters.items.len,
            );
            const owner = direct.type_store.generic_owners.items[0];
            try std.testing.expect(
                std.meta.activeTag(owner.compatibility) == .ignored_declaration_parameters,
            );
            try std.testing.expectEqualStrings("<T>", owner.list_span.text(source));
            try std.testing.expectEqual(@as(u32, 0), owner.authored_parameters.start);
            try std.testing.expectEqual(@as(u32, 1), owner.authored_parameters.count);
            try std.testing.expectEqual(@as(u32, 0), owner.projected_parameters.start);
            try std.testing.expectEqual(@as(u32, 1), owner.projected_parameters.count);
            const authored = direct.type_store.genericParameterSlice(
                owner.authored_parameters,
            ) orelse return error.TestUnexpectedResult;
            const projected = direct.type_store.projectedGenericParameterSlice(
                owner.projected_parameters,
            ) orelse return error.TestUnexpectedResult;
            try std.testing.expectEqual(@as(usize, 1), authored.len);
            try std.testing.expectEqualStrings("T", authored[0].trimmed_span.text(source));
            try std.testing.expectEqual(@as(usize, 1), projected.len);
            try std.testing.expectEqualStrings("T", projected[0].name_span.text(source));
            try std.testing.expect(projected[0].bound_fragment == null);
            try std.testing.expectEqual(@as(usize, 0), direct.type_store.semantic_fragments.items.len);
            const function_owner = switch (owner.identity) {
                .function => |node| node,
                else => return error.TestUnexpectedResult,
            };
            try std.testing.expectEqual(
                engine.parser.NodeTag.function_expr,
                direct_view.getTag(function_owner).?,
            );
            try std.testing.expectEqual(@as(usize, 0), direct.type_store.function_signatures.items.len);
            try std.testing.expectEqual(prior_nodes, direct_pool.nodes.items.len);
            try std.testing.expectEqual(prior_names, direct_env.name_storage.items.len);
            try std.testing.expectEqual(@as(usize, 0), direct_env.direct_fn_signatures.count());
            try std.testing.expectEqual(@as(usize, 0), direct_env.fn_sigs_by_name.count());
            try std.testing.expectEqual(@as(usize, 0), direct_env.direct_accumulator_events);
        },
        .ignored_prefix => {
            try std.testing.expectEqual(@as(usize, 1), direct.type_store.erased_type_prefixes.items.len);
            try std.testing.expectEqual(@as(usize, 0), direct.type_store.generic_parameters.items.len);
            try std.testing.expectEqual(
                @as(usize, 0),
                direct.type_store.projected_generic_parameters.items.len,
            );
            try std.testing.expectEqual(@as(usize, 0), direct.type_store.semantic_fragments.items.len);
            try std.testing.expectEqual(@as(usize, 0), direct.type_store.generic_owners.items.len);
            const prefix = direct.type_store.erased_type_prefixes.items[0];
            try std.testing.expectEqualStrings("<T>", prefix.list_span.text(source));
            switch (prefix.compatibility) {
                .ignored_parameters => {},
                .legacy_parameter_projection => return error.TestUnexpectedResult,
            }
            const expression_owner = switch (prefix.owner) {
                .expression => |node| node,
                .block => return error.TestUnexpectedResult,
            };
            try std.testing.expectEqual(
                engine.parser.NodeTag.object_literal,
                direct_view.getTag(expression_owner).?,
            );
            try std.testing.expectEqual(prior_nodes, direct_pool.nodes.items.len);
            try std.testing.expectEqual(prior_names, direct_env.name_storage.items.len);
            try std.testing.expectEqual(@as(usize, 0), direct_env.direct_fn_signatures.count());
            try std.testing.expectEqual(@as(usize, 0), direct_env.fn_sigs_by_name.count());
            try std.testing.expectEqual(@as(usize, 0), direct_env.direct_accumulator_events);
        },
        .empty_prefix => {
            try std.testing.expectEqual(@as(usize, 1), direct.type_store.erased_type_prefixes.items.len);
            try std.testing.expectEqual(@as(usize, 0), direct.type_store.generic_parameters.items.len);
            try std.testing.expectEqual(
                @as(usize, 0),
                direct.type_store.projected_generic_parameters.items.len,
            );
            try std.testing.expectEqual(@as(usize, 0), direct.type_store.semantic_fragments.items.len);
            try std.testing.expectEqual(@as(usize, 0), direct.type_store.generic_owners.items.len);
            const prefix = direct.type_store.erased_type_prefixes.items[0];
            try std.testing.expectEqualStrings("<>", prefix.list_span.text(source));
            const projection = switch (prefix.compatibility) {
                .legacy_parameter_projection => |value| value,
                .ignored_parameters => return error.TestUnexpectedResult,
            };
            try std.testing.expectEqual(@as(u32, 0), projection.projected_parameters.start);
            try std.testing.expectEqual(@as(u32, 0), projection.projected_parameters.count);
            try std.testing.expectEqual(@as(u32, 0), projection.semantic_fragments.start);
            try std.testing.expectEqual(@as(u32, 0), projection.semantic_fragments.count);
            const expression_owner = switch (prefix.owner) {
                .expression => |node| node,
                .block => return error.TestUnexpectedResult,
            };
            try std.testing.expectEqual(
                engine.parser.NodeTag.lit_int,
                direct_view.getTag(expression_owner).?,
            );
            try std.testing.expectEqual(prior_nodes, direct_pool.nodes.items.len);
            try std.testing.expectEqual(prior_names, direct_env.name_storage.items.len);
            try std.testing.expectEqual(@as(usize, 0), direct_env.direct_fn_signatures.count());
            try std.testing.expectEqual(@as(usize, 0), direct_env.fn_sigs_by_name.count());
            try std.testing.expectEqual(@as(usize, 0), direct_env.direct_accumulator_events);
        },
    }

    var legacy_checker = type_checker_mod.TypeChecker.init(
        std.testing.allocator,
        legacy_view,
        &legacy_atoms,
        &legacy_env,
    );
    defer legacy_checker.deinit();
    var direct_checker = type_checker_mod.TypeChecker.init(
        std.testing.allocator,
        direct_view,
        &direct_atoms,
        &direct_env,
    );
    defer direct_checker.deinit();
    try std.testing.expectEqual(
        try legacy_checker.check(legacy_root),
        try direct_checker.check(direct_root),
    );
    const legacy_type_diagnostics = legacy_checker.getDiagnostics();
    const direct_type_diagnostics = direct_checker.getDiagnostics();
    try std.testing.expectEqual(legacy_type_diagnostics.len, direct_type_diagnostics.len);
    for (legacy_type_diagnostics, direct_type_diagnostics) |legacy_diagnostic, direct_diagnostic| {
        try expectSameTypeDiagnostic(
            legacy_diagnostic,
            legacy_view,
            direct_diagnostic,
            direct_view,
        );
    }

    var legacy_strict = strict_checker_mod.StrictChecker.init(
        std.testing.allocator,
        legacy_view,
        &legacy_atoms,
        &legacy_env,
        &legacy_checker,
    );
    defer legacy_strict.deinit();
    var direct_strict = strict_checker_mod.StrictChecker.init(
        std.testing.allocator,
        direct_view,
        &direct_atoms,
        &direct_env,
        &direct_checker,
    );
    defer direct_strict.deinit();
    try std.testing.expectEqual(
        try legacy_strict.check(legacy_root),
        try direct_strict.check(direct_root),
    );
    const legacy_strict_diagnostics = legacy_strict.getDiagnostics();
    const direct_strict_diagnostics = direct_strict.getDiagnostics();
    try std.testing.expectEqual(legacy_strict_diagnostics.len, direct_strict_diagnostics.len);
    for (legacy_strict_diagnostics, direct_strict_diagnostics) |legacy_diagnostic, direct_diagnostic| {
        try expectSameStrictDiagnostic(
            legacy_diagnostic,
            legacy_view,
            direct_diagnostic,
            direct_view,
        );
    }
}

test "direct phase two consumer matrix preserves generics and headers" {
    const cases = [_]struct {
        source: []const u8,
        case: DirectGenericConsumerCase,
    }{
        .{
            .source = "const before = <P extends string>(1);\n" ++
                "function identity<T extends string>(value: T): T { return value; }\n" ++
                "const empty = <>(1);\n" ++
                "const after = <Q extends number>(2);",
            .case = .interleaved,
        },
        .{
            .source = "const value = <P extends { id: string }>(1);",
            .case = .compound_prefix,
        },
        .{
            .source = "function duplicate<T extends string, T extends number>(value: T): T { return value; }",
            .case = .duplicate_parameters,
        },
        .{
            .source = "const identity = <T extends string>(value: T): T => value;",
            .case = .generic_arrow,
        },
        .{
            .source = "function identity<>(value: string): string { return value; }",
            .case = .empty_callable,
        },
        .{
            .source = "function identity<T>(value) { return value; }",
            .case = .generic_only,
        },
        .{
            .source = "function identity<T>/* gap */(value) { return value; }",
            .case = .ignored_callable,
        },
        .{
            .source = "const value = (<T>{ id: 1 });",
            .case = .ignored_prefix,
        },
        .{
            .source = "const value = <>(1);",
            .case = .empty_prefix,
        },
    };
    try std.testing.expectEqual(std.meta.fields(DirectGenericConsumerCase).len, cases.len);
    var seen = std.EnumSet(DirectGenericConsumerCase).initEmpty();
    for (cases) |case| {
        try std.testing.expect(!seen.contains(case.case));
        try expectDirectGenericConsumer(case.source, case.case);
        seen.insert(case.case);
    }
    try std.testing.expectEqual(std.meta.fields(DirectGenericConsumerCase).len, seen.count());
}

fn compatibilityCallOwner(owner: TypeSyntax.GenericOwner) ?NodeIndex {
    if (std.meta.activeTag(owner.compatibility) != .legacy_call_arguments) return null;
    return switch (owner.identity) {
        .function => |node| node,
        .arrow => |node| node,
        .structural_declaration, .nominal_declaration => null,
    };
}

fn expectExactCallArguments(
    legacy_pool: *const TypePool,
    direct_pool: *const TypePool,
    legacy: type_env_mod.CallTypeArgs,
    direct: type_env_mod.CallTypeArgs,
) !void {
    try std.testing.expectEqual(legacy.count, direct.count);
    for (legacy.args[0..legacy.count], direct.args[0..direct.count]) |legacy_arg, direct_arg| {
        try std.testing.expectEqual(legacy_arg, direct_arg);
        try std.testing.expect(try orderedTypeEqual(
            std.testing.allocator,
            legacy_pool,
            legacy_arg,
            direct_pool,
            direct_arg,
        ));
    }
}

fn expectExactDirectCallMaps(
    legacy_pool: *const TypePool,
    direct_pool: *const TypePool,
    legacy_env: *const TypeEnv,
    direct_env: *const TypeEnv,
    legacy_view: engine.parser.IrView,
    direct_view: engine.parser.IrView,
    store: *const TypeSyntax.Store,
) !void {
    var expected_count: usize = 0;
    for (store.explicit_call_arguments.items) |record| {
        const fragments = store.semanticFragmentSlice(record.semantic_fragments) orelse
            return error.TestUnexpectedResult;
        const legacy = legacy_env.getCallTypeArgs(record.list_span.end);
        const direct = direct_env.getCallTypeArgsForCall(direct_view, record.owner);
        if (fragments.len == 0) {
            try std.testing.expect(legacy == null);
            try std.testing.expect(direct == null);
            continue;
        }
        expected_count += 1;
        try std.testing.expectEqual(engine.parser.NodeTag.call, direct_view.getTag(record.owner).?);
        try expectExactCallArguments(
            legacy_pool,
            direct_pool,
            legacy orelse return error.TestUnexpectedResult,
            direct orelse return error.TestUnexpectedResult,
        );
    }
    for (store.generic_owners.items) |record| {
        const owner = compatibilityCallOwner(record) orelse continue;
        const expected_tag: engine.parser.NodeTag = switch (record.identity) {
            .function => .function_expr,
            .arrow => .arrow_function,
            .structural_declaration, .nominal_declaration => unreachable,
        };
        try std.testing.expectEqual(expected_tag, direct_view.getTag(owner).?);
        const fragments = switch (record.compatibility) {
            .legacy_call_arguments => |arguments| store.semanticFragmentSlice(
                arguments.semantic_fragments,
            ) orelse return error.TestUnexpectedResult,
            .declaration_parameters, .ignored_declaration_parameters => unreachable,
        };
        const legacy_offset = (legacy_view.getLoc(owner) orelse
            return error.TestUnexpectedResult).offset;
        const legacy = legacy_env.getCallTypeArgs(legacy_offset);
        const direct = direct_env.direct_call_type_args.get(owner);
        try std.testing.expect(direct_env.getCallTypeArgsForCall(direct_view, owner) == null);
        if (fragments.len == 0) {
            try std.testing.expect(legacy == null);
            try std.testing.expect(direct == null);
            continue;
        }
        expected_count += 1;
        try expectExactCallArguments(
            legacy_pool,
            direct_pool,
            legacy orelse return error.TestUnexpectedResult,
            direct orelse return error.TestUnexpectedResult,
        );
    }
    try std.testing.expectEqual(expected_count, legacy_env.call_type_args.count());
    try std.testing.expectEqual(expected_count, direct_env.direct_call_type_args.count());

    var published = direct_env.direct_call_type_args.iterator();
    while (published.next()) |entry| {
        const published_owner = entry.key_ptr.*;
        var found = false;
        for (store.explicit_call_arguments.items) |record| {
            if (record.owner == published_owner and record.semantic_fragments.count != 0) {
                found = true;
                break;
            }
        }
        if (!found) for (store.generic_owners.items) |record| {
            const owner = compatibilityCallOwner(record) orelse continue;
            const count = switch (record.compatibility) {
                .legacy_call_arguments => |arguments| arguments.semantic_fragments.count,
                .declaration_parameters, .ignored_declaration_parameters => unreachable,
            };
            if (owner == published_owner and count != 0) {
                found = true;
                break;
            }
        };
        try std.testing.expect(found);
    }
}

const DirectCallConsumerCase = enum {
    interleaved,
    generic_scope_contrast,
    generic_application_argument,
    arrow_compatibility,
};

fn expectDirectCallConsumer(source: []const u8, case: DirectCallConsumerCase) !void {
    var prepared = try PreparedSource.init(
        std.testing.allocator,
        source,
        "<u12-phase-three>.ts",
        .{},
    );
    defer prepared.deinit();
    try std.testing.expectEqual(@as(usize, 0), prepared.stripDiagnostics().len);

    var legacy_count = CountingAllocator.init(std.testing.allocator);
    var direct_count = CountingAllocator.init(std.testing.allocator);
    var type_count = CountingAllocator.init(std.testing.allocator);
    var legacy_atoms = AtomTable.init(legacy_count.allocator());
    defer legacy_atoms.deinit();
    var direct_atoms = AtomTable.init(direct_count.allocator());
    defer direct_atoms.deinit();
    var legacy = try JsParser.init(legacy_count.allocator(), prepared.parserInput());
    defer legacy.deinit();
    legacy.setAtomTable(&legacy_atoms);
    var direct = try JsParser.initTyped(
        direct_count.allocator(),
        type_count.allocator(),
        source,
    );
    defer direct.deinit();
    direct.setAtomTable(&direct_atoms);
    const legacy_root = try legacy.parse();
    const direct_root = try direct.parse();
    const legacy_view = parserIrView(&legacy);
    const direct_view = parserIrView(&direct);
    try std.testing.expect(compareRuntime(
        &legacy,
        legacy_root,
        &legacy_atoms,
        &direct,
        direct_root,
        &direct_atoms,
    ) == null);
    try std.testing.expect(legacy_count.sameRuntimeShape(direct_count));

    var legacy_pool = TypePool.init(std.testing.allocator);
    defer legacy_pool.deinit(std.testing.allocator);
    var direct_pool = TypePool.init(std.testing.allocator);
    defer direct_pool.deinit(std.testing.allocator);
    var legacy_env = TypeEnv.init(std.testing.allocator, &legacy_pool);
    defer legacy_env.deinit();
    var direct_env = TypeEnv.init(std.testing.allocator, &direct_pool);
    defer direct_env.deinit();
    module_types.populateModuleTypes(&legacy_env, &legacy_pool, std.testing.allocator);
    abi_types.populateHandlerAbiTypes(&legacy_env, &legacy_pool, std.testing.allocator);
    module_types.populateModuleTypes(&direct_env, &direct_pool, std.testing.allocator);
    abi_types.populateHandlerAbiTypes(&direct_env, &direct_pool, std.testing.allocator);
    const prior_nodes = direct_pool.nodes.items.len;
    try legacy_env.populateSourceTypes(.{ .legacy = prepared.typeMap().? });
    try direct_env.populateSourceTypes(.{ .direct = .{
        .store = &direct.type_store,
        .ir_view = direct_view,
        .atoms = &direct_atoms,
    } });
    try expectExactTypePool(&legacy_pool, &direct_pool);
    try expectExactFunctionNameMaps(&legacy_env, &direct_env);
    try expectExactOwnerSignatures(
        &legacy_env,
        &direct_env,
        legacy_view,
        direct_view,
        &direct.type_store,
    );
    try expectExactDirectCallMaps(
        &legacy_pool,
        &direct_pool,
        &legacy_env,
        &direct_env,
        legacy_view,
        direct_view,
        &direct.type_store,
    );
    try legacy_pool.ensureHealthy();
    try direct_pool.ensureHealthy();
    try legacy_env.ensureHealthy();
    try direct_env.ensureHealthy();
    try std.testing.expectEqual(@as(usize, 0), direct_env.generic_scopes.items.len);

    switch (case) {
        .interleaved => {
            try std.testing.expectEqual(@as(usize, 3), direct.type_store.explicit_call_arguments.items.len);
            try std.testing.expectEqual(@as(usize, 2), direct.type_store.generic_owners.items.len);
            try std.testing.expectEqual(@as(usize, 3), direct_env.direct_call_type_args.count());
            const before = direct.type_store.explicit_call_arguments.items[0];
            const empty = direct.type_store.explicit_call_arguments.items[1];
            const after = direct.type_store.explicit_call_arguments.items[2];
            try std.testing.expectEqualStrings("<string>", before.list_span.text(source));
            try std.testing.expectEqualStrings("<>", empty.list_span.text(source));
            try std.testing.expectEqualStrings("<(),number>", after.list_span.text(source));
            try std.testing.expect(direct_env.getCallTypeArgsForCall(direct_view, empty.owner) == null);
            const after_arguments = direct_env.getCallTypeArgsForCall(
                direct_view,
                after.owner,
            ) orelse return error.TestUnexpectedResult;
            try std.testing.expectEqual(@as(u8, 2), after_arguments.count);
            try std.testing.expectEqual(null_type_idx, after_arguments.args[0]);
            try std.testing.expectEqual(direct_pool.idx_number, after_arguments.args[1]);
            const compatibility = direct.type_store.generic_owners.items[0];
            const compatibility_owner = compatibilityCallOwner(compatibility) orelse
                return error.TestUnexpectedResult;
            const compatibility_arguments = direct_env.direct_call_type_args.get(
                compatibility_owner,
            ) orelse return error.TestUnexpectedResult;
            try std.testing.expectEqual(@as(u8, 1), compatibility_arguments.count);
            try std.testing.expectEqual(
                TypeTag.t_ref,
                direct_pool.getTag(compatibility_arguments.args[0]).?,
            );
            try std.testing.expectEqualStrings(
                "T",
                direct_pool.getRefName(compatibility_arguments.args[0]),
            );
            const empty_compatibility = direct.type_store.generic_owners.items[1];
            const empty_compatibility_owner = compatibilityCallOwner(empty_compatibility) orelse
                return error.TestUnexpectedResult;
            const empty_compatibility_range = switch (empty_compatibility.compatibility) {
                .legacy_call_arguments => |arguments| arguments.semantic_fragments,
                .declaration_parameters, .ignored_declaration_parameters => return error.TestUnexpectedResult,
            };
            try std.testing.expectEqual(@as(u32, 0), empty_compatibility_range.count);
            try std.testing.expect(
                direct_env.direct_call_type_args.get(empty_compatibility_owner) == null,
            );
            try std.testing.expect(
                direct_env.getCallTypeArgsForCall(direct_view, empty_compatibility_owner) == null,
            );
        },
        .generic_scope_contrast => {
            try std.testing.expectEqual(@as(usize, 1), direct.type_store.explicit_call_arguments.items.len);
            try std.testing.expectEqual(@as(usize, 1), direct_env.direct_call_type_args.count());
            const call = direct.type_store.explicit_call_arguments.items[0];
            const call_arguments = direct_env.getCallTypeArgsForCall(
                direct_view,
                call.owner,
            ) orelse return error.TestUnexpectedResult;
            try std.testing.expectEqual(@as(u8, 1), call_arguments.count);
            try std.testing.expectEqual(TypeTag.t_ref, direct_pool.getTag(call_arguments.args[0]).?);
            try std.testing.expectEqualStrings("T", direct_pool.getRefName(call_arguments.args[0]));
            var outer_owner: ?NodeIndex = null;
            for (direct.type_store.generic_owners.items) |owner| switch (owner.identity) {
                .function => |node| if (std.meta.activeTag(owner.compatibility) == .declaration_parameters) {
                    outer_owner = node;
                },
                .structural_declaration, .nominal_declaration, .arrow => {},
            };
            const owner = outer_owner orelse return error.TestUnexpectedResult;
            const reference = direct_env.functionTypeRef(direct_view, owner) orelse
                return error.TestUnexpectedResult;
            const signature = direct_env.getFunctionSignature(reference) orelse
                return error.TestUnexpectedResult;
            try std.testing.expectEqual(@as(u8, 1), signature.type_param_count);
            try std.testing.expectEqual(@as(u8, 1), signature.param_count);
            try std.testing.expectEqual(signature.type_params[0].idx, signature.param_types[0]);
            try std.testing.expectEqual(signature.type_params[0].idx, signature.return_type);
            try std.testing.expect(signature.type_params[0].idx != call_arguments.args[0]);
            try std.testing.expectEqual(TypeTag.t_generic_param, direct_pool.getTag(signature.type_params[0].idx).?);
            try std.testing.expectEqual(
                @as(usize, 1),
                poolTagCount(&direct_pool, prior_nodes, .t_generic_param),
            );
        },
        .generic_application_argument => {
            try std.testing.expectEqual(@as(usize, 1), direct.type_store.explicit_call_arguments.items.len);
            try std.testing.expectEqual(@as(usize, 0), direct.type_store.generic_owners.items.len);
            const record = direct.type_store.explicit_call_arguments.items[0];
            try std.testing.expectEqualStrings("<Box<string>>", record.list_span.text(source));
            const fragments = direct.type_store.semanticFragmentSlice(record.semantic_fragments) orelse
                return error.TestUnexpectedResult;
            try std.testing.expectEqual(@as(usize, 1), fragments.len);
            const root = switch (fragments[0].root) {
                .present => |root| root,
                .absent => return error.TestUnexpectedResult,
            };
            try std.testing.expectEqual(
                TypeSyntax.NodeTag.generic_application,
                std.meta.activeTag(direct.type_store.nodes.items[root].data),
            );
            const arguments = direct_env.getCallTypeArgsForCall(direct_view, record.owner) orelse
                return error.TestUnexpectedResult;
            try std.testing.expectEqual(@as(u8, 1), arguments.count);
            try std.testing.expectEqual(TypeTag.t_generic_app, direct_pool.getTag(arguments.args[0]).?);
            const application = direct_pool.getGenericAppInfo(arguments.args[0]);
            try std.testing.expectEqual(TypeTag.t_ref, direct_pool.getTag(application.base).?);
            try std.testing.expectEqualStrings("Box", direct_pool.getRefName(application.base));
            try std.testing.expectEqualSlices(TypeIndex, &.{direct_pool.idx_string}, application.args);
        },
        .arrow_compatibility => {
            try std.testing.expectEqual(@as(usize, 0), direct.type_store.explicit_call_arguments.items.len);
            try std.testing.expectEqual(@as(usize, 1), direct.type_store.generic_owners.items.len);
            const record = direct.type_store.generic_owners.items[0];
            const owner = switch (record.identity) {
                .arrow => |owner| owner,
                else => return error.TestUnexpectedResult,
            };
            try std.testing.expectEqual(engine.parser.NodeTag.arrow_function, direct_view.getTag(owner).?);
            try std.testing.expectEqual(
                std.meta.Tag(TypeSyntax.GenericOwnerCompatibility).legacy_call_arguments,
                std.meta.activeTag(record.compatibility),
            );
            try std.testing.expectEqualStrings("<T>", record.list_span.text(source));
            const arguments = direct_env.direct_call_type_args.get(owner) orelse return error.TestUnexpectedResult;
            try std.testing.expectEqual(@as(u8, 1), arguments.count);
            try std.testing.expectEqual(TypeTag.t_ref, direct_pool.getTag(arguments.args[0]).?);
            try std.testing.expectEqualStrings("T", direct_pool.getRefName(arguments.args[0]));
            try std.testing.expect(direct_env.getCallTypeArgsForCall(direct_view, owner) == null);
            try std.testing.expectEqual(@as(usize, 1), direct_env.direct_call_type_args.count());
        },
    }

    var legacy_checker = type_checker_mod.TypeChecker.init(
        std.testing.allocator,
        legacy_view,
        &legacy_atoms,
        &legacy_env,
    );
    defer legacy_checker.deinit();
    var direct_checker = type_checker_mod.TypeChecker.init(
        std.testing.allocator,
        direct_view,
        &direct_atoms,
        &direct_env,
    );
    defer direct_checker.deinit();
    try std.testing.expectEqual(
        try legacy_checker.check(legacy_root),
        try direct_checker.check(direct_root),
    );
    try std.testing.expectEqual(
        legacy_checker.getDiagnostics().len,
        direct_checker.getDiagnostics().len,
    );
    for (legacy_checker.getDiagnostics(), direct_checker.getDiagnostics()) |legacy_diag, direct_diag| {
        try expectSameTypeDiagnostic(legacy_diag, legacy_view, direct_diag, direct_view);
    }

    var legacy_strict = strict_checker_mod.StrictChecker.init(
        std.testing.allocator,
        legacy_view,
        &legacy_atoms,
        &legacy_env,
        &legacy_checker,
    );
    defer legacy_strict.deinit();
    var direct_strict = strict_checker_mod.StrictChecker.init(
        std.testing.allocator,
        direct_view,
        &direct_atoms,
        &direct_env,
        &direct_checker,
    );
    defer direct_strict.deinit();
    try std.testing.expectEqual(
        try legacy_strict.check(legacy_root),
        try direct_strict.check(direct_root),
    );
    try std.testing.expectEqual(
        legacy_strict.getDiagnostics().len,
        direct_strict.getDiagnostics().len,
    );
    for (legacy_strict.getDiagnostics(), direct_strict.getDiagnostics()) |legacy_diag, direct_diag| {
        try expectSameStrictDiagnostic(legacy_diag, legacy_view, direct_diag, direct_view);
    }
}

test "direct phase three preserves actual and compatibility call construction" {
    const cases = [_]struct {
        source: []const u8,
        case: DirectCallConsumerCase,
    }{
        .{
            .source = "const before = identity<string>(\"a\");\n" ++
                "function /* gap */ identity<T>(value) { return value; }\n" ++
                "const empty = identity<>(\"e\");\n" ++
                "function /* gap */ empty_owner<>(value) { return value; }\n" ++
                "const after = identity<(),number>(\"b\");",
            .case = .interleaved,
        },
        .{
            .source = "function identity(value) { return value; }\n" ++
                "function outer<T>(value: T): T {\n" ++
                "  const result = identity<T>(value);\n" ++
                "  return value;\n" ++
                "}",
            .case = .generic_scope_contrast,
        },
        .{
            .source = "function identity(value) { return value; }\n" ++
                "const result = identity<Box<string>>(\"value\");",
            .case = .generic_application_argument,
        },
        .{
            .source = "const id = // note\n<T>(value: T): T => value;",
            .case = .arrow_compatibility,
        },
    };
    var seen = std.EnumSet(DirectCallConsumerCase).initEmpty();
    for (cases) |case| {
        try expectDirectCallConsumer(case.source, case.case);
        seen.insert(case.case);
    }
    try std.testing.expectEqual(std.meta.fields(DirectCallConsumerCase).len, seen.count());
}

const DirectCallOrderMutation = enum {
    reversed_actual,
    equal_cross_stream,
    reversed_compatibility,
};

fn expectDirectCallOrderRefusal(
    source: []const u8,
    mutation: DirectCallOrderMutation,
) !void {
    var runtime_count = CountingAllocator.init(std.testing.allocator);
    var atoms = AtomTable.init(runtime_count.allocator());
    defer atoms.deinit();
    var parser = try JsParser.initTyped(
        runtime_count.allocator(),
        std.testing.allocator,
        source,
    );
    defer parser.deinit();
    parser.setAtomTable(&atoms);
    const root = try parser.parse();
    try expectRuntimeParityAndShape(source, &parser, root, &atoms, runtime_count);

    const expected_error: anyerror = switch (mutation) {
        .reversed_actual => blk: {
            try std.testing.expectEqual(
                @as(usize, 2),
                parser.type_store.explicit_call_arguments.items.len,
            );
            std.mem.swap(
                TypeSyntax.ExplicitCallArguments,
                &parser.type_store.explicit_call_arguments.items[0],
                &parser.type_store.explicit_call_arguments.items[1],
            );
            break :blk error.InvalidTypeSourceOrder;
        },
        .equal_cross_stream => blk: {
            try std.testing.expectEqual(
                @as(usize, 1),
                parser.type_store.explicit_call_arguments.items.len,
            );
            try std.testing.expectEqual(@as(usize, 1), parser.type_store.generic_owners.items.len);
            parser.type_store.generic_owners.items[0].list_span.start =
                parser.type_store.explicit_call_arguments.items[0].list_span.start;
            break :blk error.InvalidGenericOwner;
        },
        .reversed_compatibility => blk: {
            try std.testing.expectEqual(@as(usize, 2), parser.type_store.generic_owners.items.len);
            try std.testing.expect(compatibilityCallOwner(
                parser.type_store.generic_owners.items[0],
            ) != null);
            try std.testing.expect(compatibilityCallOwner(
                parser.type_store.generic_owners.items[1],
            ) != null);
            std.mem.swap(
                TypeSyntax.GenericOwner,
                &parser.type_store.generic_owners.items[0],
                &parser.type_store.generic_owners.items[1],
            );
            break :blk error.InvalidTypeSourceOrder;
        },
    };

    switch (mutation) {
        .reversed_actual => try parser.type_store.validateRuntimeOwners(
            std.testing.allocator,
            parserIrView(&parser),
        ),
        .equal_cross_stream, .reversed_compatibility => try std.testing.expectError(
            expected_error,
            parser.type_store.validateRuntimeOwners(std.testing.allocator, parserIrView(&parser)),
        ),
    }

    var pool = TypePool.init(std.testing.allocator);
    defer pool.deinit(std.testing.allocator);
    var env = TypeEnv.init(std.testing.allocator, &pool);
    defer env.deinit();
    const prior_nodes = pool.nodes.items.len;
    const prior_names = env.name_storage.items.len;
    const prior_scopes = env.generic_scopes.items.len;
    const prior_aliases = env.type_aliases.count();
    const prior_generic_aliases = env.generic_aliases.count();
    try std.testing.expectError(
        expected_error,
        env.populateSourceTypes(.{ .direct = .{
            .store = &parser.type_store,
            .ir_view = parserIrView(&parser),
            .atoms = &atoms,
        } }),
    );
    try std.testing.expect(env.sourceTypeMode() == null);
    try std.testing.expectEqual(prior_nodes, pool.nodes.items.len);
    try std.testing.expectEqual(prior_names, env.name_storage.items.len);
    try std.testing.expectEqual(prior_scopes, env.generic_scopes.items.len);
    try std.testing.expectEqual(prior_aliases, env.type_aliases.count());
    try std.testing.expectEqual(prior_generic_aliases, env.generic_aliases.count());
    try std.testing.expectEqual(@as(usize, 0), env.direct_call_type_args.count());
    try std.testing.expectEqual(@as(usize, 0), env.direct_var_types.count());
    try std.testing.expectEqual(@as(usize, 0), env.direct_fn_signatures.count());
    try pool.ensureHealthy();
    try env.ensureHealthy();
}

test "direct phase three refuses malformed call order before selection" {
    const cases = [_]struct {
        source: []const u8,
        mutation: DirectCallOrderMutation,
    }{
        .{
            .source = "const first = identity<string>(\"a\");\n" ++
                "const second = identity<number>(1);",
            .mutation = .reversed_actual,
        },
        .{
            .source = "const first = identity<string>(\"a\");\n" ++
                "function /* gap */ identity<T>(value) { return value; }",
            .mutation = .equal_cross_stream,
        },
        .{
            .source = "function /* gap */ first<T>(value) { return value; }\n" ++
                "function /* gap */ second<U>(value) { return value; }",
            .mutation = .reversed_compatibility,
        },
    };
    var seen = std.EnumSet(DirectCallOrderMutation).initEmpty();
    for (cases) |case| {
        try expectDirectCallOrderRefusal(case.source, case.mutation);
        seen.insert(case.mutation);
    }
    try std.testing.expectEqual(std.meta.fields(DirectCallOrderMutation).len, seen.count());
}

const DirectCallAllocationObservations = struct {
    unselected_validation_failures: usize = 0,
    selected_failures: usize = 0,
    post_seed_failures: usize = 0,
    incomplete_publication_failures: usize = 0,
    successes: usize = 0,
};

fn runDirectCallAllocationSweep(
    allocator: std.mem.Allocator,
    observations: *DirectCallAllocationObservations,
) !void {
    const source =
        "structural Seed = string;\n" ++
        "const first: Seed = identity<Seed>(\"a\");\n" ++
        "function /* gap */ identity<T>(value) { return value; }\n" ++
        "const second: Seed = identity<{ id: string }>(\"b\");";
    var runtime_count = CountingAllocator.init(std.testing.allocator);
    var atoms = AtomTable.init(runtime_count.allocator());
    defer atoms.deinit();
    var parser = try JsParser.initTyped(
        runtime_count.allocator(),
        std.testing.allocator,
        source,
    );
    defer parser.deinit();
    parser.setAtomTable(&atoms);
    const root = try parser.parse();
    try expectRuntimeParityAndShape(source, &parser, root, &atoms, runtime_count);
    try std.testing.expectEqual(@as(usize, 2), parser.type_store.explicit_call_arguments.items.len);
    try std.testing.expectEqual(@as(usize, 1), parser.type_store.generic_owners.items.len);

    var pool = TypePool.init(allocator);
    defer pool.deinit(allocator);
    var env = TypeEnv.init(allocator, &pool);
    defer env.deinit();
    const prior_nodes = pool.nodes.items.len;
    env.populateSourceTypes(.{ .direct = .{
        .store = &parser.type_store,
        .ir_view = parserIrView(&parser),
        .atoms = &atoms,
    } }) catch |err| {
        try std.testing.expectEqual(@as(usize, 0), env.generic_scopes.items.len);
        if (env.sourceTypeMode() == null) {
            observations.unselected_validation_failures += 1;
            try std.testing.expectEqual(prior_nodes, pool.nodes.items.len);
            try std.testing.expectEqual(@as(usize, 0), env.direct_call_type_args.count());
        } else {
            observations.selected_failures += 1;
            try std.testing.expectEqual(type_env_mod.SourceTypeMode.direct, env.sourceTypeMode().?);
            const has_seed = env.getTypeAlias("Seed") != null;
            if (has_seed) observations.post_seed_failures += 1;
            if (has_seed and env.direct_call_type_args.count() > 0 and
                env.direct_call_type_args.count() < 3)
            {
                observations.incomplete_publication_failures += 1;
            }
        }
        try std.testing.expectError(error.OutOfMemory, env.ensureHealthy());
        var checker = type_checker_mod.TypeChecker.init(
            std.testing.allocator,
            parserIrView(&parser),
            &atoms,
            &env,
        );
        defer checker.deinit();
        try std.testing.expectError(error.OutOfMemory, checker.check(root));
        var strict = strict_checker_mod.StrictChecker.init(
            std.testing.allocator,
            parserIrView(&parser),
            &atoms,
            &env,
            null,
        );
        defer strict.deinit();
        try std.testing.expectError(error.OutOfMemory, strict.check(root));
        return err;
    };

    observations.successes += 1;
    try pool.ensureHealthy();
    try env.ensureHealthy();
    try std.testing.expectEqual(@as(usize, 0), env.generic_scopes.items.len);
    try std.testing.expect(env.getTypeAlias("Seed") != null);
    try std.testing.expectEqual(@as(usize, 3), env.direct_call_type_args.count());

    var prepared = try PreparedSource.init(
        std.testing.allocator,
        source,
        "<u12-phase-three-oom>.ts",
        .{},
    );
    defer prepared.deinit();
    var legacy_atoms = AtomTable.init(std.testing.allocator);
    defer legacy_atoms.deinit();
    var legacy = try JsParser.init(std.testing.allocator, prepared.parserInput());
    defer legacy.deinit();
    legacy.setAtomTable(&legacy_atoms);
    _ = try legacy.parse();
    var legacy_pool = TypePool.init(std.testing.allocator);
    defer legacy_pool.deinit(std.testing.allocator);
    var legacy_env = TypeEnv.init(std.testing.allocator, &legacy_pool);
    defer legacy_env.deinit();
    try legacy_env.populateSourceTypes(.{ .legacy = prepared.typeMap().? });
    try expectExactTypePool(&legacy_pool, &pool);
    try expectExactDirectCallMaps(
        &legacy_pool,
        &pool,
        &legacy_env,
        &env,
        parserIrView(&legacy),
        parserIrView(&parser),
        &parser.type_store,
    );
}

test "direct phase three allocation failures retain selection and incomplete calls" {
    var observations: DirectCallAllocationObservations = .{};
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        runDirectCallAllocationSweep,
        .{&observations},
    );
    try std.testing.expect(observations.unselected_validation_failures > 0);
    try std.testing.expect(observations.selected_failures > 0);
    try std.testing.expect(observations.post_seed_failures > 0);
    try std.testing.expect(observations.incomplete_publication_failures > 0);
    try std.testing.expect(observations.successes > 0);
}

const DirectPredicateCase = enum {
    named_value,
    arrow_value,
    named_guard_verified,
    named_guard_unverified,
    arrow_guard_unverified,
    ordinary_tab,
    arrow_ordinary_tab,
    readonly_tab,
    quoted_value,
    empty_narrowing,
    unresolved_target,
    mixed_untyped_target,
    compact_target_position,
    repeated_target,
    target_after_sixteen,
    captured_generic,
    trailing_ordinary,
    quoted_marker_space,
    quoted_marker_tab,
};

const ExpectedPredicate = union(enum) {
    absent,
    parameter: u8,
    captured_generic,
    literal: []const u8,
};

fn expectDirectPredicateConsumer(
    source: []const u8,
    case: DirectPredicateCase,
    expected_predicate: ExpectedPredicate,
    expected_return_spelling: ?[]const u8,
) !void {
    errdefer |err| std.debug.print(
        "direct predicate case {s} failed with {s}\nsource: {s}\n",
        .{ @tagName(case), @errorName(err), source },
    );
    var prepared = try PreparedSource.init(
        std.testing.allocator,
        source,
        "<u12-predicate>.ts",
        .{},
    );
    defer prepared.deinit();
    try std.testing.expectEqual(@as(usize, 0), prepared.stripDiagnostics().len);

    var legacy_count = CountingAllocator.init(std.testing.allocator);
    var direct_count = CountingAllocator.init(std.testing.allocator);
    var type_count = CountingAllocator.init(std.testing.allocator);
    var legacy_atoms = AtomTable.init(legacy_count.allocator());
    defer legacy_atoms.deinit();
    var direct_atoms = AtomTable.init(direct_count.allocator());
    defer direct_atoms.deinit();
    var legacy = try JsParser.init(legacy_count.allocator(), prepared.parserInput());
    defer legacy.deinit();
    legacy.setAtomTable(&legacy_atoms);
    var direct = try JsParser.initTyped(
        direct_count.allocator(),
        type_count.allocator(),
        source,
    );
    defer direct.deinit();
    direct.setAtomTable(&direct_atoms);
    const legacy_root = try legacy.parse();
    const direct_root = try direct.parse();
    const legacy_view = parserIrView(&legacy);
    const direct_view = parserIrView(&direct);
    try std.testing.expect(compareRuntime(
        &legacy,
        legacy_root,
        &legacy_atoms,
        &direct,
        direct_root,
        &direct_atoms,
    ) == null);
    try std.testing.expect(legacy_count.sameRuntimeShape(direct_count));

    try std.testing.expectEqual(@as(usize, 1), direct.type_store.function_signatures.items.len);
    const syntax_signature = direct.type_store.function_signatures.items[0];
    const return_syntax = syntax_signature.return_syntax orelse return error.TestUnexpectedResult;

    var legacy_pool = TypePool.init(std.testing.allocator);
    defer legacy_pool.deinit(std.testing.allocator);
    var direct_pool = TypePool.init(std.testing.allocator);
    defer direct_pool.deinit(std.testing.allocator);
    var legacy_env = TypeEnv.init(std.testing.allocator, &legacy_pool);
    defer legacy_env.deinit();
    var direct_env = TypeEnv.init(std.testing.allocator, &direct_pool);
    defer direct_env.deinit();
    module_types.populateModuleTypes(&legacy_env, &legacy_pool, std.testing.allocator);
    abi_types.populateHandlerAbiTypes(&legacy_env, &legacy_pool, std.testing.allocator);
    module_types.populateModuleTypes(&direct_env, &direct_pool, std.testing.allocator);
    abi_types.populateHandlerAbiTypes(&direct_env, &direct_pool, std.testing.allocator);
    const prior_nodes = direct_pool.nodes.items.len;
    try legacy_env.populateSourceTypes(.{ .legacy = prepared.typeMap().? });
    try direct_env.populateSourceTypes(.{ .direct = .{
        .store = &direct.type_store,
        .ir_view = direct_view,
        .atoms = &direct_atoms,
    } });
    try expectExactTypePool(&legacy_pool, &direct_pool);
    try expectExactFunctionNameMaps(&legacy_env, &direct_env);
    try expectExactOwnerSignatures(
        &legacy_env,
        &direct_env,
        legacy_view,
        direct_view,
        &direct.type_store,
    );
    try expectExactDirectCallMaps(
        &legacy_pool,
        &direct_pool,
        &legacy_env,
        &direct_env,
        legacy_view,
        direct_view,
        &direct.type_store,
    );
    try legacy_pool.ensureHealthy();
    try direct_pool.ensureHealthy();
    try legacy_env.ensureHealthy();
    try direct_env.ensureHealthy();
    try std.testing.expectEqual(@as(usize, 0), direct_env.generic_scopes.items.len);

    const direct_reference = direct_env.functionTypeRef(
        direct_view,
        syntax_signature.owner,
    ) orelse return error.TestUnexpectedResult;
    const legacy_reference = legacy_env.functionTypeRef(
        legacy_view,
        syntax_signature.owner,
    ) orelse return error.TestUnexpectedResult;
    const direct_signature = direct_env.getFunctionSignature(direct_reference) orelse
        return error.TestUnexpectedResult;
    const legacy_signature = legacy_env.getFunctionSignature(legacy_reference) orelse
        return error.TestUnexpectedResult;
    try expectExactFunctionSignature(legacy_signature, direct_signature);

    if (expected_return_spelling) |expected| {
        try std.testing.expectEqualStrings(
            expected,
            direct_env.getFunctionReturnSpelling(direct_reference) orelse
                return error.TestUnexpectedResult,
        );
    } else {
        try std.testing.expect(direct_env.getFunctionReturnSpelling(direct_reference) == null);
    }

    switch (expected_predicate) {
        .absent => try std.testing.expect(direct_signature.type_predicate == null),
        .parameter => |expected_index| {
            const predicate = direct_signature.type_predicate orelse
                return error.TestUnexpectedResult;
            try std.testing.expectEqual(expected_index, predicate.param_index);
            try std.testing.expectEqual(direct_pool.idx_string, predicate.narrowed);
        },
        .captured_generic => {
            const predicate = direct_signature.type_predicate orelse
                return error.TestUnexpectedResult;
            try std.testing.expectEqual(@as(u8, 0), predicate.param_index);
            try std.testing.expectEqual(@as(u8, 1), direct_signature.type_param_count);
            try std.testing.expectEqual(direct_signature.type_params[0].idx, predicate.narrowed);
            try std.testing.expectEqualStrings("T", direct_signature.type_params[0].name);
            try std.testing.expectEqual(
                prior_nodes,
                @as(usize, @intCast(direct_signature.type_params[0].idx)),
            );
        },
        .literal => |expected_literal| {
            const predicate = direct_signature.type_predicate orelse
                return error.TestUnexpectedResult;
            try std.testing.expectEqual(@as(u8, 0), predicate.param_index);
            try std.testing.expectEqual(
                TypeTag.t_literal_string,
                direct_pool.getTag(predicate.narrowed).?,
            );
            try std.testing.expectEqualStrings(
                expected_literal,
                direct_pool.getLiteralStringValue(predicate.narrowed).?,
            );
        },
    }

    if (case == .mixed_untyped_target or case == .compact_target_position or
        case == .repeated_target or case == .target_after_sixteen)
    {
        const predicate = switch (return_syntax.structure) {
            .predicate => |value| value,
            .value => return error.TestUnexpectedResult,
        };
        const target = switch (predicate.target) {
            .resolved => |value| value,
            .unresolved => return error.TestUnexpectedResult,
        };
        const function = direct_view.getFunction(syntax_signature.owner) orelse
            return error.TestUnexpectedResult;
        const expected_actual_position: u8 = switch (case) {
            .mixed_untyped_target, .repeated_target => 0,
            .compact_target_position => 2,
            .target_after_sixteen => 16,
            else => unreachable,
        };
        try std.testing.expectEqual(
            direct_view.getListIndex(function.params_start, expected_actual_position),
            target.pattern,
        );
        try std.testing.expectEqual(
            switch (case) {
                .mixed_untyped_target => @as(u8, 1),
                .compact_target_position, .repeated_target => 2,
                .target_after_sixteen => 16,
                else => unreachable,
            },
            direct_signature.param_count,
        );
    }

    if (case == .unresolved_target or case == .mixed_untyped_target or
        case == .target_after_sixteen)
    {
        const predicate = switch (return_syntax.structure) {
            .predicate => |value| value,
            .value => return error.TestUnexpectedResult,
        };
        try std.testing.expect(predicate.narrowed.node_range.count > 0);
        try std.testing.expectEqualStrings(
            "string[]",
            predicate.narrowed.raw_span.text(source),
        );
        const narrowed_root = direct.type_store.node(
            try syntaxChildIndex(predicate.narrowed.root),
        ) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqual(TypeSyntax.NodeTag.array, narrowed_root.tag);
        try std.testing.expect(direct_signature.type_predicate == null);
        try std.testing.expectEqual(prior_nodes, direct_pool.nodes.items.len);
    }

    switch (case) {
        .named_value, .arrow_value, .trailing_ordinary => {
            try std.testing.expectEqual(
                TypeSyntax.LegacyReturnKind.ordinary,
                return_syntax.legacy_return_kind,
            );
            try std.testing.expectEqual(direct_pool.idx_string, direct_signature.return_type);
        },
        .ordinary_tab, .arrow_ordinary_tab => {
            try std.testing.expectEqual(
                TypeSyntax.LegacyReturnKind.ordinary,
                return_syntax.legacy_return_kind,
            );
            try std.testing.expect(return_syntax.legacy_ordinary_prefix != null);
            try std.testing.expectEqualStrings(
                "candidate\tis\tstring ",
                return_syntax.raw_span.text(source),
            );
            try std.testing.expectEqual(TypeTag.t_ref, direct_pool.getTag(direct_signature.return_type).?);
            try std.testing.expectEqualStrings(
                "candidate",
                direct_pool.getRefName(direct_signature.return_type),
            );
        },
        .readonly_tab => {
            try std.testing.expectEqual(
                TypeSyntax.LegacyReturnKind.ordinary,
                return_syntax.legacy_return_kind,
            );
            try std.testing.expect(return_syntax.legacy_ordinary_prefix != null);
            try std.testing.expectEqual(
                TypeTag.t_ref,
                direct_pool.getTag(direct_signature.return_type).?,
            );
            try std.testing.expectEqualStrings(
                "is",
                direct_pool.getRefName(direct_signature.return_type),
            );
        },
        .empty_narrowing => {
            const predicate = switch (return_syntax.structure) {
                .predicate => |value| value,
                .value => return error.TestUnexpectedResult,
            };
            switch (predicate.narrowed.root) {
                .absent => {},
                .present => return error.TestUnexpectedResult,
            }
            try std.testing.expectEqual(@as(u32, 0), predicate.narrowed.node_range.count);
            try std.testing.expectEqualStrings(" ", predicate.narrowed.raw_span.text(source));
        },
        .quoted_value => {
            try std.testing.expectEqual(
                TypeSyntax.LegacyReturnKind.type_guard,
                return_syntax.legacy_return_kind,
            );
            switch (return_syntax.structure) {
                .value => {},
                .predicate => return error.TestUnexpectedResult,
            }
            try std.testing.expectEqual(direct_pool.idx_boolean, direct_signature.return_type);
        },
        .quoted_marker_tab => {
            try std.testing.expectEqual(
                TypeSyntax.LegacyReturnKind.type_guard,
                return_syntax.legacy_return_kind,
            );
            const predicate = switch (return_syntax.structure) {
                .predicate => |value| value,
                .value => return error.TestUnexpectedResult,
            };
            try std.testing.expectEqualStrings("candidate", predicate.target_span.text(source));
            try std.testing.expectEqualStrings("\"a is b\"", predicate.narrowed.raw_span.text(source));
            const target = switch (predicate.target) {
                .resolved => |value| value,
                .unresolved => return error.TestUnexpectedResult,
            };
            const function = direct_view.getFunction(syntax_signature.owner) orelse
                return error.TestUnexpectedResult;
            const first_parameter = direct_view.getListIndex(function.params_start, 0);
            try std.testing.expectEqual(first_parameter, target.pattern);
            try std.testing.expect(std.meta.eql(
                direct_view.paramBinding(first_parameter).?,
                target.binding,
            ));
            try std.testing.expectEqualStrings(
                "candidate\tis \"a is b\" ",
                return_syntax.raw_span.text(source),
            );
            try std.testing.expectEqual(direct_pool.idx_boolean, direct_signature.return_type);
        },
        .quoted_marker_space => {
            try std.testing.expectEqual(
                TypeSyntax.LegacyReturnKind.type_guard,
                return_syntax.legacy_return_kind,
            );
            const predicate = switch (return_syntax.structure) {
                .predicate => |value| value,
                .value => return error.TestUnexpectedResult,
            };
            try std.testing.expectEqualStrings("candidate", predicate.target_span.text(source));
            try std.testing.expectEqualStrings("\"a is b\"", predicate.narrowed.raw_span.text(source));
            try std.testing.expectEqualStrings(
                "candidate is \"a is b\" ",
                return_syntax.raw_span.text(source),
            );
            try std.testing.expectEqual(direct_pool.idx_boolean, direct_signature.return_type);
        },
        .unresolved_target => {
            try std.testing.expectEqual(
                TypeSyntax.LegacyReturnKind.type_guard,
                return_syntax.legacy_return_kind,
            );
            const predicate = switch (return_syntax.structure) {
                .predicate => |value| value,
                .value => return error.TestUnexpectedResult,
            };
            switch (predicate.target) {
                .unresolved => {},
                .resolved => return error.TestUnexpectedResult,
            }
            try std.testing.expectEqual(direct_pool.idx_boolean, direct_signature.return_type);
        },
        .named_guard_verified,
        .named_guard_unverified,
        .arrow_guard_unverified,
        .mixed_untyped_target,
        .compact_target_position,
        .repeated_target,
        .target_after_sixteen,
        .captured_generic,
        => {
            try std.testing.expectEqual(
                TypeSyntax.LegacyReturnKind.type_guard,
                return_syntax.legacy_return_kind,
            );
            try std.testing.expectEqual(direct_pool.idx_boolean, direct_signature.return_type);
        },
    }

    var legacy_checker = type_checker_mod.TypeChecker.init(
        std.testing.allocator,
        legacy_view,
        &legacy_atoms,
        &legacy_env,
    );
    defer legacy_checker.deinit();
    var direct_checker = type_checker_mod.TypeChecker.init(
        std.testing.allocator,
        direct_view,
        &direct_atoms,
        &direct_env,
    );
    defer direct_checker.deinit();
    try std.testing.expectEqual(
        try legacy_checker.check(legacy_root),
        try direct_checker.check(direct_root),
    );
    try std.testing.expectEqual(
        legacy_checker.getDiagnostics().len,
        direct_checker.getDiagnostics().len,
    );
    for (legacy_checker.getDiagnostics(), direct_checker.getDiagnostics()) |legacy_diag, direct_diag| {
        try expectSameTypeDiagnostic(legacy_diag, legacy_view, direct_diag, direct_view);
    }
    if (case == .named_guard_unverified or case == .quoted_marker_space) {
        try std.testing.expectEqual(@as(usize, 1), direct_checker.getDiagnostics().len);
        try std.testing.expectEqual(
            type_checker_mod.DiagnosticKind.invalid_type_predicate,
            direct_checker.getDiagnostics()[0].kind,
        );
    }
    if (case == .named_guard_verified or case == .arrow_guard_unverified) {
        try std.testing.expectEqual(@as(usize, 0), direct_checker.getDiagnostics().len);
    }

    var legacy_strict = strict_checker_mod.StrictChecker.init(
        std.testing.allocator,
        legacy_view,
        &legacy_atoms,
        &legacy_env,
        &legacy_checker,
    );
    defer legacy_strict.deinit();
    var direct_strict = strict_checker_mod.StrictChecker.init(
        std.testing.allocator,
        direct_view,
        &direct_atoms,
        &direct_env,
        &direct_checker,
    );
    defer direct_strict.deinit();
    try std.testing.expectEqual(
        try legacy_strict.check(legacy_root),
        try direct_strict.check(direct_root),
    );
    try std.testing.expectEqual(
        legacy_strict.getDiagnostics().len,
        direct_strict.getDiagnostics().len,
    );
    for (legacy_strict.getDiagnostics(), direct_strict.getDiagnostics()) |legacy_diag, direct_diag| {
        try expectSameStrictDiagnostic(legacy_diag, legacy_view, direct_diag, direct_view);
    }
}

test "direct predicates preserve construction and checker behavior" {
    const cases = [_]struct {
        case: DirectPredicateCase,
        source: []const u8,
        predicate: ExpectedPredicate,
        return_spelling: ?[]const u8,
    }{
        .{ .case = .named_value, .source = "function echo(value: string): string { return value; }", .predicate = .absent, .return_spelling = "string " },
        .{ .case = .arrow_value, .source = "const echo = (value: string): string => value;", .predicate = .absent, .return_spelling = "string " },
        .{ .case = .named_guard_verified, .source = "function guard(candidate: unknown): candidate is string { return typeof candidate === \"string\"; }", .predicate = .{ .parameter = 0 }, .return_spelling = null },
        .{ .case = .named_guard_unverified, .source = "function guard(candidate: unknown): candidate is string { return true; }", .predicate = .{ .parameter = 0 }, .return_spelling = null },
        .{ .case = .arrow_guard_unverified, .source = "const guard = (candidate: unknown): candidate is string => true;", .predicate = .{ .parameter = 0 }, .return_spelling = null },
        .{ .case = .ordinary_tab, .source = "function guard(candidate: unknown): candidate\tis\tstring { return true; }", .predicate = .absent, .return_spelling = "candidate\tis\tstring " },
        .{ .case = .arrow_ordinary_tab, .source = "const guard = (candidate: unknown): candidate\tis\tstring => true;", .predicate = .absent, .return_spelling = "candidate\tis\tstring " },
        .{ .case = .readonly_tab, .source = "function guard(readonly: unknown): readonly\tis\tstring { return true; }", .predicate = .absent, .return_spelling = "readonly\tis\tstring " },
        .{ .case = .quoted_value, .source = "const text = (): \"x is y\" => true;", .predicate = .absent, .return_spelling = null },
        .{ .case = .empty_narrowing, .source = "function guard(candidate: unknown): candidate is { return true; }", .predicate = .absent, .return_spelling = null },
        .{ .case = .unresolved_target, .source = "function guard(candidate: unknown): missing is string[] { return true; }\n", .predicate = .absent, .return_spelling = null },
        .{ .case = .mixed_untyped_target, .source = "function guard(candidate, marker: unknown): candidate is string[] { return true; }\n", .predicate = .absent, .return_spelling = null },
        .{ .case = .compact_target_position, .source = "const guard = (lead, marker: unknown, candidate: unknown): candidate is string => true;", .predicate = .{ .parameter = 1 }, .return_spelling = null },
        .{ .case = .repeated_target, .source = "const guard = (candidate, candidate: number, candidate: string): candidate is string => true;", .predicate = .{ .parameter = 0 }, .return_spelling = null },
        .{ .case = .target_after_sixteen, .source = "const guard = (p0: unknown, p1: unknown, p2: unknown, p3: unknown, p4: unknown, p5: unknown, p6: unknown, p7: unknown, p8: unknown, p9: unknown, p10: unknown, p11: unknown, p12: unknown, p13: unknown, p14: unknown, p15: unknown, target: unknown): target is string[] => true;\n", .predicate = .absent, .return_spelling = null },
        .{ .case = .captured_generic, .source = "const guard = <T>(candidate: unknown): candidate is T => true;", .predicate = .captured_generic, .return_spelling = null },
        .{ .case = .trailing_ordinary, .source = "function echo(value: string): string   { return value; }", .predicate = .absent, .return_spelling = "string   " },
        .{ .case = .quoted_marker_space, .source = "function guard(candidate: unknown): candidate is \"a is b\" { return true; }\n", .predicate = .{ .literal = "a is b" }, .return_spelling = null },
        .{ .case = .quoted_marker_tab, .source = "function guard(candidate: unknown): candidate\tis \"a is b\" { return true; }\n", .predicate = .absent, .return_spelling = null },
    };
    var seen = std.EnumSet(DirectPredicateCase).initEmpty();
    for (cases) |case| {
        try expectDirectPredicateConsumer(
            case.source,
            case.case,
            case.predicate,
            case.return_spelling,
        );
        seen.insert(case.case);
    }
    try std.testing.expectEqual(std.meta.fields(DirectPredicateCase).len, cases.len);
    try std.testing.expectEqual(cases.len, seen.count());
}

const PredicateAllocationObservations = struct {
    unselected_failures: usize = 0,
    selected_failures: usize = 0,
    post_seed_failures: usize = 0,
    incomplete_publication_failures: usize = 0,
    successes: usize = 0,
};

fn runPredicateAllocationSweep(
    allocator: std.mem.Allocator,
    observations: *PredicateAllocationObservations,
) !void {
    const source =
        "structural Seed = string;\n" ++
        "const guard = <T>(candidate: Seed): candidate is T[] => true;\n";
    var runtime_count = CountingAllocator.init(std.testing.allocator);
    var atoms = AtomTable.init(runtime_count.allocator());
    defer atoms.deinit();
    var parser = try JsParser.initTyped(
        runtime_count.allocator(),
        std.testing.allocator,
        source,
    );
    defer parser.deinit();
    parser.setAtomTable(&atoms);
    const root = try parser.parse();
    try expectRuntimeParityAndShape(source, &parser, root, &atoms, runtime_count);
    try std.testing.expectEqual(@as(usize, 1), parser.type_store.declarations.items.len);
    try std.testing.expectEqual(@as(usize, 1), parser.type_store.generic_owners.items.len);
    try std.testing.expectEqual(@as(usize, 1), parser.type_store.function_signatures.items.len);

    var pool = TypePool.init(allocator);
    defer pool.deinit(allocator);
    var env = TypeEnv.init(allocator, &pool);
    defer env.deinit();
    module_types.populateModuleTypes(&env, &pool, allocator);
    abi_types.populateHandlerAbiTypes(&env, &pool, allocator);
    try pool.ensureHealthy();
    try env.ensureHealthy();
    const prior_nodes = pool.nodes.items.len;
    env.populateSourceTypes(.{ .direct = .{
        .store = &parser.type_store,
        .ir_view = parserIrView(&parser),
        .atoms = &atoms,
    } }) catch |err| {
        try std.testing.expectEqual(@as(usize, 0), env.generic_scopes.items.len);
        if (env.sourceTypeMode() == null) {
            observations.unselected_failures += 1;
            try std.testing.expectEqual(prior_nodes, pool.nodes.items.len);
            try std.testing.expectEqual(@as(usize, 0), env.direct_fn_signatures.count());
        } else {
            observations.selected_failures += 1;
            try std.testing.expectEqual(type_env_mod.SourceTypeMode.direct, env.sourceTypeMode().?);
            const has_seed = env.getTypeAlias("Seed") != null;
            if (has_seed and poolTagCount(&pool, prior_nodes, .t_generic_param) > 0) {
                observations.post_seed_failures += 1;
            }
            if (has_seed and env.direct_source_fn_annotations.count() > 0 and
                env.direct_fn_signatures.count() == 0)
            {
                observations.incomplete_publication_failures += 1;
            }
        }
        try std.testing.expectError(error.OutOfMemory, env.ensureHealthy());
        var checker = type_checker_mod.TypeChecker.init(
            std.testing.allocator,
            parserIrView(&parser),
            &atoms,
            &env,
        );
        defer checker.deinit();
        try std.testing.expectError(error.OutOfMemory, checker.check(root));
        var strict = strict_checker_mod.StrictChecker.init(
            std.testing.allocator,
            parserIrView(&parser),
            &atoms,
            &env,
            null,
        );
        defer strict.deinit();
        try std.testing.expectError(error.OutOfMemory, strict.check(root));
        return err;
    };

    observations.successes += 1;
    try pool.ensureHealthy();
    try env.ensureHealthy();
    try std.testing.expectEqual(@as(usize, 0), env.generic_scopes.items.len);
    try std.testing.expect(env.getTypeAlias("Seed") != null);
    var prepared = try PreparedSource.init(
        std.testing.allocator,
        source,
        "<u12-predicate-oom>.ts",
        .{},
    );
    defer prepared.deinit();
    var legacy_atoms = AtomTable.init(std.testing.allocator);
    defer legacy_atoms.deinit();
    var legacy = try JsParser.init(std.testing.allocator, prepared.parserInput());
    defer legacy.deinit();
    legacy.setAtomTable(&legacy_atoms);
    _ = try legacy.parse();
    var legacy_pool = TypePool.init(std.testing.allocator);
    defer legacy_pool.deinit(std.testing.allocator);
    var legacy_env = TypeEnv.init(std.testing.allocator, &legacy_pool);
    defer legacy_env.deinit();
    module_types.populateModuleTypes(&legacy_env, &legacy_pool, std.testing.allocator);
    abi_types.populateHandlerAbiTypes(&legacy_env, &legacy_pool, std.testing.allocator);
    try legacy_env.populateSourceTypes(.{ .legacy = prepared.typeMap().? });
    try expectExactTypePool(&legacy_pool, &pool);
    try expectExactFunctionNameMaps(&legacy_env, &env);
    try expectExactOwnerSignatures(
        &legacy_env,
        &env,
        parserIrView(&legacy),
        parserIrView(&parser),
        &parser.type_store,
    );

    const syntax_signature = parser.type_store.function_signatures.items[0];
    const reference = env.functionTypeRef(parserIrView(&parser), syntax_signature.owner) orelse
        return error.TestUnexpectedResult;
    const signature = env.getFunctionSignature(reference) orelse return error.TestUnexpectedResult;
    const predicate = signature.type_predicate orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u8, 0), predicate.param_index);
    try std.testing.expectEqual(@as(u8, 1), signature.type_param_count);
    try std.testing.expectEqual(TypeTag.t_array, pool.getTag(predicate.narrowed).?);
    const element = pool.getArrayElement(predicate.narrowed);
    try std.testing.expectEqual(TypeTag.t_ref, pool.getTag(element).?);
    try std.testing.expectEqualStrings("T", pool.getRefName(element));
    try std.testing.expect(element != signature.type_params[0].idx);
}

test "direct predicate allocation failures restore scopes and poison consumers" {
    var observations: PredicateAllocationObservations = .{};
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        runPredicateAllocationSweep,
        .{&observations},
    );
    try std.testing.expect(observations.unselected_failures > 0);
    try std.testing.expect(observations.selected_failures > 0);
    try std.testing.expect(observations.post_seed_failures > 0);
    try std.testing.expect(observations.incomplete_publication_failures > 0);
    try std.testing.expect(observations.successes > 0);
}

test "bounded erased prefixes preserve preflight and consumer admission" {
    const Case = enum { scalar_bound, compound_bound, any_bound, default_parameter, operator_parameter };
    const cases = [_]struct { case: Case, source: []const u8 }{
        .{ .case = .scalar_bound, .source = "const value = <T extends string>(1);" },
        .{ .case = .compound_bound, .source = "const value = <T extends { id: string }>(1);" },
        .{ .case = .any_bound, .source = "const value = <T extends any>(1);" },
        .{ .case = .default_parameter, .source = "const value = <T = string>(1);" },
        .{ .case = .operator_parameter, .source = "const value = <T | U>(1);" },
    };
    const modes = [_]AdmissionMode{ .collect, .compile };
    var seen = std.EnumSet(Case).initEmpty();
    for (cases) |case| {
        for (modes) |mode| switch (try compare(std.testing.allocator, case.source, mode)) {
            .equivalent => {},
            else => return error.TestUnexpectedResult,
        };
        try expectDirectDeclarationConsumer(case.source, &.{}, "", false);
        seen.insert(case.case);
    }
    try std.testing.expectEqual(std.meta.fields(Case).len, seen.count());
    try std.testing.expectEqual(@as(usize, 2), modes.len);

    for (modes) |mode| switch (try compare(
        std.testing.allocator,
        "const value = <T extends void>(1);",
        mode,
    )) {
        .admission_refused => |refusal| {
            try std.testing.expectEqual(AdmissionKind.void_type, refusal.first);
            try std.testing.expectEqual(@as(usize, 1), refusal.count);
        },
        else => return error.TestUnexpectedResult,
    };
}

test "direct callable bounds stop before excluded projected fragments" {
    const source =
        "function compact<T, = string, U extends { id: string }>(value: T): T { " ++
        "return value; }";
    var prepared = try PreparedSource.init(
        std.testing.allocator,
        source,
        "<u12-compact-stop>.ts",
        .{},
    );
    defer prepared.deinit();
    var legacy_count = CountingAllocator.init(std.testing.allocator);
    var direct_count = CountingAllocator.init(std.testing.allocator);
    var type_count = CountingAllocator.init(std.testing.allocator);
    var legacy_atoms = AtomTable.init(legacy_count.allocator());
    defer legacy_atoms.deinit();
    var direct_atoms = AtomTable.init(direct_count.allocator());
    defer direct_atoms.deinit();
    var legacy = try JsParser.init(legacy_count.allocator(), prepared.parserInput());
    defer legacy.deinit();
    legacy.setAtomTable(&legacy_atoms);
    var direct = try JsParser.initTyped(
        direct_count.allocator(),
        type_count.allocator(),
        source,
    );
    defer direct.deinit();
    direct.setAtomTable(&direct_atoms);
    const legacy_root = try legacy.parse();
    const direct_root = try direct.parse();
    const direct_view = parserIrView(&direct);
    try std.testing.expect(compareRuntime(
        &legacy,
        legacy_root,
        &legacy_atoms,
        &direct,
        direct_root,
        &direct_atoms,
    ) == null);
    try std.testing.expect(legacy_count.sameRuntimeShape(direct_count));

    try std.testing.expectEqual(@as(usize, 1), direct.type_store.generic_owners.items.len);
    const owner = direct.type_store.generic_owners.items[0];
    const projected = direct.type_store.projectedGenericParameterSlice(owner.projected_parameters) orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 3), projected.len);
    try std.testing.expectEqualStrings("T", projected[0].name_span.text(source));
    try std.testing.expectEqualStrings("", projected[1].name_span.text(source));
    try std.testing.expectEqualStrings("U", projected[2].name_span.text(source));
    try std.testing.expectEqualStrings(
        "{ id: string }",
        (projected[2].legacy_bound_span orelse return error.TestUnexpectedResult).text(source),
    );
    try std.testing.expect(projected[2].bound_fragment == null);
    const fragment_index = try TypeSyntax.parseSemanticFragmentAndStore(
        &direct.type_store,
        projected[2].legacy_bound_span.?,
    );
    direct.type_store.projected_generic_parameters.items[
        owner.projected_parameters.start + 2
    ].bound_fragment = fragment_index;
    try direct.type_store.validateRuntimeOwners(std.testing.allocator, direct_view);

    var legacy_pool = TypePool.init(std.testing.allocator);
    defer legacy_pool.deinit(std.testing.allocator);
    var direct_pool = TypePool.init(std.testing.allocator);
    defer direct_pool.deinit(std.testing.allocator);
    var legacy_env = TypeEnv.init(std.testing.allocator, &legacy_pool);
    defer legacy_env.deinit();
    var direct_env = TypeEnv.init(std.testing.allocator, &direct_pool);
    defer direct_env.deinit();
    const prior_nodes = direct_pool.nodes.items.len;
    try legacy_env.populateSourceTypes(.{ .legacy = prepared.typeMap().? });
    try direct_env.populateSourceTypes(.{ .direct = .{
        .store = &direct.type_store,
        .ir_view = direct_view,
        .atoms = &direct_atoms,
    } });
    try expectExactTypePool(&legacy_pool, &direct_pool);
    try expectExactFunctionNameMaps(&legacy_env, &direct_env);
    try std.testing.expectEqual(prior_nodes + 2, direct_pool.nodes.items.len);
    try std.testing.expectEqual(TypeTag.t_generic_param, direct_pool.getTag(@intCast(prior_nodes)).?);
    try std.testing.expectEqual(TypeTag.t_generic_param, direct_pool.getTag(@intCast(prior_nodes + 1)).?);
    try std.testing.expectEqualStrings("T", direct_pool.getRefName(@intCast(prior_nodes)));
    try std.testing.expectEqualStrings("U", direct_pool.getRefName(@intCast(prior_nodes + 1)));
    const function_owner = switch (owner.identity) {
        .function => |node| node,
        else => return error.TestUnexpectedResult,
    };
    const reference = direct_env.functionTypeRef(direct_view, function_owner) orelse
        return error.TestUnexpectedResult;
    const signature = direct_env.getFunctionSignature(reference) orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u8, 2), signature.type_param_count);
    try std.testing.expectEqualStrings("T", signature.type_params[0].name);
    try std.testing.expectEqualStrings("U", signature.type_params[1].name);
    try std.testing.expectEqual(null_type_idx, signature.type_params[1].constraint);
    try std.testing.expectEqual(signature.type_params[0].idx, signature.param_types[0]);
    try std.testing.expectEqual(signature.type_params[0].idx, signature.return_type);
    try std.testing.expectEqual(@as(usize, 0), direct_env.generic_scopes.items.len);
}

fn poolHasGenericName(pool: *const TypePool, start: usize, name: []const u8) bool {
    for (start..pool.nodes.items.len) |index| {
        const type_index: TypeIndex = @intCast(index);
        if (pool.getTag(type_index) != .t_generic_param) continue;
        if (std.mem.eql(u8, pool.getRefName(type_index), name)) return true;
    }
    return false;
}

fn poolTagCount(pool: *const TypePool, start: usize, tag: TypeTag) usize {
    var count: usize = 0;
    for (start..pool.nodes.items.len) |index| {
        if (pool.getTag(@intCast(index)) == tag) count += 1;
    }
    return count;
}

const DirectGenericAllocationObservations = struct {
    unselected_plan_failures: usize = 0,
    selected_failures: usize = 0,
    bound_failures: usize = 0,
    generic_only_validation_failures: usize = 0,
    retained_map_failures: usize = 0,
    publication_failures: usize = 0,
    successes: usize = 0,
};

fn runDirectGenericAllocationSweep(
    allocator: std.mem.Allocator,
    observations: *DirectGenericAllocationObservations,
) !void {
    const source =
        "structural Seed = string;\n" ++
        "const before = <P extends { id: string }>(1);\n" ++
        "function identity<T extends string>(value: T): T { return value; }\n" ++
        "const after = <Q extends number>(2);";
    var runtime_count = CountingAllocator.init(std.testing.allocator);
    var atoms = AtomTable.init(runtime_count.allocator());
    defer atoms.deinit();
    var parser = try JsParser.initTyped(
        runtime_count.allocator(),
        std.testing.allocator,
        source,
    );
    defer parser.deinit();
    parser.setAtomTable(&atoms);
    const root = try parser.parse();
    try expectRuntimeParityAndShape(source, &parser, root, &atoms, runtime_count);

    var pool = TypePool.init(allocator);
    defer pool.deinit(allocator);
    var env = TypeEnv.init(allocator, &pool);
    defer env.deinit();
    const prior_nodes = pool.nodes.items.len;
    env.populateSourceTypes(.{ .direct = .{
        .store = &parser.type_store,
        .ir_view = parserIrView(&parser),
        .atoms = &atoms,
    } }) catch |err| {
        try std.testing.expectEqual(@as(usize, 0), env.generic_scopes.items.len);
        if (env.sourceTypeMode() == null) {
            observations.unselected_plan_failures += 1;
            try std.testing.expectEqual(prior_nodes, pool.nodes.items.len);
        } else {
            try std.testing.expectEqual(type_env_mod.SourceTypeMode.direct, env.sourceTypeMode().?);
            observations.selected_failures += 1;
            const has_p = poolHasGenericName(&pool, prior_nodes, "P");
            const has_t = poolHasGenericName(&pool, prior_nodes, "T");
            const has_q = poolHasGenericName(&pool, prior_nodes, "Q");
            const records = poolTagCount(&pool, prior_nodes, .t_record);
            const has_seed = env.getTypeAlias("Seed") != null;
            if (has_p and !has_t and records == 0) {
                try std.testing.expect(has_seed);
                observations.bound_failures += 1;
            }
            if (has_p and has_t and has_q and
                env.direct_source_fn_annotations.count() == 2 and
                env.direct_fn_signatures.count() == 0)
            {
                try std.testing.expect(has_seed);
                observations.publication_failures += 1;
            }
        }
        try std.testing.expectError(error.OutOfMemory, env.ensureHealthy());
        return err;
    };

    observations.successes += 1;
    try pool.ensureHealthy();
    try env.ensureHealthy();
    try std.testing.expectEqual(@as(usize, 0), env.generic_scopes.items.len);
    try std.testing.expect(env.getTypeAlias("Seed") != null);
    try std.testing.expect(poolHasGenericName(&pool, prior_nodes, "P"));
    try std.testing.expect(poolHasGenericName(&pool, prior_nodes, "T"));
    try std.testing.expect(poolHasGenericName(&pool, prior_nodes, "Q"));
    try std.testing.expectEqual(@as(usize, 1), env.direct_fn_signatures.count());
}

fn runDirectGenericMapAllocationSweep(
    allocator: std.mem.Allocator,
    observations: *DirectGenericAllocationObservations,
) !void {
    const source =
        "structural Seed = string;\n" ++
        "function identity<T>(value) { return value; }";
    var runtime_count = CountingAllocator.init(std.testing.allocator);
    var atoms = AtomTable.init(runtime_count.allocator());
    defer atoms.deinit();
    var parser = try JsParser.initTyped(
        runtime_count.allocator(),
        std.testing.allocator,
        source,
    );
    defer parser.deinit();
    parser.setAtomTable(&atoms);
    const root = try parser.parse();
    try expectRuntimeParityAndShape(source, &parser, root, &atoms, runtime_count);

    var pool = TypePool.init(allocator);
    defer pool.deinit(allocator);
    var env = TypeEnv.init(allocator, &pool);
    defer env.deinit();
    const prior_nodes = pool.nodes.items.len;
    env.populateSourceTypes(.{ .direct = .{
        .store = &parser.type_store,
        .ir_view = parserIrView(&parser),
        .atoms = &atoms,
    } }) catch |err| {
        try std.testing.expectEqual(@as(usize, 0), env.generic_scopes.items.len);
        if (env.sourceTypeMode() == null) {
            observations.generic_only_validation_failures += 1;
        } else {
            try std.testing.expectEqual(type_env_mod.SourceTypeMode.direct, env.sourceTypeMode().?);
            if (poolHasGenericName(&pool, prior_nodes, "T")) {
                try std.testing.expect(env.getTypeAlias("Seed") != null);
                observations.retained_map_failures += 1;
            }
        }
        try std.testing.expectError(error.OutOfMemory, env.ensureHealthy());
        return err;
    };
    try pool.ensureHealthy();
    try env.ensureHealthy();
    try std.testing.expectEqual(@as(usize, 0), env.generic_scopes.items.len);
    try std.testing.expect(env.getTypeAlias("Seed") != null);
    try std.testing.expect(poolHasGenericName(&pool, prior_nodes, "T"));
    try std.testing.expectEqual(@as(usize, 0), env.direct_fn_signatures.count());
}

test "direct callable generic allocation failures close scopes by construction stage" {
    var observations: DirectGenericAllocationObservations = .{};
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        runDirectGenericAllocationSweep,
        .{&observations},
    );
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        runDirectGenericMapAllocationSweep,
        .{&observations},
    );
    try std.testing.expect(observations.unselected_plan_failures > 0);
    try std.testing.expect(observations.selected_failures > 0);
    try std.testing.expect(observations.bound_failures > 0);
    try std.testing.expect(observations.generic_only_validation_failures > 0);
    try std.testing.expect(observations.retained_map_failures > 0);
    try std.testing.expect(observations.publication_failures > 0);
    try std.testing.expect(observations.successes > 0);
}

fn functionWrapper(view: engine.parser.IrView, owner: NodeIndex) ?NodeIndex {
    for (0..view.nodeCount()) |raw| {
        const node: NodeIndex = @intCast(raw);
        if (view.getTag(node) != .function_decl) continue;
        const declaration = view.getVarDecl(node) orelse continue;
        if (declaration.init == owner) return node;
    }
    return null;
}

fn expectSameTypeDiagnostic(
    left: type_checker_mod.Diagnostic,
    left_view: engine.parser.IrView,
    right: type_checker_mod.Diagnostic,
    right_view: engine.parser.IrView,
) !void {
    try std.testing.expectEqual(left.kind, right.kind);
    try std.testing.expectEqualStrings(left.message, right.message);
    try std.testing.expect(std.meta.eql(left_view.getLoc(left.node).?, right_view.getLoc(right.node).?));
}

fn expectSameStrictDiagnostic(
    left: strict_checker_mod.Diagnostic,
    left_view: engine.parser.IrView,
    right: strict_checker_mod.Diagnostic,
    right_view: engine.parser.IrView,
) !void {
    try std.testing.expectEqual(left.kind, right.kind);
    try std.testing.expectEqualStrings(left.message, right.message);
    try std.testing.expect(std.meta.eql(left_view.getLoc(left.node).?, right_view.getLoc(right.node).?));
}

test "direct source pilot preserves runtime types owners checks and capsules" {
    const source =
        "const seed: number = 1;\n" ++
        "export function helper(value: string): Proof<string, \"deterministic\"> {\n" ++
        "  return value;\n" ++
        "}";
    var prepared = try PreparedSource.init(std.testing.allocator, source, "<u12-pilot>.ts", .{});
    defer prepared.deinit();
    try std.testing.expectEqual(@as(usize, 0), prepared.stripDiagnostics().len);

    var legacy_count = CountingAllocator.init(std.testing.allocator);
    var direct_count = CountingAllocator.init(std.testing.allocator);
    var type_count = CountingAllocator.init(std.testing.allocator);
    const legacy_allocator = legacy_count.allocator();
    const direct_allocator = direct_count.allocator();
    const type_allocator = type_count.allocator();
    var legacy_atoms = AtomTable.init(legacy_allocator);
    defer legacy_atoms.deinit();
    var direct_atoms = AtomTable.init(direct_allocator);
    defer direct_atoms.deinit();
    var legacy = try JsParser.init(legacy_allocator, prepared.parserInput());
    defer legacy.deinit();
    legacy.setAtomTable(&legacy_atoms);
    var direct = try JsParser.initTyped(direct_allocator, type_allocator, source);
    defer direct.deinit();
    direct.setAtomTable(&direct_atoms);
    const legacy_root = try legacy.parse();
    const direct_root = try direct.parse();
    try std.testing.expect(compareRuntime(
        &legacy,
        legacy_root,
        &legacy_atoms,
        &direct,
        direct_root,
        &direct_atoms,
    ) == null);
    try std.testing.expect(legacy_count.sameRuntimeShape(direct_count));

    var legacy_pool = TypePool.init(std.testing.allocator);
    defer legacy_pool.deinit(std.testing.allocator);
    var direct_pool = TypePool.init(std.testing.allocator);
    defer direct_pool.deinit(std.testing.allocator);
    var legacy_env = TypeEnv.init(std.testing.allocator, &legacy_pool);
    defer legacy_env.deinit();
    var direct_env = TypeEnv.init(std.testing.allocator, &direct_pool);
    defer direct_env.deinit();
    module_types.populateModuleTypes(&legacy_env, &legacy_pool, std.testing.allocator);
    abi_types.populateHandlerAbiTypes(&legacy_env, &legacy_pool, std.testing.allocator);
    module_types.populateModuleTypes(&direct_env, &direct_pool, std.testing.allocator);
    abi_types.populateHandlerAbiTypes(&direct_env, &direct_pool, std.testing.allocator);
    try legacy_env.populateSourceTypes(.{ .legacy = prepared.typeMap().? });
    const legacy_view = parserIrView(&legacy);
    const direct_view = parserIrView(&direct);
    try direct_env.populateSourceTypes(.{ .direct = .{
        .store = &direct.type_store,
        .ir_view = direct_view,
        .atoms = &direct_atoms,
    } });
    try expectExactTypePool(&legacy_pool, &direct_pool);
    try std.testing.expectEqual(type_env_mod.SourceTypeMode.legacy, legacy_env.sourceTypeMode().?);
    try std.testing.expectEqual(type_env_mod.SourceTypeMode.direct, direct_env.sourceTypeMode().?);
    try std.testing.expectEqual(@as(usize, 1), direct_env.varAnnotationCount());
    try std.testing.expectEqual(@as(usize, 2), direct_env.direct_accumulator_events);

    const annotation = direct.type_store.annotations.items[0];
    const annotation_owner = annotation.runtime_owner orelse return error.TestUnexpectedResult;
    const declaration = direct_view.getVarDecl(annotation_owner.declaration) orelse
        return error.TestUnexpectedResult;
    try std.testing.expect(std.meta.eql(annotation.binding, declaration.binding));
    try std.testing.expectEqual(direct_pool.idx_number, direct_env.getVarTypeForDeclaration(
        direct_view,
        annotation_owner.declaration,
    ).?);
    try std.testing.expect(direct_env.getVarTypeForDeclaration(direct_view, direct_root) == null);

    const signature_record = direct.type_store.function_signatures.items[0];
    const owner = signature_record.owner;
    try std.testing.expectEqual(engine.parser.NodeTag.function_expr, direct_view.getTag(owner).?);
    const wrapper = functionWrapper(direct_view, owner) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(engine.parser.NodeTag.function_decl, direct_view.getTag(wrapper).?);
    try std.testing.expect(direct_env.functionTypeRef(direct_view, wrapper) == null);
    const direct_reference = direct_env.functionTypeRef(direct_view, owner) orelse
        return error.TestUnexpectedResult;
    const legacy_reference = legacy_env.functionTypeRef(legacy_view, owner) orelse
        return error.TestUnexpectedResult;
    const direct_signature = direct_env.getFunctionSignature(direct_reference) orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u8, 1), direct_signature.param_count);
    try std.testing.expectEqual(direct_pool.idx_string, direct_signature.param_types[0]);
    try std.testing.expectEqualStrings(
        "string",
        direct_env.getFunctionParameterSpelling(direct_reference, 0).?,
    );
    try std.testing.expectEqualStrings(
        legacy_env.getFunctionParameterSpelling(legacy_reference, 0).?,
        direct_env.getFunctionParameterSpelling(direct_reference, 0).?,
    );
    try std.testing.expectEqualStrings(
        "Proof<string, \"deterministic\"> ",
        direct_env.getFunctionReturnSpelling(direct_reference).?,
    );
    try std.testing.expectEqualStrings(
        legacy_env.getFunctionReturnSpelling(legacy_reference).?,
        direct_env.getFunctionReturnSpelling(direct_reference).?,
    );
    try std.testing.expect(direct_env.getCallTypeArgsForCall(direct_view, owner) == null);

    var legacy_checker = type_checker_mod.TypeChecker.init(
        std.testing.allocator,
        legacy_view,
        &legacy_atoms,
        &legacy_env,
    );
    defer legacy_checker.deinit();
    var direct_checker = type_checker_mod.TypeChecker.init(
        std.testing.allocator,
        direct_view,
        &direct_atoms,
        &direct_env,
    );
    defer direct_checker.deinit();
    try std.testing.expectEqual(@as(u32, 0), try legacy_checker.check(legacy_root));
    try std.testing.expectEqual(@as(u32, 0), try direct_checker.check(direct_root));

    var legacy_strict = strict_checker_mod.StrictChecker.init(
        std.testing.allocator,
        legacy_view,
        &legacy_atoms,
        &legacy_env,
        &legacy_checker,
    );
    defer legacy_strict.deinit();
    var direct_strict = strict_checker_mod.StrictChecker.init(
        std.testing.allocator,
        direct_view,
        &direct_atoms,
        &direct_env,
        &direct_checker,
    );
    defer direct_strict.deinit();
    try std.testing.expectEqual(@as(u32, 1), try legacy_strict.check(legacy_root));
    try std.testing.expectEqual(@as(u32, 1), try direct_strict.check(direct_root));
    const legacy_strict_diagnostics = legacy_strict.getDiagnostics();
    const direct_strict_diagnostics = direct_strict.getDiagnostics();
    try std.testing.expectEqual(@as(usize, 1), legacy_strict_diagnostics.len);
    try std.testing.expectEqual(@as(usize, 1), direct_strict_diagnostics.len);
    try expectSameStrictDiagnostic(
        legacy_strict_diagnostics[0],
        legacy_view,
        direct_strict_diagnostics[0],
        direct_view,
    );
    try std.testing.expectEqual(
        strict_checker_mod.DiagnosticKind.raw_exported_boundary_type,
        direct_strict_diagnostics[0].kind,
    );
    try std.testing.expectEqualStrings(
        "exported function parameter type `string` exposes raw `string`",
        direct_strict_diagnostics[0].message,
    );
    const strict_location = direct_view.getLoc(direct_strict_diagnostics[0].node).?;
    try std.testing.expectEqual(@as(u32, 2), strict_location.line);
    try std.testing.expectEqual(@as(u32, 24), strict_location.column);

    var legacy_effects = try effect_inference.buildEffectFacts(
        std.testing.allocator,
        legacy_view,
        &legacy_atoms,
        legacy_root,
        .{},
    );
    defer legacy_effects.deinit(std.testing.allocator);
    var direct_effects = try effect_inference.buildEffectFacts(
        std.testing.allocator,
        direct_view,
        &direct_atoms,
        direct_root,
        .{},
    );
    defer direct_effects.deinit(std.testing.allocator);
    var legacy_capsules = try function_specs.dischargeWithTypeSource(
        std.testing.allocator,
        &legacy_effects,
        .{ .legacy = &legacy_env },
        legacy_view,
    );
    defer legacy_capsules.deinit(std.testing.allocator);
    var direct_capsules = try function_specs.dischargeWithTypeSource(
        std.testing.allocator,
        &direct_effects,
        .{ .direct = &direct_env },
        direct_view,
    );
    defer direct_capsules.deinit(std.testing.allocator);
    const legacy_capsule = legacy_capsules.byName("helper") orelse return error.TestUnexpectedResult;
    const direct_capsule = direct_capsules.byName("helper") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 1), direct_capsule.declared.items.len);
    try std.testing.expectEqualStrings("deterministic", direct_capsule.declared.items[0]);
    try std.testing.expect(direct_capsule.proven.total);
    try std.testing.expect(direct_capsule.proven.pure);
    try std.testing.expect(direct_capsule.proven.read_only);
    try std.testing.expect(direct_capsule.proven.deterministic);
    try std.testing.expect(direct_capsule.discharged());
    try std.testing.expectEqualStrings(legacy_capsule.declared.items[0], direct_capsule.declared.items[0]);
    try std.testing.expect(std.meta.eql(legacy_capsule.proven, direct_capsule.proven));
    try std.testing.expectEqual(legacy_capsule.discharged(), direct_capsule.discharged());
}

fn expectPilotCheckerContrast(
    source: []const u8,
    expected_type_errors: u32,
    expected_strict_errors: u32,
) !void {
    var prepared = try PreparedSource.init(std.testing.allocator, source, "<u12-contrast>.ts", .{});
    defer prepared.deinit();
    var legacy_count = CountingAllocator.init(std.testing.allocator);
    var direct_count = CountingAllocator.init(std.testing.allocator);
    var type_count = CountingAllocator.init(std.testing.allocator);
    var legacy_atoms = AtomTable.init(legacy_count.allocator());
    defer legacy_atoms.deinit();
    var direct_atoms = AtomTable.init(direct_count.allocator());
    defer direct_atoms.deinit();
    var legacy = try JsParser.init(legacy_count.allocator(), prepared.parserInput());
    defer legacy.deinit();
    legacy.setAtomTable(&legacy_atoms);
    var direct = try JsParser.initTyped(direct_count.allocator(), type_count.allocator(), source);
    defer direct.deinit();
    direct.setAtomTable(&direct_atoms);
    const legacy_root = try legacy.parse();
    const direct_root = try direct.parse();
    const legacy_view = parserIrView(&legacy);
    const direct_view = parserIrView(&direct);
    try std.testing.expect(compareRuntime(
        &legacy,
        legacy_root,
        &legacy_atoms,
        &direct,
        direct_root,
        &direct_atoms,
    ) == null);
    try std.testing.expect(legacy_count.sameRuntimeShape(direct_count));

    var legacy_pool = TypePool.init(std.testing.allocator);
    defer legacy_pool.deinit(std.testing.allocator);
    var direct_pool = TypePool.init(std.testing.allocator);
    defer direct_pool.deinit(std.testing.allocator);
    var legacy_env = TypeEnv.init(std.testing.allocator, &legacy_pool);
    defer legacy_env.deinit();
    var direct_env = TypeEnv.init(std.testing.allocator, &direct_pool);
    defer direct_env.deinit();
    module_types.populateModuleTypes(&legacy_env, &legacy_pool, std.testing.allocator);
    abi_types.populateHandlerAbiTypes(&legacy_env, &legacy_pool, std.testing.allocator);
    module_types.populateModuleTypes(&direct_env, &direct_pool, std.testing.allocator);
    abi_types.populateHandlerAbiTypes(&direct_env, &direct_pool, std.testing.allocator);
    try legacy_env.populateSourceTypes(.{ .legacy = prepared.typeMap().? });
    try direct_env.populateSourceTypes(.{ .direct = .{
        .store = &direct.type_store,
        .ir_view = direct_view,
        .atoms = &direct_atoms,
    } });
    try expectExactTypePool(&legacy_pool, &direct_pool);

    var legacy_checker = type_checker_mod.TypeChecker.init(
        std.testing.allocator,
        legacy_view,
        &legacy_atoms,
        &legacy_env,
    );
    defer legacy_checker.deinit();
    var direct_checker = type_checker_mod.TypeChecker.init(
        std.testing.allocator,
        direct_view,
        &direct_atoms,
        &direct_env,
    );
    defer direct_checker.deinit();
    try std.testing.expectEqual(expected_type_errors, try legacy_checker.check(legacy_root));
    try std.testing.expectEqual(expected_type_errors, try direct_checker.check(direct_root));
    try std.testing.expectEqual(
        legacy_checker.getDiagnostics().len,
        direct_checker.getDiagnostics().len,
    );
    for (legacy_checker.getDiagnostics(), direct_checker.getDiagnostics()) |legacy_diag, direct_diag| {
        try expectSameTypeDiagnostic(legacy_diag, legacy_view, direct_diag, direct_view);
    }
    if (expected_type_errors == 1) {
        const diagnostic = direct_checker.getDiagnostics()[0];
        try std.testing.expectEqual(type_checker_mod.DiagnosticKind.type_mismatch, diagnostic.kind);
        const location = direct_view.getLoc(diagnostic.node).?;
        try std.testing.expectEqual(@as(u32, 1), location.line);
        try std.testing.expectEqual(@as(u32, 1), location.column);
    }

    var legacy_strict = strict_checker_mod.StrictChecker.init(
        std.testing.allocator,
        legacy_view,
        &legacy_atoms,
        &legacy_env,
        &legacy_checker,
    );
    defer legacy_strict.deinit();
    var direct_strict = strict_checker_mod.StrictChecker.init(
        std.testing.allocator,
        direct_view,
        &direct_atoms,
        &direct_env,
        &direct_checker,
    );
    defer direct_strict.deinit();
    try std.testing.expectEqual(expected_strict_errors, try legacy_strict.check(legacy_root));
    try std.testing.expectEqual(expected_strict_errors, try direct_strict.check(direct_root));
    try std.testing.expectEqual(
        legacy_strict.getDiagnostics().len,
        direct_strict.getDiagnostics().len,
    );
    for (legacy_strict.getDiagnostics(), direct_strict.getDiagnostics()) |legacy_diag, direct_diag| {
        try expectSameStrictDiagnostic(legacy_diag, legacy_view, direct_diag, direct_view);
    }
    if (expected_strict_errors == 1) {
        const diagnostic = direct_strict.getDiagnostics()[0];
        try std.testing.expectEqual(
            strict_checker_mod.DiagnosticKind.raw_exported_boundary_type,
            diagnostic.kind,
        );
        try std.testing.expectEqualStrings(
            "exported function parameter type `string` exposes raw `string`",
            diagnostic.message,
        );
        const location = direct_view.getLoc(diagnostic.node).?;
        try std.testing.expectEqual(@as(u32, 2), location.line);
        try std.testing.expectEqual(@as(u32, 24), location.column);
    }
}

test "direct source pilot retains independent type and strict failures" {
    const source =
        "const seed: number = \"x\";\n" ++
        "export function helper(value: string): Proof<string, \"deterministic\"> {\n" ++
        "  return value;\n" ++
        "}";
    try expectPilotCheckerContrast(source, 1, 1);
}

test "direct source pilot keeps inline record boundaries accepted" {
    const source =
        "const seed: number = 1;\n" ++
        "export function helper(value: { id: string }): Proof<string, \"deterministic\"> {\n" ++
        "  return value.id;\n" ++
        "}";
    try expectPilotCheckerContrast(source, 0, 0);
}

test "direct source selection distinguishes omitted and empty inputs" {
    var omitted_pool = TypePool.init(std.testing.allocator);
    defer omitted_pool.deinit(std.testing.allocator);
    var omitted_env = TypeEnv.init(std.testing.allocator, &omitted_pool);
    defer omitted_env.deinit();
    module_types.populateModuleTypes(&omitted_env, &omitted_pool, std.testing.allocator);
    try omitted_pool.ensureHealthy();
    try omitted_env.ensureHealthy();
    try std.testing.expect(omitted_env.getFnSigByName("sha256") != null);
    try omitted_env.populateSourceTypes(.omitted);
    try std.testing.expectEqual(type_env_mod.SourceTypeMode.omitted, omitted_env.sourceTypeMode().?);
    try std.testing.expectEqual(@as(usize, 0), omitted_env.varAnnotationCount());
    try std.testing.expect(omitted_env.getFnSigByName("sha256") != null);
    try std.testing.expectError(
        error.TypeSourceAlreadySelected,
        omitted_env.populateSourceTypes(.omitted),
    );

    var empty_prepared = try PreparedSource.init(
        std.testing.allocator,
        "",
        "<u12-empty-legacy>.ts",
        .{},
    );
    defer empty_prepared.deinit();
    const empty_type_map = empty_prepared.typeMap().?;
    try std.testing.expectError(
        error.TypeSourceAlreadySelected,
        omitted_env.populateFromTypeMap(empty_type_map),
    );

    var atoms = AtomTable.init(std.testing.allocator);
    defer atoms.deinit();
    var empty_parser = try JsParser.initTyped(std.testing.allocator, std.testing.allocator, "");
    defer empty_parser.deinit();
    empty_parser.setAtomTable(&atoms);
    const empty_root = try empty_parser.parse();
    const empty_view = parserIrView(&empty_parser);
    var direct_pool = TypePool.init(std.testing.allocator);
    defer direct_pool.deinit(std.testing.allocator);
    var direct_env = TypeEnv.init(std.testing.allocator, &direct_pool);
    defer direct_env.deinit();
    try direct_env.populateSourceTypes(.{ .direct = .{
        .store = &empty_parser.type_store,
        .ir_view = empty_view,
        .atoms = &atoms,
    } });
    try std.testing.expectEqual(type_env_mod.SourceTypeMode.direct, direct_env.sourceTypeMode().?);
    try std.testing.expectEqual(@as(usize, 0), direct_env.varAnnotationCount());
    try std.testing.expect(direct_env.functionTypeRef(empty_view, empty_root) == null);
    try std.testing.expect(direct_env.getVarTypeForDeclaration(empty_view, empty_root) == null);
    try std.testing.expect(direct_env.getCallTypeArgsForCall(empty_view, empty_root) == null);
    try std.testing.expectError(
        error.TypeSourceAlreadySelected,
        direct_env.populateFromTypeMap(empty_type_map),
    );

    var repeated_pool = TypePool.init(std.testing.allocator);
    defer repeated_pool.deinit(std.testing.allocator);
    var repeated_env = TypeEnv.init(std.testing.allocator, &repeated_pool);
    defer repeated_env.deinit();
    try repeated_env.populateFromTypeMap(empty_type_map);
    try repeated_env.populateFromTypeMap(empty_type_map);
    try std.testing.expect(repeated_env.sourceTypeMode() == null);
    try repeated_env.populateSourceTypes(.{ .legacy = empty_type_map });
    try std.testing.expectEqual(type_env_mod.SourceTypeMode.legacy, repeated_env.sourceTypeMode().?);
    try repeated_env.populateFromTypeMap(empty_type_map);

    var legacy_first_pool = TypePool.init(std.testing.allocator);
    defer legacy_first_pool.deinit(std.testing.allocator);
    var legacy_first_env = TypeEnv.init(std.testing.allocator, &legacy_first_pool);
    defer legacy_first_env.deinit();
    try legacy_first_env.populateFromTypeMap(empty_type_map);
    try std.testing.expectError(
        error.TypeSourceAlreadySelected,
        legacy_first_env.populateSourceTypes(.{ .direct = .{
            .store = &empty_parser.type_store,
            .ir_view = empty_view,
            .atoms = &atoms,
        } }),
    );
    try std.testing.expect(legacy_first_env.sourceTypeMode() == null);
    try legacy_first_env.ensureHealthy();
    try std.testing.expectEqual(@as(usize, 0), legacy_first_env.direct_var_types.count());
    try std.testing.expectEqual(@as(usize, 0), legacy_first_env.direct_fn_signatures.count());

    var legacy_omitted_pool = TypePool.init(std.testing.allocator);
    defer legacy_omitted_pool.deinit(std.testing.allocator);
    var legacy_omitted_env = TypeEnv.init(std.testing.allocator, &legacy_omitted_pool);
    defer legacy_omitted_env.deinit();
    try legacy_omitted_env.populateFromTypeMap(empty_type_map);
    try std.testing.expectError(
        error.TypeSourceAlreadySelected,
        legacy_omitted_env.populateSourceTypes(.omitted),
    );
    try std.testing.expect(legacy_omitted_env.sourceTypeMode() == null);
    try legacy_omitted_env.ensureHealthy();
    const empty_effects: effect_inference.EffectFacts = .{};
    try std.testing.expectError(
        error.TypeSourceModeMismatch,
        function_specs.dischargeWithTypeSource(
            std.testing.allocator,
            &empty_effects,
            .{ .legacy = &direct_env },
            empty_view,
        ),
    );
    direct_pool.failure = error.TypePoolCapacityExceeded;
    var capacity_strict = strict_checker_mod.StrictChecker.init(
        std.testing.allocator,
        empty_view,
        &atoms,
        &direct_env,
        null,
    );
    defer capacity_strict.deinit();
    try std.testing.expectError(
        error.TypePoolCapacityExceeded,
        capacity_strict.check(empty_root),
    );
    direct_pool.failure = null;
    direct_env.markAllocationFailure();
    var unhealthy_checker = type_checker_mod.TypeChecker.init(
        std.testing.allocator,
        empty_view,
        &atoms,
        &direct_env,
    );
    defer unhealthy_checker.deinit();
    try std.testing.expectError(error.OutOfMemory, unhealthy_checker.check(empty_root));
    var unhealthy_strict = strict_checker_mod.StrictChecker.init(
        std.testing.allocator,
        empty_view,
        &atoms,
        &direct_env,
        null,
    );
    defer unhealthy_strict.deinit();
    try std.testing.expectError(error.OutOfMemory, unhealthy_strict.check(empty_root));
    try std.testing.expectError(
        error.OutOfMemory,
        function_specs.dischargeWithTypeSource(
            std.testing.allocator,
            &empty_effects,
            .{ .direct = &direct_env },
            empty_view,
        ),
    );
}

const PilotAllocationObservations = struct {
    unselected_plan_failures: usize = 0,
    selected_failures: usize = 0,
    populated_failures: usize = 0,
};

fn runDirectPilotAllocationSweep(
    allocator: std.mem.Allocator,
    observations: *PilotAllocationObservations,
) !void {
    const source =
        "const seed: number = 1;\n" ++
        "export function helper(value: string): Proof<string, \"deterministic\"> {\n" ++
        "  return value;\n" ++
        "}";
    var atoms = AtomTable.init(std.testing.allocator);
    defer atoms.deinit();
    var parser = try JsParser.initTyped(std.testing.allocator, std.testing.allocator, source);
    defer parser.deinit();
    parser.setAtomTable(&atoms);
    const root = try parser.parse();
    const view = parserIrView(&parser);

    var pool = TypePool.init(allocator);
    defer pool.deinit(allocator);
    try pool.ensureHealthy();
    var env = TypeEnv.init(allocator, &pool);
    defer env.deinit();
    module_types.populateModuleTypes(&env, &pool, allocator);
    abi_types.populateHandlerAbiTypes(&env, &pool, allocator);
    try pool.ensureHealthy();
    try env.ensureHealthy();
    env.populateSourceTypes(.{ .direct = .{
        .store = &parser.type_store,
        .ir_view = view,
        .atoms = &atoms,
    } }) catch |err| {
        if (env.sourceTypeMode() == null) {
            observations.unselected_plan_failures += 1;
            try std.testing.expect(env.sourceTypeMode() == null);
            try std.testing.expectEqual(@as(usize, 0), env.direct_var_types.count());
            try std.testing.expectEqual(@as(usize, 0), env.direct_fn_signatures.count());
            try std.testing.expectEqual(@as(usize, 0), env.direct_source_fn_annotations.count());
            try std.testing.expectEqual(@as(usize, 0), env.direct_call_type_args.count());
            try std.testing.expectError(error.OutOfMemory, env.ensureHealthy());
            var checker = type_checker_mod.TypeChecker.init(allocator, view, &atoms, &env);
            defer checker.deinit();
            try std.testing.expectError(error.OutOfMemory, checker.check(root));
            var strict = strict_checker_mod.StrictChecker.init(
                allocator,
                view,
                &atoms,
                &env,
                null,
            );
            defer strict.deinit();
            try std.testing.expectError(error.OutOfMemory, strict.check(root));
            const empty_effects: effect_inference.EffectFacts = .{};
            try std.testing.expectError(
                error.OutOfMemory,
                function_specs.dischargeWithTypeSource(
                    allocator,
                    &empty_effects,
                    .{ .legacy = &env },
                    view,
                ),
            );
            try std.testing.expectError(
                error.TypeSourceModeMismatch,
                function_specs.dischargeWithTypeSource(
                    allocator,
                    &empty_effects,
                    .{ .direct = &env },
                    view,
                ),
            );
        } else if (env.sourceTypeMode() == .direct) {
            observations.selected_failures += 1;
            if (env.direct_var_types.count() > 0 or env.direct_fn_signatures.count() > 0) {
                observations.populated_failures += 1;
            }
            try std.testing.expectError(error.OutOfMemory, env.ensureHealthy());
            var checker = type_checker_mod.TypeChecker.init(allocator, view, &atoms, &env);
            defer checker.deinit();
            try std.testing.expectError(error.OutOfMemory, checker.check(root));
            var strict = strict_checker_mod.StrictChecker.init(
                allocator,
                view,
                &atoms,
                &env,
                null,
            );
            defer strict.deinit();
            try std.testing.expectError(error.OutOfMemory, strict.check(root));
            const empty_effects: effect_inference.EffectFacts = .{};
            try std.testing.expectError(
                error.OutOfMemory,
                function_specs.dischargeWithTypeSource(
                    allocator,
                    &empty_effects,
                    .{ .direct = &env },
                    view,
                ),
            );
        }
        return err;
    };

    try pool.ensureHealthy();
    try env.ensureHealthy();
    try std.testing.expectEqual(@as(usize, 1), env.direct_var_types.count());
    try std.testing.expectEqual(@as(usize, 1), env.direct_fn_signatures.count());
    try std.testing.expectEqual(@as(usize, 2), env.direct_source_fn_annotations.count());
    try std.testing.expectEqual(@as(usize, 2), env.direct_accumulator_events);
}

test "direct source pilot allocation failures poison populated consumers" {
    var observations: PilotAllocationObservations = .{};
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        runDirectPilotAllocationSweep,
        .{&observations},
    );
    try std.testing.expect(observations.unselected_plan_failures > 0);
    try std.testing.expect(observations.selected_failures > 0);
    try std.testing.expect(observations.populated_failures > 0);
}

const ExpectedDeclarationDiagnostic = struct {
    kind: type_checker_mod.DiagnosticKind,
    line: u32 = 2,
    column: u32 = 1,
};

fn expectDirectDeclarationConsumer(
    source: []const u8,
    expected_diagnostics: []const ExpectedDeclarationDiagnostic,
    contractivity_name: []const u8,
    expected_non_contractive: bool,
) !void {
    var prepared = try PreparedSource.init(std.testing.allocator, source, "<u12-declarations>.ts", .{});
    defer prepared.deinit();
    try std.testing.expectEqual(@as(usize, 0), prepared.stripDiagnostics().len);

    var legacy_count = CountingAllocator.init(std.testing.allocator);
    var direct_count = CountingAllocator.init(std.testing.allocator);
    var type_count = CountingAllocator.init(std.testing.allocator);
    var legacy_atoms = AtomTable.init(legacy_count.allocator());
    defer legacy_atoms.deinit();
    var direct_atoms = AtomTable.init(direct_count.allocator());
    defer direct_atoms.deinit();
    var legacy = try JsParser.init(legacy_count.allocator(), prepared.parserInput());
    defer legacy.deinit();
    legacy.setAtomTable(&legacy_atoms);
    var direct = try JsParser.initTyped(direct_count.allocator(), type_count.allocator(), source);
    defer direct.deinit();
    direct.setAtomTable(&direct_atoms);
    const legacy_root = try legacy.parse();
    const direct_root = try direct.parse();
    const legacy_view = parserIrView(&legacy);
    const direct_view = parserIrView(&direct);
    try std.testing.expect(compareRuntime(
        &legacy,
        legacy_root,
        &legacy_atoms,
        &direct,
        direct_root,
        &direct_atoms,
    ) == null);
    try std.testing.expect(legacy_count.sameRuntimeShape(direct_count));

    var legacy_pool = TypePool.init(std.testing.allocator);
    defer legacy_pool.deinit(std.testing.allocator);
    var direct_pool = TypePool.init(std.testing.allocator);
    defer direct_pool.deinit(std.testing.allocator);
    var legacy_env = TypeEnv.init(std.testing.allocator, &legacy_pool);
    defer legacy_env.deinit();
    var direct_env = TypeEnv.init(std.testing.allocator, &direct_pool);
    defer direct_env.deinit();
    module_types.populateModuleTypes(&legacy_env, &legacy_pool, std.testing.allocator);
    abi_types.populateHandlerAbiTypes(&legacy_env, &legacy_pool, std.testing.allocator);
    module_types.populateModuleTypes(&direct_env, &direct_pool, std.testing.allocator);
    abi_types.populateHandlerAbiTypes(&direct_env, &direct_pool, std.testing.allocator);
    try legacy_env.populateSourceTypes(.{ .legacy = prepared.typeMap().? });
    try direct_env.populateSourceTypes(.{ .direct = .{
        .store = &direct.type_store,
        .ir_view = direct_view,
        .atoms = &direct_atoms,
    } });
    try expectExactTypePool(&legacy_pool, &direct_pool);
    try std.testing.expectEqual(legacy_env.type_aliases.count(), direct_env.type_aliases.count());
    var aliases = legacy_env.type_aliases.iterator();
    while (aliases.next()) |entry| {
        const direct_alias = direct_env.getTypeAlias(entry.key_ptr.*) orelse
            return error.TestUnexpectedResult;
        try std.testing.expectEqual(entry.value_ptr.*, direct_alias);
        try std.testing.expect(try orderedTypeEqual(
            std.testing.allocator,
            &legacy_pool,
            entry.value_ptr.*,
            &direct_pool,
            direct_alias,
        ));
        try std.testing.expectEqual(
            legacy_env.isNonContractiveAlias(entry.key_ptr.*),
            direct_env.isNonContractiveAlias(entry.key_ptr.*),
        );
        try std.testing.expectEqual(
            legacy_env.isNonContractiveType(entry.value_ptr.*),
            direct_env.isNonContractiveType(direct_alias),
        );
    }
    try std.testing.expectEqual(legacy_env.generic_aliases.count(), direct_env.generic_aliases.count());
    var generic_aliases = legacy_env.generic_aliases.iterator();
    while (generic_aliases.next()) |entry| {
        const direct_alias = direct_env.generic_aliases.get(entry.key_ptr.*) orelse
            return error.TestUnexpectedResult;
        try std.testing.expectEqual(entry.value_ptr.body, direct_alias.body);
        try std.testing.expectEqual(entry.value_ptr.param_count, direct_alias.param_count);
        for (
            entry.value_ptr.param_names[0..entry.value_ptr.param_count],
            direct_alias.param_names[0..direct_alias.param_count],
        ) |legacy_name, direct_name| {
            try std.testing.expectEqualStrings(legacy_name, direct_name);
        }
        try std.testing.expect(try orderedTypeEqual(
            std.testing.allocator,
            &legacy_pool,
            entry.value_ptr.body,
            &direct_pool,
            direct_alias.body,
        ));
    }
    try std.testing.expectEqual(
        legacy_env.non_contractive_aliases.count(),
        direct_env.non_contractive_aliases.count(),
    );
    var non_contractive_aliases = legacy_env.non_contractive_aliases.iterator();
    while (non_contractive_aliases.next()) |entry| {
        try std.testing.expect(direct_env.non_contractive_aliases.contains(entry.key_ptr.*));
    }
    try std.testing.expectEqual(
        legacy_env.non_contractive_indices.count(),
        direct_env.non_contractive_indices.count(),
    );
    var non_contractive_indices = legacy_env.non_contractive_indices.iterator();
    while (non_contractive_indices.next()) |entry| {
        try std.testing.expect(direct_env.non_contractive_indices.contains(entry.key_ptr.*));
    }
    try std.testing.expectEqual(
        expected_non_contractive,
        direct_env.isNonContractiveAlias(contractivity_name),
    );
    try std.testing.expectEqual(direct.type_store.annotations.items.len, direct_env.varAnnotationCount());
    for (direct.type_store.annotations.items) |annotation| {
        const owner = annotation.runtime_owner orelse return error.TestUnexpectedResult;
        const runtime = direct_view.getVarDecl(owner.declaration) orelse return error.TestUnexpectedResult;
        try std.testing.expect(std.meta.eql(annotation.binding, runtime.binding));
        try std.testing.expect(direct_env.getVarTypeForDeclaration(
            direct_view,
            owner.declaration,
        ) != null);
    }

    var legacy_checker = type_checker_mod.TypeChecker.init(
        std.testing.allocator,
        legacy_view,
        &legacy_atoms,
        &legacy_env,
    );
    defer legacy_checker.deinit();
    var direct_checker = type_checker_mod.TypeChecker.init(
        std.testing.allocator,
        direct_view,
        &direct_atoms,
        &direct_env,
    );
    defer direct_checker.deinit();
    try std.testing.expectEqual(@as(u32, @intCast(expected_diagnostics.len)), try legacy_checker.check(legacy_root));
    try std.testing.expectEqual(@as(u32, @intCast(expected_diagnostics.len)), try direct_checker.check(direct_root));
    try std.testing.expectEqual(expected_diagnostics.len, direct_checker.getDiagnostics().len);
    for (
        legacy_checker.getDiagnostics(),
        direct_checker.getDiagnostics(),
        expected_diagnostics,
    ) |legacy_diagnostic, direct_diagnostic, expected| {
        try expectSameTypeDiagnostic(legacy_diagnostic, legacy_view, direct_diagnostic, direct_view);
        try std.testing.expectEqual(expected.kind, direct_diagnostic.kind);
        const location = direct_view.getLoc(direct_diagnostic.node).?;
        try std.testing.expectEqual(expected.line, location.line);
        try std.testing.expectEqual(expected.column, location.column);
    }

    var legacy_strict = strict_checker_mod.StrictChecker.init(
        std.testing.allocator,
        legacy_view,
        &legacy_atoms,
        &legacy_env,
        &legacy_checker,
    );
    defer legacy_strict.deinit();
    var direct_strict = strict_checker_mod.StrictChecker.init(
        std.testing.allocator,
        direct_view,
        &direct_atoms,
        &direct_env,
        &direct_checker,
    );
    defer direct_strict.deinit();
    const legacy_strict_count = try legacy_strict.check(legacy_root);
    const direct_strict_count = try direct_strict.check(direct_root);
    try std.testing.expectEqual(legacy_strict_count, direct_strict_count);
    try std.testing.expectEqual(
        legacy_strict.getDiagnostics().len,
        direct_strict.getDiagnostics().len,
    );
    for (legacy_strict.getDiagnostics(), direct_strict.getDiagnostics()) |legacy_diagnostic, direct_diagnostic| {
        try expectSameStrictDiagnostic(legacy_diagnostic, legacy_view, direct_diagnostic, direct_view);
    }
}

test "direct declarations preserve namespace contractivity and diagnostics" {
    try expectDirectDeclarationConsumer(
        "structural Label = string;\n" ++
            "nominal Count = number;\n" ++
            "const label: Label = \"ok\";\n" ++
            "const count: Count = 1;",
        &.{},
        "Label",
        false,
    );
    try expectDirectDeclarationConsumer(
        "structural Loop = Loop;\n" ++
            "const value: Loop = 1;",
        &.{
            .{ .kind = .non_contractive_alias },
            .{ .kind = .type_mismatch },
        },
        "Loop",
        true,
    );
    try expectDirectDeclarationConsumer(
        "structural Loop = Loop;\n" ++
            "structural Loop = string;\n" ++
            "const value: Loop = \"ok\";",
        &.{},
        "Loop",
        false,
    );
}

const RepeatedGlobalBindingCase = enum {
    two_typed,
    typed_untyped,
    untyped_typed_bad,
    two_typed_bad,
};

test "direct declaration consumer preserves repeated global bindings" {
    const cases = [_]struct {
        case: RepeatedGlobalBindingCase,
        source: []const u8,
        diagnostics: []const ExpectedDeclarationDiagnostic,
    }{
        .{
            .case = .two_typed,
            .source = "const value: number = 1;\n" ++
                "const value: string = \"x\";\n",
            .diagnostics = &.{},
        },
        .{
            .case = .typed_untyped,
            .source = "const value: number = 1;\n" ++
                "const value = \"x\";\n",
            .diagnostics = &.{},
        },
        .{
            .case = .untyped_typed_bad,
            .source = "const value = 1;\n" ++
                "const value: string = 2;\n",
            .diagnostics = &.{.{ .kind = .type_mismatch }},
        },
        .{
            .case = .two_typed_bad,
            .source = "const value: number = \"x\";\n" ++
                "const value: string = 2;\n",
            .diagnostics = &.{
                .{ .kind = .type_mismatch, .line = 1 },
                .{ .kind = .type_mismatch },
            },
        },
    };
    var seen = std.EnumSet(RepeatedGlobalBindingCase).initEmpty();
    for (cases) |case| {
        try expectDirectDeclarationConsumer(case.source, case.diagnostics, "", false);
        seen.insert(case.case);
    }
    try std.testing.expectEqual(std.meta.fields(RepeatedGlobalBindingCase).len, seen.count());
}

const GenericDeclarationFactCase = enum {
    combined,
    collision,
    absent_body,
    empty_parameters,
};

fn expectDirectGenericDeclarationFacts(
    source: []const u8,
    case: GenericDeclarationFactCase,
) !void {
    var atoms = AtomTable.init(std.testing.allocator);
    defer atoms.deinit();
    var parser = try JsParser.initTyped(std.testing.allocator, std.testing.allocator, source);
    defer parser.deinit();
    parser.setAtomTable(&atoms);
    _ = try parser.parse();
    var pool = TypePool.init(std.testing.allocator);
    defer pool.deinit(std.testing.allocator);
    var env = TypeEnv.init(std.testing.allocator, &pool);
    defer env.deinit();
    module_types.populateModuleTypes(&env, &pool, std.testing.allocator);
    abi_types.populateHandlerAbiTypes(&env, &pool, std.testing.allocator);
    try env.populateSourceTypes(.{ .direct = .{
        .store = &parser.type_store,
        .ir_view = parserIrView(&parser),
        .atoms = &atoms,
    } });
    try pool.ensureHealthy();
    try env.ensureHealthy();
    try std.testing.expectEqual(@as(usize, 0), env.generic_scopes.items.len);

    switch (case) {
        .combined => {
            const box = env.generic_aliases.get("Box") orelse return error.TestUnexpectedResult;
            try std.testing.expectEqual(@as(u8, 1), box.param_count);
            try std.testing.expectEqualStrings("T", box.param_names[0]);
            try std.testing.expectEqual(TypeTag.t_record, pool.getTag(box.body).?);
            const fields = pool.getRecordFields(box.body);
            try std.testing.expectEqual(@as(usize, 1), fields.len);
            try std.testing.expectEqual(TypeTag.t_ref, pool.getTag(fields[0].type_idx).?);
            try std.testing.expectEqualStrings("T", pool.getRefName(fields[0].type_idx));
            const user_id = env.getTypeAlias("UserId") orelse return error.TestUnexpectedResult;
            try std.testing.expect(pool.isNominal(user_id));
            try std.testing.expectEqualStrings("UserId", pool.nominalName(user_id));
            try std.testing.expect(env.generic_aliases.get("UserId") == null);
        },
        .collision => {
            try std.testing.expectEqual(pool.idx_number, env.getTypeAlias("Box").?);
            const box = env.generic_aliases.get("Box") orelse return error.TestUnexpectedResult;
            try std.testing.expectEqual(@as(u8, 1), box.param_count);
            try std.testing.expectEqualStrings("T", box.param_names[0]);
            try std.testing.expectEqual(TypeTag.t_record, pool.getTag(box.body).?);
        },
        .absent_body => {
            try std.testing.expect(env.getTypeAlias("Empty") == null);
            try std.testing.expect(env.generic_aliases.get("Empty") == null);
        },
        .empty_parameters => {
            const unit = env.generic_aliases.get("Unit") orelse return error.TestUnexpectedResult;
            try std.testing.expectEqual(@as(u8, 0), unit.param_count);
            try std.testing.expectEqual(pool.idx_number, unit.body);
            try std.testing.expect(env.getTypeAlias("Unit") == null);
        },
    }
}

test "direct generic declarations preserve aliases and empty distinctions" {
    const cases = [_]struct {
        source: []const u8,
        case: GenericDeclarationFactCase,
    }{
        .{
            .source = "structural Box<T> = { value: T };\n" ++
                "nominal UserId<T> = string;\n" ++
                "const box: Box<number> = { value: 1 };\n" ++
                "const id: UserId = \"x\";",
            .case = .combined,
        },
        .{
            .source = "structural Box = number;\n" ++
                "structural Box<T> = { value: T };\n" ++
                "const plain: Box = 1;\n" ++
                "const generic: Box<string> = { value: \"ok\" };",
            .case = .collision,
        },
        .{ .source = "structural Empty<T> =;", .case = .absent_body },
        .{
            .source = "structural Unit<> = number;\n" ++
                "const value: Unit<> = 1;",
            .case = .empty_parameters,
        },
    };
    var seen = std.EnumSet(GenericDeclarationFactCase).initEmpty();
    for (cases) |case| {
        try expectDirectDeclarationConsumer(case.source, &.{}, "", false);
        try expectDirectGenericDeclarationFacts(case.source, case.case);
        seen.insert(case.case);
    }
    try std.testing.expectEqual(std.meta.fields(GenericDeclarationFactCase).len, seen.count());
}

test "parsed declaration helper retains operational failure and checks absent health" {
    const record_source = "structural Record = { id: string };";
    var record_atoms = AtomTable.init(std.testing.allocator);
    defer record_atoms.deinit();
    var record_parser = try JsParser.initTyped(
        std.testing.allocator,
        std.testing.allocator,
        record_source,
    );
    defer record_parser.deinit();
    record_parser.setAtomTable(&record_atoms);
    _ = try record_parser.parse();
    var record_plan = try record_parser.type_store.planApplicationBasesWithIr(
        std.testing.allocator,
        parserIrView(&record_parser),
    );
    defer record_plan.deinit();
    const record_lowered = try std.testing.allocator.alloc(
        TypeIndex,
        record_parser.type_store.nodes.items.len,
    );
    defer std.testing.allocator.free(record_lowered);
    @memset(record_lowered, null_type_idx);
    var failing = std.testing.FailingAllocator.init(
        std.testing.allocator,
        .{ .fail_index = std.math.maxInt(usize) },
    );
    const semantic_allocator = failing.allocator();
    var record_pool = TypePool.init(semantic_allocator);
    defer record_pool.deinit(semantic_allocator);
    var record_env = TypeEnv.init(semantic_allocator, &record_pool);
    defer record_env.deinit();
    try record_pool.ensureHealthy();
    try record_env.ensureHealthy();
    const setup_allocations = failing.alloc_index;
    failing.fail_index = failing.alloc_index;
    try std.testing.expectError(
        error.OutOfMemory,
        record_env.populateParsedDeclaration(
            &record_parser.type_store,
            &record_plan,
            record_lowered,
            0,
        ),
    );
    try std.testing.expect(failing.has_induced_failure);
    try std.testing.expectEqual(setup_allocations, failing.alloc_index);
    try record_pool.ensureHealthy();
    try std.testing.expectError(error.OutOfMemory, record_env.ensureHealthy());

    const empty_source = "structural Empty =;";
    var empty_atoms = AtomTable.init(std.testing.allocator);
    defer empty_atoms.deinit();
    var empty_parser = try JsParser.initTyped(
        std.testing.allocator,
        std.testing.allocator,
        empty_source,
    );
    defer empty_parser.deinit();
    empty_parser.setAtomTable(&empty_atoms);
    _ = try empty_parser.parse();
    var empty_plan = try empty_parser.type_store.planApplicationBasesWithIr(
        std.testing.allocator,
        parserIrView(&empty_parser),
    );
    defer empty_plan.deinit();
    const empty_lowered = try std.testing.allocator.alloc(
        TypeIndex,
        empty_parser.type_store.nodes.items.len,
    );
    defer std.testing.allocator.free(empty_lowered);
    @memset(empty_lowered, null_type_idx);
    var empty_pool = TypePool.init(std.testing.allocator);
    defer empty_pool.deinit(std.testing.allocator);
    var empty_env = TypeEnv.init(std.testing.allocator, &empty_pool);
    defer empty_env.deinit();
    try std.testing.expectEqual(
        std.meta.Tag(TypeSyntax.DeclarationBody).absent,
        std.meta.activeTag(empty_parser.type_store.declarations.items[0].body),
    );
    empty_pool.failure = error.TypePoolCapacityExceeded;
    try std.testing.expectError(
        error.TypePoolCapacityExceeded,
        empty_env.populateParsedDeclaration(
            &empty_parser.type_store,
            &empty_plan,
            empty_lowered,
            0,
        ),
    );
    empty_pool.failure = null;
    empty_env.markAllocationFailure();
    try std.testing.expectError(
        error.OutOfMemory,
        empty_env.populateParsedDeclaration(
            &empty_parser.type_store,
            &empty_plan,
            empty_lowered,
            0,
        ),
    );
    try empty_pool.ensureHealthy();
}

test "parsed generic declaration helper restores scope and retains failure" {
    const source = "structural Unit<> = number;";
    var atoms = AtomTable.init(std.testing.allocator);
    defer atoms.deinit();
    var parser = try JsParser.initTyped(std.testing.allocator, std.testing.allocator, source);
    defer parser.deinit();
    parser.setAtomTable(&atoms);
    _ = try parser.parse();
    var plan = try parser.type_store.planApplicationBasesWithIr(
        std.testing.allocator,
        parserIrView(&parser),
    );
    defer plan.deinit();
    const lowered = try std.testing.allocator.alloc(TypeIndex, parser.type_store.nodes.items.len);
    defer std.testing.allocator.free(lowered);
    @memset(lowered, null_type_idx);

    var failing = std.testing.FailingAllocator.init(
        std.testing.allocator,
        .{ .fail_index = std.math.maxInt(usize) },
    );
    const semantic_allocator = failing.allocator();
    var pool = TypePool.init(semantic_allocator);
    defer pool.deinit(semantic_allocator);
    var env = TypeEnv.init(semantic_allocator, &pool);
    defer env.deinit();
    try pool.ensureHealthy();
    try env.ensureHealthy();
    const setup_allocations = failing.alloc_index;
    failing.fail_index = setup_allocations;
    try std.testing.expectError(
        error.OutOfMemory,
        env.populateParsedDeclaration(&parser.type_store, &plan, lowered, 0),
    );
    try std.testing.expect(failing.has_induced_failure);
    try std.testing.expectEqual(setup_allocations, failing.alloc_index);
    try std.testing.expectEqual(@as(usize, 0), env.generic_scopes.items.len);
    try std.testing.expect(env.generic_aliases.get("Unit") == null);
    try pool.ensureHealthy();
    try std.testing.expectError(error.OutOfMemory, env.ensureHealthy());
}

test "parsed generic declaration helper validates exact owner before mutation" {
    const source = "structural Box<T> = T;";
    var atoms = AtomTable.init(std.testing.allocator);
    defer atoms.deinit();
    var parser = try JsParser.initTyped(std.testing.allocator, std.testing.allocator, source);
    defer parser.deinit();
    parser.setAtomTable(&atoms);
    _ = try parser.parse();
    var plan = try parser.type_store.planApplicationBasesWithIr(
        std.testing.allocator,
        parserIrView(&parser),
    );
    defer plan.deinit();
    const lowered = try std.testing.allocator.alloc(TypeIndex, parser.type_store.nodes.items.len);
    defer std.testing.allocator.free(lowered);
    @memset(lowered, null_type_idx);
    var pool = TypePool.init(std.testing.allocator);
    defer pool.deinit(std.testing.allocator);
    var env = TypeEnv.init(std.testing.allocator, &pool);
    defer env.deinit();
    const initial_nodes = pool.nodes.items.len;
    const initial_names = env.name_storage.items.len;
    const initial_generic_aliases = env.generic_aliases.count();

    const owner_index = parser.type_store.declarations.items[0].generic_owner.?;
    const original_identity = parser.type_store.generic_owners.items[owner_index].identity;
    parser.type_store.generic_owners.items[owner_index].identity = .{ .structural_declaration = 1 };
    try std.testing.expectError(
        error.InvalidGenericOwner,
        env.populateParsedDeclaration(&parser.type_store, &plan, lowered, 0),
    );
    parser.type_store.generic_owners.items[owner_index].identity = original_identity;

    const original_compatibility = parser.type_store.generic_owners.items[owner_index].compatibility;
    parser.type_store.generic_owners.items[owner_index].compatibility = .ignored_declaration_parameters;
    try std.testing.expectError(
        error.InvalidGenericOwner,
        env.populateParsedDeclaration(&parser.type_store, &plan, lowered, 0),
    );
    parser.type_store.generic_owners.items[owner_index].compatibility = original_compatibility;

    parser.type_store.declarations.items[0].kind = .nominal;
    try std.testing.expectError(
        error.InvalidGenericOwner,
        env.populateParsedDeclaration(&parser.type_store, &plan, lowered, 0),
    );
    parser.type_store.declarations.items[0].kind = .structural;
    try std.testing.expectEqual(initial_nodes, pool.nodes.items.len);
    try std.testing.expectEqual(initial_names, env.name_storage.items.len);
    try std.testing.expectEqual(initial_generic_aliases, env.generic_aliases.count());
    try std.testing.expectEqual(@as(usize, 0), env.generic_scopes.items.len);
    try pool.ensureHealthy();
    try env.ensureHealthy();
}

test "parsed generic declaration helper rejects malformed oversized projected Store" {
    const wide_source = "structural Wide<A, B, C, D, E, F, G, H, I> = string;";
    var wide_atoms = AtomTable.init(std.testing.allocator);
    defer wide_atoms.deinit();
    var wide_parser = try JsParser.initTyped(
        std.testing.allocator,
        std.testing.allocator,
        wide_source,
    );
    defer wide_parser.deinit();
    wide_parser.setAtomTable(&wide_atoms);
    _ = try wide_parser.parse();
    const wide_owner = wide_parser.type_store.generic_owners.items[0];
    try std.testing.expectEqual(@as(u32, 9), wide_owner.authored_parameters.count);
    try std.testing.expectEqual(
        @as(u32, @intCast(type_env_mod.MAX_TYPE_PARAMS)),
        wide_owner.projected_parameters.count,
    );
    var wide_plan = try wide_parser.type_store.planApplicationBasesWithIr(
        std.testing.allocator,
        parserIrView(&wide_parser),
    );
    defer wide_plan.deinit();
    const extra_projected = wide_parser.type_store.projected_generic_parameters.items[7];
    try wide_parser.type_store.projected_generic_parameters.append(
        std.testing.allocator,
        extra_projected,
    );
    wide_parser.type_store.generic_owners.items[0].projected_parameters.count += 1;
    const malformed_owner = wide_parser.type_store.generic_owners.items[0];
    const malformed_projected = wide_parser.type_store.projectedGenericParameterSlice(
        malformed_owner.projected_parameters,
    ) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, type_env_mod.MAX_TYPE_PARAMS + 1), malformed_projected.len);
    const wide_lowered = try std.testing.allocator.alloc(
        TypeIndex,
        wide_parser.type_store.nodes.items.len,
    );
    defer std.testing.allocator.free(wide_lowered);
    @memset(wide_lowered, null_type_idx);
    var pool = TypePool.init(std.testing.allocator);
    defer pool.deinit(std.testing.allocator);
    var env = TypeEnv.init(std.testing.allocator, &pool);
    defer env.deinit();
    const initial_nodes = pool.nodes.items.len;
    const initial_names = env.name_storage.items.len;
    const initial_generic_aliases = env.generic_aliases.count();
    try std.testing.expectError(
        error.InvalidTypeRange,
        env.populateParsedDeclaration(&wide_parser.type_store, &wide_plan, wide_lowered, 0),
    );
    try std.testing.expectEqual(initial_nodes, pool.nodes.items.len);
    try std.testing.expectEqual(initial_names, env.name_storage.items.len);
    try std.testing.expectEqual(initial_generic_aliases, env.generic_aliases.count());
    try std.testing.expectEqual(@as(usize, 0), env.generic_scopes.items.len);
    try pool.ensureHealthy();
    try env.ensureHealthy();
}

const DirectDeclarationAllocationObservations = struct {
    selected_failures: usize = 0,
    post_seed_failures: usize = 0,
};

fn runDirectDeclarationAllocationSweep(
    allocator: std.mem.Allocator,
    observations: *DirectDeclarationAllocationObservations,
) !void {
    const source =
        "structural Seed = string;\n" ++
        "structural Loop = Loop;\n" ++
        "const seed: Seed = \"ok\";";
    var runtime_count = CountingAllocator.init(std.testing.allocator);
    var atoms = AtomTable.init(runtime_count.allocator());
    defer atoms.deinit();
    var parser = try JsParser.initTyped(runtime_count.allocator(), std.testing.allocator, source);
    defer parser.deinit();
    parser.setAtomTable(&atoms);
    const root = try parser.parse();
    try expectRuntimeParityAndShape(source, &parser, root, &atoms, runtime_count);

    var pool = TypePool.init(allocator);
    defer pool.deinit(allocator);
    var env = TypeEnv.init(allocator, &pool);
    defer env.deinit();
    env.populateSourceTypes(.{ .direct = .{
        .store = &parser.type_store,
        .ir_view = parserIrView(&parser),
        .atoms = &atoms,
    } }) catch |err| {
        if (env.sourceTypeMode() == .direct) {
            observations.selected_failures += 1;
            if (env.getTypeAlias("Seed") != null) observations.post_seed_failures += 1;
            try std.testing.expectError(error.OutOfMemory, env.ensureHealthy());
        }
        return err;
    };
    try pool.ensureHealthy();
    try env.ensureHealthy();
    try std.testing.expect(env.getTypeAlias("Seed") != null);
    try std.testing.expect(env.isNonContractiveAlias("Loop"));
    try std.testing.expectEqual(@as(usize, 1), env.varAnnotationCount());
}

test "direct declaration allocation failures retain selected health" {
    var observations: DirectDeclarationAllocationObservations = .{};
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        runDirectDeclarationAllocationSweep,
        .{&observations},
    );
    try std.testing.expect(observations.selected_failures > 0);
    try std.testing.expect(observations.post_seed_failures > 0);
}

const DirectGenericDeclarationAllocationObservations = struct {
    selected_failures: usize = 0,
    post_seed_failures: usize = 0,
    generic_construction_failures: usize = 0,
};

fn runDirectGenericDeclarationAllocationSweep(
    allocator: std.mem.Allocator,
    observations: *DirectGenericDeclarationAllocationObservations,
) !void {
    const source =
        "structural Seed = string;\n" ++
        "structural Box<T> = { value: T };\n" ++
        "const seed: Seed = \"ok\";";
    var runtime_count = CountingAllocator.init(std.testing.allocator);
    var atoms = AtomTable.init(runtime_count.allocator());
    defer atoms.deinit();
    var parser = try JsParser.initTyped(runtime_count.allocator(), std.testing.allocator, source);
    defer parser.deinit();
    parser.setAtomTable(&atoms);
    const root = try parser.parse();
    try expectRuntimeParityAndShape(source, &parser, root, &atoms, runtime_count);

    var pool = TypePool.init(allocator);
    defer pool.deinit(allocator);
    var env = TypeEnv.init(allocator, &pool);
    defer env.deinit();
    env.populateSourceTypes(.{ .direct = .{
        .store = &parser.type_store,
        .ir_view = parserIrView(&parser),
        .atoms = &atoms,
    } }) catch |err| {
        try std.testing.expectEqual(@as(usize, 0), env.generic_scopes.items.len);
        if (env.sourceTypeMode() == .direct) {
            observations.selected_failures += 1;
            if (env.getTypeAlias("Seed") != null) {
                observations.post_seed_failures += 1;
                if (env.generic_aliases.get("Box") == null) {
                    observations.generic_construction_failures += 1;
                }
            }
            try std.testing.expectError(error.OutOfMemory, env.ensureHealthy());
        }
        return err;
    };
    try pool.ensureHealthy();
    try env.ensureHealthy();
    try std.testing.expect(env.getTypeAlias("Seed") != null);
    const box = env.generic_aliases.get("Box") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u8, 1), box.param_count);
    try std.testing.expectEqualStrings("T", box.param_names[0]);
    try std.testing.expectEqual(@as(usize, 0), env.generic_scopes.items.len);
}

test "direct generic declaration allocation failures restore scope after seed" {
    var observations: DirectGenericDeclarationAllocationObservations = .{};
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        runDirectGenericDeclarationAllocationSweep,
        .{&observations},
    );
    try std.testing.expect(observations.selected_failures > 0);
    try std.testing.expect(observations.post_seed_failures > 0);
    try std.testing.expect(observations.generic_construction_failures > 0);
}

test "direct source pilot compacts annotated parameters by final owner" {
    const source = "function helper(skip, value: string): number { return 1; }";
    var prepared = try PreparedSource.init(std.testing.allocator, source, "<u12-compact>.ts", .{});
    defer prepared.deinit();
    var legacy_count = CountingAllocator.init(std.testing.allocator);
    var direct_count = CountingAllocator.init(std.testing.allocator);
    var type_count = CountingAllocator.init(std.testing.allocator);
    var legacy_atoms = AtomTable.init(legacy_count.allocator());
    defer legacy_atoms.deinit();
    var direct_atoms = AtomTable.init(direct_count.allocator());
    defer direct_atoms.deinit();
    var legacy = try JsParser.init(legacy_count.allocator(), prepared.parserInput());
    defer legacy.deinit();
    legacy.setAtomTable(&legacy_atoms);
    var direct = try JsParser.initTyped(direct_count.allocator(), type_count.allocator(), source);
    defer direct.deinit();
    direct.setAtomTable(&direct_atoms);
    const legacy_root = try legacy.parse();
    const direct_root = try direct.parse();
    const legacy_view = parserIrView(&legacy);
    const direct_view = parserIrView(&direct);
    try std.testing.expect(compareRuntime(
        &legacy,
        legacy_root,
        &legacy_atoms,
        &direct,
        direct_root,
        &direct_atoms,
    ) == null);
    try std.testing.expect(legacy_count.sameRuntimeShape(direct_count));

    var legacy_pool = TypePool.init(std.testing.allocator);
    defer legacy_pool.deinit(std.testing.allocator);
    var direct_pool = TypePool.init(std.testing.allocator);
    defer direct_pool.deinit(std.testing.allocator);
    var legacy_env = TypeEnv.init(std.testing.allocator, &legacy_pool);
    defer legacy_env.deinit();
    var direct_env = TypeEnv.init(std.testing.allocator, &direct_pool);
    defer direct_env.deinit();
    try legacy_env.populateSourceTypes(.{ .legacy = prepared.typeMap().? });
    try direct_env.populateSourceTypes(.{ .direct = .{
        .store = &direct.type_store,
        .ir_view = direct_view,
        .atoms = &direct_atoms,
    } });
    try expectExactTypePool(&legacy_pool, &direct_pool);
    const signature_record = direct.type_store.function_signatures.items[0];
    const reference = direct_env.functionTypeRef(direct_view, signature_record.owner) orelse
        return error.TestUnexpectedResult;
    const legacy_reference = legacy_env.functionTypeRef(
        legacy_view,
        signature_record.owner,
    ) orelse return error.TestUnexpectedResult;
    const signature = direct_env.getFunctionSignature(reference) orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u8, 1), signature.param_count);
    try std.testing.expectEqual(direct_pool.idx_string, signature.param_types[0]);
    try std.testing.expectEqualStrings(
        "string",
        direct_env.getFunctionParameterSpelling(reference, 0).?,
    );
    try std.testing.expectEqualStrings(
        legacy_env.getFunctionParameterSpelling(legacy_reference, 0).?,
        direct_env.getFunctionParameterSpelling(reference, 0).?,
    );
    try std.testing.expect(direct_env.getFunctionParameterSpelling(reference, 1) == null);
    try std.testing.expectEqualStrings(
        "number ",
        direct_env.getFunctionReturnSpelling(reference).?,
    );
    try std.testing.expectEqualStrings(
        legacy_env.getFunctionReturnSpelling(legacy_reference).?,
        direct_env.getFunctionReturnSpelling(reference).?,
    );
    try std.testing.expectEqual(@as(usize, 2), direct_env.direct_accumulator_events);
}

test "direct function specifications preserve variable arrow capsule absence" {
    const source =
        "const helper = (value: number): Proof<number, \"deterministic\"> => value;";
    var prepared = try PreparedSource.init(std.testing.allocator, source, "<u12-arrow-capsule>.ts", .{});
    defer prepared.deinit();
    var legacy_count = CountingAllocator.init(std.testing.allocator);
    var direct_count = CountingAllocator.init(std.testing.allocator);
    var type_count = CountingAllocator.init(std.testing.allocator);
    var legacy_atoms = AtomTable.init(legacy_count.allocator());
    defer legacy_atoms.deinit();
    var direct_atoms = AtomTable.init(direct_count.allocator());
    defer direct_atoms.deinit();
    var legacy = try JsParser.init(legacy_count.allocator(), prepared.parserInput());
    defer legacy.deinit();
    legacy.setAtomTable(&legacy_atoms);
    var direct = try JsParser.initTyped(direct_count.allocator(), type_count.allocator(), source);
    defer direct.deinit();
    direct.setAtomTable(&direct_atoms);
    const legacy_root = try legacy.parse();
    const direct_root = try direct.parse();
    const legacy_view = parserIrView(&legacy);
    const direct_view = parserIrView(&direct);
    try std.testing.expect(compareRuntime(
        &legacy,
        legacy_root,
        &legacy_atoms,
        &direct,
        direct_root,
        &direct_atoms,
    ) == null);
    try std.testing.expect(legacy_count.sameRuntimeShape(direct_count));

    var legacy_pool = TypePool.init(std.testing.allocator);
    defer legacy_pool.deinit(std.testing.allocator);
    var direct_pool = TypePool.init(std.testing.allocator);
    defer direct_pool.deinit(std.testing.allocator);
    var legacy_env = TypeEnv.init(std.testing.allocator, &legacy_pool);
    defer legacy_env.deinit();
    var direct_env = TypeEnv.init(std.testing.allocator, &direct_pool);
    defer direct_env.deinit();
    module_types.populateModuleTypes(&legacy_env, &legacy_pool, std.testing.allocator);
    abi_types.populateHandlerAbiTypes(&legacy_env, &legacy_pool, std.testing.allocator);
    module_types.populateModuleTypes(&direct_env, &direct_pool, std.testing.allocator);
    abi_types.populateHandlerAbiTypes(&direct_env, &direct_pool, std.testing.allocator);
    try legacy_env.populateSourceTypes(.{ .legacy = prepared.typeMap().? });
    try direct_env.populateSourceTypes(.{ .direct = .{
        .store = &direct.type_store,
        .ir_view = direct_view,
        .atoms = &direct_atoms,
    } });
    try expectExactTypePool(&legacy_pool, &direct_pool);

    var legacy_effects = try effect_inference.buildEffectFacts(
        std.testing.allocator,
        legacy_view,
        &legacy_atoms,
        legacy_root,
        .{},
    );
    defer legacy_effects.deinit(std.testing.allocator);
    var direct_effects = try effect_inference.buildEffectFacts(
        std.testing.allocator,
        direct_view,
        &direct_atoms,
        direct_root,
        .{},
    );
    defer direct_effects.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), legacy_effects.all().len);
    try std.testing.expectEqual(@as(usize, 1), direct_effects.all().len);
    const legacy_effect = legacy_effects.all()[0];
    const direct_effect = direct_effects.all()[0];
    try std.testing.expectEqual(engine.parser.NodeTag.var_decl, legacy_view.getTag(legacy_effect.decl_node).?);
    try std.testing.expectEqual(engine.parser.NodeTag.var_decl, direct_view.getTag(direct_effect.decl_node).?);
    const direct_declaration = direct_view.getVarDecl(direct_effect.decl_node) orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqual(engine.parser.NodeTag.arrow_function, direct_view.getTag(direct_declaration.init).?);
    const arrow_reference = direct_env.functionTypeRef(direct_view, direct_declaration.init) orelse
        return error.TestUnexpectedResult;
    try std.testing.expect(direct_env.getFunctionSignature(arrow_reference) != null);

    var legacy_capsules = try function_specs.dischargeWithTypeSource(
        std.testing.allocator,
        &legacy_effects,
        .{ .legacy = &legacy_env },
        legacy_view,
    );
    defer legacy_capsules.deinit(std.testing.allocator);
    var direct_capsules = try function_specs.dischargeWithTypeSource(
        std.testing.allocator,
        &direct_effects,
        .{ .direct = &direct_env },
        direct_view,
    );
    defer direct_capsules.deinit(std.testing.allocator);
    const legacy_capsule = legacy_capsules.byName("helper") orelse return error.TestUnexpectedResult;
    const direct_capsule = direct_capsules.byName("helper") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 0), legacy_capsule.declared.items.len);
    try std.testing.expectEqual(@as(usize, 0), direct_capsule.declared.items.len);
    try std.testing.expectEqual(@as(usize, 0), legacy_capsule.effect_declared.items.len);
    try std.testing.expectEqual(@as(usize, 0), direct_capsule.effect_declared.items.len);
    try std.testing.expectEqual(@as(usize, 0), legacy_capsule.inferred_caps.count());
    try std.testing.expectEqual(@as(usize, 0), direct_capsule.inferred_caps.count());
    try std.testing.expect(legacy_capsule.proven.total);
    try std.testing.expect(legacy_capsule.proven.pure);
    try std.testing.expect(legacy_capsule.proven.read_only);
    try std.testing.expect(legacy_capsule.proven.deterministic);
    try std.testing.expect(std.meta.eql(legacy_capsule.proven, direct_capsule.proven));
    try std.testing.expect(!legacy_capsule.discharged());
    try std.testing.expect(!direct_capsule.discharged());
    try std.testing.expect(!legacy_capsule.effectDischarged());
    try std.testing.expect(!direct_capsule.effectDischarged());
}

const ExpectedConsumerTypeDiagnostic = struct {
    kind: type_checker_mod.DiagnosticKind,
    line: ?u32 = null,
    column: ?u32 = null,
};

const ExpectedConsumerStrictDiagnostic = struct {
    kind: strict_checker_mod.DiagnosticKind,
    line: ?u32 = null,
    column: ?u32 = null,
};

fn expectDirectConsumerMatrixCase(
    source: []const u8,
    expected_type_diagnostics: ?[]const ExpectedConsumerTypeDiagnostic,
    expected_strict_diagnostics: ?[]const ExpectedConsumerStrictDiagnostic,
) !void {
    var prepared = try PreparedSource.init(
        std.testing.allocator,
        source,
        "<u12-consumer-matrix>.ts",
        .{},
    );
    defer prepared.deinit();
    try std.testing.expectEqual(@as(usize, 0), prepared.stripDiagnostics().len);

    var legacy_count = CountingAllocator.init(std.testing.allocator);
    var direct_count = CountingAllocator.init(std.testing.allocator);
    var type_count = CountingAllocator.init(std.testing.allocator);
    var legacy_atoms = AtomTable.init(legacy_count.allocator());
    defer legacy_atoms.deinit();
    var direct_atoms = AtomTable.init(direct_count.allocator());
    defer direct_atoms.deinit();
    var legacy = try JsParser.init(legacy_count.allocator(), prepared.parserInput());
    defer legacy.deinit();
    legacy.setAtomTable(&legacy_atoms);
    var direct = try JsParser.initTyped(direct_count.allocator(), type_count.allocator(), source);
    defer direct.deinit();
    direct.setAtomTable(&direct_atoms);
    const legacy_root = try legacy.parse();
    const direct_root = try direct.parse();
    const legacy_view = parserIrView(&legacy);
    const direct_view = parserIrView(&direct);
    try std.testing.expect(compareRuntime(
        &legacy,
        legacy_root,
        &legacy_atoms,
        &direct,
        direct_root,
        &direct_atoms,
    ) == null);
    try std.testing.expect(legacy_count.sameRuntimeShape(direct_count));

    var legacy_pool = TypePool.init(std.testing.allocator);
    defer legacy_pool.deinit(std.testing.allocator);
    var direct_pool = TypePool.init(std.testing.allocator);
    defer direct_pool.deinit(std.testing.allocator);
    var legacy_env = TypeEnv.init(std.testing.allocator, &legacy_pool);
    defer legacy_env.deinit();
    var direct_env = TypeEnv.init(std.testing.allocator, &direct_pool);
    defer direct_env.deinit();
    module_types.populateModuleTypes(&legacy_env, &legacy_pool, std.testing.allocator);
    abi_types.populateHandlerAbiTypes(&legacy_env, &legacy_pool, std.testing.allocator);
    module_types.populateModuleTypes(&direct_env, &direct_pool, std.testing.allocator);
    abi_types.populateHandlerAbiTypes(&direct_env, &direct_pool, std.testing.allocator);
    try legacy_env.populateSourceTypes(.{ .legacy = prepared.typeMap().? });
    try direct_env.populateSourceTypes(.{ .direct = .{
        .store = &direct.type_store,
        .ir_view = direct_view,
        .atoms = &direct_atoms,
    } });

    try expectExactTypePool(&legacy_pool, &direct_pool);
    try expectExactFunctionNameMaps(&legacy_env, &direct_env);
    try expectExactOwnerSignatures(
        &legacy_env,
        &direct_env,
        legacy_view,
        direct_view,
        &direct.type_store,
    );
    try expectExactDirectCallMaps(
        &legacy_pool,
        &direct_pool,
        &legacy_env,
        &direct_env,
        legacy_view,
        direct_view,
        &direct.type_store,
    );
    try std.testing.expectEqual(
        direct.type_store.annotations.items.len,
        direct_env.varAnnotationCount(),
    );
    for (direct.type_store.annotations.items) |annotation| {
        const owner = annotation.runtime_owner orelse return error.TestUnexpectedResult;
        const declaration = direct_view.getVarDecl(owner.declaration) orelse
            return error.TestUnexpectedResult;
        try std.testing.expect(std.meta.eql(annotation.binding, declaration.binding));
        try std.testing.expect(direct_env.getVarTypeForDeclaration(
            direct_view,
            owner.declaration,
        ) != null);
    }

    var legacy_checker = type_checker_mod.TypeChecker.init(
        std.testing.allocator,
        legacy_view,
        &legacy_atoms,
        &legacy_env,
    );
    defer legacy_checker.deinit();
    var direct_checker = type_checker_mod.TypeChecker.init(
        std.testing.allocator,
        direct_view,
        &direct_atoms,
        &direct_env,
    );
    defer direct_checker.deinit();
    const legacy_type_count = try legacy_checker.check(legacy_root);
    const direct_type_count = try direct_checker.check(direct_root);
    try std.testing.expectEqual(legacy_type_count, direct_type_count);
    const legacy_type_diagnostics = legacy_checker.getDiagnostics();
    const direct_type_diagnostics = direct_checker.getDiagnostics();
    try std.testing.expectEqual(legacy_type_diagnostics.len, direct_type_diagnostics.len);
    for (legacy_type_diagnostics, direct_type_diagnostics) |legacy_diagnostic, direct_diagnostic| {
        try expectSameTypeDiagnostic(
            legacy_diagnostic,
            legacy_view,
            direct_diagnostic,
            direct_view,
        );
    }
    if (expected_type_diagnostics) |expected_diagnostics| {
        try std.testing.expectEqual(expected_diagnostics.len, direct_type_diagnostics.len);
        for (direct_type_diagnostics, expected_diagnostics) |direct_diagnostic, expected| {
            try std.testing.expectEqual(expected.kind, direct_diagnostic.kind);
            const location = direct_view.getLoc(direct_diagnostic.node) orelse
                return error.TestUnexpectedResult;
            if (expected.line) |line| try std.testing.expectEqual(line, location.line);
            if (expected.column) |column| try std.testing.expectEqual(column, location.column);
        }
    }

    var legacy_strict = strict_checker_mod.StrictChecker.init(
        std.testing.allocator,
        legacy_view,
        &legacy_atoms,
        &legacy_env,
        &legacy_checker,
    );
    defer legacy_strict.deinit();
    var direct_strict = strict_checker_mod.StrictChecker.init(
        std.testing.allocator,
        direct_view,
        &direct_atoms,
        &direct_env,
        &direct_checker,
    );
    defer direct_strict.deinit();
    const legacy_strict_count = try legacy_strict.check(legacy_root);
    const direct_strict_count = try direct_strict.check(direct_root);
    try std.testing.expectEqual(legacy_strict_count, direct_strict_count);
    const legacy_strict_diagnostics = legacy_strict.getDiagnostics();
    const direct_strict_diagnostics = direct_strict.getDiagnostics();
    try std.testing.expectEqual(legacy_strict_diagnostics.len, direct_strict_diagnostics.len);
    for (legacy_strict_diagnostics, direct_strict_diagnostics) |legacy_diagnostic, direct_diagnostic| {
        try expectSameStrictDiagnostic(
            legacy_diagnostic,
            legacy_view,
            direct_diagnostic,
            direct_view,
        );
    }
    if (expected_strict_diagnostics) |expected_diagnostics| {
        try std.testing.expectEqual(expected_diagnostics.len, direct_strict_diagnostics.len);
        for (direct_strict_diagnostics, expected_diagnostics) |direct_diagnostic, expected| {
            try std.testing.expectEqual(expected.kind, direct_diagnostic.kind);
            const location = direct_view.getLoc(direct_diagnostic.node) orelse
                return error.TestUnexpectedResult;
            if (expected.line) |line| try std.testing.expectEqual(line, location.line);
            if (expected.column) |column| try std.testing.expectEqual(column, location.column);
        }
    }
}

const LookupConsumerCase = enum {
    forward_repeated,
    repeated_predicates,
    return_fallback,
    untyped_shadow_gap,
    shadowed_capture,
    untyped_shadow_gap_mismatch,
    shadowed_capture_mismatch,
};

test "direct consumers preserve measured lookup winners shadows and captures" {
    const cases = [_]struct {
        case: LookupConsumerCase,
        source: []const u8,
        type_diagnostics: []const ExpectedConsumerTypeDiagnostic,
        strict_diagnostics: []const ExpectedConsumerStrictDiagnostic,
    }{
        .{
            .case = .forward_repeated,
            .source =
            \\function useNumber(value: number): number {
            \\  inner(value);
            \\  function inner(item: number): number { return item; }
            \\  return value;
            \\}
            \\function useText(value: string): string {
            \\  inner(value, "");
            \\  function inner(item: string, suffix: string): string { return item; }
            \\  return value;
            \\}
            \\export function handler(req: Request): Response {
            \\  return Response.json({ number: useNumber(1), text: useText("x") });
            \\}
            \\
            ,
            .type_diagnostics = &.{.{ .kind = .arg_type_mismatch, .line = 7, .column = 9 }},
            .strict_diagnostics = &.{
                .{ .kind = .unpublished_ambient_global, .line = 2, .column = 3 },
                .{ .kind = .unpublished_ambient_global, .line = 7, .column = 3 },
            },
        },
        .{
            .case = .repeated_predicates,
            .source =
            \\{
            \\  function isText(value: string | number): value is string {
            \\    return typeof value === "string";
            \\  }
            \\  const raw: string | number = "first";
            \\  if (isText(raw)) { const text: string = raw; }
            \\}
            \\{
            \\  function isText(skip: number, value: string | number): value is string {
            \\    return typeof value === "string";
            \\  }
            \\  const raw: string | number = "second";
            \\  if (isText(0, raw)) { const text: string = raw; }
            \\}
            \\export function handler(req: Request): Response {
            \\  return Response.json({ ok: true });
            \\}
            \\
            ,
            .type_diagnostics = &.{
                .{ .kind = .invalid_type_predicate, .line = 9, .column = 3 },
                .{ .kind = .type_mismatch, .line = 13, .column = 25 },
            },
            .strict_diagnostics = &.{},
        },
        .{
            .case = .return_fallback,
            .source =
            \\function numericValue(): number {
            \\  const value: number = make();
            \\  function make(): number { return 1; }
            \\  return value;
            \\}
            \\function textValue(): string {
            \\  const value: string = make();
            \\  function make(): string { return "text"; }
            \\  return value;
            \\}
            \\export function handler(req: Request): Response {
            \\  return Response.json({ number: numericValue(), text: textValue() });
            \\}
            \\
            ,
            .type_diagnostics = &.{.{ .kind = .type_mismatch, .line = 2, .column = 3 }},
            .strict_diagnostics = &.{
                .{
                    .kind = .unpublished_ambient_global,
                    .line = 2,
                    .column = 25,
                },
                .{
                    .kind = .unpublished_ambient_global,
                    .line = 7,
                    .column = 25,
                },
            },
        },
        .{
            .case = .untyped_shadow_gap,
            .source =
            \\const item: number = 1;
            \\function readItem(): string {
            \\  const item = "inferred";
            \\  {
            \\    const item: string = "typed";
            \\    return item;
            \\  }
            \\}
            \\export function handler(req: Request): Response {
            \\  return Response.json({ top: item, nested: readItem() });
            \\}
            \\
            ,
            .type_diagnostics = &.{},
            .strict_diagnostics = &.{},
        },
        .{
            .case = .shadowed_capture,
            .source =
            \\function compute(): number {
            \\  const value: number = 1;
            \\  const readOuter = (): number => value;
            \\  {
            \\    const value: string = "inner";
            \\    const readInner = (): string => value;
            \\    const outerResult: number = readOuter();
            \\    const innerResult: string = readInner();
            \\    return outerResult;
            \\  }
            \\}
            \\export function handler(req: Request): Response {
            \\  return Response.json({ value: compute() });
            \\}
            \\
            ,
            .type_diagnostics = &.{},
            .strict_diagnostics = &.{},
        },
        .{
            .case = .untyped_shadow_gap_mismatch,
            .source =
            \\const item: number = 1;
            \\function readItem(): string {
            \\  const item = "inferred";
            \\  {
            \\    const item: string = 2;
            \\    return item;
            \\  }
            \\}
            \\export function handler(req: Request): Response {
            \\  return Response.json({ top: item, nested: readItem() });
            \\}
            \\
            ,
            .type_diagnostics = &.{.{ .kind = .type_mismatch, .line = 5, .column = 5 }},
            .strict_diagnostics = &.{},
        },
        .{
            .case = .shadowed_capture_mismatch,
            .source =
            \\function compute(): number {
            \\  const value: number = 1;
            \\  const readOuter = (): number => value;
            \\  {
            \\    const value: string = "inner";
            \\    const readInner = (): number => value;
            \\    const outerResult: number = readOuter();
            \\    const innerResult: number = readInner();
            \\    return outerResult;
            \\  }
            \\}
            \\export function handler(req: Request): Response {
            \\  return Response.json({ value: compute() });
            \\}
            \\
            ,
            .type_diagnostics = &.{.{
                .kind = .return_type_mismatch,
                .line = 6,
                .column = 23,
            }},
            .strict_diagnostics = &.{},
        },
    };
    try std.testing.expectEqual(std.meta.fields(LookupConsumerCase).len, cases.len);
    var seen = std.EnumSet(LookupConsumerCase).initEmpty();
    for (cases) |case| {
        try std.testing.expect(!seen.contains(case.case));
        try expectDirectConsumerMatrixCase(
            case.source,
            case.type_diagnostics,
            case.strict_diagnostics,
        );
        seen.insert(case.case);
    }
    try std.testing.expectEqual(std.meta.fields(LookupConsumerCase).len, seen.count());
}

const ConsumerSemanticCase = enum {
    generic_substitution,
    generic_constraint,
    compact_arity,
    incomplete_signature,
    annotated_arrow_without_return,
};

test "direct consumers preserve generic calls compact arity and strict signature rules" {
    const cases = [_]struct {
        case: ConsumerSemanticCase,
        source: []const u8,
        type_diagnostics: ?[]const ExpectedConsumerTypeDiagnostic,
        strict_diagnostics: ?[]const ExpectedConsumerStrictDiagnostic,
    }{
        .{
            .case = .generic_substitution,
            .source =
            \\function first<T>(values: T[]): T | undefined { return values[0]; }
            \\function handler(req: Request): Response {
            \\  const head: number | undefined = first(["a"]);
            \\  return Response.json({ head: head });
            \\}
            ,
            .type_diagnostics = &.{.{ .kind = .type_mismatch }},
            .strict_diagnostics = &.{},
        },
        .{
            .case = .generic_constraint,
            .source =
            \\function idOf<T extends { id: string }>(value: T): string { return value.id; }
            \\function handler(req: Request): Response {
            \\  const value = idOf({ name: "no id" });
            \\  return Response.json({ value: value });
            \\}
            ,
            .type_diagnostics = &.{.{ .kind = .type_constraint_violation }},
            .strict_diagnostics = &.{},
        },
        .{
            .case = .compact_arity,
            .source =
            \\const first = (a: number, b): number => a;
            \\function handler(req: Request): Response {
            \\  return Response.json({ value: first(1, 2, 3) });
            \\}
            ,
            .type_diagnostics = &.{.{ .kind = .arg_count_mismatch }},
            .strict_diagnostics = &.{.{ .kind = .missing_public_annotation }},
        },
        .{
            .case = .incomplete_signature,
            .source =
            \\function handler(req: Request): Response { return Response.json({}); }
            \\const first = (a: number, b): number => a;
            ,
            .type_diagnostics = null,
            .strict_diagnostics = &.{.{ .kind = .missing_public_annotation }},
        },
        .{
            .case = .annotated_arrow_without_return,
            .source =
            \\function handler(req: Request): Response {
            \\  return Response.json({ ys: [1].map((x: number) => x) });
            \\}
            ,
            .type_diagnostics = &.{},
            .strict_diagnostics = &.{},
        },
    };
    try std.testing.expectEqual(std.meta.fields(ConsumerSemanticCase).len, cases.len);
    var seen = std.EnumSet(ConsumerSemanticCase).initEmpty();
    for (cases) |case| {
        try std.testing.expect(!seen.contains(case.case));
        try expectDirectConsumerMatrixCase(
            case.source,
            case.type_diagnostics,
            case.strict_diagnostics,
        );
        seen.insert(case.case);
    }
    try std.testing.expectEqual(std.meta.fields(ConsumerSemanticCase).len, seen.count());
}

fn expectDirectPrimitiveFacts(source: []const u8) !void {
    try expectDirectConsumerMatrixCase(source, null, null);

    var atoms = AtomTable.init(std.testing.allocator);
    defer atoms.deinit();
    var parser = try JsParser.initTyped(std.testing.allocator, std.testing.allocator, source);
    defer parser.deinit();
    parser.setAtomTable(&atoms);
    _ = try parser.parse();
    const view = parserIrView(&parser);
    var pool = TypePool.init(std.testing.allocator);
    defer pool.deinit(std.testing.allocator);
    var env = TypeEnv.init(std.testing.allocator, &pool);
    defer env.deinit();
    module_types.populateModuleTypes(&env, &pool, std.testing.allocator);
    abi_types.populateHandlerAbiTypes(&env, &pool, std.testing.allocator);
    try env.populateSourceTypes(.{ .direct = .{
        .store = &parser.type_store,
        .ir_view = view,
        .atoms = &atoms,
    } });

    try std.testing.expectEqual(@as(usize, 0), parser.type_store.annotations.items.len);
    try std.testing.expectEqual(@as(usize, 0), env.varAnnotationCount());

    try std.testing.expectEqual(@as(usize, 1), parser.type_store.function_signatures.items.len);
    const owner = parser.type_store.function_signatures.items[0].owner;
    const reference = env.functionTypeRef(view, owner) orelse return error.TestUnexpectedResult;
    const signature = env.getFunctionSignature(reference) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u8, 3), signature.param_count);
    try std.testing.expectEqualSlices(
        TypeIndex,
        &.{ pool.idx_null, pool.idx_undefined, pool.idx_unknown },
        signature.param_types[0..signature.param_count],
    );
    try std.testing.expectEqual(pool.idx_unknown, signature.return_type);
}

test "direct consumers preserve null undefined and unknown primitives" {
    const source =
        \\function kinds(a: null, b: undefined, c: unknown): unknown { return c; }
        \\
    ;
    try expectDirectPrimitiveFacts(source);
}

test "direct consumers preserve present null failure and hide refused expression types" {
    const source =
        \\const absent: `` = "";
        \\const known: unknown = 1;
        \\const n: number = 1;
        \\const refused = n + "y";
        \\
    ;
    var prepared = try PreparedSource.init(
        std.testing.allocator,
        source,
        "<u12-present-null>.ts",
        .{},
    );
    defer prepared.deinit();
    try std.testing.expectEqual(@as(usize, 0), prepared.stripDiagnostics().len);

    var legacy_count = CountingAllocator.init(std.testing.allocator);
    var direct_count = CountingAllocator.init(std.testing.allocator);
    var type_count = CountingAllocator.init(std.testing.allocator);
    var legacy_atoms = AtomTable.init(legacy_count.allocator());
    defer legacy_atoms.deinit();
    var direct_atoms = AtomTable.init(direct_count.allocator());
    defer direct_atoms.deinit();
    var legacy = try JsParser.init(legacy_count.allocator(), prepared.parserInput());
    defer legacy.deinit();
    legacy.setAtomTable(&legacy_atoms);
    var direct = try JsParser.initTyped(
        direct_count.allocator(),
        type_count.allocator(),
        source,
    );
    defer direct.deinit();
    direct.setAtomTable(&direct_atoms);
    const legacy_root = try legacy.parse();
    const direct_root = try direct.parse();
    const legacy_view = parserIrView(&legacy);
    const direct_view = parserIrView(&direct);
    try std.testing.expect(compareRuntime(
        &legacy,
        legacy_root,
        &legacy_atoms,
        &direct,
        direct_root,
        &direct_atoms,
    ) == null);
    try std.testing.expect(legacy_count.sameRuntimeShape(direct_count));

    var legacy_pool = TypePool.init(std.testing.allocator);
    defer legacy_pool.deinit(std.testing.allocator);
    var direct_pool = TypePool.init(std.testing.allocator);
    defer direct_pool.deinit(std.testing.allocator);
    var legacy_env = TypeEnv.init(std.testing.allocator, &legacy_pool);
    defer legacy_env.deinit();
    var direct_env = TypeEnv.init(std.testing.allocator, &direct_pool);
    defer direct_env.deinit();
    module_types.populateModuleTypes(&legacy_env, &legacy_pool, std.testing.allocator);
    abi_types.populateHandlerAbiTypes(&legacy_env, &legacy_pool, std.testing.allocator);
    module_types.populateModuleTypes(&direct_env, &direct_pool, std.testing.allocator);
    abi_types.populateHandlerAbiTypes(&direct_env, &direct_pool, std.testing.allocator);
    try legacy_env.populateSourceTypes(.{ .legacy = prepared.typeMap().? });
    try direct_env.populateSourceTypes(.{ .direct = .{
        .store = &direct.type_store,
        .ir_view = direct_view,
        .atoms = &direct_atoms,
    } });

    try expectExactTypePool(&legacy_pool, &direct_pool);
    try expectExactFunctionNameMaps(&legacy_env, &direct_env);
    try expectExactOwnerSignatures(
        &legacy_env,
        &direct_env,
        legacy_view,
        direct_view,
        &direct.type_store,
    );
    try expectExactDirectCallMaps(
        &legacy_pool,
        &direct_pool,
        &legacy_env,
        &direct_env,
        legacy_view,
        direct_view,
        &direct.type_store,
    );
    try std.testing.expectEqual(
        direct.type_store.annotations.items.len,
        direct_env.varAnnotationCount(),
    );
    try std.testing.expectEqual(@as(usize, 3), direct.type_store.annotations.items.len);
    var found_absent = false;
    var found_unknown = false;
    var found_number = false;
    for (direct.type_store.annotations.items) |annotation| {
        const owner = annotation.runtime_owner orelse return error.TestUnexpectedResult;
        const declaration = direct_view.getVarDecl(owner.declaration) orelse
            return error.TestUnexpectedResult;
        try std.testing.expect(std.meta.eql(annotation.binding, declaration.binding));
        const direct_type = direct_env.getVarTypeForDeclaration(
            direct_view,
            owner.declaration,
        ) orelse return error.TestUnexpectedResult;
        if (std.mem.eql(u8, annotation.raw_span.text(source), "``")) {
            try std.testing.expectEqual(null_type_idx, direct_type);
            found_absent = true;
        } else if (std.mem.eql(u8, annotation.raw_span.text(source), "unknown")) {
            try std.testing.expectEqual(direct_pool.idx_unknown, direct_type);
            found_unknown = true;
        } else if (std.mem.eql(u8, annotation.raw_span.text(source), "number")) {
            try std.testing.expectEqual(direct_pool.idx_number, direct_type);
            found_number = true;
        } else {
            return error.TestUnexpectedResult;
        }
    }
    try std.testing.expect(found_absent);
    try std.testing.expect(found_unknown);
    try std.testing.expect(found_number);
    try std.testing.expectEqual(null_type_idx, legacy_env.getVarTypeByName("absent").?);
    try std.testing.expectEqual(
        legacy_pool.idx_unknown,
        legacy_env.getVarTypeByName("known").?,
    );
    try std.testing.expectEqual(
        legacy_pool.idx_number,
        legacy_env.getVarTypeByName("n").?,
    );

    var legacy_checker = type_checker_mod.TypeChecker.init(
        std.testing.allocator,
        legacy_view,
        &legacy_atoms,
        &legacy_env,
    );
    defer legacy_checker.deinit();
    var direct_checker = type_checker_mod.TypeChecker.init(
        std.testing.allocator,
        direct_view,
        &direct_atoms,
        &direct_env,
    );
    defer direct_checker.deinit();
    try std.testing.expectError(error.UnresolvedTypeBinding, legacy_checker.check(legacy_root));
    try std.testing.expectError(error.UnresolvedTypeBinding, direct_checker.check(direct_root));
    try legacy_pool.ensureHealthy();
    try direct_pool.ensureHealthy();
    try legacy_env.ensureHealthy();
    try direct_env.ensureHealthy();
    try std.testing.expectError(error.UnresolvedTypeBinding, legacy_checker.ensureHealthy());
    try std.testing.expectError(error.UnresolvedTypeBinding, direct_checker.ensureHealthy());
    const legacy_diagnostics = legacy_checker.getDiagnostics();
    const direct_diagnostics = direct_checker.getDiagnostics();
    try std.testing.expectEqual(@as(usize, 1), legacy_diagnostics.len);
    try std.testing.expectEqual(legacy_diagnostics.len, direct_diagnostics.len);
    for (legacy_diagnostics, direct_diagnostics) |legacy_diagnostic, direct_diagnostic| {
        try expectSameTypeDiagnostic(
            legacy_diagnostic,
            legacy_view,
            direct_diagnostic,
            direct_view,
        );
    }
    try std.testing.expectEqual(
        type_checker_mod.DiagnosticKind.string_add,
        direct_diagnostics[0].kind,
    );

    var legacy_refused: ?NodeIndex = null;
    for (0..legacy_view.nodeCount()) |raw| {
        const node: NodeIndex = @intCast(raw);
        if (legacy_view.getTag(node) != .binary_op) continue;
        const binary = legacy_view.getBinary(node) orelse continue;
        if (binary.op == .add) {
            legacy_refused = node;
            break;
        }
    }
    var direct_refused: ?NodeIndex = null;
    for (0..direct_view.nodeCount()) |raw| {
        const node: NodeIndex = @intCast(raw);
        if (direct_view.getTag(node) != .binary_op) continue;
        const binary = direct_view.getBinary(node) orelse continue;
        if (binary.op == .add) {
            direct_refused = node;
            break;
        }
    }
    try std.testing.expectEqual(
        null_type_idx,
        legacy_checker.inferTypeWithoutDiagnostics(
            legacy_refused orelse return error.TestUnexpectedResult,
        ),
    );
    try std.testing.expectEqual(
        null_type_idx,
        direct_checker.inferTypeWithoutDiagnostics(
            direct_refused orelse return error.TestUnexpectedResult,
        ),
    );

    var legacy_strict = strict_checker_mod.StrictChecker.init(
        std.testing.allocator,
        legacy_view,
        &legacy_atoms,
        &legacy_env,
        &legacy_checker,
    );
    defer legacy_strict.deinit();
    var direct_strict = strict_checker_mod.StrictChecker.init(
        std.testing.allocator,
        direct_view,
        &direct_atoms,
        &direct_env,
        &direct_checker,
    );
    defer direct_strict.deinit();
    try std.testing.expectError(error.UnresolvedTypeBinding, legacy_strict.check(legacy_root));
    try std.testing.expectError(error.UnresolvedTypeBinding, direct_strict.check(direct_root));
    try std.testing.expectEqual(
        legacy_strict.getDiagnostics().len,
        direct_strict.getDiagnostics().len,
    );
    for (
        legacy_strict.getDiagnostics(),
        direct_strict.getDiagnostics(),
    ) |legacy_diagnostic, direct_diagnostic| {
        try expectSameStrictDiagnostic(
            legacy_diagnostic,
            legacy_view,
            direct_diagnostic,
            direct_view,
        );
    }
}

fn expectOptionalStringEqual(left: ?[]const u8, right: ?[]const u8) !void {
    if (left) |value| {
        try std.testing.expectEqualStrings(value, right orelse return error.TestUnexpectedResult);
    } else {
        try std.testing.expect(right == null);
    }
}

fn expectSameSpecDiagnostic(
    left: contract_types.SpecDiagnostic,
    right: contract_types.SpecDiagnostic,
) !void {
    try std.testing.expectEqual(left.kind, right.kind);
    try std.testing.expectEqualStrings(left.spec_name, right.spec_name);
    try std.testing.expect(std.meta.eql(left.cause, right.cause));
    try expectOptionalStringEqual(left.incompatible_module, right.incompatible_module);
    try expectOptionalStringEqual(left.suggestion, right.suggestion);
    try expectOptionalStringEqual(left.function, right.function);
    try std.testing.expectEqual(left.implicit_default, right.implicit_default);
}

fn expectSameCapsule(
    left: *const function_specs.Capsule,
    right: *const function_specs.Capsule,
) !void {
    try std.testing.expectEqualStrings(left.name, right.name);
    try std.testing.expectEqual(left.line, right.line);
    try std.testing.expectEqual(left.declared.items.len, right.declared.items.len);
    for (left.declared.items, right.declared.items) |left_name, right_name| {
        try std.testing.expectEqualStrings(left_name, right_name);
    }
    try std.testing.expect(std.meta.eql(left.proven, right.proven));
    try std.testing.expectEqual(left.diagnostics.items.len, right.diagnostics.items.len);
    for (left.diagnostics.items, right.diagnostics.items) |left_diagnostic, right_diagnostic| {
        try expectSameSpecDiagnostic(left_diagnostic, right_diagnostic);
    }
    try std.testing.expectEqual(left.effect_declared.items.len, right.effect_declared.items.len);
    for (left.effect_declared.items, right.effect_declared.items) |left_name, right_name| {
        try std.testing.expectEqualStrings(left_name, right_name);
    }
    try std.testing.expect(std.meta.eql(left.inferred_caps, right.inferred_caps));
    try std.testing.expectEqual(
        left.effect_diagnostics.items.len,
        right.effect_diagnostics.items.len,
    );
    for (
        left.effect_diagnostics.items,
        right.effect_diagnostics.items,
    ) |left_diagnostic, right_diagnostic| {
        try expectSameSpecDiagnostic(left_diagnostic, right_diagnostic);
    }
    try std.testing.expectEqual(left.exported, right.exported);
    try std.testing.expectEqual(left.discharged(), right.discharged());
    try std.testing.expectEqual(left.effectDischarged(), right.effectDischarged());
}

fn expectDirectFunctionCapsules(source: []const u8) !void {
    try expectDirectConsumerMatrixCase(source, null, null);

    var prepared = try PreparedSource.init(
        std.testing.allocator,
        source,
        "<u12-capsules>.ts",
        .{},
    );
    defer prepared.deinit();
    var legacy_count = CountingAllocator.init(std.testing.allocator);
    var direct_count = CountingAllocator.init(std.testing.allocator);
    var type_count = CountingAllocator.init(std.testing.allocator);
    var legacy_atoms = AtomTable.init(legacy_count.allocator());
    defer legacy_atoms.deinit();
    var direct_atoms = AtomTable.init(direct_count.allocator());
    defer direct_atoms.deinit();
    var legacy = try JsParser.init(legacy_count.allocator(), prepared.parserInput());
    defer legacy.deinit();
    legacy.setAtomTable(&legacy_atoms);
    var direct = try JsParser.initTyped(
        direct_count.allocator(),
        type_count.allocator(),
        source,
    );
    defer direct.deinit();
    direct.setAtomTable(&direct_atoms);
    const legacy_root = try legacy.parse();
    const direct_root = try direct.parse();
    const legacy_view = parserIrView(&legacy);
    const direct_view = parserIrView(&direct);
    try std.testing.expect(compareRuntime(
        &legacy,
        legacy_root,
        &legacy_atoms,
        &direct,
        direct_root,
        &direct_atoms,
    ) == null);
    try std.testing.expect(legacy_count.sameRuntimeShape(direct_count));

    var legacy_pool = TypePool.init(std.testing.allocator);
    defer legacy_pool.deinit(std.testing.allocator);
    var direct_pool = TypePool.init(std.testing.allocator);
    defer direct_pool.deinit(std.testing.allocator);
    var legacy_env = TypeEnv.init(std.testing.allocator, &legacy_pool);
    defer legacy_env.deinit();
    var direct_env = TypeEnv.init(std.testing.allocator, &direct_pool);
    defer direct_env.deinit();
    module_types.populateModuleTypes(&legacy_env, &legacy_pool, std.testing.allocator);
    abi_types.populateHandlerAbiTypes(&legacy_env, &legacy_pool, std.testing.allocator);
    module_types.populateModuleTypes(&direct_env, &direct_pool, std.testing.allocator);
    abi_types.populateHandlerAbiTypes(&direct_env, &direct_pool, std.testing.allocator);
    try legacy_env.populateSourceTypes(.{ .legacy = prepared.typeMap().? });
    try direct_env.populateSourceTypes(.{ .direct = .{
        .store = &direct.type_store,
        .ir_view = direct_view,
        .atoms = &direct_atoms,
    } });

    var legacy_effects = try effect_inference.buildEffectFacts(
        std.testing.allocator,
        legacy_view,
        &legacy_atoms,
        legacy_root,
        .{},
    );
    defer legacy_effects.deinit(std.testing.allocator);
    var direct_effects = try effect_inference.buildEffectFacts(
        std.testing.allocator,
        direct_view,
        &direct_atoms,
        direct_root,
        .{},
    );
    defer direct_effects.deinit(std.testing.allocator);
    try std.testing.expectEqual(legacy_effects.all().len, direct_effects.all().len);
    try std.testing.expectEqual(@as(usize, 2), legacy_effects.all().len);

    var legacy_capsules = try function_specs.dischargeWithTypeSource(
        std.testing.allocator,
        &legacy_effects,
        .{ .legacy = &legacy_env },
        legacy_view,
    );
    defer legacy_capsules.deinit(std.testing.allocator);
    var direct_capsules = try function_specs.dischargeWithTypeSource(
        std.testing.allocator,
        &direct_effects,
        .{ .direct = &direct_env },
        direct_view,
    );
    defer direct_capsules.deinit(std.testing.allocator);
    try std.testing.expectEqual(
        legacy_capsules.capsules.items.len,
        direct_capsules.capsules.items.len,
    );
    try std.testing.expectEqual(@as(usize, 2), legacy_capsules.capsules.items.len);
    for (
        legacy_capsules.capsules.items,
        direct_capsules.capsules.items,
    ) |*legacy_capsule, *direct_capsule| {
        try expectSameCapsule(legacy_capsule, direct_capsule);
    }

    const legacy_selected = legacy_capsules.byName("helper") orelse
        return error.TestUnexpectedResult;
    const direct_selected = direct_capsules.byName("helper") orelse
        return error.TestUnexpectedResult;
    try expectSameCapsule(legacy_selected, direct_selected);
    try std.testing.expect(legacy_selected == &legacy_capsules.capsules.items[0]);
    try std.testing.expect(direct_selected == &direct_capsules.capsules.items[0]);
    try std.testing.expectEqual(@as(u32, 4), legacy_selected.line);
    try std.testing.expectEqual(@as(usize, 0), legacy_selected.declared.items.len);
    try std.testing.expect(legacy_selected.proven.total);
    try std.testing.expect(!legacy_selected.proven.pure);
    try std.testing.expect(legacy_selected.proven.read_only);
    try std.testing.expect(legacy_selected.proven.deterministic);
    try std.testing.expect(!legacy_selected.discharged());
    try std.testing.expectEqual(@as(usize, 1), legacy_selected.effect_declared.items.len);
    try std.testing.expectEqualStrings("crypto", legacy_selected.effect_declared.items[0]);
    try std.testing.expectEqual(@as(usize, 1), legacy_selected.inferred_caps.count());
    try std.testing.expect(legacy_selected.inferred_caps.contains(.crypto));
    try std.testing.expect(legacy_selected.effectDischarged());

    const legacy_second = &legacy_capsules.capsules.items[1];
    const direct_second = &direct_capsules.capsules.items[1];
    try expectSameCapsule(legacy_second, direct_second);
    try std.testing.expectEqualStrings("helper", legacy_second.name);
    try std.testing.expectEqual(@as(u32, 8), legacy_second.line);
    try std.testing.expectEqual(@as(usize, 0), legacy_second.declared.items.len);
    try std.testing.expect(legacy_second.proven.total);
    try std.testing.expect(legacy_second.proven.pure);
    try std.testing.expect(legacy_second.proven.read_only);
    try std.testing.expect(legacy_second.proven.deterministic);
    try std.testing.expect(!legacy_second.discharged());
    try std.testing.expectEqual(@as(usize, 1), legacy_second.effect_declared.items.len);
    try std.testing.expectEqualStrings("clock", legacy_second.effect_declared.items[0]);
    try std.testing.expectEqual(@as(usize, 0), legacy_second.inferred_caps.count());
    try std.testing.expect(legacy_second.effectDischarged());
}

test "direct function specifications preserve nonempty effects and repeated helper selection" {
    const source =
        \\import { sha256 } from "zttp:crypto";
        \\structural Text = string;
        \\{
        \\  function helper(value: Text): Effects<Text, "crypto"> { return sha256(value); }
        \\  helper("first");
        \\}
        \\{
        \\  function helper(value: Text): Effects<Text, "clock"> { return value; }
        \\  helper("second");
        \\}
        \\
    ;
    try expectDirectFunctionCapsules(source);
}

const ContractConsumerCase = enum {
    simple,
    nested_first,
    outer_first,
    repeated_holes,
    repeated_capsules,
    nested_hole,
    module_arrow,
    nonliteral_effect,
    unknown_capability,
};

fn expectContractConsumerFacts(
    kind: ContractConsumerCase,
    contract: *const contract_types.HandlerContract,
) !void {
    switch (kind) {
        .simple => {
            try std.testing.expectEqual(@as(usize, 0), contract.holes.items.len);
            try std.testing.expectEqual(@as(usize, 0), contract.function_capsules.items.len);
        },
        .nested_first, .outer_first => {
            try std.testing.expect(!contract.declared_specs_implicit);
            try std.testing.expectEqual(@as(usize, 1), contract.declared_specs.items.len);
            try std.testing.expectEqualStrings("pure", contract.declared_specs.items[0]);
            try std.testing.expectEqual(@as(usize, 1), contract.function_capsules.items.len);
            const capsule = contract.function_capsules.items[0];
            try std.testing.expectEqualStrings("wrapper", capsule.function);
            try std.testing.expectEqual(if (kind == .nested_first) @as(u32, 1) else 4, capsule.line);
        },
        .repeated_holes => {
            try std.testing.expectEqual(@as(usize, 2), contract.holes.items.len);
            for (contract.holes.items, 0..) |hole, index| {
                try std.testing.expectEqualStrings("helper", hole.function);
                try std.testing.expectEqualStrings("string", hole.expected_type);
                try std.testing.expectEqual(@as(u32, @intCast(index + 1)), hole.line);
                try std.testing.expectEqual(if (index == 0) @as(u32, 36) else 49, hole.column);
                try std.testing.expectEqual(index, hole.in_scope.items.len);
                if (index == 1) {
                    try std.testing.expectEqualStrings("value", hole.in_scope.items[0].name);
                    try std.testing.expectEqualStrings("string", hole.in_scope.items[0].type_name);
                }
                try std.testing.expect(!hole.budget_declared);
                try std.testing.expectEqual(@as(usize, 0), hole.remaining_budget.items.len);
                try std.testing.expectEqual(@as(usize, 0), hole.undischarged.items.len);
            }
            try std.testing.expectEqual(@as(usize, 2), contract.function_capsules.items.len);
            for (contract.function_capsules.items) |capsule| {
                try std.testing.expectEqual(@as(usize, 0), capsule.declared.items.len);
                try std.testing.expect(!capsule.discharged);
            }
        },
        .repeated_capsules => {
            try std.testing.expectEqual(@as(usize, 2), contract.function_capsules.items.len);
            for (contract.function_capsules.items, 0..) |capsule, index| {
                try std.testing.expectEqualStrings("helper", capsule.function);
                try std.testing.expectEqual(@as(u32, @intCast(index + 1)), capsule.line);
                try std.testing.expectEqual(@as(usize, 1), capsule.declared.items.len);
                try std.testing.expectEqualStrings(if (index == 0) "pure" else "deterministic", capsule.declared.items[0]);
                try std.testing.expect(capsule.proven_total);
                try std.testing.expect(capsule.proven_pure);
                try std.testing.expect(capsule.proven_read_only);
                try std.testing.expect(capsule.proven_deterministic);
                try std.testing.expect(capsule.discharged);
            }
        },
        .nonliteral_effect, .unknown_capability => {
            const expected_kind: contract_types.SpecDiagnostic.Kind = if (kind == .nonliteral_effect)
                .effect_ceiling_not_literal
            else
                .effect_unknown_capability;
            var matches: usize = 0;
            for (contract.spec_diagnostics.items) |diagnostic| {
                if (diagnostic.kind != expected_kind) continue;
                try std.testing.expectEqualStrings(if (kind == .nonliteral_effect) "Effects" else "unpublished-capability", diagnostic.spec_name);
                try std.testing.expectEqual(contract_types.SpecDiagnostic.Severity.err, diagnostic.kind.severity());
                matches += 1;
            }
            try std.testing.expectEqual(@as(usize, 1), matches);
            try std.testing.expectEqual(@as(u32, 1), contract.handler.line);
            try std.testing.expectEqual(@as(u32, 17), contract.handler.column);
        },
        .nested_hole, .module_arrow => {
            try std.testing.expectEqual(@as(usize, 1), contract.function_capsules.items.len);
            try std.testing.expectEqual(@as(usize, 1), contract.function_effect_capsules.items.len);
            try std.testing.expectEqual(@as(usize, 0), contract.function_capsules.items[0].declared.items.len);
            try std.testing.expectEqual(@as(usize, 0), contract.function_effect_capsules.items[0].declared.items.len);
            try std.testing.expectEqual(@as(usize, 1), contract.holes.items.len);
            const hole = contract.holes.items[0];
            try std.testing.expectEqualStrings(if (kind == .nested_hole) "outer" else "helper", hole.function);
            try std.testing.expectEqualStrings(if (kind == .nested_hole) "number" else "unknown", hole.expected_type);
            try std.testing.expectEqual(if (kind == .nested_hole) @as(u32, 2) else 1, hole.line);
            try std.testing.expectEqual(if (kind == .nested_hole) @as(u32, 37) else 43, hole.column);
            try std.testing.expectEqual(if (kind == .nested_hole) @as(usize, 0) else 1, hole.in_scope.items.len);
            if (kind == .module_arrow) {
                try std.testing.expectEqualStrings("value", hole.in_scope.items[0].name);
                try std.testing.expectEqualStrings("string", hole.in_scope.items[0].type_name);
            }
        },
    }
    if (kind == .repeated_holes or kind == .repeated_capsules) {
        try std.testing.expectEqual(@as(usize, 2), contract.function_effect_capsules.items.len);
        for (contract.function_effect_capsules.items) |capsule| {
            try std.testing.expectEqual(@as(usize, 0), capsule.declared.items.len);
            try std.testing.expectEqual(@as(usize, 0), capsule.inferred.items.len);
            try std.testing.expect(!capsule.discharged);
        }
    }
}

fn expectDirectSingleModuleContractParity(
    profile: pipeline_mod.ModuleAnalysisSession.Profile,
    kind: ContractConsumerCase,
    source: []const u8,
) !void {
    var prepared = try PreparedSource.init(
        std.testing.allocator,
        source,
        "<u13-single-module>.ts",
        .{},
    );
    defer prepared.deinit();

    var legacy_count = CountingAllocator.init(std.testing.allocator);
    var direct_count = CountingAllocator.init(std.testing.allocator);
    var type_count = CountingAllocator.init(std.testing.allocator);
    var legacy_atoms = AtomTable.init(legacy_count.allocator());
    defer legacy_atoms.deinit();
    var direct_atoms = AtomTable.init(direct_count.allocator());
    defer direct_atoms.deinit();
    var legacy = try JsParser.init(legacy_count.allocator(), prepared.parserInput());
    defer legacy.deinit();
    legacy.setAtomTable(&legacy_atoms);
    var direct = try JsParser.initTyped(
        direct_count.allocator(),
        type_count.allocator(),
        source,
    );
    defer direct.deinit();
    direct.setAtomTable(&direct_atoms);
    const legacy_root = try legacy.parse();
    const direct_root = try direct.parse();
    const legacy_view = parserIrView(&legacy);
    const direct_view = parserIrView(&direct);
    try std.testing.expect(compareRuntime(
        &legacy,
        legacy_root,
        &legacy_atoms,
        &direct,
        direct_root,
        &direct_atoms,
    ) == null);
    try std.testing.expect(legacy_count.sameRuntimeShape(direct_count));

    const legacy_parsed = pipeline_mod.ParsedModule.fromExisting(
        legacy_view,
        legacy_root,
        &legacy_atoms,
    );
    const direct_parsed = pipeline_mod.ParsedModule.fromTypedExisting(
        direct_view,
        direct_root,
        &direct_atoms,
        &direct.type_store,
    );
    var legacy_session: pipeline_mod.ModuleAnalysisSession = .{};
    var direct_session: pipeline_mod.ModuleAnalysisSession = .{};
    switch (profile) {
        .full => {
            try legacy_session.initFull(std.testing.allocator, legacy_parsed, .{
                .source_types = .{ .legacy = prepared.typeMap().? },
                .strict = false,
            });
            try direct_session.initFull(std.testing.allocator, direct_parsed, .{
                .source_types = .direct,
                .strict = false,
            });
        },
        .sound_extraction => {
            try legacy_session.initSoundExtraction(std.testing.allocator, legacy_parsed, .{
                .source_types = .{ .legacy = prepared.typeMap().? },
                .strict = false,
            });
            try direct_session.initSoundExtraction(std.testing.allocator, direct_parsed, .{
                .source_types = .direct,
                .strict = false,
            });
        },
        .contract_only => return error.TestUnexpectedResult,
    }
    defer legacy_session.deinit();
    defer direct_session.deinit();
    try legacy_session.complete();
    try direct_session.complete();

    const legacy_env = legacy_session.type_env_storage.envPtr() orelse
        return error.TestUnexpectedResult;
    const direct_env = direct_session.type_env_storage.envPtr() orelse
        return error.TestUnexpectedResult;
    try expectExactTypePool(legacy_env.pool, direct_env.pool);
    try std.testing.expectEqual(type_env_mod.SourceTypeMode.legacy, legacy_env.sourceTypeMode().?);
    try std.testing.expectEqual(type_env_mod.SourceTypeMode.direct, direct_env.sourceTypeMode().?);
    try std.testing.expectEqual(
        (try legacy_session.resolvedForReport()).typeErrorCount(),
        (try direct_session.resolvedForReport()).typeErrorCount(),
    );
    try std.testing.expectEqual(
        (try legacy_session.resolvedForReport()).strict_error_count,
        (try direct_session.resolvedForReport()).strict_error_count,
    );

    var legacy_contract = try legacy_session.extractContract("single-module.ts");
    defer legacy_contract.deinit(std.testing.allocator);
    var direct_contract = try direct_session.extractContract("single-module.ts");
    defer direct_contract.deinit(std.testing.allocator);
    const legacy_json = try serializeContractForConsumerTest(
        std.testing.allocator,
        &legacy_contract,
    );
    defer std.testing.allocator.free(legacy_json);
    const direct_json = try serializeContractForConsumerTest(
        std.testing.allocator,
        &direct_contract,
    );
    defer std.testing.allocator.free(direct_json);
    try std.testing.expectEqualStrings(legacy_json, direct_json);
    try std.testing.expect(std.meta.eql(legacy_contract.properties, direct_contract.properties));
    try std.testing.expectEqualDeep(legacy_contract.function_capsules.items, direct_contract.function_capsules.items);
    try std.testing.expectEqualDeep(legacy_contract.function_effect_capsules.items, direct_contract.function_effect_capsules.items);
    try std.testing.expectEqualDeep(legacy_contract.holes.items, direct_contract.holes.items);
    try std.testing.expectEqualDeep(legacy_contract.spec_diagnostics.items, direct_contract.spec_diagnostics.items);
    try expectContractConsumerFacts(kind, &legacy_contract);
    try expectContractConsumerFacts(kind, &direct_contract);
}

test "direct single-module full and sound extraction preserve contract bytes" {
    const fixtures = [_]struct { kind: ContractConsumerCase, source: []const u8 }{
        .{ .kind = .simple, .source = "function handler(req: Request): Response { return Response.text(\"ok\"); }\n" },
        .{ .kind = .nested_first, .source = "function wrapper(): number {\n  function handler(req: Request): Proof<Response, \"pure\"> {\n    return Response.text(\"nested\");\n  }\n  return 1;\n}\nfunction handler(req: Request): Proof<Response, \"deterministic\"> {\n  return Response.text(\"outer\");\n}\n" },
        .{ .kind = .outer_first, .source = "function handler(req: Request): Proof<Response, \"deterministic\"> {\n  return Response.text(\"outer\");\n}\nfunction wrapper(): number {\n  function handler(req: Request): Proof<Response, \"pure\"> {\n    return Response.text(\"nested\");\n  }\n  return 1;\n}\n" },
        .{ .kind = .repeated_holes, .source = "function helper(): number { return hole(); }\nfunction helper(value: string): string { return hole(); }\nfunction handler(req: Request): Response { return Response.text(helper(\"x\")); }\n" },
        .{ .kind = .repeated_capsules, .source = "function helper(): Proof<string, \"pure\"> { return \"a\"; }\nfunction helper(value: string): Proof<string, \"deterministic\"> { return value; }\nfunction handler(req: Request): Response { return Response.text(helper(\"x\")); }\n" },
        .{ .kind = .nested_hole, .source = "function outer(): string {\n  function inner(): number { return hole(); }\n  return \"ok\";\n}\nfunction handler(req: Request): Response { return Response.text(outer()); }\n" },
        .{ .kind = .module_arrow, .source = "const helper = (value: string): string => hole();\nfunction handler(req: Request): Response { return Response.text(helper(\"x\")); }\n" },
        .{ .kind = .nonliteral_effect, .source = "function handler(req: Request): Effects<Response, string> { return Response.text(\"ok\"); }\n" },
        .{ .kind = .unknown_capability, .source = "function handler(req: Request): Effects<Response, \"unpublished-capability\"> { return Response.text(\"ok\"); }\n" },
    };
    const fields = @typeInfo(ContractConsumerCase).@"enum".fields;
    try std.testing.expectEqual(@as(usize, 9), fixtures.len);
    try std.testing.expectEqual(fields.len, fixtures.len);
    var seen: [fields.len]bool = @splat(false);
    for (fixtures) |fixture| {
        const index = @intFromEnum(fixture.kind);
        try std.testing.expect(!seen[index]);
        seen[index] = true;
        try expectDirectSingleModuleContractParity(.full, fixture.kind, fixture.source);
        try expectDirectSingleModuleContractParity(.sound_extraction, fixture.kind, fixture.source);
    }
    for (seen) |present| try std.testing.expect(present);
}

const ExpectedCallbackCeiling = struct {
    has_crypto: bool,
    pure: bool,
    lower_bound: bool,
    effect_discharged: bool,
    line: u32,
    diagnostic: ?contract_types.SpecDiagnostic.Kind,
};

fn expectSameExportEffect(
    legacy: effect_inference.ExportEffect,
    direct: effect_inference.ExportEffect,
) !void {
    switch (legacy) {
        .callable => |legacy_row| switch (direct) {
            .callable => |direct_row| try std.testing.expect(legacy_row.eql(direct_row)),
            else => return error.TestUnexpectedResult,
        },
        .data => |legacy_row| switch (direct) {
            .data => |direct_row| try std.testing.expect(legacy_row.eql(direct_row)),
            else => return error.TestUnexpectedResult,
        },
        .blocked => switch (direct) {
            .blocked => {},
            else => return error.TestUnexpectedResult,
        },
    }
}

fn expectSameEffectFacts(
    legacy: *const effect_inference.EffectFacts,
    direct: *const effect_inference.EffectFacts,
) !void {
    try std.testing.expectEqual(legacy.all().len, direct.all().len);
    for (legacy.all(), direct.all()) |legacy_function, direct_function| {
        try std.testing.expectEqualStrings(legacy_function.name, direct_function.name);
        try std.testing.expectEqual(legacy_function.binding_key, direct_function.binding_key);
        try std.testing.expectEqual(legacy_function.decl_node, direct_function.decl_node);
        try std.testing.expectEqual(legacy_function.body_node, direct_function.body_node);
        try std.testing.expect(legacy_function.row.eql(direct_function.row));
        try std.testing.expect(std.meta.eql(
            legacy_function.direct_caps,
            direct_function.direct_caps,
        ));
        try std.testing.expectEqual(legacy_function.exported, direct_function.exported);
    }
    try std.testing.expectEqualSlices(u32, legacy.callee_starts, direct.callee_starts);
    try std.testing.expectEqualSlices(usize, legacy.callee_storage, direct.callee_storage);
    try std.testing.expectEqualSlices(u32, legacy.value_starts, direct.value_starts);
    try std.testing.expectEqualSlices(usize, legacy.value_storage, direct.value_storage);
    try std.testing.expectEqualSlices(
        bool,
        legacy.reaches_recursion,
        direct.reaches_recursion,
    );
    try std.testing.expectEqual(
        legacy.export_effects.entries.len,
        direct.export_effects.entries.len,
    );
    for (
        legacy.export_effects.entries,
        direct.export_effects.entries,
    ) |legacy_entry, direct_entry| {
        try std.testing.expectEqualStrings(legacy_entry.name, direct_entry.name);
        try expectSameExportEffect(legacy_entry.effect, direct_entry.effect);
    }

    const legacy_contract = try legacy.requireContract();
    const direct_contract = try direct.requireContract();
    try std.testing.expect(std.meta.eql(legacy_contract.summary, direct_contract.summary));
    try std.testing.expectEqual(
        legacy_contract.selected_handler,
        direct_contract.selected_handler,
    );
    try std.testing.expectEqual(
        legacy_contract.first_handler_index,
        direct_contract.first_handler_index,
    );
    try std.testing.expectEqualSlices(
        bool,
        legacy_contract.handler_reachable,
        direct_contract.handler_reachable,
    );
}

fn expectDirectCallbackCeiling(
    source: []const u8,
    expected: ExpectedCallbackCeiling,
) !void {
    var prepared = try PreparedSource.init(
        std.testing.allocator,
        source,
        "<u13-callback>.ts",
        .{},
    );
    defer prepared.deinit();
    var legacy_count = CountingAllocator.init(std.testing.allocator);
    var direct_count = CountingAllocator.init(std.testing.allocator);
    var type_count = CountingAllocator.init(std.testing.allocator);
    var legacy_atoms = AtomTable.init(legacy_count.allocator());
    defer legacy_atoms.deinit();
    var direct_atoms = AtomTable.init(direct_count.allocator());
    defer direct_atoms.deinit();
    var legacy = try JsParser.init(legacy_count.allocator(), prepared.parserInput());
    defer legacy.deinit();
    legacy.setAtomTable(&legacy_atoms);
    var direct = try JsParser.initTyped(
        direct_count.allocator(),
        type_count.allocator(),
        source,
    );
    defer direct.deinit();
    direct.setAtomTable(&direct_atoms);
    const legacy_root = try legacy.parse();
    const direct_root = try direct.parse();
    const legacy_view = parserIrView(&legacy);
    const direct_view = parserIrView(&direct);
    try std.testing.expect(compareRuntime(
        &legacy,
        legacy_root,
        &legacy_atoms,
        &direct,
        direct_root,
        &direct_atoms,
    ) == null);
    try std.testing.expect(legacy_count.sameRuntimeShape(direct_count));

    var legacy_pool = TypePool.init(std.testing.allocator);
    defer legacy_pool.deinit(std.testing.allocator);
    var direct_pool = TypePool.init(std.testing.allocator);
    defer direct_pool.deinit(std.testing.allocator);
    var legacy_env = TypeEnv.init(std.testing.allocator, &legacy_pool);
    defer legacy_env.deinit();
    var direct_env = TypeEnv.init(std.testing.allocator, &direct_pool);
    defer direct_env.deinit();
    module_types.populateModuleTypes(&legacy_env, &legacy_pool, std.testing.allocator);
    abi_types.populateHandlerAbiTypes(&legacy_env, &legacy_pool, std.testing.allocator);
    module_types.populateModuleTypes(&direct_env, &direct_pool, std.testing.allocator);
    abi_types.populateHandlerAbiTypes(&direct_env, &direct_pool, std.testing.allocator);
    try legacy_env.populateSourceTypes(.{ .legacy = prepared.typeMap().? });
    try direct_env.populateSourceTypes(.{ .direct = .{
        .store = &direct.type_store,
        .ir_view = direct_view,
        .atoms = &direct_atoms,
    } });
    try expectExactTypePool(&legacy_pool, &direct_pool);

    const legacy_parsed = pipeline_mod.ParsedModule.fromExisting(
        legacy_view,
        legacy_root,
        &legacy_atoms,
    );
    const direct_parsed = pipeline_mod.ParsedModule.fromTypedExisting(
        direct_view,
        direct_root,
        &direct_atoms,
        &direct.type_store,
    );
    var legacy_module_facts = try pipeline_mod.buildModuleFacts(
        std.testing.allocator,
        legacy_parsed,
        null,
    );
    defer legacy_module_facts.deinit();
    var direct_module_facts = try pipeline_mod.buildModuleFacts(
        std.testing.allocator,
        direct_parsed,
        null,
    );
    defer direct_module_facts.deinit();
    const legacy_handler = handler_verifier_mod.findHandlerFunction(
        legacy_view,
        legacy_root,
    ) orelse return error.TestUnexpectedResult;
    const direct_handler = handler_verifier_mod.findHandlerFunction(
        direct_view,
        direct_root,
    ) orelse return error.TestUnexpectedResult;

    var legacy_effects = try effect_inference.buildEffectFacts(
        std.testing.allocator,
        legacy_view,
        &legacy_atoms,
        legacy_root,
        .{
            .module_facts = &legacy_module_facts,
            .type_source = .{ .legacy = &legacy_env },
            .contract_projection = .{ .complete = .{
                .selected_handler = legacy_handler,
            } },
        },
    );
    defer legacy_effects.deinit(std.testing.allocator);
    var direct_effects = try effect_inference.buildEffectFacts(
        std.testing.allocator,
        direct_view,
        &direct_atoms,
        direct_root,
        .{
            .module_facts = &direct_module_facts,
            .type_source = .{ .direct = &direct_env },
            .contract_projection = .{ .complete = .{
                .selected_handler = direct_handler,
            } },
        },
    );
    defer direct_effects.deinit(std.testing.allocator);
    try expectSameEffectFacts(&legacy_effects, &direct_effects);
    const legacy_row = legacy_effects.lookup("run") orelse return error.TestUnexpectedResult;
    const direct_row = direct_effects.lookup("run") orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.meta.eql(legacy_row, direct_row));
    try std.testing.expectEqual(expected.pure, direct_row.pure);
    try std.testing.expect(direct_row.readOnly());
    try std.testing.expect(direct_row.deterministic);
    try std.testing.expectEqual(expected.lower_bound, direct_row.lower_bound);
    try std.testing.expectEqual(
        if (expected.has_crypto) @as(usize, 1) else 0,
        direct_row.capabilities.count(),
    );
    try std.testing.expectEqual(expected.has_crypto, direct_row.capabilities.contains(.crypto));

    var legacy_capsules = try function_specs.dischargeWithTypeSource(
        std.testing.allocator,
        &legacy_effects,
        .{ .legacy = &legacy_env },
        legacy_view,
    );
    defer legacy_capsules.deinit(std.testing.allocator);
    var direct_capsules = try function_specs.dischargeWithTypeSource(
        std.testing.allocator,
        &direct_effects,
        .{ .direct = &direct_env },
        direct_view,
    );
    defer direct_capsules.deinit(std.testing.allocator);
    const legacy_capsule = legacy_capsules.byName("run") orelse return error.TestUnexpectedResult;
    const direct_capsule = direct_capsules.byName("run") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(
        legacy_capsules.capsules.items.len,
        direct_capsules.capsules.items.len,
    );
    for (
        legacy_capsules.capsules.items,
        direct_capsules.capsules.items,
    ) |*legacy_item, *direct_item| {
        try expectSameCapsule(legacy_item, direct_item);
    }
    try expectSameCapsule(legacy_capsule, direct_capsule);
    try std.testing.expectEqual(expected.line, direct_capsule.line);
    try std.testing.expectEqual(@as(usize, 1), direct_capsule.effect_declared.items.len);
    try std.testing.expectEqualStrings("crypto", direct_capsule.effect_declared.items[0]);
    try std.testing.expectEqual(
        if (expected.has_crypto) @as(usize, 1) else 0,
        direct_capsule.inferred_caps.count(),
    );
    try std.testing.expectEqual(
        expected.effect_discharged,
        direct_capsule.effectDischarged(),
    );
    if (expected.diagnostic) |kind| {
        try std.testing.expectEqual(@as(usize, 1), direct_capsule.effect_diagnostics.items.len);
        try std.testing.expectEqual(kind, direct_capsule.effect_diagnostics.items[0].kind);
        try std.testing.expectEqual(
            if (expected.lower_bound) contract_types.SpecDiagnostic.Severity.err else .warn,
            direct_capsule.effect_diagnostics.items[0].kind.severity(),
        );
        try std.testing.expectEqualStrings(
            if (kind == .effect_over_declared) "crypto" else "Effects",
            direct_capsule.effect_diagnostics.items[0].spec_name,
        );
    } else {
        try std.testing.expectEqual(@as(usize, 0), direct_capsule.effect_diagnostics.items.len);
    }
}

test "direct callback ceilings preserve actual-position compact-gap behavior" {
    try expectDirectCallbackCeiling(
        \\function run<T extends string>(callback: (value: T) => Effects<T, "crypto">, value: T): Effects<T, "crypto"> {
        \\  return callback(value);
        \\}
        \\function handler(req: Request): Response { return Response.text("ok"); }
        \\
    , .{
        .has_crypto = false,
        .pure = true,
        .lower_bound = false,
        .effect_discharged = true,
        .line = 1,
        .diagnostic = .effect_over_declared,
    });
    try expectDirectCallbackCeiling(
        \\function run(skip, callback: (value: string) => Effects<string, "crypto">): Effects<string, "crypto"> {
        \\  return callback("x");
        \\}
        \\function handler(req: Request): Response { return Response.text("ok"); }
        \\
    , .{
        .has_crypto = false,
        .pure = true,
        .lower_bound = true,
        .effect_discharged = false,
        .line = 1,
        .diagnostic = .effect_row_lower_bound,
    });
    try expectDirectCallbackCeiling(
        \\function run(callback): Effects<string, "crypto"> {
        \\  return callback("x");
        \\}
        \\function handler(req: Request): Response { return Response.text("ok"); }
        \\
    , .{
        .has_crypto = false,
        .pure = true,
        .lower_bound = true,
        .effect_discharged = false,
        .line = 1,
        .diagnostic = .effect_row_lower_bound,
    });
    try expectDirectCallbackCeiling(
        \\structural CryptoValue = Effects<string, "crypto">;
        \\
        \\function run<T extends string>(callback: (value: T) => CryptoValue, value: T): Effects<string, "crypto"> {
        \\  return callback(value);
        \\}
        \\
        \\function handler(req: Request): Response {
        \\  return Response.text("ok");
        \\}
        \\
    , .{
        .has_crypto = true,
        .pure = false,
        .lower_bound = false,
        .effect_discharged = true,
        .line = 3,
        .diagnostic = null,
    });
}

test "admission header fallback preserves grouped and raw arrow type construction" {
    const cases = [_][]const u8{
        "const result = flag ? <T>(value) /* gap */ : (x) => x;",
        "const result = <T>(value /* ( */) => value;",
        "const result = (value /* ( */) => value;",
    };
    try std.testing.expectEqual(@as(usize, 3), cases.len);
    for (cases) |source| {
        var prepared = try PreparedSource.init(std.testing.allocator, source, "header-fallback.ts", .{});
        defer prepared.deinit();
        var legacy_atoms = AtomTable.init(std.testing.allocator);
        defer legacy_atoms.deinit();
        var direct_atoms = AtomTable.init(std.testing.allocator);
        defer direct_atoms.deinit();
        var legacy = try JsParser.init(std.testing.allocator, prepared.parserInput());
        defer legacy.deinit();
        legacy.setAtomTable(&legacy_atoms);
        const legacy_root = try legacy.parse();
        var direct = try JsParser.initAdmission(std.testing.allocator, std.testing.allocator, source, .compile);
        defer direct.deinit();
        direct.setAtomTable(&direct_atoms);
        const direct_root = switch (try direct.parseAdmission()) {
            .accepted => |root| root,
            else => return error.TestUnexpectedResult,
        };
        try std.testing.expect(compareRuntime(&legacy, legacy_root, &legacy_atoms, &direct, direct_root, &direct_atoms) == null);
        var legacy_pool = TypePool.init(std.testing.allocator);
        defer legacy_pool.deinit(std.testing.allocator);
        var direct_pool = TypePool.init(std.testing.allocator);
        defer direct_pool.deinit(std.testing.allocator);
        var legacy_env = TypeEnv.init(std.testing.allocator, &legacy_pool);
        defer legacy_env.deinit();
        var direct_env = TypeEnv.init(std.testing.allocator, &direct_pool);
        defer direct_env.deinit();
        try legacy_env.populateSourceTypes(.{ .legacy = prepared.typeMap().? });
        try direct_env.populateSourceTypes(.{ .direct = .{
            .store = &direct.type_store,
            .ir_view = parserIrView(&direct),
            .atoms = &direct_atoms,
        } });
        try expectExactTypePool(&legacy_pool, &direct_pool);
        try direct.type_store.validateRuntimeOwners(std.testing.allocator, parserIrView(&direct));
        if (std.mem.indexOf(u8, source, "flag ?") != null) {
            try std.testing.expectEqual(@as(usize, 1), direct.type_store.erased_type_prefixes.items.len);
        }
    }
}
