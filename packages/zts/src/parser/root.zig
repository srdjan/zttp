//! New Parser Module - Two-pass architecture with scope-aware IR
//!
//! This module provides a modern JavaScript parser with:
//! - Proper closure/upvalue support for nested functions
//! - Full template literal interpolation
//! - Core syntax only; JSX is unsupported
//! - Better error messages with source locations
//!
//! Usage:
//!   const parser = @import("parser/root.zig");
//!
//!   // Parse source code (new API)
//!   var p = parser.JsParser.init(allocator, source);
//!   defer p.deinit();
//!   const ast = try p.parse();
//!
//!   // Or use the stable `zts.Parser` wrapper:
//!   var p = parser.Parser.init(allocator, source, &strings, &atoms);
//!   defer p.deinit();
//!   const bytecode = try p.parse();
//!   // Access: p.max_local_count, p.constants.items

const std = @import("std");

// Import from parent
const bytecode = @import("../bytecode.zig");
const value = @import("../value.zig");
const string = @import("../string.zig");
const atom_table_mod = @import("../atom_table.zig");
const object = @import("../object.zig");

// Re-export all parser components
// The IR store as a module, for a consumer in another build module that
// walks the IR rather than naming one symbol from it. A relative import
// across the module line would compile a second copy of ir.zig, and a
// NodeIndex from one copy is not a NodeIndex from the other. `parse.zig`
// needs no such re-export: `JsParser` below is the only thing anyone wants
// from it, and `parse` is already a function in this file.
pub const ir = @import("ir.zig");

pub const Token = @import("token.zig").Token;
pub const TokenType = @import("token.zig").TokenType;
pub const SourceLocation = @import("token.zig").SourceLocation;

pub const Tokenizer = @import("tokenizer.zig").Tokenizer;

pub const trivia = @import("trivia.zig");
pub const Trivia = @import("trivia.zig").Trivia;
pub const TriviaKind = @import("trivia.zig").Kind;
pub const type_syntax = @import("type_syntax.zig");

pub const Node = @import("ir.zig").Node;
pub const NodeTag = @import("ir.zig").NodeTag;
pub const NodeIndex = @import("ir.zig").NodeIndex;
pub const ConstantPool = @import("ir.zig").ConstantPool;
pub const BinaryOp = @import("ir.zig").BinaryOp;
pub const UnaryOp = @import("ir.zig").UnaryOp;
pub const BindingRef = @import("ir.zig").BindingRef;
pub const null_node = @import("ir.zig").null_node;

// Phase 3: Optimized IR storage (SoA pattern)
pub const IRStore = @import("ir.zig").IRStore;
pub const IrView = @import("ir.zig").IrView;
pub const DataPayload = @import("ir.zig").DataPayload;

pub const ScopeAnalyzer = @import("scope.zig").ScopeAnalyzer;
pub const Scope = @import("scope.zig").Scope;
pub const Binding = @import("scope.zig").Binding;
pub const Upvalue = @import("scope.zig").Upvalue;

pub const ErrorList = @import("error.zig").ErrorList;
pub const ParseError = @import("error.zig").ParseError;
pub const ErrorKind = @import("error.zig").ErrorKind;

pub const JsParser = @import("parse.zig").Parser;
pub const AdmissionFailure = @import("parse.zig").AdmissionFailure;
pub const AdmissionParseOutcome = @import("parse.zig").AdmissionParseOutcome;
pub const CodeGen = @import("codegen.zig").CodeGen;
pub const ir_opt = @import("ir_opt.zig");

/// Parse options
pub const ParseOptions = struct {
    module_mode: bool = false,
    strict_mode: bool = true,
};

/// Parse result containing IR and any errors
pub const ParseResult = struct {
    nodes: IRStore,
    constants: ConstantPool,
    scopes: ScopeAnalyzer,
    errors: ErrorList,
    type_store: type_syntax.Store,
    root: NodeIndex,

    pub fn deinit(self: *ParseResult) void {
        self.nodes.deinit();
        self.constants.deinit();
        self.scopes.deinit();
        self.errors.deinit();
        self.type_store.deinit();
    }

    pub fn hasErrors(self: *const ParseResult) bool {
        return self.errors.hasErrors();
    }
};

