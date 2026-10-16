//! Parser-owned TypeScript syntax that has no runtime representation.
//!
//! The store borrows the original source and owns only compact syntax arrays.
//! It does not intern names or allocate runtime nodes, constants, or scopes.

const std = @import("std");
const retired_types_module = @import("zts-base").module_specifier.retired_types_module;
const ir = @import("ir.zig");
const token_mod = @import("token.zig");
const TokenType = token_mod.TokenType;
const tokenizer_mod = @import("tokenizer.zig");

const BindingRef = ir.BindingRef;
const Token = token_mod.Token;
const Tokenizer = tokenizer_mod.Tokenizer;

pub const Span = struct {
    start: u32,
    end: u32,

    pub fn text(self: Span, source: []const u8) []const u8 {
        if (self.start > self.end or @as(usize, self.end) > source.len) return "";
        return source[self.start..self.end];
    }
};

pub const AdmissionMode = enum {
    compile,
    collect,
};

pub const AdmissionKind = enum {
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
};

pub const AdmissionPosition = struct {
    line: u32 = 1,
    column: u32 = 1,
};

pub const AdmissionPresentation = struct {
    source: []const u8,
    offset: u32 = 0,
    position: AdmissionPosition = .{},

    pub fn positionAt(self: AdmissionPresentation, offset: u32) !AdmissionPosition {
        if (offset < self.offset or @as(usize, offset) > self.source.len) {
            return error.InvalidAdmissionPosition;
        }
        var position = self.position;
        for (self.source[self.offset..offset]) |byte| {
            if (byte == '\n') {
                position.line += 1;
                position.column = 1;
            } else {
                position.column += 1;
            }
        }
        return position;
    }

    pub fn declinedParameterColon(self: AdmissionPresentation, colon: u32) !AdmissionPresentation {
        if (@as(usize, colon) >= self.source.len or self.source[colon] != ':') {
            return error.InvalidAdmissionPosition;
        }
        var consumed = try self.trackedWhitespaceAt(colon + 1);
        consumed.offset = colon;
        return consumed;
    }

    pub fn trackedWhitespaceAt(self: AdmissionPresentation, start: u32) !AdmissionPresentation {
        var position = try self.positionAt(start);
        var offset: usize = start;
        while (offset < self.source.len) : (offset += 1) {
            switch (self.source[offset]) {
                ' ', '\t' => position.column += 1,
                '\n' => {
                    position.line += 1;
                    position.column = 1;
                },
                '\r' => {},
                else => break,
            }
        }
        return .{ .source = self.source, .offset = @intCast(offset), .position = position };
    }
};

pub const AdmissionDiagnostic = struct {
    kind: AdmissionKind,
    span: Span,
    presentation: ?AdmissionPosition = null,

    pub fn positionIn(self: AdmissionDiagnostic, source: []const u8) AdmissionPosition {
        if (self.presentation) |position| return position;
        return (AdmissionPresentation{ .source = source }).positionAt(
            @intCast(@min(@as(usize, self.span.start), source.len)),
        ) catch |err| @panic(@errorName(err));
    }
};

fn sameAdmissionPosition(
    source: ?[]const u8,
    first: AdmissionDiagnostic,
    second: AdmissionDiagnostic,
) bool {
    if (source) |text| return std.meta.eql(first.positionIn(text), second.positionIn(text));
    if (first.presentation) |position| {
        if (second.presentation) |other| return std.meta.eql(position, other);
        return false;
    }
    if (second.presentation != null) return false;
    return first.span.start == second.span.start;
}

pub const AdmissionObservationHistory = struct {
    allocator: std.mem.Allocator,
    source: ?[]const u8 = null,
    diagnostics: std.ArrayListUnmanaged(AdmissionDiagnostic) = .empty,

    pub fn init(allocator: std.mem.Allocator) AdmissionObservationHistory {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *AdmissionObservationHistory) void {
        self.diagnostics.deinit(self.allocator);
    }

    pub fn items(self: *const AdmissionObservationHistory) []const AdmissionDiagnostic {
        return self.diagnostics.items;
    }

    pub fn last(self: *const AdmissionObservationHistory) ?AdmissionDiagnostic {
        return if (self.diagnostics.items.len == 0)
            null
        else
            self.diagnostics.items[self.diagnostics.items.len - 1];
    }

    pub fn checkpoint(self: *const AdmissionObservationHistory) usize {
        return self.diagnostics.items.len;
    }

    pub fn rollbackUnconfirmed(
        self: *AdmissionObservationHistory,
        checkpoint_value: usize,
    ) void {
        std.debug.assert(checkpoint_value <= self.diagnostics.items.len);
        self.diagnostics.items.len = checkpoint_value;
    }

    pub fn record(
        self: *AdmissionObservationHistory,
        diagnostic: AdmissionDiagnostic,
    ) !void {
        for (self.diagnostics.items) |existing| {
            if (sameAdmissionPosition(self.source, existing, diagnostic)) return;
        }
        try self.diagnostics.append(self.allocator, diagnostic);
    }
};

pub const AdmissionCollector = struct {
    allocator: std.mem.Allocator,
    source: ?[]const u8 = null,
    mode: AdmissionMode,
    diagnostics: std.ArrayListUnmanaged(AdmissionDiagnostic) = .empty,
    encounter_generation: u64 = 0,
    fatal: bool = false,

    pub fn init(allocator: std.mem.Allocator, mode: AdmissionMode) AdmissionCollector {
        return .{
            .allocator = allocator,
            .mode = mode,
        };
    }

    pub fn deinit(self: *AdmissionCollector) void {
        self.diagnostics.deinit(self.allocator);
    }

    pub fn items(self: *const AdmissionCollector) []const AdmissionDiagnostic {
        return self.diagnostics.items;
    }

    pub fn generation(self: *const AdmissionCollector) u64 {
        return self.encounter_generation;
    }

    pub fn hasFatal(self: *const AdmissionCollector) bool {
        return self.fatal;
    }

    pub fn isCompile(self: *const AdmissionCollector) bool {
        return self.mode == .compile;
    }

    pub fn shouldStop(self: *const AdmissionCollector) bool {
        return self.fatal or
            (self.mode == .compile and self.diagnostics.items.len != 0);
    }

    pub fn recordRecoverable(
        self: *AdmissionCollector,
        diagnostic: AdmissionDiagnostic,
    ) !void {
        self.noteEncounter();
        if (self.shouldStop()) return;
        for (self.diagnostics.items) |existing| {
            if (sameAdmissionPosition(self.source, existing, diagnostic)) return;
        }
        try self.diagnostics.append(self.allocator, diagnostic);
    }

    pub fn recordCaught(
        self: *AdmissionCollector,
        diagnostic: AdmissionDiagnostic,
    ) !void {
        if (self.mode == .compile) return;
        try self.recordRecoverable(diagnostic);
    }

    pub fn recordFatal(
        self: *AdmissionCollector,
        diagnostic: AdmissionDiagnostic,
    ) !void {
        self.noteEncounter();
        if (self.fatal) return;
        try self.diagnostics.ensureTotalCapacity(self.allocator, 1);
        self.diagnostics.items.len = 0;
        self.diagnostics.appendAssumeCapacity(diagnostic);
        self.fatal = true;
    }

    fn noteEncounter(self: *AdmissionCollector) void {
        self.encounter_generation = std.math.add(
            u64,
            self.encounter_generation,
            1,
        ) catch std.math.maxInt(u64);
    }
};

pub const AdmissionSink = struct {
    collector: *AdmissionCollector,
    observations: ?*AdmissionObservationHistory,
    presentation: ?AdmissionPresentation = null,

    pub fn init(
        collector: *AdmissionCollector,
        observations: ?*AdmissionObservationHistory,
    ) AdmissionSink {
        return .{
            .collector = collector,
            .observations = observations,
        };
    }

    pub fn recordCaught(self: AdmissionSink, diagnostic: AdmissionDiagnostic) !void {
        const presented = try self.present(diagnostic);
        try self.recordObservation(presented);
        try self.collector.recordCaught(presented);
    }

    pub fn recordRecoverable(self: AdmissionSink, diagnostic: AdmissionDiagnostic) !void {
        const presented = try self.present(diagnostic);
        try self.recordObservation(presented);
        try self.collector.recordRecoverable(presented);
    }

    pub fn recordFatal(self: AdmissionSink, diagnostic: AdmissionDiagnostic) !void {
        const presented = try self.present(diagnostic);
        try self.recordObservation(presented);
        try self.collector.recordFatal(presented);
    }

    pub fn present(self: AdmissionSink, diagnostic: AdmissionDiagnostic) !AdmissionDiagnostic {
        var presented = diagnostic;
        if (presented.presentation == null) {
            if (self.presentation) |context| {
                presented.presentation = try context.positionAt(diagnostic.span.start);
            }
        }
        return presented;
    }

    pub fn physicalPositions(self: AdmissionSink) AdmissionSink {
        var physical = self;
        if (self.presentation) |context| {
            physical.presentation = .{ .source = context.source };
        }
        return physical;
    }

    pub fn shouldStop(self: AdmissionSink) bool {
        return self.collector.shouldStop();
    }

    pub fn isCompile(self: AdmissionSink) bool {
        return self.collector.isCompile();
    }

    fn recordObservation(self: AdmissionSink, diagnostic: AdmissionDiagnostic) !void {
        if (self.observations) |observations| try observations.record(diagnostic);
    }
};

pub const AdmissionTypePolicy = enum {
    general_type,
    parameter_type,
    any_only,
    removed_only,
};

pub const AdmissionTypeSpanOptions = struct {
    span: Span,
    policy: AdmissionTypePolicy,
    caught_lexical: []const AdmissionDiagnostic = &.{},
    removed_span: ?Span = null,
};

pub const NamedFunctionGap = enum {
    whitespace,
    block_comment,
    line_comment,
    forbidden,
};

fn isNamedFunctionHorizontalWhitespace(byte: u8) bool {
    return byte == ' ' or byte == '\t';
}

pub fn classifyNamedFunctionGap(source: []const u8, span: Span) NamedFunctionGap {
    if (span.start > span.end or @as(usize, span.end) > source.len) return .forbidden;
    var pos: usize = span.start;
    const end: usize = span.end;
    while (pos < end and isTypeWhitespace(source[pos])) pos += 1;
    if (pos == end) return .whitespace;
    pos = span.start;
    while (pos < end and isNamedFunctionHorizontalWhitespace(source[pos])) pos += 1;
    if (pos + 1 >= end or source[pos] != '/') return .forbidden;

    if (source[pos + 1] == '*') {
        pos += 2;
        while (pos + 1 < end and !(source[pos] == '*' and source[pos + 1] == '/')) : (pos += 1) {
            if (source[pos] == '\n' or source[pos] == '\r') return .forbidden;
        }
        if (pos + 1 >= end) return .forbidden;
        pos += 2;
        while (pos < end and isNamedFunctionHorizontalWhitespace(source[pos])) pos += 1;
        return if (pos == end) .block_comment else .forbidden;
    }
    if (source[pos + 1] == '/') {
        pos += 2;
        while (pos < end and source[pos] != '\n') : (pos += 1) {
            if (source[pos] == '\r') return .forbidden;
        }
        if (pos == end) return .forbidden;
        pos += 1;
        while (pos < end and isNamedFunctionHorizontalWhitespace(source[pos])) pos += 1;
        return if (pos == end) .line_comment else .forbidden;
    }
    return .forbidden;
}

pub fn hasDedicatedAssignmentArrowWindow(
    source: []const u8,
    previous: Token,
    generic_start: u32,
) bool {
    const previous_end = std.math.add(u32, previous.start, previous.len) catch return false;
    if (previous_end > generic_start or @as(usize, generic_start) > source.len) return false;
    const previous_text = previous.text(source);
    if (previous_text.len == 0 or previous_text[previous_text.len - 1] != '=') return false;
    return std.mem.trim(
        u8,
        source[@as(usize, previous_end)..@as(usize, generic_start)],
        " \t\r\n",
    ).len == 0;
}

pub fn isPrivateArrowPrefixEligible(
    source: []const u8,
    previous: Token,
    generic_start: u32,
) bool {
    if (hasDedicatedAssignmentArrowWindow(source, previous, generic_start)) return true;
    return !rawLooksLikeComparison(source, generic_start);
}

pub fn rawLooksLikeComparison(source: []const u8, generic_start: u32) bool {
    var at: usize = generic_start;
    while (at > 0) {
        switch (source[at - 1]) {
            ' ', '\t', '\r', '\n' => at -= 1,
            else => break,
        }
    }
    if (at == 0) return false;
    const previous = source[at - 1];
    return std.ascii.isAlphanumeric(previous) or previous == ')' or previous == ']' or
        previous == '_' or previous == '$';
}

pub fn tokenStartsGenericList(source: []const u8, token: Token) bool {
    return @as(usize, token.start) < source.len and source[token.start] == '<';
}

pub const Primitive = enum {
    unknown,
    never,
    undefined,
    null,
    boolean,
    number,
    string,
    bytes,
};

pub const NodeIndex = u32;

pub const Child = union(enum) {
    absent,
    present: NodeIndex,
};

pub const Range = struct {
    start: u32,
    count: u32,
};

pub const NodeTag = enum {
    primitive,
    named_reference,
    generic_application,
    group,
    readonly_modifier,
    record,
    array,
    tuple,
    function,
    union_type,
    intersection,
    literal_string,
    literal_number,
    literal_bool,
    template,
};

pub const Node = struct {
    tag: NodeTag,
    semantic_span: Span,
    data: Data,

    pub const Data = union(NodeTag) {
        primitive: Primitive,
        named_reference: Span,
        generic_application: struct { base: Child, arguments: Range },
        group: struct { child: Child, attempted_params: Range },
        readonly_modifier: Child,
        record: Range,
        array: Child,
        tuple: Range,
        function: struct { params: Range, ret: Child },
        union_type: Range,
        intersection: Range,
        literal_string: Span,
        literal_number: i16,
        literal_bool: bool,
        template: Range,
    };
};

pub const Field = struct {
    span: Span,
    name: Span,
    type_child: Child,
    optional: bool,
    readonly: bool,
};

pub const Parameter = struct {
    span: Span,
    name: Span,
    type_child: Child,
    optional: bool,
};

pub const TemplatePart = union(enum) {
    literal: Span,
    type_slot: Child,
};

pub const Annotation = struct {
    binding: BindingRef,
    root: Child,
    node_range: Range,
    raw_span: Span,
    admission_end: u32,
    semantic_prefix_end: u32,
    runtime_owner: ?AnnotationRuntimeOwner = null,
};

pub const AnnotationRuntimeOwner = struct {
    declaration: ir.NodeIndex,
    declaration_start: u32,
};

pub const TypeValue = struct {
    root: Child,
    node_range: Range,
    raw_span: Span,
    admission_end: u32,
    semantic_prefix_end: u32,
};

pub const ParameterOwner = struct {
    pattern: ir.NodeIndex,
    binding: BindingRef,
};

pub const ParameterAnnotation = struct {
    owner: ParameterOwner,
    value: TypeValue,
};

pub const LegacyReturnKind = enum {
    ordinary,
    type_guard,
};

pub const PredicateTarget = union(enum) {
    resolved: ParameterOwner,
    unresolved,
};

pub const PredicateSyntax = struct {
    target_span: Span,
    target: PredicateTarget,
    narrowed: TypeValue,
};

pub const ReturnStructure = union(enum) {
    value: TypeValue,
    predicate: PredicateSyntax,
};

pub const ReturnSyntax = struct {
    raw_span: Span,
    legacy_return_kind: LegacyReturnKind,
    structure: ReturnStructure,
    legacy_ordinary_prefix: ?TypeValue,
};

pub const FunctionSignature = struct {
    owner: ir.NodeIndex,
    parameters: Range,
    return_syntax: ?ReturnSyntax,
    source_span: Span,
};

pub const PendingFunctionSignature = struct {
    checkpoint: Store.Checkpoint,
    parameter_start: usize,
    return_syntax: ?ReturnSyntax = null,
    record_index: ?u32 = null,
    final_record: ?FunctionSignature = null,
    reserved: bool = false,
    active: bool = true,
};

pub const TypeOnlyModuleKind = enum {
    import_type,
    export_type,
};

pub const TypeOnlyModule = struct {
    kind: TypeOnlyModuleKind,
    raw_span: Span,
};

pub const TypeOnlyModuleRefusalReason = enum {
    zttp_types,
};

pub const TypeOnlyModuleRefusal = struct {
    reason: TypeOnlyModuleRefusalReason,
    original_location: token_mod.SourceLocation,
    raw_span: Span,
};

pub const TypeOnlyModuleDiagnosticKind = enum {
    unterminated_string,
    nesting_too_deep,
};

pub const TypeOnlyModuleDiagnostic = struct {
    kind: TypeOnlyModuleDiagnosticKind,
    offset: u32,
};

pub const TypeOnlyModuleScanOptions = struct {
    source: []const u8,
    keyword: Token,
    diagnostics: *std.ArrayListUnmanaged(TypeOnlyModuleDiagnostic),
};

pub const TypeOnlyModuleScan = union(enum) {
    not_type_only,
    refused: TypeOnlyModuleRefusal,
    excluded: TypeOnlyModule,
    scanned: TypeOnlyModule,
};

pub const GenericCaptureSpans = struct {
    actual_erased_span: Span,
    legacy_recorded_span: Span,
};

pub const ErasedTypePrefixOwner = union(enum) {
    expression: ir.NodeIndex,
    block: ir.NodeIndex,
};

pub const ErasedTypePrefixCompatibility = union(enum) {
    ignored_parameters,
    legacy_parameter_projection: struct {
        projected_parameters: Range,
        semantic_fragments: Range,
    },
};

pub const ErasedTypePrefix = struct {
    list_span: Span,
    capture_spans: GenericCaptureSpans,
    operand_span: Span,
    owner: ErasedTypePrefixOwner,
    compatibility: ErasedTypePrefixCompatibility,
};

pub const ErasedTypePrefixPolicy = enum {
    ignored_parameters,
    legacy_parameter_projection,
};

pub const ErasedTypePrefixOptions = struct {
    list_span: Span,
    capture_spans: GenericCaptureSpans,
    policy: ErasedTypePrefixPolicy,
};

pub const ErasedTypePrefixFinal = struct {
    owner: ErasedTypePrefixOwner,
    operand_span: Span,
    view: ir.IrView,
};

pub const PendingErasedTypePrefix = struct {
    checkpoint: Store.Checkpoint,
    record_index: u32,
    list_span: Span,
    capture_spans: GenericCaptureSpans,
    compatibility: ErasedTypePrefixCompatibility,
    active: bool = true,
};

pub const DeclarationKind = enum {
    structural,
    nominal,
};

pub const DeclarationBody = union(enum) {
    absent,
    present: struct {
        root: Child,
        node_range: Range,
        raw_span: Span,
        admission_end: u32,
        semantic_prefix_end: u32,
    },
};

pub const RecognizedGenericParameter = struct {
    name_span: Span,
    extends_span: ?Span,
    constraint_span: ?Span,
    equals_span: ?Span,
    default_span: ?Span,
};

pub const AuthoredGenericParameter = struct {
    raw_span: Span,
    trimmed_span: Span,
    recognized: ?RecognizedGenericParameter,
};

pub const ProjectedGenericParameter = struct {
    raw_span: Span,
    name_span: Span,
    legacy_bound_span: ?Span,
    bound_fragment: ?u32,
};

pub const SemanticFragment = struct {
    raw_span: Span,
    root: Child,
    node_range: Range,
    semantic_prefix_end: u32,
};

pub const GenericOwnerIdentity = union(enum) {
    structural_declaration: u32,
    nominal_declaration: u32,
    function: ir.NodeIndex,
    arrow: ir.NodeIndex,
};

pub const GenericOwnerCompatibility = union(enum) {
    declaration_parameters,
    ignored_declaration_parameters,
    legacy_call_arguments: struct {
        authored_arguments: Range,
        semantic_fragments: Range,
    },
};

pub const GenericOwner = struct {
    identity: GenericOwnerIdentity,
    list_span: Span,
    capture_spans: GenericCaptureSpans,
    authored_parameters: Range,
    projected_parameters: Range,
    compatibility: GenericOwnerCompatibility,
};

pub const GenericOwnerPolicy = enum {
    structural,
    callable,
    ignored,
    legacy_call,
};

pub const GenericOwnerOptions = struct {
    list_span: Span,
    capture_spans: GenericCaptureSpans,
    policy: GenericOwnerPolicy,
};

pub const GenericOwnerFinal = union(enum) {
    declaration: struct {
        kind: DeclarationKind,
        index: u32,
    },
    runtime: struct {
        owner: ir.NodeIndex,
        view: ir.IrView,
    },
};

pub const PendingGenericOwner = struct {
    checkpoint: Store.Checkpoint,
    owner_index: u32,
    list_span: Span,
    capture_spans: GenericCaptureSpans,
    authored_parameters: Range,
    projected_parameters: Range,
    compatibility: GenericOwnerCompatibility,
    policy: GenericOwnerPolicy,
    active: bool = true,
};

pub const AuthoredCallArgument = struct {
    full_span: Span,
};

pub const ExplicitCallArguments = struct {
    owner: ir.NodeIndex,
    list_span: Span,
    capture_spans: GenericCaptureSpans,
    authored_arguments: Range,
    semantic_fragments: Range,
};

pub const ExplicitCallOptions = struct {
    list_span: Span,
    capture_spans: GenericCaptureSpans,
};

pub const PendingExplicitCall = struct {
    checkpoint: Store.Checkpoint,
    record_index: u32,
    final_record: ExplicitCallArguments,
    active: bool = true,
};

pub const Declaration = struct {
    kind: DeclarationKind,
    export_span: ?Span,
    keyword_span: Span,
    name_span: Span,
    equals_span: ?Span,
    terminator_span: ?Span,
    body: DeclarationBody,
    generic_owner: ?u32 = null,
    full_span: Span,
    source_order: u32,
    authored_scope: u16,
};

