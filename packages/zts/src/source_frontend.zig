//! One source-preparation boundary for every parser consumer.
//!
//! This module owns extension classification, direct typed parsing, and the
//! original-source position view.

const std = @import("std");
const atom_table = @import("atom_table.zig");
const parser = @import("parser/root.zig");
const source_diagnostics = @import("zts-base").source_diagnostics;

pub const SourceKind = enum {
    typescript,
    virtual_javascript,
    unsupported,

    pub fn isTyped(self: SourceKind) bool {
        return self == .typescript;
    }

    pub fn isSupportedFile(self: SourceKind) bool {
        return self == .typescript;
    }
};

pub fn classifyPath(path: []const u8) SourceKind {
    if (std.mem.endsWith(u8, path, ".ts")) return .typescript;
    if (path.len >= 2 and path[0] == '<' and path[path.len - 1] == '>') return .virtual_javascript;
    return .unsupported;
}

pub const PrepareError = source_diagnostics.StripError || error{UnsupportedSourceExtension};

pub fn prepareErrorForAdmissionFailure(failure: parser.AdmissionFailure) PrepareError {
    return switch (failure) {
        .unterminated_comment => error.UnterminatedComment,
        .diagnostic => |diagnostic| switch (diagnostic.kind) {
            .any_type => error.UnsupportedAnyType,
            .as_assertion => error.UnsupportedAsAssertion,
            .satisfies_assertion => error.UnsupportedSatisfiesAssertion,
            .unterminated_string => error.UnterminatedString,
            .nominal_base_not_scalar => error.NominalBaseNotScalar,
            .interface_declaration => error.InterfaceDeclaration,
            .type_alias_declaration => error.TypeAliasDeclaration,
            .distinct_type_declaration => error.DistinctTypeDeclaration,
            .retired_types_import => error.LegacyTypesImport,
            .default_parameter => error.DefaultParameter,
            .optional_parameter => error.OptionalParameter,
            .default_export => error.DefaultExport,
            .mutable_export => error.MutableExport,
            .array_type_alias => error.ArrayTypeAlias,
            .readonly_array_type_alias => error.ReadonlyArrayTypeAlias,
            .void_type => error.VoidType,
            .nesting_too_deep => error.NestingTooDeep,
        },
    };
}

pub const SourceObservationError = error{ OutOfMemory, InvalidSourceObservation };

/// Observe complete source admission without creating a runtime tree or atom table.
/// The returned failure contains value data and outlives the temporary observer.
pub fn checkSourceAdmission(
    allocator: std.mem.Allocator,
    source: []const u8,
) SourceObservationError!?parser.AdmissionFailure {
    var observer = try parser.JsParser.initSourceObserver(allocator, allocator, source, .compile);
    defer observer.deinit();
    observer.observeSourceProgram() catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.AdmissionRefused, error.UnterminatedComment, error.TypeOnlyModuleRefused => {
            return observer.getAdmissionFailure() orelse error.InvalidSourceObservation;
        },
        else => return error.InvalidSourceObservation,
    };
    return observer.getAdmissionFailure();
}

pub fn sourceDiagnosticFromAdmission(
    source: []const u8,
    diag: parser.type_syntax.AdmissionDiagnostic,
) source_diagnostics.StripDiagnostic {
    const kind: source_diagnostics.StripDiagnosticKind = switch (diag.kind) {
        .any_type => .any_type,
        .as_assertion => .as_assertion,
        .satisfies_assertion => .satisfies_assertion,
        .unterminated_string => .unterminated_string,
        .nominal_base_not_scalar => .nominal_base_not_scalar,
        .interface_declaration => .interface_declaration,
        .type_alias_declaration => .type_alias_declaration,
        .distinct_type_declaration => .distinct_type_declaration,
        .retired_types_import => .retired_types_import,
        .default_parameter => .default_parameter,
        .optional_parameter => .optional_parameter,
        .default_export => .default_export,
        .mutable_export => .mutable_export,
        .array_type_alias => .array_type_alias,
        .readonly_array_type_alias => .readonly_array_type_alias,
        .void_type => .void_type,
        .nesting_too_deep => .nesting_too_deep,
    };
    const position = diag.positionIn(source);
    return .{
        .kind = kind,
        .line = position.line,
        .column = position.column,
    };
}

/// Log an admission failure at callers that enable source-preparation reports.
pub fn logAdmissionFailure(source: []const u8, failure: parser.AdmissionFailure) void {
    if (@import("builtin").is_test) return;
    switch (failure) {
        .unterminated_comment => {},
        .diagnostic => |diagnostic| switch (diagnostic.kind) {
            .unterminated_string => {},
            else => {
                const mapped = sourceDiagnosticFromAdmission(source, diagnostic);
                std.log.err("{}:{}: {s}", .{ mapped.line, mapped.column, mapped.kind.message() });
            },
        },
    }
}

