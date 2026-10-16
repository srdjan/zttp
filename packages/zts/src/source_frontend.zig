//! One source-preparation boundary for every parser consumer.
//!
//! This module owns extension classification, TypeScript stripping, the parser
//! input, and the source-position view.

const std = @import("std");
const atom_table = @import("atom_table.zig");
const parser = @import("parser/root.zig");
const stripper = @import("stripper.zig");
const TypeMap = @import("zts-base").type_map.TypeMap;

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

pub const PrepareError = stripper.StripError || error{UnsupportedSourceExtension};

pub const PreparedSource = struct {
    original_source: []const u8,
    path: []const u8,
    kind: SourceKind,
    strip_result: ?stripper.StripResult = null,

    pub fn init(
        allocator: std.mem.Allocator,
        source: []const u8,
        path: []const u8,
        options: stripper.StripOptions,
    ) PrepareError!PreparedSource {
        const kind = classifyPath(path);
        switch (kind) {
            .unsupported => return error.UnsupportedSourceExtension,
            .typescript, .virtual_javascript => {},
        }
        var result = PreparedSource{
            .original_source = source,
            .path = path,
            .kind = kind,
        };
        if (kind.isTyped()) result.strip_result = try stripper.strip(allocator, source, options);
        return result;
    }

    pub fn deinit(self: *PreparedSource) void {
        if (self.strip_result) |*result| result.deinit();
        self.strip_result = null;
    }

    pub fn parserInput(self: *const PreparedSource) []const u8 {
        return if (self.strip_result) |result| result.code else self.original_source;
    }

    pub fn typeMap(self: *PreparedSource) ?*TypeMap {
        return if (self.strip_result) |*result| &result.type_map else null;
    }

    pub fn stripDiagnostics(self: *const PreparedSource) []const stripper.StripDiagnostic {
        return if (self.strip_result) |result| result.diagnostics else &.{};
    }

    pub fn sourceView(self: *const PreparedSource) stripper.SourceView {
        var view = if (self.strip_result) |*result|
            stripper.SourceView.stripped(self.original_source, result)
        else
            stripper.SourceView.of(self.original_source);
        view.name = self.path;
        return view;
    }
};

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
            .compile,
        );
    }

    fn initWithModeInPlace(
        self: *DirectCheckSource,
        allocator: std.mem.Allocator,
        type_allocator: std.mem.Allocator,
        source: []const u8,
        path: []const u8,
        mode: parser.type_syntax.AdmissionMode,
    ) anyerror!void {
        switch (classifyPath(path)) {
            .typescript => {},
            .virtual_javascript, .unsupported => return error.UnsupportedSourceExtension,
        }

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

    pub fn sourceView(self: *const DirectCheckSource) stripper.SourceView {
        var view = stripper.SourceView.of(self.source);
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

test "PreparedSource refuses unsupported file extensions" {
    const cases = [_][]const u8{ "handler.js", "handler.jsx", "handler.tsx", "handler.txt" };
    for (cases) |path| {
        try std.testing.expectError(
            error.UnsupportedSourceExtension,
            PreparedSource.init(std.testing.allocator, "const value = 1;", path, .{}),
        );
    }
}

test "PreparedSource strips TypeScript and preserves virtual source" {
    const allocator = std.testing.allocator;

    var typed = try PreparedSource.init(allocator, "const name: string = \"Ada\";", "handler.ts", .{});
    defer typed.deinit();
    try std.testing.expect(typed.typeMap() != null);
    try std.testing.expect(std.mem.indexOf(u8, typed.parserInput(), ": string") == null);
    try std.testing.expectEqualStrings("const name: string = \"Ada\";", typed.sourceView().text);

    var virtual = try PreparedSource.init(allocator, "const value = 1;", "<eval>", .{});
    defer virtual.deinit();
    try std.testing.expect(virtual.typeMap() == null);
    try std.testing.expectEqualStrings(virtual.original_source, virtual.parserInput());
}

test "PreparedSource closes every stripping allocation failure" {
    const Context = struct {
        fn run(allocator: std.mem.Allocator) !void {
            var prepared = try PreparedSource.init(
                allocator,
                "const name: string = \"Ada\";",
                "handler.ts",
                .{},
            );
            defer prepared.deinit();
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Context.run, .{});
}

test "PreparedSource characterizes every type map kind" {
    const TypeMapKind = @import("zts-base").type_map.TypeMapKind;
    const source =
        \\structural Box<T> = { value: T } & { meta: string };
        \\nominal UserId = string;
        \\function keep<T>(value: T): Box<T> { return { value: value, meta: "kept" }; }
        \\function isText(value: unknown): value is string { return typeof value === "string"; }
        \\const boxed: Box<string> = keep<Box<string>>({ value: "x", meta: "m" });
        \\const tolerant: string ignored_suffix = "kept";
    ;

    var prepared = try PreparedSource.init(std.testing.allocator, source, "types.ts", .{});
    defer prepared.deinit();

    const type_map = prepared.typeMap().?;
    var seen = std.EnumSet(TypeMapKind).initEmpty();
    var alias_count: usize = 0;
    var distinct_count: usize = 0;
    var variable_count: usize = 0;
    var parameter_count: usize = 0;
    var return_count: usize = 0;
    var guard_count: usize = 0;
    var generic_count: usize = 0;
    var call_argument_count: usize = 0;
    var saw_t_parameter = false;
    var saw_unknown_parameter = false;
    var saw_alias_generic = false;
    var saw_function_generic = false;

    for (type_map.entries.items) |entry| {
        seen.insert(entry.kind);
        switch (entry.kind) {
            .type_alias => {
                alias_count += 1;
                try std.testing.expectEqualStrings("Box", type_map.getNameText(entry).?);
                try std.testing.expectEqualStrings("{ value: T } & { meta: string }", type_map.getTypeText(entry));
                try std.testing.expect(entry.signature_offset == null);
            },
            .distinct_type => {
                distinct_count += 1;
                try std.testing.expectEqualStrings("UserId", type_map.getNameText(entry).?);
                try std.testing.expectEqualStrings("string", type_map.getTypeText(entry));
                try std.testing.expect(entry.signature_offset == null);
            },
            .var_annotation => {
                variable_count += 1;
                const name = type_map.getNameText(entry).?;
                if (std.mem.eql(u8, name, "boxed")) {
                    try std.testing.expectEqualStrings("Box<string>", type_map.getTypeText(entry));
                } else if (std.mem.eql(u8, name, "tolerant")) {
                    try std.testing.expectEqualStrings("string ignored_suffix", type_map.getTypeText(entry));
                } else {
                    return error.TestUnexpectedResult;
                }
                try std.testing.expect(entry.name_ordinal != null);
                try std.testing.expect(entry.signature_offset == null);
            },
            .param_annotation => {
                parameter_count += 1;
                try std.testing.expectEqualStrings("value", type_map.getNameText(entry).?);
                const text = type_map.getTypeText(entry);
                if (std.mem.eql(u8, text, "T")) {
                    saw_t_parameter = true;
                } else if (std.mem.eql(u8, text, "unknown")) {
                    saw_unknown_parameter = true;
                } else {
                    return error.TestUnexpectedResult;
                }
                try std.testing.expect(entry.signature_offset != null);
            },
            .return_annotation => {
                return_count += 1;
                try std.testing.expectEqualStrings("keep", type_map.getNameText(entry).?);
                try std.testing.expectEqualStrings("Box<T> ", type_map.getTypeText(entry));
                try std.testing.expect(entry.signature_offset != null);
            },
            .type_guard_annotation => {
                guard_count += 1;
                try std.testing.expectEqualStrings("isText", type_map.getNameText(entry).?);
                try std.testing.expectEqualStrings("value is string ", type_map.getTypeText(entry));
                try std.testing.expect(entry.signature_offset != null);
            },
            .generic_params => {
                generic_count += 1;
                const name = type_map.getNameText(entry).?;
                const text = type_map.getTypeText(entry);
                if (std.mem.eql(u8, name, "Box")) {
                    saw_alias_generic = true;
                    try std.testing.expectEqualStrings("<T>", text);
                    try std.testing.expect(entry.signature_offset == null);
                } else if (std.mem.eql(u8, name, "keep")) {
                    saw_function_generic = true;
                    try std.testing.expectEqualStrings("T", text);
                    const offset = entry.signature_offset.?;
                    try std.testing.expectEqual(@as(u8, '('), prepared.parserInput()[offset]);
                } else {
                    return error.TestUnexpectedResult;
                }
            },
            .call_type_arguments => {
                call_argument_count += 1;
                try std.testing.expect(type_map.getNameText(entry) == null);
                try std.testing.expectEqualStrings("Box<string>", type_map.getTypeText(entry));
                try std.testing.expect(entry.signature_offset == null);
            },
        }
    }

    inline for (@typeInfo(TypeMapKind).@"enum".fields) |field| {
        const kind: TypeMapKind = @enumFromInt(field.value);
        std.testing.expect(seen.contains(kind)) catch |err| {
            std.debug.print("type map kind '{s}' has no characterization fixture\n", .{@tagName(kind)});
            return err;
        };
    }
    try std.testing.expectEqual(@as(usize, 1), alias_count);
    try std.testing.expectEqual(@as(usize, 1), distinct_count);
    try std.testing.expectEqual(@as(usize, 2), variable_count);
    try std.testing.expectEqual(@as(usize, 2), parameter_count);
    try std.testing.expectEqual(@as(usize, 1), return_count);
    try std.testing.expectEqual(@as(usize, 1), guard_count);
    try std.testing.expectEqual(@as(usize, 2), generic_count);
    try std.testing.expectEqual(@as(usize, 1), call_argument_count);
    try std.testing.expect(saw_t_parameter);
    try std.testing.expect(saw_unknown_parameter);
    try std.testing.expect(saw_alias_generic);
    try std.testing.expect(saw_function_generic);
    try std.testing.expectEqual(source.len, prepared.parserInput().len);
    try std.testing.expectEqualStrings(source, prepared.sourceView().text);
    try std.testing.expectEqualStrings("types.ts", prepared.sourceView().name.?);
    try std.testing.expect(prepared.sourceView().normalize_positions);
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
        capabilities.atoms.getName(@enumFromInt(function.name_atom)).?,
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

    var runtime_failures: usize = 0;
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        Context.runRuntime,
        .{&runtime_failures},
    );
    try std.testing.expect(runtime_failures > 0);

    var store_failures: usize = 0;
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
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

test "PreparedSource distinguishes signatures and shadowed bindings" {
    const source = "function outer(value: number): number { const convert = (value: string): string => value; const item: number = value; { const item: string = convert(\"x\"); } return value; } function next(value: boolean): boolean { return value; }";
    var prepared = try PreparedSource.init(std.testing.allocator, source, "signatures.ts", .{});
    defer prepared.deinit();

    const outer_offset = std.mem.indexOf(u8, source, "(value: number)").?;
    const arrow_offset = std.mem.indexOf(u8, source, "(value: string)").?;
    const next_offset = std.mem.indexOf(u8, source, "(value: boolean)").?;
    var outer_annotations: usize = 0;
    var arrow_annotations: usize = 0;
    var next_annotations: usize = 0;
    var item_annotation_count: usize = 0;
    var item_ordinals = [_]bool{ false, false };

    const type_map = prepared.typeMap().?;
    for (type_map.entries.items) |entry| switch (entry.kind) {
        .param_annotation, .return_annotation => {
            const offset = entry.signature_offset.?;
            try std.testing.expectEqual(@as(u8, '('), prepared.parserInput()[offset]);
            if (offset == outer_offset) outer_annotations += 1;
            if (offset == arrow_offset) arrow_annotations += 1;
            if (offset == next_offset) next_annotations += 1;
        },
        .var_annotation => {
            const name = type_map.getNameText(entry).?;
            if (!std.mem.eql(u8, name, "item")) continue;
            item_annotation_count += 1;
            const ordinal = entry.name_ordinal orelse return error.TestUnexpectedResult;
            if (ordinal >= item_ordinals.len) return error.TestUnexpectedResult;
            item_ordinals[ordinal] = true;
            try std.testing.expect(entry.signature_offset == null);
            const expected_text = if (ordinal == 0) "number" else "string";
            try std.testing.expectEqualStrings(expected_text, type_map.getTypeText(entry));
        },
        else => {},
    };

    try std.testing.expectEqual(@as(usize, 2), outer_annotations);
    try std.testing.expectEqual(@as(usize, 2), arrow_annotations);
    try std.testing.expectEqual(@as(usize, 2), next_annotations);
    try std.testing.expectEqual(@as(usize, 2), item_annotation_count);
    try std.testing.expect(item_ordinals[0]);
    try std.testing.expect(item_ordinals[1]);
}

test "PreparedSource exposes ordered source refusal diagnostics" {
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
    const expected = [_]struct { kind: stripper.StripDiagnosticKind, line: u32 }{
        .{ .kind = .interface_declaration, .line = 1 },
        .{ .kind = .type_alias_declaration, .line = 2 },
        .{ .kind = .distinct_type_declaration, .line = 3 },
        .{ .kind = .any_type, .line = 4 },
        .{ .kind = .as_assertion, .line = 5 },
        .{ .kind = .satisfies_assertion, .line = 6 },
        .{ .kind = .void_type, .line = 7 },
        .{ .kind = .optional_parameter, .line = 8 },
    };

    var prepared = try PreparedSource.init(std.testing.allocator, source, "refused.ts", .{
        .collect_all_diagnostics = true,
        .report_errors = false,
    });
    defer prepared.deinit();

    const diagnostics = prepared.stripDiagnostics();
    try std.testing.expectEqual(expected.len, diagnostics.len);
    for (expected, diagnostics) |want, got| {
        try std.testing.expectEqual(want.kind, got.kind);
        try std.testing.expectEqual(want.line, got.line);
        try std.testing.expect(got.column > 0);
    }
}

test "PreparedSource leaves parser-owned syntax unchanged" {
    const source = "const folded = comptime(1);\nconst view = <div />;";
    var prepared = try PreparedSource.init(std.testing.allocator, source, "parser-owned.ts", .{});
    defer prepared.deinit();

    try std.testing.expectEqualStrings(source, prepared.parserInput());
    try std.testing.expectEqual(@as(usize, 0), prepared.typeMap().?.count());
    try std.testing.expectEqual(@as(usize, 0), prepared.stripDiagnostics().len);
}