/// High-level parse function
pub fn parse(
    allocator: std.mem.Allocator,
    source: []const u8,
    options: ParseOptions,
) !ParseResult {
    _ = options;
    var p = try JsParser.init(allocator, source);
    // The result adopts permanent parser storage, not reusable list scratch.
    defer p.scratch_nodes.deinit(allocator);

    // Note: strict_mode is always true in zts (var keyword rejected)
    // Note: module_mode affects import/export handling (future)

    const root = p.parse() catch {
        return ParseResult{
            .nodes = p.nodes,
            .constants = p.constants,
            .scopes = p.scopes,
            .errors = p.errors,
            .type_store = p.type_store,
            .root = @import("ir.zig").null_node,
        };
    };

    return ParseResult{
        .nodes = p.nodes,
        .constants = p.constants,
        .scopes = p.scopes,
        .errors = p.errors,
        .type_store = p.type_store,
        .root = root,
    };
}

// ============================================================================
// Parser wrapper - the stable `zts.Parser`
// ============================================================================

/// Parser wrapper behind the stable `zts.Parser` that zruntime.zig and embedders use
/// Usage:
///   var p = Parser.init(allocator, source, &strings, &atoms);
///   defer p.deinit();
///   const bytecode = try p.parse();
///   // Access: p.max_local_count, p.constants.items
pub const Parser = struct {
    allocator: std.mem.Allocator,
    source: []const u8,

    // Internal parser and codegen state
    js_parser: JsParser,
    code_gen: ?CodeGen,

    // Output fields for zruntime.zig
    max_local_count: u8,
    constants: ConstantsList,
    root_node: NodeIndex = @import("ir.zig").null_node,
    typed_phase: ?TypedPhase = null,

    // Strings and atoms that CodeGen receives
    strings: *string.StringTable,
    atoms: ?*atom_table_mod.AtomTable,

    /// Wrapper for constants to provide .items interface
    const TypedPhase = enum { ready, attempted, ir_ready };

    pub const ConstantsList = struct {
        items: []const value.JSValue,
    };

    pub fn init(
        allocator: std.mem.Allocator,
        source: []const u8,
        strings: *string.StringTable,
        atoms: ?*atom_table_mod.AtomTable,
    ) !Parser {
        var p = Parser{
            .allocator = allocator,
            .source = source,
            .js_parser = try JsParser.init(allocator, source),
            .code_gen = null,
            .max_local_count = 0,
            .constants = .{ .items = &.{} },
            .strings = strings,
            .atoms = atoms,
        };
        // This wrapper already borrows source for its complete lifetime, and
        // codegen copies strings into the runtime StringTable before teardown.
        p.js_parser.borrowSourceStrings();
        if (atoms) |atom_table| {
            p.js_parser.setAtomTable(atom_table);
        }
        return p;
    }

    pub fn initTyped(
        allocator: std.mem.Allocator,
        type_allocator: std.mem.Allocator,
        source: []const u8,
        strings: *string.StringTable,
        atoms: ?*atom_table_mod.AtomTable,
    ) !Parser {
        var result: Parser = .{
            .allocator = allocator,
            .source = source,
            .js_parser = try JsParser.initAdmission(allocator, type_allocator, source, .compile),
            .code_gen = null,
            .max_local_count = 0,
            .constants = .{ .items = &.{} },
            .strings = strings,
            .atoms = atoms,
            .typed_phase = .ready,
        };
        result.js_parser.borrowSourceStrings();
        if (atoms) |table| result.js_parser.setAtomTable(table);
        return result;
    }

    pub fn parseTypedIr(self: *Parser) !AdmissionParseOutcome {
        if (self.typed_phase != .ready) return error.InvalidParserPhase;
        self.typed_phase = .attempted;
        const outcome = try self.js_parser.parseAdmission();
        switch (outcome) {
            .accepted => |root| {
                try self.js_parser.type_store.validateRuntimeOwners(
                    self.js_parser.type_store.allocator,
                    IrView.fromIRStore(&self.js_parser.nodes, &self.js_parser.constants),
                );
                self.root_node = root;
                self.typed_phase = .ir_ready;
            },
            else => {},
        }
        return outcome;
    }

    pub fn generateParsed(self: *Parser, codegen_allocator: std.mem.Allocator) ![]const u8 {
        if (self.typed_phase != .ir_ready) return error.InvalidParserPhase;
        self.typed_phase = .attempted;
        self.code_gen = CodeGen.initWithIRStore(
            codegen_allocator,
            &self.js_parser.nodes,
            &self.js_parser.constants,
            &self.js_parser.scopes,
            self.strings,
            self.atoms,
        );
        errdefer {
            self.code_gen.?.freeOwnedConstantPayloads();
            self.code_gen.?.deinit();
            self.code_gen = null;
        }
        const function = try self.code_gen.?.generate(self.root_node);
        self.max_local_count = @intCast(function.local_count);
        self.constants = .{ .items = function.constants };
        return function.code;
    }

    pub fn deinit(self: *Parser) void {
        if (self.code_gen) |*cg| {
            cg.deinit();
        }
        self.js_parser.deinit();
    }

    /// Parse and generate bytecode, returns bytecode slice
    pub fn parse(self: *Parser) ![]const u8 {
        if (self.typed_phase != null) return error.InvalidParserPhase;
        return self.parseWithCodegenAllocator(self.allocator);
    }

    /// Parse and generate bytecode, using `codegen_alloc` for the CodeGen pass.
    /// The tokenizer/parser/IR still use `self.allocator`. Used by the
    /// compile-time microbench to isolate codegen allocation from parser/IR
    /// allocation; production paths call `parse()` with both identical.
    pub fn parseWithCodegenAllocator(self: *Parser, codegen_alloc: std.mem.Allocator) ![]const u8 {
        if (self.typed_phase != null) return error.InvalidParserPhase;
        const root = try self.js_parser.parse();
        self.root_node = root;

        self.code_gen = CodeGen.initWithIRStore(
            codegen_alloc,
            &self.js_parser.nodes,
            &self.js_parser.constants,
            &self.js_parser.scopes,
            self.strings,
            self.atoms,
        );

        const func_bc = try self.code_gen.?.generate(root);

        self.max_local_count = @intCast(func_bc.local_count);
        self.constants = .{ .items = func_bc.constants };

        return func_bc.code;
    }

    /// Get the object literal shapes collected during compilation.
    /// Must be called after parse(). Returns empty slice if parse() wasn't called.
    pub fn getShapes(self: *const Parser) []const []const object.Atom {
        if (self.code_gen) |*cg| {
            return cg.shapes.items;
        }
        return &[_][]const object.Atom{};
    }

    /// Must be called after parse(). The returned slice is owned by CodeGen.
    pub fn getLineTable(self: *const Parser) []const bytecode.LineEntry {
        if (self.code_gen) |*cg| {
            return cg.line_table.items;
        }
        return &.{};
    }

    /// Import declaration info extracted from the IR after parsing.
    pub const ImportInfo = struct {
        module_specifier: []const u8,
        specifier_names: []const []const u8,
    };

    /// Extract module import declarations from the parsed IR.
    /// Must be called after parse(). Returns a list of (module_specifier, imported_names).
    /// Caller owns the returned slices and must free with the same allocator.
    pub fn getImports(self: *const Parser) ![]ImportInfo {
        const ir_store = &self.js_parser.nodes;
        const ir_constants = &self.js_parser.constants;
        const view = IrView.fromIRStore(ir_store, ir_constants);

        var imports = std.ArrayList(ImportInfo).empty;
        errdefer {
            for (imports.items) |info| {
                self.allocator.free(info.specifier_names);
            }
            imports.deinit(self.allocator);
        }

        // Scan all nodes for import_decl
        const node_count = view.nodeCount();
        for (0..node_count) |idx| {
            const tag = view.getTag(@intCast(idx)) orelse continue;
            if (tag != .import_decl) continue;

            const import_decl = view.getImportDecl(@intCast(idx)) orelse continue;
            const module_str = view.getString(import_decl.module_idx) orelse continue;

            // Collect specifier names
            var names = std.ArrayList([]const u8).empty;
            errdefer names.deinit(self.allocator);

            for (0..import_decl.specifiers_count) |si| {
                const spec_idx = view.getListIndex(import_decl.specifiers_start, @intCast(si));
                const spec = view.getImportSpec(spec_idx) orelse continue;
                // Resolve atom to string name (handles both predefined and dynamic atoms)
                const atom: object.Atom = @fromBackingInt(@intCast(spec.imported_atom));
                const imported_name = resolveAtomName(atom, self.atoms) orelse continue;
                try names.append(self.allocator, imported_name);
            }

            try imports.append(self.allocator, .{
                .module_specifier = module_str,
                .specifier_names = try names.toOwnedSlice(self.allocator),
            });
        }

        return imports.toOwnedSlice(self.allocator);
    }

    /// Resolve an atom index back to a string name
    fn resolveAtomName(atom: object.Atom, atoms: ?*atom_table_mod.AtomTable) ?[]const u8 {
        // Check predefined atoms first
        if (atom.isPredefined()) {
            return atom.toPredefinedName();
        }
        // Check dynamic atoms from atom table
        if (atoms) |at| {
            return at.getName(atom);
        }
        return null;
    }

    /// Free import info returned by getImports
    pub fn freeImports(self: *const Parser, imports: []ImportInfo) void {
        for (imports) |info| {
            self.allocator.free(info.specifier_names);
        }
        self.allocator.free(imports);
    }
};

