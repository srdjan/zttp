//! The type parser: parse a type value, a function return, or a declaration into the type syntax store.

const std = @import("std");
const ir = @import("ir.zig");
const token_mod = @import("token.zig");
const BindingRef = ir.BindingRef;
const Token = token_mod.Token;
const store_mod = @import("type_syntax_store.zig");
const Child = store_mod.Child;
const Span = store_mod.Span;
const TypeValue = store_mod.TypeValue;
const ReturnSyntax = store_mod.ReturnSyntax;
const Store = store_mod.Store;
const scan_mod = @import("type_syntax_scan.zig");
const Cursor = scan_mod.Cursor;
const skipTypeWhitespace = scan_mod.skipTypeWhitespace;
const looksLikeTypeStart = scan_mod.looksLikeTypeStart;
const tokenAtOffset = scan_mod.tokenAtOffset;
const scanAdmissionEnd = scan_mod.scanAdmissionEnd;
const trimWhitespaceEnd = scan_mod.trimWhitespaceEnd;
const advanceCursorTo = scan_mod.advanceCursorTo;
const containsOnlyTypeWhitespace = scan_mod.containsOnlyTypeWhitespace;
const isTypeWhitespace = scan_mod.isTypeWhitespace;
const LegacyReturnKind = store_mod.LegacyReturnKind;
const Annotation = store_mod.Annotation;
const SemanticFragment = store_mod.SemanticFragment;
const DeclarationKind = store_mod.DeclarationKind;
const scanTypeQuoted = scan_mod.scanTypeQuoted;
const Range = store_mod.Range;
const RecognizedGenericParameter = store_mod.RecognizedGenericParameter;
const ProjectedGenericParameter = store_mod.ProjectedGenericParameter;
const tokenIsDeclarationName = scan_mod.tokenIsDeclarationName;
const PendingGenericOwner = store_mod.PendingGenericOwner;
const Declaration = store_mod.Declaration;
const tokenSpan = scan_mod.tokenSpan;
const scanBalancedGenericList = scan_mod.scanBalancedGenericList;
const isPrivateGenericListEligible = scan_mod.isPrivateGenericListEligible;
const DeclarationBody = store_mod.DeclarationBody;
const scanDeclarationEnd = scan_mod.scanDeclarationEnd;
const isScalarNominalBase = scan_mod.isScalarNominalBase;
const Field = store_mod.Field;
const Parameter = store_mod.Parameter;
const TemplatePart = store_mod.TemplatePart;
const NodeTag = store_mod.NodeTag;
const Node = store_mod.Node;
const Primitive = store_mod.Primitive;
const support_mod = @import("type_syntax_support.zig");
const TestRuntime = support_mod.TestRuntime;
const rangesOverlap = store_mod.rangesOverlap;
const seedNumberAnnotation = support_mod.seedNumberAnnotation;
const validateAfterAllocationFailure = support_mod.validateAfterAllocationFailure;

pub const Failure = union(enum) {
    missing_type: Token,
    unmatched_parenthesis: Token,
    nesting_too_deep: Token,
    unsupported_suffix: Token,
};

pub const ParsedType = struct {
    root: Child,
    semantic_span: Span,
    raw_span: Span,
};

pub const TypeParseOutcome = union(enum) {
    parsed: ParsedType,
    failure: Failure,
    excluded: ExcludedType,
};

pub const TypeValueOutcome = union(enum) {
    parsed: TypeValue,
    failure: Failure,
    excluded: ExcludedType,
};

pub const AdmittedTypeInput = struct {
    raw_span: Span,
    admission_end: u32,
};

pub const AdmittedTypeValueOutcome = union(enum) {
    parsed: TypeValue,
    excluded: ExcludedType,
};

pub const ReturnSyntaxOutcome = union(enum) {
    parsed: ReturnSyntax,
    failure: Failure,
    excluded: ExcludedType,
};

pub const Exclusion = union(enum) {
    implementation_budget: Span,
    unsupported_syntax: Span,
    malformed_syntax: Span,
};

pub const ExcludedType = struct {
    reason: Exclusion,
    raw_span: Span,
    admission_end: u32,
};

/// Legacy source admission rejects the next ordinary delimiter at this depth.
pub const max_type_depth: u16 = 512;

/// The iterative parser declines syntax that exceeds this private frame budget.
pub const max_parser_frames: usize = 4096;

/// The raw scanner declines syntax that exceeds this private template budget.
pub const max_template_levels: usize = 512;

pub fn parseTypeValueAndStore(
    store: *Store,
    raw_start_offset: u32,
    cursor: *Cursor,
) !TypeValueOutcome {
    const checkpoint = store.checkpoint();
    errdefer store.rollback(checkpoint);

    const source = store.source;
    const raw_start = skipTypeWhitespace(source, raw_start_offset);
    if (!looksLikeTypeStart(source, raw_start)) {
        if (@as(usize, raw_start) >= source.len or source[raw_start] != '/' or
            @as(usize, raw_start) + 1 >= source.len or
            (source[raw_start + 1] != '/' and source[raw_start + 1] != '*'))
        {
            return .{ .failure = .{ .missing_type = tokenAtOffset(source, raw_start) } };
        }
        const end = @min(raw_start +| 1, @as(u32, @intCast(source.len)));
        return .{ .excluded = .{
            .reason = .{ .unsupported_syntax = .{ .start = raw_start, .end = end } },
            .raw_span = .{ .start = raw_start, .end = end },
            .admission_end = raw_start,
        } };
    }

    var scanned = cursor.*;
    const scan = scanAdmissionEnd(source, raw_start);
    const admission_end = switch (scan) {
        .end => |end| end,
        .nesting_too_deep => |offset| return .{ .failure = .{
            .nesting_too_deep = tokenAtOffset(source, offset),
        } },
        .unmatched_parenthesis => |offset| return .{ .failure = .{
            .unmatched_parenthesis = tokenAtOffset(source, offset),
        } },
        .malformed => |span| return .{ .excluded = .{
            .reason = .{ .malformed_syntax = span },
            .raw_span = .{ .start = raw_start, .end = trimWhitespaceEnd(source, raw_start, span.end) },
            .admission_end = span.end,
        } },
        .implementation_budget => |offset| return .{ .excluded = .{
            .reason = .{ .implementation_budget = .{ .start = offset, .end = offset } },
            .raw_span = .{ .start = raw_start, .end = offset },
            .admission_end = offset,
        } },
    };
    advanceCursorTo(&scanned, admission_end);
    const raw_end = trimWhitespaceEnd(source, raw_start, admission_end);
    var parser = SyntaxParser.init(store, source, raw_start, raw_end);
    defer parser.deinit();
    const parsed = parser.parse() catch |err| switch (err) {
        error.TypeSyntaxFrameBudgetExceeded, error.UnsupportedTypeSyntax => {
            store.rollback(checkpoint);
            const span: Span = parser.exclusion_span orelse .{
                .start = parser.pos,
                .end = parser.pos,
            };
            return .{ .excluded = .{
                .reason = switch (err) {
                    error.TypeSyntaxFrameBudgetExceeded => .{ .implementation_budget = span },
                    error.UnsupportedTypeSyntax => .{ .unsupported_syntax = span },
                    else => return err,
                },
                .raw_span = .{ .start = raw_start, .end = raw_end },
                .admission_end = admission_end,
            } };
        },
        else => return err,
    };
    try store.validateParsed(parsed.child, .{ .start = raw_start, .end = raw_end });
    const value: TypeValue = .{
        .root = parsed.child,
        .node_range = .{
            .start = @intCast(checkpoint.nodes),
            .count = @intCast(store.nodes.items.len - checkpoint.nodes),
        },
        .raw_span = .{ .start = raw_start, .end = raw_end },
        .admission_end = admission_end,
        .semantic_prefix_end = parsed.end,
    };
    try store.validateTypeValue(value);
    cursor.* = scanned;
    return .{ .parsed = value };
}

pub fn parseAdmittedTypeValue(store: *Store, raw_span: Span) !TypeValue {
    return switch (try parseAdmittedTypeValueOutcome(store, .{
        .raw_span = raw_span,
        .admission_end = raw_span.end,
    })) {
        .parsed => |value| value,
        .excluded => |excluded| switch (excluded.reason) {
            .implementation_budget => error.TypeSyntaxFrameBudgetExceeded,
            .unsupported_syntax, .malformed_syntax => error.UnsupportedTypeSyntax,
        },
    };
}

pub fn parseAdmittedTypeValueOutcome(
    store: *Store,
    input: AdmittedTypeInput,
) !AdmittedTypeValueOutcome {
    const checkpoint = store.checkpoint();
    errdefer store.rollback(checkpoint);
    try validateAdmittedTypeInput(store, input);
    var parser = SyntaxParser.init(
        store,
        store.source,
        input.raw_span.start,
        input.raw_span.end,
    );
    defer parser.deinit();
    const parsed = parser.parse() catch |err| switch (err) {
        error.TypeSyntaxFrameBudgetExceeded, error.UnsupportedTypeSyntax => {
            store.rollback(checkpoint);
            const span: Span = parser.exclusion_span orelse .{
                .start = parser.pos,
                .end = parser.pos,
            };
            return .{ .excluded = .{
                .reason = switch (err) {
                    error.TypeSyntaxFrameBudgetExceeded => .{ .implementation_budget = span },
                    error.UnsupportedTypeSyntax => .{ .unsupported_syntax = span },
                    else => unreachable,
                },
                .raw_span = input.raw_span,
                .admission_end = input.admission_end,
            } };
        },
        else => return err,
    };
    try store.validateParsed(parsed.child, input.raw_span);
    const value: TypeValue = .{
        .root = parsed.child,
        .node_range = .{
            .start = @intCast(checkpoint.nodes),
            .count = @intCast(store.nodes.items.len - checkpoint.nodes),
        },
        .raw_span = input.raw_span,
        .admission_end = input.admission_end,
        .semantic_prefix_end = parsed.end,
    };
    try store.validateTypeValue(value);
    return .{ .parsed = value };
}

fn validateAdmittedTypeInput(store: *const Store, input: AdmittedTypeInput) !void {
    try store.validateSpan(input.raw_span);
    if (input.admission_end < input.raw_span.end or
        @as(usize, input.admission_end) > store.source.len or
        !containsOnlyTypeWhitespace(store.source, input.raw_span.end, input.admission_end))
    {
        return error.InvalidTypeSpan;
    }
}

const PredicateHeader = struct {
    target_span: Span,
    narrowed_span: Span,
};