/// One refusal line for a source named by `name`: the position and message when
/// the refusal has a position, otherwise the strip error name.
pub fn formatAdmissionRefusal(
    allocator: std.mem.Allocator,
    source: []const u8,
    name: []const u8,
    failure: parser.AdmissionFailure,
) std.mem.Allocator.Error![]u8 {
    return switch (failure) {
        .unterminated_comment => std.fmt.allocPrint(allocator, "TypeScript strip error in {s}: {}", .{ name, prepareErrorForAdmissionFailure(failure) }),
        .diagnostic => |diagnostic| blk: {
            const mapped = sourceDiagnosticFromAdmission(source, diagnostic);
            break :blk std.fmt.allocPrint(allocator, "{s}:{d}:{d}: {s}", .{ name, mapped.line, mapped.column, mapped.kind.message() });
        },
    };
}

pub const DirectCheckOutcome = parser.AdmissionParseOutcome;

pub const AcceptedDirectCapabilities = struct {
    ir_view: parser.IrView,
    root: parser.NodeIndex,
    atoms: *atom_table.AtomTable,
    type_store: *const parser.type_syntax.Store,
};

/// Owns one direct TypeScript parse and its atom table.
/// Initialize the owner in final storage. The parser borrows `atoms`, so an
/// initialized owner cannot move. The source and path remain borrowed and must
/// outlive the owner. A failed initializer cleans all state, so the caller must
/// not call an accessor or `deinit`. Returned capabilities borrow this owner.
pub const DirectCheckSource = struct {
    source: []const u8,
    path: []const u8,
    atoms: atom_table.AtomTable,
    parser: parser.JsParser,
    parse_outcome: DirectCheckOutcome,

    pub fn initInPlace(
        self: *DirectCheckSource,
        allocator: std.mem.Allocator,
        type_allocator: std.mem.Allocator,
        source: []const u8,
        path: []const u8,
    ) anyerror!void {
        try self.initWithModeInPlace(
            allocator,
            type_allocator,
            source,
            path,
            .typescript,
            .collect,
        );
    }

    pub fn initCompileInPlace(
        self: *DirectCheckSource,
        allocator: std.mem.Allocator,
        type_allocator: std.mem.Allocator,
        source: []const u8,
        path: []const u8,
    ) anyerror!void {
        try self.initWithModeInPlace(
            allocator,
            type_allocator,
            source,
            path,
            .typescript,
            .compile,
        );
    }

    /// Initialize prepared evaluation source. Only a virtual path such as `<eval>` is accepted.
    pub fn initPreparedEvalInPlace(
        self: *DirectCheckSource,
        allocator: std.mem.Allocator,
        type_allocator: std.mem.Allocator,
        source: []const u8,
        path: []const u8,
    ) anyerror!void {
        try self.initWithModeInPlace(
            allocator,
            type_allocator,
            source,
            path,
            .virtual_javascript,
            .compile,
        );
    }

    fn initWithModeInPlace(
        self: *DirectCheckSource,
        allocator: std.mem.Allocator,
        type_allocator: std.mem.Allocator,
        source: []const u8,
        path: []const u8,
        accepted_kind: SourceKind,
        mode: parser.type_syntax.AdmissionMode,
    ) anyerror!void {
        if (classifyPath(path) != accepted_kind) return error.UnsupportedSourceExtension;

        self.source = source;
        self.path = path;
        self.atoms = atom_table.AtomTable.init(allocator);
        errdefer self.atoms.deinit();

        self.parser = try parser.JsParser.initAdmission(
            allocator,
            type_allocator,
            source,
            mode,
        );
        errdefer self.parser.deinit();
        // DirectCheckSource already retains this immutable source until its
        // parser is destroyed; no parsed storage escapes this owner's lifetime.
        self.parser.borrowSourceStrings();
        self.parser.setAtomTable(&self.atoms);

        const parse_outcome = try self.parser.parseAdmission();
        switch (parse_outcome) {
            .accepted => |root| {
                const view = parser.IrView.fromIRStore(
                    &self.parser.nodes,
                    &self.parser.constants,
                );
                if (view.getTag(root) != .program) return error.InvalidDirectSourceRoot;
                try self.parser.type_store.validateRuntimeOwners(type_allocator, view);
            },
            .recovered_admission_refused,
            .parser_refused,
            .terminal_admission_refused,
            => {},
        }
        self.parse_outcome = parse_outcome;
    }

    pub fn deinit(self: *DirectCheckSource) void {
        self.parser.deinit();
        self.atoms.deinit();
        self.* = undefined;
    }

    pub fn sourceView(self: *const DirectCheckSource) source_diagnostics.SourceView {
        var view = source_diagnostics.SourceView.of(self.source);
        view.name = self.path;
        return view;
    }

    pub fn outcome(self: *const DirectCheckSource) *const DirectCheckOutcome {
        return &self.parse_outcome;
    }

    pub fn acceptedCapabilities(self: *DirectCheckSource) ?AcceptedDirectCapabilities {
        const root = switch (self.parse_outcome) {
            .accepted => |root| root,
            else => return null,
        };
        return .{
            .ir_view = parser.IrView.fromIRStore(
                &self.parser.nodes,
                &self.parser.constants,
            ),
            .root = root,
            .atoms = &self.atoms,
            .type_store = &self.parser.type_store,
        };
    }

    pub fn selectedAdmissionDiagnostics(
        self: *const DirectCheckSource,
    ) []const parser.type_syntax.AdmissionDiagnostic {
        return switch (self.parse_outcome) {
            .recovered_admission_refused => self.parser.getAdmissionDiagnostics(),
            else => &.{},
        };
    }

    pub fn terminalAdmissionDiagnostic(
        self: *const DirectCheckSource,
    ) ?parser.type_syntax.AdmissionDiagnostic {
        return switch (self.parse_outcome) {
            .terminal_admission_refused => self.parser.getLastAdmissionObservation(),
            else => null,
        };
    }

    pub fn parserErrors(self: *const DirectCheckSource) []const parser.ParseError {
        return switch (self.parse_outcome) {
            .parser_refused => self.parser.getProjectedErrors(),
            else => &.{},
        };
    }
};