pub const Store = struct {
    allocator: std.mem.Allocator,
    source: []const u8,
    nodes: std.ArrayListUnmanaged(Node) = .empty,
    members: std.ArrayListUnmanaged(Child) = .empty,
    fields: std.ArrayListUnmanaged(Field) = .empty,
    params: std.ArrayListUnmanaged(Parameter) = .empty,
    template_parts: std.ArrayListUnmanaged(TemplatePart) = .empty,
    annotations: std.ArrayListUnmanaged(Annotation) = .empty,
    declarations: std.ArrayListUnmanaged(Declaration) = .empty,
    generic_parameters: std.ArrayListUnmanaged(AuthoredGenericParameter) = .empty,
    projected_generic_parameters: std.ArrayListUnmanaged(ProjectedGenericParameter) = .empty,
    semantic_fragments: std.ArrayListUnmanaged(SemanticFragment) = .empty,
    generic_owners: std.ArrayListUnmanaged(GenericOwner) = .empty,
    authored_call_arguments: std.ArrayListUnmanaged(AuthoredCallArgument) = .empty,
    explicit_call_arguments: std.ArrayListUnmanaged(ExplicitCallArguments) = .empty,
    parameter_annotations: std.ArrayListUnmanaged(ParameterAnnotation) = .empty,
    function_signatures: std.ArrayListUnmanaged(FunctionSignature) = .empty,
    type_only_modules: std.ArrayListUnmanaged(TypeOnlyModule) = .empty,
    erased_type_prefixes: std.ArrayListUnmanaged(ErasedTypePrefix) = .empty,

    pub fn init(allocator: std.mem.Allocator, source: []const u8) Store {
        return .{
            .allocator = allocator,
            .source = source,
        };
    }

    pub fn deinit(self: *Store) void {
        self.nodes.deinit(self.allocator);
        self.members.deinit(self.allocator);
        self.fields.deinit(self.allocator);
        self.params.deinit(self.allocator);
        self.template_parts.deinit(self.allocator);
        self.annotations.deinit(self.allocator);
        self.declarations.deinit(self.allocator);
        self.generic_parameters.deinit(self.allocator);
        self.projected_generic_parameters.deinit(self.allocator);
        self.semantic_fragments.deinit(self.allocator);
        self.generic_owners.deinit(self.allocator);
        self.authored_call_arguments.deinit(self.allocator);
        self.explicit_call_arguments.deinit(self.allocator);
        self.parameter_annotations.deinit(self.allocator);
        self.function_signatures.deinit(self.allocator);
        self.type_only_modules.deinit(self.allocator);
        self.erased_type_prefixes.deinit(self.allocator);
    }

    pub fn add(self: *Store, binding: BindingRef, parsed: ParsedPrimitive) !void {
        const previous = self.checkpoint();
        errdefer self.rollback(previous);
        const root = try self.appendNode(.{
            .tag = .primitive,
            .semantic_span = parsed.semantic_span,
            .data = .{ .primitive = parsed.primitive },
        });
        try self.validateParsed(.{ .present = root }, parsed.raw_span);
        const annotation: Annotation = .{
            .binding = binding,
            .root = .{ .present = root },
            .node_range = .{ .start = @intCast(previous.nodes), .count = 1 },
            .raw_span = parsed.raw_span,
            .admission_end = parsed.raw_span.end,
            .semantic_prefix_end = parsed.semantic_span.end,
        };
        try self.validateAnnotation(annotation);
        try self.annotations.ensureUnusedCapacity(self.allocator, 1);
        self.annotations.appendAssumeCapacity(annotation);
    }

    pub const Checkpoint = struct {
        nodes: usize,
        members: usize,
        fields: usize,
        params: usize,
        template_parts: usize,
        annotations: usize,
        declarations: usize,
        generic_parameters: usize,
        projected_generic_parameters: usize,
        semantic_fragments: usize,
        generic_owners: usize,
        authored_call_arguments: usize,
        explicit_call_arguments: usize,
        parameter_annotations: usize,
        function_signatures: usize,
        type_only_modules: usize,
        erased_type_prefixes: usize,
    };

    pub fn checkpoint(self: *const Store) Checkpoint {
        return .{
            .nodes = self.nodes.items.len,
            .members = self.members.items.len,
            .fields = self.fields.items.len,
            .params = self.params.items.len,
            .template_parts = self.template_parts.items.len,
            .annotations = self.annotations.items.len,
            .declarations = self.declarations.items.len,
            .generic_parameters = self.generic_parameters.items.len,
            .projected_generic_parameters = self.projected_generic_parameters.items.len,
            .semantic_fragments = self.semantic_fragments.items.len,
            .generic_owners = self.generic_owners.items.len,
            .authored_call_arguments = self.authored_call_arguments.items.len,
            .explicit_call_arguments = self.explicit_call_arguments.items.len,
            .parameter_annotations = self.parameter_annotations.items.len,
            .function_signatures = self.function_signatures.items.len,
            .type_only_modules = self.type_only_modules.items.len,
            .erased_type_prefixes = self.erased_type_prefixes.items.len,
        };
    }

    pub fn rollback(self: *Store, value: Checkpoint) void {
        self.nodes.items.len = value.nodes;
        self.members.items.len = value.members;
        self.fields.items.len = value.fields;
        self.params.items.len = value.params;
        self.template_parts.items.len = value.template_parts;
        self.annotations.items.len = value.annotations;
        self.declarations.items.len = value.declarations;
        self.generic_parameters.items.len = value.generic_parameters;
        self.projected_generic_parameters.items.len = value.projected_generic_parameters;
        self.semantic_fragments.items.len = value.semantic_fragments;
        self.generic_owners.items.len = value.generic_owners;
        self.authored_call_arguments.items.len = value.authored_call_arguments;
        self.explicit_call_arguments.items.len = value.explicit_call_arguments;
        self.parameter_annotations.items.len = value.parameter_annotations;
        self.function_signatures.items.len = value.function_signatures;
        self.type_only_modules.items.len = value.type_only_modules;
        self.erased_type_prefixes.items.len = value.erased_type_prefixes;
    }

    fn appendNode(self: *Store, value: Node) !NodeIndex {
        const index = std.math.cast(NodeIndex, self.nodes.items.len) orelse return error.TooManyTypeNodes;
        try self.nodes.append(self.allocator, value);
        return index;
    }

    fn appendMembers(self: *Store, values: []const Child) !Range {
        return appendRange(Child, self.allocator, &self.members, values);
    }

    fn appendFields(self: *Store, values: []const Field) !Range {
        return appendRange(Field, self.allocator, &self.fields, values);
    }

    fn appendParams(self: *Store, values: []const Parameter) !Range {
        return appendRange(Parameter, self.allocator, &self.params, values);
    }

    fn appendTemplateParts(self: *Store, values: []const TemplatePart) !Range {
        return appendRange(TemplatePart, self.allocator, &self.template_parts, values);
    }

    fn appendAnnotation(self: *Store, value: Annotation) !void {
        try self.annotations.append(self.allocator, value);
    }

    pub fn finishAnnotationOwner(
        self: *Store,
        annotation_index: u32,
        owner: AnnotationRuntimeOwner,
        view: ir.IrView,
    ) !void {
        if (@as(usize, annotation_index) >= self.annotations.items.len) {
            return error.InvalidAnnotationOwner;
        }
        const annotation = self.annotations.items[annotation_index];
        if (annotation.runtime_owner != null) return error.InvalidAnnotationOwner;
        try self.validateAnnotation(annotation);
        try self.validateAnnotationRuntimeOwner(annotation, owner, view);
        self.annotations.items[annotation_index].runtime_owner = owner;
    }

    pub fn node(self: *const Store, index: NodeIndex) ?Node {
        if (@as(usize, index) >= self.nodes.items.len) return null;
        return self.nodes.items[index];
    }

    pub fn memberSlice(self: *const Store, range: Range) ?[]const Child {
        return rangeSlice(Child, self.members.items, range);
    }

    pub fn fieldSlice(self: *const Store, range: Range) ?[]const Field {
        return rangeSlice(Field, self.fields.items, range);
    }

    pub fn paramSlice(self: *const Store, range: Range) ?[]const Parameter {
        return rangeSlice(Parameter, self.params.items, range);
    }

    pub fn templatePartSlice(self: *const Store, range: Range) ?[]const TemplatePart {
        return rangeSlice(TemplatePart, self.template_parts.items, range);
    }

    pub fn genericParameterSlice(self: *const Store, range: Range) ?[]const AuthoredGenericParameter {
        return rangeSlice(AuthoredGenericParameter, self.generic_parameters.items, range);
    }

    pub fn projectedGenericParameterSlice(self: *const Store, range: Range) ?[]const ProjectedGenericParameter {
        return rangeSlice(ProjectedGenericParameter, self.projected_generic_parameters.items, range);
    }

    pub fn semanticFragmentSlice(self: *const Store, range: Range) ?[]const SemanticFragment {
        return rangeSlice(SemanticFragment, self.semantic_fragments.items, range);
    }

    pub fn authoredCallArgumentSlice(self: *const Store, range: Range) ?[]const AuthoredCallArgument {
        return rangeSlice(AuthoredCallArgument, self.authored_call_arguments.items, range);
    }

    pub fn parameterAnnotationSlice(self: *const Store, range: Range) ?[]const ParameterAnnotation {
        return rangeSlice(ParameterAnnotation, self.parameter_annotations.items, range);
    }

    pub fn reserveGenericOwner(
        self: *Store,
        options: GenericOwnerOptions,
    ) !PendingGenericOwner {
        const previous = self.checkpoint();
        errdefer self.rollback(previous);
        try self.validateGenericListSpan(options.list_span);
        try self.validateOwnerCaptureSpans(options.list_span, options.capture_spans);

        const authored_start = std.math.cast(u32, self.generic_parameters.items.len) orelse
            return error.TooManyTypeItems;
        try appendAuthoredGenericParameters(self, options.list_span);
        const projection = try appendProjectedParametersWithBounds(
            self,
            projectedListBody(self.source, options.capture_spans.legacy_recorded_span),
            options.policy == .callable,
        );

        const compatibility: GenericOwnerCompatibility = switch (options.policy) {
            .structural, .callable => .declaration_parameters,
            .ignored => .ignored_declaration_parameters,
            .legacy_call => blk: {
                const argument_start = std.math.cast(u32, self.authored_call_arguments.items.len) orelse
                    return error.TooManyTypeItems;
                const fragment_start = std.math.cast(u32, self.semantic_fragments.items.len) orelse
                    return error.TooManyTypeItems;
                try appendAuthoredCallArguments(self, options.list_span);
                try appendProjectedCallFragments(self, options.capture_spans.legacy_recorded_span);
                break :blk .{ .legacy_call_arguments = .{
                    .authored_arguments = .{
                        .start = argument_start,
                        .count = @intCast(self.authored_call_arguments.items.len - argument_start),
                    },
                    .semantic_fragments = .{
                        .start = fragment_start,
                        .count = @intCast(self.semantic_fragments.items.len - fragment_start),
                    },
                } };
            },
        };

        const owner_index = std.math.cast(u32, self.generic_owners.items.len) orelse
            return error.TooManyTypeItems;
        try self.generic_owners.ensureUnusedCapacity(self.allocator, 1);
        self.generic_owners.appendAssumeCapacity(undefined);
        return .{
            .checkpoint = previous,
            .owner_index = owner_index,
            .list_span = options.list_span,
            .capture_spans = options.capture_spans,
            .authored_parameters = .{
                .start = authored_start,
                .count = @intCast(self.generic_parameters.items.len - authored_start),
            },
            .projected_parameters = projection.parameters,
            .compatibility = compatibility,
            .policy = options.policy,
        };
    }

    pub fn finishGenericOwner(
        self: *Store,
        pending: *PendingGenericOwner,
        final: GenericOwnerFinal,
    ) !void {
        if (!pending.active or @as(usize, pending.owner_index) >= self.generic_owners.items.len) {
            return error.InvalidGenericOwner;
        }
        const identity: GenericOwnerIdentity = switch (final) {
            .declaration => |declaration| switch (pending.policy) {
                .structural => if (declaration.kind == .structural)
                    .{ .structural_declaration = declaration.index }
                else
                    return error.InvalidGenericOwner,
                .ignored => if (declaration.kind == .nominal)
                    .{ .nominal_declaration = declaration.index }
                else
                    return error.InvalidGenericOwner,
                .callable, .legacy_call => return error.InvalidGenericOwner,
            },
            .runtime => |runtime| blk: {
                const tag = runtime.view.getTag(runtime.owner) orelse return error.InvalidGenericOwner;
                break :blk switch (pending.policy) {
                    .structural => return error.InvalidGenericOwner,
                    .callable => switch (tag) {
                        .function_expr => .{ .function = runtime.owner },
                        .arrow_function => .{ .arrow = runtime.owner },
                        else => return error.InvalidGenericOwner,
                    },
                    .ignored => if (tag == .function_expr)
                        .{ .function = runtime.owner }
                    else
                        return error.InvalidGenericOwner,
                    .legacy_call => switch (tag) {
                        .function_expr => .{ .function = runtime.owner },
                        .arrow_function => .{ .arrow = runtime.owner },
                        else => return error.InvalidGenericOwner,
                    },
                };
            },
        };
        const record: GenericOwner = .{
            .identity = identity,
            .list_span = pending.list_span,
            .capture_spans = pending.capture_spans,
            .authored_parameters = pending.authored_parameters,
            .projected_parameters = pending.projected_parameters,
            .compatibility = pending.compatibility,
        };
        switch (final) {
            .declaration => try self.validateGenericOwnerSyntax(record, pending.owner_index),
            .runtime => |runtime| try self.validateGenericOwnerRecord(
                record,
                pending.owner_index,
                runtime.view,
            ),
        }
        self.generic_owners.items[pending.owner_index] = record;
        pending.active = false;
    }

    pub fn cancelGenericOwner(self: *Store, pending: *PendingGenericOwner) void {
        if (!pending.active) return;
        self.rollback(pending.checkpoint);
        pending.active = false;
    }

    pub fn reserveExplicitCall(
        self: *Store,
        options: ExplicitCallOptions,
    ) !PendingExplicitCall {
        const previous = self.checkpoint();
        errdefer self.rollback(previous);
        try self.validateGenericListSpan(options.list_span);
        try self.validateOwnerCaptureSpans(options.list_span, options.capture_spans);

        const authored_start = std.math.cast(u32, self.authored_call_arguments.items.len) orelse
            return error.TooManyTypeItems;
        const projected_start = std.math.cast(u32, self.semantic_fragments.items.len) orelse
            return error.TooManyTypeItems;
        try appendAuthoredCallArguments(self, options.list_span);
        try appendProjectedCallFragments(self, options.capture_spans.legacy_recorded_span);

        const record_index = std.math.cast(u32, self.explicit_call_arguments.items.len) orelse
            return error.TooManyTypeItems;
        try self.explicit_call_arguments.ensureUnusedCapacity(self.allocator, 1);
        self.explicit_call_arguments.appendAssumeCapacity(undefined);
        return .{
            .checkpoint = previous,
            .record_index = record_index,
            .final_record = .{
                .owner = ir.null_node,
                .list_span = options.list_span,
                .capture_spans = options.capture_spans,
                .authored_arguments = .{
                    .start = authored_start,
                    .count = @intCast(self.authored_call_arguments.items.len - authored_start),
                },
                .semantic_fragments = .{
                    .start = projected_start,
                    .count = @intCast(self.semantic_fragments.items.len - projected_start),
                },
            },
        };
    }

    pub fn finishExplicitCall(
        self: *Store,
        pending: *PendingExplicitCall,
        owner: ir.NodeIndex,
        view: ir.IrView,
    ) !void {
        if (!pending.active or @as(usize, pending.record_index) >= self.explicit_call_arguments.items.len) {
            return error.InvalidGenericOwner;
        }
        var record = pending.final_record;
        record.owner = owner;
        try self.validateExplicitCallArgumentsRecord(record, view);
        self.explicit_call_arguments.items[pending.record_index] = record;
        pending.active = false;
    }

    pub fn cancelExplicitCall(self: *Store, pending: *PendingExplicitCall) void {
        if (!pending.active) return;
        self.rollback(pending.checkpoint);
        pending.active = false;
    }

    pub fn beginFunctionSignature(self: *Store) PendingFunctionSignature {
        return .{
            .checkpoint = self.checkpoint(),
            .parameter_start = self.parameter_annotations.items.len,
        };
    }

    pub fn appendParameterAnnotation(
        self: *Store,
        pending: *PendingFunctionSignature,
        value: ParameterAnnotation,
    ) !void {
        if (!pending.active or pending.reserved or
            pending.parameter_start > self.parameter_annotations.items.len)
        {
            return error.InvalidFunctionSignature;
        }
        try self.validateTypeValue(value.value);
        try self.parameter_annotations.append(self.allocator, value);
    }

    pub fn setFunctionReturn(
        self: *Store,
        pending: *PendingFunctionSignature,
        value: ReturnSyntax,
    ) !void {
        if (!pending.active or pending.reserved or pending.return_syntax != null) {
            return error.InvalidFunctionSignature;
        }
        try self.validateReturnSyntax(value);
        pending.return_syntax = value;
    }

    pub fn reserveFunctionSignature(
        self: *Store,
        pending: *PendingFunctionSignature,
        source_span: Span,
    ) !void {
        if (!pending.active or pending.reserved) {
            return error.InvalidFunctionSignature;
        }
        try self.validateSpan(source_span);
        pending.reserved = true;
        const parameter_count = self.parameter_annotations.items.len -
            pending.parameter_start;
        if (parameter_count == 0 and pending.return_syntax == null) return;
        const record_index = std.math.cast(u32, self.function_signatures.items.len) orelse
            return error.TooManyTypeItems;
        try self.function_signatures.ensureUnusedCapacity(self.allocator, 1);
        self.function_signatures.appendAssumeCapacity(undefined);
        pending.record_index = record_index;
        pending.final_record = .{
            .owner = ir.null_node,
            .parameters = .{
                .start = std.math.cast(u32, pending.parameter_start) orelse
                    return error.TooManyTypeItems,
                .count = std.math.cast(u32, parameter_count) orelse
                    return error.TooManyTypeItems,
            },
            .return_syntax = pending.return_syntax,
            .source_span = source_span,
        };
    }

    pub fn finishFunctionSignature(
        self: *Store,
        pending: *PendingFunctionSignature,
        owner: ir.NodeIndex,
        view: ir.IrView,
    ) !void {
        if (!pending.active or !pending.reserved) return error.InvalidFunctionSignature;
        if (pending.final_record == null) {
            pending.active = false;
            return;
        }
        const record_index = pending.record_index orelse return error.InvalidFunctionSignature;
        if (@as(usize, record_index) >= self.function_signatures.items.len) {
            return error.InvalidFunctionSignature;
        }
        var record = pending.final_record.?;
        record.owner = owner;
        try self.validateFunctionSignatureRecord(record, view);
        self.function_signatures.items[record_index] = record;
        pending.active = false;
    }

    pub fn cancelFunctionSignature(self: *Store, pending: *PendingFunctionSignature) void {
        if (!pending.active) return;
        self.rollback(pending.checkpoint);
        pending.active = false;
    }

    pub fn reserveErasedTypePrefix(
        self: *Store,
        options: ErasedTypePrefixOptions,
    ) !PendingErasedTypePrefix {
        const prior = self.checkpoint();
        errdefer self.rollback(prior);
        try self.validateErasedTypePrefixCaptureSpans(
            options.list_span,
            options.capture_spans,
        );
        const compatibility: ErasedTypePrefixCompatibility = switch (options.policy) {
            .ignored_parameters => .ignored_parameters,
            .legacy_parameter_projection => blk: {
                const projection = try appendProjectedParametersWithBounds(
                    self,
                    projectedListBody(self.source, options.capture_spans.legacy_recorded_span),
                    true,
                );
                break :blk .{ .legacy_parameter_projection = .{
                    .projected_parameters = projection.parameters,
                    .semantic_fragments = projection.fragments,
                } };
            },
        };
        const record_index = std.math.cast(u32, self.erased_type_prefixes.items.len) orelse
            return error.TooManyTypeItems;
        try self.erased_type_prefixes.ensureUnusedCapacity(self.allocator, 1);
        self.erased_type_prefixes.appendAssumeCapacity(undefined);
        return .{
            .checkpoint = prior,
            .record_index = record_index,
            .list_span = options.list_span,
            .capture_spans = options.capture_spans,
            .compatibility = compatibility,
        };
    }

    pub fn finishErasedTypePrefix(
        self: *Store,
        pending: *PendingErasedTypePrefix,
        final: ErasedTypePrefixFinal,
    ) !void {
        if (!pending.active or
            @as(usize, pending.record_index) >= self.erased_type_prefixes.items.len)
        {
            return error.InvalidErasedTypePrefix;
        }
        const record: ErasedTypePrefix = .{
            .list_span = pending.list_span,
            .capture_spans = pending.capture_spans,
            .operand_span = final.operand_span,
            .owner = final.owner,
            .compatibility = pending.compatibility,
        };
        try self.validateErasedTypePrefixRecord(record, final.view);
        self.erased_type_prefixes.items[pending.record_index] = record;
        pending.active = false;
    }

    pub fn cancelErasedTypePrefix(
        self: *Store,
        pending: *PendingErasedTypePrefix,
    ) void {
        if (!pending.active) return;
        self.rollback(pending.checkpoint);
        pending.active = false;
    }

    pub fn appendTypeOnlyModule(self: *Store, module: TypeOnlyModule) !void {
        try self.validateTypeOnlyModule(module);
        if (self.type_only_modules.items.len > 0) {
            const prior = self.type_only_modules.items[self.type_only_modules.items.len - 1].raw_span;
            if (prior.start >= module.raw_span.start or prior.end > module.raw_span.start) {
                return error.InvalidTypeSourceOrder;
            }
        }
        try self.type_only_modules.append(self.allocator, module);
    }

    pub fn validateFunctionDeclarationWrapper(
        self: *const Store,
        owner: ir.NodeIndex,
        wrapper: ir.NodeIndex,
        view: ir.IrView,
    ) !void {
        _ = self;
        if (view.getTag(wrapper) != .function_decl) return error.InvalidFunctionSignatureOwner;
        const declaration = view.getVarDecl(wrapper) orelse return error.InvalidFunctionSignatureOwner;
        if (declaration.init != owner) return error.InvalidFunctionSignatureOwner;
    }

    pub fn validateRuntimeOwners(
        self: *const Store,
        allocator: std.mem.Allocator,
        view: ir.IrView,
    ) !void {
        try self.validate();
        try self.validateSharedRangeOwners(allocator);
        const generic_owners = try allocator.alloc(u8, view.nodeCount());
        defer allocator.free(generic_owners);
        @memset(generic_owners, 0);
        const call_owners = try allocator.alloc(u8, view.nodeCount());
        defer allocator.free(call_owners);
        @memset(call_owners, 0);
        const signature_owners = try allocator.alloc(u8, view.nodeCount());
        defer allocator.free(signature_owners);
        @memset(signature_owners, 0);
        const parameter_owners = try allocator.alloc(u8, self.parameter_annotations.items.len);
        defer allocator.free(parameter_owners);
        @memset(parameter_owners, 0);
        const pattern_owners = try allocator.alloc(u8, view.nodeCount());
        defer allocator.free(pattern_owners);
        @memset(pattern_owners, 0);
        const annotation_owners = try allocator.alloc(u8, view.nodeCount());
        defer allocator.free(annotation_owners);
        @memset(annotation_owners, 0);

        for (self.annotations.items) |annotation| {
            const owner = annotation.runtime_owner orelse return error.InvalidAnnotationOwner;
            try self.validateAnnotationRuntimeOwner(annotation, owner, view);
            if (@as(usize, owner.declaration) >= annotation_owners.len or
                annotation_owners[owner.declaration] != 0)
            {
                return error.InvalidAnnotationOwner;
            }
            annotation_owners[owner.declaration] = 1;
        }

        for (self.generic_owners.items, 0..) |owner, owner_index| {
            try self.validateGenericOwnerRecord(owner, owner_index, view);
            const runtime_owner = switch (owner.identity) {
                .structural_declaration, .nominal_declaration => continue,
                .function => |runtime_node| runtime_node,
                .arrow => |runtime_node| runtime_node,
            };
            if (@as(usize, runtime_owner) >= generic_owners.len or
                generic_owners[runtime_owner] != 0)
            {
                return error.InvalidGenericOwner;
            }
            generic_owners[runtime_owner] = 1;
        }
        for (self.explicit_call_arguments.items) |arguments| {
            try self.validateExplicitCallArgumentsRecord(arguments, view);
            if (@as(usize, arguments.owner) >= call_owners.len or
                call_owners[arguments.owner] != 0)
            {
                return error.InvalidGenericOwner;
            }
            call_owners[arguments.owner] = 1;
        }
        for (self.function_signatures.items) |signature| {
            try self.validateFunctionSignatureRecord(signature, view);
            if (@as(usize, signature.owner) >= signature_owners.len or
                signature_owners[signature.owner] != 0)
            {
                return error.InvalidFunctionSignatureOwner;
            }
            signature_owners[signature.owner] = 1;
            const start: usize = signature.parameters.start;
            const end = std.math.add(usize, start, signature.parameters.count) catch
                return error.InvalidTypeRange;
            if (end > parameter_owners.len) return error.InvalidTypeRange;
            for (start..end) |parameter_index| {
                if (parameter_owners[parameter_index] != 0) {
                    return error.InvalidFunctionParameterOwner;
                }
                parameter_owners[parameter_index] = 1;
                const pattern = self.parameter_annotations.items[parameter_index].owner.pattern;
                if (@as(usize, pattern) >= pattern_owners.len or pattern_owners[pattern] != 0) {
                    return error.InvalidFunctionParameterOwner;
                }
                pattern_owners[pattern] = 1;
            }
        }
        for (parameter_owners) |claimed| {
            if (claimed != 1) return error.InvalidFunctionParameterOwner;
        }
        for (self.erased_type_prefixes.items) |prefix| {
            try self.validateErasedTypePrefixRecord(prefix, view);
        }
        try self.validateErasedPrefixRuntimeRelationships();
    }

    pub fn validateParsed(self: *const Store, root: Child, raw_span: Span) !void {
        try self.validateSpan(raw_span);
        for (self.nodes.items, 0..) |syntax_node, index| {
            try self.validateSpan(syntax_node.semantic_span);
            if (std.meta.activeTag(syntax_node.data) != syntax_node.tag) {
                return error.InvalidTypeNodeTag;
            }
            switch (syntax_node.data) {
                .primitive, .literal_number, .literal_bool => {},
                .named_reference => |span| try self.validateSpan(span),
                .generic_application => |application| {
                    try validateChild(application.base, index);
                    const arguments = self.memberSlice(application.arguments) orelse
                        return error.InvalidTypeRange;
                    for (arguments) |argument| try validateChild(argument, index);
                },
                .group => |group| {
                    try validateChild(group.child, index);
                    const parameters = self.paramSlice(group.attempted_params) orelse
                        return error.InvalidTypeRange;
                    for (parameters) |parameter| {
                        try self.validateSpan(parameter.span);
                        try self.validateSpan(parameter.name);
                        try validateChild(parameter.type_child, index);
                    }
                },
                .readonly_modifier => |child| try validateChild(child, index),
                .record => |range| {
                    const values = self.fieldSlice(range) orelse return error.InvalidTypeRange;
                    for (values) |field| {
                        try self.validateSpan(field.span);
                        try self.validateSpan(field.name);
                        try validateChild(field.type_child, index);
                    }
                },
                .array => |child| try validateChild(child, index),
                .tuple => |range| {
                    const values = self.memberSlice(range) orelse return error.InvalidTypeRange;
                    for (values) |child| try validateChild(child, index);
                },
                .function => |function| {
                    const values = self.paramSlice(function.params) orelse return error.InvalidTypeRange;
                    for (values) |parameter| {
                        try self.validateSpan(parameter.span);
                        try self.validateSpan(parameter.name);
                        try validateChild(parameter.type_child, index);
                    }
                    try validateChild(function.ret, index);
                },
                .union_type => |range| {
                    const values = self.memberSlice(range) orelse return error.InvalidTypeRange;
                    for (values) |child| try validateChild(child, index);
                },
                .intersection => |range| {
                    const values = self.memberSlice(range) orelse return error.InvalidTypeRange;
                    for (values) |child| try validateChild(child, index);
                },
                .literal_string => |span| try self.validateSpan(span),
                .template => |range| {
                    const values = self.templatePartSlice(range) orelse return error.InvalidTypeRange;
                    for (values) |part| switch (part) {
                        .literal => |span| try self.validateSpan(span),
                        .type_slot => |child| try validateChild(child, index),
                    };
                },
            }
        }
        var parameter_count: usize = 0;
        for (self.nodes.items, 0..) |syntax_node, index| {
            const parameter_range = parameterRange(syntax_node) orelse continue;
            const parameters = self.paramSlice(parameter_range) orelse
                return error.InvalidTypeRange;
            parameter_count = std.math.add(usize, parameter_count, parameters.len) catch
                return error.InvalidTypeRange;
            for (self.nodes.items[0..index]) |prior_node| {
                const prior_range = parameterRange(prior_node) orelse continue;
                if (rangesOverlap(parameter_range, prior_range)) {
                    return error.SharedTypeParameter;
                }
            }
        }
        if (parameter_count != self.params.items.len) return error.UnownedTypeParameter;
        try validateChild(root, self.nodes.items.len);
    }

    fn parameterRange(syntax_node: Node) ?Range {
        return switch (syntax_node.data) {
            .group => |group| group.attempted_params,
            .function => |function| function.params,
            else => null,
        };
    }

    pub fn validate(self: *const Store) !void {
        try self.validateParsed(.absent, .{ .start = 0, .end = 0 });
        for (self.annotations.items) |annotation| try self.validateAnnotation(annotation);
        for (self.declarations.items, 0..) |declaration, index| {
            try self.validateDeclaration(declaration);
            if (declaration.source_order != @as(u32, @intCast(index))) return error.InvalidTypeSourceOrder;
            if (index > 0 and self.declarations.items[index - 1].full_span.start > declaration.full_span.start) {
                return error.InvalidTypeSourceOrder;
            }
        }
        for (self.generic_parameters.items) |parameter| {
            try self.validateSpan(parameter.raw_span);
            try self.validateSpan(parameter.trimmed_span);
            if (!spanContains(parameter.raw_span, parameter.trimmed_span)) return error.InvalidTypeSpan;
            if (parameter.recognized) |recognized| {
                try self.validateRecognizedGenericParameter(parameter.trimmed_span, recognized);
            }
        }
        for (self.projected_generic_parameters.items) |parameter| {
            try self.validateSpan(parameter.raw_span);
            try self.validateSpan(parameter.name_span);
            if (!spanContains(parameter.raw_span, parameter.name_span)) return error.InvalidTypeSpan;
            if (parameter.legacy_bound_span) |span| {
                try self.validateSpan(span);
                if (!spanContains(parameter.raw_span, span)) return error.InvalidTypeSpan;
            }
            if (parameter.bound_fragment) |index| {
                if (@as(usize, index) >= self.semantic_fragments.items.len) {
                    return error.InvalidTypeRange;
                }
            }
        }
        for (self.semantic_fragments.items) |fragment| try self.validateSemanticFragment(fragment);
        for (self.generic_owners.items, 0..) |owner, index| try self.validateGenericOwnerSyntax(owner, index);
        for (self.authored_call_arguments.items) |argument| try self.validateSpan(argument.full_span);
        for (self.explicit_call_arguments.items) |arguments| try self.validateExplicitCallArgumentsSyntax(arguments);
        for (self.parameter_annotations.items) |parameter| try self.validateParameterAnnotation(parameter);
        for (self.function_signatures.items, 0..) |signature, index| {
            try self.validateFunctionSignatureSyntax(signature);
            if (index > 0 and
                self.function_signatures.items[index - 1].source_span.start >= signature.source_span.start)
            {
                return error.InvalidTypeSourceOrder;
            }
        }
        for (self.type_only_modules.items, 0..) |module, index| {
            try self.validateTypeOnlyModule(module);
            if (index > 0) {
                const prior = self.type_only_modules.items[index - 1].raw_span;
                if (prior.start >= module.raw_span.start or prior.end > module.raw_span.start) {
                    return error.InvalidTypeSourceOrder;
                }
            }
        }
        for (self.erased_type_prefixes.items, 0..) |prefix, index| {
            try self.validateErasedTypePrefix(prefix);
            if (index > 0 and
                self.erased_type_prefixes.items[index - 1].list_span.start >= prefix.list_span.start)
            {
                return error.InvalidTypeSourceOrder;
            }
        }
        try self.validateErasedPrefixOperandRelationships();
        try self.validateRecordOwnership();
        try self.validateOwnerRangesDoNotOverlap();
    }

    pub const ApplicationBasePlan = struct {
        allocator: std.mem.Allocator,
        uses: []u8,

        pub fn deinit(self: *ApplicationBasePlan) void {
            self.allocator.free(self.uses);
            self.* = undefined;
        }

        pub fn contains(self: *const ApplicationBasePlan, index: usize) bool {
            return index < self.uses.len and self.uses[index] == 1;
        }
    };

    pub fn planApplicationBases(
        self: *const Store,
        allocator: std.mem.Allocator,
    ) !ApplicationBasePlan {
        if (self.hasRuntimeOwnedRecords()) return error.RuntimeOwnerRequired;
        try self.validate();
        try self.validateSharedRangeOwners(allocator);
        return self.planApplicationBasesValidated(allocator);
    }

    pub fn planApplicationBasesWithIr(
        self: *const Store,
        allocator: std.mem.Allocator,
        view: ir.IrView,
    ) !ApplicationBasePlan {
        try self.validateRuntimeOwners(allocator, view);
        return self.planApplicationBasesValidated(allocator);
    }

    fn hasRuntimeOwnedRecords(self: *const Store) bool {
        if (self.explicit_call_arguments.items.len != 0 or
            self.function_signatures.items.len != 0 or
            self.parameter_annotations.items.len != 0 or
            self.erased_type_prefixes.items.len != 0)
        {
            return true;
        }
        for (self.generic_owners.items) |owner| switch (owner.identity) {
            .function, .arrow => return true,
            .structural_declaration, .nominal_declaration => {},
        };
        for (self.annotations.items) |annotation| {
            if (annotation.runtime_owner != null) return true;
        }
        return false;
    }

    fn planApplicationBasesValidated(
        self: *const Store,
        allocator: std.mem.Allocator,
    ) !ApplicationBasePlan {
        const base_uses = try allocator.alloc(u8, self.nodes.items.len);
        errdefer allocator.free(base_uses);
        @memset(base_uses, 0);
        const ordinary_uses = try allocator.alloc(bool, self.nodes.items.len);
        defer allocator.free(ordinary_uses);
        @memset(ordinary_uses, false);

        for (self.annotations.items) |annotation| {
            try self.validateApplicationBasesForOwner(
                annotation.root,
                annotation.node_range,
                base_uses,
                ordinary_uses,
            );
        }
        for (self.declarations.items) |declaration| switch (declaration.body) {
            .absent => {},
            .present => |body| try self.validateApplicationBasesForOwner(
                body.root,
                body.node_range,
                base_uses,
                ordinary_uses,
            ),
        };
        for (self.semantic_fragments.items) |fragment| {
            try self.validateApplicationBasesForOwner(
                fragment.root,
                fragment.node_range,
                base_uses,
                ordinary_uses,
            );
        }
        for (self.parameter_annotations.items) |parameter| {
            try self.validateApplicationBasesForTypeValue(
                parameter.value,
                base_uses,
                ordinary_uses,
            );
        }
        for (self.function_signatures.items) |signature| {
            if (signature.return_syntax) |return_syntax| {
                try self.validateApplicationBasesForReturn(
                    return_syntax,
                    base_uses,
                    ordinary_uses,
                );
            }
        }
        return .{ .allocator = allocator, .uses = base_uses };
    }

    fn validateApplicationBasesForTypeValue(
        self: *const Store,
        value: TypeValue,
        base_uses: []u8,
        ordinary_uses: []bool,
    ) !void {
        try self.validateApplicationBasesForOwner(
            value.root,
            value.node_range,
            base_uses,
            ordinary_uses,
        );
    }

    fn validateApplicationBasesForReturn(
        self: *const Store,
        value: ReturnSyntax,
        base_uses: []u8,
        ordinary_uses: []bool,
    ) !void {
        switch (value.structure) {
            .value => |type_value| try self.validateApplicationBasesForTypeValue(
                type_value,
                base_uses,
                ordinary_uses,
            ),
            .predicate => |predicate| try self.validateApplicationBasesForTypeValue(
                predicate.narrowed,
                base_uses,
                ordinary_uses,
            ),
        }
        if (value.legacy_ordinary_prefix) |compatibility| {
            try self.validateApplicationBasesForTypeValue(
                compatibility,
                base_uses,
                ordinary_uses,
            );
        }
    }

    fn validateSharedRangeOwners(
        self: *const Store,
        allocator: std.mem.Allocator,
    ) !void {
        const argument_owners = try allocator.alloc(u8, self.authored_call_arguments.items.len);
        defer allocator.free(argument_owners);
        @memset(argument_owners, 0);
        const fragment_owners = try allocator.alloc(u8, self.semantic_fragments.items.len);
        defer allocator.free(fragment_owners);
        @memset(fragment_owners, 0);
        const prefix_fragment_references = try allocator.alloc(u8, self.semantic_fragments.items.len);
        defer allocator.free(prefix_fragment_references);
        @memset(prefix_fragment_references, 0);

        for (self.generic_owners.items) |owner| {
            const projected = self.projectedGenericParameterSlice(owner.projected_parameters) orelse
                return error.InvalidTypeRange;
            for (projected) |parameter| {
                if (parameter.bound_fragment) |fragment_index| {
                    try claimSemanticFragment(fragment_owners, fragment_index);
                }
            }
            switch (owner.compatibility) {
                .declaration_parameters, .ignored_declaration_parameters => {},
                .legacy_call_arguments => |arguments| {
                    try claimRange(argument_owners, arguments.authored_arguments, error.SharedAuthoredCallArgument);
                    try claimRange(fragment_owners, arguments.semantic_fragments, error.SharedSemanticFragment);
                },
            }
        }
        for (self.explicit_call_arguments.items) |arguments| {
            try claimRange(argument_owners, arguments.authored_arguments, error.SharedAuthoredCallArgument);
            try claimRange(fragment_owners, arguments.semantic_fragments, error.SharedSemanticFragment);
        }
        for (self.erased_type_prefixes.items) |prefix| switch (prefix.compatibility) {
            .ignored_parameters => {},
            .legacy_parameter_projection => |projection| {
                try claimRange(
                    fragment_owners,
                    projection.semantic_fragments,
                    error.SharedSemanticFragment,
                );
                const parameters = self.projectedGenericParameterSlice(projection.projected_parameters) orelse
                    return error.InvalidTypeRange;
                for (parameters) |parameter| if (parameter.bound_fragment) |fragment_index| {
                    if (@as(usize, fragment_index) >= prefix_fragment_references.len or
                        prefix_fragment_references[fragment_index] != 0)
                    {
                        return error.SharedSemanticFragment;
                    }
                    prefix_fragment_references[fragment_index] = 1;
                };
                const fragment_start: usize = projection.semantic_fragments.start;
                const fragment_end = std.math.add(
                    usize,
                    fragment_start,
                    projection.semantic_fragments.count,
                ) catch return error.InvalidTypeRange;
                if (fragment_end > prefix_fragment_references.len) return error.InvalidTypeRange;
                for (prefix_fragment_references[fragment_start..fragment_end]) |reference_count| {
                    if (reference_count != 1) return error.UnownedSemanticFragment;
                }
            },
        };
        for (argument_owners) |owner_count| {
            if (owner_count == 0) return error.UnownedAuthoredCallArgument;
        }
        for (fragment_owners) |owner_count| {
            if (owner_count == 0) return error.UnownedSemanticFragment;
        }
    }

    fn validateApplicationBasesForOwner(
        self: *const Store,
        root: Child,
        owner: Range,
        base_uses: []u8,
        ordinary_uses: []bool,
    ) !void {
        markOrdinaryUse(root, ordinary_uses);
        const start: usize = owner.start;
        const end: usize = start + owner.count;
        for (self.nodes.items[start..end]) |syntax_node| switch (syntax_node.data) {
            .primitive, .named_reference, .literal_string, .literal_number, .literal_bool => {},
            .generic_application => |application| {
                markApplicationBaseUse(application.base, base_uses);
                const arguments = self.memberSlice(application.arguments) orelse
                    return error.InvalidTypeRange;
                for (arguments) |argument| markOrdinaryUse(argument, ordinary_uses);
            },
            .group => |group| {
                const parameters = self.paramSlice(group.attempted_params) orelse
                    return error.InvalidTypeRange;
                for (parameters) |parameter| markOrdinaryUse(parameter.type_child, ordinary_uses);
                markOrdinaryUse(group.child, ordinary_uses);
            },
            .readonly_modifier => |child| markOrdinaryUse(child, ordinary_uses),
            .record => |range| {
                const fields = self.fieldSlice(range) orelse return error.InvalidTypeRange;
                for (fields) |field| markOrdinaryUse(field.type_child, ordinary_uses);
            },
            .array => |child| markOrdinaryUse(child, ordinary_uses),
            .tuple => |range| {
                const members = self.memberSlice(range) orelse return error.InvalidTypeRange;
                for (members) |child| markOrdinaryUse(child, ordinary_uses);
            },
            .function => |function| {
                const params = self.paramSlice(function.params) orelse return error.InvalidTypeRange;
                for (params) |parameter| markOrdinaryUse(parameter.type_child, ordinary_uses);
                markOrdinaryUse(function.ret, ordinary_uses);
            },
            .union_type, .intersection => |range| {
                const members = self.memberSlice(range) orelse return error.InvalidTypeRange;
                for (members) |child| markOrdinaryUse(child, ordinary_uses);
            },
            .template => |range| {
                const parts = self.templatePartSlice(range) orelse return error.InvalidTypeRange;
                for (parts) |part| switch (part) {
                    .literal => {},
                    .type_slot => |child| markOrdinaryUse(child, ordinary_uses),
                };
            },
        };

        for (self.nodes.items[start..end]) |syntax_node| switch (syntax_node.data) {
            .generic_application => |application| {
                const base_index = switch (application.base) {
                    .absent => return error.InvalidGenericApplicationBase,
                    .present => |index| @as(usize, index),
                };
                if (base_uses[base_index] != 1) return error.SharedGenericApplicationBase;
                if (ordinary_uses[base_index]) return error.InvalidGenericApplicationBase;
                if (self.nodes.items[base_index].tag != .named_reference) {
                    return error.InvalidGenericApplicationBase;
                }
            },
            else => {},
        };
    }

    fn validateAnnotation(self: *const Store, annotation: Annotation) !void {
        try self.validateSpan(annotation.raw_span);
        try self.validateNodeRange(annotation.node_range);
        if (annotation.admission_end < annotation.raw_span.end or
            @as(usize, annotation.admission_end) > self.source.len or
            annotation.semantic_prefix_end < annotation.raw_span.start or
            annotation.semantic_prefix_end > annotation.raw_span.end)
        {
            return error.InvalidTypeSpan;
        }
        try validateChild(annotation.root, self.nodes.items.len);
        try validateOwnedChild(annotation.root, annotation.node_range);
        try self.validateOwnedNodes(annotation.node_range, annotation.raw_span);
    }

    fn validateAnnotationRuntimeOwner(
        self: *const Store,
        annotation: Annotation,
        owner: AnnotationRuntimeOwner,
        view: ir.IrView,
    ) !void {
        if (@as(usize, owner.declaration_start) >= self.source.len or
            owner.declaration_start >= annotation.raw_span.start)
        {
            return error.InvalidAnnotationOwner;
        }
        const tag = view.getTag(owner.declaration) orelse return error.InvalidAnnotationOwner;
        if (tag != .var_decl) return error.InvalidAnnotationOwner;
        const location = view.getLoc(owner.declaration) orelse return error.InvalidAnnotationOwner;
        if (location.offset != owner.declaration_start) return error.InvalidAnnotationOwner;
        const declaration = view.getVarDecl(owner.declaration) orelse return error.InvalidAnnotationOwner;
        if (!std.meta.eql(declaration.binding, annotation.binding)) {
            return error.InvalidAnnotationOwner;
        }
    }

    fn validateTypeValue(self: *const Store, value: TypeValue) !void {
        try self.validateSpan(value.raw_span);
        try self.validateNodeRange(value.node_range);
        if (value.admission_end < value.raw_span.end or
            @as(usize, value.admission_end) > self.source.len or
            value.semantic_prefix_end < value.raw_span.start or
            value.semantic_prefix_end > value.raw_span.end)
        {
            return error.InvalidTypeSpan;
        }
        try validateChild(value.root, self.nodes.items.len);
        try validateOwnedChild(value.root, value.node_range);
        try self.validateOwnedNodes(value.node_range, value.raw_span);
    }

    fn validateParameterAnnotation(self: *const Store, parameter: ParameterAnnotation) !void {
        if (parameter.owner.pattern == ir.null_node) return error.InvalidFunctionParameterOwner;
        try self.validateTypeValue(parameter.value);
    }

    fn validateTypeOnlyModule(self: *const Store, module: TypeOnlyModule) !void {
        try self.validateSpan(module.raw_span);
        var diagnostics: std.ArrayListUnmanaged(TypeOnlyModuleDiagnostic) = .empty;
        defer diagnostics.deinit(self.allocator);
        const scanned = (try scanRawTypeOnlyModule(
            self.allocator,
            self.source,
            module.raw_span.start,
            module.kind,
            &diagnostics,
        )) orelse return error.InvalidTypeOnlyModule;
        if (scanned.refused or !std.meta.eql(scanned.module, module)) {
            return error.InvalidTypeOnlyModule;
        }
    }

    fn validateReturnSyntax(self: *const Store, value: ReturnSyntax) !void {
        try self.validateSpan(value.raw_span);
        const expected_kind: LegacyReturnKind = if (hasLegacyGuardFacet(self.source, value.raw_span))
            .type_guard
        else
            .ordinary;
        if (value.legacy_return_kind != expected_kind) return error.InvalidReturnSyntax;
        switch (value.structure) {
            .value => |type_value| {
                if (!std.meta.eql(value.raw_span, type_value.raw_span)) return error.InvalidTypeSpan;
                try self.validateTypeValue(type_value);
                if (value.legacy_ordinary_prefix != null) return error.InvalidReturnSyntax;
            },
            .predicate => |predicate| {
                try self.validateSpan(predicate.target_span);
                const header = predicateHeader(self.source, value.raw_span) orelse
                    return error.InvalidReturnSyntax;
                if (!std.meta.eql(header.target_span, predicate.target_span) or
                    !std.meta.eql(header.narrowed_span, predicate.narrowed.raw_span))
                {
                    return error.InvalidReturnSyntax;
                }
                const empty_narrowing = childIsAbsent(predicate.narrowed.root);
                const whitespace_tail = spanContainsOnlyTypeWhitespace(
                    self.source,
                    header.narrowed_span,
                );
                if (empty_narrowing != whitespace_tail or
                    (empty_narrowing and
                        (predicate.narrowed.node_range.count != 0 or
                            predicate.narrowed.admission_end != value.raw_span.end or
                            predicate.narrowed.semantic_prefix_end != header.narrowed_span.end)))
                {
                    return error.InvalidReturnSyntax;
                }
                try self.validateTypeValue(predicate.narrowed);
                if (value.legacy_return_kind == .ordinary and value.legacy_ordinary_prefix == null) {
                    return error.InvalidReturnSyntax;
                }
                if (value.legacy_return_kind == .type_guard and value.legacy_ordinary_prefix != null) {
                    return error.InvalidReturnSyntax;
                }
            },
        }
        if (value.legacy_ordinary_prefix) |compatibility| {
            try self.validateTypeValue(compatibility);
            if (!std.meta.eql(value.raw_span, compatibility.raw_span)) return error.InvalidTypeSpan;
        }
    }

    fn validateFunctionSignatureSyntax(self: *const Store, signature: FunctionSignature) !void {
        try self.validateSpan(signature.source_span);
        if (signature.source_span.start == signature.source_span.end or
            self.source[signature.source_span.start] != '(')
        {
            return error.InvalidTypeSpan;
        }
        const parameters = self.parameterAnnotationSlice(signature.parameters) orelse
            return error.InvalidTypeRange;
        for (parameters) |parameter| {
            try self.validateParameterAnnotation(parameter);
            if (!spanContains(signature.source_span, parameter.value.raw_span)) {
                return error.InvalidTypeSpan;
            }
        }
        if (signature.return_syntax) |return_syntax| {
            try self.validateReturnSyntax(return_syntax);
            if (!spanContains(signature.source_span, return_syntax.raw_span)) {
                return error.InvalidTypeSpan;
            }
        }
    }

    fn validateFunctionSignatureRecord(
        self: *const Store,
        signature: FunctionSignature,
        view: ir.IrView,
    ) !void {
        try self.validateFunctionSignatureSyntax(signature);
        const owner_tag = view.getTag(signature.owner) orelse
            return error.InvalidFunctionSignatureOwner;
        if (owner_tag != .function_expr and owner_tag != .arrow_function) {
            return error.InvalidFunctionSignatureOwner;
        }
        const owner_location = view.getLoc(signature.owner) orelse
            return error.InvalidFunctionSignatureOwner;
        if (owner_location.offset != signature.source_span.start) {
            return error.InvalidFunctionSignatureOwner;
        }
        const function = view.getFunction(signature.owner) orelse
            return error.InvalidFunctionSignatureOwner;
        const parameters = self.parameterAnnotationSlice(signature.parameters) orelse
            return error.InvalidTypeRange;
        for (parameters) |parameter| {
            const pattern_tag = view.getTag(parameter.owner.pattern) orelse
                return error.InvalidFunctionParameterOwner;
            if (pattern_tag != .pattern_element) return error.InvalidFunctionParameterOwner;
            const binding = view.paramBinding(parameter.owner.pattern) orelse
                return error.InvalidFunctionParameterOwner;
            if (!std.meta.eql(binding, parameter.owner.binding)) {
                return error.InvalidFunctionParameterOwner;
            }
            const parameter_location = view.getLoc(parameter.owner.pattern) orelse
                return error.InvalidFunctionParameterOwner;
            if (parameter_location.offset < signature.source_span.start or
                parameter_location.offset >= parameter.value.raw_span.start)
            {
                return error.InvalidFunctionParameterOwner;
            }
            var actual_position: ?u16 = null;
            for (0..function.params_count) |offset| {
                if (view.getListIndex(function.params_start, @intCast(offset)) == parameter.owner.pattern) {
                    actual_position = @intCast(offset);
                    break;
                }
            }
            const position = actual_position orelse return error.InvalidFunctionParameterOwner;
            const annotation_bound = if (position + 1 < function.params_count) blk: {
                const next_pattern = view.getListIndex(function.params_start, position + 1);
                const next_tag = view.getTag(next_pattern) orelse
                    return error.InvalidFunctionParameterOwner;
                if (next_tag != .pattern_element) return error.InvalidFunctionParameterOwner;
                const next_location = view.getLoc(next_pattern) orelse
                    return error.InvalidFunctionParameterOwner;
                break :blk next_location.offset;
            } else signature.source_span.end;
            if (parameter.value.raw_span.end > annotation_bound) {
                return error.InvalidFunctionParameterOwner;
            }
        }
        if (signature.return_syntax) |return_syntax| switch (return_syntax.structure) {
            .value => {},
            .predicate => |predicate| try self.validatePredicateTarget(
                predicate,
                function.params_start,
                function.params_count,
                view,
            ),
        };
    }

    fn validatePredicateTarget(
        self: *const Store,
        predicate: PredicateSyntax,
        params_start: ir.NodeIndex,
        params_count: u8,
        view: ir.IrView,
    ) !void {
        var matching_pattern: ?ir.NodeIndex = null;
        var matching_binding: ?BindingRef = null;
        for (0..params_count) |offset| {
            const pattern = view.getListIndex(params_start, @intCast(offset));
            const tag = view.getTag(pattern) orelse return error.InvalidPredicateTarget;
            if (tag != .pattern_element) return error.InvalidPredicateTarget;
            const binding = view.paramBinding(pattern) orelse return error.InvalidPredicateTarget;
            const location = view.getLoc(pattern) orelse return error.InvalidPredicateTarget;
            const name_start: usize = location.offset;
            if (name_start >= self.source.len or !isIdentifierStart(self.source[name_start])) {
                return error.InvalidPredicateTarget;
            }
            var name_end = name_start + 1;
            while (name_end < self.source.len and isIdentifierContinue(self.source[name_end])) {
                name_end += 1;
            }
            if (std.mem.eql(u8, self.source[name_start..name_end], predicate.target_span.text(self.source))) {
                matching_pattern = pattern;
                matching_binding = binding;
                break;
            }
        }
        switch (predicate.target) {
            .unresolved => if (matching_pattern != null) return error.InvalidPredicateTarget,
            .resolved => |target| {
                const pattern = matching_pattern orelse return error.InvalidPredicateTarget;
                const binding = matching_binding orelse return error.InvalidPredicateTarget;
                if (target.pattern != pattern or !std.meta.eql(target.binding, binding)) {
                    return error.InvalidPredicateTarget;
                }
                const tag = view.getTag(target.pattern) orelse return error.InvalidPredicateTarget;
                if (tag != .pattern_element) return error.InvalidPredicateTarget;
                const actual_binding = view.paramBinding(target.pattern) orelse
                    return error.InvalidPredicateTarget;
                if (!std.meta.eql(actual_binding, target.binding)) return error.InvalidPredicateTarget;
            },
        }
    }

    fn validateErasedTypePrefix(self: *const Store, prefix: ErasedTypePrefix) !void {
        try self.validateErasedTypePrefixCaptureSpans(
            prefix.list_span,
            prefix.capture_spans,
        );
        try self.validateSpan(prefix.operand_span);
        if (@as(usize, prefix.operand_span.start) >= self.source.len) {
            return error.InvalidErasedTypePrefix;
        }
        const opener = self.source[prefix.operand_span.start];
        const closer: u8 = switch (opener) {
            '{' => '}',
            '(' => ')',
            else => return error.InvalidErasedTypePrefix,
        };
        const operand_end = scanErasedPrefixOperandEnd(
            self.source,
            prefix.operand_span.start,
            opener,
        ) orelse return error.InvalidErasedTypePrefix;
        const assignment_capture = std.meta.eql(
            prefix.capture_spans.actual_erased_span,
            prefix.list_span,
        );
        const general_capture = prefix.capture_spans.actual_erased_span.end ==
            prefix.operand_span.start;
        if (prefix.list_span.end > prefix.operand_span.start or
            !containsOnlyTypeWhitespace(
                self.source,
                prefix.list_span.end,
                prefix.operand_span.start,
            ) or
            prefix.operand_span.end - prefix.operand_span.start < 2 or
            self.source[prefix.operand_span.end - 1] != closer or
            operand_end != prefix.operand_span.end)
        {
            return error.InvalidErasedTypePrefix;
        }
        switch (prefix.compatibility) {
            .ignored_parameters => {
                if (opener != '{' or !general_capture) return error.InvalidErasedTypePrefix;
            },
            .legacy_parameter_projection => |projection| {
                if (opener != '(' or (!assignment_capture and !general_capture)) {
                    return error.InvalidErasedTypePrefix;
                }
                const parameters = self.projectedGenericParameterSlice(projection.projected_parameters) orelse
                    return error.InvalidTypeRange;
                const fragments = self.semanticFragmentSlice(projection.semantic_fragments) orelse
                    return error.InvalidTypeRange;
                if (parameters.len > 8 or fragments.len > 8) return error.InvalidTypeRange;
                for (parameters) |parameter| {
                    if (!spanContains(prefix.capture_spans.legacy_recorded_span, parameter.raw_span)) {
                        return error.InvalidErasedTypePrefix;
                    }
                    if (parameter.bound_fragment) |fragment_index| {
                        const fragment_end = std.math.add(
                            u32,
                            projection.semantic_fragments.start,
                            projection.semantic_fragments.count,
                        ) catch return error.InvalidTypeRange;
                        if (fragment_index < projection.semantic_fragments.start or
                            fragment_index >= fragment_end)
                        {
                            return error.InvalidErasedTypePrefix;
                        }
                        const fragment = self.semantic_fragments.items[fragment_index];
                        const bound_span = parameter.legacy_bound_span orelse
                            return error.InvalidErasedTypePrefix;
                        if (!std.meta.eql(fragment.raw_span, bound_span)) {
                            return error.InvalidErasedTypePrefix;
                        }
                    }
                }
            },
        }
    }

    fn validateErasedTypePrefixCaptureSpans(
        self: *const Store,
        list_span: Span,
        capture_spans: GenericCaptureSpans,
    ) !void {
        try self.validateGenericListSpan(list_span);
        try self.validateOwnerCaptureSpans(list_span, capture_spans);
        const legacy_start = std.math.add(u32, list_span.start, 1) catch
            return error.InvalidErasedTypePrefix;
        const legacy_end = list_span.end - 1;
        const assignment_capture = std.meta.eql(capture_spans.actual_erased_span, list_span) and
            capture_spans.legacy_recorded_span.start == legacy_start and
            capture_spans.legacy_recorded_span.end == legacy_end;
        const legacy_projected_end = std.math.add(
            u32,
            capture_spans.legacy_recorded_span.end,
            1,
        ) catch return error.InvalidErasedTypePrefix;
        const general_capture = capture_spans.actual_erased_span.start == list_span.start and
            capture_spans.actual_erased_span.end >= list_span.end and
            capture_spans.legacy_recorded_span.start == legacy_start and
            legacy_projected_end == capture_spans.actual_erased_span.end and
            containsOnlyTypeWhitespace(
                self.source,
                list_span.end,
                capture_spans.actual_erased_span.end,
            );
        if (!assignment_capture and !general_capture) return error.InvalidErasedTypePrefix;
    }

    fn validateErasedTypePrefixRecord(
        self: *const Store,
        prefix: ErasedTypePrefix,
        view: ir.IrView,
    ) !void {
        try self.validateErasedTypePrefix(prefix);
        const owner, const is_block = switch (prefix.owner) {
            .expression => |runtime_node| .{ runtime_node, false },
            .block => |runtime_node| .{ runtime_node, true },
        };
        const tag = view.getTag(owner) orelse return error.InvalidErasedTypePrefix;
        if (is_block) {
            if (tag != .block or self.source[prefix.operand_span.start] != '{') {
                return error.InvalidErasedTypePrefix;
            }
        } else if (!isErasedPrefixExpressionTag(tag)) {
            return error.InvalidErasedTypePrefix;
        }
        const location = view.getLoc(owner) orelse return error.InvalidErasedTypePrefix;
        if (is_block) {
            if (location.offset != prefix.operand_span.start) return error.InvalidErasedTypePrefix;
        } else if (self.source[prefix.operand_span.start] == '{') {
            if (tag != .object_literal or location.offset != prefix.operand_span.start) {
                return error.InvalidErasedTypePrefix;
            }
        } else if (location.offset <= prefix.operand_span.start or
            location.offset >= prefix.operand_span.end - 1)
        {
            return error.InvalidErasedTypePrefix;
        }
    }

    fn validateErasedPrefixOperandRelationships(self: *const Store) !void {
        for (self.erased_type_prefixes.items, 0..) |left, left_index| {
            for (self.erased_type_prefixes.items[left_index + 1 ..]) |right| {
                if (!spansOverlap(left.operand_span, right.operand_span)) continue;
                if (!spanStrictlyContains(left.operand_span, right.operand_span) and
                    !spanStrictlyContains(right.operand_span, left.operand_span))
                {
                    return error.InvalidErasedTypePrefix;
                }
            }
        }
    }

    fn validateErasedPrefixRuntimeRelationships(self: *const Store) !void {
        for (self.erased_type_prefixes.items, 0..) |left, left_index| {
            const left_owner = switch (left.owner) {
                .expression => |runtime_node| runtime_node,
                .block => continue,
            };
            for (self.erased_type_prefixes.items[left_index + 1 ..]) |right| {
                const right_owner = switch (right.owner) {
                    .expression => |runtime_node| runtime_node,
                    .block => continue,
                };
                if (left_owner != right_owner) continue;
                const outer, const inner = if (spanStrictlyContains(left.operand_span, right.operand_span))
                    .{ left, right }
                else if (spanStrictlyContains(right.operand_span, left.operand_span))
                    .{ right, left }
                else
                    return error.InvalidErasedTypePrefix;
                if (self.source[outer.operand_span.start] != '(' or
                    !spanContains(outer.operand_span, inner.capture_spans.actual_erased_span))
                {
                    return error.InvalidErasedTypePrefix;
                }
            }
        }
    }

    fn scanErasedPrefixOperandEnd(
        source: []const u8,
        operand_start: u32,
        opener: u8,
    ) ?u32 {
        if (@as(usize, operand_start) >= source.len) return null;
        const local_source = source[operand_start..];
        var cursor = Cursor.init(local_source);
        const opener_type: TokenType = switch (opener) {
            '{' => .lbrace,
            '(' => .lparen,
            else => return null,
        };
        const closer_type: TokenType = switch (opener) {
            '{' => .rbrace,
            '(' => .rparen,
            else => return null,
        };
        if (cursor.current.type != opener_type or cursor.current.start != 0) return null;
        var depth: u16 = 0;
        while (cursor.current.type != .eof) {
            if (cursor.current.type == opener_type) {
                if (depth == max_type_depth) return null;
                depth += 1;
            } else if (cursor.current.type == closer_type) {
                if (depth == 0) return null;
                depth -= 1;
                if (depth == 0) {
                    const local_end = std.math.add(
                        u32,
                        cursor.current.start,
                        cursor.current.len,
                    ) catch return null;
                    return std.math.add(u32, operand_start, local_end) catch null;
                }
            }
            cursor.advance();
        }
        return null;
    }

    fn isErasedPrefixExpressionTag(tag: ir.NodeTag) bool {
        return switch (tag) {
            .lit_int,
            .lit_float,
            .lit_string,
            .lit_bool,
            .lit_null,
            .lit_undefined,
            .identifier,
            .binary_op,
            .unary_op,
            .ternary,
            .call,
            .method_call,
            .member_access,
            .computed_access,
            .optional_chain,
            .assignment,
            .array_literal,
            .object_literal,
            .function_expr,
            .arrow_function,
            .sequence_expr,
            .comma_expr,
            .match_expr,
            => true,
            else => false,
        };
    }

    fn validateDeclaration(self: *const Store, declaration: Declaration) !void {
        if (declaration.export_span) |span| try self.validateSpan(span);
        try self.validateSpan(declaration.keyword_span);
        try self.validateSpan(declaration.name_span);
        if (declaration.equals_span) |span| try self.validateSpan(span);
        if (declaration.terminator_span) |span| try self.validateSpan(span);
        try self.validateSpan(declaration.full_span);
        if (declaration.full_span.start != if (declaration.export_span) |span| span.start else declaration.keyword_span.start) {
            return error.InvalidTypeSpan;
        }
        if (!spanContains(declaration.full_span, declaration.keyword_span) or
            !spanContains(declaration.full_span, declaration.name_span) or
            declaration.keyword_span.end > declaration.name_span.start)
        {
            return error.InvalidTypeSpan;
        }
        if (declaration.export_span) |span| {
            if (!spanContains(declaration.full_span, span) or span.end > declaration.keyword_span.start) {
                return error.InvalidTypeSpan;
            }
        }
        if (declaration.equals_span) |span| {
            if (!spanContains(declaration.full_span, span) or declaration.name_span.end > span.start) {
                return error.InvalidTypeSpan;
            }
        }
        if (declaration.terminator_span) |span| {
            if (!spanContains(declaration.full_span, span) or span.end != declaration.full_span.end) {
                return error.InvalidTypeSpan;
            }
        }
        if (declaration.generic_owner) |owner_index| {
            if (@as(usize, owner_index) >= self.generic_owners.items.len) return error.InvalidTypeRange;
            const owner = self.generic_owners.items[owner_index];
            const owner_kind, const declaration_index = switch (owner.identity) {
                .structural_declaration => |index| .{ DeclarationKind.structural, index },
                .nominal_declaration => |index| .{ DeclarationKind.nominal, index },
                else => return error.InvalidGenericOwner,
            };
            if (owner_kind != declaration.kind or
                declaration_index != declaration.source_order or
                !spanContains(declaration.full_span, owner.list_span) or
                declaration.name_span.end > owner.list_span.start)
            {
                return error.InvalidGenericOwner;
            }
        }
        switch (declaration.body) {
            .absent => {},
            .present => |body| {
                try self.validateSpan(body.raw_span);
                try self.validateNodeRange(body.node_range);
                if (body.admission_end < body.raw_span.end or
                    @as(usize, body.admission_end) > self.source.len or
                    body.semantic_prefix_end < body.raw_span.start or
                    body.semantic_prefix_end > body.raw_span.end)
                {
                    return error.InvalidTypeSpan;
                }
                if (!spanContains(declaration.full_span, body.raw_span) or
                    body.admission_end > declaration.full_span.end or
                    (declaration.equals_span == null or declaration.equals_span.?.end > body.raw_span.start))
                {
                    return error.InvalidTypeSpan;
                }
                try validateChild(body.root, self.nodes.items.len);
                try validateOwnedChild(body.root, body.node_range);
                try self.validateOwnedNodes(body.node_range, body.raw_span);
            },
        }
    }

    fn validateRecognizedGenericParameter(
        self: *const Store,
        owner: Span,
        parameter: RecognizedGenericParameter,
    ) !void {
        try self.validateSpan(parameter.name_span);
        if (!spanContains(owner, parameter.name_span)) return error.InvalidTypeSpan;
        inline for (.{ parameter.extends_span, parameter.constraint_span, parameter.equals_span, parameter.default_span }) |maybe_span| {
            if (maybe_span) |span| {
                try self.validateSpan(span);
                if (!spanContains(owner, span)) return error.InvalidTypeSpan;
            }
        }
    }

    fn validateSemanticFragment(self: *const Store, fragment: SemanticFragment) !void {
        try self.validateSpan(fragment.raw_span);
        try self.validateNodeRange(fragment.node_range);
        if (fragment.semantic_prefix_end < fragment.raw_span.start or
            fragment.semantic_prefix_end > fragment.raw_span.end)
        {
            return error.InvalidTypeSpan;
        }
        try validateChild(fragment.root, self.nodes.items.len);
        try validateOwnedChild(fragment.root, fragment.node_range);
        try self.validateOwnedNodes(fragment.node_range, fragment.raw_span);
    }

    fn validateCaptureSpans(self: *const Store, capture_spans: GenericCaptureSpans) !void {
        try self.validateSpan(capture_spans.actual_erased_span);
        try self.validateSpan(capture_spans.legacy_recorded_span);
    }

    fn validateOwnerCaptureSpans(
        self: *const Store,
        list_span: Span,
        capture_spans: GenericCaptureSpans,
    ) !void {
        try self.validateCaptureSpans(capture_spans);
        if (capture_spans.actual_erased_span.start != list_span.start or
            !spanContains(capture_spans.actual_erased_span, list_span) or
            !spanContains(capture_spans.actual_erased_span, capture_spans.legacy_recorded_span))
        {
            return error.InvalidGenericOwner;
        }
    }

    fn validateGenericListSpan(self: *const Store, list_span: Span) !void {
        try self.validateSpan(list_span);
        if (list_span.end - list_span.start < 2 or
            self.source[list_span.start] != '<' or
            self.source[list_span.end - 1] != '>')
        {
            return error.InvalidGenericOwner;
        }
    }

    fn validateGenericOwnerSyntax(self: *const Store, owner: GenericOwner, owner_index: usize) !void {
        try self.validateGenericListSpan(owner.list_span);
        try self.validateOwnerCaptureSpans(owner.list_span, owner.capture_spans);
        const authored = self.genericParameterSlice(owner.authored_parameters) orelse return error.InvalidTypeRange;
        const projected = self.projectedGenericParameterSlice(owner.projected_parameters) orelse
            return error.InvalidTypeRange;
        if (projected.len > 8) return error.InvalidTypeRange;
        for (authored) |parameter| {
            if (!spanContains(owner.list_span, parameter.raw_span)) return error.InvalidTypeSpan;
        }
        for (projected) |parameter| {
            if (!spanContains(owner.list_span, parameter.raw_span)) return error.InvalidTypeSpan;
        }
        switch (owner.compatibility) {
            .declaration_parameters => {},
            .ignored_declaration_parameters => {
                for (projected) |parameter| {
                    if (parameter.bound_fragment != null) return error.InvalidGenericOwner;
                }
            },
            .legacy_call_arguments => |arguments| {
                for (projected) |parameter| {
                    if (parameter.bound_fragment != null) return error.InvalidGenericOwner;
                }
                const authored_arguments = self.authoredCallArgumentSlice(arguments.authored_arguments) orelse
                    return error.InvalidTypeRange;
                const fragments = self.semanticFragmentSlice(arguments.semantic_fragments) orelse
                    return error.InvalidTypeRange;
                if (fragments.len > 8) return error.InvalidTypeRange;
                for (authored_arguments) |argument| {
                    if (!spanContains(owner.list_span, argument.full_span)) return error.InvalidTypeSpan;
                }
                for (fragments) |fragment| {
                    if (!spanContains(owner.list_span, fragment.raw_span)) return error.InvalidTypeSpan;
                }
            },
        }
        switch (owner.identity) {
            .structural_declaration => |declaration_index| {
                if (std.meta.activeTag(owner.compatibility) != .declaration_parameters) {
                    return error.InvalidGenericOwner;
                }
                for (projected) |parameter| {
                    if (parameter.bound_fragment != null) return error.InvalidGenericOwner;
                }
                if (@as(usize, declaration_index) >= self.declarations.items.len) return error.InvalidGenericOwner;
                if (self.declarations.items[declaration_index].kind != .structural or
                    self.declarations.items[declaration_index].generic_owner != @as(u32, @intCast(owner_index)))
                {
                    return error.InvalidGenericOwner;
                }
            },
            .nominal_declaration => |declaration_index| {
                if (std.meta.activeTag(owner.compatibility) != .ignored_declaration_parameters or
                    @as(usize, declaration_index) >= self.declarations.items.len)
                {
                    return error.InvalidGenericOwner;
                }
                if (self.declarations.items[declaration_index].kind != .nominal or
                    self.declarations.items[declaration_index].generic_owner != @as(u32, @intCast(owner_index)))
                {
                    return error.InvalidGenericOwner;
                }
            },
            .function => {
                for (projected) |parameter| if (parameter.bound_fragment) |fragment_index| {
                    if (@as(usize, fragment_index) >= self.semantic_fragments.items.len) {
                        return error.InvalidTypeRange;
                    }
                    const fragment = self.semantic_fragments.items[fragment_index];
                    const bound_span = parameter.legacy_bound_span orelse return error.InvalidGenericOwner;
                    if (!std.meta.eql(fragment.raw_span, bound_span)) return error.InvalidGenericOwner;
                };
            },
            .arrow => {
                if (std.meta.activeTag(owner.compatibility) == .ignored_declaration_parameters) {
                    return error.InvalidGenericOwner;
                }
                for (projected) |parameter| if (parameter.bound_fragment) |fragment_index| {
                    if (@as(usize, fragment_index) >= self.semantic_fragments.items.len) {
                        return error.InvalidTypeRange;
                    }
                    const fragment = self.semantic_fragments.items[fragment_index];
                    const bound_span = parameter.legacy_bound_span orelse return error.InvalidGenericOwner;
                    if (!std.meta.eql(fragment.raw_span, bound_span)) return error.InvalidGenericOwner;
                };
            },
        }
    }

    fn validateGenericOwnerRecord(
        self: *const Store,
        owner: GenericOwner,
        owner_index: usize,
        view: ir.IrView,
    ) !void {
        try self.validateGenericOwnerSyntax(owner, owner_index);
        const runtime_owner, const expected_tag = switch (owner.identity) {
            .structural_declaration, .nominal_declaration => return,
            .function => |runtime_node| .{ runtime_node, ir.NodeTag.function_expr },
            .arrow => |runtime_node| .{ runtime_node, ir.NodeTag.arrow_function },
        };
        const tag = view.getTag(runtime_owner) orelse return error.InvalidGenericOwner;
        if (tag != expected_tag) return error.InvalidGenericOwner;
        const location = view.getLoc(runtime_owner) orelse return error.InvalidGenericOwner;
        const ignored_function_comment = switch (owner.identity) {
            .function => std.meta.activeTag(owner.compatibility) == .ignored_declaration_parameters and
                std.meta.eql(owner.list_span, owner.capture_spans.actual_erased_span) and
                owner.capture_spans.legacy_recorded_span.start == owner.list_span.start + 1 and
                owner.capture_spans.legacy_recorded_span.end == owner.list_span.end - 1 and
                switch (classifyNamedFunctionGap(self.source, .{
                    .start = owner.list_span.end,
                    .end = location.offset,
                })) {
                    .block_comment, .line_comment => true,
                    .whitespace, .forbidden => false,
                },
            .structural_declaration, .nominal_declaration, .arrow => false,
        };
        if (@as(usize, location.offset) >= self.source.len or self.source[location.offset] != '(' or
            location.offset < owner.list_span.end or
            owner.capture_spans.actual_erased_span.end > location.offset or
            (!ignored_function_comment and !containsOnlyTypeWhitespace(
                self.source,
                owner.list_span.end,
                location.offset,
            )))
        {
            return error.InvalidGenericOwner;
        }
    }

    fn validateExplicitCallArgumentsSyntax(self: *const Store, arguments: ExplicitCallArguments) !void {
        try self.validateGenericListSpan(arguments.list_span);
        try self.validateOwnerCaptureSpans(arguments.list_span, arguments.capture_spans);
        const authored = rangeSlice(AuthoredCallArgument, self.authored_call_arguments.items, arguments.authored_arguments) orelse
            return error.InvalidTypeRange;
        const projected = self.semanticFragmentSlice(arguments.semantic_fragments) orelse return error.InvalidTypeRange;
        if (projected.len > 8) return error.InvalidTypeRange;
        for (authored) |argument| {
            if (!spanContains(arguments.list_span, argument.full_span)) return error.InvalidTypeSpan;
        }
        for (projected) |fragment| {
            if (!spanContains(arguments.list_span, fragment.raw_span)) return error.InvalidTypeSpan;
        }
    }

    fn validateExplicitCallArgumentsRecord(
        self: *const Store,
        arguments: ExplicitCallArguments,
        view: ir.IrView,
    ) !void {
        try self.validateExplicitCallArgumentsSyntax(arguments);
        const tag = view.getTag(arguments.owner) orelse return error.InvalidGenericOwner;
        if (tag != .call) return error.InvalidGenericOwner;
        const location = view.getLoc(arguments.owner) orelse return error.InvalidGenericOwner;
        if (location.offset != arguments.list_span.end) return error.InvalidGenericOwner;
        if (arguments.capture_spans.actual_erased_span.end > location.offset) return error.InvalidGenericOwner;
        if (@as(usize, location.offset) >= self.source.len or self.source[location.offset] != '(') {
            return error.InvalidGenericOwner;
        }
    }

    fn validateRecordOwnership(self: *const Store) !void {
        var list_owner_index: usize = 0;
        var list_prefix_index: usize = 0;
        var prior_list_start: ?u32 = null;
        while (list_owner_index < self.generic_owners.items.len or
            list_prefix_index < self.erased_type_prefixes.items.len)
        {
            const owner_start = if (list_owner_index < self.generic_owners.items.len)
                self.generic_owners.items[list_owner_index].list_span.start
            else
                null;
            const prefix_start = if (list_prefix_index < self.erased_type_prefixes.items.len)
                self.erased_type_prefixes.items[list_prefix_index].list_span.start
            else
                null;
            const use_owner = prefix_start == null or
                (owner_start != null and owner_start.? < prefix_start.?);
            const list_start = if (use_owner) owner_start.? else prefix_start.?;
            if (prior_list_start) |prior_start| {
                if (prior_start >= list_start) return error.InvalidTypeSourceOrder;
            }
            prior_list_start = list_start;
            if (use_owner) list_owner_index += 1 else list_prefix_index += 1;
        }

        var authored_parameter_end: u32 = 0;
        for (self.generic_owners.items) |owner| {
            if (owner.authored_parameters.start != authored_parameter_end) {
                return error.InvalidGenericOwner;
            }
            authored_parameter_end = std.math.add(
                u32,
                authored_parameter_end,
                owner.authored_parameters.count,
            ) catch return error.InvalidTypeRange;
        }
        if (@as(usize, authored_parameter_end) != self.generic_parameters.items.len) {
            return error.InvalidGenericOwner;
        }

        var generic_index: usize = 0;
        var prefix_index: usize = 0;
        var projected_parameter_end: u32 = 0;
        var previous_list_start: ?u32 = null;
        while (true) {
            while (prefix_index < self.erased_type_prefixes.items.len and
                std.meta.activeTag(self.erased_type_prefixes.items[prefix_index].compatibility) !=
                    .legacy_parameter_projection)
            {
                prefix_index += 1;
            }
            const generic_owner = if (generic_index < self.generic_owners.items.len)
                self.generic_owners.items[generic_index]
            else
                null;
            const prefix = if (prefix_index < self.erased_type_prefixes.items.len)
                self.erased_type_prefixes.items[prefix_index]
            else
                null;
            if (generic_owner == null and prefix == null) break;

            const use_generic = prefix == null or
                (generic_owner != null and generic_owner.?.list_span.start < prefix.?.list_span.start);
            const list_start, const projected_range = if (use_generic)
                .{ generic_owner.?.list_span.start, generic_owner.?.projected_parameters }
            else
                .{ prefix.?.list_span.start, switch (prefix.?.compatibility) {
                    .legacy_parameter_projection => |projection| projection.projected_parameters,
                    .ignored_parameters => unreachable,
                } };
            if (previous_list_start) |prior_start| {
                if (prior_start >= list_start) return error.InvalidTypeSourceOrder;
            }
            if (projected_range.start != projected_parameter_end) return error.InvalidGenericOwner;
            projected_parameter_end = std.math.add(
                u32,
                projected_parameter_end,
                projected_range.count,
            ) catch return error.InvalidTypeRange;
            previous_list_start = list_start;
            if (use_generic) generic_index += 1 else prefix_index += 1;
        }
        if (@as(usize, projected_parameter_end) != self.projected_generic_parameters.items.len) {
            return error.InvalidGenericOwner;
        }

        var parameter_annotation_end: u32 = 0;
        for (self.function_signatures.items) |signature| {
            if (signature.parameters.start != parameter_annotation_end) {
                return error.InvalidFunctionSignature;
            }
            parameter_annotation_end = std.math.add(
                u32,
                parameter_annotation_end,
                signature.parameters.count,
            ) catch return error.InvalidTypeRange;
        }
        if (@as(usize, parameter_annotation_end) != self.parameter_annotations.items.len) {
            return error.InvalidFunctionSignature;
        }
    }

    fn validateOwnedNodes(self: *const Store, owner: Range, raw_span: Span) !void {
        const start: usize = owner.start;
        const end = std.math.add(usize, start, owner.count) catch return error.InvalidTypeRange;
        if (end > self.nodes.items.len) return error.InvalidTypeRange;
        for (self.nodes.items[start..end]) |syntax_node| switch (syntax_node.data) {
            .primitive, .named_reference, .literal_string, .literal_number, .literal_bool => {},
            .generic_application => |application| {
                try validateOwnedChild(application.base, owner);
                const arguments = self.memberSlice(application.arguments) orelse
                    return error.InvalidTypeRange;
                for (arguments) |argument| try validateOwnedChild(argument, owner);
            },
            .group => |group| {
                try validateOwnedChild(group.child, owner);
                const parameters = self.paramSlice(group.attempted_params) orelse
                    return error.InvalidTypeRange;
                for (parameters) |parameter| {
                    if (!spanContains(raw_span, parameter.span) or
                        !spanContains(raw_span, parameter.name))
                    {
                        return error.InvalidTypeSpan;
                    }
                    try validateOwnedChild(parameter.type_child, owner);
                }
            },
            .readonly_modifier => |child| try validateOwnedChild(child, owner),
            .record => |range| {
                const fields = self.fieldSlice(range) orelse return error.InvalidTypeRange;
                for (fields) |field| try validateOwnedChild(field.type_child, owner);
            },
            .array => |child| try validateOwnedChild(child, owner),
            .tuple => |range| {
                const members = self.memberSlice(range) orelse return error.InvalidTypeRange;
                for (members) |child| try validateOwnedChild(child, owner);
            },
            .function => |function| {
                const params = self.paramSlice(function.params) orelse return error.InvalidTypeRange;
                for (params) |parameter| try validateOwnedChild(parameter.type_child, owner);
                try validateOwnedChild(function.ret, owner);
            },
            .union_type => |range| {
                const members = self.memberSlice(range) orelse return error.InvalidTypeRange;
                for (members) |child| try validateOwnedChild(child, owner);
            },
            .intersection => |range| {
                const members = self.memberSlice(range) orelse return error.InvalidTypeRange;
                for (members) |child| try validateOwnedChild(child, owner);
            },
            .template => |range| {
                const parts = self.templatePartSlice(range) orelse return error.InvalidTypeRange;
                for (parts) |part| switch (part) {
                    .literal => {},
                    .type_slot => |child| try validateOwnedChild(child, owner),
                };
            },
        };
    }

    fn validateOwnerRangesDoNotOverlap(self: *const Store) !void {
        for (self.annotations.items, 0..) |annotation, annotation_index| {
            for (self.annotations.items[annotation_index + 1 ..]) |other| {
                if (rangesOverlap(annotation.node_range, other.node_range)) {
                    return error.OverlappingTypeNodeOwnership;
                }
            }
            for (self.declarations.items) |declaration| switch (declaration.body) {
                .absent => {},
                .present => |body| if (rangesOverlap(annotation.node_range, body.node_range)) {
                    return error.OverlappingTypeNodeOwnership;
                },
            };
        }
        for (self.declarations.items, 0..) |declaration, declaration_index| {
            const range = switch (declaration.body) {
                .absent => continue,
                .present => |body| body.node_range,
            };
            for (self.declarations.items[declaration_index + 1 ..]) |other| switch (other.body) {
                .absent => {},
                .present => |body| if (rangesOverlap(range, body.node_range)) {
                    return error.OverlappingTypeNodeOwnership;
                },
            };
            for (self.semantic_fragments.items) |fragment| {
                if (rangesOverlap(range, fragment.node_range)) return error.OverlappingTypeNodeOwnership;
            }
        }
        for (self.annotations.items) |annotation| {
            for (self.semantic_fragments.items) |fragment| {
                if (rangesOverlap(annotation.node_range, fragment.node_range)) {
                    return error.OverlappingTypeNodeOwnership;
                }
            }
        }
        for (self.semantic_fragments.items, 0..) |fragment, index| {
            for (self.semantic_fragments.items[index + 1 ..]) |other| {
                if (rangesOverlap(fragment.node_range, other.node_range)) {
                    return error.OverlappingTypeNodeOwnership;
                }
            }
        }
        for (self.parameter_annotations.items, 0..) |parameter, parameter_index| {
            const range = parameter.value.node_range;
            for (self.annotations.items) |annotation| {
                if (rangesOverlap(range, annotation.node_range)) {
                    return error.OverlappingTypeNodeOwnership;
                }
            }
            for (self.declarations.items) |declaration| switch (declaration.body) {
                .absent => {},
                .present => |body| if (rangesOverlap(range, body.node_range)) {
                    return error.OverlappingTypeNodeOwnership;
                },
            };
            for (self.semantic_fragments.items) |fragment| {
                if (rangesOverlap(range, fragment.node_range)) {
                    return error.OverlappingTypeNodeOwnership;
                }
            }
            for (self.parameter_annotations.items[parameter_index + 1 ..]) |other| {
                if (rangesOverlap(range, other.value.node_range)) {
                    return error.OverlappingTypeNodeOwnership;
                }
            }
            for (self.function_signatures.items) |signature| {
                if (signature.return_syntax) |return_syntax| {
                    if (returnSyntaxOverlapsRange(return_syntax, range)) {
                        return error.OverlappingTypeNodeOwnership;
                    }
                }
            }
        }
        for (self.function_signatures.items, 0..) |signature, signature_index| {
            const return_syntax = signature.return_syntax orelse continue;
            if (returnSyntaxHasInternalOverlap(return_syntax)) {
                return error.OverlappingTypeNodeOwnership;
            }
            for (self.annotations.items) |annotation| {
                if (returnSyntaxOverlapsRange(return_syntax, annotation.node_range)) {
                    return error.OverlappingTypeNodeOwnership;
                }
            }
            for (self.declarations.items) |declaration| switch (declaration.body) {
                .absent => {},
                .present => |body| if (returnSyntaxOverlapsRange(return_syntax, body.node_range)) {
                    return error.OverlappingTypeNodeOwnership;
                },
            };
            for (self.semantic_fragments.items) |fragment| {
                if (returnSyntaxOverlapsRange(return_syntax, fragment.node_range)) {
                    return error.OverlappingTypeNodeOwnership;
                }
            }
            for (self.function_signatures.items[signature_index + 1 ..]) |other| {
                if (other.return_syntax) |other_return| {
                    if (returnSyntaxesOverlap(return_syntax, other_return)) {
                        return error.OverlappingTypeNodeOwnership;
                    }
                }
            }
        }
    }

    fn validateSpan(self: *const Store, span: Span) !void {
        if (span.start > span.end or @as(usize, span.end) > self.source.len) {
            return error.InvalidTypeSpan;
        }
    }

    fn validateNodeRange(self: *const Store, range: Range) !void {
        const start: usize = range.start;
        const end = std.math.add(usize, start, range.count) catch return error.InvalidTypeRange;
        if (end > self.nodes.items.len) return error.InvalidTypeRange;
    }
};