test "root module imports" {
    // Just verify imports work
    _ = Token;
    _ = Tokenizer;
    _ = Node;
    _ = JsParser;
    _ = CodeGen;
    _ = ir_opt;
}

test "parse result owns permanent lists after scratch teardown" {
    var result = try parse(std.testing.allocator, "function f(a) { return [a, [1, 2]]; }", .{});
    defer result.deinit();
    try std.testing.expect(!result.hasErrors());
    const view = IrView.fromIRStore(&result.nodes, &result.constants);
    const program = view.getBlock(result.root).?;
    try std.testing.expectEqual(@as(u16, 1), program.stmts_count);
    const decl = view.getVarDecl(view.getListIndex(program.stmts_start, 0)).?;
    try std.testing.expectEqual(@as(u8, 1), view.getFunction(decl.init).?.params_count);
}

// Pull in tests from submodules
test {
    _ = @import("ir_opt.zig");
    _ = @import("trivia.zig");
    _ = @import("ir_children_tests.zig");
}

test "legacy Parser API" {
    const allocator = std.testing.allocator;
    var strings = string.StringTable.init(allocator);
    defer strings.deinit();

    var p = try Parser.init(allocator, "let x = 1;", &strings, null);
    defer p.deinit();

    const bytecode_data = try p.parse();
    try std.testing.expect(bytecode_data.len > 0);
    // Global variables don't need local slots - they use put_global
    // max_local_count is 0 for top-level code with only global vars

    // `let x = 1;` pushes 1, stores it to the global (opcode plus u16 atom),
    // and the generator ends every program with ret_undefined.
    try std.testing.expectEqual(@as(usize, 5), bytecode_data.len);
    try std.testing.expectEqual(@backingInt(bytecode.Opcode.push_1), bytecode_data[0]);
    try std.testing.expectEqual(@backingInt(bytecode.Opcode.put_global), bytecode_data[1]);
    try std.testing.expectEqual(@backingInt(bytecode.Opcode.ret_undefined), bytecode_data[4]);
}