test "classifyPath supports TypeScript and refuses legacy source extensions" {
    try std.testing.expectEqual(SourceKind.typescript, classifyPath("handler.ts"));
    try std.testing.expectEqual(SourceKind.typescript, classifyPath("types.d.ts"));
    try std.testing.expectEqual(SourceKind.unsupported, classifyPath("view.tsx"));
    try std.testing.expectEqual(SourceKind.unsupported, classifyPath("handler.js"));
    try std.testing.expectEqual(SourceKind.unsupported, classifyPath("view.jsx"));
    try std.testing.expectEqual(SourceKind.virtual_javascript, classifyPath("<eval>"));
    try std.testing.expectEqual(SourceKind.unsupported, classifyPath("handler.mts"));
}

test "direct source refuses unsupported file extensions" {
    const cases = [_][]const u8{ "handler.js", "handler.jsx", "handler.tsx", "handler.txt" };
    for (cases) |path| {
        var owner: DirectCheckSource = undefined;
        try std.testing.expectError(
            error.UnsupportedSourceExtension,
            owner.initCompileInPlace(std.testing.allocator, std.testing.allocator, "const value = 1;", path),
        );
    }
}

test "direct source owns authored TypeScript and classifies virtual JavaScript" {
    const allocator = std.testing.allocator;
    const source = "const name: string = \"Ada\";";
    var typed: DirectCheckSource = undefined;
    try typed.initCompileInPlace(allocator, allocator, source, "handler.ts");
    defer typed.deinit();
    try std.testing.expect(typed.acceptedCapabilities() != null);
    try std.testing.expectEqual(@as(usize, 1), typed.parser.type_store.annotations.items.len);
    try std.testing.expectEqualStrings(source, typed.sourceView().text);
    try std.testing.expectEqual(SourceKind.virtual_javascript, classifyPath("<eval>"));
}