fn rangesOverlap(left: Range, right: Range) bool {
    if (left.count == 0 or right.count == 0) return false;
    const left_end = std.math.add(u32, left.start, left.count) catch return true;
    const right_end = std.math.add(u32, right.start, right.count) catch return true;
    return left.start < right_end and right.start < left_end;
}

fn spansOverlap(left: Span, right: Span) bool {
    return left.start < right.end and right.start < left.end;
}

fn spanStrictlyContains(outer: Span, inner: Span) bool {
    return outer.start < inner.start and inner.end < outer.end;
}

fn returnSyntaxOverlapsRange(value: ReturnSyntax, range: Range) bool {
    const structure_overlap = switch (value.structure) {
        .value => |type_value| rangesOverlap(type_value.node_range, range),
        .predicate => |predicate| rangesOverlap(predicate.narrowed.node_range, range),
    };
    if (structure_overlap) return true;
    return if (value.legacy_ordinary_prefix) |compatibility|
        rangesOverlap(compatibility.node_range, range)
    else
        false;
}

fn returnSyntaxHasInternalOverlap(value: ReturnSyntax) bool {
    const compatibility = value.legacy_ordinary_prefix orelse return false;
    const structure_range = switch (value.structure) {
        .value => |type_value| type_value.node_range,
        .predicate => |predicate| predicate.narrowed.node_range,
    };
    return rangesOverlap(structure_range, compatibility.node_range);
}

