//! Private U7 comparison between legacy stripping and direct primitive parsing.
//!
//! This module is test-only. It adds no public frontend choice or fallback.

const std = @import("std");
const engine = @import("zts-engine");
const type_env_mod = @import("type_env.zig");
const type_pool_mod = @import("type_pool.zig");

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

const AdmissionMode = enum {
    collect,
    compile,
};

const AdmissionKind = enum {
    any_type,
    void_type,
    nesting_too_deep,
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
    var result = Preflight{};
    var owns_result = true;
    defer if (owns_result) result.deinit(allocator);

    var tokenizer = Tokenizer.init(source);
    var current = tokenizer.next();
    var annotation_count: usize = 0;

    while (current.type != .eof) {
        switch (current.type) {
            .kw_function => return .{ .out_of_slice = .function_declaration },
            .kw_import => return .{ .out_of_slice = .import_declaration },
            .kw_export => return .{ .out_of_slice = .export_declaration },
            .template_literal, .template_head, .template_middle, .template_tail => return .{ .out_of_slice = .template_literal },
            .regex_literal => return .{ .out_of_slice = .regex_literal },
            .kw_let, .kw_const => {},
            .identifier => {
                if (isTypeDeclarationWord(current.text(source))) {
                    return .{ .out_of_slice = .type_declaration };
                }
                return .{ .out_of_slice = .unsupported_initializer };
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
            const initial_cursor = TypeSyntax.Cursor.afterCurrent(tokenizer);
            var type_cursor = initial_cursor;
            var scan_removed_forms = true;
            switch (TypeSyntax.parsePrimitive(source, &type_cursor)) {
                .parsed => {},
                .failure => |failure| switch (failure) {
                    .nesting_too_deep => |at| {
                        var validation = initial_cursor;
                        switch (TypeSyntax.validatePrimitiveAfterDepthRefusal(source, &validation)) {
                            .parsed => type_cursor = validation,
                            .failure => |invalid| return .{ .out_of_slice = switch (invalid) {
                                .unsupported_suffix => .compound_annotation,
                                .missing_type, .unmatched_parenthesis, .nesting_too_deep => .malformed_annotation,
                            } },
                        }
                        try result.diagnostics.append(allocator, .{
                            .kind = .nesting_too_deep,
                            .span = tokenSpan(at),
                        });
                        scan_removed_forms = false;
                    },
                    .unsupported_suffix => return .{ .out_of_slice = .compound_annotation },
                    .missing_type => |at| {
                        if (!isRemovedRoot(at, source)) {
                            return .{ .out_of_slice = .malformed_annotation };
                        }
                        while (!isAnnotationDelimiter(type_cursor.current.type)) {
                            if (!isRemovedSuffix(type_cursor.current)) {
                                return .{ .out_of_slice = .compound_annotation };
                            }
                            type_cursor.advance();
                        }
                    },
                    .unmatched_parenthesis => return .{ .out_of_slice = .malformed_annotation },
                },
            }

            const annotation_end = type_cursor.current.start;
            const annotation_start = colon.start + colon.len;
            if (containsTypeComment(source, annotation_start, annotation_end)) {
                return .{ .out_of_slice = .type_comment };
            }
            if (scan_removed_forms) {
                try appendRemovedForms(
                    allocator,
                    &result.diagnostics,
                    source,
                    annotation_start,
                    annotation_end,
                );
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

    if (annotation_count != 1) return .{ .out_of_slice = .annotation_count };
    if (mode == .compile and result.diagnostics.items.len > 1) {
        result.diagnostics.items.len = 1;
    }
    owns_result = false;
    return .{ .eligible = result };
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

fn containsTypeComment(source: []const u8, start: u32, end: u32) bool {
    if (start > end or @as(usize, end) > source.len) return true;
    const text = source[@as(usize, start)..@as(usize, end)];
    return std.mem.indexOf(u8, text, "//") != null or
        std.mem.indexOf(u8, text, "/*") != null;
}

fn appendRemovedForms(
    allocator: std.mem.Allocator,
    diagnostics: *std.ArrayListUnmanaged(AdmissionDiagnostic),
    source: []const u8,
    start: u32,
    end: u32,
) !void {
    var first_void: ?TypeSyntax.Span = null;
    var cursor: usize = @intCast(start);
    const end_index: usize = @intCast(end);
    while (cursor < end_index) {
        if (!isIdentifierStart(source[cursor])) {
            cursor += 1;
            continue;
        }
        const ident_start = cursor;
        cursor += 1;
        while (cursor < end_index and isIdentifierContinue(source[cursor])) cursor += 1;
        const ident = source[ident_start..cursor];
        const span: TypeSyntax.Span = .{ .start = @intCast(ident_start), .end = @intCast(cursor) };
        if (std.mem.eql(u8, ident, "any")) {
            try diagnostics.append(allocator, .{ .kind = .any_type, .span = span });
        } else if (first_void == null and std.mem.eql(u8, ident, "void")) {
            first_void = span;
        }
    }
    if (first_void) |span| {
        try diagnostics.append(allocator, .{ .kind = .void_type, .span = span });
    }
}

fn isIdentifierStart(byte: u8) bool {
    return std.ascii.isAlphabetic(byte) or byte == '_' or byte == '$';
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
    if (direct.type_store.annotations.items.len != 1) {
        return .{ .differs = "the direct parser did not retain one annotation" };
    }
    if (!try compareLowering(allocator, &prepared, &direct.type_store)) {
        return .{ .differs = "direct and legacy primitive lowering differ" };
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
        .nesting_too_deep => .nesting_too_deep,
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
    try lowerPrimitiveStore(direct_store, &direct_pool, &direct_env);

    const direct_annotation = direct_store.annotations.items[0];
    const direct_idx = direct_env.getVarTypeByBinding(
        direct_annotation.binding.scope_id,
        direct_annotation.binding.name_atom,
    ) orelse return false;

    const type_map = prepared.typeMap() orelse return false;
    var legacy_idx: ?TypeIndex = null;
    for (type_map.entries.items) |entry| {
        if (entry.kind != .var_annotation) continue;
        const name = type_map.getNameText(entry) orelse continue;
        const ordinal = entry.name_ordinal orelse continue;
        legacy_idx = legacy_env.getVarTypeByNameOrdinal(name, ordinal) orelse return false;
        break;
    }

    return direct_pool.getTag(direct_idx) == legacy_pool.getTag(legacy_idx orelse return false);
}

fn lowerPrimitiveStore(
    store: *const TypeSyntax.Store,
    pool: *TypePool,
    env: *TypeEnv,
) !void {
    try pool.ensureHealthy();
    try env.ensureHealthy();
    for (store.annotations.items) |annotation| {
        const node = store.node(annotation.root) orelse return error.InvalidTypeNode;
        const type_idx = primitiveIndex(pool, node.primitive);
        try env.bindVarType(annotation.binding.scope_id, annotation.binding.name_atom, type_idx);
    }
    try pool.ensureHealthy();
    try env.ensureHealthy();
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
    try refused.appendSlice(std.testing.allocator, " = 1;");
    const verdict = try compare(std.testing.allocator, refused.items, .collect);
    try std.testing.expectEqual(AdmissionKind.nesting_too_deep, verdict.admission_refused.first);

    try refused.appendSlice(std.testing.allocator, " function excluded() {}");
    const excluded = try compare(std.testing.allocator, refused.items, .collect);
    try std.testing.expectEqual(OutOfSliceReason.function_declaration, excluded.out_of_slice);
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

test "depth refusals retain primitive comparison eligibility" {
    const cases = [_]struct {
        body: []const u8,
        closed: bool,
        reason: OutOfSliceReason,
    }{
        // A grouped union fails the primitive grammar at the expected closing parenthesis.
        .{ .body = "number | string", .closed = true, .reason = .malformed_annotation },
        .{ .body = "number", .closed = false, .reason = .malformed_annotation },
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
        try std.testing.expectEqual(case.reason, verdict.out_of_slice);
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
}

test "out of slice census covers every private reason" {
    const fixtures = [_]struct {
        reason: OutOfSliceReason,
        source: []const u8,
    }{
        .{ .reason = .function_declaration, .source = "function f() {} const x: number = 1;" },
        .{ .reason = .import_declaration, .source = "import { x } from \"m\"; const y: number = 1;" },
        .{ .reason = .export_declaration, .source = "export const x: number = 1;" },
        .{ .reason = .type_declaration, .source = "structural X = number; const x: number = 1;" },
        .{ .reason = .multiple_bindings, .source = "const { x } = y; const z: number = 1;" },
        .{ .reason = .annotation_count, .source = "const x: number = 1; const y: number = 2;" },
        .{ .reason = .compound_annotation, .source = "const x: number[] = y;" },
        .{ .reason = .malformed_annotation, .source = "const x: (number = 1;" },
        .{ .reason = .unsupported_annotation_position, .source = "const x = a: b; const y: number = 1;" },
        .{ .reason = .assertion_syntax, .source = "const x: number = y as number;" },
        .{ .reason = .template_literal, .source = "const x: string = `x`;" },
        .{ .reason = .regex_literal, .source = "const x: unknown = /x/;" },
        .{ .reason = .type_comment, .source = "const x: number /* comment */ = 1;" },
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

test "direct parser and lowering close every allocation failure" {
    const ParserContext = struct {
        fn run(type_allocator: std.mem.Allocator) !void {
            const source = "const value: number = input;";
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

            var store = TypeSyntax.Store.init(std.testing.allocator, "number");
            defer store.deinit();
            try store.add(.global(300), .{
                .primitive = .number,
                .semantic_span = .{ .start = 0, .end = 6 },
                .raw_span = .{ .start = 0, .end = 6 },
            });
            try lowerPrimitiveStore(&store, &pool, &env);
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, LowerContext.run, .{});
}

test "runtime comparison includes constants locations and complete empty upvalue state" {
    try expectEquivalent(
        "const seed = \"x\"; const value: number = make(1.25 + 2 * 3); let copy = seed;",
    );
}