test "direct source closes every initialization allocation failure" {
    const Context = struct {
        fn run(allocator: std.mem.Allocator) !void {
            var owner: DirectCheckSource = undefined;
            try owner.initCompileInPlace(
                allocator,
                allocator,
                "const name: string = \"Ada\";",
                "handler.ts",
            );
            defer owner.deinit();
            if (owner.acceptedCapabilities() == null) return error.TestUnexpectedResult;
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Context.run, .{});
}

test "direct source retains every syntax owner family" {
    const source =
        "import type { Shape } from \"./types\";\n" ++
        "structural Box<T> = { value: T };\n" ++
        "nominal UserId = string;\n" ++
        "function keep<T>(value: T): Box<T> { return { value: value }; }\n" ++
        "function isText(value: unknown): value is string { return typeof value === \"string\"; }\n" ++
        "const boxed: Box<string> = keep<Box<string>>({ value: \"x\" });\n" ++
        "const prefixed = <P>(1);\n";
    var owner: DirectCheckSource = undefined;
    try owner.initCompileInPlace(std.testing.allocator, std.testing.allocator, source, "types.ts");
    defer owner.deinit();
    const accepted = owner.acceptedCapabilities() orelse return error.TestUnexpectedResult;
    const store = accepted.type_store;

    const Family = enum {
        variable,
        declaration,
        parameter,
        signature,
        generic,
        explicit_call,
        type_only_module,
        erased_prefix,
    };
    var seen = std.EnumSet(Family).empty;
    if (store.annotations.items.len > 0) seen.insert(.variable);
    if (store.declarations.items.len > 0) seen.insert(.declaration);
    if (store.parameter_annotations.items.len > 0) seen.insert(.parameter);
    if (store.function_signatures.items.len > 0) seen.insert(.signature);
    if (store.generic_owners.items.len > 0) seen.insert(.generic);
    if (store.explicit_call_arguments.items.len > 0) seen.insert(.explicit_call);
    if (store.type_only_modules.items.len > 0) seen.insert(.type_only_module);
    if (store.erased_type_prefixes.items.len > 0) seen.insert(.erased_prefix);
    inline for (std.meta.tags(Family)) |family| try std.testing.expect(seen.contains(family));

    try std.testing.expectEqual(@as(usize, 2), store.declarations.items.len);
    try std.testing.expectEqual(parser.type_syntax.DeclarationKind.structural, store.declarations.items[0].kind);
    try std.testing.expectEqual(parser.type_syntax.DeclarationKind.nominal, store.declarations.items[1].kind);
    try std.testing.expectEqualStrings("Box", store.declarations.items[0].name_span.text(source));
    try std.testing.expectEqualStrings("UserId", store.declarations.items[1].name_span.text(source));
    try std.testing.expectEqualStrings("{ value: T }", store.declarations.items[0].body.present.raw_span.text(source));
    try std.testing.expectEqualStrings("string", store.declarations.items[1].body.present.raw_span.text(source));
    try std.testing.expectEqual(@as(usize, 1), store.annotations.items.len);
    try std.testing.expectEqualStrings("Box<string>", store.annotations.items[0].raw_span.text(source));
    try std.testing.expectEqual(@as(usize, 2), store.parameter_annotations.items.len);
    try std.testing.expectEqualStrings("T", store.parameter_annotations.items[0].value.raw_span.text(source));
    try std.testing.expectEqualStrings("unknown", store.parameter_annotations.items[1].value.raw_span.text(source));
    try std.testing.expectEqual(@as(usize, 2), store.function_signatures.items.len);
    try std.testing.expectEqual(@as(usize, 2), store.generic_owners.items.len);
    try std.testing.expectEqual(@as(usize, 1), store.explicit_call_arguments.items.len);
    try std.testing.expectEqualStrings("<T>", store.generic_owners.items[0].list_span.text(source));
    try std.testing.expectEqualStrings("<Box<string>>", store.explicit_call_arguments.items[0].list_span.text(source));
    try std.testing.expectEqualStrings("import type { Shape } from \"./types\";", store.type_only_modules.items[0].raw_span.text(source));
    try std.testing.expectEqualStrings("<P>", store.erased_type_prefixes.items[0].list_span.text(source));
    var saw_predicate = false;
    for (store.function_signatures.items) |signature| {
        const returned = signature.return_syntax orelse continue;
        if (std.meta.activeTag(returned.structure) == .predicate) {
            saw_predicate = true;
            try std.testing.expectEqualStrings("value is string ", returned.raw_span.text(source));
        }
    }
    try std.testing.expect(saw_predicate);
    try std.testing.expectEqualStrings(source, owner.sourceView().text);
    try std.testing.expectEqualStrings("types.ts", owner.sourceView().name.?);
}

test "direct source retains tolerated annotation suffix" {
    const source = "const tolerant: string ignored_suffix = \"kept\";";
    var owner: DirectCheckSource = undefined;
    try owner.initCompileInPlace(std.testing.allocator, std.testing.allocator, source, "tolerant.ts");
    defer owner.deinit();
    const accepted = owner.acceptedCapabilities() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 1), accepted.type_store.annotations.items.len);
    try std.testing.expectEqualStrings(
        "string ignored_suffix",
        accepted.type_store.annotations.items[0].raw_span.text(source),
    );
}

test "DirectCheckSource publishes one validated capability set" {
    const source =
        "import type { Shape } from \"./types\";\n" ++
        "function directOwnerFixture(value: number): number { return value; }\n";
    var owner: DirectCheckSource = undefined;
    try owner.initInPlace(
        std.testing.allocator,
        std.testing.allocator,
        source,
        "handler.ts",
    );
    defer owner.deinit();

    const capabilities = owner.acceptedCapabilities() orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqual(parser.NodeTag.program, capabilities.ir_view.getTag(capabilities.root).?);
    try std.testing.expect(capabilities.atoms == &owner.atoms);
    try std.testing.expect(capabilities.type_store == &owner.parser.type_store);

    const view = owner.sourceView();
    try std.testing.expectEqualStrings(source, view.text);
    try std.testing.expectEqualStrings("handler.ts", view.name.?);
    try std.testing.expect(!view.normalize_positions);

    const store = capabilities.type_store;
    try std.testing.expectEqual(@as(usize, 1), store.type_only_modules.items.len);
    try std.testing.expectEqualStrings(
        "import type { Shape } from \"./types\";",
        store.type_only_modules.items[0].raw_span.text(source),
    );
    try std.testing.expectEqual(@as(usize, 1), store.function_signatures.items.len);
    try std.testing.expectEqual(@as(usize, 1), store.parameter_annotations.items.len);

    const signature = store.function_signatures.items[0];
    try std.testing.expectEqual(parser.NodeTag.function_expr, capabilities.ir_view.getTag(signature.owner).?);
    const function = capabilities.ir_view.getFunction(signature.owner) orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings(
        "directOwnerFixture",
        capabilities.atoms.getName(@fromBackingInt(@intCast(function.name_atom))).?,
    );

    var wrapper: ?parser.NodeIndex = null;
    for (0..capabilities.ir_view.nodeCount()) |index| {
        const node: parser.NodeIndex = @intCast(index);
        if (capabilities.ir_view.getTag(node) == .function_decl) {
            wrapper = node;
            break;
        }
    }
    try store.validateFunctionDeclarationWrapper(
        signature.owner,
        wrapper orelse return error.TestUnexpectedResult,
        capabilities.ir_view,
    );
}

