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

const type_syntax_store_mod = @import("type_syntax_store.zig");
const type_syntax_scan_mod = @import("type_syntax_scan.zig");
const type_syntax_parser_mod = @import("type_syntax_parser.zig");
const type_syntax_support_mod = @import("type_syntax_support.zig");
pub const Span = type_syntax_store_mod.Span;
pub const AdmissionMode = type_syntax_store_mod.AdmissionMode;
pub const AdmissionKind = type_syntax_store_mod.AdmissionKind;
pub const AdmissionPosition = type_syntax_store_mod.AdmissionPosition;
pub const AdmissionPresentation = type_syntax_store_mod.AdmissionPresentation;
pub const AdmissionDiagnostic = type_syntax_store_mod.AdmissionDiagnostic;
pub const AdmissionObservationHistory = type_syntax_store_mod.AdmissionObservationHistory;
pub const AdmissionCollector = type_syntax_store_mod.AdmissionCollector;
pub const AdmissionSink = type_syntax_store_mod.AdmissionSink;
pub const AdmissionTypePolicy = type_syntax_store_mod.AdmissionTypePolicy;
pub const AdmissionTypeSpanOptions = type_syntax_store_mod.AdmissionTypeSpanOptions;
pub const NamedFunctionGap = type_syntax_store_mod.NamedFunctionGap;
pub const classifyNamedFunctionGap = type_syntax_store_mod.classifyNamedFunctionGap;
pub const hasDedicatedAssignmentArrowWindow = type_syntax_store_mod.hasDedicatedAssignmentArrowWindow;
pub const rawLooksLikeComparison = type_syntax_store_mod.rawLooksLikeComparison;
pub const tokenStartsGenericList = type_syntax_store_mod.tokenStartsGenericList;
pub const Primitive = type_syntax_store_mod.Primitive;
pub const NodeIndex = type_syntax_store_mod.NodeIndex;
pub const Child = type_syntax_store_mod.Child;
pub const Range = type_syntax_store_mod.Range;
pub const NodeTag = type_syntax_store_mod.NodeTag;
pub const Node = type_syntax_store_mod.Node;
pub const Field = type_syntax_store_mod.Field;
pub const Parameter = type_syntax_store_mod.Parameter;
pub const TemplatePart = type_syntax_store_mod.TemplatePart;
pub const Annotation = type_syntax_store_mod.Annotation;
pub const AnnotationRuntimeOwner = type_syntax_store_mod.AnnotationRuntimeOwner;
pub const TypeValue = type_syntax_store_mod.TypeValue;
pub const ParameterOwner = type_syntax_store_mod.ParameterOwner;
pub const ParameterAnnotation = type_syntax_store_mod.ParameterAnnotation;
pub const LegacyReturnKind = type_syntax_store_mod.LegacyReturnKind;
pub const PredicateTarget = type_syntax_store_mod.PredicateTarget;
pub const PredicateSyntax = type_syntax_store_mod.PredicateSyntax;
pub const ReturnStructure = type_syntax_store_mod.ReturnStructure;
pub const ReturnSyntax = type_syntax_store_mod.ReturnSyntax;
pub const FunctionSignature = type_syntax_store_mod.FunctionSignature;
pub const PendingFunctionSignature = type_syntax_store_mod.PendingFunctionSignature;
pub const TypeOnlyModuleKind = type_syntax_store_mod.TypeOnlyModuleKind;
pub const TypeOnlyModule = type_syntax_store_mod.TypeOnlyModule;
pub const TypeOnlyModuleRefusalReason = type_syntax_store_mod.TypeOnlyModuleRefusalReason;
pub const TypeOnlyModuleRefusal = type_syntax_store_mod.TypeOnlyModuleRefusal;
pub const TypeOnlyModuleDiagnosticKind = type_syntax_store_mod.TypeOnlyModuleDiagnosticKind;
pub const TypeOnlyModuleDiagnostic = type_syntax_store_mod.TypeOnlyModuleDiagnostic;
pub const TypeOnlyModuleScanOptions = type_syntax_store_mod.TypeOnlyModuleScanOptions;
pub const TypeOnlyModuleScan = type_syntax_store_mod.TypeOnlyModuleScan;
pub const GenericCaptureSpans = type_syntax_store_mod.GenericCaptureSpans;
pub const ErasedTypePrefixOwner = type_syntax_store_mod.ErasedTypePrefixOwner;
pub const ErasedTypePrefixCompatibility = type_syntax_store_mod.ErasedTypePrefixCompatibility;
pub const ErasedTypePrefix = type_syntax_store_mod.ErasedTypePrefix;
pub const ErasedTypePrefixPolicy = type_syntax_store_mod.ErasedTypePrefixPolicy;
pub const ErasedTypePrefixOptions = type_syntax_store_mod.ErasedTypePrefixOptions;
pub const ErasedTypePrefixFinal = type_syntax_store_mod.ErasedTypePrefixFinal;
pub const PendingErasedTypePrefix = type_syntax_store_mod.PendingErasedTypePrefix;
pub const DeclarationKind = type_syntax_store_mod.DeclarationKind;
pub const DeclarationBody = type_syntax_store_mod.DeclarationBody;
pub const RecognizedGenericParameter = type_syntax_store_mod.RecognizedGenericParameter;
pub const AuthoredGenericParameter = type_syntax_store_mod.AuthoredGenericParameter;
pub const ProjectedGenericParameter = type_syntax_store_mod.ProjectedGenericParameter;
pub const SemanticFragment = type_syntax_store_mod.SemanticFragment;
pub const GenericOwnerIdentity = type_syntax_store_mod.GenericOwnerIdentity;
pub const GenericOwnerCompatibility = type_syntax_store_mod.GenericOwnerCompatibility;
pub const GenericOwner = type_syntax_store_mod.GenericOwner;
pub const GenericOwnerPolicy = type_syntax_store_mod.GenericOwnerPolicy;
pub const GenericOwnerOptions = type_syntax_store_mod.GenericOwnerOptions;
pub const GenericOwnerFinal = type_syntax_store_mod.GenericOwnerFinal;
pub const PendingGenericOwner = type_syntax_store_mod.PendingGenericOwner;
pub const AuthoredCallArgument = type_syntax_store_mod.AuthoredCallArgument;
pub const ExplicitCallArguments = type_syntax_store_mod.ExplicitCallArguments;
pub const ExplicitCallOptions = type_syntax_store_mod.ExplicitCallOptions;
pub const PendingExplicitCall = type_syntax_store_mod.PendingExplicitCall;
pub const Declaration = type_syntax_store_mod.Declaration;
pub const Store = type_syntax_store_mod.Store;
pub const scanTypeOnlyModule = type_syntax_scan_mod.scanTypeOnlyModule;
pub const Cursor = type_syntax_scan_mod.Cursor;
pub const scanParenthesizedArrowHeader = type_syntax_scan_mod.scanParenthesizedArrowHeader;
pub const Failure = type_syntax_parser_mod.Failure;
pub const ParsedType = type_syntax_parser_mod.ParsedType;
pub const TypeParseOutcome = type_syntax_parser_mod.TypeParseOutcome;
pub const TypeValueOutcome = type_syntax_parser_mod.TypeValueOutcome;
pub const AdmittedTypeInput = type_syntax_parser_mod.AdmittedTypeInput;
pub const AdmittedTypeValueOutcome = type_syntax_parser_mod.AdmittedTypeValueOutcome;
pub const ReturnSyntaxOutcome = type_syntax_parser_mod.ReturnSyntaxOutcome;
pub const Exclusion = type_syntax_parser_mod.Exclusion;
pub const ExcludedType = type_syntax_parser_mod.ExcludedType;
pub const max_type_depth = type_syntax_parser_mod.max_type_depth;
pub const max_parser_frames = type_syntax_parser_mod.max_parser_frames;
pub const max_template_levels = type_syntax_parser_mod.max_template_levels;
pub const parseTypeValueAndStore = type_syntax_parser_mod.parseTypeValueAndStore;
pub const parseAdmittedTypeValue = type_syntax_parser_mod.parseAdmittedTypeValue;
pub const parseAdmittedTypeValueOutcome = type_syntax_parser_mod.parseAdmittedTypeValueOutcome;
pub const parseFunctionReturnAndStore = type_syntax_parser_mod.parseFunctionReturnAndStore;
pub const parseAdmittedFunctionReturnAndStore = type_syntax_parser_mod.parseAdmittedFunctionReturnAndStore;
pub const parseAndStore = type_syntax_parser_mod.parseAndStore;
pub const parseAdmittedAnnotationAndStore = type_syntax_parser_mod.parseAdmittedAnnotationAndStore;
pub const parseSemanticFragmentAndStore = type_syntax_parser_mod.parseSemanticFragmentAndStore;
pub const DeclarationParseOutcome = type_syntax_parser_mod.DeclarationParseOutcome;
pub const AdmittedDeclarationOptions = type_syntax_parser_mod.AdmittedDeclarationOptions;
pub const GenericListScan = type_syntax_scan_mod.GenericListScan;
pub const AdmissionGenericScan = type_syntax_scan_mod.AdmissionGenericScan;
pub const AdmissionRawScanOptions = type_syntax_scan_mod.AdmissionRawScanOptions;
pub const AdmissionQuotedScan = type_syntax_scan_mod.AdmissionQuotedScan;
pub const AdmissionBraceScan = type_syntax_scan_mod.AdmissionBraceScan;
pub const ExplicitCallScan = type_syntax_scan_mod.ExplicitCallScan;
pub const AdmissionHeaderProbe = type_syntax_scan_mod.AdmissionHeaderProbe;
pub const scanAdmissionHeaderProbe = type_syntax_scan_mod.scanAdmissionHeaderProbe;
pub const scanAdmissionQuotedRegion = type_syntax_scan_mod.scanAdmissionQuotedRegion;
pub const scanAdmissionGenericList = type_syntax_scan_mod.scanAdmissionGenericList;
pub const scanBalancedGenericList = type_syntax_scan_mod.scanBalancedGenericList;
pub const isPrivateGenericListEligible = type_syntax_scan_mod.isPrivateGenericListEligible;
pub const scanAdmissionCallTypeArguments = type_syntax_scan_mod.scanAdmissionCallTypeArguments;
pub const scanExplicitCallTypeArguments = type_syntax_scan_mod.scanExplicitCallTypeArguments;
pub const scanAdmissionBraceBody = type_syntax_scan_mod.scanAdmissionBraceBody;
const trimSpan = type_syntax_parser_mod.trimSpan;
pub const parseDeclarationAndStore = type_syntax_parser_mod.parseDeclarationAndStore;
pub const parseAdmittedDeclarationAndStore = type_syntax_parser_mod.parseAdmittedDeclarationAndStore;
pub const GeneralAdmissionEndpoint = type_syntax_scan_mod.GeneralAdmissionEndpoint;
pub const AdmissionEndpointPolicy = type_syntax_scan_mod.AdmissionEndpointPolicy;
pub const AdmissionCommentFailure = type_syntax_scan_mod.AdmissionCommentFailure;
pub const AdmissionEndpointResult = type_syntax_scan_mod.AdmissionEndpointResult;
pub const AdmissionTemplateScan = type_syntax_scan_mod.AdmissionTemplateScan;
pub const scanAdmissionTemplate = type_syntax_scan_mod.scanAdmissionTemplate;
pub const AdmissionEndpointProgress = type_syntax_scan_mod.AdmissionEndpointProgress;
pub const scanAdmissionEndpointWithPresentation = type_syntax_scan_mod.scanAdmissionEndpointWithPresentation;
const scanAdmissionEndpointCore = type_syntax_scan_mod.scanAdmissionEndpointCore;
const skipTypeWhitespace = type_syntax_scan_mod.skipTypeWhitespace;
const advanceCursorTo = type_syntax_scan_mod.advanceCursorTo;
pub const tokenIsDeclarationName = type_syntax_scan_mod.tokenIsDeclarationName;
pub const classifyTypeSpan = type_syntax_scan_mod.classifyTypeSpan;
pub const classifyTypeSpanPrefix = type_syntax_scan_mod.classifyTypeSpanPrefix;
pub const isScalarNominalBase = type_syntax_scan_mod.isScalarNominalBase;
const validateAfterAllocationFailure = type_syntax_support_mod.validateAfterAllocationFailure;
const seedNumberAnnotation = type_syntax_support_mod.seedNumberAnnotation;

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
                try validateAfterAllocationFailure(&store);
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
                try validateAfterAllocationFailure(&store);
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
    var no_resize = std.testing.FailingAllocator.init(std.testing.allocator, .{ .resize_fail_index = 0 });
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
    try std.testing.checkAllAllocationFailures(no_resize.allocator(), Context.run, .{&observed_failures});
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

test "admission interface brace scanner preserves raw boundaries" {
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
    try std.testing.expect(std.meta.eql(owner.list_span, owner.capture_spans.recorded_span));
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
        try std.testing.expect(std.meta.eql(owner.list_span, owner.capture_spans.recorded_span));
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
            const admitted_span = switch (try scanAdmissionEndpointCore(
                std.testing.allocator,
                source,
                body_start,
                .declaration,
                &caught,
                null,
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
        var no_resize = std.testing.FailingAllocator.init(std.testing.allocator, .{ .resize_fail_index = 0 });
        var failures: usize = 0;
        try std.testing.checkAllAllocationFailures(
            no_resize.allocator(),
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
    try seedNumberAnnotation(&store);
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

comptime {
    _ = @import("type_syntax_store.zig");
    _ = @import("type_syntax_scan.zig");
    _ = @import("type_syntax_parser.zig");
}