test "legacy Parser API getImports returns imported names" {
    const allocator = std.testing.allocator;
    var strings = string.StringTable.init(allocator);
    defer strings.deinit();
    var atoms = atom_table_mod.AtomTable.init(allocator);
    defer atoms.deinit();

    var p = try Parser.init(
        allocator,
        \\import { sha256 as hash, base64Encode } from "zttp:crypto";
        \\const out = hash("abc");
    ,
        &strings,
        &atoms,
    );
    defer p.deinit();

    _ = try p.parse();
    const imports = try p.getImports();
    defer p.freeImports(imports);

    try std.testing.expectEqual(@as(usize, 1), imports.len);
    try std.testing.expectEqualStrings("zttp:crypto", imports[0].module_specifier);
    try std.testing.expectEqual(@as(usize, 2), imports[0].specifier_names.len);
    try std.testing.expectEqualStrings("sha256", imports[0].specifier_names[0]);
    try std.testing.expectEqualStrings("base64Encode", imports[0].specifier_names[1]);
}

test "core parser rejects raw JSX element syntax" {
    var parser = try JsParser.init(std.testing.allocator, "const view = <div />;");
    defer parser.deinit();

    try std.testing.expectError(error.UnexpectedToken, parser.parse());
    try std.testing.expect(parser.hasErrors());
    try std.testing.expectEqual(ErrorKind.unexpected_token, parser.getErrors()[0].kind);
}