fn returnSyntaxesOverlap(left: ReturnSyntax, right: ReturnSyntax) bool {
    const left_structure = switch (left.structure) {
        .value => |type_value| type_value.node_range,
        .predicate => |predicate| predicate.narrowed.node_range,
    };
    if (returnSyntaxOverlapsRange(right, left_structure)) return true;
    if (left.legacy_ordinary_prefix) |compatibility| {
        if (returnSyntaxOverlapsRange(right, compatibility.node_range)) return true;
    }
    return false;
}

fn claimSemanticFragment(owners: []u8, fragment_index: u32) !void {
    if (@as(usize, fragment_index) >= owners.len) return error.InvalidTypeRange;
    if (owners[fragment_index] != 0) return error.SharedSemanticFragment;
    owners[fragment_index] = 1;
}

fn claimRange(owners: []u8, range: Range, comptime shared_error: anyerror) !void {
    const start: usize = range.start;
    const end = std.math.add(usize, start, range.count) catch return error.InvalidTypeRange;
    if (end > owners.len) return error.InvalidTypeRange;
    for (owners[start..end]) |*owner_count| {
        if (owner_count.* != 0) return shared_error;
        owner_count.* = 1;
    }
}

fn spanContains(owner: Span, child: Span) bool {
    return child.start >= owner.start and child.end <= owner.end;
}

fn validateChild(child: Child, parent: usize) !void {
    switch (child) {
        .absent => {},
        .present => |index| if (@as(usize, index) >= parent) return error.InvalidTypeChild,
    }
}

fn childIsAbsent(child: Child) bool {
    return switch (child) {
        .absent => true,
        .present => false,
    };
}

fn validateOwnedChild(child: Child, range: Range) !void {
    switch (child) {
        .absent => {},
        .present => |index| {
            const end = std.math.add(u32, range.start, range.count) catch
                return error.InvalidTypeRange;
            if (index < range.start or index >= end) return error.InvalidTypeChild;
        },
    }
}

fn markApplicationBaseUse(child: Child, base_uses: []u8) void {
    switch (child) {
        .absent => {},
        .present => |index| {
            const slot = &base_uses[index];
            if (slot.* < 2) slot.* += 1;
        },
    }
}

fn markOrdinaryUse(child: Child, ordinary_uses: []bool) void {
    switch (child) {
        .absent => {},
        .present => |index| ordinary_uses[index] = true,
    }
}

fn appendRange(
    comptime T: type,
    allocator: std.mem.Allocator,
    list: *std.ArrayListUnmanaged(T),
    values: []const T,
) !Range {
    const start = std.math.cast(u32, list.items.len) orelse return error.TooManyTypeItems;
    const count = std.math.cast(u32, values.len) orelse return error.TooManyTypeItems;
    try list.appendSlice(allocator, values);
    return .{ .start = start, .count = count };
}

fn rangeSlice(comptime T: type, values: []const T, range: Range) ?[]const T {
    const start: usize = range.start;
    const count: usize = range.count;
    const end = std.math.add(usize, start, count) catch return null;
    if (end > values.len) return null;
    return values[start..end];
}

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

