//! Parser-owned TypeScript syntax that has no runtime representation.
//!
//! The store borrows the original source and owns only compact syntax arrays.
//! It does not intern names or allocate runtime nodes, constants, or scopes.

const std = @import("std");
const ir = @import("ir.zig");
const token_mod = @import("token.zig");
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
        group: Child,
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
    function_declaration_paren: u32,
    arrow_function_paren: u32,
};

pub const GenericOwner = struct {
    identity: GenericOwnerIdentity,
    list_span: Span,
    authored_parameters: Range,
    projected_parameters: Range,
};

pub const GenericOwnerOptions = struct {
    identity: GenericOwnerIdentity,
    list_span: Span,
    projected_span: Span,
};

pub const PendingGenericOwner = struct {
    checkpoint: Store.Checkpoint,
    owner_index: u32,
    final_record: GenericOwner,
    active: bool = true,
};

pub const AuthoredCallArgument = struct {
    full_span: Span,
};

pub const ExplicitCallArguments = struct {
    lparen_offset: u32,
    list_span: Span,
    authored_arguments: Range,
    projected_fragments: Range,
};

pub const ExplicitCallOptions = struct {
    lparen_offset: u32,
    list_span: Span,
    projected_span: Span,
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

    pub fn reserveGenericOwner(
        self: *Store,
        options: GenericOwnerOptions,
    ) !PendingGenericOwner {
        const previous = self.checkpoint();
        errdefer self.rollback(previous);
        try self.validateSpan(options.list_span);
        try self.validateSpan(options.projected_span);
        if (options.projected_span.start < options.list_span.start or
            @as(usize, options.projected_span.end) > self.source.len)
        {
            return error.InvalidTypeSpan;
        }

        const authored_start = std.math.cast(u32, self.generic_parameters.items.len) orelse
            return error.TooManyTypeItems;
        const projected_start = std.math.cast(u32, self.projected_generic_parameters.items.len) orelse
            return error.TooManyTypeItems;
        try appendAuthoredGenericParameters(self, options.list_span);
        try appendProjectedGenericParametersFromSpan(self, projectedListBody(self.source, options.projected_span));
        const projected_end = self.projected_generic_parameters.items.len;
        const projected_start_index: usize = @intCast(projected_start);
        var compact_count: usize = 0;
        for (self.projected_generic_parameters.items[projected_start_index..projected_end]) |parameter| {
            if (parameter.name_span.start != parameter.name_span.end) compact_count += 1;
        }
        var projected_index = projected_start_index;
        while (projected_index < projected_end) : (projected_index += 1) {
            if (projected_index - projected_start_index >= compact_count) break;
            const bound_span = self.projected_generic_parameters.items[projected_index].legacy_bound_span orelse
                continue;
            const fragment_index = try parseSemanticFragmentAndStore(self, bound_span);
            self.projected_generic_parameters.items[projected_index].bound_fragment = fragment_index;
        }

        const owner_index = std.math.cast(u32, self.generic_owners.items.len) orelse
            return error.TooManyTypeItems;
        try self.generic_owners.ensureUnusedCapacity(self.allocator, 1);
        self.generic_owners.appendAssumeCapacity(undefined);
        return .{
            .checkpoint = previous,
            .owner_index = owner_index,
            .final_record = .{
                .identity = options.identity,
                .list_span = options.list_span,
                .authored_parameters = .{
                    .start = authored_start,
                    .count = @intCast(self.generic_parameters.items.len - authored_start),
                },
                .projected_parameters = .{
                    .start = projected_start,
                    .count = @intCast(projected_end - projected_start),
                },
            },
        };
    }

    pub fn finishGenericOwner(self: *Store, pending: *PendingGenericOwner) !void {
        if (!pending.active or @as(usize, pending.owner_index) >= self.generic_owners.items.len) {
            return error.InvalidGenericOwner;
        }
        self.generic_owners.items[pending.owner_index] = pending.final_record;
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
        try self.validateSpan(options.list_span);
        try self.validateSpan(options.projected_span);
        if (options.list_span.end != options.lparen_offset or
            options.projected_span.start < options.list_span.start or
            options.projected_span.end > options.list_span.end)
        {
            return error.InvalidTypeSpan;
        }

        const authored_start = std.math.cast(u32, self.authored_call_arguments.items.len) orelse
            return error.TooManyTypeItems;
        const projected_start = std.math.cast(u32, self.semantic_fragments.items.len) orelse
            return error.TooManyTypeItems;
        try appendAuthoredCallArguments(self, options.list_span);
        try appendProjectedCallFragments(self, options.projected_span);

        const record_index = std.math.cast(u32, self.explicit_call_arguments.items.len) orelse
            return error.TooManyTypeItems;
        try self.explicit_call_arguments.ensureUnusedCapacity(self.allocator, 1);
        self.explicit_call_arguments.appendAssumeCapacity(undefined);
        return .{
            .checkpoint = previous,
            .record_index = record_index,
            .final_record = .{
                .lparen_offset = options.lparen_offset,
                .list_span = options.list_span,
                .authored_arguments = .{
                    .start = authored_start,
                    .count = @intCast(self.authored_call_arguments.items.len - authored_start),
                },
                .projected_fragments = .{
                    .start = projected_start,
                    .count = @intCast(self.semantic_fragments.items.len - projected_start),
                },
            },
        };
    }

    pub fn finishExplicitCall(self: *Store, pending: *PendingExplicitCall) !void {
        if (!pending.active or @as(usize, pending.record_index) >= self.explicit_call_arguments.items.len) {
            return error.InvalidGenericOwner;
        }
        self.explicit_call_arguments.items[pending.record_index] = pending.final_record;
        pending.active = false;
    }

    pub fn cancelExplicitCall(self: *Store, pending: *PendingExplicitCall) void {
        if (!pending.active) return;
        self.rollback(pending.checkpoint);
        pending.active = false;
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
                .group => |child| try validateChild(child, index),
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
        try validateChild(root, self.nodes.items.len);
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
        for (self.generic_owners.items, 0..) |owner, index| try self.validateGenericOwner(owner, index);
        for (self.authored_call_arguments.items) |argument| try self.validateSpan(argument.full_span);
        for (self.explicit_call_arguments.items, 0..) |arguments, index| {
            try self.validateExplicitCallArguments(arguments);
            for (self.explicit_call_arguments.items[0..index]) |prior| {
                if (prior.lparen_offset == arguments.lparen_offset) return error.InvalidGenericOwner;
            }
        }
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
        try self.validate();
        try self.validateSemanticFragmentOwners(allocator);
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
        return .{ .allocator = allocator, .uses = base_uses };
    }

    fn validateSemanticFragmentOwners(
        self: *const Store,
        allocator: std.mem.Allocator,
    ) !void {
        const owners = try allocator.alloc(u8, self.semantic_fragments.items.len);
        defer allocator.free(owners);
        @memset(owners, 0);

        for (self.generic_owners.items) |owner| {
            const projected = self.projectedGenericParameterSlice(owner.projected_parameters) orelse
                return error.InvalidTypeRange;
            for (projected) |parameter| {
                if (parameter.bound_fragment) |fragment_index| {
                    try claimSemanticFragment(owners, fragment_index);
                }
            }
        }
        for (self.explicit_call_arguments.items) |arguments| {
            const start: usize = arguments.projected_fragments.start;
            const end = std.math.add(
                usize,
                start,
                arguments.projected_fragments.count,
            ) catch return error.InvalidTypeRange;
            if (end > owners.len) return error.InvalidTypeRange;
            for (start..end) |fragment_index| {
                try claimSemanticFragment(owners, @intCast(fragment_index));
            }
        }
        for (owners) |owner_count| {
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
            .group => |child| markOrdinaryUse(child, ordinary_uses),
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
        try self.validateOwnedNodes(annotation.node_range);
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
            const declaration_index = switch (owner.identity) {
                .structural_declaration => |index| index,
                else => return error.InvalidGenericOwner,
            };
            if (declaration_index != declaration.source_order or
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
                try self.validateOwnedNodes(body.node_range);
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
        try self.validateOwnedNodes(fragment.node_range);
    }

    fn validateGenericOwner(self: *const Store, owner: GenericOwner, owner_index: usize) !void {
        try self.validateSpan(owner.list_span);
        if (owner.list_span.end - owner.list_span.start < 2 or
            self.source[owner.list_span.start] != '<' or
            self.source[owner.list_span.end - 1] != '>')
        {
            return error.InvalidGenericOwner;
        }
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
        switch (owner.identity) {
            .structural_declaration => |declaration_index| {
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
            .function_declaration_paren, .arrow_function_paren => |offset| {
                if (@as(usize, offset) >= self.source.len or self.source[offset] != '(') {
                    return error.InvalidGenericOwner;
                }
                for (self.generic_owners.items[0..owner_index]) |prior| switch (prior.identity) {
                    .function_declaration_paren, .arrow_function_paren => |prior_offset| {
                        if (prior_offset == offset) return error.InvalidGenericOwner;
                    },
                    .structural_declaration => {},
                };
                for (projected) |parameter| if (parameter.bound_fragment) |fragment_index| {
                    const fragment = self.semantic_fragments.items[fragment_index];
                    const bound_span = parameter.legacy_bound_span orelse return error.InvalidGenericOwner;
                    if (!std.meta.eql(fragment.raw_span, bound_span)) return error.InvalidGenericOwner;
                };
            },
        }
    }

    fn validateExplicitCallArguments(self: *const Store, arguments: ExplicitCallArguments) !void {
        try self.validateSpan(arguments.list_span);
        const authored = rangeSlice(AuthoredCallArgument, self.authored_call_arguments.items, arguments.authored_arguments) orelse
            return error.InvalidTypeRange;
        const projected = self.semanticFragmentSlice(arguments.projected_fragments) orelse return error.InvalidTypeRange;
        if (projected.len > 8) return error.InvalidTypeRange;
        if (@as(usize, arguments.lparen_offset) >= self.source.len or
            self.source[arguments.lparen_offset] != '(' or
            arguments.list_span.end != arguments.lparen_offset or
            arguments.list_span.end - arguments.list_span.start < 2 or
            self.source[arguments.list_span.start] != '<' or
            self.source[arguments.list_span.end - 1] != '>')
        {
            return error.InvalidGenericOwner;
        }
        for (authored) |argument| {
            if (!spanContains(arguments.list_span, argument.full_span)) return error.InvalidTypeSpan;
        }
        for (projected) |fragment| {
            if (!spanContains(arguments.list_span, fragment.raw_span)) return error.InvalidTypeSpan;
        }
    }

    fn validateRecordOwnership(self: *const Store) !void {
        var authored_parameter_end: u32 = 0;
        var projected_parameter_end: u32 = 0;
        for (self.generic_owners.items) |owner| {
            if (owner.authored_parameters.start != authored_parameter_end or
                owner.projected_parameters.start != projected_parameter_end)
            {
                return error.InvalidGenericOwner;
            }
            authored_parameter_end = std.math.add(
                u32,
                authored_parameter_end,
                owner.authored_parameters.count,
            ) catch return error.InvalidTypeRange;
            projected_parameter_end = std.math.add(
                u32,
                projected_parameter_end,
                owner.projected_parameters.count,
            ) catch return error.InvalidTypeRange;
        }
        if (@as(usize, authored_parameter_end) != self.generic_parameters.items.len or
            @as(usize, projected_parameter_end) != self.projected_generic_parameters.items.len)
        {
            return error.InvalidGenericOwner;
        }

        var authored_argument_end: u32 = 0;
        var prior_call_fragment_end: u32 = 0;
        for (self.explicit_call_arguments.items) |arguments| {
            if (arguments.authored_arguments.start != authored_argument_end or
                arguments.projected_fragments.start < prior_call_fragment_end)
            {
                return error.InvalidGenericOwner;
            }
            authored_argument_end = std.math.add(
                u32,
                authored_argument_end,
                arguments.authored_arguments.count,
            ) catch return error.InvalidTypeRange;
            prior_call_fragment_end = std.math.add(
                u32,
                arguments.projected_fragments.start,
                arguments.projected_fragments.count,
            ) catch return error.InvalidTypeRange;
        }
        if (@as(usize, authored_argument_end) != self.authored_call_arguments.items.len) {
            return error.InvalidGenericOwner;
        }
    }

    fn validateOwnedNodes(self: *const Store, owner: Range) !void {
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
            .group => |child| try validateOwnedChild(child, owner),
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

fn claimSemanticFragment(owners: []u8, fragment_index: u32) !void {
    if (@as(usize, fragment_index) >= owners.len) return error.InvalidTypeRange;
    if (owners[fragment_index] != 0) return error.SharedSemanticFragment;
    owners[fragment_index] = 1;
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

/// Parse and publish one admitted type annotation. The runtime parser calls
/// this only through its private typed initializer.
pub fn parseAndStore(
    store: *Store,
    binding: BindingRef,
    source: []const u8,
    after_colon: u32,
    cursor: *Cursor,
) !TypeParseOutcome {
    const checkpoint = store.checkpoint();
    errdefer store.rollback(checkpoint);

    const raw_start = skipTypeWhitespace(source, after_colon);
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
    const annotation: Annotation = .{
        .binding = binding,
        .root = parsed.child,
        .node_range = .{
            .start = @intCast(checkpoint.nodes),
            .count = @intCast(store.nodes.items.len - checkpoint.nodes),
        },
        .raw_span = .{ .start = raw_start, .end = raw_end },
        .admission_end = admission_end,
        .semantic_prefix_end = parsed.end,
    };
    try store.validateAnnotation(annotation);
    try store.appendAnnotation(annotation);
    cursor.* = scanned;
    return .{ .parsed = .{
        .root = parsed.child,
        .semantic_span = .{ .start = raw_start, .end = parsed.end },
        .raw_span = .{ .start = raw_start, .end = raw_end },
    } };
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
    },
    not_declaration,
};

pub const GenericListScan = struct {
    span: Span,
    suppressed_diagnostic: bool,
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
    if (quote != '`') {
        const scanned = scanLegacyPlainQuoted(source, start, quote);
        if (scanned.unterminated_line and propagate_errors) return null;
        if (scanned.unterminated_line) suppressed_diagnostic.* = true;
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
            if (nested.unterminated_line) suppressed_diagnostic.* = true;
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
                if (frame.propagate_errors) return null;
                suppressed_diagnostic.* = true;
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

fn skipLegacyMatchingBracket(
    allocator: std.mem.Allocator,
    source: []const u8,
    start: usize,
    open: u8,
    suppressed_diagnostic: *bool,
) !?usize {
    const close: u8 = switch (open) {
        '(' => ')',
        '[' => ']',
        '{' => '}',
        else => return start + 1,
    };
    var depth: u16 = 1;
    var pos = start + 1;
    while (pos < source.len and depth > 0) {
        const byte = source[pos];
        if (byte == '"' or byte == '\'' or byte == '`') {
            pos = (try scanLegacyGenericQuoted(
                allocator,
                source,
                pos,
                byte,
                false,
                suppressed_diagnostic,
            )) orelse pos + 1;
            continue;
        }
        if (byte == open) {
            if (depth >= max_type_depth) return null;
            depth += 1;
        } else if (byte == close) {
            depth -= 1;
        }
        pos += 1;
    }
    return pos;
}

pub fn scanBalancedGenericList(
    allocator: std.mem.Allocator,
    source: []const u8,
    start: u32,
) !?GenericListScan {
    if (@as(usize, start) >= source.len or source[start] != '<') return null;
    var angle_depth: u16 = 1;
    var suppressed_diagnostic = false;
    var pos: usize = start + 1;
    while (pos < source.len and angle_depth > 0) {
        const byte = source[pos];
        if (byte == '"' or byte == '\'' or byte == '`') {
            pos = (try scanLegacyGenericQuoted(
                allocator,
                source,
                pos,
                byte,
                true,
                &suppressed_diagnostic,
            )) orelse return null;
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
                if (pos + 1 >= source.len) return null;
                pos += 2;
                continue;
            }
        }
        switch (byte) {
            '<' => {
                if (angle_depth >= max_type_depth) return null;
                angle_depth += 1;
            },
            '>' => if (pos == 0 or source[pos - 1] != '=') {
                angle_depth -= 1;
            },
            '(', '[', '{' => {
                pos = (try skipLegacyMatchingBracket(
                    allocator,
                    source,
                    pos,
                    byte,
                    &suppressed_diagnostic,
                )) orelse return null;
                continue;
            },
            else => {},
        }
        pos += 1;
    }
    if (angle_depth != 0) return null;
    return .{
        .span = .{ .start = start, .end = @intCast(pos) },
        .suppressed_diagnostic = suppressed_diagnostic,
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

pub fn scanExplicitCallTypeArguments(
    allocator: std.mem.Allocator,
    source: []const u8,
    start: u32,
) !ExplicitCallScan {
    if (@as(usize, start) >= source.len or source[start] != '<') return .not_call;
    var angle_depth: u16 = 1;
    var paren_depth: u16 = 0;
    var bracket_depth: u16 = 0;
    var brace_depth: u16 = 0;
    var suppressed_diagnostic = false;
    var pos: usize = start + 1;
    while (pos < source.len) {
        const byte = source[pos];
        if (byte == '"' or byte == '\'' or byte == '`') {
            pos = (try scanLegacyGenericQuoted(
                allocator,
                source,
                pos,
                byte,
                true,
                &suppressed_diagnostic,
            )) orelse return .excluded;
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
                if (pos + 1 >= source.len) return .excluded;
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
                        return .not_call;
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
            )) return .excluded,
            '(' => if (!increaseCombinedGenericDepth(
                &paren_depth,
                angle_depth,
                bracket_depth,
                brace_depth,
            )) return .excluded,
            ')' => {
                if (paren_depth == 0) return .not_call;
                paren_depth -= 1;
            },
            '[' => if (!increaseCombinedGenericDepth(
                &bracket_depth,
                angle_depth,
                paren_depth,
                brace_depth,
            )) return .excluded,
            ']' => {
                if (bracket_depth == 0) return .not_call;
                bracket_depth -= 1;
            },
            '{' => if (!increaseCombinedGenericDepth(
                &brace_depth,
                angle_depth,
                paren_depth,
                bracket_depth,
            )) return .excluded,
            '}' => {
                if (brace_depth == 0) return .not_call;
                brace_depth -= 1;
            },
            '=' => {
                if (pos + 1 >= source.len or source[pos + 1] != '>') return .not_call;
                pos += 2;
                continue;
            },
            '|', '&' => if (pos + 1 < source.len and source[pos + 1] == byte) return .not_call,
            '?', ':' => if (paren_depth == 0 and bracket_depth == 0 and brace_depth == 0) return .not_call,
            ';' => if (brace_depth == 0) return .not_call,
            '-' => if (pos + 1 >= source.len or !std.ascii.isDigit(source[pos + 1])) return .not_call,
            ' ', '\t', '\n', '\r', ',', '.' => {},
            else => if (!isIdentifierContinue(byte)) return .not_call,
        }
        pos += 1;
    }
    return .not_call;
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

fn appendGenericList(
    store: *Store,
    list_span: Span,
    declaration_index: u32,
) !u32 {
    const authored_start = std.math.cast(u32, store.generic_parameters.items.len) orelse
        return error.TooManyTypeItems;
    const projected_start = std.math.cast(u32, store.projected_generic_parameters.items.len) orelse
        return error.TooManyTypeItems;
    try appendAuthoredGenericParameters(store, list_span);
    try appendProjectedGenericParameters(store, list_span);
    const owner_index = std.math.cast(u32, store.generic_owners.items.len) orelse
        return error.TooManyTypeItems;
    try store.generic_owners.append(store.allocator, .{
        .identity = .{ .structural_declaration = declaration_index },
        .list_span = list_span,
        .authored_parameters = .{
            .start = authored_start,
            .count = @intCast(store.generic_parameters.items.len - authored_start),
        },
        .projected_parameters = .{
            .start = projected_start,
            .count = @intCast(store.projected_generic_parameters.items.len - projected_start),
        },
    });
    return owner_index;
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
    const checkpoint = store.checkpoint();
    var published = false;
    defer if (!published) store.rollback(checkpoint);

    var scanned = cursor.*;
    if (!tokenIsDeclarationName(scanned.current, source)) return .not_declaration;
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

    var generic_owner: ?u32 = null;
    if (@as(usize, scanned.current.start) < source.len and source[scanned.current.start] == '<') {
        if (kind != .structural) return .not_declaration;
        const generic_list = (try scanBalancedGenericList(
            store.allocator,
            source,
            scanned.current.start,
        )) orelse
            return .not_declaration;
        if (!isPrivateGenericListEligible(source, generic_list)) {
            return .{ .excluded = .{
                .reason = .unsupported_syntax,
                .raw_span = generic_list.span,
                .admission_end = generic_list.span.end,
            } };
        }
        const declaration_index = std.math.cast(u32, store.declarations.items.len) orelse
            return error.TooManyTypeItems;
        generic_owner = try appendGenericList(store, generic_list.span, declaration_index);
        advanceCursorTo(&scanned, generic_list.span.end);
        if (!containsOnlyTypeWhitespace(source, generic_list.span.end, scanned.current.start)) {
            return .not_declaration;
        }
    }

    var equals_span: ?Span = null;
    var body: DeclarationBody = .absent;
    var erased_end = scanned.current.start;
    if (scanned.current.type == .assign) {
        equals_span = tokenSpan(scanned.current);
        const after_equals = scanned.current.start + scanned.current.len;
        erased_end = after_equals;
        scanned.advance();

        const raw_start = skipTypeWhitespace(source, after_equals);
        const admission_end = switch (scanDeclarationEnd(source, raw_start)) {
            .end => |end| end,
            else => return .not_declaration,
        };
        erased_end = skipTypeWhitespace(source, admission_end);
        advanceCursorTo(&scanned, admission_end);
        const raw_end = trimWhitespaceEnd(source, raw_start, admission_end);
        if (raw_start == raw_end) {
            if (kind == .nominal) return .{ .excluded = .{
                .reason = .nominal_base_not_scalar,
                .raw_span = .{ .start = raw_start, .end = raw_end },
                .admission_end = admission_end,
            } };
        }
        if (kind == .nominal and !isScalarNominalBase(source[raw_start..raw_end])) {
            return .{ .excluded = .{
                .reason = .nominal_base_not_scalar,
                .raw_span = .{ .start = raw_start, .end = raw_end },
                .admission_end = admission_end,
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
    try store.validateDeclaration(declaration);
    try store.declarations.append(store.allocator, declaration);
    cursor.* = scanned;
    published = true;
    return .{ .parsed = declaration.full_span };
}

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

fn tokenIsDeclarationName(token: Token, source: []const u8) bool {
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

fn isTypeWhitespace(byte: u8) bool {
    return byte == ' ' or byte == '\t' or byte == '\r' or byte == '\n';
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
                            .{ .group = .absent },
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
                    .{ .group = parsed.child },
                );
                var result = grouped;
                result.semantic_present = parsed.semantic_present;
                self.complete(result);
            },
        }
    }

    fn backtrackGroup(self: *SyntaxParser) !void {
        const frame = &self.frames.items[self.frames.items.len - 1].paren;
        self.store.rollback(frame.attempt);
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
            var first = try store.reserveExplicitCall(.{
                .lparen_offset = first_lparen,
                .list_span = .{ .start = first_start, .end = first_lparen },
                .projected_span = .{ .start = first_start + 1, .end = first_lparen - 1 },
            });
            try store.finishExplicitCall(&first);
            try std.testing.expect(!first.active);
            try store.validate();
            var first_bases = try store.planApplicationBases(std.testing.allocator);
            first_bases.deinit();
            const prior = store.checkpoint();
            try std.testing.expect(prior.nodes > 0);
            try std.testing.expect(prior.members > 0);
            try std.testing.expectEqual(@as(usize, 1), prior.authored_call_arguments);
            try std.testing.expectEqual(@as(usize, 1), prior.semantic_fragments);
            try std.testing.expectEqual(@as(usize, 1), prior.explicit_call_arguments);

            var second = store.reserveExplicitCall(.{
                .lparen_offset = second_lparen,
                .list_span = .{ .start = second_start, .end = second_lparen },
                .projected_span = .{ .start = second_start + 1, .end = second_lparen - 1 },
            }) catch |err| switch (err) {
                error.OutOfMemory => {
                    observed_later_failures.* += 1;
                    try std.testing.expect(std.meta.eql(prior, store.checkpoint()));
                    try store.validate();
                    var retained_bases = try store.planApplicationBases(std.testing.allocator);
                    retained_bases.deinit();
                    return error.OutOfMemory;
                },
                else => return err,
            };
            try store.finishExplicitCall(&second);
            try store.validate();
            var completed_bases = try store.planApplicationBases(std.testing.allocator);
            completed_bases.deinit();
            const completed = store.checkpoint();
            try std.testing.expect(completed.nodes > prior.nodes);
            try std.testing.expect(completed.members > prior.members);
            try std.testing.expect(completed.fields > prior.fields);
            try std.testing.expectEqual(prior.authored_call_arguments + 2, completed.authored_call_arguments);
            try std.testing.expectEqual(prior.semantic_fragments + 2, completed.semantic_fragments);
            try std.testing.expectEqual(prior.explicit_call_arguments + 1, completed.explicit_call_arguments);

            var canceled = try store.reserveExplicitCall(.{
                .lparen_offset = second_lparen,
                .list_span = .{ .start = second_start, .end = second_lparen },
                .projected_span = .{ .start = second_start + 1, .end = second_lparen - 1 },
            });
            store.cancelExplicitCall(&canceled);
            try std.testing.expect(!canceled.active);
            try std.testing.expect(std.meta.eql(completed, store.checkpoint()));
            try std.testing.expectError(error.InvalidGenericOwner, store.finishExplicitCall(&canceled));
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
    var pending = try store.reserveExplicitCall(.{
        .lparen_offset = lparen,
        .list_span = .{ .start = list_start, .end = lparen },
        .projected_span = .{ .start = list_start + 1, .end = lparen - 1 },
    });
    try store.finishExplicitCall(&pending);
    try store.validate();
    try std.testing.expectEqual(
        @as(u32, 8),
        store.explicit_call_arguments.items[0].projected_fragments.count,
    );

    try store.semantic_fragments.append(
        std.testing.allocator,
        store.semantic_fragments.items[7],
    );
    store.explicit_call_arguments.items[0].projected_fragments.count = 9;
    try std.testing.expectError(error.InvalidTypeRange, store.validate());
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
                store.nodes.items[root].data.group = .{ .present = 0 };
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
    const fragment_index = try parseSemanticFragmentAndStore(&store, .{ .start = 1, .end = 7 });

    try std.testing.expectError(
        error.UnownedSemanticFragment,
        store.planApplicationBases(std.testing.allocator),
    );

    try store.explicit_call_arguments.append(std.testing.allocator, .{
        .lparen_offset = 8,
        .list_span = .{ .start = 0, .end = 8 },
        .authored_arguments = .{ .start = 0, .count = 0 },
        .projected_fragments = .{ .start = fragment_index, .count = 1 },
    });
    var valid = try store.planApplicationBases(std.testing.allocator);
    valid.deinit();

    store.explicit_call_arguments.items.len = 0;
    for (0..2) |_| try store.projected_generic_parameters.append(std.testing.allocator, .{
        .raw_span = .{ .start = 1, .end = 7 },
        .name_span = .{ .start = 1, .end = 1 },
        .legacy_bound_span = .{ .start = 1, .end = 7 },
        .bound_fragment = fragment_index,
    });
    try store.generic_owners.append(std.testing.allocator, .{
        .identity = .{ .function_declaration_paren = 8 },
        .list_span = .{ .start = 0, .end = 8 },
        .authored_parameters = .{ .start = 0, .count = 0 },
        .projected_parameters = .{ .start = 0, .count = 1 },
    });
    try store.generic_owners.append(std.testing.allocator, .{
        .identity = .{ .function_declaration_paren = 9 },
        .list_span = .{ .start = 0, .end = 8 },
        .authored_parameters = .{ .start = 0, .count = 0 },
        .projected_parameters = .{ .start = 1, .count = 1 },
    });
    try std.testing.expectError(
        error.SharedSemanticFragment,
        store.planApplicationBases(std.testing.allocator),
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
                .data = .{ .group = .absent },
            },
            .range => .{
                .tag = .record,
                .semantic_span = .{ .start = 0, .end = 6 },
                .data = .{ .record = .{ .start = 1, .count = 1 } },
            },
            .child => .{
                .tag = .group,
                .semantic_span = .{ .start = 0, .end = 6 },
                .data = .{ .group = .{ .present = index } },
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