test "var keyword is rejected with helpful error" {
    const allocator = std.testing.allocator;
    var strings = string.StringTable.init(allocator);
    defer strings.deinit();

    const source = "var x = 1;";
    var p = try Parser.init(allocator, source, &strings, null);
    defer p.deinit();

    _ = p.parse() catch {};

    // Should have an error
    try std.testing.expect(p.js_parser.errors.hasErrors());

    // Error should mention 'var' and suggest 'let' or 'const'
    const errors = p.js_parser.errors.getErrors();
    try std.testing.expect(errors.len > 0);
    const err = errors[0];
    try std.testing.expect(std.mem.indexOf(u8, err.message, "var") != null);
    try std.testing.expect(std.mem.indexOf(u8, err.message, "let") != null);
}

test "postfix increment is rejected with helpful error" {
    const allocator = std.testing.allocator;
    var strings = string.StringTable.init(allocator);
    defer strings.deinit();

    const source = "let x = 0; x++;";
    var p = try Parser.init(allocator, source, &strings, null);
    defer p.deinit();

    _ = p.parse() catch {};

    // Should have an error about postfix increment
    try std.testing.expect(p.js_parser.errors.hasErrors());
    const errors = p.js_parser.errors.getErrors();
    try std.testing.expect(errors.len > 0);
    const err = errors[0];
    // Message should mention x++ and suggest x = x + 1
    try std.testing.expect(std.mem.indexOf(u8, err.message, "x++") != null);
    try std.testing.expect(std.mem.indexOf(u8, err.message, "x = x + 1") != null);
}

test "prefix increment is rejected with helpful error" {
    const allocator = std.testing.allocator;
    var strings = string.StringTable.init(allocator);
    defer strings.deinit();

    const source = "let x = 0; ++x;";
    var p = try Parser.init(allocator, source, &strings, null);
    defer p.deinit();

    _ = p.parse() catch {};

    // Should have an error about prefix increment
    try std.testing.expect(p.js_parser.errors.hasErrors());
    const errors = p.js_parser.errors.getErrors();
    try std.testing.expect(errors.len > 0);
    const err = errors[0];
    // Message should mention ++x and suggest x = x + 1
    try std.testing.expect(std.mem.indexOf(u8, err.message, "++x") != null);
    try std.testing.expect(std.mem.indexOf(u8, err.message, "x = x + 1") != null);
}

test "a match record key that cannot be interned fails codegen instead of dropping the field" {
    // Codegen skipped a record-pattern field whose key atom could not be
    // interned and emitted the rest, so the bytecode tested fewer fields than
    // the proven IR. Every other name is interned first; the table is then
    // full, so only the pattern key `zzkind` fails.
    const allocator = std.testing.allocator;
    var strings = string.StringTable.init(allocator);
    defer strings.deinit();
    var atoms = atom_table_mod.AtomTable.init(allocator);
    defer atoms.deinit();
    for ([_][]const u8{ "h", "zzq" }) |name| _ = try atoms.intern(name);
    atoms.next_id = 0xFFFE;

    var p = try Parser.init(allocator,
        \\function h(zzq) {
        \\  return match (zzq) {
        \\    when { zzkind: "x" }: 200,
        \\    default: 404
        \\  };
        \\}
    , &strings, &atoms);
    defer p.deinit();

    try std.testing.expectError(error.OutOfMemory, p.parse());
}