pub fn predicateHeader(source: []const u8, raw_span: Span) ?PredicateHeader {
    var pos: usize = raw_span.start;
    const end: usize = raw_span.end;
    if (pos >= end or !isIdentifierStart(source[pos])) return null;
    const target_start = pos;
    pos += 1;
    while (pos < end and isIdentifierContinue(source[pos])) pos += 1;
    const target_end = pos;
    const before_is = pos;
    while (pos < end and isTypeWhitespace(source[pos])) pos += 1;
    if (pos == before_is or pos + 2 > end or !std.mem.eql(u8, source[pos..][0..2], "is")) {
        return null;
    }
    if (pos + 2 < end and isIdentifierContinue(source[pos + 2])) return null;
    pos += 2;
    const after_is = pos;
    while (pos < end and isTypeWhitespace(source[pos])) pos += 1;
    if (pos == after_is) return null;
    const narrowed_end = trimWhitespaceEnd(source, @intCast(pos), raw_span.end);
    return .{
        .target_span = .{ .start = @intCast(target_start), .end = @intCast(target_end) },
        .narrowed_span = if (pos == narrowed_end)
            .{ .start = @intCast(after_is), .end = raw_span.end }
        else
            .{ .start = @intCast(pos), .end = narrowed_end },
    };
}

pub fn hasLegacyGuardFacet(source: []const u8, raw_span: Span) bool {
    return std.mem.indexOf(u8, raw_span.text(source), " is ") != null;
}

pub fn parseFunctionReturnAndStore(
    store: *Store,
    raw_start_offset: u32,
    cursor: *Cursor,
) !ReturnSyntaxOutcome {
    const checkpoint = store.checkpoint();
    var success = false;
    defer if (!success) store.rollback(checkpoint);

    const source = store.source;
    const raw_start = skipTypeWhitespace(source, raw_start_offset);
    if (!looksLikeTypeStart(source, raw_start)) {
        return .{ .failure = .{ .missing_type = tokenAtOffset(source, raw_start) } };
    }
    const admission_end = switch (scanAdmissionEnd(source, raw_start)) {
        .end => |end| end,
        .nesting_too_deep => |offset| return .{ .failure = .{
            .nesting_too_deep = tokenAtOffset(source, offset),
        } },
        .unmatched_parenthesis => |offset| return .{ .failure = .{
            .unmatched_parenthesis = tokenAtOffset(source, offset),
        } },
        .malformed => |span| return .{ .excluded = .{
            .reason = .{ .malformed_syntax = span },
            .raw_span = .{ .start = raw_start, .end = span.end },
            .admission_end = span.end,
        } },
        .implementation_budget => |offset| return .{ .excluded = .{
            .reason = .{ .implementation_budget = .{ .start = offset, .end = offset } },
            .raw_span = .{ .start = raw_start, .end = offset },
            .admission_end = offset,
        } },
    };
    var local_cursor = cursor.*;
    advanceCursorTo(&local_cursor, admission_end);
    const outcome = try parseAdmittedFunctionReturnAndStore(store, .{
        .raw_span = .{ .start = raw_start, .end = admission_end },
        .admission_end = admission_end,
    });
    switch (outcome) {
        .parsed => {
            cursor.* = local_cursor;
            success = true;
        },
        .failure, .excluded => {},
    }
    return outcome;
}

pub fn parseAdmittedFunctionReturnAndStore(
    store: *Store,
    input: AdmittedTypeInput,
) !ReturnSyntaxOutcome {
    const checkpoint = store.checkpoint();
    var success = false;
    defer if (!success) store.rollback(checkpoint);
    try validateAdmittedTypeInput(store, input);
    if (input.raw_span.end != input.admission_end) return error.InvalidTypeSpan;

    const source = store.source;
    const legacy_return_kind: LegacyReturnKind = if (hasLegacyGuardFacet(source, input.raw_span))
        .type_guard
    else
        .ordinary;

    var result: ReturnSyntax = undefined;
    if (predicateHeader(source, input.raw_span)) |header| {
        const narrowed = switch (try parseAdmittedTypeValueOutcome(
            store,
            .{
                .raw_span = header.narrowed_span,
                .admission_end = input.admission_end,
            },
        )) {
            .parsed => |value| value,
            .excluded => |excluded| return .{ .excluded = excluded },
        };
        const compatibility: ?TypeValue = if (legacy_return_kind == .ordinary)
            switch (try parseAdmittedTypeValueOutcome(store, input)) {
                .parsed => |value| value,
                .excluded => |excluded| return .{ .excluded = excluded },
            }
        else
            null;
        result = .{
            .raw_span = input.raw_span,
            .legacy_return_kind = legacy_return_kind,
            .structure = .{ .predicate = .{
                .target_span = header.target_span,
                .target = .unresolved,
                .narrowed = narrowed,
            } },
            .legacy_ordinary_prefix = compatibility,
        };
    } else {
        const value = switch (try parseAdmittedTypeValueOutcome(store, input)) {
            .parsed => |parsed| parsed,
            .excluded => |excluded| return .{ .excluded = excluded },
        };
        result = .{
            .raw_span = input.raw_span,
            .legacy_return_kind = legacy_return_kind,
            .structure = .{ .value = value },
            .legacy_ordinary_prefix = null,
        };
    }
    try store.validateReturnSyntax(result);
    success = true;
    return .{ .parsed = result };
}

/// Parse and publish one admitted type annotation. The runtime parser calls
/// this only through its private typed initializer.
pub fn parseAndStore(
    store: *Store,
    binding: BindingRef,
    source: []const u8,
    after_colon: u32,
    cursor: *Cursor,
) !TypeParseOutcome {
    if (source.ptr != store.source.ptr or source.len != store.source.len) {
        return error.InvalidTypeSource;
    }
    const checkpoint = store.checkpoint();
    errdefer store.rollback(checkpoint);
    var local_cursor = cursor.*;
    const outcome = try parseTypeValueAndStore(store, after_colon, &local_cursor);
    const value = switch (outcome) {
        .parsed => |parsed| parsed,
        .failure => |failure| return .{ .failure = failure },
        .excluded => |excluded| return .{ .excluded = excluded },
    };
    try appendAnnotationValue(store, binding, value);
    cursor.* = local_cursor;
    return .{ .parsed = parsedTypeFromValue(value) };
}

pub fn parseAdmittedAnnotationAndStore(
    store: *Store,
    binding: BindingRef,
    input: AdmittedTypeInput,
) !AdmittedTypeValueOutcome {
    const checkpoint = store.checkpoint();
    var published = false;
    defer if (!published) store.rollback(checkpoint);
    const outcome = try parseAdmittedTypeValueOutcome(store, input);
    const value = switch (outcome) {
        .parsed => |parsed| parsed,
        .excluded => return outcome,
    };
    try appendAnnotationValue(store, binding, value);
    published = true;
    return .{ .parsed = value };
}

fn appendAnnotationValue(store: *Store, binding: BindingRef, value: TypeValue) !void {
    const annotation: Annotation = .{
        .binding = binding,
        .root = value.root,
        .node_range = value.node_range,
        .raw_span = value.raw_span,
        .admission_end = value.admission_end,
        .semantic_prefix_end = value.semantic_prefix_end,
    };
    try store.validateAnnotation(annotation);
    try store.appendAnnotation(annotation);
}

fn parsedTypeFromValue(value: TypeValue) ParsedType {
    return .{
        .root = value.root,
        .semantic_span = .{ .start = value.raw_span.start, .end = value.semantic_prefix_end },
        .raw_span = value.raw_span,
    };
}

/// Parse one already-admitted generic fragment without ordinary annotation
/// admission. The caller owns the raw split and its legacy projection rules.
pub fn parseSemanticFragmentAndStore(store: *Store, raw_span: Span) !u32 {
    const checkpoint = store.checkpoint();
    errdefer store.rollback(checkpoint);
    try store.validateSpan(raw_span);
    var parser = SyntaxParser.init(store, store.source, raw_span.start, raw_span.end);
    defer parser.deinit();
    const parsed = try parser.parse();
    const fragment: SemanticFragment = .{
        .raw_span = raw_span,
        .root = parsed.child,
        .node_range = .{
            .start = @intCast(checkpoint.nodes),
            .count = @intCast(store.nodes.items.len - checkpoint.nodes),
        },
        .semantic_prefix_end = parsed.end,
    };
    try store.validateSemanticFragment(fragment);
    const index = std.math.cast(u32, store.semantic_fragments.items.len) orelse
        return error.TooManyTypeItems;
    try store.semantic_fragments.append(store.allocator, fragment);
    return index;
}

pub const DeclarationParseOutcome = union(enum) {
    parsed: Span,
    excluded: struct {
        reason: enum { unsupported_syntax, implementation_budget, nominal_base_not_scalar },
        raw_span: Span,
        admission_end: u32,
        generic_list_span: ?Span = null,
    },
    not_declaration,
};

pub const AdmittedDeclarationOptions = struct {
    keyword: Token,
    export_span: ?Span,
    kind: DeclarationKind,
    authored_scope: u16,
    generic_list: ?Span = null,
    body: ?AdmittedTypeInput,
    raw_header_end: ?u32 = null,
};

pub fn appendAuthoredGenericParameters(store: *Store, list_span: Span) !void {
    const body_start = list_span.start + 1;
    const body_end = list_span.end - 1;
    if (trimSpan(store.source, .{ .start = body_start, .end = body_end }).start ==
        trimSpan(store.source, .{ .start = body_start, .end = body_end }).end)
    {
        return;
    }

    var angle_depth: u32 = 0;
    var paren_depth: u32 = 0;
    var bracket_depth: u32 = 0;
    var brace_depth: u32 = 0;
    var piece_start = body_start;
    var pos: usize = body_start;
    while (pos <= body_end) {
        const at_end = pos == body_end;
        if (at_end) {
            try appendAuthoredGenericParameter(store, .{
                .start = piece_start,
                .end = body_end,
            });
            break;
        }
        const byte = store.source[pos];
        if (byte == '"' or byte == '\'' or byte == '`') {
            switch (scanTypeQuoted(store.source, pos, byte)) {
                .end => |end| pos = @min(end, @as(usize, body_end)),
                else => pos = body_end,
            }
            continue;
        }
        if (byte == '/' and pos + 1 < body_end) {
            if (store.source[pos + 1] == '/') {
                pos += 2;
                while (pos < body_end and store.source[pos] != '\n') pos += 1;
                continue;
            }
            if (store.source[pos + 1] == '*') {
                pos += 2;
                while (pos + 1 < body_end and !(store.source[pos] == '*' and store.source[pos + 1] == '/')) pos += 1;
                pos = @min(pos + 2, @as(usize, body_end));
                continue;
            }
        }
        const outside_groups = paren_depth == 0 and bracket_depth == 0 and brace_depth == 0;
        switch (byte) {
            '<' => if (outside_groups) {
                angle_depth += 1;
            },
            '>' => if (outside_groups and (pos == 0 or store.source[pos - 1] != '=')) {
                if (angle_depth > 0) angle_depth -= 1;
            },
            '(' => paren_depth += 1,
            ')' => if (paren_depth > 0) {
                paren_depth -= 1;
            },
            '[' => bracket_depth += 1,
            ']' => if (bracket_depth > 0) {
                bracket_depth -= 1;
            },
            '{' => brace_depth += 1,
            '}' => if (brace_depth > 0) {
                brace_depth -= 1;
            },
            else => {},
        }
        if (byte == ',' and angle_depth == 0 and paren_depth == 0 and
            bracket_depth == 0 and brace_depth == 0)
        {
            try appendAuthoredGenericParameter(store, .{
                .start = piece_start,
                .end = @intCast(pos),
            });
            piece_start = @intCast(pos + 1);
        }
        pos += 1;
    }
}