test "DirectCheckSource projects each tagged admission outcome" {
    {
        const source =
            "const first: any = 1;\n" ++
            "const second: void = undefined;\n";
        var owner: DirectCheckSource = undefined;
        try owner.initInPlace(
            std.testing.allocator,
            std.testing.allocator,
            source,
            "handler.ts",
        );
        defer owner.deinit();
        switch (owner.outcome().*) {
            .recovered_admission_refused => {},
            else => return error.TestUnexpectedResult,
        }
        const diagnostics = owner.selectedAdmissionDiagnostics();
        try std.testing.expectEqual(@as(usize, 2), diagnostics.len);
        try std.testing.expectEqual(parser.type_syntax.AdmissionKind.any_type, diagnostics[0].kind);
        try std.testing.expectEqual(parser.type_syntax.AdmissionKind.void_type, diagnostics[1].kind);
        try std.testing.expectEqual(
            @as(u32, @intCast(std.mem.indexOf(u8, source, "any").?)),
            diagnostics[0].span.start,
        );
        try std.testing.expectEqual(
            @as(u32, @intCast(std.mem.indexOf(u8, source, "void").?)),
            diagnostics[1].span.start,
        );
        try std.testing.expect(owner.acceptedCapabilities() == null);
        try std.testing.expect(owner.terminalAdmissionDiagnostic() == null);
        try std.testing.expectEqual(@as(usize, 0), owner.parserErrors().len);
    }

    {
        const source =
            "const value: \"open\n" ++
            " = \"open\";\n" ++
            "function handler(req: Request): Response { return Response.text(\"ok\"); }\n";
        var owner: DirectCheckSource = undefined;
        try owner.initCompileInPlace(
            std.testing.allocator,
            std.testing.allocator,
            source,
            "handler.ts",
        );
        defer owner.deinit();
        switch (owner.outcome().*) {
            .accepted => {},
            else => return error.TestUnexpectedResult,
        }
        try std.testing.expect(owner.acceptedCapabilities() != null);
        const last_observation = owner.parser.getLastAdmissionObservation() orelse
            return error.TestUnexpectedResult;
        try std.testing.expectEqual(
            parser.type_syntax.AdmissionKind.unterminated_string,
            last_observation.kind,
        );
        try std.testing.expectEqual(
            @as(u32, @intCast(std.mem.indexOfScalar(u8, source, '\n').?)),
            last_observation.span.start,
        );
        try std.testing.expectEqual(@as(usize, 0), owner.selectedAdmissionDiagnostics().len);
        try std.testing.expect(owner.terminalAdmissionDiagnostic() == null);
        try std.testing.expectEqual(@as(usize, 0), owner.parserErrors().len);
    }

    {
        const source =
            "const broken = ;\n" ++
            "const later = ;\n";
        var owner: DirectCheckSource = undefined;
        try owner.initInPlace(
            std.testing.allocator,
            std.testing.allocator,
            source,
            "handler.ts",
        );
        defer owner.deinit();
        switch (owner.outcome().*) {
            .parser_refused => |refusal| {
                try std.testing.expectEqual(@as(usize, 1), refusal.projected_error_count);
            },
            else => return error.TestUnexpectedResult,
        }
        try std.testing.expectEqual(@as(usize, 1), owner.parserErrors().len);
        try std.testing.expect(owner.parser.getErrors().len > owner.parserErrors().len);
        try std.testing.expect(owner.acceptedCapabilities() == null);
        try std.testing.expectEqual(@as(usize, 0), owner.selectedAdmissionDiagnostics().len);
        try std.testing.expect(owner.terminalAdmissionDiagnostic() == null);
    }

    {
        var owner: DirectCheckSource = undefined;
        try owner.initInPlace(
            std.testing.allocator,
            std.testing.allocator,
            "/* unfinished",
            "handler.ts",
        );
        defer owner.deinit();
        switch (owner.outcome().*) {
            .terminal_admission_refused => |failure| switch (failure) {
                .unterminated_comment => {},
                .diagnostic => return error.TestUnexpectedResult,
            },
            else => return error.TestUnexpectedResult,
        }
        try std.testing.expect(owner.terminalAdmissionDiagnostic() == null);
        try std.testing.expectEqual(@as(usize, 0), owner.selectedAdmissionDiagnostics().len);
        try std.testing.expectEqual(@as(usize, 0), owner.parserErrors().len);
        try std.testing.expect(owner.acceptedCapabilities() == null);
    }

    {
        const source =
            "const value: \"open\n" ++
            " = \"open\";\n" ++
            "/* unfinished";
        var owner: DirectCheckSource = undefined;
        try owner.initInPlace(
            std.testing.allocator,
            std.testing.allocator,
            source,
            "handler.ts",
        );
        defer owner.deinit();
        switch (owner.outcome().*) {
            .terminal_admission_refused => |failure| switch (failure) {
                .unterminated_comment => {},
                .diagnostic => return error.TestUnexpectedResult,
            },
            else => return error.TestUnexpectedResult,
        }
        const terminal = owner.terminalAdmissionDiagnostic() orelse
            return error.TestUnexpectedResult;
        try std.testing.expectEqual(parser.type_syntax.AdmissionKind.unterminated_string, terminal.kind);
        try std.testing.expectEqual(
            @as(u32, @intCast(std.mem.indexOfScalar(u8, source, '\n').?)),
            terminal.span.start,
        );
        try std.testing.expectEqual(@as(usize, 0), owner.selectedAdmissionDiagnostics().len);
        try std.testing.expectEqual(@as(usize, 0), owner.parserErrors().len);
        try std.testing.expect(owner.acceptedCapabilities() == null);
    }
}