test "typed parser delays generation and matches equivalent JavaScript bytecode and atoms" {
    const allocator = std.testing.allocator;
    const typed_source = "const reset_value: number = 4;\nfunction reset_identity(input: number): number { return input; }\n";
    const raw_source = "const reset_value         = 4;\nfunction reset_identity(input        )         { return input; }\n";
    var raw_strings = string.StringTable.init(allocator);
    defer raw_strings.deinit();
    var typed_strings = string.StringTable.init(allocator);
    defer typed_strings.deinit();
    var raw_atoms = atom_table_mod.AtomTable.init(allocator);
    defer raw_atoms.deinit();
    var typed_atoms = atom_table_mod.AtomTable.init(allocator);
    defer typed_atoms.deinit();
    _ = try raw_atoms.intern("reset_prefix");
    _ = try typed_atoms.intern("reset_prefix");
    var raw = try Parser.init(allocator, raw_source, &raw_strings, &raw_atoms);
    defer raw.deinit();
    var typed = try Parser.initTyped(allocator, allocator, typed_source, &typed_strings, &typed_atoms);
    defer typed.deinit();
    const before = typed.js_parser.tokens_advanced;
    try std.testing.expectError(error.InvalidParserPhase, typed.generateParsed(allocator));
    try std.testing.expectError(error.InvalidParserPhase, typed.parse());
    try std.testing.expectError(error.InvalidParserPhase, typed.parseWithCodegenAllocator(allocator));
    try std.testing.expectEqual(before, typed.js_parser.tokens_advanced);
    try std.testing.expectEqual(@as(usize, 1), typed_atoms.count());
    try std.testing.expectError(error.InvalidParserPhase, raw.parseTypedIr());
    try std.testing.expectError(error.InvalidParserPhase, raw.generateParsed(allocator));
    const root = switch (try typed.parseTypedIr()) {
        .accepted => |node| node,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(NodeTag.program, typed.js_parser.nodes.getTag(root));
    try std.testing.expect(typed.code_gen == null);
    try std.testing.expectEqual(@as(usize, 0), typed.constants.items.len);
    try std.testing.expectEqual(@as(usize, 0), typed.getShapes().len);
    try std.testing.expectEqual(@as(usize, 1), typed.js_parser.type_store.annotations.items.len);
    try std.testing.expectEqualStrings("number", typed.js_parser.type_store.annotations.items[0].raw_span.text(typed_source));
    try std.testing.expectError(error.InvalidParserPhase, typed.parseTypedIr());
    const parsed_progress = typed.js_parser.tokens_advanced;
    const typed_code = try typed.generateParsed(allocator);
    defer typed.code_gen.?.freeOwnedConstantPayloads();
    const raw_code = try raw.parse();
    defer raw.code_gen.?.freeOwnedConstantPayloads();
    try std.testing.expect(typed_code.len > 0);
    try std.testing.expectEqualSlices(u8, raw_code, typed_code);
    try std.testing.expectEqual(raw.max_local_count, typed.max_local_count);
    const cache = @import("../bytecode_cache.zig");
    var raw_buffer: [4096]u8 = undefined;
    var typed_buffer: [4096]u8 = undefined;
    var raw_writer: cache.SliceWriter = .{ .buffer = &raw_buffer };
    var typed_writer: cache.SliceWriter = .{ .buffer = &typed_buffer };
    try cache.serializeConstants(raw.constants.items, &raw_writer, allocator);
    try cache.serializeConstants(typed.constants.items, &typed_writer, allocator);
    try std.testing.expect(raw_writer.pos > @sizeOf(u16));
    try std.testing.expectEqualSlices(u8, raw_writer.getWritten(), typed_writer.getWritten());

    try std.testing.expectEqual(raw_atoms.count(), typed_atoms.count());
    try std.testing.expectEqual(raw_atoms.next_id, typed_atoms.next_id);
    for (object.Atom.FIRST_DYNAMIC..raw_atoms.next_id) |atom_id| {
        const atom: object.Atom = @fromBackingInt(@intCast(atom_id));
        try std.testing.expectEqualStrings(raw_atoms.getName(atom).?, typed_atoms.getName(atom).?);
    }
    try std.testing.expectEqual(parsed_progress, typed.js_parser.tokens_advanced);
    try std.testing.expectError(error.InvalidParserPhase, typed.generateParsed(allocator));
    try std.testing.expectError(error.InvalidParserPhase, typed.parseTypedIr());
    try std.testing.expectEqual(parsed_progress, typed.js_parser.tokens_advanced);
    try std.testing.expectEqualSlices(u8, raw_code, typed_code);
}

test "typed compatibility refusals consume the parse attempt" {
    const sources = [_][]const u8{ "const value: any = 1;\n", "const value: number = ;\n" };
    for (sources, 0..) |source, index| {
        var strings = string.StringTable.init(std.testing.allocator);
        defer strings.deinit();
        var atoms = atom_table_mod.AtomTable.init(std.testing.allocator);
        defer atoms.deinit();
        var parser = try Parser.initTyped(std.testing.allocator, std.testing.allocator, source, &strings, &atoms);
        defer parser.deinit();
        switch (try parser.parseTypedIr()) {
            .terminal_admission_refused => try std.testing.expectEqual(@as(usize, 0), index),
            .parser_refused => try std.testing.expectEqual(@as(usize, 1), index),
            else => return error.TestUnexpectedResult,
        }
        const progress = parser.js_parser.tokens_advanced;
        try std.testing.expectError(error.InvalidParserPhase, parser.parseTypedIr());
        try std.testing.expectError(error.InvalidParserPhase, parser.generateParsed(std.testing.allocator));
        try std.testing.expectError(error.InvalidParserPhase, parser.parse());
        try std.testing.expectEqual(progress, parser.js_parser.tokens_advanced);
        try std.testing.expectEqual(null_node, parser.root_node);
        try std.testing.expect(parser.code_gen == null);
    }
}

test "typed generation failures clean published float and nested function payloads" {
    const source =
        "const top: number = 1.25;\n" ++
        "function outer(value: number): number {\n" ++
        "  function inner(input: number): number { return input + 2.5; }\n" ++
        "  const local: number = 3.75;\n" ++
        "  return inner(value) + local;\n" ++
        "}\n" ++
        "const tail: number = 4.125;\n";
    const Floors = struct { after_float: usize = 0, after_function: usize = 0, after_dispatch: usize = 0 };
    const WitnessAllocator = struct {
        backing: std.mem.Allocator,
        parser: *Parser,
        floors: *Floors,
        fail_after_dispatch: bool = false,

        fn allocator(self: *@This()) std.mem.Allocator {
            return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
        }
        fn alloc(context: *anyopaque, len: usize, alignment: std.mem.Alignment, return_address: usize) ?[*]u8 {
            const self: *@This() = @ptrCast(@alignCast(context));
            if (self.fail_after_dispatch) {
                if (self.parser.code_gen) |*generator| {
                    for (generator.constants.items) |constant| {
                        if (!constant.isExternPtr()) continue;
                        const function = constant.toExternPtr(bytecode.FunctionBytecode);
                        if (function.pattern_dispatch) |dispatch| {
                            if (dispatch.patterns.len == 0) continue;
                            self.floors.after_dispatch += 1;
                            return null;
                        }
                    }
                }
            }
            const memory = self.backing.rawAlloc(len, alignment, return_address);
            if (memory == null) {
                if (self.parser.code_gen) |*generator| {
                    var float_published = false;
                    var function_published = false;
                    for (generator.constants.items) |constant| {
                        float_published = float_published or constant.isFloat64();
                        function_published = function_published or constant.isExternPtr();
                    }
                    if (float_published) self.floors.after_float += 1;
                    if (function_published) self.floors.after_function += 1;
                }
            }
            return memory;
        }
        fn resize(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, return_address: usize) bool {
            const self: *@This() = @ptrCast(@alignCast(context));
            return self.backing.rawResize(memory, alignment, new_len, return_address);
        }
        fn remap(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, return_address: usize) ?[*]u8 {
            const self: *@This() = @ptrCast(@alignCast(context));
            return self.backing.rawRemap(memory, alignment, new_len, return_address);
        }
        fn free(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, return_address: usize) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.backing.rawFree(memory, alignment, return_address);
        }
    };
    const Context = struct {
        fn run(codegen_allocator: std.mem.Allocator, floors: *Floors) !void {
            var strings = string.StringTable.init(std.testing.allocator);
            defer strings.deinit();
            var atoms = atom_table_mod.AtomTable.init(std.testing.allocator);
            defer atoms.deinit();
            var parser = try Parser.initTyped(std.testing.allocator, std.testing.allocator, source, &strings, &atoms);
            defer parser.deinit();
            const root = switch (try parser.parseTypedIr()) {
                .accepted => |node| node,
                else => return error.TestUnexpectedResult,
            };
            var witness: WitnessAllocator = .{ .backing = codegen_allocator, .parser = &parser, .floors = floors };
            const code = parser.generateParsed(witness.allocator()) catch |err| {
                switch (err) {
                    error.OutOfMemory => {
                        try std.testing.expect(parser.code_gen == null);
                        try std.testing.expectEqual(@as(u8, 0), parser.max_local_count);
                        try std.testing.expectEqual(@as(usize, 0), parser.constants.items.len);
                        try std.testing.expectEqual(@as(usize, 0), parser.getShapes().len);
                        try std.testing.expectEqual(@as(usize, 0), parser.getLineTable().len);
                        try std.testing.expectEqual(root, parser.root_node);
                        try parser.js_parser.type_store.validateRuntimeOwners(std.testing.allocator, IrView.fromIRStore(&parser.js_parser.nodes, &parser.js_parser.constants));
                        try std.testing.expectError(error.InvalidParserPhase, parser.generateParsed(std.testing.allocator));
                        try std.testing.expectError(error.InvalidParserPhase, parser.parseTypedIr());
                    },
                    else => {},
                }
                return err;
            };
            defer parser.code_gen.?.freeOwnedConstantPayloads();
            try std.testing.expect(code.len > 0);
        }
    };
    var floors: Floors = .{};
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Context.run, .{&floors});
    try std.testing.expect(floors.after_float > 0);
    try std.testing.expect(floors.after_function > 0);

    const dispatch_source =
        "function handler(request: Request): Response {\n" ++
        "  const url: string = request.url;\n" ++
        "  return match (url) {\n" ++
        "    when '/api/a': Response.json({ ok: true }),\n" ++
        "    default: Response.text('missing')\n" ++
        "  };\n" ++
        "}\n" ++
        "const tail: number = 1.25;\n";
    var strings = string.StringTable.init(std.testing.allocator);
    defer strings.deinit();
    var atoms = atom_table_mod.AtomTable.init(std.testing.allocator);
    defer atoms.deinit();
    var parser = try Parser.initTyped(std.testing.allocator, std.testing.allocator, dispatch_source, &strings, &atoms);
    defer parser.deinit();
    const root = switch (try parser.parseTypedIr()) {
        .accepted => |node| node,
        else => return error.TestUnexpectedResult,
    };
    var witness: WitnessAllocator = .{ .backing = std.testing.allocator, .parser = &parser, .floors = &floors, .fail_after_dispatch = true };
    try std.testing.expectError(error.OutOfMemory, parser.generateParsed(witness.allocator()));
    try std.testing.expect(floors.after_dispatch > 0);
    try std.testing.expect(parser.code_gen == null);
    try std.testing.expectEqual(@as(usize, 0), parser.constants.items.len);
    try std.testing.expectEqual(root, parser.root_node);
    try std.testing.expectError(error.InvalidParserPhase, parser.generateParsed(std.testing.allocator));
}