fn appendAuthoredGenericParameter(store: *Store, raw_span: Span) !void {
    const trimmed_span = trimSpan(store.source, raw_span);
    try store.generic_parameters.append(store.allocator, .{
        .raw_span = raw_span,
        .trimmed_span = trimmed_span,
        .recognized = recognizeAuthoredGenericParameter(store.source, trimmed_span),
    });
}

pub fn appendAuthoredCallArguments(store: *Store, list_span: Span) !void {
    const body_start = list_span.start + 1;
    const body_end = list_span.end - 1;
    const body = trimSpan(store.source, .{ .start = body_start, .end = body_end });
    if (body.start == body.end) return;

    var angle_depth: u32 = 0;
    var paren_depth: u32 = 0;
    var bracket_depth: u32 = 0;
    var brace_depth: u32 = 0;
    var piece_start = body_start;
    var pos: usize = body_start;
    while (pos <= body_end) {
        if (pos == body_end) {
            try store.authored_call_arguments.append(store.allocator, .{
                .full_span = .{ .start = piece_start, .end = body_end },
            });
            break;
        }
        const byte = store.source[pos];
        if (byte == '"' or byte == '\'' or byte == '`') {
            switch (scanTypeQuoted(store.source, pos, byte)) {
                .end => |end| pos = @min(end, @as(usize, body_end)),
                else => pos = body_end,
            }
            continue;
        }
        if (byte == '/' and pos + 1 < body_end) {
            if (store.source[pos + 1] == '/') {
                pos += 2;
                while (pos < body_end and store.source[pos] != '\n') pos += 1;
                continue;
            }
            if (store.source[pos + 1] == '*') {
                pos += 2;
                while (pos + 1 < body_end and !(store.source[pos] == '*' and store.source[pos + 1] == '/')) pos += 1;
                pos = @min(pos + 2, @as(usize, body_end));
                continue;
            }
        }
        const outside_groups = paren_depth == 0 and bracket_depth == 0 and brace_depth == 0;
        switch (byte) {
            '<' => if (outside_groups) {
                angle_depth += 1;
            },
            '>' => if (outside_groups and (pos == 0 or store.source[pos - 1] != '=')) {
                if (angle_depth > 0) angle_depth -= 1;
            },
            '(' => paren_depth += 1,
            ')' => {
                if (paren_depth > 0) paren_depth -= 1;
            },
            '[' => bracket_depth += 1,
            ']' => {
                if (bracket_depth > 0) bracket_depth -= 1;
            },
            '{' => brace_depth += 1,
            '}' => {
                if (brace_depth > 0) brace_depth -= 1;
            },
            else => {},
        }
        if (byte == ',' and angle_depth == 0 and paren_depth == 0 and
            bracket_depth == 0 and brace_depth == 0)
        {
            try store.authored_call_arguments.append(store.allocator, .{
                .full_span = .{ .start = piece_start, .end = @intCast(pos) },
            });
            piece_start = @intCast(pos + 1);
        }
        pos += 1;
    }
}

pub fn appendProjectedCallFragments(store: *Store, projected_span: Span) !void {
    const body = projectedListBody(store.source, projected_span);
    if (body.start == body.end) return;
    var angle_depth: u32 = 0;
    var bracket_depth: u32 = 0;
    var piece_start = body.start;
    var pos: usize = body.start;
    var count: usize = 0;
    while (pos <= body.end) : (pos += 1) {
        const at_end = pos == body.end;
        const byte = if (at_end) ',' else store.source[pos];
        switch (byte) {
            '<' => angle_depth += 1,
            '>' => {
                if (angle_depth > 0) angle_depth -= 1;
            },
            '{', '[', '(' => bracket_depth += 1,
            '}', ']', ')' => {
                if (bracket_depth > 0) bracket_depth -= 1;
            },
            else => {},
        }
        if (byte != ',' or angle_depth != 0 or bracket_depth != 0) continue;
        const raw_span = trimSpan(store.source, .{ .start = piece_start, .end = @intCast(pos) });
        piece_start = @intCast(pos + 1);
        if (raw_span.start == raw_span.end) continue;
        if (count == 8) break;
        _ = try parseSemanticFragmentAndStore(store, raw_span);
        count += 1;
    }
}

const ProjectedParameterRanges = struct {
    parameters: Range,
    fragments: Range,
};

pub fn appendProjectedParametersWithBounds(
    store: *Store,
    body: Span,
    with_bounds: bool,
) !ProjectedParameterRanges {
    const parameter_start_index = store.projected_generic_parameters.items.len;
    const parameter_start = std.math.cast(u32, parameter_start_index) orelse
        return error.TooManyTypeItems;
    const fragment_start_index = store.semantic_fragments.items.len;
    const fragment_start = std.math.cast(u32, fragment_start_index) orelse
        return error.TooManyTypeItems;
    try appendProjectedGenericParametersFromSpan(store, body);
    const parameter_end = store.projected_generic_parameters.items.len;
    if (with_bounds) {
        const start = parameter_start_index;
        var compact_count: usize = 0;
        for (store.projected_generic_parameters.items[start..parameter_end]) |parameter| {
            if (parameter.name_span.start != parameter.name_span.end) compact_count += 1;
        }
        var index = start;
        while (index < parameter_end) : (index += 1) {
            if (index - start >= compact_count) break;
            const bound_span = store.projected_generic_parameters.items[index].bound_span orelse
                continue;
            const fragment_index = try parseSemanticFragmentAndStore(store, bound_span);
            store.projected_generic_parameters.items[index].bound_fragment = fragment_index;
        }
    }
    return .{
        .parameters = .{
            .start = parameter_start,
            .count = @intCast(parameter_end - parameter_start_index),
        },
        .fragments = .{
            .start = fragment_start,
            .count = @intCast(store.semantic_fragments.items.len - fragment_start_index),
        },
    };
}

pub fn projectedListBody(source: []const u8, recorded_span: Span) Span {
    var body = trimSpan(source, recorded_span);
    if (body.end - body.start >= 2 and source[body.start] == '<' and source[body.end - 1] == '>') {
        body = trimSpan(source, .{ .start = body.start + 1, .end = body.end - 1 });
    }
    return body;
}

fn appendProjectedGenericParametersFromSpan(store: *Store, body: Span) !void {
    if (body.start == body.end) return;
    var angle_depth: u32 = 0;
    var bracket_depth: u32 = 0;
    var piece_start = body.start;
    var pos: usize = body.start;
    var count: usize = 0;
    while (pos <= body.end) : (pos += 1) {
        const at_end = pos == body.end;
        const byte = if (at_end) ',' else store.source[pos];
        switch (byte) {
            '<' => angle_depth += 1,
            '>' => if (angle_depth > 0) {
                angle_depth -= 1;
            },
            '{', '[', '(' => bracket_depth += 1,
            '}', ']', ')' => if (bracket_depth > 0) {
                bracket_depth -= 1;
            },
            else => {},
        }
        if (byte != ',' or angle_depth != 0 or bracket_depth != 0) continue;
        const raw_span = trimSpan(store.source, .{ .start = piece_start, .end = @intCast(pos) });
        piece_start = @intCast(pos + 1);
        if (raw_span.start == raw_span.end) continue;
        if (count == 8) break;
        try store.projected_generic_parameters.append(
            store.allocator,
            projectGenericParameter(store.source, raw_span),
        );
        count += 1;
    }
}

fn recognizeAuthoredGenericParameter(
    source: []const u8,
    span: Span,
) ?RecognizedGenericParameter {
    if (span.start == span.end) return null;
    const projected = projectGenericParameter(source, span);
    var recognized: RecognizedGenericParameter = .{
        .name_span = projected.name_span,
        .extends_span = null,
        .constraint_span = null,
        .equals_span = null,
        .default_span = null,
    };
    var offset = projected.name_span.end;
    offset = skipWhitespaceWithin(source, offset, span.end);
    if (wordAt(source, offset, span.end, "extends")) {
        const extends_end = offset + @as(u32, "extends".len);
        recognized.extends_span = .{ .start = offset, .end = extends_end };
        offset = skipWhitespaceWithin(source, extends_end, span.end);
        const equals = findTopLevelEquals(source, offset, span.end);
        const constraint_end = equals orelse span.end;
        recognized.constraint_span = trimSpan(source, .{ .start = offset, .end = constraint_end });
        offset = constraint_end;
    }
    if (offset < span.end and source[offset] == '=') {
        recognized.equals_span = .{ .start = offset, .end = offset + 1 };
        recognized.default_span = trimSpan(source, .{ .start = offset + 1, .end = span.end });
    } else if (recognized.extends_span == null and offset != span.end) {
        return null;
    }
    return recognized;
}

fn projectGenericParameter(source: []const u8, raw_span: Span) ProjectedGenericParameter {
    var name_end = raw_span.end;
    var pos: usize = raw_span.start;
    while (pos < raw_span.end) : (pos += 1) switch (source[pos]) {
        ' ', '\t', '\n', '\r', '=' => {
            name_end = @intCast(pos);
            break;
        },
        else => {},
    };
    const name_span: Span = .{ .start = raw_span.start, .end = name_end };
    const rest_start = skipWhitespaceWithin(source, name_end, raw_span.end);
    var bound_span: ?Span = null;
    if (wordAt(source, rest_start, raw_span.end, "extends")) {
        const after = rest_start + @as(u32, "extends".len);
        if (after < raw_span.end and isTypeWhitespace(source[after])) {
            bound_span = trimSpan(source, .{
                .start = after,
                .end = raw_span.end,
            });
        }
    }
    return .{
        .raw_span = raw_span,
        .name_span = name_span,
        .bound_span = bound_span,
        .bound_fragment = null,
    };
}

