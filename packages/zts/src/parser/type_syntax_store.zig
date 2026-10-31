//! The type syntax store: the node, annotation, declaration, and admission records and the `Store` that owns them.

const std = @import("std");
const ir = @import("ir.zig");
const token_mod = @import("token.zig");
const TokenType = token_mod.TokenType;
const BindingRef = ir.BindingRef;
const Token = token_mod.Token;
const scan_mod = @import("type_syntax_scan.zig");
const isTypeWhitespace = scan_mod.isTypeWhitespace;
const parser_mod = @import("type_syntax_parser.zig");
const appendAuthoredGenericParameters = parser_mod.appendAuthoredGenericParameters;
const appendProjectedParametersWithBounds = parser_mod.appendProjectedParametersWithBounds;
const projectedListBody = parser_mod.projectedListBody;
const appendAuthoredCallArguments = parser_mod.appendAuthoredCallArguments;
const appendProjectedCallFragments = parser_mod.appendProjectedCallFragments;
const scanRawTypeOnlyModule = scan_mod.scanRawTypeOnlyModule;
const hasLegacyGuardFacet = parser_mod.hasLegacyGuardFacet;
const predicateHeader = parser_mod.predicateHeader;
const spanContainsOnlyTypeWhitespace = scan_mod.spanContainsOnlyTypeWhitespace;
const isIdentifierStart = parser_mod.isIdentifierStart;
const isIdentifierContinue = parser_mod.isIdentifierContinue;
const containsOnlyTypeWhitespace = scan_mod.containsOnlyTypeWhitespace;
const Cursor = scan_mod.Cursor;
const max_type_depth = parser_mod.max_type_depth;
const support_mod = @import("type_syntax_support.zig");
const TestRuntime = support_mod.TestRuntime;
const validateAfterAllocationFailure = support_mod.validateAfterAllocationFailure;
const seedNumberAnnotation = support_mod.seedNumberAnnotation;
const parseFunctionReturnAndStore = parser_mod.parseFunctionReturnAndStore;
const classifyTypeSpan = scan_mod.classifyTypeSpan;

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
    retired_types_import,
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
    recorded_span: Span,
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
    bound_span: ?Span,
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

    pub fn appendNode(self: *Store, value: Node) !NodeIndex {
        const index = std.math.cast(NodeIndex, self.nodes.items.len) orelse return error.TooManyTypeNodes;
        try self.nodes.append(self.allocator, value);
        return index;
    }

    pub fn appendMembers(self: *Store, values: []const Child) !Range {
        return appendRange(Child, self.allocator, &self.members, values);
    }

    pub fn appendFields(self: *Store, values: []const Field) !Range {
        return appendRange(Field, self.allocator, &self.fields, values);
    }

    pub fn appendParams(self: *Store, values: []const Parameter) !Range {
        return appendRange(Parameter, self.allocator, &self.params, values);
    }

    pub fn appendTemplateParts(self: *Store, values: []const TemplatePart) !Range {
        return appendRange(TemplatePart, self.allocator, &self.template_parts, values);
    }

    pub fn appendAnnotation(self: *Store, value: Annotation) !void {
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
            projectedListBody(self.source, options.capture_spans.recorded_span),
            options.policy == .callable,
        );

        const compatibility: GenericOwnerCompatibility = switch (options.policy) {
            .structural, .callable => .declaration_parameters,
            .ignored => .ignored_declaration_parameters,
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
                .callable => return error.InvalidGenericOwner,
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
        try appendProjectedCallFragments(self, options.capture_spans.recorded_span);

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
                    projectedListBody(self.source, options.capture_spans.recorded_span),
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
            if (parameter.bound_span) |span| {
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

    pub fn validateAnnotation(self: *const Store, annotation: Annotation) !void {
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

    pub fn validateTypeValue(self: *const Store, value: TypeValue) !void {
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

    pub fn validateReturnSyntax(self: *const Store, value: ReturnSyntax) !void {
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
                    if (!spanContains(prefix.capture_spans.recorded_span, parameter.raw_span)) {
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
                        const bound_span = parameter.bound_span orelse
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
            capture_spans.recorded_span.start == legacy_start and
            capture_spans.recorded_span.end == legacy_end;
        const legacy_projected_end = std.math.add(
            u32,
            capture_spans.recorded_span.end,
            1,
        ) catch return error.InvalidErasedTypePrefix;
        const general_capture = capture_spans.actual_erased_span.start == list_span.start and
            capture_spans.actual_erased_span.end >= list_span.end and
            capture_spans.recorded_span.start == legacy_start and
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

    pub fn validateDeclaration(self: *const Store, declaration: Declaration) !void {
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

    pub fn validateSemanticFragment(self: *const Store, fragment: SemanticFragment) !void {
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
        try self.validateSpan(capture_spans.recorded_span);
    }

    fn validateOwnerCaptureSpans(
        self: *const Store,
        list_span: Span,
        capture_spans: GenericCaptureSpans,
    ) !void {
        try self.validateCaptureSpans(capture_spans);
        if (capture_spans.actual_erased_span.start != list_span.start or
            !spanContains(capture_spans.actual_erased_span, list_span) or
            !spanContains(capture_spans.actual_erased_span, capture_spans.recorded_span))
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
                    const bound_span = parameter.bound_span orelse return error.InvalidGenericOwner;
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
                    const bound_span = parameter.bound_span orelse return error.InvalidGenericOwner;
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
                owner.capture_spans.recorded_span.start == owner.list_span.start + 1 and
                owner.capture_spans.recorded_span.end == owner.list_span.end - 1 and
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
        const owners = try self.allocator.alloc(u8, self.nodes.items.len);
        defer self.allocator.free(owners);
        @memset(owners, 0);
        for (self.annotations.items) |annotation| {
            try claimRange(owners, annotation.node_range, error.OverlappingTypeNodeOwnership);
        }
        for (self.declarations.items) |declaration| switch (declaration.body) {
            .absent => {},
            .present => |body| try claimRange(
                owners,
                body.node_range,
                error.OverlappingTypeNodeOwnership,
            ),
        };
        for (self.semantic_fragments.items) |fragment| {
            try claimRange(owners, fragment.node_range, error.OverlappingTypeNodeOwnership);
        }
        for (self.parameter_annotations.items) |parameter| {
            try claimRange(owners, parameter.value.node_range, error.OverlappingTypeNodeOwnership);
        }
        for (self.function_signatures.items) |signature| {
            const return_syntax = signature.return_syntax orelse continue;
            switch (return_syntax.structure) {
                .value => |value| try claimRange(
                    owners,
                    value.node_range,
                    error.OverlappingTypeNodeOwnership,
                ),
                .predicate => |predicate| try claimRange(
                    owners,
                    predicate.narrowed.node_range,
                    error.OverlappingTypeNodeOwnership,
                ),
            }
            if (return_syntax.legacy_ordinary_prefix) |compatibility| {
                try claimRange(
                    owners,
                    compatibility.node_range,
                    error.OverlappingTypeNodeOwnership,
                );
            }
        }
    }

    pub fn validateSpan(self: *const Store, span: Span) !void {
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

pub fn rangesOverlap(left: Range, right: Range) bool {
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

test "explicit call reservation owns its record and rolls back every array" {
    var no_resize = std.testing.FailingAllocator.init(std.testing.allocator, .{ .resize_fail_index = 0 });
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
                    .recorded_span = .{ .start = first_start + 1, .end = first_lparen - 1 },
                },
            });
            try store.finishExplicitCall(&first, first_call, runtime.view());
            try std.testing.expect(!first.active);
            try validateAfterAllocationFailure(&store);
            var first_bases = try planApplicationBasesAfterAllocationFailure(&store, runtime.view());
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
                    .recorded_span = .{ .start = second_start + 1, .end = second_lparen - 1 },
                },
            }) catch |err| switch (err) {
                error.OutOfMemory => {
                    observed_later_failures.* += 1;
                    try std.testing.expect(std.meta.eql(prior, store.checkpoint()));
                    try validateAfterAllocationFailure(&store);
                    var retained_bases = try planApplicationBasesAfterAllocationFailure(&store, runtime.view());
                    retained_bases.deinit();
                    return error.OutOfMemory;
                },
                else => return err,
            };
            try store.finishExplicitCall(&second, second_call, runtime.view());
            try validateAfterAllocationFailure(&store);
            var completed_bases = try planApplicationBasesAfterAllocationFailure(&store, runtime.view());
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
                    .recorded_span = .{ .start = second_start + 1, .end = second_lparen - 1 },
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
        no_resize.allocator(),
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
            .recorded_span = .{ .start = list_start + 1, .end = lparen - 1 },
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
        .recorded_span = .{ .start = 1, .end = 2 },
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
                    .recorded_span = .{ .start = 1, .end = 2 },
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
                store.generic_owners.items[0].capture_spans.recorded_span = .{ .start = 0, .end = 3 };
                try std.testing.expectError(
                    error.InvalidGenericOwner,
                    store.validateRuntimeOwners(std.testing.allocator, runtime.view()),
                );
                store.generic_owners.items[0].capture_spans.recorded_span = .{ .start = 1, .end = 2 };
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
                    .recorded_span = .{ .start = 2, .end = 3 },
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
                    .recorded_span = .{ .start = 5, .end = 5 },
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
                    .recorded_span = .{ .start = 1, .end = 2 },
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
                    .recorded_span = .{ .start = 1, .end = 2 },
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
                    .recorded_span = .{ .start = 1, .end = 2 },
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
                .recorded_span = .{ .start = 1, .end = 2 },
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
                .recorded_span = .{ .start = 1, .end = @intCast(source.len - 1) },
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
        .recorded_span = .{ .start = 1, .end = 2 },
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

test "explicit calls own their argument and fragment ranges" {
    const source = "<string>(";
    var store = Store.init(std.testing.allocator, source);
    defer store.deinit();
    var runtime = TestRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    const call = try runtime.addCall(8);
    const capture_spans: GenericCaptureSpans = .{
        .actual_erased_span = .{ .start = 0, .end = 8 },
        .recorded_span = .{ .start = 0, .end = 8 },
    };

    var explicit = try store.reserveExplicitCall(.{
        .list_span = .{ .start = 0, .end = 8 },
        .capture_spans = capture_spans,
    });
    try store.finishExplicitCall(&explicit, call, runtime.view());
    try store.validateRuntimeOwners(std.testing.allocator, runtime.view());

    const original_arguments = store.explicit_call_arguments.items[0].authored_arguments;

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

fn appendTypeOwnersForTest(store: *Store, owner_count: usize) !void {
    const allocator = store.allocator;
    try store.nodes.ensureTotalCapacity(allocator, owner_count);
    try store.annotations.ensureTotalCapacity(allocator, owner_count);
    for (0..owner_count) |index| {
        store.nodes.appendAssumeCapacity(.{
            .tag = .primitive,
            .semantic_span = .{ .start = 0, .end = 0 },
            .data = .{ .primitive = .number },
        });
        store.annotations.appendAssumeCapacity(.{
            .binding = .global(0),
            .root = .{ .present = @intCast(index) },
            .node_range = .{ .start = @intCast(index), .count = 1 },
            .raw_span = .{ .start = 0, .end = 0 },
            .admission_end = 0,
            .semantic_prefix_end = 0,
        });
    }
}

test "validating 2500 disjoint type owners succeeds" {
    var store = Store.init(std.testing.allocator, "");
    defer store.deinit();
    try appendTypeOwnersForTest(&store, 2500);
    try store.validate();
}

test "type owner validation rejects invalid ranges and allocation failure" {
    const allocator = std.testing.allocator;
    var store = Store.init(allocator, "");
    defer store.deinit();
    try appendTypeOwnersForTest(&store, 2);

    std.mem.swap(Annotation, &store.annotations.items[0], &store.annotations.items[1]);
    try store.validate();
    std.mem.swap(Annotation, &store.annotations.items[0], &store.annotations.items[1]);

    store.annotations.items[1].node_range.start = 0;
    store.annotations.items[1].root = .{ .present = 0 };
    try std.testing.expectError(error.OverlappingTypeNodeOwnership, store.validate());
    store.annotations.items[1].node_range.start = 2;
    store.annotations.items[1].root = .{ .present = 1 };
    try std.testing.expectError(error.InvalidTypeRange, store.validate());
    store.annotations.items[1].node_range.start = 1;

    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    store.allocator = failing.allocator();
    try std.testing.expectError(error.OutOfMemory, store.validate());
    store.allocator = allocator;
}

test "type store validation rejects invalid nodes without erasing prior syntax" {
    const Case = enum { tag, range, child, span };
    inline for (std.meta.tags(Case)) |case| {
        var store = Store.init(std.testing.allocator, "number");
        defer store.deinit();
        try seedNumberAnnotation(&store);
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
    try seedNumberAnnotation(&store);
    const valid = store.annotations.items[0];
    store.annotations.items[0].root = .{ .present = @intCast(store.nodes.items.len) };
    try std.testing.expectError(error.InvalidTypeChild, store.validate());
    store.annotations.items[0] = valid;
    store.annotations.items[0].admission_end = 7;
    try std.testing.expectError(error.InvalidTypeSpan, store.validate());
    store.annotations.items[0] = valid;
    try store.validate();
}

fn planApplicationBasesAfterAllocationFailure(
    store: *Store,
    view: ir.IrView,
) !Store.ApplicationBasePlan {
    const allocator = store.allocator;
    store.allocator = std.testing.allocator;
    defer store.allocator = allocator;
    return store.planApplicationBasesWithIr(std.testing.allocator, view);
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
        .retired_types_import,
        .default_parameter,
        .optional_parameter,
        .default_export,
        .mutable_export,
        .array_type_alias,
        .readonly_array_type_alias,
        .void_type,
        .nesting_too_deep,
    };
    try std.testing.expectEqual(@as(usize, 17), @typeInfo(AdmissionKind).@"enum".field_names.len);
    for (expected, 0..) |kind, index| {
        try std.testing.expectEqual(index, @backingInt(kind));
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

test "admission observation history preserves the first kind at one position" {
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