test "typed parse and validation allocation failures consume the attempt" {
    const source = "const reset_value: number = 4;\nfunction identity(input: number): number { return input; }\n";
    const Context = struct {
        fn run(failing_allocator: std.mem.Allocator, type_failures: bool, after_parse: *usize, during_parse: *usize) !void {
            const allocator = if (type_failures) std.testing.allocator else failing_allocator;
            const type_allocator = if (type_failures) failing_allocator else std.testing.allocator;
            var strings = string.StringTable.init(std.testing.allocator);
            defer strings.deinit();
            var atoms = atom_table_mod.AtomTable.init(std.testing.allocator);
            defer atoms.deinit();
            var parser = try Parser.initTyped(allocator, type_allocator, source, &strings, &atoms);
            defer parser.deinit();
            const before = parser.js_parser.current.start;
            const outcome = parser.parseTypedIr() catch |err| {
                switch (err) {
                    error.OutOfMemory => {
                        const count = parser.js_parser.nodes.tags.items.len;
                        if (count > 0 and parser.js_parser.current.type == .eof and
                            parser.js_parser.nodes.getTag(@intCast(count - 1)) == .program)
                        {
                            after_parse.* += 1;
                        } else if (parser.js_parser.current.start > before) {
                            during_parse.* += 1;
                        }
                        const progress = parser.js_parser.tokens_advanced;
                        try std.testing.expectError(error.InvalidParserPhase, parser.parseTypedIr());
                        try std.testing.expectError(error.InvalidParserPhase, parser.generateParsed(std.testing.allocator));
                        try std.testing.expectError(error.InvalidParserPhase, parser.parse());
                        try std.testing.expectEqual(progress, parser.js_parser.tokens_advanced);
                        try std.testing.expectEqual(null_node, parser.root_node);
                        try std.testing.expect(parser.code_gen == null);
                        try std.testing.expectEqual(@as(usize, 0), parser.constants.items.len);
                    },
                    else => {},
                }
                return err;
            };
            switch (outcome) {
                .accepted => {},
                else => return error.TestUnexpectedResult,
            }
            try std.testing.expect(parser.root_node != null_node);
        }
    };
    var after_type_parse: usize = 0;
    var during_type_parse: usize = 0;
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Context.run, .{ true, &after_type_parse, &during_type_parse });
    try std.testing.expect(after_type_parse > 0);
    var after_runtime_parse: usize = 0;
    var during_runtime_parse: usize = 0;
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Context.run, .{ false, &after_runtime_parse, &during_runtime_parse });
    try std.testing.expect(during_runtime_parse > 0);
}