fn findTopLevelEquals(source: []const u8, start: u32, end: u32) ?u32 {
    var angle: u32 = 0;
    var paren: u32 = 0;
    var bracket: u32 = 0;
    var brace: u32 = 0;
    var pos: usize = start;
    const limit: usize = end;
    while (pos < limit) {
        const byte = source[pos];
        if (byte == '"' or byte == '\'' or byte == '`') {
            switch (scanTypeQuoted(source, pos, byte)) {
                .end => |quoted_end| pos = @min(quoted_end, limit),
                else => return null,
            }
            continue;
        }
        if (byte == '/' and pos + 1 < limit) {
            if (source[pos + 1] == '/') {
                pos += 2;
                while (pos < limit and source[pos] != '\n') pos += 1;
                continue;
            }
            if (source[pos + 1] == '*') {
                pos += 2;
                while (pos + 1 < limit and !(source[pos] == '*' and source[pos + 1] == '/')) pos += 1;
                pos = @min(pos + 2, limit);
                continue;
            }
        }
        if (byte == '=' and pos + 1 < limit and source[pos + 1] == '>') {
            pos += 2;
            continue;
        }
        const outside_groups = paren == 0 and bracket == 0 and brace == 0;
        switch (byte) {
            '<' => if (outside_groups) {
                angle += 1;
            },
            '>' => if (outside_groups and angle > 0) {
                angle -= 1;
            },
            '(' => paren += 1,
            ')' => if (paren > 0) {
                paren -= 1;
            },
            '[' => bracket += 1,
            ']' => if (bracket > 0) {
                bracket -= 1;
            },
            '{' => brace += 1,
            '}' => if (brace > 0) {
                brace -= 1;
            },
            '=' => if (angle == 0 and paren == 0 and bracket == 0 and brace == 0) {
                return @intCast(pos);
            },
            else => {},
        }
        pos += 1;
    }
    return null;
}

fn wordAt(source: []const u8, start: u32, end: u32, word: []const u8) bool {
    const first: usize = start;
    const last = std.math.add(usize, first, word.len) catch return false;
    const limit: usize = end;
    if (last > limit or !std.mem.eql(u8, source[first..last], word)) return false;
    return last == limit or isTypeWhitespace(source[last]);
}

fn skipWhitespaceWithin(source: []const u8, start: u32, end: u32) u32 {
    var pos: usize = start;
    while (pos < end and isTypeWhitespace(source[pos])) pos += 1;
    return @intCast(pos);
}

pub fn trimSpan(source: []const u8, span: Span) Span {
    var start: usize = span.start;
    var end: usize = span.end;
    while (start < end and isTypeWhitespace(source[start])) start += 1;
    while (end > start and isTypeWhitespace(source[end - 1])) end -= 1;
    return .{ .start = @intCast(start), .end = @intCast(end) };
}

/// Parse one declaration after its keyword. The caller supplies a copied
/// cursor, so an excluded form preserves the runtime parser state.
pub fn parseDeclarationAndStore(
    store: *Store,
    source: []const u8,
    keyword: Token,
    export_span: ?Span,
    kind: DeclarationKind,
    authored_scope: u16,
    cursor: *Cursor,
) !DeclarationParseOutcome {
    return parseDeclarationAndStoreCore(
        store,
        source,
        keyword,
        export_span,
        kind,
        authored_scope,
        cursor,
        .strict,
    );
}

pub fn parseAdmittedDeclarationAndStore(
    store: *Store,
    options: AdmittedDeclarationOptions,
    cursor: *Cursor,
) !DeclarationParseOutcome {
    if (options.raw_header_end) |end| {
        return parseAdmittedAbsentDeclarationAndStore(store, options, cursor, end);
    }
    return parseDeclarationAndStoreCore(
        store,
        store.source,
        options.keyword,
        options.export_span,
        options.kind,
        options.authored_scope,
        cursor,
        .{ .admitted = .{
            .generic_list = options.generic_list,
            .body = options.body,
        } },
    );
}

fn parseAdmittedAbsentDeclarationAndStore(
    store: *Store,
    options: AdmittedDeclarationOptions,
    cursor: *Cursor,
    raw_header_end: u32,
) !DeclarationParseOutcome {
    const source = store.source;
    if (options.kind != .structural or options.body != null) return error.InvalidAdmissionSpan;
    const keyword_end = std.math.add(u32, options.keyword.start, options.keyword.len) catch
        return error.InvalidAdmissionSpan;
    const name = cursor.current;
    const name_end = std.math.add(u32, name.start, name.len) catch return error.InvalidAdmissionSpan;
    if (@as(usize, keyword_end) > source.len or @as(usize, name_end) > source.len or
        keyword_end > name.start or @as(usize, raw_header_end) > source.len or
        name_end > raw_header_end)
    {
        return error.InvalidAdmissionSpan;
    }
    if (!std.mem.eql(u8, source[options.keyword.start..keyword_end], "structural") or
        !tokenIsDeclarationName(name, source) or
        !containsOnlyTypeWhitespace(source, keyword_end, name.start))
    {
        return error.InvalidAdmissionSpan;
    }
    if (options.export_span) |span| {
        if (span.start > span.end or @as(usize, span.end) > source.len or
            span.end > options.keyword.start or !std.mem.eql(u8, span.text(source), "export") or
            !containsOnlyTypeWhitespace(source, span.end, options.keyword.start))
        {
            return error.InvalidAdmissionSpan;
        }
    }
    var header_tail = name_end;
    if (options.generic_list) |span| {
        if (span.start > span.end or @as(usize, span.end) > source.len or
            span.end - span.start < 2 or span.end > raw_header_end or
            span.start != skipTypeWhitespace(source, name_end) or
            source[span.start] != '<' or source[span.end - 1] != '>')
        {
            return error.InvalidAdmissionSpan;
        }
        header_tail = span.end;
    }
    if (raw_header_end != skipTypeWhitespace(source, header_tail) or
        source.len < 2 or @as(usize, raw_header_end) > source.len - 2 or
        source[raw_header_end] != '/' or
        (source[raw_header_end + 1] != '/' and source[raw_header_end + 1] != '*'))
    {
        return error.InvalidAdmissionSpan;
    }

    const checkpoint = store.checkpoint();
    var published = false;
    defer if (!published) store.rollback(checkpoint);
    const source_order = std.math.cast(u32, store.declarations.items.len) orelse
        return error.TooManyTypeItems;
    var pending_owner: ?PendingGenericOwner = if (options.generic_list) |span|
        try reserveDeclarationGenericOwner(store, span, .structural)
    else
        null;
    const declaration: Declaration = .{
        .kind = .structural,
        .export_span = options.export_span,
        .keyword_span = .{ .start = options.keyword.start, .end = keyword_end },
        .name_span = .{ .start = name.start, .end = name_end },
        .equals_span = null,
        .terminator_span = null,
        .body = .absent,
        .generic_owner = if (pending_owner) |owner| owner.owner_index else null,
        .full_span = .{
            .start = if (options.export_span) |span| span.start else options.keyword.start,
            .end = raw_header_end,
        },
        .source_order = source_order,
        .authored_scope = options.authored_scope,
    };
    const full_span = try publishDeclaration(store, declaration, if (pending_owner) |*owner| owner else null);
    var resumed = cursor.tokenizer;
    resumed.resumeAfterRawErasure(raw_header_end, name);
    const consumed_before_erasure = cursor.consumed;
    cursor.* = Cursor.afterCurrent(resumed);
    cursor.consumed +|= consumed_before_erasure;
    published = true;
    return .{ .parsed = full_span };
}

fn publishDeclaration(store: *Store, declaration: Declaration, pending_owner: ?*PendingGenericOwner) !Span {
    try store.declarations.append(store.allocator, declaration);
    if (pending_owner) |owner| {
        try store.finishGenericOwner(owner, .{ .declaration = .{
            .kind = declaration.kind,
            .index = declaration.source_order,
        } });
    }
    try store.validateDeclaration(store.declarations.items[declaration.source_order]);
    return declaration.full_span;
}

const DeclarationBodyInput = union(enum) {
    strict,
    admitted: struct {
        generic_list: ?Span,
        body: ?AdmittedTypeInput,
    },
};

fn reserveDeclarationGenericOwner(
    store: *Store,
    list_span: Span,
    kind: DeclarationKind,
) !PendingGenericOwner {
    return store.reserveGenericOwner(.{
        .list_span = list_span,
        .capture_spans = .{
            .actual_erased_span = list_span,
            .recorded_span = list_span,
        },
        .policy = switch (kind) {
            .structural => .structural,
            .nominal => .ignored,
        },
    });
}