fn scanRawTypeOnlyModule(
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

pub const ParsedPrimitive = struct {
    primitive: Primitive,
    semantic_span: Span,
    raw_span: Span,
};

pub const Failure = union(enum) {
    missing_type: Token,
    unmatched_parenthesis: Token,
    nesting_too_deep: Token,
    unsupported_suffix: Token,
};

pub const ParseOutcome = union(enum) {
    parsed: ParsedPrimitive,
    failure: Failure,
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

/// Parse one primitive annotation and leave `cursor.current` at its delimiter.
/// Plain identifier suffixes remain in the raw span but not the semantic span.
pub fn parsePrimitive(source: []const u8, cursor: *Cursor) ParseOutcome {
    return parsePrimitiveWithLimit(source, cursor, max_type_depth);
}

/// Validate comparison eligibility after a depth refusal, using the same grammar.
/// Each opening parenthesis consumes a source byte, which bounds this scan.
pub fn validatePrimitiveAfterDepthRefusal(source: []const u8, cursor: *Cursor) ParseOutcome {
    return parsePrimitiveWithLimit(source, cursor, source.len);
}

fn parsePrimitiveWithLimit(source: []const u8, cursor: *Cursor, limit: usize) ParseOutcome {
    const raw_start = cursor.current.start;
    var depth: usize = 0;

    while (cursor.current.type == .lparen) {
        if (depth == limit) {
            return .{ .failure = .{ .nesting_too_deep = cursor.current } };
        }
        depth += 1;
        cursor.advance();
    }

    const primitive_token = cursor.current;
    const primitive = primitiveFor(primitive_token, source) orelse {
        return .{ .failure = .{ .missing_type = primitive_token } };
    };
    cursor.advance();

    var semantic_end = primitive_token.start + primitive_token.len;
    var remaining = depth;
    while (remaining > 0) : (remaining -= 1) {
        if (cursor.current.type != .rparen) {
            return .{ .failure = .{ .unmatched_parenthesis = cursor.current } };
        }
        semantic_end = cursor.current.start + cursor.current.len;
        cursor.advance();
    }

    var raw_end = semantic_end;
    while (!isAnnotationDelimiter(cursor.current.type)) {
        if (!isPlainSuffix(cursor.current)) {
            return .{ .failure = .{ .unsupported_suffix = cursor.current } };
        }
        raw_end = cursor.current.start + cursor.current.len;
        cursor.advance();
    }

    return .{ .parsed = .{
        .primitive = primitive,
        .semantic_span = .{ .start = raw_start, .end = semantic_end },
        .raw_span = .{ .start = raw_start, .end = raw_end },
    } };
}

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

fn predicateHeader(source: []const u8, raw_span: Span) ?PredicateHeader {
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

fn hasLegacyGuardFacet(source: []const u8, raw_span: Span) bool {
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
    if (source.len > std.math.maxInt(u32)) return error.TypeSourceTooLarge;
    const caught_checkpoint = if (caught) |items| items.items.len else 0;
    errdefer {
        if (caught) |items| items.items.len = caught_checkpoint;
    }
    const close: u8 = switch (open) {
        '(' => ')',
        '[' => ']',
        '{' => '}',
        else => return .{ .complete = start + 1 },
    };
    var depth: u16 = 1;
    var pos = start + 1;
    while (pos < source.len and depth > 0) {
        const byte = source[pos];
        if (byte == '"' or byte == '\'' or byte == '`') {
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
    return .{ .complete = pos };
}

fn skipLegacyMatchingBracket(
    allocator: std.mem.Allocator,
    source: []const u8,
    start: usize,
    open: u8,
    suppressed_diagnostic: *bool,
) !?usize {
    return switch (try scanLegacyMatchingBracketCore(
        allocator,
        source,
        start,
        open,
        suppressed_diagnostic,
        null,
    )) {
        .complete => |end| end,
        .nesting_too_deep => null,
    };
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

fn appendAuthoredGenericParameters(store: *Store, list_span: Span) !void {
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

fn appendAuthoredCallArguments(store: *Store, list_span: Span) !void {
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

fn appendProjectedCallFragments(store: *Store, projected_span: Span) !void {
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

fn appendProjectedGenericParameters(store: *Store, list_span: Span) !void {
    try appendProjectedGenericParametersFromSpan(store, projectedListBody(store.source, list_span));
}

const ProjectedParameterRanges = struct {
    parameters: Range,
    fragments: Range,
};

fn appendProjectedParametersWithBounds(
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
            const bound_span = store.projected_generic_parameters.items[index].legacy_bound_span orelse
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

fn projectedListBody(source: []const u8, recorded_span: Span) Span {
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
    var legacy_bound_span: ?Span = null;
    if (wordAt(source, rest_start, raw_span.end, "extends")) {
        const after = rest_start + @as(u32, "extends".len);
        if (after < raw_span.end and isTypeWhitespace(source[after])) {
            legacy_bound_span = trimSpan(source, .{
                .start = after,
                .end = raw_span.end,
            });
        }
    }
    return .{
        .raw_span = raw_span,
        .name_span = name_span,
        .legacy_bound_span = legacy_bound_span,
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

fn trimSpan(source: []const u8, span: Span) Span {
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
            .legacy_recorded_span = list_span,
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

const TestRuntime = struct {
    nodes: ir.IRStore,
    constants: ir.ConstantPool,

    fn init(allocator: std.mem.Allocator) TestRuntime {
        return .{
            .nodes = ir.IRStore.init(allocator),
            .constants = ir.ConstantPool.init(allocator),
        };
    }

    fn deinit(self: *TestRuntime) void {
        self.nodes.deinit();
        self.constants.deinit();
    }

    fn view(self: *const TestRuntime) ir.IrView {
        return ir.IrView.fromIRStore(&self.nodes, &self.constants);
    }

    fn addCall(self: *TestRuntime, offset: u32) !ir.NodeIndex {
        return self.nodes.add(.{
            .tag = .call,
            .loc = .{ .line = 1, .column = offset + 1, .offset = offset, .end_offset = offset + 1 },
            .data = .{ .call = .{
                .callee = ir.null_node,
                .args_start = ir.null_node,
                .args_count = 0,
            } },
        });
    }

    fn addFunction(self: *TestRuntime, tag: ir.NodeTag, offset: u32) !ir.NodeIndex {
        if (tag != .function_expr and tag != .arrow_function) return error.TestUnexpectedResult;
        return self.nodes.add(.{
            .tag = tag,
            .loc = .{ .line = 1, .column = offset + 1, .offset = offset, .end_offset = offset + 1 },
            .data = .{ .function = .{
                .scope_id = 0,
                .name_atom = 0,
                .params_start = ir.null_node,
                .params_count = 0,
                .body = ir.null_node,
                .flags = .{},
            } },
        });
    }
};

const AdmissionScan = union(enum) {
    end: u32,
    nesting_too_deep: u32,
    unmatched_parenthesis: u32,
    malformed: Span,
    implementation_budget: u32,
};

fn scanAdmissionEnd(source: []const u8, raw_start: u32) AdmissionScan {
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

fn scanDeclarationEnd(source: []const u8, raw_start: u32) AdmissionScan {
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

pub fn scanAdmissionEndpoint(
    allocator: std.mem.Allocator,
    source: []const u8,
    raw_start: u32,
    policy: AdmissionEndpointPolicy,
    caught: *std.ArrayListUnmanaged(AdmissionDiagnostic),
) !AdmissionEndpointResult {
    return scanAdmissionEndpointCore(allocator, source, raw_start, policy, caught, null);
}

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

fn scanAdmissionEndpointCore(
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

fn scanTypeQuoted(source: []const u8, start: usize, quote: u8) QuotedScan {
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

fn skipTypeWhitespace(source: []const u8, start: u32) u32 {
    var pos: usize = @min(@as(usize, start), source.len);
    while (pos < source.len and isTypeWhitespace(source[pos])) pos += 1;
    return @intCast(pos);
}

fn containsOnlyTypeWhitespace(source: []const u8, start: u32, end: u32) bool {
    const first = @min(@as(usize, start), source.len);
    const last = @min(@as(usize, end), source.len);
    if (first > last) return false;
    for (source[first..last]) |byte| if (!isTypeWhitespace(byte)) return false;
    return true;
}

fn looksLikeTypeStart(source: []const u8, start: u32) bool {
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

fn advanceCursorTo(cursor: *Cursor, offset: u32) void {
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

fn tokenAtOffset(source: []const u8, offset: u32) Token {
    var cursor = Cursor.init(source);
    while (cursor.current.type != .eof and cursor.current.start < offset) cursor.advance();
    return cursor.current;
}

fn tokenSpan(token: Token) Span {
    return .{ .start = token.start, .end = token.start + token.len };
}

pub fn tokenIsDeclarationName(token: Token, source: []const u8) bool {
    const text = token.text(source);
    if (text.len == 0 or !isIdentifierStart(text[0])) return false;
    for (text[1..]) |byte| if (!isIdentifierContinue(byte)) return false;
    return true;
}

fn trimWhitespaceEnd(source: []const u8, start: u32, end: u32) u32 {
    var result = @min(@as(usize, end), source.len);
    const first = @min(@as(usize, start), result);
    while (result > first and isTypeWhitespace(source[result - 1])) result -= 1;
    return @intCast(result);
}

fn spanContainsOnlyTypeWhitespace(source: []const u8, span: Span) bool {
    if (span.start >= span.end or @as(usize, span.end) > source.len) return false;
    for (source[span.start..span.end]) |byte| {
        if (!isTypeWhitespace(byte)) return false;
    }
    return true;
}

fn isTypeWhitespace(byte: u8) bool {
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

fn isScalarNominalBase(text: []const u8) bool {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    return std.mem.eql(u8, trimmed, "string") or
        std.mem.eql(u8, trimmed, "number") or
        std.mem.eql(u8, trimmed, "boolean");
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

fn primitiveFor(tok: Token, source: []const u8) ?Primitive {
    return switch (tok.type) {
        .undefined_lit => .undefined,
        .null_lit => .null,
        .identifier => primitiveForIdentifier(tok.text(source)),
        else => null,
    };
}

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

fn isIdentifierStart(byte: u8) bool {
    return std.ascii.isAlphabetic(byte) or byte == '_' or byte == '$';
}

fn isIdentifierContinue(byte: u8) bool {
    return isIdentifierStart(byte) or std.ascii.isDigit(byte);
}

fn isAnnotationDelimiter(kind: token_mod.TokenType) bool {
    return kind == .assign or kind == .semicolon or kind == .eof;
}

fn isPlainSuffix(tok: Token) bool {
    if (tok.type == .identifier or tok.type == .kw_void) return true;
    return false;
}

test "primitive parser retains semantic and raw annotation spans" {
    const source = "(((string))) tolerated_suffix = value;";
    var cursor = Cursor.init(source);
    const parsed = switch (parsePrimitive(source, &cursor)) {
        .parsed => |value| value,
        .failure => return error.TestUnexpectedResult,
    };

    try std.testing.expectEqual(Primitive.string, parsed.primitive);
    try std.testing.expectEqualStrings("(((string)))", parsed.semantic_span.text(source));
    try std.testing.expectEqualStrings("(((string))) tolerated_suffix", parsed.raw_span.text(source));
    try std.testing.expectEqual(token_mod.TokenType.assign, cursor.current.type);
}

test "simple declaration retains ownership and component spans" {
    const source = "structural Alias = number;";
    var store = Store.init(std.testing.allocator, source);
    defer store.deinit();
    var cursor = Cursor.init(source);
    const keyword = cursor.current;
    cursor.advance();

    const outcome = try parseDeclarationAndStore(
        &store,
        source,
        keyword,
        null,
        .structural,
        0,
        &cursor,
    );
    const full_span = switch (outcome) {
        .parsed => |span| span,
        .not_declaration, .excluded => return error.TestUnexpectedResult,
    };
    try store.validate();
    try std.testing.expectEqualStrings(source, full_span.text(source));
    try std.testing.expectEqual(@as(usize, 1), store.declarations.items.len);
    const declaration = store.declarations.items[0];
    try std.testing.expectEqualStrings("structural", declaration.keyword_span.text(source));
    try std.testing.expectEqualStrings("Alias", declaration.name_span.text(source));
    try std.testing.expectEqualStrings("=", declaration.equals_span.?.text(source));
    try std.testing.expectEqualStrings(";", declaration.terminator_span.?.text(source));
    const body = switch (declaration.body) {
        .absent => return error.TestUnexpectedResult,
        .present => |present| present,
    };
    try std.testing.expectEqualStrings("number", body.raw_span.text(source));
    try std.testing.expectEqual(@as(u32, 0), declaration.source_order);
    try std.testing.expectEqual(@as(u16, 0), declaration.authored_scope);
    try std.testing.expectEqual(token_mod.TokenType.eof, cursor.current.type);
}

test "declaration full spans retain consumed equals and trailing whitespace" {
    const sources = [_][]const u8{
        "structural Empty   ",
        "structural Empty =   ",
        "structural Alias = number\n  ",
    };
    for (sources) |source| {
        var store = Store.init(std.testing.allocator, source);
        defer store.deinit();
        var cursor = Cursor.init(source);
        const keyword = cursor.current;
        cursor.advance();
        const full_span = switch (try parseDeclarationAndStore(
            &store,
            source,
            keyword,
            null,
            .structural,
            0,
            &cursor,
        )) {
            .parsed => |span| span,
            .not_declaration, .excluded => return error.TestUnexpectedResult,
        };
        try store.validate();
        try std.testing.expectEqualStrings(source, full_span.text(source));
        try std.testing.expectEqualStrings(source, store.declarations.items[0].full_span.text(source));
        if (std.mem.indexOfScalar(u8, source, '\n')) |newline| {
            const body = switch (store.declarations.items[0].body) {
                .absent => return error.TestUnexpectedResult,
                .present => |present| present,
            };
            try std.testing.expectEqual(@as(u32, @intCast(newline)), body.admission_end);
            try std.testing.expectEqual(@as(u32, @intCast(source.len)), full_span.end);
        }
    }
}

test "declaration headers require whitespace between raw components" {
    const sources = [_][]const u8{
        "structural /*c*/ A = number;",
        "structural A /*c*/ = number;",
    };
    for (sources) |source| {
        var store = Store.init(std.testing.allocator, source);
        defer store.deinit();
        var cursor = Cursor.init(source);
        const keyword = cursor.current;
        cursor.advance();
        const before = cursor;
        switch (try parseDeclarationAndStore(
            &store,
            source,
            keyword,
            null,
            .structural,
            0,
            &cursor,
        )) {
            .not_declaration => {},
            .parsed, .excluded => return error.TestUnexpectedResult,
        }
        try std.testing.expect(std.meta.eql(before, cursor));
        try std.testing.expectEqual(@as(usize, 0), store.declarations.items.len);
        try store.validate();
    }
}

test "declaration terminators must start at the raw whitespace endpoint" {
    const source = "structural A = number\n/*c*/;";
    var store = Store.init(std.testing.allocator, source);
    defer store.deinit();
    var cursor = Cursor.init(source);
    const keyword = cursor.current;
    cursor.advance();
    const full_span = switch (try parseDeclarationAndStore(
        &store,
        source,
        keyword,
        null,
        .structural,
        0,
        &cursor,
    )) {
        .parsed => |span| span,
        .not_declaration, .excluded => return error.TestUnexpectedResult,
    };
    try store.validate();
    const comment_start = std.mem.indexOf(u8, source, "/*c*/") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u32, @intCast(comment_start)), full_span.end);
    try std.testing.expect(store.declarations.items[0].terminator_span == null);
    try std.testing.expectEqual(token_mod.TokenType.semicolon, cursor.current.type);

    const empty_source = "structural A =\n;";
    var empty_store = Store.init(std.testing.allocator, empty_source);
    defer empty_store.deinit();
    var empty_cursor = Cursor.init(empty_source);
    const empty_keyword = empty_cursor.current;
    empty_cursor.advance();
    switch (try parseDeclarationAndStore(
        &empty_store,
        empty_source,
        empty_keyword,
        null,
        .structural,
        0,
        &empty_cursor,
    )) {
        .parsed => |span| try std.testing.expectEqualStrings(empty_source, span.text(empty_source)),
        .not_declaration, .excluded => return error.TestUnexpectedResult,
    }
    try empty_store.validate();
    try std.testing.expect(empty_store.declarations.items[0].terminator_span != null);
    try std.testing.expectEqual(token_mod.TokenType.eof, empty_cursor.current.type);
}

test "declaration validation rejects source order and component escape" {
    const source = "structural First = number;\nstructural Second = string;";
    var store = Store.init(std.testing.allocator, source);
    defer store.deinit();
    var cursor = Cursor.init(source);
    inline for (0..2) |index| {
        const keyword = cursor.current;
        cursor.advance();
        switch (try parseDeclarationAndStore(
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
        try std.testing.expectEqual(@as(u32, index), store.declarations.items[index].source_order);
    }
    try store.validate();

    const second = store.declarations.items[1];
    store.declarations.items[1].source_order = 0;
    try std.testing.expectError(error.InvalidTypeSourceOrder, store.validate());
    store.declarations.items[1] = second;

    const first = store.declarations.items[0];
    store.declarations.items[0].full_span.end = store.declarations.items[0].name_span.end;
    try std.testing.expectError(error.InvalidTypeSpan, store.validate());
    store.declarations.items[0] = first;

    store.declarations.items[0].name_span.end = @intCast(source.len);
    try std.testing.expectError(error.InvalidTypeSpan, store.validate());
    store.declarations.items[0] = first;
    try store.validate();
}

test "excluded declaration preserves prior syntax and cursor" {
    const source = "structural Prior = number;\nstructural Later = readonly<number>;";
    var store = Store.init(std.testing.allocator, source);
    defer store.deinit();
    var cursor = Cursor.init(source);
    const first_keyword = cursor.current;
    cursor.advance();
    switch (try parseDeclarationAndStore(
        &store,
        source,
        first_keyword,
        null,
        .structural,
        0,
        &cursor,
    )) {
        .parsed => {},
        .not_declaration, .excluded => return error.TestUnexpectedResult,
    }

    const prior = store.checkpoint();
    const second_keyword = cursor.current;
    cursor.advance();
    const before = cursor;
    switch (try parseDeclarationAndStore(
        &store,
        source,
        second_keyword,
        null,
        .structural,
        0,
        &cursor,
    )) {
        .parsed => return error.TestUnexpectedResult,
        .not_declaration, .excluded => {},
    }
    try std.testing.expect(std.meta.eql(before, cursor));
    try std.testing.expect(std.meta.eql(prior, store.checkpoint()));
    try std.testing.expectEqual(@as(usize, 1), store.declarations.items.len);
}

test "primitive parser admits 512 type parentheses and refuses the next" {
    var admitted_source: std.ArrayListUnmanaged(u8) = .empty;
    defer admitted_source.deinit(std.testing.allocator);
    try admitted_source.appendNTimes(std.testing.allocator, '(', max_type_depth);
    try admitted_source.appendSlice(std.testing.allocator, "number");
    try admitted_source.appendNTimes(std.testing.allocator, ')', max_type_depth);
    try admitted_source.appendSlice(std.testing.allocator, " = 1;");

    var admitted = Cursor.init(admitted_source.items);
    switch (parsePrimitive(admitted_source.items, &admitted)) {
        .parsed => {},
        .failure => return error.TestUnexpectedResult,
    }

    var refused_source: std.ArrayListUnmanaged(u8) = .empty;
    defer refused_source.deinit(std.testing.allocator);
    try refused_source.appendNTimes(std.testing.allocator, '(', max_type_depth + 1);
    try refused_source.appendSlice(std.testing.allocator, "number");
    try refused_source.appendNTimes(std.testing.allocator, ')', max_type_depth + 1);
    try refused_source.appendSlice(std.testing.allocator, " = 1;");

    var refused = Cursor.init(refused_source.items);
    const failure = switch (parsePrimitive(refused_source.items, &refused)) {
        .parsed => return error.TestUnexpectedResult,
        .failure => |value| value,
    };
    const at = switch (failure) {
        .nesting_too_deep => |token| token,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(token_mod.TokenType.lparen, at.type);
    try std.testing.expectEqual(@as(u32, max_type_depth), at.start);
}

test "type store closes every allocation failure" {
    const Context = struct {
        fn run(allocator: std.mem.Allocator) !void {
            var store = Store.init(allocator, "string suffix");
            defer store.deinit();
            try store.add(.global(300), .{
                .primitive = .string,
                .semantic_span = .{ .start = 0, .end = 6 },
                .raw_span = .{ .start = 0, .end = 13 },
            });
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Context.run, .{});
}

test "annotation publication failure preserves its cursor and prior syntax" {
    const source = "number = first; string = second;";
    const Context = struct {
        fn run(fail_index: usize, expect_failure: bool) !usize {
            var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{
                .fail_index = fail_index,
                .resize_fail_index = 0,
            });
            const allocator = failing.allocator();
            var store = Store.init(allocator, source);
            defer store.deinit();
            try store.nodes.ensureTotalCapacityPrecise(allocator, 2);
            try store.annotations.ensureTotalCapacityPrecise(allocator, 1);
            var first = Cursor.init(source);
            switch (try parseAndStore(&store, .global(300), source, 0, &first)) {
                .parsed => {},
                .failure, .excluded => return error.TestUnexpectedResult,
            }
            try std.testing.expectEqual(@as(usize, 1), store.nodes.items.len);
            try std.testing.expectEqual(@as(usize, 1), store.annotations.items.len);
            try std.testing.expectEqual(@as(usize, 2), store.nodes.capacity);
            try std.testing.expectEqual(@as(usize, 1), store.annotations.capacity);
            const prior = store.checkpoint();
            const second_start: u32 = @intCast(std.mem.indexOf(u8, source, "string").?);
            var second = Cursor.init(source);
            while (second.current.type != .eof and second.current.start < second_start) second.advance();
            const before = second;
            const prior_allocations = failing.alloc_index;
            const outcome = parseAndStore(&store, .global(301), source, second_start, &second);
            if (expect_failure) {
                try std.testing.expectError(error.OutOfMemory, outcome);
                try std.testing.expect(failing.has_induced_failure);
                try std.testing.expectEqual(fail_index, failing.alloc_index);
                try std.testing.expect(std.meta.eql(before, second));
                try std.testing.expect(std.meta.eql(prior, store.checkpoint()));
                try store.validate();
            } else {
                switch (try outcome) {
                    .parsed => {},
                    .failure, .excluded => return error.TestUnexpectedResult,
                }
                try std.testing.expect(!failing.has_induced_failure);
                try std.testing.expect(failing.alloc_index > prior_allocations);
                try std.testing.expectEqual(@as(usize, 2), store.nodes.items.len);
                try std.testing.expectEqual(@as(usize, 2), store.annotations.items.len);
                try std.testing.expectEqualStrings("string", store.annotations.items[1].raw_span.text(source));
                try store.validate();
            }
            return failing.alloc_index;
        }
    };
    const allocations = try Context.run(std.math.maxInt(usize), false);
    try std.testing.expect(allocations > 0);
    _ = try Context.run(allocations - 1, true);
}

test "compound annotation keeps raw admission and semantic prefix ends separate" {
    const source = "number /* comment */ []  = value;";
    var store = Store.init(std.testing.allocator, source);
    defer store.deinit();
    var cursor = Cursor.init(source);

    const parsed = switch (try parseAndStore(&store, .global(300), source, 0, &cursor)) {
        .parsed => |value| value,
        .failure, .excluded => return error.TestUnexpectedResult,
    };
    const annotation = store.annotations.items[0];
    try std.testing.expectEqualStrings("number", parsed.semantic_span.text(source));
    try std.testing.expectEqualStrings("number /* comment */ []", annotation.raw_span.text(source));
    try std.testing.expectEqualStrings(
        "number /* comment */ []  ",
        source[annotation.raw_span.start..annotation.admission_end],
    );
    try std.testing.expectEqual(parsed.semantic_span.end, annotation.semantic_prefix_end);
    try std.testing.expectEqual(token_mod.TokenType.assign, cursor.current.type);
}

test "excluded compound annotation rolls back all arrays and keeps its cursor" {
    const source =
        "{ prior: number | string; cb: (x: number) => `v${string}` } = first; " ++
        "{ a: number | string } | ((p: number) => `x${string}`) | readonly<number> = second;";
    var store = Store.init(std.testing.allocator, source);
    defer store.deinit();

    var first = Cursor.init(source);
    switch (try parseAndStore(&store, .global(300), source, 0, &first)) {
        .parsed => {},
        .failure, .excluded => return error.TestUnexpectedResult,
    }
    const prior = store.checkpoint();
    try std.testing.expectEqual(@as(usize, 1), prior.annotations);
    try std.testing.expect(prior.nodes > 0);
    try std.testing.expect(prior.members > 0);
    try std.testing.expect(prior.fields > 0);
    try std.testing.expect(prior.params > 0);
    try std.testing.expect(prior.template_parts > 0);

    const second_start: u32 = @intCast(std.mem.indexOf(u8, source, "{ a:").?);
    var second = Cursor.init(source);
    while (second.current.type != .eof and second.current.start < second_start) second.advance();
    const before = second;
    const outcome = try parseAndStore(&store, .global(301), source, second_start, &second);
    switch (outcome) {
        .excluded => |excluded| switch (excluded.reason) {
            .unsupported_syntax => {},
            else => return error.TestUnexpectedResult,
        },
        .parsed, .failure => return error.TestUnexpectedResult,
    }
    try std.testing.expect(std.meta.eql(before, second));
    try std.testing.expect(std.meta.eql(prior, store.checkpoint()));
}

test "private compound budgets roll back retained syntax and keep their cursors" {
    const Budget = enum { frames, templates };
    inline for (std.meta.tags(Budget)) |budget| {
        var source: std.ArrayListUnmanaged(u8) = .empty;
        defer source.deinit(std.testing.allocator);
        try source.appendSlice(
            std.testing.allocator,
            "{ prior: number | string; cb: (x: [number, string]) => `v${boolean}` } = first; ",
        );
        const second_start: u32 = @intCast(source.items.len);
        switch (budget) {
            .frames => {
                for (0..max_parser_frames + 1) |_| {
                    try source.appendSlice(std.testing.allocator, "readonly ");
                }
                try source.appendSlice(std.testing.allocator, "number = second;");
            },
            .templates => {
                try source.append(std.testing.allocator, '`');
                for (0..max_template_levels) |_| {
                    try source.appendSlice(std.testing.allocator, "${`");
                }
                try source.appendSlice(std.testing.allocator, "value");
                for (0..max_template_levels) |_| {
                    try source.appendSlice(std.testing.allocator, "`}");
                }
                try source.appendSlice(std.testing.allocator, "` = second;");
            },
        }

        var store = Store.init(std.testing.allocator, source.items);
        defer store.deinit();
        var first = Cursor.init(source.items);
        switch (try parseAndStore(&store, .global(300), source.items, 0, &first)) {
            .parsed => {},
            .failure, .excluded => return error.TestUnexpectedResult,
        }
        const prior = store.checkpoint();
        try std.testing.expect(prior.nodes > 0);
        try std.testing.expect(prior.members > 0);
        try std.testing.expect(prior.fields > 0);
        try std.testing.expect(prior.params > 0);
        try std.testing.expect(prior.template_parts > 0);
        try std.testing.expect(prior.annotations > 0);

        var second = Cursor.init(source.items);
        while (second.current.type != .eof and second.current.start < second_start) second.advance();
        const before = second;
        const outcome = try parseAndStore(
            &store,
            .global(301),
            source.items,
            second_start,
            &second,
        );
        switch (outcome) {
            .excluded => |excluded| switch (excluded.reason) {
                .implementation_budget => {},
                else => return error.TestUnexpectedResult,
            },
            .parsed, .failure => return error.TestUnexpectedResult,
        }
        try std.testing.expect(std.meta.eql(before, second));
        try std.testing.expect(std.meta.eql(prior, store.checkpoint()));
        try store.validate();
    }
}

test "second compound annotation rolls back every allocation failure" {
    const source =
        "{ prior: number | string; cb: (x: [number, string]) => `v${boolean}` } = first; " ++
        "{ field: number | string; cb: (pair: [number, string]) => `x${boolean}` } & " ++
        "{ tags: string[] } = second;";
    const Context = struct {
        fn run(allocator: std.mem.Allocator, observed_failures: *usize) !void {
            const second_start: u32 = @intCast(std.mem.indexOf(u8, source, "{ field:").?);
            var store = Store.init(allocator, source);
            defer store.deinit();
            var first = Cursor.init(source);
            switch (try parseAndStore(&store, .global(300), source, 0, &first)) {
                .parsed => {},
                .failure, .excluded => return error.TestUnexpectedResult,
            }
            const prior = store.checkpoint();
            try std.testing.expect(prior.nodes > 0);
            try std.testing.expect(prior.members > 0);
            try std.testing.expect(prior.fields > 0);
            try std.testing.expect(prior.params > 0);
            try std.testing.expect(prior.template_parts > 0);
            try std.testing.expect(prior.annotations > 0);

            var second = Cursor.init(source);
            while (second.current.type != .eof and second.current.start < second_start) second.advance();
            const before = second;
            const outcome = parseAndStore(&store, .global(301), source, second_start, &second);
            const parsed = outcome catch |err| switch (err) {
                error.OutOfMemory => {
                    observed_failures.* += 1;
                    try std.testing.expect(std.meta.eql(before, second));
                    try std.testing.expect(std.meta.eql(prior, store.checkpoint()));
                    try store.validate();
                    return error.OutOfMemory;
                },
                else => return err,
            };
            switch (parsed) {
                .parsed => {},
                .failure, .excluded => return error.TestUnexpectedResult,
            }
            const completed = store.checkpoint();
            try std.testing.expect(completed.nodes > prior.nodes);
            try std.testing.expect(completed.members > prior.members);
            try std.testing.expect(completed.fields > prior.fields);
            try std.testing.expect(completed.params > prior.params);
            try std.testing.expect(completed.template_parts > prior.template_parts);
            try std.testing.expectEqual(prior.annotations + 1, completed.annotations);
            try store.validate();
        }
    };
    var observed_failures: usize = 0;
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Context.run, .{&observed_failures});
    try std.testing.expect(observed_failures > 0);
}

test "second declaration rolls back every store array on allocation failure" {
    const source =
        "structural First = { field: number | string; cb: (pair: [number, string]) => `x${boolean}`; tags: string[] };\n" ++
        "structural Second = { field: number | string; cb: (pair: [number, string]) => `y${boolean}`; tags: string[] };";
    const Context = struct {
        fn run(allocator: std.mem.Allocator, observed_failures: *usize) !void {
            var store = Store.init(allocator, source);
            defer store.deinit();
            var cursor = Cursor.init(source);
            const first_keyword = cursor.current;
            cursor.advance();
            switch (try parseDeclarationAndStore(
                &store,
                source,
                first_keyword,
                null,
                .structural,
                0,
                &cursor,
            )) {
                .parsed => {},
                .not_declaration, .excluded => return error.TestUnexpectedResult,
            }
            const prior = store.checkpoint();
            try std.testing.expect(prior.nodes > 0);
            try std.testing.expect(prior.members > 0);
            try std.testing.expect(prior.fields > 0);
            try std.testing.expect(prior.params > 0);
            try std.testing.expect(prior.template_parts > 0);
            try std.testing.expectEqual(@as(usize, 0), prior.annotations);
            try std.testing.expectEqual(@as(usize, 1), prior.declarations);

            const second_keyword = cursor.current;
            cursor.advance();
            const before = cursor;
            const outcome = parseDeclarationAndStore(
                &store,
                source,
                second_keyword,
                null,
                .structural,
                1,
                &cursor,
            );
            const parsed = outcome catch |err| switch (err) {
                error.OutOfMemory => {
                    observed_failures.* += 1;
                    try std.testing.expect(std.meta.eql(before, cursor));
                    try std.testing.expect(std.meta.eql(prior, store.checkpoint()));
                    try store.validate();
                    return error.OutOfMemory;
                },
                else => return err,
            };
            switch (parsed) {
                .parsed => {},
                .not_declaration, .excluded => return error.TestUnexpectedResult,
            }
            const completed = store.checkpoint();
            try std.testing.expect(completed.nodes > prior.nodes);
            try std.testing.expect(completed.members > prior.members);
            try std.testing.expect(completed.fields > prior.fields);
            try std.testing.expect(completed.params > prior.params);
            try std.testing.expect(completed.template_parts > prior.template_parts);
            try std.testing.expectEqual(prior.annotations, completed.annotations);
            try std.testing.expectEqual(prior.declarations + 1, completed.declarations);
            try store.validate();
        }
    };
    var observed_failures: usize = 0;
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Context.run, .{&observed_failures});
    try std.testing.expect(observed_failures > 0);
}

test "second generic declaration rolls back all generic arrays on allocation failure" {
    const source =
        "structural First<T extends string = boolean> = { value: T };\n" ++
        "structural Second<U,V> = { left: U; right: V };";
    const Context = struct {
        fn run(allocator: std.mem.Allocator, observed_failures: *usize) !void {
            var store = Store.init(allocator, source);
            defer store.deinit();
            var cursor = Cursor.init(source);
            const first_keyword = cursor.current;
            cursor.advance();
            switch (try parseDeclarationAndStore(
                &store,
                source,
                first_keyword,
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
            try store.validate();

            const second_keyword = cursor.current;
            cursor.advance();
            const before = cursor;
            const outcome = parseDeclarationAndStore(
                &store,
                source,
                second_keyword,
                null,
                .structural,
                1,
                &cursor,
            );
            const parsed = outcome catch |err| switch (err) {
                error.OutOfMemory => {
                    observed_failures.* += 1;
                    try std.testing.expect(std.meta.eql(before, cursor));
                    try std.testing.expect(std.meta.eql(prior, store.checkpoint()));
                    try store.validate();
                    return error.OutOfMemory;
                },
                else => return err,
            };
            switch (parsed) {
                .parsed => {},
                .not_declaration, .excluded => return error.TestUnexpectedResult,
            }
            const completed = store.checkpoint();
            try std.testing.expect(completed.generic_parameters > prior.generic_parameters);
            try std.testing.expect(completed.projected_generic_parameters > prior.projected_generic_parameters);
            try std.testing.expectEqual(prior.generic_owners + 1, completed.generic_owners);
            try std.testing.expectEqual(prior.declarations + 1, completed.declarations);
            try store.validate();
        }
    };
    var observed_failures: usize = 0;
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Context.run, .{&observed_failures});
    try std.testing.expect(observed_failures > 0);
}

test "second generic application rolls back every allocation failure" {
    const source =
        "Outer<Inner<string>, number> = first; " ++
        "Proof<Readonly<{ data: Dict<string, number> }>, \"pure\"> = second;";
    const Context = struct {
        fn run(allocator: std.mem.Allocator, observed_later_failures: *usize) !void {
            const second_start: u32 = @intCast(std.mem.indexOf(u8, source, "Proof<").?);
            var store = Store.init(allocator, source);
            defer store.deinit();

            var first = Cursor.init(source);
            switch (try parseAndStore(&store, .global(300), source, 0, &first)) {
                .parsed => {},
                .failure, .excluded => return error.TestUnexpectedResult,
            }
            const prior = store.checkpoint();
            try std.testing.expect(prior.nodes > 0);
            try std.testing.expect(prior.members > 0);
            try std.testing.expectEqual(@as(usize, 1), prior.annotations);
            try store.validate();

            var second = Cursor.init(source);
            while (second.current.type != .eof and second.current.start < second_start) second.advance();
            const before = second;
            const outcome = parseAndStore(&store, .global(301), source, second_start, &second);
            const parsed = outcome catch |err| switch (err) {
                error.OutOfMemory => {
                    observed_later_failures.* += 1;
                    try std.testing.expect(std.meta.eql(before, second));
                    try std.testing.expect(std.meta.eql(prior, store.checkpoint()));
                    try store.validate();
                    return error.OutOfMemory;
                },
                else => return err,
            };
            switch (parsed) {
                .parsed => {},
                .failure, .excluded => return error.TestUnexpectedResult,
            }
            const completed = store.checkpoint();
            try std.testing.expect(completed.nodes > prior.nodes);
            try std.testing.expect(completed.members > prior.members);
            try std.testing.expectEqual(prior.annotations + 1, completed.annotations);
            try store.validate();
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

test "explicit call reservation owns its record and rolls back every array" {
    const source =
        "first<Outer<number>>(a); " ++
        "second<Proof<Readonly<{ data: Dict<string, number> }>>, \"pure\">(b);";
    const Context = struct {
        fn run(allocator: std.mem.Allocator, observed_later_failures: *usize) !void {
            const first_start: u32 = @intCast(std.mem.indexOf(u8, source, "<Outer").?);
            const first_lparen: u32 = @intCast(std.mem.indexOf(u8, source, "(a)").?);
            const second_start: u32 = @intCast(std.mem.indexOf(u8, source, "<Proof").?);
            const second_lparen: u32 = @intCast(std.mem.indexOf(u8, source, "(b)").?);
            var store = Store.init(allocator, source);
            defer store.deinit();
            var runtime = TestRuntime.init(std.testing.allocator);
            defer runtime.deinit();
            const first_call = try runtime.addCall(first_lparen);
            const second_call = try runtime.addCall(second_lparen);
            var first = try store.reserveExplicitCall(.{
                .list_span = .{ .start = first_start, .end = first_lparen },
                .capture_spans = .{
                    .actual_erased_span = .{ .start = first_start, .end = first_lparen },
                    .legacy_recorded_span = .{ .start = first_start + 1, .end = first_lparen - 1 },
                },
            });
            try store.finishExplicitCall(&first, first_call, runtime.view());
            try std.testing.expect(!first.active);
            try store.validate();
            var first_bases = try store.planApplicationBasesWithIr(
                std.testing.allocator,
                runtime.view(),
            );
            first_bases.deinit();
            const prior = store.checkpoint();
            try std.testing.expect(prior.nodes > 0);
            try std.testing.expect(prior.members > 0);
            try std.testing.expectEqual(@as(usize, 1), prior.authored_call_arguments);
            try std.testing.expectEqual(@as(usize, 1), prior.semantic_fragments);
            try std.testing.expectEqual(@as(usize, 1), prior.explicit_call_arguments);

            var second = store.reserveExplicitCall(.{
                .list_span = .{ .start = second_start, .end = second_lparen },
                .capture_spans = .{
                    .actual_erased_span = .{ .start = second_start, .end = second_lparen },
                    .legacy_recorded_span = .{ .start = second_start + 1, .end = second_lparen - 1 },
                },
            }) catch |err| switch (err) {
                error.OutOfMemory => {
                    observed_later_failures.* += 1;
                    try std.testing.expect(std.meta.eql(prior, store.checkpoint()));
                    try store.validate();
                    var retained_bases = try store.planApplicationBasesWithIr(
                        std.testing.allocator,
                        runtime.view(),
                    );
                    retained_bases.deinit();
                    return error.OutOfMemory;
                },
                else => return err,
            };
            try store.finishExplicitCall(&second, second_call, runtime.view());
            try store.validate();
            var completed_bases = try store.planApplicationBasesWithIr(
                std.testing.allocator,
                runtime.view(),
            );
            completed_bases.deinit();
            const completed = store.checkpoint();
            try std.testing.expect(completed.nodes > prior.nodes);
            try std.testing.expect(completed.members > prior.members);
            try std.testing.expect(completed.fields > prior.fields);
            try std.testing.expectEqual(prior.authored_call_arguments + 2, completed.authored_call_arguments);
            try std.testing.expectEqual(prior.semantic_fragments + 2, completed.semantic_fragments);
            try std.testing.expectEqual(prior.explicit_call_arguments + 1, completed.explicit_call_arguments);

            var canceled = try store.reserveExplicitCall(.{
                .list_span = .{ .start = second_start, .end = second_lparen },
                .capture_spans = .{
                    .actual_erased_span = .{ .start = second_start, .end = second_lparen },
                    .legacy_recorded_span = .{ .start = second_start + 1, .end = second_lparen - 1 },
                },
            });
            store.cancelExplicitCall(&canceled);
            try std.testing.expect(!canceled.active);
            try std.testing.expect(std.meta.eql(completed, store.checkpoint()));
            try std.testing.expectError(
                error.InvalidGenericOwner,
                store.finishExplicitCall(&canceled, second_call, runtime.view()),
            );
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

test "explicit call validation rejects more than eight projected arguments" {
    const source = "id<A,B,C,D,E,F,G,H,I>(value);";
    const list_start: u32 = @intCast(std.mem.indexOfScalar(u8, source, '<').?);
    const lparen: u32 = @intCast(std.mem.indexOf(u8, source, "(value)").?);
    var store = Store.init(std.testing.allocator, source);
    defer store.deinit();
    var runtime = TestRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    const call = try runtime.addCall(lparen);
    var pending = try store.reserveExplicitCall(.{
        .list_span = .{ .start = list_start, .end = lparen },
        .capture_spans = .{
            .actual_erased_span = .{ .start = list_start, .end = lparen },
            .legacy_recorded_span = .{ .start = list_start + 1, .end = lparen - 1 },
        },
    });
    try store.finishExplicitCall(&pending, call, runtime.view());
    try store.validate();
    try std.testing.expectEqual(
        @as(u32, 8),
        store.explicit_call_arguments.items[0].semantic_fragments.count,
    );

    try store.semantic_fragments.append(
        std.testing.allocator,
        store.semantic_fragments.items[7],
    );
    store.explicit_call_arguments.items[0].semantic_fragments.count = 9;
    try std.testing.expectError(error.InvalidTypeRange, store.validate());
}

test "generic and call finalizers reject incompatible runtime owners" {
    const source = "<T>(";
    var store = Store.init(std.testing.allocator, source);
    defer store.deinit();
    var runtime = TestRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    const function = try runtime.addFunction(.function_expr, 3);
    const arrow = try runtime.addFunction(.arrow_function, 3);
    const capture_spans: GenericCaptureSpans = .{
        .actual_erased_span = .{ .start = 0, .end = 3 },
        .legacy_recorded_span = .{ .start = 1, .end = 2 },
    };

    var structural = try store.reserveGenericOwner(.{
        .list_span = .{ .start = 0, .end = 3 },
        .capture_spans = capture_spans,
        .policy = .structural,
    });
    try std.testing.expectError(
        error.InvalidGenericOwner,
        store.finishGenericOwner(&structural, .{ .runtime = .{
            .owner = function,
            .view = runtime.view(),
        } }),
    );
    store.cancelGenericOwner(&structural);

    var callable = try store.reserveGenericOwner(.{
        .list_span = .{ .start = 0, .end = 3 },
        .capture_spans = capture_spans,
        .policy = .callable,
    });
    try std.testing.expectError(
        error.InvalidGenericOwner,
        store.finishGenericOwner(
            &callable,
            .{ .declaration = .{ .kind = .structural, .index = 0 } },
        ),
    );
    store.cancelGenericOwner(&callable);

    var ignored = try store.reserveGenericOwner(.{
        .list_span = .{ .start = 0, .end = 3 },
        .capture_spans = capture_spans,
        .policy = .ignored,
    });
    try std.testing.expectError(
        error.InvalidGenericOwner,
        store.finishGenericOwner(&ignored, .{ .runtime = .{
            .owner = arrow,
            .view = runtime.view(),
        } }),
    );
    store.cancelGenericOwner(&ignored);

    var legacy_call = try store.reserveGenericOwner(.{
        .list_span = .{ .start = 0, .end = 3 },
        .capture_spans = capture_spans,
        .policy = .legacy_call,
    });
    try std.testing.expectError(
        error.InvalidGenericOwner,
        store.finishGenericOwner(
            &legacy_call,
            .{ .declaration = .{ .kind = .structural, .index = 0 } },
        ),
    );
    store.cancelGenericOwner(&legacy_call);

    var explicit = try store.reserveExplicitCall(.{
        .list_span = .{ .start = 0, .end = 3 },
        .capture_spans = capture_spans,
    });
    try std.testing.expectError(
        error.InvalidGenericOwner,
        store.finishExplicitCall(&explicit, function, runtime.view()),
    );
    store.cancelExplicitCall(&explicit);
}

test "named function gap classifier accepts one bounded comment shape" {
    const Case = struct {
        source: []const u8,
        span: Span,
        expected: NamedFunctionGap,
    };
    const cases = [_]Case{
        .{ .source = " \t\r\n", .span = .{ .start = 0, .end = @intCast(" \t\r\n".len) }, .expected = .whitespace },
        .{ .source = " \t/* any // <text> */ \t", .span = .{ .start = 0, .end = @intCast(" \t/* any // <text> */ \t".len) }, .expected = .block_comment },
        .{ .source = " // any /* text */\n\t", .span = .{ .start = 0, .end = @intCast(" // any /* text */\n\t".len) }, .expected = .line_comment },
        .{ .source = "/* first *//* second */", .span = .{ .start = 0, .end = @intCast("/* first *//* second */".len) }, .expected = .forbidden },
        .{ .source = "// first\n// second\n", .span = .{ .start = 0, .end = @intCast("// first\n// second\n".len) }, .expected = .forbidden },
        .{ .source = "/* first */ token", .span = .{ .start = 0, .end = @intCast("/* first */ token".len) }, .expected = .forbidden },
        .{ .source = "/* two\nlines */", .span = .{ .start = 0, .end = @intCast("/* two\nlines */".len) }, .expected = .forbidden },
        .{ .source = "/* two\rlines */", .span = .{ .start = 0, .end = @intCast("/* two\rlines */".len) }, .expected = .forbidden },
        .{ .source = "// crlf\r\n", .span = .{ .start = 0, .end = @intCast("// crlf\r\n".len) }, .expected = .forbidden },
        .{ .source = "// embedded\rtext\n", .span = .{ .start = 0, .end = @intCast("// embedded\rtext\n".len) }, .expected = .forbidden },
        .{ .source = "\n/* moved */", .span = .{ .start = 0, .end = @intCast("\n/* moved */".len) }, .expected = .forbidden },
        .{ .source = "// first\n\n", .span = .{ .start = 0, .end = @intCast("// first\n\n".len) }, .expected = .forbidden },
        .{ .source = "/* open", .span = .{ .start = 0, .end = @intCast("/* open".len) }, .expected = .forbidden },
        .{ .source = "// no lf", .span = .{ .start = 0, .end = @intCast("// no lf".len) }, .expected = .forbidden },
        .{ .source = "x", .span = .{ .start = 1, .end = 0 }, .expected = .forbidden },
        .{ .source = "x", .span = .{ .start = 0, .end = 2 }, .expected = .forbidden },
    };
    for (cases) |case| {
        try std.testing.expectEqual(
            case.expected,
            classifyNamedFunctionGap(case.source, case.span),
        );
    }
}

test "only ignored named functions accept one bounded after-list comment gap" {
    const Context = struct {
        fn check(
            source: []const u8,
            policy: GenericOwnerPolicy,
            tag: ir.NodeTag,
            accepted: bool,
        ) !void {
            const opener: u32 = @intCast(std.mem.indexOfScalar(u8, source, '(') orelse
                return error.TestUnexpectedResult);
            var store = Store.init(std.testing.allocator, source);
            defer store.deinit();
            var runtime = TestRuntime.init(std.testing.allocator);
            defer runtime.deinit();
            const owner = try runtime.addFunction(tag, opener);
            var pending = try store.reserveGenericOwner(.{
                .list_span = .{ .start = 0, .end = 3 },
                .capture_spans = .{
                    .actual_erased_span = .{ .start = 0, .end = 3 },
                    .legacy_recorded_span = .{ .start = 1, .end = 2 },
                },
                .policy = policy,
            });
            if (accepted) {
                try store.finishGenericOwner(&pending, .{ .runtime = .{
                    .owner = owner,
                    .view = runtime.view(),
                } });
                try store.validateRuntimeOwners(std.testing.allocator, runtime.view());
                store.generic_owners.items[0].capture_spans.actual_erased_span.end += 1;
                try std.testing.expectError(
                    error.InvalidGenericOwner,
                    store.validateRuntimeOwners(std.testing.allocator, runtime.view()),
                );
                store.generic_owners.items[0].capture_spans.actual_erased_span.end -= 1;
                store.generic_owners.items[0].capture_spans.legacy_recorded_span = .{ .start = 0, .end = 3 };
                try std.testing.expectError(
                    error.InvalidGenericOwner,
                    store.validateRuntimeOwners(std.testing.allocator, runtime.view()),
                );
                store.generic_owners.items[0].capture_spans.legacy_recorded_span = .{ .start = 1, .end = 2 };
                try store.validateRuntimeOwners(std.testing.allocator, runtime.view());
            } else {
                try std.testing.expectError(
                    error.InvalidGenericOwner,
                    store.finishGenericOwner(&pending, .{ .runtime = .{
                        .owner = owner,
                        .view = runtime.view(),
                    } }),
                );
                store.cancelGenericOwner(&pending);
                try std.testing.expect(std.meta.eql(
                    std.mem.zeroes(Store.Checkpoint),
                    store.checkpoint(),
                ));
            }
        }
    };

    const accepted = "<T>/* arbitrary // text */(";
    try Context.check(accepted, .ignored, .function_expr, true);
    try Context.check(accepted, .callable, .function_expr, false);
    try Context.check(accepted, .ignored, .arrow_function, false);
    try Context.check(accepted, .legacy_call, .function_expr, false);

    const forbidden = [_][]const u8{
        "<T>// crlf\r\n(",
        "<T>// embedded\rtext\n(",
        "<T>/* embedded\ntext */(",
        "<T>/* embedded\rtext */(",
        "<T>/* first *//* second */(",
        "<T>// first\n// second\n(",
        "<T>/* first */ token(",
        "<T>\n/* moved */(",
        "<T>/* open(",
        "<T>// no lf(",
    };
    for (forbidden) |source| {
        try Context.check(source, .ignored, .function_expr, false);
    }
}

test "generic and call owners reject unrelated captures and invalid openers" {
    {
        const source = "x<T>(";
        var store = Store.init(std.testing.allocator, source);
        defer store.deinit();
        const before = store.checkpoint();
        try std.testing.expectError(
            error.InvalidGenericOwner,
            store.reserveGenericOwner(.{
                .list_span = .{ .start = 1, .end = 4 },
                .capture_spans = .{
                    .actual_erased_span = .{ .start = 0, .end = 4 },
                    .legacy_recorded_span = .{ .start = 2, .end = 3 },
                },
                .policy = .callable,
            }),
        );
        try std.testing.expect(std.meta.eql(before, store.checkpoint()));
        try std.testing.expectError(
            error.InvalidGenericOwner,
            store.reserveExplicitCall(.{
                .list_span = .{ .start = 1, .end = 4 },
                .capture_spans = .{
                    .actual_erased_span = .{ .start = 1, .end = 4 },
                    .legacy_recorded_span = .{ .start = 5, .end = 5 },
                },
            }),
        );
        try std.testing.expect(std.meta.eql(before, store.checkpoint()));
    }
    {
        const source = "<T>x";
        var store = Store.init(std.testing.allocator, source);
        defer store.deinit();
        try std.testing.expectError(
            error.InvalidGenericOwner,
            store.reserveGenericOwner(.{
                .list_span = .{ .start = 0, .end = 3 },
                .capture_spans = .{
                    .actual_erased_span = .{ .start = 1, .end = 2 },
                    .legacy_recorded_span = .{ .start = 1, .end = 2 },
                },
                .policy = .callable,
            }),
        );

        var runtime = TestRuntime.init(std.testing.allocator);
        defer runtime.deinit();
        inline for (.{ ir.NodeTag.function_expr, ir.NodeTag.arrow_function }) |tag| {
            const non_opener = try runtime.addFunction(tag, 3);
            var pending_non_opener = try store.reserveGenericOwner(.{
                .list_span = .{ .start = 0, .end = 3 },
                .capture_spans = .{
                    .actual_erased_span = .{ .start = 0, .end = 3 },
                    .legacy_recorded_span = .{ .start = 1, .end = 2 },
                },
                .policy = .callable,
            });
            try std.testing.expectError(
                error.InvalidGenericOwner,
                store.finishGenericOwner(&pending_non_opener, .{ .runtime = .{
                    .owner = non_opener,
                    .view = runtime.view(),
                } }),
            );
            store.cancelGenericOwner(&pending_non_opener);

            const out_of_range = try runtime.addFunction(tag, @intCast(source.len));
            var pending_out_of_range = try store.reserveGenericOwner(.{
                .list_span = .{ .start = 0, .end = 3 },
                .capture_spans = .{
                    .actual_erased_span = .{ .start = 0, .end = 3 },
                    .legacy_recorded_span = .{ .start = 1, .end = 2 },
                },
                .policy = .callable,
            });
            try std.testing.expectError(
                error.InvalidGenericOwner,
                store.finishGenericOwner(&pending_out_of_range, .{ .runtime = .{
                    .owner = out_of_range,
                    .view = runtime.view(),
                } }),
            );
            store.cancelGenericOwner(&pending_out_of_range);
        }
    }
    {
        const source = "<T>x";
        var store = Store.init(std.testing.allocator, source);
        defer store.deinit();
        var runtime = TestRuntime.init(std.testing.allocator);
        defer runtime.deinit();
        const call = try runtime.addCall(3);
        var pending = try store.reserveExplicitCall(.{
            .list_span = .{ .start = 0, .end = 3 },
            .capture_spans = .{
                .actual_erased_span = .{ .start = 0, .end = 3 },
                .legacy_recorded_span = .{ .start = 1, .end = 2 },
            },
        });
        try std.testing.expectError(
            error.InvalidGenericOwner,
            store.finishExplicitCall(&pending, call, runtime.view()),
        );
        store.cancelExplicitCall(&pending);
    }
    {
        const source = "<T>";
        var store = Store.init(std.testing.allocator, source);
        defer store.deinit();
        var runtime = TestRuntime.init(std.testing.allocator);
        defer runtime.deinit();
        const call = try runtime.addCall(@intCast(source.len));
        var pending = try store.reserveExplicitCall(.{
            .list_span = .{ .start = 0, .end = @intCast(source.len) },
            .capture_spans = .{
                .actual_erased_span = .{ .start = 0, .end = @intCast(source.len) },
                .legacy_recorded_span = .{ .start = 1, .end = @intCast(source.len - 1) },
            },
        });
        try std.testing.expectError(
            error.InvalidGenericOwner,
            store.finishExplicitCall(&pending, call, runtime.view()),
        );
        store.cancelExplicitCall(&pending);
    }
}

test "runtime owners reject captures extending through their opener" {
    const source = "<T>()";
    var store = Store.init(std.testing.allocator, source);
    defer store.deinit();
    var runtime = TestRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    const before = store.checkpoint();
    const captures: GenericCaptureSpans = .{
        .actual_erased_span = .{ .start = 0, .end = 4 },
        .legacy_recorded_span = .{ .start = 1, .end = 2 },
    };
    inline for (.{ ir.NodeTag.function_expr, ir.NodeTag.arrow_function }) |tag| {
        const owner = try runtime.addFunction(tag, 3);
        var pending = try store.reserveGenericOwner(.{
            .list_span = .{ .start = 0, .end = 3 },
            .capture_spans = captures,
            .policy = .callable,
        });
        try std.testing.expectError(
            error.InvalidGenericOwner,
            store.finishGenericOwner(&pending, .{ .runtime = .{
                .owner = owner,
                .view = runtime.view(),
            } }),
        );
        store.cancelGenericOwner(&pending);
        try std.testing.expect(std.meta.eql(before, store.checkpoint()));
    }
    const call = try runtime.addCall(3);
    var pending_call = try store.reserveExplicitCall(.{
        .list_span = .{ .start = 0, .end = 3 },
        .capture_spans = captures,
    });
    try std.testing.expectError(
        error.InvalidGenericOwner,
        store.finishExplicitCall(&pending_call, call, runtime.view()),
    );
    store.cancelExplicitCall(&pending_call);
    try std.testing.expect(std.meta.eql(before, store.checkpoint()));
}

test "legacy compatibility and explicit calls own distinct shared ranges" {
    const source = "<string>(";
    var store = Store.init(std.testing.allocator, source);
    defer store.deinit();
    var runtime = TestRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    const function = try runtime.addFunction(.function_expr, 8);
    const call = try runtime.addCall(8);
    const capture_spans: GenericCaptureSpans = .{
        .actual_erased_span = .{ .start = 0, .end = 8 },
        .legacy_recorded_span = .{ .start = 0, .end = 8 },
    };

    var compatibility = try store.reserveGenericOwner(.{
        .list_span = .{ .start = 0, .end = 8 },
        .capture_spans = capture_spans,
        .policy = .legacy_call,
    });
    try store.finishGenericOwner(&compatibility, .{ .runtime = .{
        .owner = function,
        .view = runtime.view(),
    } });
    var explicit = try store.reserveExplicitCall(.{
        .list_span = .{ .start = 0, .end = 8 },
        .capture_spans = capture_spans,
    });
    try store.finishExplicitCall(&explicit, call, runtime.view());
    try store.validateRuntimeOwners(std.testing.allocator, runtime.view());

    const compatibility_ranges = switch (store.generic_owners.items[0].compatibility) {
        .legacy_call_arguments => |ranges| ranges,
        else => return error.TestUnexpectedResult,
    };
    const original_arguments = store.explicit_call_arguments.items[0].authored_arguments;
    const original_fragments = store.explicit_call_arguments.items[0].semantic_fragments;

    store.explicit_call_arguments.items[0].authored_arguments = compatibility_ranges.authored_arguments;
    try std.testing.expectError(
        error.SharedAuthoredCallArgument,
        store.validateRuntimeOwners(std.testing.allocator, runtime.view()),
    );
    store.explicit_call_arguments.items[0].authored_arguments = original_arguments;

    store.explicit_call_arguments.items[0].semantic_fragments = compatibility_ranges.semantic_fragments;
    try std.testing.expectError(
        error.SharedSemanticFragment,
        store.validateRuntimeOwners(std.testing.allocator, runtime.view()),
    );
    store.explicit_call_arguments.items[0].semantic_fragments = original_fragments;

    store.explicit_call_arguments.items[0].authored_arguments.count = 0;
    try std.testing.expectError(
        error.UnownedAuthoredCallArgument,
        store.validateRuntimeOwners(std.testing.allocator, runtime.view()),
    );
    store.explicit_call_arguments.items[0].authored_arguments = original_arguments;

    store.explicit_call_arguments.items[0].semantic_fragments.count = 0;
    try std.testing.expectError(
        error.UnownedSemanticFragment,
        store.validateRuntimeOwners(std.testing.allocator, runtime.view()),
    );
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

test "explicit call scanner separates its depth exclusion from comparisons" {
    var boundary: std.ArrayListUnmanaged(u8) = .empty;
    defer boundary.deinit(std.testing.allocator);
    try boundary.appendSlice(std.testing.allocator, "id<");
    try boundary.appendNTimes(std.testing.allocator, '<', max_type_depth - 1);
    try boundary.append(std.testing.allocator, 'T');
    try boundary.appendNTimes(std.testing.allocator, '>', max_type_depth);
    try boundary.appendSlice(std.testing.allocator, "(value)");
    switch (try scanExplicitCallTypeArguments(std.testing.allocator, boundary.items, 2)) {
        .scanned => |scan| try std.testing.expectEqual(
            @as(u32, @intCast(boundary.items.len - "(value)".len)),
            scan.span.end,
        ),
        .not_call, .excluded => return error.TestUnexpectedResult,
    }

    var excluded: std.ArrayListUnmanaged(u8) = .empty;
    defer excluded.deinit(std.testing.allocator);
    try excluded.appendSlice(std.testing.allocator, "id<");
    try excluded.appendNTimes(std.testing.allocator, '<', max_type_depth);
    try excluded.append(std.testing.allocator, 'T');
    try excluded.appendNTimes(std.testing.allocator, '>', max_type_depth + 1);
    try excluded.appendSlice(std.testing.allocator, "(value)");
    switch (try scanExplicitCallTypeArguments(std.testing.allocator, excluded.items, 2)) {
        .excluded => {},
        .not_call, .scanned => return error.TestUnexpectedResult,
    }
    switch (try scanExplicitCallTypeArguments(
        std.testing.allocator,
        "seed < other >> 1",
        5,
    )) {
        .not_call => {},
        .excluded, .scanned => return error.TestUnexpectedResult,
    }
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

test "admission generic scanner reports raw angle and bracket depth" {
    var angle_limit: std.ArrayListUnmanaged(u8) = .empty;
    defer angle_limit.deinit(std.testing.allocator);
    try angle_limit.appendNTimes(std.testing.allocator, '<', max_type_depth);
    try angle_limit.append(std.testing.allocator, 'T');
    try angle_limit.appendNTimes(std.testing.allocator, '>', max_type_depth);
    var caught: std.ArrayListUnmanaged(AdmissionDiagnostic) = .empty;
    defer caught.deinit(std.testing.allocator);
    switch (try scanAdmissionGenericList(std.testing.allocator, .{
        .source = angle_limit.items,
        .start = 0,
        .caught = &caught,
    })) {
        .scanned => |scan| try std.testing.expectEqual(
            @as(u32, @intCast(angle_limit.items.len)),
            scan.span.end,
        ),
        .not_matched, .lexical_nonmatch, .nesting_too_deep => return error.TestUnexpectedResult,
    }

    var angle_overflow: std.ArrayListUnmanaged(u8) = .empty;
    defer angle_overflow.deinit(std.testing.allocator);
    try angle_overflow.appendNTimes(std.testing.allocator, '<', max_type_depth + 1);
    switch (try scanAdmissionGenericList(std.testing.allocator, .{
        .source = angle_overflow.items,
        .start = 0,
        .caught = &caught,
    })) {
        .nesting_too_deep => |offset| try std.testing.expectEqual(
            @as(u32, max_type_depth),
            offset,
        ),
        .not_matched, .lexical_nonmatch, .scanned => return error.TestUnexpectedResult,
    }

    var bracket_limit: std.ArrayListUnmanaged(u8) = .empty;
    defer bracket_limit.deinit(std.testing.allocator);
    try bracket_limit.append(std.testing.allocator, '<');
    try bracket_limit.appendNTimes(std.testing.allocator, '(', max_type_depth);
    try bracket_limit.append(std.testing.allocator, 'T');
    try bracket_limit.appendNTimes(std.testing.allocator, ')', max_type_depth);
    try bracket_limit.append(std.testing.allocator, '>');
    switch (try scanAdmissionGenericList(std.testing.allocator, .{
        .source = bracket_limit.items,
        .start = 0,
        .caught = &caught,
    })) {
        .scanned => {},
        .not_matched, .lexical_nonmatch, .nesting_too_deep => return error.TestUnexpectedResult,
    }

    var bracket_overflow: std.ArrayListUnmanaged(u8) = .empty;
    defer bracket_overflow.deinit(std.testing.allocator);
    try bracket_overflow.append(std.testing.allocator, '<');
    try bracket_overflow.appendNTimes(std.testing.allocator, '(', max_type_depth + 1);
    switch (try scanAdmissionGenericList(std.testing.allocator, .{
        .source = bracket_overflow.items,
        .start = 0,
        .caught = &caught,
    })) {
        .nesting_too_deep => |offset| try std.testing.expectEqual(
            @as(u32, max_type_depth) + 1,
            offset,
        ),
        .not_matched, .lexical_nonmatch, .scanned => return error.TestUnexpectedResult,
    }
    try std.testing.expect((try scanBalancedGenericList(
        std.testing.allocator,
        bracket_overflow.items,
        0,
    )) == null);

    var template_overflow: std.ArrayListUnmanaged(u8) = .empty;
    defer template_overflow.deinit(std.testing.allocator);
    try template_overflow.appendSlice(std.testing.allocator, "<`x${");
    try template_overflow.appendNTimes(
        std.testing.allocator,
        '{',
        max_type_depth - 1,
    );
    const template_failure_offset: u32 = @intCast(template_overflow.items.len);
    try template_overflow.append(std.testing.allocator, '{');
    switch (try scanAdmissionGenericList(std.testing.allocator, .{
        .source = template_overflow.items,
        .start = 0,
        .caught = &caught,
    })) {
        .lexical_nonmatch => {},
        .not_matched, .scanned, .nesting_too_deep => return error.TestUnexpectedResult,
    }
    try std.testing.expectEqual(@as(usize, 1), caught.items.len);
    try std.testing.expectEqual(AdmissionKind.nesting_too_deep, caught.items[0].kind);
    try std.testing.expectEqual(
        Span{ .start = template_failure_offset, .end = template_failure_offset + 1 },
        caught.items[0].span,
    );
}

test "admission call scanner retains caught rows before a grammar nonmatch" {
    const source = "const value = f<`a${\"open\n 1}tail` || T>(x);\n";
    const list_start: u32 = @intCast(std.mem.indexOfScalar(u8, source, '<').?);
    var caught: std.ArrayListUnmanaged(AdmissionDiagnostic) = .empty;
    defer caught.deinit(std.testing.allocator);

    switch (try scanAdmissionCallTypeArguments(std.testing.allocator, .{
        .source = source,
        .start = list_start,
        .caught = &caught,
    })) {
        .not_matched => {},
        .lexical_nonmatch, .scanned, .nesting_too_deep => return error.TestUnexpectedResult,
    }
    try std.testing.expectEqual(@as(usize, 1), caught.items.len);
    try std.testing.expectEqual(AdmissionKind.unterminated_string, caught.items[0].kind);
    try std.testing.expectEqual(Span{ .start = 25, .end = 26 }, caught.items[0].span);
    switch (try scanExplicitCallTypeArguments(std.testing.allocator, source, list_start)) {
        .not_call => {},
        .excluded, .scanned => return error.TestUnexpectedResult,
    }

    caught.clearRetainingCapacity();
    const lexical_source = "id<\"open\n>(value)";
    switch (try scanAdmissionCallTypeArguments(std.testing.allocator, .{
        .source = lexical_source,
        .start = 2,
        .caught = &caught,
    })) {
        .lexical_nonmatch => {},
        .not_matched, .scanned, .nesting_too_deep => return error.TestUnexpectedResult,
    }
    try std.testing.expectEqual(@as(usize, 1), caught.items.len);
    try std.testing.expectEqual(AdmissionKind.unterminated_string, caught.items[0].kind);
    try std.testing.expectEqual(Span{ .start = 8, .end = 9 }, caught.items[0].span);
    switch (try scanExplicitCallTypeArguments(std.testing.allocator, lexical_source, 2)) {
        .excluded => {},
        .not_call, .scanned => return error.TestUnexpectedResult,
    }

    caught.clearRetainingCapacity();
    var depth_source: std.ArrayListUnmanaged(u8) = .empty;
    defer depth_source.deinit(std.testing.allocator);
    try depth_source.append(std.testing.allocator, '<');
    try depth_source.appendNTimes(std.testing.allocator, '(', max_type_depth);
    switch (try scanAdmissionCallTypeArguments(std.testing.allocator, .{
        .source = depth_source.items,
        .start = 0,
        .caught = &caught,
    })) {
        .nesting_too_deep => |offset| try std.testing.expectEqual(
            @as(u32, max_type_depth),
            offset,
        ),
        .not_matched, .lexical_nonmatch, .scanned => return error.TestUnexpectedResult,
    }
    switch (try scanExplicitCallTypeArguments(std.testing.allocator, depth_source.items, 0)) {
        .excluded => {},
        .not_call, .scanned => return error.TestUnexpectedResult,
    }

    caught.clearRetainingCapacity();
    const accepted = "id<(value: string) => number>(value)";
    switch (try scanAdmissionCallTypeArguments(std.testing.allocator, .{
        .source = accepted,
        .start = 2,
        .caught = &caught,
    })) {
        .scanned => |scan| try std.testing.expectEqualStrings(
            "<(value: string) => number>",
            scan.span.text(accepted),
        ),
        .not_matched, .lexical_nonmatch, .nesting_too_deep => return error.TestUnexpectedResult,
    }
}

test "admission interface brace scanner preserves raw legacy boundaries" {
    const quoted_source = "interface X extends { field: \"open\n next: any } trailing";
    const body_start: u32 = @intCast(std.mem.indexOfScalar(u8, quoted_source, '{').?);
    const body_end: u32 = @intCast(std.mem.indexOfScalar(u8, quoted_source, '}').? + 1);
    var caught: std.ArrayListUnmanaged(AdmissionDiagnostic) = .empty;
    defer caught.deinit(std.testing.allocator);

    switch (try scanAdmissionBraceBody(std.testing.allocator, .{
        .source = quoted_source,
        .start = body_start,
        .caught = &caught,
    })) {
        .complete => |end| try std.testing.expectEqual(body_end, end),
        .nesting_too_deep => return error.TestUnexpectedResult,
    }
    try std.testing.expectEqual(@as(usize, 1), caught.items.len);
    try std.testing.expectEqual(AdmissionKind.unterminated_string, caught.items[0].kind);
    try std.testing.expectEqual(
        @as(u32, @intCast(std.mem.indexOfScalar(u8, quoted_source, '\n').?)),
        caught.items[0].span.start,
    );

    caught.clearRetainingCapacity();
    const comment_source = "interface X extends { /* } */ field: any } trailing";
    const comment_body: u32 = @intCast(std.mem.indexOfScalar(u8, comment_source, '{').?);
    const comment_close: u32 = @intCast(std.mem.indexOfScalar(u8, comment_source, '}').? + 1);
    switch (try scanAdmissionBraceBody(std.testing.allocator, .{
        .source = comment_source,
        .start = comment_body,
        .caught = &caught,
    })) {
        .complete => |end| try std.testing.expectEqual(comment_close, end),
        .nesting_too_deep => return error.TestUnexpectedResult,
    }
    try std.testing.expectEqual(@as(usize, 0), caught.items.len);

    const eof_source = "{ field: number";
    switch (try scanAdmissionBraceBody(std.testing.allocator, .{
        .source = eof_source,
        .start = 0,
        .caught = &caught,
    })) {
        .complete => |end| try std.testing.expectEqual(@as(u32, eof_source.len), end),
        .nesting_too_deep => return error.TestUnexpectedResult,
    }

    var overflow: std.ArrayListUnmanaged(u8) = .empty;
    defer overflow.deinit(std.testing.allocator);
    try overflow.appendNTimes(std.testing.allocator, '{', max_type_depth + 1);
    switch (try scanAdmissionBraceBody(std.testing.allocator, .{
        .source = overflow.items,
        .start = 0,
        .caught = &caught,
    })) {
        .nesting_too_deep => |offset| try std.testing.expectEqual(
            @as(u32, max_type_depth),
            offset,
        ),
        .complete => return error.TestUnexpectedResult,
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
    var observed_failures = [_]usize{0} ** cases.len;
    for (cases, 0..) |case, index| {
        try std.testing.checkAllAllocationFailures(
            std.testing.allocator,
            Context.run,
            .{ case, &observed_failures[index] },
        );
        try std.testing.expect(observed_failures[index] > 0);
    }
}

test "generic application admission rejects a missing closing angle before syntax parsing" {
    const source = "Outer<string = value;";
    var store = Store.init(std.testing.allocator, source);
    defer store.deinit();
    var cursor = Cursor.init(source);
    const before = cursor;
    const outcome = try parseAndStore(&store, .global(300), source, 0, &cursor);
    switch (outcome) {
        .excluded => |excluded| switch (excluded.reason) {
            .malformed_syntax => {},
            else => return error.TestUnexpectedResult,
        },
        .parsed, .failure => return error.TestUnexpectedResult,
    }
    try std.testing.expect(std.meta.eql(before, cursor));
    try std.testing.expect(std.meta.eql(store.checkpoint(), Store.Checkpoint{
        .nodes = 0,
        .members = 0,
        .fields = 0,
        .params = 0,
        .template_parts = 0,
        .annotations = 0,
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
    }));
}

test "type owners reject direct indirect and overlapping cross-owner ranges" {
    const Case = enum {
        direct_child,
        indirect_member_child,
        application_base,
        application_argument,
        overlap,
    };
    inline for (std.meta.tags(Case)) |case| {
        const source = switch (case) {
            .direct_child => "(number) = first; (string) = second;",
            .indirect_member_child => "[number] = first; [string] = second;",
            .application_base, .application_argument => "Outer<number> = first; Outer<string> = second;",
            .overlap => "number = first; string = second;",
        };
        var store = Store.init(std.testing.allocator, source);
        defer store.deinit();
        var first = Cursor.init(source);
        switch (try parseAndStore(&store, .global(300), source, 0, &first)) {
            .parsed => {},
            .failure, .excluded => return error.TestUnexpectedResult,
        }
        const second_start: u32 = @intCast(std.mem.indexOf(u8, source, switch (case) {
            .direct_child => "(string)",
            .indirect_member_child => "[string]",
            .application_base, .application_argument => "Outer<string>",
            .overlap => "string",
        }).?);
        var second = Cursor.init(source);
        while (second.current.type != .eof and second.current.start < second_start) second.advance();
        switch (try parseAndStore(&store, .global(301), source, second_start, &second)) {
            .parsed => {},
            .failure, .excluded => return error.TestUnexpectedResult,
        }
        try store.validate();

        switch (case) {
            .direct_child => {
                const root = switch (store.annotations.items[1].root) {
                    .absent => return error.TestUnexpectedResult,
                    .present => |index| index,
                };
                store.nodes.items[root].data.group.child = .{ .present = 0 };
                try std.testing.expectError(error.InvalidTypeChild, store.validate());
            },
            .indirect_member_child => {
                const root = switch (store.annotations.items[1].root) {
                    .absent => return error.TestUnexpectedResult,
                    .present => |index| index,
                };
                const range = store.nodes.items[root].data.tuple;
                store.members.items[range.start] = .{ .present = 0 };
                try std.testing.expectError(error.InvalidTypeChild, store.validate());
            },
            .application_base, .application_argument => {
                const first_root = switch (store.annotations.items[0].root) {
                    .absent => return error.TestUnexpectedResult,
                    .present => |index| index,
                };
                const second_root = switch (store.annotations.items[1].root) {
                    .absent => return error.TestUnexpectedResult,
                    .present => |index| index,
                };
                const application = &store.nodes.items[second_root].data.generic_application;
                switch (case) {
                    .application_base => application.base = .{ .present = first_root },
                    .application_argument => {
                        store.members.items[application.arguments.start] = .{ .present = first_root };
                    },
                    else => unreachable,
                }
                try std.testing.expectError(error.InvalidTypeChild, store.validate());
            },
            .overlap => {
                store.annotations.items[1].node_range = .{ .start = 0, .count = 2 };
                try std.testing.expectError(error.OverlappingTypeNodeOwnership, store.validate());
            },
        }
    }
}

test "application base plan rejects nonexclusive base nodes" {
    const Case = enum {
        absent,
        wrong_kind,
        reused_as_argument,
        shared_by_applications,
        owner_root,
    };
    inline for (std.meta.tags(Case)) |case| {
        const source = if (case == .shared_by_applications)
            "[Outer<number>, Inner<string>] = value;"
        else
            "Outer<number> = value;";
        var store = Store.init(std.testing.allocator, source);
        defer store.deinit();
        var cursor = Cursor.init(source);
        switch (try parseAndStore(&store, .global(300), source, 0, &cursor)) {
            .parsed => {},
            .failure, .excluded => return error.TestUnexpectedResult,
        }
        try store.validate();

        const annotation = &store.annotations.items[0];
        const first_application_index: NodeIndex = switch (case) {
            .shared_by_applications => blk: {
                const tuple_index = switch (annotation.root) {
                    .absent => return error.TestUnexpectedResult,
                    .present => |index| index,
                };
                const tuple = store.nodes.items[tuple_index].data.tuple;
                break :blk switch (store.members.items[tuple.start]) {
                    .absent => return error.TestUnexpectedResult,
                    .present => |index| index,
                };
            },
            else => switch (annotation.root) {
                .absent => return error.TestUnexpectedResult,
                .present => |index| index,
            },
        };
        const first_application = &store.nodes.items[first_application_index].data.generic_application;
        const first_base = first_application.base;
        switch (case) {
            .absent => first_application.base = .absent,
            .wrong_kind => {
                const base_index = switch (first_base) {
                    .absent => return error.TestUnexpectedResult,
                    .present => |index| index,
                };
                store.nodes.items[base_index].tag = .primitive;
                store.nodes.items[base_index].data = .{ .primitive = .number };
            },
            .reused_as_argument => {
                const arguments = first_application.arguments;
                store.members.items[arguments.start] = first_base;
            },
            .shared_by_applications => {
                const tuple_index = switch (annotation.root) {
                    .absent => return error.TestUnexpectedResult,
                    .present => |index| index,
                };
                const tuple = store.nodes.items[tuple_index].data.tuple;
                const second_application_index = switch (store.members.items[tuple.start + 1]) {
                    .absent => return error.TestUnexpectedResult,
                    .present => |index| index,
                };
                store.nodes.items[second_application_index].data.generic_application.base = first_base;
            },
            .owner_root => annotation.root = first_base,
        }
        try store.validate();
        const expected = if (case == .shared_by_applications)
            error.SharedGenericApplicationBase
        else
            error.InvalidGenericApplicationBase;
        try std.testing.expectError(
            expected,
            store.planApplicationBases(std.testing.allocator),
        );
    }
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
            .legacy_recorded_span = .{ .start = 1, .end = 7 },
        },
        .authored_arguments = .{ .start = 0, .count = 0 },
        .semantic_fragments = .{ .start = fragment_index, .count = 1 },
    });
    var valid = try store.planApplicationBasesWithIr(std.testing.allocator, runtime.view());
    valid.deinit();

    try store.projected_generic_parameters.append(std.testing.allocator, .{
        .raw_span = .{ .start = 1, .end = 7 },
        .name_span = .{ .start = 1, .end = 1 },
        .legacy_bound_span = .{ .start = 1, .end = 7 },
        .bound_fragment = fragment_index,
    });
    try store.generic_owners.append(std.testing.allocator, .{
        .identity = .{ .function = function },
        .list_span = .{ .start = 0, .end = 8 },
        .capture_spans = .{
            .actual_erased_span = .{ .start = 0, .end = 8 },
            .legacy_recorded_span = .{ .start = 1, .end = 7 },
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

test "structural generic owner rejects a nominal declaration backlink" {
    const source = "structural Box<T> = number;";
    var store = Store.init(std.testing.allocator, source);
    defer store.deinit();
    var cursor = Cursor.init(source);
    const keyword = cursor.current;
    cursor.advance();
    switch (try parseDeclarationAndStore(
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
    try store.validate();
    store.declarations.items[0].kind = .nominal;
    try std.testing.expectError(error.InvalidGenericOwner, store.validate());
    store.declarations.items[0].kind = .structural;
    store.generic_owners.items[0].identity = .{ .structural_declaration = 1 };
    try std.testing.expectError(error.InvalidGenericOwner, store.validate());
}

test "nominal generic declaration owns its ignored parameter list" {
    const source = "nominal Id<T> = string;";
    var store = Store.init(std.testing.allocator, source);
    defer store.deinit();
    var cursor = Cursor.init(source);
    const keyword = cursor.current;
    cursor.advance();
    switch (try parseDeclarationAndStore(
        &store,
        source,
        keyword,
        null,
        .nominal,
        0,
        &cursor,
    )) {
        .parsed => {},
        .not_declaration, .excluded => return error.TestUnexpectedResult,
    }
    try store.validate();
    try std.testing.expectEqual(token_mod.TokenType.eof, cursor.current.type);
    try std.testing.expectEqual(@as(usize, 1), store.declarations.items.len);
    try std.testing.expectEqual(@as(usize, 1), store.generic_owners.items.len);
    try std.testing.expectEqual(@as(?u32, 0), store.declarations.items[0].generic_owner);

    const owner = store.generic_owners.items[0];
    switch (owner.identity) {
        .nominal_declaration => |index| try std.testing.expectEqual(@as(u32, 0), index),
        else => return error.TestUnexpectedResult,
    }
    switch (owner.compatibility) {
        .ignored_declaration_parameters => {},
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expectEqualStrings("<T>", owner.list_span.text(source));
    try std.testing.expect(std.meta.eql(owner.list_span, owner.capture_spans.actual_erased_span));
    try std.testing.expect(std.meta.eql(owner.list_span, owner.capture_spans.legacy_recorded_span));
    const authored = store.genericParameterSlice(owner.authored_parameters) orelse
        return error.TestUnexpectedResult;
    const projected = store.projectedGenericParameterSlice(owner.projected_parameters) orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 1), authored.len);
    try std.testing.expectEqualStrings("T", authored[0].trimmed_span.text(source));
    try std.testing.expectEqual(@as(usize, 1), projected.len);
    try std.testing.expectEqualStrings("T", projected[0].name_span.text(source));
    try std.testing.expect(projected[0].bound_fragment == null);
    try std.testing.expectEqual(@as(usize, 0), store.semantic_fragments.items.len);

    const identity = store.generic_owners.items[0].identity;
    store.generic_owners.items[0].identity = .{ .nominal_declaration = 1 };
    try std.testing.expectError(error.InvalidGenericOwner, store.validate());
    store.generic_owners.items[0].identity = .{ .structural_declaration = 0 };
    try std.testing.expectError(error.InvalidGenericOwner, store.validate());
    store.generic_owners.items[0].identity = identity;
    try store.validate();
}

test "nominal generic scalar refusal restores the prior declaration" {
    const source = "nominal Seed<S> = number;\nnominal Bad<T> = T;";
    var store = Store.init(std.testing.allocator, source);
    defer store.deinit();
    var cursor = Cursor.init(source);
    const seed_keyword = cursor.current;
    cursor.advance();
    switch (try parseDeclarationAndStore(
        &store,
        source,
        seed_keyword,
        null,
        .nominal,
        0,
        &cursor,
    )) {
        .parsed => {},
        .not_declaration, .excluded => return error.TestUnexpectedResult,
    }
    const prior = store.checkpoint();
    const keyword = cursor.current;
    cursor.advance();
    const before = cursor;
    switch (try parseDeclarationAndStore(
        &store,
        source,
        keyword,
        null,
        .nominal,
        0,
        &cursor,
    )) {
        .excluded => |excluded| {
            try std.testing.expectEqual(@TypeOf(excluded.reason).nominal_base_not_scalar, excluded.reason);
            try std.testing.expectEqualStrings("T", excluded.raw_span.text(source));
            try std.testing.expectEqualStrings(
                "<T>",
                (excluded.generic_list_span orelse return error.TestUnexpectedResult).text(source),
            );
        },
        .parsed, .not_declaration => return error.TestUnexpectedResult,
    }
    try std.testing.expect(std.meta.eql(before, cursor));
    try std.testing.expect(std.meta.eql(prior, store.checkpoint()));
    try std.testing.expectEqual(@as(usize, 1), store.declarations.items.len);
    try std.testing.expectEqual(@as(usize, 1), store.generic_owners.items.len);
    try store.validate();
}

test "generic syntax resumes combined operator tokens at exact boundaries" {
    {
        const source = "structural Box<=string,T extends number> = T;";
        var store = Store.init(std.testing.allocator, source);
        defer store.deinit();
        var cursor = Cursor.init(source);
        const keyword = cursor.current;
        cursor.advance();
        switch (try parseDeclarationAndStore(
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
        const owner = store.generic_owners.items[0];
        const projected = store.projectedGenericParameterSlice(owner.projected_parameters) orelse
            return error.TestUnexpectedResult;
        try std.testing.expectEqual(@as(usize, 2), projected.len);
        try std.testing.expectEqualStrings("", projected[0].name_span.text(source));
        try std.testing.expectEqual(.eof, cursor.current.type);
    }
    {
        const source = "structural Box<<T>> = number;";
        var store = Store.init(std.testing.allocator, source);
        defer store.deinit();
        var cursor = Cursor.init(source);
        const keyword = cursor.current;
        cursor.advance();
        switch (try parseDeclarationAndStore(
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
        const owner = store.generic_owners.items[0];
        try std.testing.expectEqualStrings("<<T>>", owner.list_span.text(source));
        try std.testing.expect(std.meta.eql(owner.list_span, owner.capture_spans.actual_erased_span));
        try std.testing.expect(std.meta.eql(owner.list_span, owner.capture_spans.legacy_recorded_span));
        const projected = store.projectedGenericParameterSlice(owner.projected_parameters) orelse
            return error.TestUnexpectedResult;
        try std.testing.expectEqual(@as(usize, 1), projected.len);
        try std.testing.expectEqualStrings("<T>", projected[0].name_span.text(source));
        try std.testing.expectEqual(.eof, cursor.current.type);
    }
    {
        const source = "structural Box<T>=T;";
        var store = Store.init(std.testing.allocator, source);
        defer store.deinit();
        var cursor = Cursor.init(source);
        const keyword = cursor.current;
        cursor.advance();
        switch (try parseDeclarationAndStore(
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
        switch (store.declarations.items[0].body) {
            .present => {},
            .absent => return error.TestUnexpectedResult,
        }
        try std.testing.expectEqual(.eof, cursor.current.type);
    }
    {
        const source = "Box<number>=value;";
        var store = Store.init(std.testing.allocator, source);
        defer store.deinit();
        var cursor = Cursor.init(source);
        switch (try parseAndStore(&store, .global(300), source, 0, &cursor)) {
            .parsed => {},
            .failure, .excluded => return error.TestUnexpectedResult,
        }
        const equals = std.mem.indexOfScalar(u8, source, '=') orelse return error.TestUnexpectedResult;
        try std.testing.expectEqual(token_mod.TokenType.assign, cursor.current.type);
        try std.testing.expectEqual(@as(u32, @intCast(equals)), cursor.current.start);
        try std.testing.expectEqual(@as(u32, @intCast(equals + 1)), cursor.tokenizer.saveState().pos);
        cursor.advance();
        try std.testing.expectEqualStrings("value", cursor.current.text(source));
    }
}

test "generic syntax excludes diagnostics swallowed inside bracket groups" {
    const Context = struct {
        fn expectExcluded(source: []const u8) !void {
            var store = Store.init(std.testing.allocator, source);
            defer store.deinit();
            var cursor = Cursor.init(source);
            const keyword = cursor.current;
            cursor.advance();
            const before = cursor;
            switch (try parseDeclarationAndStore(
                &store,
                source,
                keyword,
                null,
                .structural,
                0,
                &cursor,
            )) {
                .excluded => |excluded| try std.testing.expectEqual(
                    @TypeOf(excluded.reason).unsupported_syntax,
                    excluded.reason,
                ),
                .parsed, .not_declaration => return error.TestUnexpectedResult,
            }
            try std.testing.expect(std.meta.eql(before, cursor));
            try std.testing.expectEqual(@as(usize, 0), store.generic_owners.items.len);
            try std.testing.expectEqual(@as(usize, 0), store.declarations.items.len);
        }
    };

    try Context.expectExcluded("structural Box<T = (\"x\n)> = number;");
    try Context.expectExcluded("structural Box<T = /> = number;");

    var nested_template: std.ArrayListUnmanaged(u8) = .empty;
    defer nested_template.deinit(std.testing.allocator);
    try nested_template.appendSlice(std.testing.allocator, "structural Box<T = (`${");
    try nested_template.appendNTimes(std.testing.allocator, '{', max_type_depth);
    try nested_template.appendSlice(std.testing.allocator, ")> = number;");
    try Context.expectExcluded(nested_template.items);

    var balanced_template: std.ArrayListUnmanaged(u8) = .empty;
    defer balanced_template.deinit(std.testing.allocator);
    try balanced_template.appendSlice(std.testing.allocator, "structural Box<T = ");
    for (0..max_type_depth + 1) |_| {
        try balanced_template.appendSlice(std.testing.allocator, "`${");
    }
    try balanced_template.appendSlice(std.testing.allocator, "string");
    for (0..max_type_depth + 1) |_| {
        try balanced_template.appendSlice(std.testing.allocator, "}`");
    }
    try balanced_template.appendSlice(std.testing.allocator, ", U> = number;");
    try Context.expectExcluded(balanced_template.items);
}

test "type store validation rejects invalid nodes without erasing prior syntax" {
    const Case = enum { tag, range, child, span };
    inline for (std.meta.tags(Case)) |case| {
        var store = Store.init(std.testing.allocator, "number");
        defer store.deinit();
        try store.add(.global(300), .{
            .primitive = .number,
            .semantic_span = .{ .start = 0, .end = 6 },
            .raw_span = .{ .start = 0, .end = 6 },
        });
        const prior = store.checkpoint();
        const index: NodeIndex = @intCast(store.nodes.items.len);
        const invalid: Node = switch (case) {
            .tag => .{
                .tag = .primitive,
                .semantic_span = .{ .start = 0, .end = 6 },
                .data = .{ .group = .{
                    .child = .absent,
                    .attempted_params = .{ .start = 0, .count = 0 },
                } },
            },
            .range => .{
                .tag = .record,
                .semantic_span = .{ .start = 0, .end = 6 },
                .data = .{ .record = .{ .start = 1, .count = 1 } },
            },
            .child => .{
                .tag = .group,
                .semantic_span = .{ .start = 0, .end = 6 },
                .data = .{ .group = .{
                    .child = .{ .present = index },
                    .attempted_params = .{ .start = 0, .count = 0 },
                } },
            },
            .span => .{
                .tag = .primitive,
                .semantic_span = .{ .start = 0, .end = 7 },
                .data = .{ .primitive = .number },
            },
        };
        try store.nodes.append(store.allocator, invalid);
        const expected: anyerror = switch (case) {
            .tag => error.InvalidTypeNodeTag,
            .range => error.InvalidTypeRange,
            .child => error.InvalidTypeChild,
            .span => error.InvalidTypeSpan,
        };
        try std.testing.expectError(
            expected,
            store.validateParsed(.{ .present = index }, .{ .start = 0, .end = 6 }),
        );
        store.rollback(prior);
        try std.testing.expect(std.meta.eql(prior, store.checkpoint()));
        try std.testing.expectEqual(@as(usize, 1), store.annotations.items.len);
    }

    var store = Store.init(std.testing.allocator, "number");
    defer store.deinit();
    try store.add(.global(300), .{
        .primitive = .number,
        .semantic_span = .{ .start = 0, .end = 6 },
        .raw_span = .{ .start = 0, .end = 6 },
    });
    const valid = store.annotations.items[0];
    store.annotations.items[0].root = .{ .present = @intCast(store.nodes.items.len) };
    try std.testing.expectError(error.InvalidTypeChild, store.validate());
    store.annotations.items[0] = valid;
    store.annotations.items[0].admission_end = 7;
    try std.testing.expectError(error.InvalidTypeSpan, store.validate());
    store.annotations.items[0] = valid;
    try store.validate();
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

test "group metadata participates in application planning" {
    const source = "(first: Outer<Left>, Selected) = value;";
    var store = Store.init(std.testing.allocator, source);
    defer store.deinit();
    var cursor = Cursor.init(source);
    switch (try parseAndStore(&store, .global(300), source, 0, &cursor)) {
        .parsed => {},
        .failure, .excluded => return error.TestUnexpectedResult,
    }
    var plan = try store.planApplicationBases(std.testing.allocator);
    defer plan.deinit();
    const annotation = store.annotations.items[0];
    const group = switch (store.nodes.items[
        switch (annotation.root) {
            .absent => return error.TestUnexpectedResult,
            .present => |index| index,
        }
    ].data) {
        .group => |result| result,
        else => return error.TestUnexpectedResult,
    };
    const attempted = store.paramSlice(group.attempted_params) orelse
        return error.TestUnexpectedResult;
    const application = store.nodes.items[
        switch (attempted[0].type_child) {
            .absent => return error.TestUnexpectedResult,
            .present => |index| index,
        }
    ].data.generic_application;
    const base = switch (application.base) {
        .absent => return error.TestUnexpectedResult,
        .present => |index| index,
    };
    try std.testing.expect(plan.contains(base));
    try store.validate();
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

test "admitted annotation publishes a confirmed caught prefix once" {
    const source = "\"open\n";
    const admitted_end: u32 = @intCast(std.mem.indexOfScalar(u8, source, '\n').?);
    var store = Store.init(std.testing.allocator, source);
    defer store.deinit();
    const binding = BindingRef.global(300);

    const value = switch (try parseAdmittedAnnotationAndStore(&store, binding, .{
        .raw_span = .{ .start = 0, .end = admitted_end },
        .admission_end = admitted_end,
    })) {
        .parsed => |parsed| parsed,
        .excluded => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(@as(usize, 1), store.annotations.items.len);
    const annotation = store.annotations.items[0];
    try std.testing.expect(std.meta.eql(binding, annotation.binding));
    try std.testing.expect(std.meta.eql(value.root, annotation.root));
    try std.testing.expect(std.meta.eql(value.node_range, annotation.node_range));
    try std.testing.expectEqualStrings("\"open", annotation.raw_span.text(source));
    const root = switch (annotation.root) {
        .absent => return error.TestUnexpectedResult,
        .present => |index| store.node(index) orelse return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(NodeTag.literal_string, root.tag);
    try store.validate();

    var strict_store = Store.init(std.testing.allocator, source);
    defer strict_store.deinit();
    var cursor = Cursor.init(source);
    switch (try parseAndStore(&strict_store, binding, source, 0, &cursor)) {
        .excluded => |excluded| switch (excluded.reason) {
            .malformed_syntax => {},
            else => return error.TestUnexpectedResult,
        },
        .parsed, .failure => return error.TestUnexpectedResult,
    }
    try std.testing.expectEqual(@as(usize, 0), strict_store.annotations.items.len);
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

test "admitted annotation reuses strict semantic assembly" {
    const source = "number   ;";
    const admission_end: u32 = @intCast(std.mem.indexOfScalar(u8, source, ';').?);
    var strict_store = Store.init(std.testing.allocator, source);
    defer strict_store.deinit();
    var strict_cursor = Cursor.init(source);
    switch (try parseAndStore(&strict_store, .global(300), source, 0, &strict_cursor)) {
        .parsed => {},
        .failure, .excluded => return error.TestUnexpectedResult,
    }

    var admitted_store = Store.init(std.testing.allocator, source);
    defer admitted_store.deinit();
    switch (try parseAdmittedAnnotationAndStore(&admitted_store, .global(300), .{
        .raw_span = .{ .start = 0, .end = 6 },
        .admission_end = admission_end,
    })) {
        .parsed => {},
        .excluded => return error.TestUnexpectedResult,
    }

    try std.testing.expect(std.meta.eql(
        strict_store.checkpoint(),
        admitted_store.checkpoint(),
    ));
    try std.testing.expect(std.meta.eql(
        strict_store.annotations.items[0],
        admitted_store.annotations.items[0],
    ));
    for (strict_store.nodes.items, admitted_store.nodes.items) |strict, admitted| {
        try std.testing.expect(std.meta.eql(strict, admitted));
    }
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
    try store.add(.global(300), .{
        .primitive = .number,
        .semantic_span = .{ .start = 0, .end = 6 },
        .raw_span = .{ .start = 0, .end = 6 },
    });
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

test "admitted declaration preserves body endpoint and generic backlink" {
    const source = "structural Box<T> = { value: T }   ;";
    const generic_start: u32 = @intCast(std.mem.indexOfScalar(u8, source, '<').?);
    const generic_end: u32 = @intCast(std.mem.indexOfScalar(u8, source, '>').? + 1);
    const body_start: u32 = @intCast(std.mem.indexOfScalar(u8, source, '{').?);
    const body_end: u32 = @intCast(std.mem.indexOf(u8, source, "   ;").?);
    const admission_end: u32 = @intCast(std.mem.indexOfScalar(u8, source, ';').?);
    var store = Store.init(std.testing.allocator, source);
    defer store.deinit();
    var cursor = Cursor.init(source);
    const keyword = cursor.current;
    cursor.advance();

    const full_span = switch (try parseAdmittedDeclarationAndStore(&store, .{
        .keyword = keyword,
        .export_span = null,
        .kind = .structural,
        .authored_scope = 7,
        .generic_list = .{ .start = generic_start, .end = generic_end },
        .body = .{
            .raw_span = .{ .start = body_start, .end = body_end },
            .admission_end = admission_end,
        },
    }, &cursor)) {
        .parsed => |span| span,
        .excluded, .not_declaration => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqualStrings(source, full_span.text(source));
    try std.testing.expectEqual(token_mod.TokenType.eof, cursor.current.type);
    try std.testing.expectEqual(@as(usize, 1), store.declarations.items.len);
    try std.testing.expectEqual(@as(usize, 1), store.generic_owners.items.len);
    const declaration = store.declarations.items[0];
    try std.testing.expectEqual(@as(?u32, 0), declaration.generic_owner);
    try std.testing.expectEqual(@as(u16, 7), declaration.authored_scope);
    const body = switch (declaration.body) {
        .present => |present| present,
        .absent => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqualStrings("{ value: T }", body.raw_span.text(source));
    try std.testing.expectEqual(admission_end, body.admission_end);
    switch (store.generic_owners.items[0].identity) {
        .structural_declaration => |index| try std.testing.expectEqual(@as(u32, 0), index),
        else => return error.TestUnexpectedResult,
    }
    try store.validate();
}

test "admitted declaration publishes a confirmed caught generic list" {
    const source =
        "structural Box<T = (\"open\n" ++
        ")> = number; const live = 1;";
    const generic_start: u32 = @intCast(std.mem.indexOfScalar(u8, source, '<').?);
    var caught: std.ArrayListUnmanaged(AdmissionDiagnostic) = .empty;
    defer caught.deinit(std.testing.allocator);
    const generic_scan = switch (try scanAdmissionGenericList(std.testing.allocator, .{
        .source = source,
        .start = generic_start,
        .caught = &caught,
    })) {
        .scanned => |scanned| scanned,
        .not_matched, .lexical_nonmatch, .nesting_too_deep => return error.TestUnexpectedResult,
    };
    try std.testing.expect(generic_scan.suppressed_diagnostic);
    try std.testing.expectEqual(@as(usize, 1), caught.items.len);
    try std.testing.expectEqual(AdmissionKind.unterminated_string, caught.items[0].kind);

    const body_start: u32 = @intCast(std.mem.indexOf(u8, source, "number").?);
    const admission_end: u32 = @intCast(std.mem.indexOfScalar(u8, source, ';').?);
    var store = Store.init(std.testing.allocator, source);
    defer store.deinit();
    var cursor = Cursor.init(source);
    const keyword = cursor.current;
    cursor.advance();
    const full_span = switch (try parseAdmittedDeclarationAndStore(&store, .{
        .keyword = keyword,
        .export_span = null,
        .kind = .structural,
        .authored_scope = 11,
        .generic_list = generic_scan.span,
        .body = .{
            .raw_span = .{ .start = body_start, .end = admission_end },
            .admission_end = admission_end,
        },
    }, &cursor)) {
        .parsed => |span| span,
        .excluded, .not_declaration => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqualStrings(source[0 .. admission_end + 1], full_span.text(source));
    try std.testing.expectEqual(token_mod.TokenType.kw_const, cursor.current.type);
    try std.testing.expectEqual(@as(usize, 1), store.generic_owners.items.len);
    const owner = store.generic_owners.items[0];
    try std.testing.expect(std.meta.eql(generic_scan.span, owner.list_span));
    try std.testing.expect(std.meta.eql(generic_scan.span, owner.capture_spans.actual_erased_span));
    switch (owner.identity) {
        .structural_declaration => |index| try std.testing.expectEqual(@as(u32, 0), index),
        else => return error.TestUnexpectedResult,
    }
    const declaration = store.declarations.items[0];
    try std.testing.expectEqual(@as(?u32, 0), declaration.generic_owner);
    try std.testing.expectEqual(@as(u16, 11), declaration.authored_scope);
    const body = switch (declaration.body) {
        .present => |present| present,
        .absent => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqualStrings("number", body.raw_span.text(source));
    try store.validate();

    var strict_store = Store.init(std.testing.allocator, source);
    defer strict_store.deinit();
    var strict_cursor = Cursor.init(source);
    const strict_keyword = strict_cursor.current;
    strict_cursor.advance();
    const strict_before = strict_cursor;
    switch (try parseDeclarationAndStore(
        &strict_store,
        source,
        strict_keyword,
        null,
        .structural,
        11,
        &strict_cursor,
    )) {
        .excluded => |excluded| try std.testing.expectEqual(
            @TypeOf(excluded.reason).unsupported_syntax,
            excluded.reason,
        ),
        .parsed, .not_declaration => return error.TestUnexpectedResult,
    }
    try std.testing.expect(std.meta.eql(strict_before, strict_cursor));
    try std.testing.expect(std.meta.eql(
        std.mem.zeroes(Store.Checkpoint),
        strict_store.checkpoint(),
    ));
}

test "admitted declaration raw resume preserves caught body endpoints" {
    const Case = enum { quoted, template, strict };
    for (std.meta.tags(Case)) |case| {
        const source = switch (case) {
            .quoted => "structural Value = \"open\n" ++
                "; const live = 1;",
            .template => "structural Value = `x${\"open\n" ++
                "}`; const live = 1;",
            .strict => "structural Value = number; const live = 1;",
        };
        var store = Store.init(std.testing.allocator, source);
        defer store.deinit();
        var cursor = Cursor.init(source);
        const keyword = cursor.current;
        cursor.advance();
        const terminator_start: u32 = @intCast(std.mem.indexOfScalar(u8, source, ';').?);
        const expected_const: u32 = @intCast(std.mem.indexOf(u8, source, "const").?);
        const expected_line: u32 = if (case == .strict) 1 else 2;
        const expected_line_start: u32 = if (case == .strict)
            0
        else
            @intCast(std.mem.indexOfScalar(u8, source, '\n').? + 1);
        const expected_admission_end: u32 = if (case == .quoted)
            expected_line_start - 1
        else
            terminator_start;

        if (case == .strict) {
            switch (try parseDeclarationAndStore(
                &store,
                source,
                keyword,
                null,
                .structural,
                0,
                &cursor,
            )) {
                .parsed => {},
                .excluded, .not_declaration => return error.TestUnexpectedResult,
            }
        } else {
            const assign: u32 = @intCast(std.mem.indexOfScalar(u8, source, '=').?);
            const body_start = skipTypeWhitespace(source, assign + 1);
            var caught: std.ArrayListUnmanaged(AdmissionDiagnostic) = .empty;
            defer caught.deinit(std.testing.allocator);
            const admitted_span = switch (try scanAdmissionEndpoint(
                std.testing.allocator,
                source,
                body_start,
                .declaration,
                &caught,
            )) {
                .complete => |span| span,
                .nesting_too_deep, .unterminated_comment => return error.TestUnexpectedResult,
            };
            try std.testing.expectEqual(@as(usize, 1), caught.items.len);
            try std.testing.expectEqual(AdmissionKind.unterminated_string, caught.items[0].kind);
            const raw_span = trimSpan(source, admitted_span);
            switch (try parseAdmittedDeclarationAndStore(&store, .{
                .keyword = keyword,
                .export_span = null,
                .kind = .structural,
                .authored_scope = 0,
                .body = .{
                    .raw_span = raw_span,
                    .admission_end = admitted_span.end,
                },
            }, &cursor)) {
                .parsed => {},
                .excluded, .not_declaration => return error.TestUnexpectedResult,
            }
        }

        try std.testing.expectEqual(token_mod.TokenType.kw_const, cursor.current.type);
        try std.testing.expectEqual(expected_const, cursor.current.start);
        try std.testing.expectEqual(expected_line, cursor.current.line);
        try std.testing.expectEqual(expected_const - expected_line_start + 1, cursor.current.column);
        try std.testing.expectEqual(@as(usize, 1), store.declarations.items.len);
        const declaration = store.declarations.items[0];
        try std.testing.expectEqual(
            @as(?Span, .{ .start = terminator_start, .end = terminator_start + 1 }),
            declaration.terminator_span,
        );
        try std.testing.expectEqual(
            Span{ .start = 0, .end = terminator_start + 1 },
            declaration.full_span,
        );
        const body = switch (declaration.body) {
            .present => |present| present,
            .absent => return error.TestUnexpectedResult,
        };
        try std.testing.expectEqual(expected_admission_end, body.admission_end);
        try store.validate();
    }
}

test "admitted declaration rejects inconsistent confirmed generic spans" {
    const source = "structural Box<T> = number;";
    const list_start: u32 = @intCast(std.mem.indexOfScalar(u8, source, '<').?);
    const list_end: u32 = @intCast(std.mem.indexOfScalar(u8, source, '>').? + 1);
    const body_start: u32 = @intCast(std.mem.indexOf(u8, source, "number").?);
    const admission_end: u32 = @intCast(std.mem.indexOfScalar(u8, source, ';').?);
    const Case = enum { missing, wrong_start, wrong_angle, out_of_range };
    for (std.meta.tags(Case)) |case| {
        var store = Store.init(std.testing.allocator, source);
        defer store.deinit();
        var cursor = Cursor.init(source);
        const keyword = cursor.current;
        cursor.advance();
        const before_cursor = cursor;
        const prior = store.checkpoint();
        const generic_list: ?Span = switch (case) {
            .missing => null,
            .wrong_start => .{ .start = list_start + 1, .end = list_end },
            .wrong_angle => .{ .start = list_start, .end = list_end - 1 },
            .out_of_range => .{ .start = list_start, .end = @intCast(source.len + 1) },
        };
        try std.testing.expectError(
            error.InvalidAdmissionSpan,
            parseAdmittedDeclarationAndStore(&store, .{
                .keyword = keyword,
                .export_span = null,
                .kind = .structural,
                .authored_scope = 0,
                .generic_list = generic_list,
                .body = .{
                    .raw_span = .{ .start = body_start, .end = admission_end },
                    .admission_end = admission_end,
                },
            }, &cursor),
        );
        try std.testing.expect(std.meta.eql(before_cursor, cursor));
        try std.testing.expect(std.meta.eql(prior, store.checkpoint()));
    }

    const plain_source = "structural Plain = number;";
    var plain_store = Store.init(std.testing.allocator, plain_source);
    defer plain_store.deinit();
    var plain_cursor = Cursor.init(plain_source);
    const plain_keyword = plain_cursor.current;
    plain_cursor.advance();
    const plain_before = plain_cursor;
    const plain_body_start: u32 = @intCast(std.mem.indexOf(u8, plain_source, "number").?);
    const plain_end: u32 = @intCast(std.mem.indexOfScalar(u8, plain_source, ';').?);
    try std.testing.expectError(
        error.InvalidAdmissionSpan,
        parseAdmittedDeclarationAndStore(&plain_store, .{
            .keyword = plain_keyword,
            .export_span = null,
            .kind = .structural,
            .authored_scope = 0,
            .generic_list = .{ .start = plain_body_start, .end = plain_end },
            .body = .{
                .raw_span = .{ .start = plain_body_start, .end = plain_end },
                .admission_end = plain_end,
            },
        }, &plain_cursor),
    );
    try std.testing.expect(std.meta.eql(plain_before, plain_cursor));
    try std.testing.expect(std.meta.eql(
        std.mem.zeroes(Store.Checkpoint),
        plain_store.checkpoint(),
    ));
}

test "admitted declaration body presence matches the equals token" {
    const Case = enum { absent, empty, unexpected_body, missing_body };
    for (std.meta.tags(Case)) |case| {
        const source = switch (case) {
            .absent, .unexpected_body => "structural Empty;",
            .empty, .missing_body => "structural Empty =   ;",
        };
        const semicolon: u32 = @intCast(std.mem.indexOfScalar(u8, source, ';').?);
        var store = Store.init(std.testing.allocator, source);
        defer store.deinit();
        var cursor = Cursor.init(source);
        const keyword = cursor.current;
        cursor.advance();
        const before_cursor = cursor;
        const prior = store.checkpoint();
        const body: ?AdmittedTypeInput = switch (case) {
            .absent, .missing_body => null,
            .empty, .unexpected_body => .{
                .raw_span = .{ .start = semicolon, .end = semicolon },
                .admission_end = semicolon,
            },
        };
        const outcome = parseAdmittedDeclarationAndStore(&store, .{
            .keyword = keyword,
            .export_span = null,
            .kind = .structural,
            .authored_scope = 0,
            .body = body,
        }, &cursor);
        switch (case) {
            .absent, .empty => switch (try outcome) {
                .parsed => {},
                .excluded, .not_declaration => return error.TestUnexpectedResult,
            },
            .unexpected_body, .missing_body => {
                try std.testing.expectError(error.InvalidAdmissionSpan, outcome);
                try std.testing.expect(std.meta.eql(before_cursor, cursor));
                try std.testing.expect(std.meta.eql(prior, store.checkpoint()));
                continue;
            },
        }
        const declaration = store.declarations.items[0];
        try std.testing.expectEqual(case == .empty, declaration.equals_span != null);
        switch (declaration.body) {
            .absent => {},
            .present => return error.TestUnexpectedResult,
        }
        try store.validate();
    }
}

test "admitted nominal missing body retains its exclusion and rollback" {
    const source = "nominal Empty;";
    var store = Store.init(std.testing.allocator, source);
    defer store.deinit();
    var cursor = Cursor.init(source);
    const keyword = cursor.current;
    cursor.advance();
    const before_cursor = cursor;
    const prior = store.checkpoint();

    switch (try parseAdmittedDeclarationAndStore(&store, .{
        .keyword = keyword,
        .export_span = null,
        .kind = .nominal,
        .authored_scope = 0,
        .body = null,
    }, &cursor)) {
        .excluded => |excluded| {
            try std.testing.expectEqual(
                @TypeOf(excluded.reason).nominal_base_not_scalar,
                excluded.reason,
            );
            try std.testing.expectEqualStrings("", excluded.raw_span.text(source));
        },
        .parsed, .not_declaration => return error.TestUnexpectedResult,
    }
    try std.testing.expect(std.meta.eql(before_cursor, cursor));
    try std.testing.expect(std.meta.eql(prior, store.checkpoint()));
}

test "admitted nominal exclusion rolls back its generic projection" {
    const source = "nominal Box<T> = T;";
    const generic_start: u32 = @intCast(std.mem.indexOfScalar(u8, source, '<').?);
    const generic_end: u32 = @intCast(std.mem.indexOfScalar(u8, source, '>').? + 1);
    const body_start: u32 = @intCast(std.mem.lastIndexOfScalar(u8, source, 'T').?);
    const admission_end: u32 = @intCast(std.mem.indexOfScalar(u8, source, ';').?);
    var store = Store.init(std.testing.allocator, source);
    defer store.deinit();
    var cursor = Cursor.init(source);
    const keyword = cursor.current;
    cursor.advance();
    const before_cursor = cursor;
    const prior = store.checkpoint();

    switch (try parseAdmittedDeclarationAndStore(&store, .{
        .keyword = keyword,
        .export_span = null,
        .kind = .nominal,
        .authored_scope = 0,
        .generic_list = .{ .start = generic_start, .end = generic_end },
        .body = .{
            .raw_span = .{ .start = body_start, .end = body_start + 1 },
            .admission_end = admission_end,
        },
    }, &cursor)) {
        .excluded => |excluded| {
            try std.testing.expectEqual(
                @TypeOf(excluded.reason).nominal_base_not_scalar,
                excluded.reason,
            );
            try std.testing.expectEqualStrings("T", excluded.raw_span.text(source));
            try std.testing.expectEqualStrings(
                "<T>",
                (excluded.generic_list_span orelse return error.TestUnexpectedResult).text(source),
            );
        },
        .parsed, .not_declaration => return error.TestUnexpectedResult,
    }
    try std.testing.expect(std.meta.eql(before_cursor, cursor));
    try std.testing.expect(std.meta.eql(prior, store.checkpoint()));
}

test "admitted semantic publication restores its entry checkpoint on allocation failure" {
    const Case = enum { annotation, function_return, declaration };
    const Context = struct {
        fn run(allocator: std.mem.Allocator, case: Case, failures: *usize) !void {
            const source = switch (case) {
                .annotation => "{ field: number | string; cb: (pair: [number, string]) => `x${boolean}` }",
                .function_return => "value\tis\t{ field: number | string }   ",
                .declaration => "structural Shape<T> = { field: number | string; cb: (pair: [number, string]) => `x${boolean}` };",
            };
            var store = Store.init(allocator, source);
            defer store.deinit();
            const prior = store.checkpoint();
            switch (case) {
                .annotation => {
                    const outcome = parseAdmittedAnnotationAndStore(&store, .global(300), .{
                        .raw_span = .{ .start = 0, .end = @intCast(source.len) },
                        .admission_end = @intCast(source.len),
                    }) catch |err| {
                        try std.testing.expect(std.meta.eql(prior, store.checkpoint()));
                        failures.* += 1;
                        return err;
                    };
                    switch (outcome) {
                        .parsed => {},
                        .excluded => return error.TestUnexpectedResult,
                    }
                },
                .function_return => {
                    const outcome = parseAdmittedFunctionReturnAndStore(&store, .{
                        .raw_span = .{ .start = 0, .end = @intCast(source.len) },
                        .admission_end = @intCast(source.len),
                    }) catch |err| {
                        try std.testing.expect(std.meta.eql(prior, store.checkpoint()));
                        failures.* += 1;
                        return err;
                    };
                    switch (outcome) {
                        .parsed => {},
                        .failure, .excluded => return error.TestUnexpectedResult,
                    }
                },
                .declaration => {
                    var cursor = Cursor.init(source);
                    const keyword = cursor.current;
                    cursor.advance();
                    const before_cursor = cursor;
                    const generic_start: u32 = @intCast(std.mem.indexOfScalar(u8, source, '<').?);
                    const generic_end: u32 = @intCast(std.mem.indexOfScalar(u8, source, '>').? + 1);
                    const body_start: u32 = @intCast(std.mem.indexOfScalar(u8, source, '{').?);
                    const admission_end: u32 = @intCast(std.mem.lastIndexOfScalar(u8, source, ';').?);
                    const outcome = parseAdmittedDeclarationAndStore(&store, .{
                        .keyword = keyword,
                        .export_span = null,
                        .kind = .structural,
                        .authored_scope = 0,
                        .generic_list = .{ .start = generic_start, .end = generic_end },
                        .body = .{
                            .raw_span = .{ .start = body_start, .end = admission_end },
                            .admission_end = admission_end,
                        },
                    }, &cursor) catch |err| {
                        try std.testing.expect(std.meta.eql(before_cursor, cursor));
                        try std.testing.expect(std.meta.eql(prior, store.checkpoint()));
                        failures.* += 1;
                        return err;
                    };
                    switch (outcome) {
                        .parsed => {},
                        .excluded, .not_declaration => return error.TestUnexpectedResult,
                    }
                },
            }
            try std.testing.expect(!std.meta.eql(prior, store.checkpoint()));
        }
    };

    inline for (std.meta.tags(Case)) |case| {
        var failures: usize = 0;
        try std.testing.checkAllAllocationFailures(
            std.testing.allocator,
            Context.run,
            .{ case, &failures },
        );
        try std.testing.expect(failures > 0);
    }
}

test "admitted generic declaration failure preserves a published seed" {
    const source = "number; structural Shape<T> = { field: number };";
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{
        .fail_index = std.math.maxInt(usize),
        .resize_fail_index = std.math.maxInt(usize),
    });
    var store = Store.init(failing.allocator(), source);
    defer store.deinit();
    try store.add(.global(300), .{
        .primitive = .number,
        .semantic_span = .{ .start = 0, .end = 6 },
        .raw_span = .{ .start = 0, .end = 6 },
    });
    const prior = store.checkpoint();
    try std.testing.expect(prior.nodes > 0);
    try std.testing.expect(prior.annotations > 0);

    const declaration_start: u32 = @intCast(std.mem.indexOf(u8, source, "structural").?);
    var cursor = Cursor.init(source);
    advanceCursorTo(&cursor, declaration_start);
    const keyword = cursor.current;
    cursor.advance();
    const before_cursor = cursor;
    const generic_start: u32 = @intCast(std.mem.indexOfScalar(u8, source, '<').?);
    const generic_end: u32 = @intCast(std.mem.indexOfScalar(u8, source, '>').? + 1);
    const body_start: u32 = @intCast(std.mem.indexOfScalar(u8, source, '{').?);
    const admission_end: u32 = @intCast(std.mem.lastIndexOfScalar(u8, source, ';').?);
    failing.fail_index = failing.alloc_index;
    failing.resize_fail_index = failing.resize_index;

    try std.testing.expectError(
        error.OutOfMemory,
        parseAdmittedDeclarationAndStore(&store, .{
            .keyword = keyword,
            .export_span = null,
            .kind = .structural,
            .authored_scope = 0,
            .generic_list = .{ .start = generic_start, .end = generic_end },
            .body = .{
                .raw_span = .{ .start = body_start, .end = admission_end },
                .admission_end = admission_end,
            },
        }, &cursor),
    );
    try std.testing.expect(failing.has_induced_failure);
    try std.testing.expect(std.meta.eql(before_cursor, cursor));
    try std.testing.expect(std.meta.eql(prior, store.checkpoint()));
    failing.fail_index = std.math.maxInt(usize);
    failing.resize_fail_index = std.math.maxInt(usize);
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
    try store.add(.global(300), .{
        .primitive = .number,
        .semantic_span = .{ .start = 0, .end = 6 },
        .raw_span = .{ .start = 0, .end = 6 },
    });
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
    try store.validate();
}

fn parseReturnForTest(store: *Store) !ReturnSyntax {
    var cursor = Cursor.init(store.source);
    return switch (try parseFunctionReturnAndStore(store, 0, &cursor)) {
        .parsed => |value| value,
        .failure, .excluded => error.TestUnexpectedReturnOutcome,
    };
}

test "empty predicate narrowing retains its raw whitespace interval" {
    const source = "value is \t ";
    var store = Store.init(std.testing.allocator, source);
    defer store.deinit();

    const value = try parseReturnForTest(&store);
    try std.testing.expectEqual(LegacyReturnKind.type_guard, value.legacy_return_kind);
    try std.testing.expect(value.legacy_ordinary_prefix == null);
    try std.testing.expectEqual(
        Span{ .start = 0, .end = @intCast(source.len) },
        value.raw_span,
    );
    const predicate = switch (value.structure) {
        .predicate => |predicate| predicate,
        .value => return error.TestExpectedPredicate,
    };
    try std.testing.expectEqual(Span{ .start = 0, .end = 5 }, predicate.target_span);
    try std.testing.expectEqual(
        Span{ .start = 8, .end = @intCast(source.len) },
        predicate.narrowed.raw_span,
    );
    try std.testing.expect(childIsAbsent(predicate.narrowed.root));
    try std.testing.expectEqual(@as(u32, 0), predicate.narrowed.node_range.count);
    try std.testing.expectEqual(@as(u32, @intCast(source.len)), predicate.narrowed.admission_end);
    try std.testing.expectEqual(@as(u32, @intCast(source.len)), predicate.narrowed.semantic_prefix_end);
    try std.testing.expectEqual(@as(usize, 0), store.nodes.items.len);
}

test "ordinary empty predicate retains the complete compatibility parse" {
    const source = "readonly\tis\t ";
    var store = Store.init(std.testing.allocator, source);
    defer store.deinit();

    const value = try parseReturnForTest(&store);
    try std.testing.expectEqual(LegacyReturnKind.ordinary, value.legacy_return_kind);
    const predicate = switch (value.structure) {
        .predicate => |predicate| predicate,
        .value => return error.TestExpectedPredicate,
    };
    try std.testing.expectEqual(
        Span{ .start = 11, .end = @intCast(source.len) },
        predicate.narrowed.raw_span,
    );
    try std.testing.expect(childIsAbsent(predicate.narrowed.root));
    try std.testing.expectEqual(@as(u32, 0), predicate.narrowed.node_range.count);

    const compatibility = value.legacy_ordinary_prefix orelse
        return error.TestExpectedCompatibilityRoot;
    try std.testing.expectEqual(value.raw_span, compatibility.raw_span);
    try std.testing.expectEqual(@as(u32, 2), compatibility.node_range.count);
    const compatibility_root = switch (compatibility.root) {
        .absent => return error.TestExpectedCompatibilityRoot,
        .present => |index| store.node(index) orelse return error.TestExpectedCompatibilityRoot,
    };
    const compatibility_child = switch (compatibility_root.data) {
        .readonly_modifier => |child| child,
        else => return error.TestExpectedReadonlyCompatibility,
    };
    const child_node = switch (compatibility_child) {
        .absent => return error.TestExpectedCompatibilityRoot,
        .present => |index| store.node(index) orelse return error.TestExpectedCompatibilityRoot,
    };
    const name_span = switch (child_node.data) {
        .named_reference => |span| span,
        else => return error.TestExpectedCompatibilityReference,
    };
    try std.testing.expectEqualStrings("is", name_span.text(source));
}

test "return validation enforces empty predicate and compatibility facets" {
    {
        var store = Store.init(std.testing.allocator, "value\tis\t ");
        defer store.deinit();
        const parsed = try parseReturnForTest(&store);

        var wrong_facet = parsed;
        wrong_facet.legacy_return_kind = .type_guard;
        var wrong_facet_pending = store.beginFunctionSignature();
        defer store.cancelFunctionSignature(&wrong_facet_pending);
        try std.testing.expectError(
            error.InvalidReturnSyntax,
            store.setFunctionReturn(&wrong_facet_pending, wrong_facet),
        );

        var missing_compatibility = parsed;
        missing_compatibility.legacy_ordinary_prefix = null;
        var missing_pending = store.beginFunctionSignature();
        defer store.cancelFunctionSignature(&missing_pending);
        try std.testing.expectError(
            error.InvalidReturnSyntax,
            store.setFunctionReturn(&missing_pending, missing_compatibility),
        );
    }

    {
        var store = Store.init(std.testing.allocator, "value is \t ");
        defer store.deinit();
        const parsed = try parseReturnForTest(&store);
        const predicate = switch (parsed.structure) {
            .predicate => |predicate| predicate,
            .value => return error.TestExpectedPredicate,
        };

        var forbidden_compatibility = parsed;
        forbidden_compatibility.legacy_ordinary_prefix = predicate.narrowed;
        var forbidden_pending = store.beginFunctionSignature();
        defer store.cancelFunctionSignature(&forbidden_pending);
        try std.testing.expectError(
            error.InvalidReturnSyntax,
            store.setFunctionReturn(&forbidden_pending, forbidden_compatibility),
        );

        var rooted_empty = parsed;
        var rooted_predicate = predicate;
        rooted_predicate.narrowed.root = .{ .present = 0 };
        rooted_empty.structure = .{ .predicate = rooted_predicate };
        var root_pending = store.beginFunctionSignature();
        defer store.cancelFunctionSignature(&root_pending);
        try std.testing.expectError(
            error.InvalidReturnSyntax,
            store.setFunctionReturn(&root_pending, rooted_empty),
        );

        var ranged_empty = parsed;
        var ranged_predicate = predicate;
        ranged_predicate.narrowed.node_range.count = 1;
        ranged_empty.structure = .{ .predicate = ranged_predicate };
        var range_pending = store.beginFunctionSignature();
        defer store.cancelFunctionSignature(&range_pending);
        try std.testing.expectError(
            error.InvalidReturnSyntax,
            store.setFunctionReturn(&range_pending, ranged_empty),
        );
    }

    {
        var store = Store.init(std.testing.allocator, "value is string");
        defer store.deinit();
        var nonwhitespace_empty = try parseReturnForTest(&store);
        var predicate = switch (nonwhitespace_empty.structure) {
            .predicate => |predicate| predicate,
            .value => return error.TestExpectedPredicate,
        };
        predicate.narrowed.root = .absent;
        predicate.narrowed.node_range.count = 0;
        nonwhitespace_empty.structure = .{ .predicate = predicate };
        var pending = store.beginFunctionSignature();
        defer store.cancelFunctionSignature(&pending);
        try std.testing.expectError(
            error.InvalidReturnSyntax,
            store.setFunctionReturn(&pending, nonwhitespace_empty),
        );
    }
}

test "admission vocabulary retains seventeen ordered kinds" {
    const expected = [_]AdmissionKind{
        .any_type,
        .as_assertion,
        .satisfies_assertion,
        .unterminated_string,
        .nominal_base_not_scalar,
        .interface_declaration,
        .type_alias_declaration,
        .distinct_type_declaration,
        .legacy_types_import,
        .default_parameter,
        .optional_parameter,
        .default_export,
        .mutable_export,
        .array_type_alias,
        .readonly_array_type_alias,
        .void_type,
        .nesting_too_deep,
    };
    try std.testing.expectEqual(@as(usize, 17), std.meta.fields(AdmissionKind).len);
    for (expected, 0..) |kind, index| {
        try std.testing.expectEqual(index, @intFromEnum(kind));
    }
}

test "admission collector preserves mode order deduplication and fatal selection" {
    var collected = AdmissionCollector.init(std.testing.allocator, .collect);
    defer collected.deinit();
    try collected.recordRecoverable(.{
        .kind = .any_type,
        .span = .{ .start = 4, .end = 7 },
    });
    try collected.recordRecoverable(.{
        .kind = .void_type,
        .span = .{ .start = 4, .end = 8 },
    });
    try collected.recordRecoverable(.{
        .kind = .array_type_alias,
        .span = .{ .start = 9, .end = 14 },
    });
    try std.testing.expectEqual(@as(u64, 3), collected.generation());
    try std.testing.expectEqual(@as(usize, 2), collected.items().len);
    try std.testing.expectEqual(AdmissionKind.any_type, collected.items()[0].kind);
    try std.testing.expectEqual(AdmissionKind.array_type_alias, collected.items()[1].kind);

    try collected.recordFatal(.{
        .kind = .unterminated_string,
        .span = .{ .start = 20, .end = 20 },
    });
    try std.testing.expect(collected.hasFatal());
    try std.testing.expect(collected.shouldStop());
    try std.testing.expectEqual(@as(u64, 4), collected.generation());
    try std.testing.expectEqual(@as(usize, 1), collected.items().len);
    try std.testing.expectEqual(AdmissionKind.unterminated_string, collected.items()[0].kind);
    try std.testing.expectEqual(@as(u32, 20), collected.items()[0].span.start);

    var compiled = AdmissionCollector.init(std.testing.allocator, .compile);
    defer compiled.deinit();
    try compiled.recordCaught(.{
        .kind = .unterminated_string,
        .span = .{ .start = 0, .end = 1 },
    });
    try std.testing.expectEqual(@as(u64, 0), compiled.generation());
    try std.testing.expectEqual(@as(usize, 0), compiled.items().len);
    try std.testing.expect(!compiled.hasFatal());
    try std.testing.expect(!compiled.shouldStop());
    try compiled.recordRecoverable(.{
        .kind = .any_type,
        .span = .{ .start = 1, .end = 4 },
    });
    try compiled.recordRecoverable(.{
        .kind = .void_type,
        .span = .{ .start = 8, .end = 12 },
    });
    try std.testing.expect(compiled.isCompile());
    try std.testing.expect(compiled.shouldStop());
    try std.testing.expectEqual(@as(u64, 2), compiled.generation());
    try std.testing.expectEqual(@as(usize, 1), compiled.items().len);
    try std.testing.expectEqual(AdmissionKind.any_type, compiled.items()[0].kind);
}

test "admission observation history preserves first kind and staged rollback" {
    var history = AdmissionObservationHistory.init(std.testing.allocator);
    defer history.deinit();

    try history.record(.{
        .kind = .any_type,
        .span = .{ .start = 4, .end = 7 },
    });
    try history.record(.{
        .kind = .void_type,
        .span = .{ .start = 9, .end = 13 },
    });
    try history.record(.{
        .kind = .array_type_alias,
        .span = .{ .start = 4, .end = 9 },
    });

    try std.testing.expectEqual(@as(usize, 2), history.items().len);
    try std.testing.expectEqual(AdmissionKind.any_type, history.items()[0].kind);
    try std.testing.expectEqual(AdmissionKind.void_type, history.last().?.kind);

    const checkpoint_value = history.checkpoint();
    try history.record(.{
        .kind = .optional_parameter,
        .span = .{ .start = 20, .end = 21 },
    });
    history.rollbackUnconfirmed(checkpoint_value);
    try std.testing.expectEqual(@as(usize, 2), history.items().len);
    try std.testing.expectEqual(AdmissionKind.void_type, history.last().?.kind);
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

test "admission sink keeps presentation history across fatal replay" {
    const first: AdmissionDiagnostic = .{
        .kind = .any_type,
        .span = .{ .start = 1, .end = 4 },
    };
    const second: AdmissionDiagnostic = .{
        .kind = .void_type,
        .span = .{ .start = 8, .end = 12 },
    };
    var collector = AdmissionCollector.init(std.testing.allocator, .collect);
    defer collector.deinit();
    var history = AdmissionObservationHistory.init(std.testing.allocator);
    defer history.deinit();
    const sink = AdmissionSink.init(&collector, &history);

    try sink.recordRecoverable(first);
    try sink.recordRecoverable(second);
    try sink.recordFatal(first);

    try std.testing.expect(collector.hasFatal());
    try std.testing.expectEqual(@as(u64, 3), collector.generation());
    try std.testing.expectEqual(@as(usize, 1), collector.items().len);
    try std.testing.expectEqual(first.kind, collector.items()[0].kind);
    try std.testing.expectEqual(first.span, collector.items()[0].span);
    try std.testing.expectEqual(@as(usize, 2), history.items().len);
    try std.testing.expectEqual(first.kind, history.items()[0].kind);
    try std.testing.expectEqual(second.kind, history.last().?.kind);
    try std.testing.expectEqual(second.span, history.last().?.span);
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

fn exerciseAdmissionHistoryAllocation(allocator: std.mem.Allocator) !void {
    var history = AdmissionObservationHistory.init(allocator);
    defer history.deinit();
    try history.record(.{
        .kind = .any_type,
        .span = .{ .start = 1, .end = 4 },
    });
    try history.record(.{
        .kind = .void_type,
        .span = .{ .start = 8, .end = 12 },
    });
}

test "admission history propagates allocation failure before collector mutation" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseAdmissionHistoryAllocation,
        .{},
    );

    var failing = std.testing.FailingAllocator.init(
        std.testing.allocator,
        .{ .fail_index = 0 },
    );
    var history = AdmissionObservationHistory.init(failing.allocator());
    defer history.deinit();
    var collector = AdmissionCollector.init(std.testing.allocator, .collect);
    defer collector.deinit();
    try std.testing.expectError(
        error.OutOfMemory,
        AdmissionSink.init(&collector, &history).recordRecoverable(.{
            .kind = .any_type,
            .span = .{ .start = 1, .end = 4 },
        }),
    );
    try std.testing.expect(failing.has_induced_failure);
    try std.testing.expectEqual(@as(usize, 0), history.items().len);
    try std.testing.expectEqual(@as(u64, 0), collector.generation());
    try std.testing.expectEqual(@as(usize, 0), collector.items().len);
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

test "bounded admission classifier accepts exact lexical endpoints and unwinds templates" {
    var boundary_source: std.ArrayListUnmanaged(u8) = .empty;
    defer boundary_source.deinit(std.testing.allocator);
    try boundary_source.appendSlice(std.testing.allocator, "function f(): `${");
    try boundary_source.appendNTimes(std.testing.allocator, '{', max_type_depth);
    try boundary_source.appendSlice(std.testing.allocator, " return 1; }\n");
    var boundary_collector = AdmissionCollector.init(std.testing.allocator, .collect);
    defer boundary_collector.deinit();
    try classifyTypeSpan(boundary_source.items, .{
        .span = .{ .start = 14, .end = 528 },
        .policy = .any_only,
        .caught_lexical = &.{.{
            .kind = .nesting_too_deep,
            .span = .{ .start = 528, .end = 529 },
        }},
    }, AdmissionSink.init(&boundary_collector, null));
    try std.testing.expectEqual(@as(usize, 1), boundary_collector.items().len);
    try std.testing.expectEqual(AdmissionKind.nesting_too_deep, boundary_collector.items()[0].kind);
    try std.testing.expectEqual(Span{ .start = 528, .end = 529 }, boundary_collector.items()[0].span);

    var nested_source: std.ArrayListUnmanaged(u8) = .empty;
    defer nested_source.deinit(std.testing.allocator);
    try nested_source.appendSlice(std.testing.allocator, "function f(): `${`${");
    try nested_source.appendNTimes(std.testing.allocator, '{', max_type_depth);
    try nested_source.appendSlice(std.testing.allocator, "}}` | any { return 1; }\n");
    var nested_collector = AdmissionCollector.init(std.testing.allocator, .collect);
    defer nested_collector.deinit();
    try classifyTypeSpan(nested_source.items, .{
        .span = .{ .start = 14, .end = 542 },
        .policy = .any_only,
        .caught_lexical = &.{.{
            .kind = .nesting_too_deep,
            .span = .{ .start = 531, .end = 532 },
        }},
    }, AdmissionSink.init(&nested_collector, null));
    try std.testing.expectEqual(@as(usize, 2), nested_collector.items().len);
    try std.testing.expectEqual(AdmissionKind.nesting_too_deep, nested_collector.items()[0].kind);
    try std.testing.expectEqual(@as(u32, 531), nested_collector.items()[0].span.start);
    try std.testing.expectEqual(AdmissionKind.any_type, nested_collector.items()[1].kind);
    try std.testing.expectEqual(Span{ .start = 538, .end = 541 }, nested_collector.items()[1].span);

    const lf_source = "number\n";
    var lf_collector = AdmissionCollector.init(std.testing.allocator, .collect);
    defer lf_collector.deinit();
    try classifyTypeSpan(lf_source, .{
        .span = .{ .start = 0, .end = 6 },
        .policy = .any_only,
        .caught_lexical = &.{.{
            .kind = .unterminated_string,
            .span = .{ .start = 6, .end = 7 },
        }},
    }, AdmissionSink.init(&lf_collector, null));
    try std.testing.expectEqual(@as(usize, 1), lf_collector.items().len);
    try std.testing.expectEqual(Span{ .start = 6, .end = 7 }, lf_collector.items()[0].span);

    const equal_source = "{}";
    var equal_collector = AdmissionCollector.init(std.testing.allocator, .collect);
    defer equal_collector.deinit();
    try classifyTypeSpanPrefix(equal_source, .{
        .span = .{ .start = 0, .end = 2 },
        .policy = .removed_only,
        .caught_lexical = &.{
            .{ .kind = .nesting_too_deep, .span = .{ .start = 1, .end = 2 } },
            .{ .kind = .unterminated_string, .span = .{ .start = 1, .end = 2 } },
        },
    }, AdmissionSink.init(&equal_collector, null));
    try std.testing.expectEqual(@as(u64, 2), equal_collector.generation());
    try std.testing.expectEqual(@as(usize, 1), equal_collector.items().len);
    try std.testing.expectEqual(AdmissionKind.nesting_too_deep, equal_collector.items()[0].kind);

    try std.testing.expectError(
        error.InvalidCaughtAdmissionDiagnostic,
        classifyTypeSpan(lf_source, .{
            .span = .{ .start = 0, .end = 6 },
            .policy = .any_only,
            .caught_lexical = &.{.{
                .kind = .nesting_too_deep,
                .span = .{ .start = 6, .end = 7 },
            }},
        }, AdmissionSink.init(&lf_collector, null)),
    );
    try std.testing.expectError(
        error.InvalidCaughtAdmissionDiagnostic,
        classifyTypeSpan(lf_source, .{
            .span = .{ .start = 0, .end = 6 },
            .policy = .any_only,
            .caught_lexical = &.{.{
                .kind = .unterminated_string,
                .span = .{ .start = 6, .end = 6 },
            }},
        }, AdmissionSink.init(&lf_collector, null)),
    );
}

fn exerciseAdmissionCollectorAllocation(allocator: std.mem.Allocator) !void {
    var collector = AdmissionCollector.init(allocator, .collect);
    defer collector.deinit();
    try collector.recordRecoverable(.{
        .kind = .any_type,
        .span = .{ .start = 1, .end = 4 },
    });
    try collector.recordRecoverable(.{
        .kind = .void_type,
        .span = .{ .start = 8, .end = 12 },
    });

    var fatal = AdmissionCollector.init(allocator, .collect);
    defer fatal.deinit();
    try fatal.recordFatal(.{
        .kind = .unterminated_string,
        .span = .{ .start = 20, .end = 20 },
    });

    const nested_template = "`head ${`inner ${value}`}`";
    try classifyTypeSpan(nested_template, .{
        .span = .{ .start = 0, .end = @intCast(nested_template.len) },
        .policy = .any_only,
    }, AdmissionSink.init(&collector, null));
}

test "admission collector closes every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseAdmissionCollectorAllocation,
        .{},
    );

    var failing_recoverable = std.testing.FailingAllocator.init(
        std.testing.allocator,
        .{ .fail_index = 0 },
    );
    var recoverable = AdmissionCollector.init(failing_recoverable.allocator(), .collect);
    defer recoverable.deinit();
    try std.testing.expectError(error.OutOfMemory, recoverable.recordRecoverable(.{
        .kind = .any_type,
        .span = .{ .start = 1, .end = 4 },
    }));
    try std.testing.expectEqual(@as(u64, 1), recoverable.generation());
    try std.testing.expect(!recoverable.hasFatal());
    try std.testing.expectEqual(@as(usize, 0), recoverable.items().len);

    var failing_fatal = std.testing.FailingAllocator.init(
        std.testing.allocator,
        .{ .fail_index = 0 },
    );
    var fatal = AdmissionCollector.init(failing_fatal.allocator(), .collect);
    defer fatal.deinit();
    try std.testing.expectError(error.OutOfMemory, fatal.recordFatal(.{
        .kind = .unterminated_string,
        .span = .{ .start = 5, .end = 6 },
    }));
    try std.testing.expectEqual(@as(u64, 1), fatal.generation());
    try std.testing.expect(!fatal.hasFatal());
    try std.testing.expectEqual(@as(usize, 0), fatal.items().len);
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

test "erased prefix operand scanner is local and preserves lexical delimiters" {
    const Case = struct {
        prefix: []const u8,
        operand: []const u8,
    };
    const cases = [_]Case{
        .{
            .prefix = "before ",
            .operand = "{ text: \"brace } and {\" }",
        },
        .{
            .prefix = "before ",
            .operand = "{ nested: { id: 1 } }",
        },
        .{
            .prefix = "before ",
            .operand = "{ text: `brace } and {` }",
        },
        .{
            .prefix = "before ",
            .operand = "{ text: `head ${ { id: 1 }.id } tail }` }",
        },
        .{
            .prefix = "before ",
            .operand = "{ pattern: /[{}]/ }",
        },
        .{
            .prefix = "\"unterminated { invalid ",
            .operand = "{ id: 1 }",
        },
        .{
            .prefix = "`unterminated ${ { invalid: ",
            .operand = "{ id: 1 }",
        },
    };
    for (cases) |case| {
        const source = try std.mem.concat(
            std.testing.allocator,
            u8,
            &.{ case.prefix, case.operand, " trailing" },
        );
        defer std.testing.allocator.free(source);
        const operand_start = std.math.cast(u32, case.prefix.len) orelse
            return error.TestUnexpectedResult;
        const expected_end = std.math.cast(u32, case.prefix.len + case.operand.len) orelse
            return error.TestUnexpectedResult;
        try std.testing.expectEqual(
            expected_end,
            Store.scanErasedPrefixOperandEnd(source, operand_start, case.operand[0]).?,
        );
    }

    const source = "{ id: 1 }";
    try std.testing.expect(Store.scanErasedPrefixOperandEnd(source, @intCast(source.len), '{') == null);
    try std.testing.expect(Store.scanErasedPrefixOperandEnd(source, 1, '{') == null);
    try std.testing.expect(Store.scanErasedPrefixOperandEnd("((1)) trailing", 0, '(').? == 5);
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

test "type-only module scanner spills nested template frames without truncation" {
    var source: std.ArrayListUnmanaged(u8) = .empty;
    defer source.deinit(std.testing.allocator);
    try source.appendSlice(std.testing.allocator, "import type ");
    for (0..max_template_levels + 1) |_| try source.appendSlice(std.testing.allocator, "`${");
    try source.appendSlice(std.testing.allocator, "value");
    for (0..max_template_levels + 1) |_| try source.appendSlice(std.testing.allocator, "}`");
    try source.appendSlice(std.testing.allocator, ";tail");

    var diagnostics: std.ArrayListUnmanaged(TypeOnlyModuleDiagnostic) = .empty;
    defer diagnostics.deinit(std.testing.allocator);
    const cursor = Cursor.init(source.items);
    const module = switch (try scanTypeOnlyModule(std.testing.allocator, .{
        .source = source.items,
        .keyword = cursor.current,
        .diagnostics = &diagnostics,
    })) {
        .scanned => |module| module,
        .not_type_only, .refused, .excluded => return error.TestExpectedTypeOnlyModule,
    };
    const semicolon = std.mem.lastIndexOfScalar(u8, source.items, ';') orelse
        return error.TestExpectedTypeOnlyModule;
    try std.testing.expectEqual(@as(u32, @intCast(semicolon + 1)), module.raw_span.end);
    try std.testing.expectEqual(@as(usize, 0), diagnostics.items.len);
}

test "type-only module scanner retains exact lexical exclusions" {
    {
        const source = "import type \"open\nconst live = 1;";
        var diagnostics: std.ArrayListUnmanaged(TypeOnlyModuleDiagnostic) = .empty;
        defer diagnostics.deinit(std.testing.allocator);
        const cursor = Cursor.init(source);
        const module = switch (try scanTypeOnlyModule(std.testing.allocator, .{
            .source = source,
            .keyword = cursor.current,
            .diagnostics = &diagnostics,
        })) {
            .excluded => |module| module,
            .not_type_only, .refused, .scanned => return error.TestExpectedTypeOnlyModule,
        };
        const newline = std.mem.indexOfScalar(u8, source, '\n') orelse
            return error.TestExpectedTypeOnlyModule;
        try std.testing.expectEqual(@as(u32, @intCast(newline)), module.raw_span.end);
        try std.testing.expectEqual(@as(usize, 1), diagnostics.items.len);
        try std.testing.expectEqual(TypeOnlyModuleDiagnosticKind.unterminated_string, diagnostics.items[0].kind);
        try std.testing.expectEqual(@as(u32, @intCast(newline)), diagnostics.items[0].offset);
    }

    {
        const source = "import type `${\"open\n\"}`;\n";
        var diagnostics: std.ArrayListUnmanaged(TypeOnlyModuleDiagnostic) = .empty;
        defer diagnostics.deinit(std.testing.allocator);
        const cursor = Cursor.init(source);
        const module = switch (try scanTypeOnlyModule(std.testing.allocator, .{
            .source = source,
            .keyword = cursor.current,
            .diagnostics = &diagnostics,
        })) {
            .excluded => |module| module,
            .not_type_only, .refused, .scanned => return error.TestExpectedTypeOnlyModule,
        };
        try std.testing.expectEqual(@as(u32, @intCast(source.len)), module.raw_span.end);
        try std.testing.expectEqual(@as(usize, 2), diagnostics.items.len);
        try std.testing.expectEqual(@as(u32, @intCast(std.mem.indexOfScalar(u8, source, '\n').?)), diagnostics.items[0].offset);
        try std.testing.expectEqual(@as(u32, @intCast(std.mem.lastIndexOfScalar(u8, source, '\n').?)), diagnostics.items[1].offset);
    }

    {
        var source: std.ArrayListUnmanaged(u8) = .empty;
        defer source.deinit(std.testing.allocator);
        try source.appendSlice(std.testing.allocator, "import type `${");
        try source.appendNTimes(std.testing.allocator, '{', max_type_depth - 1);
        try source.appendSlice(std.testing.allocator, "`${");
        try source.appendNTimes(std.testing.allocator, '{', max_type_depth);
        const diagnostic_offset = source.items.len - 1;
        try source.appendSlice(std.testing.allocator, ";tail");

        var diagnostics: std.ArrayListUnmanaged(TypeOnlyModuleDiagnostic) = .empty;
        defer diagnostics.deinit(std.testing.allocator);
        const cursor = Cursor.init(source.items);
        const module = switch (try scanTypeOnlyModule(std.testing.allocator, .{
            .source = source.items,
            .keyword = cursor.current,
            .diagnostics = &diagnostics,
        })) {
            .excluded => |module| module,
            .not_type_only, .refused, .scanned => return error.TestExpectedTypeOnlyModule,
        };
        const semicolon = std.mem.indexOfScalarPos(u8, source.items, diagnostic_offset, ';') orelse
            return error.TestExpectedTypeOnlyModule;
        try std.testing.expectEqual(@as(u32, @intCast(semicolon + 1)), module.raw_span.end);
        try std.testing.expectEqual(@as(usize, 1), diagnostics.items.len);
        try std.testing.expectEqual(TypeOnlyModuleDiagnosticKind.nesting_too_deep, diagnostics.items[0].kind);
        try std.testing.expectEqual(@as(u32, @intCast(diagnostic_offset)), diagnostics.items[0].offset);
    }
}

test "type-only module scanner rolls back diagnostics on allocation failure" {
    var nested: std.ArrayListUnmanaged(u8) = .empty;
    defer nested.deinit(std.testing.allocator);
    try nested.appendSlice(std.testing.allocator, "import type ");
    for (0..max_template_levels + 1) |_| try nested.appendSlice(std.testing.allocator, "`${");
    try nested.appendSlice(std.testing.allocator, "value");

    var prior = std.ArrayListUnmanaged(TypeOnlyModuleDiagnostic).empty;
    defer prior.deinit(std.testing.allocator);
    try prior.append(std.testing.allocator, .{ .kind = .unterminated_string, .offset = 1 });
    var spill_failure = std.testing.FailingAllocator.init(
        std.testing.allocator,
        .{ .fail_index = 0 },
    );
    const nested_cursor = Cursor.init(nested.items);
    try std.testing.expectError(error.OutOfMemory, scanTypeOnlyModule(spill_failure.allocator(), .{
        .source = nested.items,
        .keyword = nested_cursor.current,
        .diagnostics = &prior,
    }));
    try std.testing.expect(spill_failure.has_induced_failure);
    try std.testing.expectEqual(@as(usize, 1), prior.items.len);

    var clean_diagnostics = std.ArrayListUnmanaged(TypeOnlyModuleDiagnostic).empty;
    defer clean_diagnostics.deinit(std.testing.allocator);
    const module = switch (try scanTypeOnlyModule(std.testing.allocator, .{
        .source = nested.items,
        .keyword = nested_cursor.current,
        .diagnostics = &clean_diagnostics,
    })) {
        .scanned => |module| module,
        .not_type_only, .refused, .excluded => return error.TestExpectedTypeOnlyModule,
    };
    var validation_failure = std.testing.FailingAllocator.init(
        std.testing.allocator,
        .{ .fail_index = 0 },
    );
    var store = Store.init(validation_failure.allocator(), nested.items);
    defer store.deinit();
    try std.testing.expectError(error.OutOfMemory, store.appendTypeOnlyModule(module));
    try std.testing.expect(validation_failure.has_induced_failure);
    try std.testing.expectEqual(@as(usize, 0), store.type_only_modules.items.len);

    const malformed = "import type \"open\n";
    var diagnostics = std.ArrayListUnmanaged(TypeOnlyModuleDiagnostic).empty;
    var diagnostic_failure = std.testing.FailingAllocator.init(
        std.testing.allocator,
        .{ .fail_index = 0 },
    );
    const malformed_cursor = Cursor.init(malformed);
    try std.testing.expectError(error.OutOfMemory, scanTypeOnlyModule(diagnostic_failure.allocator(), .{
        .source = malformed,
        .keyword = malformed_cursor.current,
        .diagnostics = &diagnostics,
    }));
    try std.testing.expect(diagnostic_failure.has_induced_failure);
    try std.testing.expectEqual(@as(usize, 0), diagnostics.items.len);
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

test "type-only module spill failure removes a diagnostic appended in the same scan" {
    var source: std.ArrayListUnmanaged(u8) = .empty;
    defer source.deinit(std.testing.allocator);
    try source.appendSlice(std.testing.allocator, "import type `${\"open\n");
    for (0..max_template_levels) |_| try source.appendSlice(std.testing.allocator, "`${");
    try source.appendSlice(std.testing.allocator, "value");
    const fault = std.mem.indexOfScalar(u8, source.items, '\n') orelse return error.TestUnexpectedResult;
    const prior: TypeOnlyModuleDiagnostic = .{ .kind = .nesting_too_deep, .offset = 1 };
    var diagnostics: std.ArrayListUnmanaged(TypeOnlyModuleDiagnostic) = .empty;
    defer diagnostics.deinit(std.testing.allocator);
    try diagnostics.ensureTotalCapacity(std.testing.allocator, 2);
    try diagnostics.append(std.testing.allocator, prior);
    const cursor = Cursor.init(source.items);
    const module = switch (try scanTypeOnlyModule(std.testing.allocator, .{
        .source = source.items,
        .keyword = cursor.current,
        .diagnostics = &diagnostics,
    })) {
        .excluded => |module| module,
        .not_type_only, .refused, .scanned => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(@as(u32, @intCast(source.items.len)), module.raw_span.end);
    try std.testing.expectEqual(@as(usize, 2), diagnostics.items.len);
    try std.testing.expectEqual(TypeOnlyModuleDiagnosticKind.unterminated_string, diagnostics.items[1].kind);
    try std.testing.expectEqual(@as(u32, @intCast(fault)), diagnostics.items[1].offset);
    diagnostics.items.len = 1;

    var failing = std.testing.FailingAllocator.init(
        std.testing.allocator,
        .{ .fail_index = 0, .resize_fail_index = 0 },
    );
    try std.testing.expectError(error.OutOfMemory, scanTypeOnlyModule(failing.allocator(), .{
        .source = source.items,
        .keyword = cursor.current,
        .diagnostics = &diagnostics,
    }));
    try std.testing.expect(failing.has_induced_failure);
    try std.testing.expectEqual(@as(usize, 1), diagnostics.items.len);
    try std.testing.expect(std.meta.eql(prior, diagnostics.items[0]));
}

test "admission endpoints retain producer specific delimiters" {
    const source = "number, (value: string) => string { body }; next\n";
    var caught: std.ArrayListUnmanaged(AdmissionDiagnostic) = .empty;
    defer caught.deinit(std.testing.allocator);

    const variable = try scanAdmissionEndpoint(
        std.testing.allocator,
        source,
        0,
        .{ .general = .variable },
        &caught,
    );
    try std.testing.expectEqual(@as(u32, 6), variable.complete.end);

    const function_start: u32 = @intCast(std.mem.indexOfScalar(u8, source, '(').?);
    const named = try scanAdmissionEndpoint(
        std.testing.allocator,
        source,
        function_start,
        .{ .general = .named_return },
        &caught,
    );
    const body_start: u32 = @intCast(std.mem.indexOfScalar(u8, source, '{').?);
    try std.testing.expectEqual(body_start, named.complete.end);

    const arrow_start: u32 = @intCast(std.mem.indexOf(u8, source, "string { body }").?);
    const arrow = try scanAdmissionEndpoint(
        std.testing.allocator,
        source,
        arrow_start,
        .{ .general = .arrow_return },
        &caught,
    );
    try std.testing.expectEqual(body_start, arrow.complete.end);

    const unmatched = "(string; any), next";
    const continued = try scanAdmissionEndpoint(
        std.testing.allocator,
        unmatched,
        0,
        .{ .general = .variable },
        &caught,
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
    const result = try scanAdmissionEndpoint(
        std.testing.allocator,
        source,
        0,
        .{ .general = .variable },
        &caught,
    );
    const failure = switch (result) {
        .unterminated_comment => |failure| failure,
        else => return error.TestExpectedUnterminatedComment,
    };
    try std.testing.expectEqual(@as(u32, 7), failure.opener);
    try std.testing.expectEqual(@as(u32, @intCast(source.len - 1)), failure.@"resume");
    try std.testing.expectEqual(@as(usize, 0), caught.items.len);

    const bare = "/*";
    const bare_result = try scanAdmissionEndpoint(
        std.testing.allocator,
        bare,
        0,
        .{ .general = .variable },
        &caught,
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
    const interface_result = try scanAdmissionEndpoint(
        std.testing.allocator,
        interface_body,
        extends_end,
        .{ .general = .interface_extends },
        &caught,
    );
    try std.testing.expectEqual(
        Span{ .start = extends_end, .end = body_start },
        interface_result.complete,
    );

    const quoted = "\"/* unfinished\";";
    const quoted_result = try scanAdmissionEndpoint(
        std.testing.allocator,
        quoted,
        0,
        .{ .general = .variable },
        &caught,
    );
    const semicolon: u32 = @intCast(std.mem.indexOfScalar(u8, quoted, ';').?);
    try std.testing.expectEqual(Span{ .start = 0, .end = semicolon }, quoted_result.complete);

    const template = "`/* unfinished`;";
    const template_result = try scanAdmissionEndpoint(
        std.testing.allocator,
        template,
        0,
        .{ .general = .variable },
        &caught,
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

    const result = try scanAdmissionEndpoint(
        std.testing.allocator,
        source,
        0,
        .parameter,
        &caught,
    );
    const equals: u32 = @intCast(std.mem.indexOfScalar(u8, source, '=').?);
    try std.testing.expectEqual(equals, result.complete.end);

    const inside_brace = "{ value = fallback }, next)";
    const nested_result = try scanAdmissionEndpoint(
        std.testing.allocator,
        inside_brace,
        0,
        .parameter,
        &caught,
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
    const arrow = try scanAdmissionEndpoint(
        std.testing.allocator,
        arrow_source,
        0,
        .{ .general = .arrow_return },
        &caught,
    );
    try std.testing.expectEqual(
        @as(u32, @intCast(std.mem.indexOf(u8, arrow_source, "=>").?)),
        arrow.complete.end,
    );

    const unmatched = "string } ; body";
    const semicolon: u32 = @intCast(std.mem.indexOfScalar(u8, unmatched, ';').?);
    const named = try scanAdmissionEndpoint(
        std.testing.allocator,
        unmatched,
        0,
        .{ .general = .named_return },
        &caught,
    );
    try std.testing.expectEqual(semicolon, named.complete.end);
    const interface = try scanAdmissionEndpoint(
        std.testing.allocator,
        unmatched,
        0,
        .{ .general = .interface_extends },
        &caught,
    );
    try std.testing.expectEqual(semicolon, interface.complete.end);

    const full_interface = "interface X extends { field: any }";
    const extends_end: u32 = @intCast(std.mem.indexOf(u8, full_interface, "extends").? + "extends".len);
    const body_start: u32 = @intCast(std.mem.indexOfScalar(u8, full_interface, '{').?);
    const full_result = try scanAdmissionEndpoint(
        std.testing.allocator,
        full_interface,
        extends_end,
        .{ .general = .interface_extends },
        &caught,
    );
    try std.testing.expectEqual(body_start, full_result.complete.end);
}

test "assertion endpoint keeps object braces and stops at expression delimiters" {
    const source = "{ field: string }, after";
    var caught: std.ArrayListUnmanaged(AdmissionDiagnostic) = .empty;
    defer caught.deinit(std.testing.allocator);
    const result = try scanAdmissionEndpoint(
        std.testing.allocator,
        source,
        0,
        .{ .general = .assertion },
        &caught,
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

test "admission quoted region retains nested rows before a root terminal" {
    var source: std.ArrayListUnmanaged(u8) = .empty;
    defer source.deinit(std.testing.allocator);
    try source.appendSlice(std.testing.allocator, "`outer${\"first\n\"second\n");
    try source.appendNTimes(std.testing.allocator, '{', max_type_depth - 1);
    const terminal_offset: u32 = @intCast(source.items.len);
    try source.append(std.testing.allocator, '{');

    var caught: std.ArrayListUnmanaged(AdmissionDiagnostic) = .empty;
    defer caught.deinit(std.testing.allocator);
    switch (try scanAdmissionQuotedRegion(std.testing.allocator, .{
        .source = source.items,
        .start = 0,
        .caught = &caught,
    })) {
        .terminal => |diagnostic| {
            try std.testing.expectEqual(AdmissionKind.nesting_too_deep, diagnostic.kind);
            try std.testing.expectEqual(
                Span{ .start = terminal_offset, .end = terminal_offset + 1 },
                diagnostic.span,
            );
        },
        .complete => return error.TestUnexpectedResult,
    }
    try std.testing.expectEqual(@as(usize, 2), caught.items.len);
    try std.testing.expectEqual(AdmissionKind.unterminated_string, caught.items[0].kind);
    try std.testing.expectEqual(AdmissionKind.unterminated_string, caught.items[1].kind);
    try std.testing.expect(caught.items[0].span.start < caught.items[1].span.start);
    try std.testing.expect(caught.items[1].span.start < terminal_offset);
}

test "admission quoted region restores caught rows on allocation failure" {
    const prefix = "`outer${\"first\n";
    const nested_count = comptime std.ArrayListUnmanaged(LegacyTemplateFrame).growCapacity(1);
    const source = prefix ++ ("`nested${" ** nested_count) ++ "value" ++ ("}`" ** nested_count) ++ "}`";
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

test "admission presentation composes tracked prefixes and parameter rewinds" {
    const source = ":\r \t/*x*/ :\n /*y*/ : number\nany";
    const initial: AdmissionPresentation = .{ .source = source };
    const first = try initial.declinedParameterColon(0);
    try std.testing.expectEqual(@as(u32, 0), first.offset);
    try std.testing.expectEqualDeep(AdmissionPosition{ .line = 1, .column = 4 }, first.position);
    try std.testing.expectEqualDeep(AdmissionPosition{ .line = 1, .column = 8 }, try first.positionAt(4));
    const second_colon: u32 = @intCast(std.mem.indexOfPos(u8, source, 1, ":").?);
    const second = try first.declinedParameterColon(second_colon);
    try std.testing.expectEqualDeep(AdmissionPosition{ .line = 2, .column = 2 }, second.position);
    const third_colon: u32 = @intCast(std.mem.indexOfPos(u8, source, second_colon + 1, ":").?);
    const third = try second.trackedWhitespaceAt(third_colon + 1);
    try std.testing.expectEqualDeep(AdmissionPosition{ .line = 3, .column = 10 }, third.position);
    try std.testing.expectEqualDeep(AdmissionPosition{ .line = 4, .column = 1 }, try third.positionAt(@intCast(source.len - 3)));
    try std.testing.expectError(error.InvalidAdmissionPosition, third.positionAt(0));
    try std.testing.expectError(error.InvalidAdmissionPosition, initial.positionAt(@intCast(source.len + 1)));
    try std.testing.expectError(error.InvalidAdmissionPosition, initial.declinedParameterColon(1));
}

test "admission deduplicates raw positions before conversion" {
    const source = "abc\ndef";
    var collector = AdmissionCollector.init(std.testing.allocator, .collect);
    defer collector.deinit();
    collector.source = source;
    var history = AdmissionObservationHistory.init(std.testing.allocator);
    defer history.deinit();
    history.source = source;
    const sink = AdmissionSink.init(&collector, &history);
    const physical: AdmissionDiagnostic = .{ .kind = .any_type, .span = .{ .start = 4, .end = 7 } };
    try sink.recordRecoverable(physical);
    try sink.recordRecoverable(.{
        .kind = .void_type,
        .span = .{ .start = 0, .end = 1 },
        .presentation = .{ .line = 2, .column = 1 },
    });
    const shifted: AdmissionDiagnostic = .{
        .kind = .default_parameter,
        .span = physical.span,
        .presentation = .{ .line = 3, .column = 1 },
    };
    try sink.recordRecoverable(shifted);
    try std.testing.expectEqual(@as(usize, 2), collector.items().len);
    try std.testing.expectEqual(@as(usize, 2), history.items().len);
    try std.testing.expectEqualDeep(physical, collector.items()[0]);
    try std.testing.expectEqualDeep(shifted, history.last().?);
    try std.testing.expectEqual(@as(u64, 3), collector.generation());
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
    const source = "(x: any) =>\r " ++ ("any | " ** first_capacity) ++ "any";
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

test "admitted absent declarations preserve comment boundaries and cursor accounting" {
    const cases = [_][]const u8{
        "structural Shape/* gap */ const live = 1;",
        "structural Shape\r // gap\n const live = 1;",
        "export structural Shape<T>\r /* gap */ const live = 1;",
    };
    try std.testing.expectEqual(@as(usize, 3), cases.len);
    for (cases) |source| {
        var store = Store.init(std.testing.allocator, source);
        defer store.deinit();
        var cursor = Cursor.init(source);
        const exported = cursor.current.type == .kw_export;
        const export_span: ?Span = if (exported) .{ .start = 0, .end = 6 } else null;
        if (exported) cursor.advance();
        const keyword = cursor.current;
        cursor.advance();
        const consumed_before = cursor.consumed;
        const generic_list: ?Span = if (std.mem.indexOfScalar(u8, source, '<')) |start| .{
            .start = @intCast(start),
            .end = @intCast(std.mem.indexOfScalar(u8, source, '>').? + 1),
        } else null;
        const comment: u32 = @intCast(std.mem.indexOfScalar(u8, source, '/').?);
        const span = switch (try parseAdmittedDeclarationAndStore(&store, .{
            .keyword = keyword,
            .export_span = export_span,
            .kind = .structural,
            .authored_scope = 7,
            .generic_list = generic_list,
            .body = null,
            .raw_header_end = comment,
        }, &cursor)) {
            .parsed => |value| value,
            else => return error.TestUnexpectedResult,
        };
        try std.testing.expectEqual(comment, span.end);
        try std.testing.expectEqual(@as(u32, 0), span.start);
        try std.testing.expectEqual(consumed_before + 1, cursor.consumed);
        try std.testing.expectEqual(token_mod.TokenType.kw_const, cursor.current.type);
        try std.testing.expectEqual(@as(usize, 1), store.declarations.items.len);
        const declaration = store.declarations.items[0];
        try std.testing.expectEqual(@as(u16, 7), declaration.authored_scope);
        try std.testing.expectEqualDeep(export_span, declaration.export_span);
        try std.testing.expectEqualStrings("Shape", declaration.name_span.text(source));
        try std.testing.expect(declaration.equals_span == null);
        try std.testing.expect(declaration.terminator_span == null);
        switch (declaration.body) {
            .absent => {},
            else => return error.TestUnexpectedResult,
        }
        try std.testing.expectEqual(@as(usize, if (generic_list != null) 1 else 0), store.generic_owners.items.len);
        if (generic_list != null) {
            try std.testing.expectEqual(@as(?u32, 0), declaration.generic_owner);
            switch (store.generic_owners.items[0].identity) {
                .structural_declaration => |index| try std.testing.expectEqual(@as(u32, 0), index),
                else => return error.TestUnexpectedResult,
            }
        } else try std.testing.expect(declaration.generic_owner == null);
        try store.validate();
    }
}

test "admitted absent declarations validate boundaries before allocation" {
    const source = "structural Shape<T> /* gap */ const live = 1;";
    const generic_start: u32 = @intCast(std.mem.indexOfScalar(u8, source, '<').?);
    const generic_end: u32 = @intCast(std.mem.indexOfScalar(u8, source, '>').? + 1);
    const comment: u32 = @intCast(std.mem.indexOfScalar(u8, source, '/').?);
    const Case = enum { nominal, body, keyword, name, export_span, generic_span, missing_generic, early, late, outside };
    inline for (std.meta.tags(Case)) |case| {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
        var store = Store.init(failing.allocator(), source);
        defer store.deinit();
        var cursor = Cursor.init(source);
        const keyword = cursor.current;
        cursor.advance();
        var options: AdmittedDeclarationOptions = .{
            .keyword = keyword,
            .export_span = null,
            .kind = .structural,
            .authored_scope = 0,
            .generic_list = .{ .start = generic_start, .end = generic_end },
            .body = null,
            .raw_header_end = comment,
        };
        switch (case) {
            .nominal => options.kind = .nominal,
            .body => options.body = .{ .raw_span = .{ .start = 0, .end = 1 }, .admission_end = 1 },
            .keyword => options.keyword.start = std.math.maxInt(u32),
            .name => cursor.current.start = std.math.maxInt(u32),
            .export_span => options.export_span = .{ .start = 0, .end = 6 },
            .generic_span => options.generic_list.?.end -= 1,
            .missing_generic => options.generic_list = null,
            .early => options.raw_header_end = comment - 1,
            .late => options.raw_header_end = comment + 1,
            .outside => options.raw_header_end = std.math.maxInt(u32),
        }
        const prior_cursor = cursor;
        const prior = store.checkpoint();
        try std.testing.expectError(error.InvalidAdmissionSpan, parseAdmittedDeclarationAndStore(&store, options, &cursor));
        try std.testing.expectEqualDeep(prior_cursor, cursor);
        try std.testing.expectEqualDeep(prior, store.checkpoint());
        try std.testing.expectEqual(@as(usize, 0), failing.alloc_index);
        try std.testing.expect(!failing.has_induced_failure);
    }
}

test "admitted absent declaration allocation failures restore syntax and cursor" {
    const Context = struct {
        fn run(allocator: std.mem.Allocator, failures: *usize) !void {
            const source = "structural Shape<T>/* gap */ const live = 1;";
            var store = Store.init(allocator, source);
            defer store.deinit();
            var cursor = Cursor.init(source);
            const keyword = cursor.current;
            cursor.advance();
            const prior = store.checkpoint();
            const prior_cursor = cursor;
            const outcome = parseAdmittedDeclarationAndStore(&store, .{
                .keyword = keyword,
                .export_span = null,
                .kind = .structural,
                .authored_scope = 0,
                .generic_list = .{
                    .start = @intCast(std.mem.indexOfScalar(u8, source, '<').?),
                    .end = @intCast(std.mem.indexOfScalar(u8, source, '>').? + 1),
                },
                .body = null,
                .raw_header_end = @intCast(std.mem.indexOfScalar(u8, source, '/').?),
            }, &cursor) catch |err| {
                try std.testing.expectEqualDeep(prior, store.checkpoint());
                try std.testing.expectEqualDeep(prior_cursor, cursor);
                failures.* += 1;
                return err;
            };
            switch (outcome) {
                .parsed => {},
                else => return error.TestUnexpectedResult,
            }
            try store.validate();
            try std.testing.expectEqual(@as(usize, 1), store.declarations.items.len);
        }
    };
    var failures: usize = 0;
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Context.run, .{&failures});
    try std.testing.expect(failures > 0);
}