test "DirectCheckSource accepts only TypeScript paths" {
    const paths = [_][]const u8{ "<eval>", "handler.js", "handler.tsx" };
    for (paths) |path| {
        var owner: DirectCheckSource = undefined;
        try std.testing.expectError(
            error.UnsupportedSourceExtension,
            owner.initInPlace(
                std.testing.allocator,
                std.testing.allocator,
                "const value = 1;",
                path,
            ),
        );
    }
}

test "DirectCheckSource cleans runtime parser and Store allocation failures" {
    const Context = struct {
        const source = "const value: number = 1;\n";

        fn runRuntime(allocator: std.mem.Allocator, failures: *usize) !void {
            var owner: DirectCheckSource = undefined;
            owner.initInPlace(
                allocator,
                std.testing.allocator,
                source,
                "handler.ts",
            ) catch |err| switch (err) {
                error.OutOfMemory => {
                    failures.* += 1;
                    return err;
                },
                else => return err,
            };
            defer owner.deinit();
            if (owner.acceptedCapabilities() == null) return error.TestUnexpectedResult;
        }

        fn runStore(allocator: std.mem.Allocator, failures: *usize) !void {
            var owner: DirectCheckSource = undefined;
            owner.initInPlace(
                std.testing.allocator,
                allocator,
                source,
                "handler.ts",
            ) catch |err| switch (err) {
                error.OutOfMemory => {
                    failures.* += 1;
                    return err;
                },
                else => return err,
            };
            defer owner.deinit();
            if (owner.acceptedCapabilities() == null) return error.TestUnexpectedResult;
        }
    };

    var no_resize = std.testing.FailingAllocator.init(std.testing.allocator, .{ .resize_fail_index = 0 });
    var runtime_failures: usize = 0;
    try std.testing.checkAllAllocationFailures(
        no_resize.allocator(),
        Context.runRuntime,
        .{&runtime_failures},
    );
    try std.testing.expect(runtime_failures > 0);

    var store_failures: usize = 0;
    try std.testing.checkAllAllocationFailures(
        no_resize.allocator(),
        Context.runStore,
        .{&store_failures},
    );
    try std.testing.expect(store_failures > 0);
}