fn parseDeclarationAndStoreCore(
    store: *Store,
    source: []const u8,
    keyword: Token,
    export_span: ?Span,
    kind: DeclarationKind,
    authored_scope: u16,
    cursor: *Cursor,
    body_input: DeclarationBodyInput,
) !DeclarationParseOutcome {
    const checkpoint = store.checkpoint();
    var published = false;
    defer if (!published) store.rollback(checkpoint);

    var scanned = cursor.*;
    if (!tokenIsDeclarationName(scanned.current, source)) return .not_declaration;
    const name_token = scanned.current;
    const name_span = tokenSpan(scanned.current);
    if (export_span) |span| {
        if (!containsOnlyTypeWhitespace(source, span.end, keyword.start)) return .not_declaration;
    }
    if (!containsOnlyTypeWhitespace(source, keyword.start + keyword.len, name_span.start)) {
        return .not_declaration;
    }
    scanned.advance();

    if (!containsOnlyTypeWhitespace(source, name_span.end, scanned.current.start)) {
        return .not_declaration;
    }

    var admitted_generic_list: ?Span = null;
    var pending_owner: ?PendingGenericOwner = null;
    var generic_owner: ?u32 = null;
    const header_has_generic = @as(usize, scanned.current.start) < source.len and
        source[scanned.current.start] == '<';
    switch (body_input) {
        .strict => if (header_has_generic) {
            const scanned_list = (try scanBalancedGenericList(
                store.allocator,
                source,
                scanned.current.start,
            )) orelse
                return .not_declaration;
            if (!isPrivateGenericListEligible(source, scanned_list)) {
                return .{ .excluded = .{
                    .reason = .unsupported_syntax,
                    .raw_span = scanned_list.span,
                    .admission_end = scanned_list.span.end,
                } };
            }
            pending_owner = try reserveDeclarationGenericOwner(store, scanned_list.span, kind);
            generic_owner = pending_owner.?.owner_index;
            advanceCursorTo(&scanned, scanned_list.span.end);
            if (!containsOnlyTypeWhitespace(source, scanned_list.span.end, scanned.current.start)) {
                return .not_declaration;
            }
        },
        .admitted => |admitted| {
            if (header_has_generic != (admitted.generic_list != null)) {
                return error.InvalidAdmissionSpan;
            }
            if (admitted.generic_list) |list_span| {
                if (list_span.start != scanned.current.start or
                    list_span.start >= list_span.end or
                    @as(usize, list_span.end) > source.len or
                    list_span.end - list_span.start < 2 or
                    source[list_span.start] != '<' or
                    source[list_span.end - 1] != '>')
                {
                    return error.InvalidAdmissionSpan;
                }
                admitted_generic_list = list_span;

                const consumed_before_erasure = scanned.consumed;
                var resumed = scanned.tokenizer;
                resumed.resumeAfterRawErasure(list_span.end, name_token);
                scanned = Cursor.afterCurrent(resumed);
                scanned.consumed +|= consumed_before_erasure;
                if (!containsOnlyTypeWhitespace(source, list_span.end, scanned.current.start)) {
                    return error.InvalidAdmissionSpan;
                }
            }
        },
    }

    switch (body_input) {
        .strict => {},
        .admitted => |admitted| {
            const body_input_value = admitted.body;
            const has_equals = scanned.current.type == .assign;
            if (has_equals != (body_input_value != null)) return error.InvalidAdmissionSpan;
            if (body_input_value) |input| {
                try validateAdmittedTypeInput(store, input);
                const after_equals = scanned.current.start + scanned.current.len;
                const raw_start = skipTypeWhitespace(source, after_equals);
                if (input.raw_span.start != raw_start or
                    input.raw_span.end != trimWhitespaceEnd(
                        source,
                        raw_start,
                        input.admission_end,
                    ))
                {
                    return error.InvalidAdmissionSpan;
                }
            }
        },
    }

    if (admitted_generic_list) |list_span| {
        pending_owner = try reserveDeclarationGenericOwner(store, list_span, kind);
        generic_owner = pending_owner.?.owner_index;
    }

    const generic_list_span: ?Span = if (pending_owner) |owner| owner.list_span else null;
    var equals_span: ?Span = null;
    var body: DeclarationBody = .absent;
    var erased_end = scanned.current.start;
    if (scanned.current.type == .assign) {
        const assign_token = scanned.current;
        const consumed_before_erasure = scanned.consumed;
        equals_span = tokenSpan(assign_token);
        const after_equals = assign_token.start + assign_token.len;
        erased_end = after_equals;

        const raw_start = skipTypeWhitespace(source, after_equals);
        const admitted = switch (body_input) {
            .strict => null,
            .admitted => |input| input.body,
        };
        const admission_end = if (admitted) |input|
            input.admission_end
        else switch (scanDeclarationEnd(source, raw_start)) {
            .end => |end| end,
            else => return .not_declaration,
        };
        erased_end = skipTypeWhitespace(source, admission_end);
        if (admitted != null) {
            var resumed = scanned.tokenizer;
            resumed.resumeAfterRawErasure(admission_end, assign_token);
            scanned = Cursor.afterCurrent(resumed);
            scanned.consumed +|= consumed_before_erasure;
        } else {
            scanned.advance();
            advanceCursorTo(&scanned, admission_end);
        }
        const raw_end = if (admitted) |input|
            input.raw_span.end
        else
            trimWhitespaceEnd(source, raw_start, admission_end);
        if (raw_start == raw_end) {
            if (kind == .nominal) return .{ .excluded = .{
                .reason = .nominal_base_not_scalar,
                .raw_span = .{ .start = raw_start, .end = raw_end },
                .admission_end = admission_end,
                .generic_list_span = generic_list_span,
            } };
        }
        if (kind == .nominal and !isScalarNominalBase(source[raw_start..raw_end])) {
            return .{ .excluded = .{
                .reason = .nominal_base_not_scalar,
                .raw_span = .{ .start = raw_start, .end = raw_end },
                .admission_end = admission_end,
                .generic_list_span = generic_list_span,
            } };
        }

        if (raw_start != raw_end) {
            var parser = SyntaxParser.init(store, source, raw_start, raw_end);
            defer parser.deinit();
            const parsed = parser.parse() catch |err| switch (err) {
                error.TypeSyntaxFrameBudgetExceeded => return .{ .excluded = .{
                    .reason = .implementation_budget,
                    .raw_span = .{ .start = raw_start, .end = raw_end },
                    .admission_end = admission_end,
                } },
                error.UnsupportedTypeSyntax => return .{ .excluded = .{
                    .reason = .unsupported_syntax,
                    .raw_span = .{ .start = raw_start, .end = raw_end },
                    .admission_end = admission_end,
                } },
                else => return err,
            };
            try store.validateParsed(parsed.child, .{ .start = raw_start, .end = raw_end });
            body = .{ .present = .{
                .root = parsed.child,
                .node_range = .{
                    .start = @intCast(checkpoint.nodes),
                    .count = @intCast(store.nodes.items.len - checkpoint.nodes),
                },
                .raw_span = .{ .start = raw_start, .end = raw_end },
                .admission_end = admission_end,
                .semantic_prefix_end = parsed.end,
            } };
        }
    }
    if (kind == .nominal and equals_span == null) return .{ .excluded = .{
        .reason = .nominal_base_not_scalar,
        .raw_span = .{ .start = erased_end, .end = erased_end },
        .admission_end = erased_end,
        .generic_list_span = generic_list_span,
    } };

    var terminator_span: ?Span = null;
    if (scanned.current.type == .semicolon and scanned.current.start == erased_end) {
        terminator_span = tokenSpan(scanned.current);
        scanned.advance();
    }
    const full_start = if (export_span) |span| span.start else keyword.start;
    const full_end = if (terminator_span) |span|
        span.end
    else
        erased_end;
    const source_order = std.math.cast(u32, store.declarations.items.len) orelse
        return error.TooManyTypeItems;
    const declaration: Declaration = .{
        .kind = kind,
        .export_span = export_span,
        .keyword_span = tokenSpan(keyword),
        .name_span = name_span,
        .equals_span = equals_span,
        .terminator_span = terminator_span,
        .body = body,
        .generic_owner = generic_owner,
        .full_span = .{ .start = full_start, .end = full_end },
        .source_order = source_order,
        .authored_scope = authored_scope,
    };
    const full_span = try publishDeclaration(store, declaration, if (pending_owner) |*owner| owner else null);
    cursor.* = scanned;
    published = true;
    return .{ .parsed = full_span };
}

const ParsedChild = struct {
    child: Child,
    start: u32,
    end: u32,
    semantic_present: bool,
};

const ExprFrame = struct {
    state: enum { start, wait_first, wait_member } = .start,
    start: u32,
    last_end: u32,
    values: std.ArrayListUnmanaged(Child) = .empty,
};

const PrimaryFrame = struct {
    state: enum { start, wait_base, wait_application, suffix } = .start,
    start: u32,
    base: ParsedChild = .{ .child = .absent, .start = 0, .end = 0, .semantic_present = false },
    readonly_modifier_pending: bool = false,
    ungrouped_named: bool = false,
    consumed_array_suffix: bool = false,
    complete_after_child: bool = false,
};

const ApplicationFrame = struct {
    state: enum { loop, wait_argument } = .loop,
    start: u32,
    base: Child,
    argument_start: u32 = 0,
    arguments: std.ArrayListUnmanaged(Child) = .empty,
};

const RecordFrame = struct {
    state: enum { loop, wait_type } = .loop,
    start: u32,
    pending_start: u32 = 0,
    pending_name: Span = .{ .start = 0, .end = 0 },
    pending_optional: bool = false,
    pending_readonly: bool = false,
    fields: std.ArrayListUnmanaged(Field) = .empty,
};

const TupleFrame = struct {
    state: enum { loop, wait_element } = .loop,
    start: u32,
    elements: std.ArrayListUnmanaged(Child) = .empty,
};

const ParenFrame = struct {
    state: enum { start, wait_param_type, next_param, wait_return, wait_group } = .start,
    start: u32,
    group_start: u32,
    attempt: Store.Checkpoint,
    pending_name: Span = .{ .start = 0, .end = 0 },
    pending_start: u32 = 0,
    pending_optional: bool = false,
    params: std.ArrayListUnmanaged(Parameter) = .empty,
    attempted_params: Range = .{ .start = 0, .count = 0 },
};

const TemplateFrame = struct {
    state: enum { loop, wait_slot } = .loop,
    start: u32,
    parts: std.ArrayListUnmanaged(TemplatePart) = .empty,
};

const Frame = union(enum) {
    union_expr: ExprFrame,
    intersection: ExprFrame,
    primary: PrimaryFrame,
    application: ApplicationFrame,
    record: RecordFrame,
    tuple: TupleFrame,
    paren: ParenFrame,
    template: TemplateFrame,

    fn deinit(self: *Frame, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .union_expr => |*frame| frame.values.deinit(allocator),
            .intersection => |*frame| frame.values.deinit(allocator),
            .application => |*frame| frame.arguments.deinit(allocator),
            .record => |*frame| frame.fields.deinit(allocator),
            .tuple => |*frame| frame.elements.deinit(allocator),
            .paren => |*frame| frame.params.deinit(allocator),
            .template => |*frame| frame.parts.deinit(allocator),
            .primary => {},
        }
    }
};

const SyntaxParser = struct {
    store: *Store,
    allocator: std.mem.Allocator,
    source: []const u8,
    pos: u32,
    end: u32,
    frames: std.ArrayListUnmanaged(Frame) = .empty,
    last: ?ParsedChild = null,
    exclusion_span: ?Span = null,

    fn init(store: *Store, source: []const u8, start: u32, end: u32) SyntaxParser {
        return .{
            .store = store,
            .allocator = store.allocator,
            .source = source,
            .pos = start,
            .end = end,
        };
    }

    fn deinit(self: *SyntaxParser) void {
        for (self.frames.items) |*frame| frame.deinit(self.allocator);
        self.frames.deinit(self.allocator);
    }

    fn parse(self: *SyntaxParser) !ParsedChild {
        try self.push(.{ .union_expr = .{
            .start = self.pos,
            .last_end = self.pos,
        } });
        while (self.frames.items.len > 0) {
            switch (std.meta.activeTag(self.frames.items[self.frames.items.len - 1])) {
                .union_expr => try self.stepExpr(.union_expr),
                .intersection => try self.stepExpr(.intersection),
                .primary => try self.stepPrimary(),
                .application => try self.stepApplication(),
                .record => try self.stepRecord(),
                .tuple => try self.stepTuple(),
                .paren => try self.stepParen(),
                .template => try self.stepTemplate(),
            }
        }
        return self.last orelse .{
            .child = .absent,
            .start = self.pos,
            .end = self.pos,
            .semantic_present = false,
        };
    }

    fn stepExpr(self: *SyntaxParser, comptime kind: std.meta.Tag(Frame)) !void {
        const frame = switch (kind) {
            .union_expr => &self.frames.items[self.frames.items.len - 1].union_expr,
            .intersection => &self.frames.items[self.frames.items.len - 1].intersection,
            else => unreachable,
        };
        switch (frame.state) {
            .start => {
                self.skipWhitespace();
                frame.start = self.pos;
                if (kind == .union_expr) _ = self.matchByte('|') else _ = self.matchByte('&');
                self.skipWhitespace();
                frame.state = .wait_first;
                self.last = null;
                if (kind == .union_expr) {
                    try self.push(.{ .intersection = .{
                        .start = self.pos,
                        .last_end = self.pos,
                    } });
                } else {
                    try self.push(.{ .primary = .{ .start = self.pos } });
                }
            },
            .wait_first, .wait_member => {
                const parsed = self.takeLast();
                if (!parsed.semantic_present) {
                    if (frame.values.items.len == 0) return self.complete(parsed);
                    return self.finishExpr(kind);
                }
                switch (parsed.child) {
                    .absent => return self.finishExpr(kind),
                    .present => {
                        try frame.values.append(self.allocator, parsed.child);
                        frame.last_end = parsed.end;
                    },
                }
                self.skipWhitespace();
                const has_more = if (kind == .union_expr) self.matchByte('|') else self.matchByte('&');
                if (has_more) {
                    frame.state = .wait_member;
                    self.last = null;
                    if (kind == .union_expr) {
                        try self.push(.{ .intersection = .{
                            .start = self.pos,
                            .last_end = self.pos,
                        } });
                    } else {
                        try self.push(.{ .primary = .{ .start = self.pos } });
                    }
                    return;
                }
                try self.finishExpr(kind);
            },
        }
    }

    fn finishExpr(self: *SyntaxParser, comptime kind: std.meta.Tag(Frame)) !void {
        const index = self.frames.items.len - 1;
        const frame = switch (kind) {
            .union_expr => &self.frames.items[index].union_expr,
            .intersection => &self.frames.items[index].intersection,
            else => unreachable,
        };
        const start = frame.start;
        const end = frame.last_end;
        if (frame.values.items.len == 0) return self.complete(.{
            .child = .absent,
            .start = start,
            .end = start,
            .semantic_present = false,
        });
        if (frame.values.items.len == 1) {
            return self.complete(.{
                .child = frame.values.items[0],
                .start = start,
                .end = end,
                .semantic_present = true,
            });
        }
        const range = try self.store.appendMembers(frame.values.items);
        const tag: NodeTag = if (kind == .union_expr) .union_type else .intersection;
        const node = try self.store.appendNode(.{
            .tag = tag,
            .semantic_span = .{ .start = start, .end = end },
            .data = if (kind == .union_expr) .{ .union_type = range } else .{ .intersection = range },
        });
        return self.complete(.{
            .child = .{ .present = node },
            .start = start,
            .end = end,
            .semantic_present = true,
        });
    }

    fn stepPrimary(self: *SyntaxParser) !void {
        const frame = &self.frames.items[self.frames.items.len - 1].primary;
        switch (frame.state) {
            .start => {
                self.skipWhitespace();
                frame.start = self.pos;
                if (self.pos >= self.end) return self.complete(.{
                    .child = .absent,
                    .start = self.pos,
                    .end = self.pos,
                    .semantic_present = false,
                });
                const byte = self.source[self.pos];
                if (byte == '{' or byte == '[' or byte == '(' or byte == '`') {
                    const start = self.pos;
                    self.pos += 1;
                    frame.state = .wait_base;
                    self.last = null;
                    const child_frame: Frame = switch (byte) {
                        '{' => .{ .record = .{ .start = start } },
                        '[' => .{ .tuple = .{ .start = start } },
                        '(' => .{ .paren = .{
                            .start = start,
                            .group_start = self.pos,
                            .attempt = self.store.checkpoint(),
                        } },
                        '`' => .{ .template = .{ .start = start } },
                        else => unreachable,
                    };
                    try self.push(child_frame);
                    return;
                }
                if (byte == '"' or byte == '\'') {
                    frame.base = try self.parseStringLiteral(byte, frame.start);
                    frame.state = .suffix;
                    return;
                }
                if (std.ascii.isDigit(byte) or (byte == '-' and self.pos + 1 < self.end and std.ascii.isDigit(self.source[self.pos + 1]))) {
                    frame.base = try self.parseNumberLiteral(frame.start);
                    frame.state = .suffix;
                    return;
                }
                const ident = self.scanIdentifier();
                if (ident.start == ident.end) {
                    return self.complete(.{
                        .child = .absent,
                        .start = frame.start,
                        .end = frame.start,
                        .semantic_present = false,
                    });
                }
                if (std.mem.eql(u8, ident.text(self.source), "readonly")) {
                    const ident_end = self.pos;
                    self.skipWhitespace();
                    if (self.pos > ident_end or self.pos >= self.end) {
                        frame.readonly_modifier_pending = true;
                        frame.state = .wait_base;
                        self.last = null;
                        try self.push(.{ .primary = .{ .start = self.pos } });
                        return;
                    }
                    self.exclusion_span = ident;
                    return error.UnsupportedTypeSyntax;
                }
                if (!std.mem.eql(u8, ident.text(self.source), "readonly")) {
                    const primitive = primitiveForIdentifier(ident.text(self.source));
                    if (primitive) |value| {
                        frame.base = try self.makeNode(frame.start, ident.end, .primitive, .{ .primitive = value });
                    } else if (std.mem.eql(u8, ident.text(self.source), "true") or std.mem.eql(u8, ident.text(self.source), "false")) {
                        frame.base = try self.makeNode(frame.start, ident.end, .literal_bool, .{
                            .literal_bool = std.mem.eql(u8, ident.text(self.source), "true"),
                        });
                    } else {
                        frame.base = try self.makeNode(frame.start, ident.end, .named_reference, .{
                            .named_reference = ident,
                        });
                        frame.ungrouped_named = true;
                        self.skipWhitespace();
                        if (self.matchByte('<')) {
                            frame.state = .wait_application;
                            self.last = null;
                            try self.push(.{ .application = .{
                                .start = frame.start,
                                .base = frame.base.child,
                            } });
                            return;
                        }
                    }
                }
                frame.state = .suffix;
            },
            .wait_base => {
                frame.base = self.takeLast();
                if (frame.readonly_modifier_pending) {
                    const semantic_present = frame.base.semantic_present;
                    frame.base = try self.makeNode(
                        frame.start,
                        frame.base.end,
                        .readonly_modifier,
                        .{ .readonly_modifier = frame.base.child },
                    );
                    frame.base.semantic_present = semantic_present;
                    frame.complete_after_child = true;
                }
                frame.state = .suffix;
            },
            .wait_application => {
                frame.base = self.takeLast();
                frame.complete_after_child = true;
                frame.state = .suffix;
            },
            .suffix => {
                if (!frame.base.semantic_present) return self.complete(frame.base);
                if (frame.complete_after_child or
                    (frame.ungrouped_named and frame.consumed_array_suffix))
                {
                    return self.complete(frame.base);
                }
                self.skipWhitespace();
                if (self.pos + 1 < self.end and self.source[self.pos] == '[' and self.source[self.pos + 1] == ']') {
                    self.pos += 2;
                    const node = try self.store.appendNode(.{
                        .tag = .array,
                        .semantic_span = .{ .start = frame.start, .end = self.pos },
                        .data = .{ .array = frame.base.child },
                    });
                    frame.base = .{
                        .child = .{ .present = node },
                        .start = frame.start,
                        .end = self.pos,
                        .semantic_present = true,
                    };
                    frame.consumed_array_suffix = true;
                    return;
                }
                return self.complete(frame.base);
            },
        }
    }

    fn stepApplication(self: *SyntaxParser) !void {
        const frame = &self.frames.items[self.frames.items.len - 1].application;
        switch (frame.state) {
            .loop => {
                self.skipWhitespace();
                if (self.matchByte('>')) return self.finishApplication(self.pos);
                if (self.pos >= self.end) return self.finishApplication(self.pos);
                frame.argument_start = self.pos;
                frame.state = .wait_argument;
                self.last = null;
                try self.push(.{ .union_expr = .{
                    .start = self.pos,
                    .last_end = self.pos,
                } });
            },
            .wait_argument => {
                const parsed = self.takeLast();
                if (!parsed.semantic_present or parsed.end <= frame.argument_start) {
                    _ = self.matchByte('>');
                    return self.finishApplication(self.pos);
                }
                switch (parsed.child) {
                    .absent => {
                        _ = self.matchByte('>');
                        return self.finishApplication(self.pos);
                    },
                    .present => try frame.arguments.append(self.allocator, parsed.child),
                }
                self.skipWhitespace();
                _ = self.matchByte(',');
                frame.state = .loop;
            },
        }
    }

    fn finishApplication(self: *SyntaxParser, end: u32) !void {
        const frame = &self.frames.items[self.frames.items.len - 1].application;
        const range = try self.store.appendMembers(frame.arguments.items);
        const node = try self.store.appendNode(.{
            .tag = .generic_application,
            .semantic_span = .{ .start = frame.start, .end = end },
            .data = .{ .generic_application = .{
                .base = frame.base,
                .arguments = range,
            } },
        });
        return self.complete(.{
            .child = .{ .present = node },
            .start = frame.start,
            .end = end,
            .semantic_present = true,
        });
    }

    fn stepRecord(self: *SyntaxParser) !void {
        const frame = &self.frames.items[self.frames.items.len - 1].record;
        switch (frame.state) {
            .loop => {
                self.skipWhitespace();
                if (self.matchByte('}')) return self.finishRecord();
                frame.pending_start = self.pos;
                const first = self.scanIdentifier();
                if (first.start == first.end) return self.finishRecordAfterBreak();
                frame.pending_readonly = false;
                frame.pending_name = first;
                if (std.mem.eql(u8, first.text(self.source), "readonly")) {
                    self.skipWhitespace();
                    const name = self.scanIdentifier();
                    if (name.start != name.end) {
                        frame.pending_readonly = true;
                        frame.pending_name = name;
                    }
                }
                self.skipWhitespace();
                frame.pending_optional = self.matchByte('?');
                self.skipWhitespace();
                if (!self.matchByte(':')) return self.finishRecordAfterBreak();
                self.skipWhitespace();
                frame.state = .wait_type;
                self.last = null;
                try self.push(.{ .union_expr = .{
                    .start = self.pos,
                    .last_end = self.pos,
                } });
            },
            .wait_type => {
                const parsed = self.takeLast();
                try frame.fields.append(self.allocator, .{
                    .span = .{ .start = frame.pending_start, .end = parsed.end },
                    .name = frame.pending_name,
                    .type_child = parsed.child,
                    .optional = frame.pending_optional,
                    .readonly = frame.pending_readonly,
                });
                self.skipWhitespace();
                if (self.pos < self.end and (self.source[self.pos] == ';' or self.source[self.pos] == ',')) self.pos += 1;
                frame.state = .loop;
            },
        }
    }

    fn finishRecord(self: *SyntaxParser) !void {
        const frame = &self.frames.items[self.frames.items.len - 1].record;
        const range = try self.store.appendFields(frame.fields.items);
        const node = try self.store.appendNode(.{
            .tag = .record,
            .semantic_span = .{ .start = frame.start, .end = self.pos },
            .data = .{ .record = range },
        });
        return self.complete(.{
            .child = .{ .present = node },
            .start = frame.start,
            .end = self.pos,
            .semantic_present = true,
        });
    }

    fn finishRecordAfterBreak(self: *SyntaxParser) !void {
        self.skipWhitespace();
        _ = self.matchByte('}');
        return self.finishRecord();
    }

    fn stepTuple(self: *SyntaxParser) !void {
        const frame = &self.frames.items[self.frames.items.len - 1].tuple;
        switch (frame.state) {
            .loop => {
                self.skipWhitespace();
                if (self.matchByte(']')) return self.finishTuple();
                frame.state = .wait_element;
                self.last = null;
                try self.push(.{ .union_expr = .{
                    .start = self.pos,
                    .last_end = self.pos,
                } });
            },
            .wait_element => {
                const parsed = self.takeLast();
                if (!parsed.semantic_present) {
                    self.skipWhitespace();
                    _ = self.matchByte(']');
                    return self.finishTuple();
                }
                const element = parsed.child;
                try frame.elements.append(self.allocator, element);
                self.skipWhitespace();
                _ = self.matchByte(',');
                frame.state = .loop;
            },
        }
    }

    fn finishTuple(self: *SyntaxParser) !void {
        const frame = &self.frames.items[self.frames.items.len - 1].tuple;
        const range = try self.store.appendMembers(frame.elements.items);
        const node = try self.store.appendNode(.{
            .tag = .tuple,
            .semantic_span = .{ .start = frame.start, .end = self.pos },
            .data = .{ .tuple = range },
        });
        return self.complete(.{
            .child = .{ .present = node },
            .start = frame.start,
            .end = self.pos,
            .semantic_present = true,
        });
    }

    fn stepParen(self: *SyntaxParser) !void {
        const frame = &self.frames.items[self.frames.items.len - 1].paren;
        switch (frame.state) {
            .start, .next_param => {
                self.skipWhitespace();
                frame.pending_start = self.pos;
                if (self.matchByte(')')) {
                    const close_end = self.pos;
                    self.skipWhitespace();
                    if (self.matchBytes("=>")) {
                        frame.state = .wait_return;
                        self.skipWhitespace();
                        self.last = null;
                        try self.push(.{ .union_expr = .{
                            .start = self.pos,
                            .last_end = self.pos,
                        } });
                    } else if (frame.params.items.len == 0) {
                        var grouped = try self.makeNode(
                            frame.start,
                            close_end,
                            .group,
                            .{ .group = .{
                                .child = .absent,
                                .attempted_params = frame.attempted_params,
                            } },
                        );
                        grouped.semantic_present = false;
                        self.complete(grouped);
                    } else {
                        try self.finishFunction(.absent, self.pos);
                    }
                    return;
                }
                const name = self.scanIdentifier();
                if (name.start == name.end) return self.backtrackGroup();
                self.skipWhitespace();
                const optional = self.matchByte('?');
                self.skipWhitespace();
                if (!self.matchByte(':')) return self.backtrackGroup();
                self.skipWhitespace();
                frame.pending_name = name;
                frame.pending_optional = optional;
                frame.state = .wait_param_type;
                self.last = null;
                try self.push(.{ .union_expr = .{
                    .start = self.pos,
                    .last_end = self.pos,
                } });
            },
            .wait_param_type => {
                const parsed = self.takeLast();
                try frame.params.append(self.allocator, .{
                    .span = .{ .start = frame.pending_start, .end = parsed.end },
                    .name = frame.pending_name,
                    .type_child = parsed.child,
                    .optional = frame.pending_optional,
                });
                self.skipWhitespace();
                _ = self.matchByte(',');
                frame.state = .next_param;
            },
            .wait_return => {
                const parsed = self.takeLast();
                try self.finishFunction(parsed.child, parsed.end);
            },
            .wait_group => {
                const parsed = self.takeLast();
                self.skipWhitespace();
                _ = self.matchByte(')');
                const grouped = try self.makeNode(
                    frame.start,
                    self.pos,
                    .group,
                    .{ .group = .{
                        .child = parsed.child,
                        .attempted_params = frame.attempted_params,
                    } },
                );
                var result = grouped;
                result.semantic_present = parsed.semantic_present;
                self.complete(result);
            },
        }
    }

    fn backtrackGroup(self: *SyntaxParser) !void {
        const frame = &self.frames.items[self.frames.items.len - 1].paren;
        if (frame.params.items.len == 0) {
            self.store.rollback(frame.attempt);
        } else {
            frame.attempted_params = try self.store.appendParams(frame.params.items);
        }
        frame.params.clearRetainingCapacity();
        self.pos = frame.group_start;
        frame.state = .wait_group;
        self.last = null;
        try self.push(.{ .union_expr = .{
            .start = self.pos,
            .last_end = self.pos,
        } });
    }

    fn finishFunction(self: *SyntaxParser, ret: Child, end: u32) !void {
        const frame = &self.frames.items[self.frames.items.len - 1].paren;
        const range = try self.store.appendParams(frame.params.items);
        const node = try self.store.appendNode(.{
            .tag = .function,
            .semantic_span = .{ .start = frame.start, .end = end },
            .data = .{ .function = .{ .params = range, .ret = ret } },
        });
        return self.complete(.{
            .child = .{ .present = node },
            .start = frame.start,
            .end = end,
            .semantic_present = true,
        });
    }

    fn stepTemplate(self: *SyntaxParser) !void {
        const frame = &self.frames.items[self.frames.items.len - 1].template;
        switch (frame.state) {
            .loop => {
                if (self.matchByte('`')) return self.finishTemplate();
                if (self.pos >= self.end) return self.finishTemplate();
                if (self.pos + 1 < self.end and self.source[self.pos] == '$' and self.source[self.pos + 1] == '{') {
                    self.pos += 2;
                    self.skipWhitespace();
                    frame.state = .wait_slot;
                    self.last = null;
                    try self.push(.{ .union_expr = .{
                        .start = self.pos,
                        .last_end = self.pos,
                    } });
                    return;
                }
                const start = self.pos;
                while (self.pos < self.end and self.source[self.pos] != '`') {
                    if (self.pos + 1 < self.end and self.source[self.pos] == '$' and self.source[self.pos + 1] == '{') break;
                    self.pos += 1;
                }
                if (self.pos > start) try frame.parts.append(self.allocator, .{ .literal = .{
                    .start = start,
                    .end = self.pos,
                } });
            },
            .wait_slot => {
                const parsed = self.takeLast();
                self.skipWhitespace();
                _ = self.matchByte('}');
                try frame.parts.append(self.allocator, .{ .type_slot = parsed.child });
                frame.state = .loop;
            },
        }
    }

    fn finishTemplate(self: *SyntaxParser) !void {
        const frame = &self.frames.items[self.frames.items.len - 1].template;
        if (frame.parts.items.len == 0) {
            return self.complete(.{
                .child = .absent,
                .start = frame.start,
                .end = self.pos,
                .semantic_present = false,
            });
        }
        const range = try self.store.appendTemplateParts(frame.parts.items);
        const node = try self.store.appendNode(.{
            .tag = .template,
            .semantic_span = .{ .start = frame.start, .end = self.pos },
            .data = .{ .template = range },
        });
        return self.complete(.{
            .child = .{ .present = node },
            .start = frame.start,
            .end = self.pos,
            .semantic_present = true,
        });
    }

    fn parseStringLiteral(self: *SyntaxParser, quote: u8, start: u32) !ParsedChild {
        self.pos += 1;
        const value_start = self.pos;
        while (self.pos < self.end and self.source[self.pos] != quote) {
            if (self.source[self.pos] == '\\' and self.pos + 1 < self.end) self.pos += 1;
            self.pos += 1;
        }
        const value_end = self.pos;
        _ = self.matchByte(quote);
        return self.makeNode(start, self.pos, .literal_string, .{
            .literal_string = .{ .start = value_start, .end = value_end },
        });
    }

    fn parseNumberLiteral(self: *SyntaxParser, start: u32) !ParsedChild {
        if (self.source[self.pos] == '-') self.pos += 1;
        while (self.pos < self.end and std.ascii.isDigit(self.source[self.pos])) self.pos += 1;
        const value = std.fmt.parseInt(i16, self.source[start..self.pos], 10) catch {
            return self.makeNode(start, self.pos, .primitive, .{ .primitive = .number });
        };
        return self.makeNode(start, self.pos, .literal_number, .{ .literal_number = value });
    }

    fn makeNode(
        self: *SyntaxParser,
        start: u32,
        end: u32,
        tag: NodeTag,
        data: Node.Data,
    ) !ParsedChild {
        const node = try self.store.appendNode(.{
            .tag = tag,
            .semantic_span = .{ .start = start, .end = end },
            .data = data,
        });
        return .{
            .child = .{ .present = node },
            .start = start,
            .end = end,
            .semantic_present = true,
        };
    }

    fn push(self: *SyntaxParser, frame: Frame) !void {
        if (self.frames.items.len == max_parser_frames) {
            return error.TypeSyntaxFrameBudgetExceeded;
        }
        try self.frames.append(self.allocator, frame);
    }

    fn complete(self: *SyntaxParser, parsed: ParsedChild) void {
        var frame = self.frames.pop().?;
        frame.deinit(self.allocator);
        self.last = parsed;
    }

    fn takeLast(self: *SyntaxParser) ParsedChild {
        const parsed = self.last orelse return .{
            .child = .absent,
            .start = self.pos,
            .end = self.pos,
            .semantic_present = false,
        };
        self.last = null;
        return parsed;
    }

    fn skipWhitespace(self: *SyntaxParser) void {
        while (self.pos < self.end and isTypeWhitespace(self.source[self.pos])) self.pos += 1;
    }

    fn matchByte(self: *SyntaxParser, byte: u8) bool {
        if (self.pos >= self.end or self.source[self.pos] != byte) return false;
        self.pos += 1;
        return true;
    }

    fn matchBytes(self: *SyntaxParser, bytes: []const u8) bool {
        const start: usize = self.pos;
        const finish = std.math.add(usize, start, bytes.len) catch return false;
        if (finish > self.end or !std.mem.eql(u8, self.source[start..finish], bytes)) return false;
        self.pos = @intCast(finish);
        return true;
    }

    fn scanIdentifier(self: *SyntaxParser) Span {
        const start = self.pos;
        if (self.pos >= self.end or !isIdentifierStart(self.source[self.pos])) {
            return .{ .start = start, .end = start };
        }
        self.pos += 1;
        while (self.pos < self.end and isIdentifierContinue(self.source[self.pos])) self.pos += 1;
        return .{ .start = start, .end = self.pos };
    }
};