test "DirectCheckSource validates runtime owners before publication" {
    var source: std.ArrayListUnmanaged(u8) = .empty;
    defer source.deinit(std.testing.allocator);
    try source.appendSlice(std.testing.allocator, "import type ");
    for (0..513) |_| try source.appendSlice(std.testing.allocator, "`${");
    try source.appendSlice(std.testing.allocator, "value");
    for (0..513) |_| try source.appendSlice(std.testing.allocator, "}`");
    try source.appendSlice(std.testing.allocator, ";\n");

    var calibration_runtime = std.testing.FailingAllocator.init(std.testing.allocator, .{
        .fail_index = std.math.maxInt(usize),
        .resize_fail_index = std.math.maxInt(usize),
    });
    var calibration_types = std.testing.FailingAllocator.init(std.testing.allocator, .{
        .fail_index = std.math.maxInt(usize),
        .resize_fail_index = std.math.maxInt(usize),
    });
    var atoms = atom_table.AtomTable.init(calibration_runtime.allocator());
    defer atoms.deinit();
    var admitted = try parser.JsParser.initAdmission(
        calibration_runtime.allocator(),
        calibration_types.allocator(),
        source.items,
        .collect,
    );
    defer admitted.deinit();
    admitted.setAtomTable(&atoms);
    const root = switch (try admitted.parseAdmission()) {
        .accepted => |root| root,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(@as(usize, 1), admitted.type_store.type_only_modules.items.len);
    const accepted_view = parser.IrView.fromIRStore(&admitted.nodes, &admitted.constants);
    try std.testing.expectEqual(parser.NodeTag.program, accepted_view.getTag(root).?);

    const validation_alloc_index = calibration_types.alloc_index;
    const validation_resize_index = calibration_types.resize_index;
    calibration_types.fail_index = validation_alloc_index;
    calibration_types.resize_fail_index = validation_resize_index;
    try std.testing.expectError(
        error.OutOfMemory,
        admitted.type_store.validateRuntimeOwners(
            calibration_types.allocator(),
            accepted_view,
        ),
    );
    try std.testing.expect(calibration_types.has_induced_failure);

    var owner_runtime = std.testing.FailingAllocator.init(std.testing.allocator, .{
        .fail_index = std.math.maxInt(usize),
        .resize_fail_index = std.math.maxInt(usize),
    });
    var owner_types = std.testing.FailingAllocator.init(std.testing.allocator, .{
        .fail_index = validation_alloc_index,
        .resize_fail_index = validation_resize_index,
    });
    var owner: DirectCheckSource = undefined;
    try std.testing.expectError(
        error.OutOfMemory,
        owner.initInPlace(
            owner_runtime.allocator(),
            owner_types.allocator(),
            source.items,
            "handler.ts",
        ),
    );
    try std.testing.expect(owner_types.has_induced_failure);
}

test "direct source distinguishes signatures and shadowed binding annotations" {
    const source = "function outer(value: number): number { const convert = (value: string): string => value; const item: number = value; { const item: string = convert(\"x\"); } return value; } function next(value: boolean): boolean { return value; }";
    var owner: DirectCheckSource = undefined;
    try owner.initCompileInPlace(std.testing.allocator, std.testing.allocator, source, "signatures.ts");
    defer owner.deinit();
    const store = (owner.acceptedCapabilities() orelse return error.TestUnexpectedResult).type_store;
    try std.testing.expectEqual(@as(usize, 3), store.function_signatures.items.len);
    try std.testing.expectEqual(@as(usize, 3), store.parameter_annotations.items.len);
    try std.testing.expectEqual(@as(usize, 2), store.annotations.items.len);
    const parameter_types = [_][]const u8{ "number", "string", "boolean" };
    for (store.parameter_annotations.items, parameter_types) |annotation, want| {
        try std.testing.expectEqualStrings(want, annotation.value.raw_span.text(source));
    }
    try std.testing.expectEqualStrings("number", store.annotations.items[0].raw_span.text(source));
    try std.testing.expectEqualStrings("string", store.annotations.items[1].raw_span.text(source));
    try std.testing.expectEqual(store.annotations.items[0].binding.name_atom, store.annotations.items[1].binding.name_atom);
    try std.testing.expect(store.annotations.items[0].binding.scope_id != store.annotations.items[1].binding.scope_id);
}

test "direct source exposes ordered refusal diagnostics" {
    const source =
        \\interface Legacy { value: string; }
        \\type Alias = string;
        \\distinct type OldId = string;
        \\const unsafe: any = value;
        \\const asserted = value as string;
        \\const checked = value satisfies Alias;
        \\let callback: (value: string) => void = use;
        \\function optional(value?: string): string { return value ?? ""; }
    ;
    // `marker` is the text the diagnostic is anchored to on its line; the column
    // is one past the marker's byte index in that line. For `as` and
    // `satisfies` the anchor is the type after the keyword, as in the admission
    // marker test in parser/parse.zig.
    const expected = [_]struct { kind: source_diagnostics.StripDiagnosticKind, line: u32, marker: []const u8 }{
        .{ .kind = .interface_declaration, .line = 1, .marker = "interface" },
        .{ .kind = .type_alias_declaration, .line = 2, .marker = "type" },
        .{ .kind = .distinct_type_declaration, .line = 3, .marker = "distinct" },
        .{ .kind = .any_type, .line = 4, .marker = "any" },
        .{ .kind = .as_assertion, .line = 5, .marker = "string" },
        .{ .kind = .satisfies_assertion, .line = 6, .marker = "Alias" },
        .{ .kind = .void_type, .line = 7, .marker = "void" },
        .{ .kind = .optional_parameter, .line = 8, .marker = "?" },
    };

    var owner: DirectCheckSource = undefined;
    try owner.initInPlace(std.testing.allocator, std.testing.allocator, source, "refused.ts");
    defer owner.deinit();
    switch (owner.outcome().*) {
        .recovered_admission_refused => {},
        else => return error.TestUnexpectedResult,
    }
    const diagnostics = owner.selectedAdmissionDiagnostics();
    try std.testing.expectEqual(expected.len, diagnostics.len);
    for (expected, diagnostics) |want, diagnostic| {
        const got = sourceDiagnosticFromAdmission(source, diagnostic);
        try std.testing.expectEqual(want.kind, got.kind);
        try std.testing.expectEqual(want.line, got.line);
        try std.testing.expect(got.column > 0);
        var lines = std.mem.splitScalar(u8, source, '\n');
        var line_text: []const u8 = "";
        for (0..want.line) |_| line_text = lines.next() orelse return error.TestUnexpectedResult;
        const marker_at = std.mem.indexOf(u8, line_text, want.marker) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqual(@as(u32, @intCast(marker_at + 1)), got.column);
    }
}

test "direct source keeps parser-owned syntax in its IR" {
    const source = "const folded = comptime(1);";
    var owner: DirectCheckSource = undefined;
    try owner.initCompileInPlace(std.testing.allocator, std.testing.allocator, source, "parser-owned.ts");
    defer owner.deinit();
    const accepted = owner.acceptedCapabilities() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings(source, owner.sourceView().text);
    try std.testing.expectEqual(parser.NodeTag.program, accepted.ir_view.getTag(accepted.root).?);
    try std.testing.expectEqual(@as(usize, 0), accepted.type_store.annotations.items.len);
    try std.testing.expectEqual(@as(usize, 0), owner.selectedAdmissionDiagnostics().len);
}

test "admission failures retain measured preparation errors" {
    const Kind = parser.type_syntax.AdmissionKind;
    const cases = [_]struct { kind: Kind, expected: anyerror }{
        .{ .kind = .any_type, .expected = error.UnsupportedAnyType },
        .{ .kind = .as_assertion, .expected = error.UnsupportedAsAssertion },
        .{ .kind = .satisfies_assertion, .expected = error.UnsupportedSatisfiesAssertion },
        .{ .kind = .unterminated_string, .expected = error.UnterminatedString },
        .{ .kind = .nominal_base_not_scalar, .expected = error.NominalBaseNotScalar },
        .{ .kind = .interface_declaration, .expected = error.InterfaceDeclaration },
        .{ .kind = .type_alias_declaration, .expected = error.TypeAliasDeclaration },
        .{ .kind = .distinct_type_declaration, .expected = error.DistinctTypeDeclaration },
        .{ .kind = .retired_types_import, .expected = error.LegacyTypesImport },
        .{ .kind = .default_parameter, .expected = error.DefaultParameter },
        .{ .kind = .optional_parameter, .expected = error.OptionalParameter },
        .{ .kind = .default_export, .expected = error.DefaultExport },
        .{ .kind = .mutable_export, .expected = error.MutableExport },
        .{ .kind = .array_type_alias, .expected = error.ArrayTypeAlias },
        .{ .kind = .readonly_array_type_alias, .expected = error.ReadonlyArrayTypeAlias },
        .{ .kind = .void_type, .expected = error.VoidType },
        .{ .kind = .nesting_too_deep, .expected = error.NestingTooDeep },
    };
    try std.testing.expectEqual(@typeInfo(Kind).@"enum".field_names.len, cases.len);
    var seen = std.EnumSet(Kind).empty;
    for (cases) |case| {
        try std.testing.expect(!seen.contains(case.kind));
        seen.insert(case.kind);
        try std.testing.expectEqual(case.expected, @as(anyerror, prepareErrorForAdmissionFailure(.{
            .diagnostic = .{ .kind = case.kind, .span = .{ .start = 0, .end = 1 } },
        })));
    }
    inline for (std.meta.tags(Kind)) |kind| try std.testing.expect(seen.contains(kind));
    try std.testing.expectEqual(error.UnterminatedComment, prepareErrorForAdmissionFailure(.{
        .unterminated_comment = .{ .opener = 0, .@"resume" = 1 },
    }));
}

test "source admission preflight returns owned failure values and propagates allocation failure" {
    const source = "const broken = ; const { value }: { value: any } = input;";
    const Context = struct {
        fn run(allocator: std.mem.Allocator) !void {
            const failure = (try checkSourceAdmission(allocator, source)) orelse return error.TestUnexpectedResult;
            switch (failure) {
                .diagnostic => |diagnostic| {
                    try std.testing.expectEqual(parser.type_syntax.AdmissionKind.any_type, diagnostic.kind);
                    try std.testing.expectEqualStrings("any", diagnostic.span.text(source));
                },
                else => return error.TestUnexpectedResult,
            }
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Context.run, .{});
    try std.testing.expect(try checkSourceAdmission(std.testing.allocator, "while (true) {} const value: number = 1;") == null);
    const unfinished = (try checkSourceAdmission(std.testing.allocator, "/* unfinished")) orelse return error.TestUnexpectedResult;
    try std.testing.expect(unfinished == .unterminated_comment);
}