fn primitiveForIdentifier(text: []const u8) ?Primitive {
    if (std.mem.eql(u8, text, "unknown")) return .unknown;
    if (std.mem.eql(u8, text, "never")) return .never;
    if (std.mem.eql(u8, text, "undefined")) return .undefined;
    if (std.mem.eql(u8, text, "null")) return .null;
    if (std.mem.eql(u8, text, "boolean")) return .boolean;
    if (std.mem.eql(u8, text, "number")) return .number;
    if (std.mem.eql(u8, text, "string")) return .string;
    if (std.mem.eql(u8, text, "Bytes")) return .bytes;
    return null;
}

pub fn isIdentifierStart(byte: u8) bool {
    return std.ascii.isAlphabetic(byte) or byte == '_' or byte == '$';
}

pub fn isIdentifierContinue(byte: u8) bool {
    return isIdentifierStart(byte) or std.ascii.isDigit(byte);
}

test "application base plan requires one owner for every semantic fragment" {
    const source = "<number>((";
    var store = Store.init(std.testing.allocator, source);
    defer store.deinit();
    var runtime = TestRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    const call = try runtime.addCall(8);
    const function = try runtime.addFunction(.function_expr, 8);
    const fragment_index = try parseSemanticFragmentAndStore(&store, .{ .start = 1, .end = 7 });

    try std.testing.expectError(
        error.UnownedSemanticFragment,
        store.planApplicationBases(std.testing.allocator),
    );

    try store.explicit_call_arguments.append(std.testing.allocator, .{
        .owner = call,
        .list_span = .{ .start = 0, .end = 8 },
        .capture_spans = .{
            .actual_erased_span = .{ .start = 0, .end = 8 },
            .recorded_span = .{ .start = 1, .end = 7 },
        },
        .authored_arguments = .{ .start = 0, .count = 0 },
        .semantic_fragments = .{ .start = fragment_index, .count = 1 },
    });
    var valid = try store.planApplicationBasesWithIr(std.testing.allocator, runtime.view());
    valid.deinit();

    try store.projected_generic_parameters.append(std.testing.allocator, .{
        .raw_span = .{ .start = 1, .end = 7 },
        .name_span = .{ .start = 1, .end = 1 },
        .bound_span = .{ .start = 1, .end = 7 },
        .bound_fragment = fragment_index,
    });
    try store.generic_owners.append(std.testing.allocator, .{
        .identity = .{ .function = function },
        .list_span = .{ .start = 0, .end = 8 },
        .capture_spans = .{
            .actual_erased_span = .{ .start = 0, .end = 8 },
            .recorded_span = .{ .start = 1, .end = 7 },
        },
        .authored_parameters = .{ .start = 0, .count = 0 },
        .projected_parameters = .{ .start = 0, .count = 1 },
        .compatibility = .declaration_parameters,
    });
    try std.testing.expectError(
        error.SharedSemanticFragment,
        store.planApplicationBasesWithIr(std.testing.allocator, runtime.view()),
    );
}

test "group metadata retains completed parameter attempts" {
    const source = "(first: Left, second: Right, Final)";
    var store = Store.init(std.testing.allocator, source);
    defer store.deinit();
    const value = try parseAdmittedTypeValue(&store, .{
        .start = 0,
        .end = @intCast(source.len),
    });
    const root = switch (value.root) {
        .absent => return error.TestUnexpectedResult,
        .present => |index| index,
    };
    const group = switch (store.nodes.items[root].data) {
        .group => |result| result,
        else => return error.TestUnexpectedResult,
    };
    const attempted = store.paramSlice(group.attempted_params) orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 2), attempted.len);
    try std.testing.expectEqualStrings("first: Left", attempted[0].span.text(source));
    try std.testing.expectEqualStrings("second: Right", attempted[1].span.text(source));
    const selected = switch (group.child) {
        .absent => return error.TestUnexpectedResult,
        .present => |index| store.nodes.items[index],
    };
    try std.testing.expectEqual(NodeTag.named_reference, selected.tag);
    try std.testing.expectEqualStrings("first", selected.data.named_reference.text(source));
    try std.testing.expectEqual(@as(u32, @intCast(source.len)), value.raw_span.end);
    const selected_end: u32 = @intCast(std.mem.indexOfScalar(u8, source, ':').?);
    try std.testing.expectEqual(selected_end, value.semantic_prefix_end);
    try std.testing.expectEqual(selected_end, store.nodes.items[root].semantic_span.end);
    try store.validateTypeValue(value);
}

test "group metadata validation uses the admitted raw interval" {
    const source = "(first: Left, Right) suffix";
    const raw_end: u32 = @intCast(std.mem.indexOf(u8, source, ") suffix").? + 1);
    var store = Store.init(std.testing.allocator, source);
    defer store.deinit();
    const value = try parseAdmittedTypeValue(&store, .{ .start = 0, .end = raw_end });
    const root = switch (value.root) {
        .absent => return error.TestUnexpectedResult,
        .present => |index| index,
    };
    const attempted_params = store.nodes.items[root].data.group.attempted_params;
    store.params.items[@as(usize, attempted_params.start)].span = .{
        .start = raw_end + 1,
        .end = @intCast(source.len),
    };
    try std.testing.expectError(error.InvalidTypeSpan, store.validateTypeValue(value));
}

test "group metadata allocation failure restores every store array" {
    const Context = struct {
        fn run(allocator: std.mem.Allocator) !void {
            const source = "(first: Left, second: Right, Final)";
            var store = Store.init(allocator, source);
            defer store.deinit();
            const before = store.checkpoint();
            _ = parseAdmittedTypeValue(&store, .{
                .start = 0,
                .end = @intCast(source.len),
            }) catch |err| {
                try std.testing.expect(std.meta.eql(before, store.checkpoint()));
                return err;
            };
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Context.run, .{});
}

test "admitted type bounds reject inconsistent trailing bytes atomically" {
    const source = "number \tX";
    var store = Store.init(std.testing.allocator, source);
    defer store.deinit();
    switch (try parseAdmittedAnnotationAndStore(&store, .global(300), .{
        .raw_span = .{ .start = 0, .end = 6 },
        .admission_end = 8,
    })) {
        .parsed => {},
        .excluded => return error.TestUnexpectedResult,
    }
    const prior = store.checkpoint();
    try std.testing.expect(prior.annotations > 0);

    const invalid = [_]AdmittedTypeInput{
        .{ .raw_span = .{ .start = 0, .end = 6 }, .admission_end = 9 },
        .{ .raw_span = .{ .start = 0, .end = 6 }, .admission_end = 5 },
        .{ .raw_span = .{ .start = 0, .end = 10 }, .admission_end = 10 },
    };
    for (invalid) |input| {
        try std.testing.expectError(
            error.InvalidTypeSpan,
            parseAdmittedAnnotationAndStore(&store, .global(301), input),
        );
        try std.testing.expect(std.meta.eql(prior, store.checkpoint()));
    }
    try store.validate();
}

test "admitted return preserves spelling and disjoint compatibility roots" {
    const source = "value\tis\tstring   {";
    const admission_end: u32 = @intCast(std.mem.indexOfScalar(u8, source, '{').?);
    var store = Store.init(std.testing.allocator, source);
    defer store.deinit();

    const value = switch (try parseAdmittedFunctionReturnAndStore(&store, .{
        .raw_span = .{ .start = 0, .end = admission_end },
        .admission_end = admission_end,
    })) {
        .parsed => |parsed| parsed,
        .failure, .excluded => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqualStrings("value\tis\tstring   ", value.raw_span.text(source));
    try std.testing.expectEqual(LegacyReturnKind.ordinary, value.legacy_return_kind);
    const predicate = switch (value.structure) {
        .predicate => |predicate| predicate,
        .value => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqualStrings("value", predicate.target_span.text(source));
    switch (predicate.target) {
        .unresolved => {},
        .resolved => return error.TestUnexpectedResult,
    }
    try std.testing.expectEqualStrings("string", predicate.narrowed.raw_span.text(source));
    const compatibility = value.legacy_ordinary_prefix orelse
        return error.TestUnexpectedResult;
    try std.testing.expect(std.meta.eql(value.raw_span, compatibility.raw_span));
    try std.testing.expect(!rangesOverlap(
        predicate.narrowed.node_range,
        compatibility.node_range,
    ));
    try store.validateReturnSyntax(value);
}

test "admitted return rejects a trimmed spelling without changing prior syntax" {
    const source = "number; value is string   {";
    const return_start: u32 = @intCast(std.mem.indexOf(u8, source, "value").?);
    const admission_end: u32 = @intCast(std.mem.indexOfScalar(u8, source, '{').?);
    const raw_end: u32 = @intCast(std.mem.indexOf(u8, source, "   {").?);
    var store = Store.init(std.testing.allocator, source);
    defer store.deinit();
    try seedNumberAnnotation(&store);
    const prior = store.checkpoint();
    try std.testing.expect(prior.annotations > 0);

    try std.testing.expectError(
        error.InvalidTypeSpan,
        parseAdmittedFunctionReturnAndStore(&store, .{
            .raw_span = .{ .start = return_start, .end = raw_end },
            .admission_end = admission_end,
        }),
    );
    try std.testing.expect(std.meta.eql(prior, store.checkpoint()));
    try store.validate();
}

test "admitted annotation failure preserves a published seed" {
    const source = "number; { field: number | string; cb: (pair: [number, string]) => `x${boolean}` }";
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{
        .fail_index = std.math.maxInt(usize),
        .resize_fail_index = std.math.maxInt(usize),
    });
    var store = Store.init(failing.allocator(), source);
    defer store.deinit();
    try seedNumberAnnotation(&store);
    const prior = store.checkpoint();
    try std.testing.expect(prior.nodes > 0);
    try std.testing.expect(prior.annotations > 0);
    const target_start: u32 = @intCast(std.mem.indexOfScalar(u8, source, '{').?);
    failing.fail_index = failing.alloc_index;
    failing.resize_fail_index = failing.resize_index;

    try std.testing.expectError(
        error.OutOfMemory,
        parseAdmittedAnnotationAndStore(&store, .global(301), .{
            .raw_span = .{ .start = target_start, .end = @intCast(source.len) },
            .admission_end = @intCast(source.len),
        }),
    );
    try std.testing.expect(failing.has_induced_failure);
    try std.testing.expect(std.meta.eql(prior, store.checkpoint()));
    try validateAfterAllocationFailure(&store);
}
