//! JavaScript/JSX Parser
//!
//! Pratt parser producing IR nodes with integrated scope analysis.
//! Supports the ZigTS profile: ES5 plus selected ES6 syntax such as arrow
//! functions and template literals. Classes are rejected with diagnostics.

const std = @import("std");
const builtin = @import("builtin");
const tokenizer_mod = @import("tokenizer.zig");
const ir = @import("ir.zig");
const scope_mod = @import("scope.zig");
const error_mod = @import("error.zig");
const token_mod = @import("token.zig");
const object = @import("../object.zig");
const atom_table = @import("../atom_table.zig");

const Tokenizer = tokenizer_mod.Tokenizer;
const TokenizerState = tokenizer_mod.TokenizerState;
const Token = token_mod.Token;
const TokenType = token_mod.TokenType;
const SourceLocation = token_mod.SourceLocation;

const Node = ir.Node;
const NodeTag = ir.NodeTag;
const NodeIndex = ir.NodeIndex;
const NodeList = ir.NodeList;
const IRStore = ir.IRStore;
const ConstantPool = ir.ConstantPool;
const BindingRef = ir.BindingRef;
const BinaryOp = ir.BinaryOp;
const UnaryOp = ir.UnaryOp;
const FunctionFlags = ir.FunctionFlags;
const null_node = ir.null_node;

const ScopeAnalyzer = scope_mod.ScopeAnalyzer;
const ScopeKind = scope_mod.ScopeKind;
const Binding = scope_mod.Binding;

const ErrorList = error_mod.ErrorList;

pub const ExpressionProfile = enum {
    comptime_expression,
};

/// Operator precedence levels (higher = binds tighter)
const Precedence = enum(u8) {
    none = 0,
    comma = 1, // ,
    assignment = 2, // = += -= etc
    pipe_op = 3, // |>
    ternary = 4, // ?:
    nullish = 5, // ??
    or_op = 6, // ||
    and_op = 7, // &&
    bit_or = 8, // |
    bit_xor = 9, // ^
    bit_and = 10, // &
    equality = 11, // == != === !==
    comparison = 12, // < > <= >= in instanceof
    shift = 13, // << >> >>>
    additive = 14, // + -
    multiplicative = 15, // * / %
    exponent = 16, // **
    unary = 17, // ! ~ - + typeof void delete
    postfix = 18, // ++ --
    call = 19, // () [] .
    primary = 20,
};

/// Parser state
pub const Parser = struct {
    allocator: std.mem.Allocator,
    tokenizer: Tokenizer,
    source: []const u8,

    // Output
    nodes: IRStore,
    constants: ConstantPool,
    scopes: ScopeAnalyzer,
    errors: ErrorList,

    // Current state
    current: Token,
    previous: Token,

    // Optional atom table for interning identifiers/properties
    atoms: ?*atom_table.AtomTable,

    // Context flags
    in_loop: bool,
    in_function: bool,
    expression_profile: ?ExpressionProfile,
    /// The scrutinee of the `match` currently being parsed. A type-test pattern
    /// lowers to a narrowing test over it (spec 5.5), so the pattern parser
    /// needs the node the arms are selecting on.
    current_match_scrutinee: NodeIndex = null_node,

    // Guard composition: binding slot for `guard` imported from zttp:compose
    guard_binding_slot: ?u16 = null,
    // Pipe composition: binding slot for `pipe` imported from zttp:compose
    pipe_binding_slot: ?u16 = null,

    // Recursive-descent depth, shared across statement and expression nesting.
    // Bounds stack growth so pathological input (minified/generated JS with
    // thousands of nested parens, unary ops, or blocks) yields a clean
    // diagnostic instead of a stack-overflow SIGSEGV that crashes the host.
    recursion_depth: u32 = 0,

    /// Maximum recursive-descent nesting. Far above any hand-written handler
    /// (real code rarely nests past ~30) yet well under the worker-thread stack
    /// budget. Roughly V8's parser nesting tolerance.
    const max_recursion_depth: u32 = 512;

    /// Inline capacity for the short-lived NodeIndex temporaries below. These
    /// buffers sit on mutually recursive frames, so every byte is multiplied by
    /// `max_recursion_depth` against the stack budget.
    ///
    /// Target-conditional because the two builds have very different budgets
    /// and very different jobs. A native worker thread gets std.Thread's 16 MiB
    /// default, where 256 bytes per frame costs ~160 KB at the depth limit -
    /// negligible - and compile speed is on the cold-start path, so the full
    /// buffer is worth it. The wasm64-freestanding analyzer takes the linker
    /// default (~1 MiB) and exists to produce diagnostics, not to be fast:
    /// there the fat buffers were measured to drop the nesting cliff from ~349
    /// to 288 levels, so inputs nesting inside that window trapped instead of
    /// returning the `nesting_too_deep` diagnostic the guard promises. Keeping
    /// wasm frames slim preserves the guard.
    ///
    /// Re-derive both numbers if the buffer set or frame layout changes.
    const temp_list_stack_bytes: usize = if (@import("builtin").target.cpu.arch.isWasm()) 32 else 256;

    pub fn init(allocator: std.mem.Allocator, source: []const u8) !Parser {
        return initWithProfile(allocator, source, null);
    }

    pub fn initExpression(allocator: std.mem.Allocator, source: []const u8, profile: ExpressionProfile) !Parser {
        return initWithProfile(allocator, source, profile);
    }

    fn initWithProfile(allocator: std.mem.Allocator, source: []const u8, profile: ?ExpressionProfile) !Parser {
        var nodes = IRStore.initCapacity(allocator, source.len);
        errdefer nodes.deinit();

        var parser = Parser{
            .allocator = allocator,
            .tokenizer = Tokenizer.init(source),
            .source = source,
            .nodes = nodes,
            .constants = ConstantPool.init(allocator),
            .scopes = try ScopeAnalyzer.init(allocator),
            .errors = ErrorList.init(allocator, source),
            .current = undefined,
            .previous = undefined,
            .atoms = null,
            .in_loop = false,
            .in_function = false,
            .expression_profile = profile,
        };
        // Prime the parser with first token
        parser.advance();
        return parser;
    }

    pub fn deinit(self: *Parser) void {
        self.nodes.deinit();
        self.constants.deinit();
        self.scopes.deinit();
        self.errors.deinit();
    }

    pub fn setAtomTable(self: *Parser, atoms: *atom_table.AtomTable) void {
        self.atoms = atoms;
    }

    /// Parse the entire program
    pub fn parse(self: *Parser) anyerror!NodeIndex {
        var stmts: std.ArrayList(NodeIndex) = .empty;
        defer stmts.deinit(self.allocator);

        while (!self.check(.eof)) {
            if (self.parseStatement()) |stmt| {
                try stmts.append(self.allocator, stmt);
            } else |err| {
                // An error the list could not record is an out-of-memory, not a
                // syntax error. Report it as one: `hasErrors` counts it, so the
                // loop stops, but `err` would name the wrong cause. Without this
                // the whole loop used to spin forever, because a truncated error
                // left `hasErrors` false and `synchronize` returns without
                // advancing when the current token starts a statement.
                if (self.errors.outOfMemory()) return error.OutOfMemory;
                // If there are recorded errors, fail immediately
                if (self.errors.hasErrors()) {
                    return err;
                }
                // Otherwise try to recover for better error messages
                self.synchronize();
            }
        }

        // If any errors were recorded during parsing, fail
        if (self.errors.hasErrors()) {
            return error.ParseError;
        }

        // Create program node
        const stmts_count = try self.checkedU16Count(.{ .line = 1, .column = 1, .offset = 0 }, stmts.items.len, "too many top-level statements; limit is 65535");
        const stmts_start = try self.addStmtList(stmts.items);
        return try self.nodes.add(.{
            .tag = .program,
            .loc = .{ .line = 1, .column = 1, .offset = 0 },
            .data = .{ .block = .{
                .stmts_start = stmts_start,
                .stmts_count = stmts_count,
                .scope_id = 0,
            } },
        });
    }

    /// Parse exactly one expression with the profile selected by
    /// `initExpression`, using the same Pratt parser as full programs.
    pub fn parseExpressionOnly(self: *Parser) anyerror!NodeIndex {
        if (self.expression_profile == null) return error.InvalidParserMode;
        if (self.check(.eof)) {
            self.errors.addErrorAt(.unexpected_eof, self.current, "expected expression");
            return error.UnexpectedToken;
        }

        const root = try self.parseExpression(.none);
        if (!self.check(.eof)) {
            self.errors.addExpectedError(self.current, "end of expression");
            return error.UnexpectedToken;
        }
        if (self.errors.hasErrors()) return error.ParseError;
        return root;
    }

    /// Parse one primary/unary/aggregate root and leave trailing input alone.
    /// This is profile-only because it exists for the legacy JSON.parse
    /// compatibility contract; full programs must continue to consume their
    /// complete grammar.
    pub fn parseExpressionPrefix(self: *Parser) anyerror!NodeIndex {
        if (self.expression_profile == null) return error.InvalidParserMode;
        if (self.check(.eof)) {
            self.errors.addErrorAt(.unexpected_eof, self.current, "expected expression");
            return error.UnexpectedToken;
        }

        const root = try self.parseExpression(.call);
        if (self.errors.hasErrors()) return error.ParseError;
        return root;
    }

    fn recursionLimit(self: *const Parser) u32 {
        return if (self.expression_profile != null) 64 else max_recursion_depth;
    }

    // ============ Statement Parsing ============

    fn parseStatement(self: *Parser) anyerror!NodeIndex {
        self.recursion_depth += 1;
        defer self.recursion_depth -= 1;
        if (self.recursion_depth > self.recursionLimit()) {
            self.errors.addErrorAt(.nesting_too_deep, self.current, "statements nest too deeply; simplify or split (nesting limit is 512)");
            return error.ParseError;
        }
        return switch (self.current.type) {
            .kw_var, .kw_let, .kw_const => self.parseVarDeclaration(),
            .kw_function => self.parseFunctionDeclaration(),
            .kw_if => self.parseIfStatement(),
            .kw_while => {
                self.errors.addErrorAt(.unsupported_feature, self.current, "'while' is not supported; use 'for-of' with a finite collection instead");
                self.advance();
                return error.ParseError;
            },
            .kw_do => {
                self.errors.addErrorAt(.unsupported_feature, self.current, "'do-while' is not supported; use 'for-of' with a finite collection instead");
                self.advance();
                return error.ParseError;
            },
            .kw_for => self.parseForStatement(),
            .kw_return => self.parseReturnStatement(),
            .kw_break => self.parseBreakStatement(),
            .kw_continue => self.parseContinueStatement(),
            .kw_throw => {
                self.errors.addErrorAt(.unsupported_feature, self.current, "'throw' is not supported; use Result types for error handling");
                self.advance();
                return error.ParseError;
            },
            .kw_try => {
                self.errors.addErrorAt(.unsupported_feature, self.current, "'try/catch' is not supported; use Result types for error handling");
                self.advance();
                return error.ParseError;
            },
            .kw_switch => {
                self.errors.addErrorAt(.unsupported_feature, self.current, "'switch' is not supported; use 'match' expression instead");
                self.advance();
                return error.ParseError;
            },
            .kw_assert => self.parseAssertStatement(),
            // class keyword in statement context: class Foo { }
            // Catches class declarations (both .js and .ts files after stripping)
            .kw_class => {
                self.errors.addErrorAt(.unsupported_feature, self.current, "'class' is not supported; use plain objects and functions instead");
                self.advance();
                return error.ParseError;
            },
            .kw_enum => {
                self.errors.addErrorAt(.unsupported_feature, self.current, "'enum' is not supported; use object literals or discriminated unions instead");
                self.advance();
                return error.ParseError;
            },
            .kw_implements => {
                self.errors.addErrorAt(.unsupported_feature, self.current, "'implements' is not supported; use duck typing or runtime checks instead");
                self.advance();
                return error.ParseError;
            },
            .kw_public, .kw_private, .kw_protected => {
                self.errors.addErrorAt(.unsupported_feature, self.current, "access modifiers are not supported; use naming conventions (e.g., _private) instead");
                self.advance();
                return error.ParseError;
            },
            .at_sign => {
                self.errors.addErrorAt(.unsupported_feature, self.current, "'@decorator' syntax is not supported; use function composition instead");
                self.advance();
                return error.ParseError;
            },
            .kw_import => self.parseImportDeclaration(),
            .kw_export => self.parseExportDeclaration(),
            .lbrace => self.parseBlock(),
            .semicolon => self.parseEmptyStatement(),
            .kw_debugger => self.parseDebuggerStatement(),
            else => {
                // Check for TypeScript namespace/module declarations
                if (self.current.type == .identifier) {
                    const name = self.current.text(self.source);
                    if (std.mem.eql(u8, name, "namespace") or std.mem.eql(u8, name, "module")) {
                        self.errors.addErrorAt(.unsupported_feature, self.current, "'namespace' is not supported; use ES6 modules instead");
                        self.advance();
                        return error.ParseError;
                    }
                }
                return self.parseExpressionStatement();
            },
        };
    }

    fn parseVarDeclaration(self: *Parser) anyerror!NodeIndex {
        // Reject 'var' - only 'let' and 'const' are supported
        if (self.current.type == .kw_var) {
            self.errors.addErrorAt(.unsupported_feature, self.current, "'var' is not supported; use 'let' or 'const' instead");
            self.advance(); // consume 'var' so synchronize() doesn't loop on it
            return error.ParseError;
        }

        const kind: Node.VarDecl.VarKind = switch (self.current.type) {
            .kw_let => .let,
            .kw_const => .@"const",
            else => unreachable,
        };
        const loc = self.current.location();
        self.advance();

        // Check for const enum (TypeScript)
        if (kind == .@"const" and self.check(.kw_enum)) {
            self.errors.addErrorAt(.unsupported_feature, self.current, "'const enum' is not supported; use object literals or discriminated unions instead");
            self.advance();
            return error.ParseError;
        }

        // Check for destructuring pattern
        if (self.check(.lbrace)) {
            return self.parseDestructuringDecl(loc, kind, .object);
        } else if (self.check(.lbracket)) {
            return self.parseDestructuringDecl(loc, kind, .array);
        }

        // Simple identifier binding
        const name = try self.expectIdentifier("variable name");
        const name_atom = try self.addAtom(name.text(self.source));

        // Declare in scope
        const binding = self.scopes.declareBinding(
            name.text(self.source),
            name_atom,
            .variable,
            kind == .@"const",
        ) catch {
            self.errorAtCurrent("too many local variables");
            return error.TooManyLocals;
        };

        // Parse initializer
        var init_node: NodeIndex = null_node;
        if (self.match(.assign)) {
            init_node = try self.parseExpression(.assignment);
        } else if (kind == .@"const") {
            self.errorAtCurrent("const declarations must have an initializer");
        }

        try self.expectSemicolon();

        return try self.nodes.add(.{
            .tag = .var_decl,
            .loc = loc,
            .data = .{ .var_decl = .{
                .binding = binding,
                .pattern = null_node,
                .init = init_node,
                .kind = kind,
            } },
        });
    }

    const PatternKind = enum { object, array };

    fn parseDestructuringDecl(self: *Parser, loc: SourceLocation, kind: Node.VarDecl.VarKind, pattern_kind: PatternKind) anyerror!NodeIndex {
        // Parse the pattern
        const pattern = switch (pattern_kind) {
            .object => try self.parseObjectPattern(),
            .array => try self.parseArrayPattern(),
        };

        // Require initializer for destructuring
        try self.expect(.assign, "'=' after destructuring pattern");
        const init_node = try self.parseExpression(.assignment);

        try self.expectSemicolon();

        // Create a special binding for destructuring (slot 255 = pattern)
        const dummy_binding = BindingRef{
            .scope_id = 0,
            .slot = 255,
            .name_atom = 0,
            .kind = .local,
        };

        return try self.nodes.add(.{
            .tag = .var_decl,
            .loc = loc,
            .data = .{ .var_decl = .{
                .binding = dummy_binding,
                .pattern = pattern,
                .init = init_node,
                .kind = kind,
            } },
        });
    }

    fn parseObjectPattern(self: *Parser) anyerror!NodeIndex {
        const loc = self.current.location();
        self.advance(); // consume '{'

        var elements = std.ArrayList(NodeIndex).empty;
        defer elements.deinit(self.allocator);

        while (!self.check(.rbrace) and !self.check(.eof)) {
            const elem = try self.parseObjectPatternElement();
            try elements.append(self.allocator, elem);

            if (!self.match(.comma)) break;
        }

        try self.expect(.rbrace, "'}' to close object pattern");

        const elements_count = try self.checkedU16Count(loc, elements.items.len, "too many object pattern elements; limit is 65535");
        const elements_start = try self.addNodeList(elements.items);

        return try self.nodes.add(.{
            .tag = .object_pattern,
            .loc = loc,
            .data = .{ .array = .{
                .elements_start = elements_start,
                .elements_count = elements_count,
                .has_spread = false,
            } },
        });
    }

    fn parseObjectPatternElement(self: *Parser) anyerror!NodeIndex {
        const loc = self.current.location();

        // Check for rest element: ...rest
        if (self.match(.spread)) {
            self.errors.addErrorAt(.unsupported_feature, self.current, "rest element in object destructuring is not supported; bind the remaining properties explicitly instead");
            const name = try self.expectIdentifier("identifier after '...'");
            const name_atom = try self.addAtom(name.text(self.source));

            const binding = self.scopes.declareBinding(
                name.text(self.source),
                name_atom,
                .variable,
                false,
            ) catch {
                self.errorAtCurrent("too many local variables");
                return error.TooManyLocals;
            };

            return try self.nodes.add(.{
                .tag = .pattern_rest,
                .loc = loc,
                .data = .{ .pattern_elem = .{
                    .kind = .rest,
                    .binding = binding,
                    .key = null_node,
                    .key_atom = 0,
                    .default_value = null_node,
                } },
            });
        }

        // Property name (could be renamed: { name: localName })
        const key_name = try self.expectPropertyIdentifier("property name in object pattern");
        const key_atom_for_binding = try self.addAtom(key_name.text(self.source));

        var local_name = key_name;
        var local_atom = key_atom_for_binding;

        // Check for rename: { name: localName }
        if (self.match(.colon)) {
            // Check for nested pattern
            if (self.check(.lbrace)) {
                const nested = try self.parseObjectPattern();

                // A nested pattern may carry a default: `{ data: { x } = {} }`.
                var nested_default: NodeIndex = null_node;
                if (self.match(.assign)) {
                    nested_default = try self.parseExpression(.assignment);
                }

                return try self.nodes.add(.{
                    .tag = .pattern_element,
                    .loc = loc,
                    .data = .{
                        .pattern_elem = .{
                            .kind = .object,
                            .binding = .{ .scope_id = 0, .slot = 255, .name_atom = 0, .kind = .local },
                            .key = nested, // Nested pattern
                            .key_atom = key_atom_for_binding, // property-name atom for get_field
                            .default_value = nested_default,
                        },
                    },
                });
            } else if (self.check(.lbracket)) {
                const nested = try self.parseArrayPattern();

                var nested_default: NodeIndex = null_node;
                if (self.match(.assign)) {
                    nested_default = try self.parseExpression(.assignment);
                }

                return try self.nodes.add(.{
                    .tag = .pattern_element,
                    .loc = loc,
                    .data = .{
                        .pattern_elem = .{
                            .kind = .array,
                            .binding = .{ .scope_id = 0, .slot = 255, .name_atom = 0, .kind = .local },
                            .key = nested, // Nested pattern
                            .key_atom = key_atom_for_binding, // property-name atom for get_field
                            .default_value = nested_default,
                        },
                    },
                });
            }

            // Simple rename
            local_name = try self.expectIdentifier("local name after ':'");
            local_atom = try self.addAtom(local_name.text(self.source));
        }

        // Declare the local binding
        const binding = self.scopes.declareBinding(
            local_name.text(self.source),
            local_atom,
            .variable,
            false,
        ) catch {
            self.errorAtCurrent("too many local variables");
            return error.TooManyLocals;
        };

        // Check for default value: { x = 10 }
        var default_value: NodeIndex = null_node;
        if (self.match(.assign)) {
            default_value = try self.parseExpression(.assignment);
        }

        return try self.nodes.add(.{
            .tag = .pattern_element,
            .loc = loc,
            .data = .{
                .pattern_elem = .{
                    .kind = .simple,
                    .binding = binding,
                    .key = null_node,
                    .key_atom = key_atom_for_binding, // property-name atom for get_field
                    .default_value = default_value,
                },
            },
        });
    }

    fn parseArrayPattern(self: *Parser) anyerror!NodeIndex {
        const loc = self.current.location();
        self.advance(); // consume '['

        var elements = std.ArrayList(NodeIndex).empty;
        defer elements.deinit(self.allocator);

        while (!self.check(.rbracket) and !self.check(.eof)) {
            // Handle holes: [a, , b]
            if (self.check(.comma)) {
                // Hole - push null_node
                try elements.append(self.allocator, null_node);
                self.advance();
                continue;
            }

            const elem = try self.parseArrayPatternElement();
            try elements.append(self.allocator, elem);

            if (!self.match(.comma)) break;
        }

        try self.expect(.rbracket, "']' to close array pattern");

        const elements_count = try self.checkedU16Count(loc, elements.items.len, "too many array pattern elements; limit is 65535");
        const elements_start = try self.addNodeList(elements.items);

        return try self.nodes.add(.{
            .tag = .array_pattern,
            .loc = loc,
            .data = .{ .array = .{
                .elements_start = elements_start,
                .elements_count = elements_count,
                .has_spread = false,
            } },
        });
    }

    fn parseArrayPatternElement(self: *Parser) anyerror!NodeIndex {
        const loc = self.current.location();

        // Check for rest element: ...rest
        if (self.match(.spread)) {
            self.errors.addErrorAt(.unsupported_feature, self.current, "rest element in array destructuring is not supported; index the remaining elements explicitly instead");
            const name = try self.expectIdentifier("identifier after '...'");
            const name_atom = try self.addAtom(name.text(self.source));

            const binding = self.scopes.declareBinding(
                name.text(self.source),
                name_atom,
                .variable,
                false,
            ) catch {
                self.errorAtCurrent("too many local variables");
                return error.TooManyLocals;
            };

            return try self.nodes.add(.{
                .tag = .pattern_rest,
                .loc = loc,
                .data = .{ .pattern_elem = .{
                    .kind = .rest,
                    .binding = binding,
                    .key = null_node,
                    .key_atom = 0,
                    .default_value = null_node,
                } },
            });
        }

        // Check for nested patterns
        if (self.check(.lbrace)) {
            const nested = try self.parseObjectPattern();
            return try self.nodes.add(.{
                .tag = .pattern_element,
                .loc = loc,
                .data = .{ .pattern_elem = .{
                    .kind = .object,
                    .binding = .{ .scope_id = 0, .slot = 255, .name_atom = 0, .kind = .local },
                    .key = nested,
                    .key_atom = 0,
                    .default_value = null_node,
                } },
            });
        } else if (self.check(.lbracket)) {
            const nested = try self.parseArrayPattern();
            return try self.nodes.add(.{
                .tag = .pattern_element,
                .loc = loc,
                .data = .{ .pattern_elem = .{
                    .kind = .array,
                    .binding = .{ .scope_id = 0, .slot = 255, .name_atom = 0, .kind = .local },
                    .key = nested,
                    .key_atom = 0,
                    .default_value = null_node,
                } },
            });
        }

        // Simple identifier
        const name = try self.expectIdentifier("identifier in array pattern");
        const name_atom = try self.addAtom(name.text(self.source));

        const binding = self.scopes.declareBinding(
            name.text(self.source),
            name_atom,
            .variable,
            false,
        ) catch {
            self.errorAtCurrent("too many local variables");
            return error.TooManyLocals;
        };

        // Check for default value: [x = 10]
        var default_value: NodeIndex = null_node;
        if (self.match(.assign)) {
            default_value = try self.parseExpression(.assignment);
        }

        return try self.nodes.add(.{
            .tag = .pattern_element,
            .loc = loc,
            .data = .{ .pattern_elem = .{
                .kind = .simple,
                .binding = binding,
                .key = null_node,
                .key_atom = 0,
                .default_value = default_value,
            } },
        });
    }

    fn parseFunctionDeclaration(self: *Parser) anyerror!NodeIndex {
        const loc = self.current.location();
        self.advance(); // consume 'function'

        const flags = FunctionFlags{};

        // Generators are not supported: `yield` is rejected below, so a
        // `function*` could only ever produce an object nothing can advance.
        // Reject it at the same place, with the same shape of diagnostic.
        if (self.match(.star)) {
            self.errors.addErrorAt(.unsupported_feature, self.current, "generators are not supported; 'function*' has no supported use");
            return error.ParseError;
        }

        // Function name
        const name = try self.expectIdentifier("function name");
        const name_atom = try self.addAtom(name.text(self.source));

        // Declare function in current scope (hoisted)
        const binding = self.scopes.declareBinding(
            name.text(self.source),
            name_atom,
            .function,
            false,
        ) catch {
            self.errorAtCurrent("too many local variables");
            return error.TooManyLocals;
        };

        // Dev-only trace gate. `std.c.getenv` needs libc and `std.debug.print`
        // needs a stderr stack; both are absent on freestanding/wasm, so the
        // whole block is comptime-elided for the analyzer build.
        if (comptime builtin.target.os.tag != .freestanding) {
            if (std.c.getenv("ZTS_TRACE_FUN_DECL") != null) {
                const scope = self.scopes.getCurrentScope();
                std.debug.print(
                    "[fun_decl] name={s} scope={} kind={s}\n",
                    .{ name.text(self.source), self.scopes.current_scope, @tagName(scope.kind) },
                );
            }
        }

        // Parse function body
        const func_node = try self.parseFunctionBody(name_atom, flags);

        // Create function declaration node
        // Note: function declarations use .let for binding (no var support)
        return try self.nodes.add(.{
            .tag = .function_decl,
            .loc = loc,
            .data = .{ .var_decl = .{
                .binding = binding,
                .pattern = null_node,
                .init = func_node,
                .kind = .let,
            } },
        });
    }

    /// Parse function parameters and body, producing a FunctionDecl node.
    ///
    /// This handles:
    /// 1. Pushing a new function scope for local bindings
    /// 2. Parsing parameter list (including rest params, default values)
    /// 3. Registering parameters as local bindings in the new scope
    /// 4. Parsing the function body (block or expression for arrows)
    /// 5. Collecting upvalue references for closures
    ///
    /// Upvalues: When a variable reference cannot be resolved in the current
    /// function's scope, it's captured as an upvalue. The scope manager tracks
    /// which outer variables are referenced, and this info is stored in the
    /// FunctionDecl node for codegen.
    ///
    /// Arrow functions: If the body starts with '{', parse as block statement.
    /// Otherwise parse as expression and wrap in implicit return.
    fn parseFunctionBody(self: *Parser, name_atom: u16, flags: FunctionFlags) anyerror!NodeIndex {
        const loc = self.current.location();

        // Enter function scope
        const scope_id = try self.scopes.pushScope(.function);
        const was_in_function = self.in_function;
        self.in_function = true;

        // Error returns while parsing parameters or the body would otherwise
        // leave `in_function` set and the function scope pushed. An enclosing
        // parseBlock swallows the error and keeps parsing against an unbalanced
        // scope stack, which reports invented follow-on errors such as
        // "'return' outside of function" for code that is plainly inside one.
        // The flag is needed because the success path restores explicitly and
        // fallible work follows it; a bare errdefer would pop a second time.
        var scope_active = true;
        errdefer if (scope_active) {
            self.in_function = was_in_function;
            self.scopes.popScope();
        };

        // Parse parameters
        try self.expect(.lparen, "'('");
        var params_sfa = std.heap.stackFallback(temp_list_stack_bytes, self.allocator);
        const params_alloc = params_sfa.get();
        var params = std.ArrayList(NodeIndex).empty;
        defer params.deinit(params_alloc);

        var param_flags = flags;

        if (!self.check(.rparen)) {
            while (true) {
                // Check for rest parameter
                if (self.match(.spread)) {
                    self.errors.addErrorAt(.unsupported_feature, self.previous, "rest parameters ('...args') are not supported; accept an explicit array parameter instead");
                    param_flags.has_rest_param = true;
                }

                if (self.check(.lbrace) or self.check(.lbracket)) {
                    self.errors.addErrorAt(.unsupported_feature, self.current, "destructured parameters are not supported; destructure inside the body instead");
                    return error.ParseError;
                }

                const param_name = try self.expectIdentifier("parameter name");
                const param_atom = try self.addAtom(param_name.text(self.source));

                const param_binding = self.scopes.declareBinding(
                    param_name.text(self.source),
                    param_atom,
                    .parameter,
                    false,
                ) catch {
                    self.errorAtCurrent("too many parameters");
                    return error.TooManyLocals;
                };

                // Check for default value. Default params are accepted here and
                // flagged downstream by the strict checker's
                // `canonical_default_parameter` rule (which `normalize` can also
                // auto-fix); rejecting them at parse time would bypass that.
                var default_value: NodeIndex = null_node;
                if (self.match(.assign)) {
                    param_flags.has_default_params = true;
                    default_value = try self.parseExpression(.assignment);
                }

                const param_node = try self.nodes.add(.{
                    .tag = .pattern_element,
                    .loc = param_name.location(),
                    .data = .{ .pattern_elem = .{
                        .kind = if (param_flags.has_rest_param) .rest else .simple,
                        .binding = param_binding,
                        .key = null_node,
                        .key_atom = 0,
                        .default_value = default_value,
                    } },
                });
                try params.append(params_alloc, param_node);

                if (param_flags.has_rest_param) break; // Rest must be last
                if (!self.match(.comma)) break;
                if (self.check(.rparen)) break; // Trailing comma
            }
        }
        try self.expect(.rparen, "')'");

        // Parse body
        const body = try self.parseBlock();

        self.in_function = was_in_function;
        self.scopes.popScope();
        scope_active = false;

        // Create function expression node
        const params_count = try self.checkedU8Count(loc, params.items.len, "too many function parameters; limit is 255");
        const params_start = if (params.items.len > 0)
            try self.addNodeList(params.items)
        else
            null_node;

        return try self.nodes.add(.{
            .tag = .function_expr,
            .loc = loc,
            .data = .{ .function = .{
                .scope_id = scope_id,
                .name_atom = name_atom,
                .params_start = params_start,
                .params_count = params_count,
                .body = body,
                .flags = param_flags,
            } },
        });
    }

    fn parseIfStatement(self: *Parser) anyerror!NodeIndex {
        const loc = self.current.location();
        self.advance(); // consume 'if'

        try self.expect(.lparen, "'('");
        const condition = try self.parseExpression(.none);
        try self.expect(.rparen, "')'");

        const then_branch = try self.parseStatement();

        var else_branch: NodeIndex = null_node;
        if (self.match(.kw_else)) {
            else_branch = try self.parseStatement();
        }

        return try self.nodes.add(.{
            .tag = .if_stmt,
            .loc = loc,
            .data = .{ .if_stmt = .{
                .condition = condition,
                .then_branch = then_branch,
                .else_branch = else_branch,
            } },
        });
    }

    /// Parse for/for-of statement.
    ///
    /// Supports two forms:
    /// 1. C-style for: for (init; condition; update) body
    /// 2. For-of: for (let/const x of iterable) body (arrays only, not objects)
    ///
    /// Note: 'var' is rejected - only 'let' and 'const' are supported.
    ///
    /// For-of detection: If initializer is a declaration followed by 'of' keyword,
    /// we parse as for-of. Otherwise we expect semicolons and parse as C-style.
    ///
    /// Scope: A loop scope is pushed for the initializer, allowing 'let' bindings
    /// to be block-scoped to the loop body.
    fn parseForStatement(self: *Parser) anyerror!NodeIndex {
        const loc = self.current.location();
        self.advance(); // consume 'for'

        try self.expect(.lparen, "'('");

        // Enter loop scope for let/const declarations
        _ = try self.scopes.pushScope(.for_loop);

        // Parse initializer
        var init_node: NodeIndex = null_node;
        var is_for_of = false;
        var is_const = false;

        if (!self.check(.semicolon)) {
            // Reject 'var' in for loops - only 'let' and 'const' are supported
            if (self.check(.kw_var)) {
                self.errors.addErrorAt(.unsupported_feature, self.current, "'var' is not supported; use 'let' or 'const' instead");
                self.advance(); // consume 'var' so synchronize() doesn't loop on it
                return error.ParseError;
            }

            if (self.check(.kw_let) or self.check(.kw_const)) {
                is_const = self.current.type == .kw_const;
                const kind: Node.VarDecl.VarKind = switch (self.current.type) {
                    .kw_let => .let,
                    .kw_const => .@"const",
                    else => unreachable,
                };
                self.advance();

                const name = try self.expectIdentifier("variable name");
                const name_atom = try self.addAtom(name.text(self.source));
                const binding = self.scopes.declareBinding(
                    name.text(self.source),
                    name_atom,
                    .variable,
                    is_const,
                ) catch return error.TooManyLocals;

                // Check for for-in/for-of
                if (self.check(.kw_in)) {
                    // for-in is not supported - only for-of
                    self.errors.addErrorAt(.unsupported_feature, self.current, "'for-in' is not supported; use 'for-of' to iterate over values instead");
                    self.scopes.popScope();
                    return error.ParseError;
                } else if (self.check(.kw_of)) {
                    is_for_of = true;
                    self.advance();
                    const iterable = try self.parseExpression(.none);
                    try self.expect(.rparen, "')'");

                    const was_in_loop = self.in_loop;
                    self.in_loop = true;
                    const body = try self.parseStatement();
                    self.in_loop = was_in_loop;

                    self.scopes.popScope();

                    return try self.nodes.add(.{
                        .tag = .for_of_stmt,
                        .loc = loc,
                        .data = .{ .for_iter = .{
                            .is_for_in = false,
                            .binding = binding,
                            .pattern = null_node,
                            .iterable = iterable,
                            .body = body,
                            .is_const = is_const,
                        } },
                    });
                }

                // Regular for loop with var declaration
                var var_init: NodeIndex = null_node;
                if (self.match(.assign)) {
                    var_init = try self.parseExpression(.assignment);
                }

                init_node = try self.nodes.add(.{
                    .tag = .var_decl,
                    .loc = name.location(),
                    .data = .{ .var_decl = .{
                        .binding = binding,
                        .pattern = null_node,
                        .init = var_init,
                        .kind = kind,
                    } },
                });
            } else {
                init_node = try self.parseExpression(.none);
            }
        }

        // C-style for loops are not supported - only for-of
        self.scopes.popScope();
        self.errors.addErrorAt(.unsupported_feature, self.previous, "C-style 'for' loops are not supported; use 'for (let x of array)' or 'for (let i of range(n))' instead");
        return error.ParseError;
    }

    fn parseReturnStatement(self: *Parser) anyerror!NodeIndex {
        const loc = self.current.location();
        self.advance(); // consume 'return'

        if (!self.in_function) {
            self.errorAt(loc, "'return' outside of function");
        }

        var value: ?NodeIndex = null;
        // ASI: a newline between 'return' and the next token acts as an implicit semicolon.
        // Only parse an expression when on the same line as the 'return' keyword.
        if (self.current.line <= self.previous.line and
            !self.check(.semicolon) and !self.check(.rbrace) and !self.check(.eof))
        {
            value = try self.parseExpression(.none);
        }
        try self.expectSemicolon();

        return try self.nodes.add(.{
            .tag = .return_stmt,
            .loc = loc,
            .data = .{ .opt_value = value },
        });
    }

    fn parseBreakStatement(self: *Parser) anyerror!NodeIndex {
        const loc = self.current.location();
        self.advance(); // consume 'break'

        if (!self.in_loop) {
            self.errorAt(loc, "'break' outside of loop");
        }

        // Labeled break is not supported
        if (self.check(.identifier)) {
            self.errors.addErrorAt(.unsupported_feature, self.current, "'labeled break' is not supported; use a conditional instead");
            self.advance();
            return error.ParseError;
        }
        try self.expectSemicolon();

        return try self.nodes.add(.{
            .tag = .break_stmt,
            .loc = loc,
            .data = .{ .opt_label = null },
        });
    }

    fn parseContinueStatement(self: *Parser) anyerror!NodeIndex {
        const loc = self.current.location();
        self.advance(); // consume 'continue'

        if (!self.in_loop) {
            self.errorAt(loc, "'continue' outside of loop");
        }

        // Labeled continue is not supported
        if (self.check(.identifier)) {
            self.errors.addErrorAt(.unsupported_feature, self.current, "'labeled continue' is not supported; use a conditional instead");
            self.advance();
            return error.ParseError;
        }
        try self.expectSemicolon();

        return try self.nodes.add(.{
            .tag = .continue_stmt,
            .loc = loc,
            .data = .{ .opt_label = null },
        });
    }

    fn parseAssertStatement(self: *Parser) anyerror!NodeIndex {
        const loc = self.current.location();
        self.advance(); // consume 'assert'

        const condition = try self.parseExpression(.none);

        // Optional comma-separated error expression: assert expr, errorExpr;
        var error_expr: NodeIndex = null_node;
        if (self.match(.comma)) {
            error_expr = try self.parseExpression(.none);
        }

        try self.expectSemicolon();
        return try self.nodes.add(.{
            .tag = .assert_stmt,
            .loc = loc,
            .data = .{ .assert_stmt = .{
                .condition = condition,
                .error_expr = error_expr,
            } },
        });
    }

    fn parseMatchExpression(self: *Parser) anyerror!NodeIndex {
        const loc = self.current.location();
        self.advance(); // consume 'match'

        try self.expect(.lparen, "'('");
        const discriminant = try self.parseExpression(.none);
        try self.expect(.rparen, "')'");
        try self.expect(.lbrace, "'{'");

        const outer_scrutinee = self.current_match_scrutinee;
        self.current_match_scrutinee = discriminant;
        defer self.current_match_scrutinee = outer_scrutinee;

        var arms: [255]NodeIndex = undefined;
        var arms_len: u8 = 0;

        while (!self.check(.rbrace) and !self.check(.eof)) {
            const arm_loc = self.current.location();
            var pattern: NodeIndex = null_node;

            // One scope per arm, opened before the pattern so a binding it
            // declares is live for this arm's body and dead for the next one.
            _ = try self.scopes.pushScope(.block);
            errdefer self.scopes.popScope();

            if (self.match(.kw_when)) {
                pattern = try self.parseMatchPattern();
            } else if (self.match(.kw_default)) {
                // default arm - pattern stays null_node
            } else {
                self.scopes.popScope();
                self.errorAtCurrent("expected 'when' or 'default'");
                break;
            }
            try self.expect(.colon, "':'");

            const body = try self.parseExpression(.none);
            self.scopes.popScope();

            const arm_node = try self.nodes.add(.{
                .tag = .match_arm,
                .loc = arm_loc,
                .data = .{ .match_arm = .{
                    .pattern = pattern,
                    .body = body,
                } },
            });
            if (arms_len >= arms.len) {
                self.errorAt(arm_loc, "too many match arms; limit is 255");
                return error.ParseError;
            }
            arms[arms_len] = arm_node;
            arms_len += 1;

            if (!self.check(.rbrace)) {
                _ = self.match(.comma);
            }
        }

        try self.expect(.rbrace, "'}'");

        if (arms_len == 0) {
            self.errorAt(loc, "match expression must have at least one arm");
            return error.ParseError;
        }

        const arms_start = try self.addNodeList(arms[0..arms_len]);

        return try self.nodes.add(.{
            .tag = .match_expr,
            .loc = loc,
            .data = .{ .match_expr = .{
                .discriminant = discriminant,
                .arms_start = arms_start,
                .arms_count = arms_len,
            } },
        });
    }

    fn parseMatchPattern(self: *Parser) anyerror!NodeIndex {
        // Object pattern: { key: value, ... }
        if (self.check(.lbrace)) {
            return self.parseMatchObjectPattern();
        }
        if (self.check(.lbracket)) {
            return self.parseMatchArrayPattern();
        }

        // Wildcard: _
        if (self.check(.identifier)) {
            const text = self.current.text(self.source);
            if (std.mem.eql(u8, text, "_")) {
                self.advance();
                return null_node;
            }
            if (typeTestKindFor(text)) |kind| return self.parseTypeTestPattern(kind);
        }

        // Literal pattern: string, number, boolean, null, undefined
        return switch (self.current.type) {
            .string_literal => self.parseString(),
            .number => self.parseNumber(),
            .true_lit => self.parseBoolLiteral(true),
            .false_lit => self.parseBoolLiteral(false),
            .null_lit => self.parseNullLiteral(),
            .undefined_lit => self.parseUndefinedLiteral(),
            else => {
                self.errorAtCurrent("expected pattern (literal, object, array, or '_' wildcard)");
                return error.ParseError;
            },
        };
    }

    /// The value kind a type-test pattern names, or null when the identifier
    /// is not one of them.
    fn typeTestKindFor(text: []const u8) ?Node.TypeTestKind {
        if (std.mem.eql(u8, text, "boolean")) return .boolean;
        if (std.mem.eql(u8, text, "number")) return .number;
        if (std.mem.eql(u8, text, "string")) return .string;
        if (std.mem.eql(u8, text, "array")) return .array;
        if (std.mem.eql(u8, text, "Dict")) return .dict;
        if (std.mem.eql(u8, text, "Bytes")) return .bytes;
        return null;
    }

    /// Build a type-test pattern and the narrowing test it lowers to (spec
    /// 5.5): `typeof s === "..."` for the three scalars, `Array.isArray(s)` for
    /// the array. The test reads the scrutinee a second time, so the scrutinee
    /// must be a name or a member path - which is what spec 5.5 requires of it
    /// anyway, with this diagnostic carrying the repair.
    fn parseTypeTestPattern(self: *Parser, kind: Node.TypeTestKind) anyerror!NodeIndex {
        const loc = self.current.location();
        const scrutinee = self.current_match_scrutinee;
        const readable = scrutinee != null_node and blk: {
            const scrutinee_tag = self.nodes.getTag(scrutinee);
            break :blk scrutinee_tag == .identifier or scrutinee_tag == .member_access;
        };
        if (!readable) {
            self.errors.addErrorAt(.unsupported_feature, self.current, "a type-test pattern needs a scrutinee that is a name or a member path; bind the scrutinee to a const first and match on that");
            return error.ParseError;
        }
        self.advance(); // consume the kind name

        const predicate = switch (kind) {
            .array => try self.buildIsArrayCall(loc, scrutinee),
            .dict => try self.buildIsDictCall(loc, scrutinee),
            .bytes => try self.buildIsBytesCall(loc, scrutinee),
            .boolean, .number, .string => try self.buildTypeofTest(loc, scrutinee, @tagName(kind)),
        };

        return try self.nodes.add(.{
            .tag = .match_type_test,
            .loc = loc,
            .data = .{ .match_type_test = .{ .kind = kind, .predicate = predicate } },
        });
    }

    fn buildTypeofTest(self: *Parser, loc: SourceLocation, scrutinee: NodeIndex, name: []const u8) anyerror!NodeIndex {
        const typeof_node = try self.nodes.add(.{
            .tag = .unary_op,
            .loc = loc,
            .data = .{ .unary = .{ .op = .typeof_op, .operand = scrutinee } },
        });
        const str_idx = try self.constants.addString(name);
        const literal = try self.nodes.add(Node.litString(loc, str_idx));
        return try self.nodes.add(.{
            .tag = .binary_op,
            .loc = loc,
            .data = .{ .binary = .{ .op = .strict_eq, .left = typeof_node, .right = literal } },
        });
    }

    /// `isDict(s)` - the intrinsic guard spec 5.7 names, called as a global
    /// rather than as a method, which is the one shape difference from the
    /// array test.
    fn buildIsDictCall(self: *Parser, loc: SourceLocation, scrutinee: NodeIndex) anyerror!NodeIndex {
        return self.buildGlobalGuardCall(loc, scrutinee, "isDict");
    }

    /// `isBytes(s)` - the intrinsic guard for `Bytes` (spec 6.3), built the
    /// same way `isDict` is: a global call rather than a method call.
    fn buildIsBytesCall(self: *Parser, loc: SourceLocation, scrutinee: NodeIndex) anyerror!NodeIndex {
        return self.buildGlobalGuardCall(loc, scrutinee, "isBytes");
    }

    /// The shared shape behind `isDict(s)` and `isBytes(s)`: resolve the
    /// intrinsic's name and call it with the scrutinee.
    fn buildGlobalGuardCall(self: *Parser, loc: SourceLocation, scrutinee: NodeIndex, name: []const u8) anyerror!NodeIndex {
        const name_atom = try self.addAtom(name);
        const binding = try self.scopes.resolveBinding(name, name_atom);
        const callee = try self.nodes.add(Node.identifier(loc, binding));
        const args_start = try self.addNodeList(&[_]NodeIndex{scrutinee});
        return try self.nodes.add(.{
            .tag = .call,
            .loc = loc,
            .data = .{ .call = .{
                .callee = callee,
                .args_start = args_start,
                .args_count = 1,
                .is_optional = false,
            } },
        });
    }

    fn buildIsArrayCall(self: *Parser, loc: SourceLocation, scrutinee: NodeIndex) anyerror!NodeIndex {
        const array_atom = try self.addAtom("Array");
        const array_binding = try self.scopes.resolveBinding("Array", array_atom);
        const array_ref = try self.nodes.add(Node.identifier(loc, array_binding));
        const method_atom = try self.addAtom("isArray");
        const callee = try self.nodes.add(.{
            .tag = .member_access,
            .loc = loc,
            .data = .{ .member = .{
                .object = array_ref,
                .property = method_atom,
                .computed = null_node,
                .is_optional = false,
            } },
        });
        const args_start = try self.addNodeList(&[_]NodeIndex{scrutinee});
        return try self.nodes.add(.{
            .tag = .call,
            .loc = loc,
            .data = .{ .call = .{
                .callee = callee,
                .args_start = args_start,
                .args_count = 1,
                .is_optional = false,
            } },
        });
    }

    /// Declare a match-pattern binding as an arm-scoped `const` and return the
    /// identifier node that carries it. The node sits in the pattern property's
    /// value slot, which is where codegen reads the slot to store the field
    /// into and where the analyzers read "this field is bound, not tested".
    fn declarePatternBinding(self: *Parser, name: []const u8, loc: SourceLocation) anyerror!NodeIndex {
        const name_atom = try self.addAtom(name);
        const binding = self.scopes.declareBinding(
            name,
            name_atom,
            .variable,
            true,
        ) catch return error.TooManyLocals;
        return try self.nodes.add(Node.identifier(loc, binding));
    }

    fn parseMatchObjectPattern(self: *Parser) anyerror!NodeIndex {
        const loc = self.current.location();
        self.advance(); // consume '{'

        var props: [255]NodeIndex = undefined;
        var props_len: u8 = 0;

        while (!self.check(.rbrace) and !self.check(.eof)) {
            const prop_loc = self.current.location();

            var key_name: []const u8 = "";
            const key = switch (self.current.type) {
                .identifier => blk: {
                    const text = self.current.text(self.source);
                    key_name = text;
                    const str_idx = try self.constants.addString(text);
                    self.advance();
                    break :blk try self.nodes.add(Node.litString(prop_loc, str_idx));
                },
                .string_literal => try self.parseString(),
                else => {
                    self.errorAtCurrent("expected property name");
                    return error.ParseError;
                },
            };

            // Spec 5.5: a record pattern field is a discriminant test, a
            // binding under the field's own name (`{ text }`), or a binding
            // under a new name (`{ value: v }`). A binding declares an
            // arm-scoped `const` in the scope the caller pushed around this
            // arm, so it cannot be read from the next arm or after the match.
            var shorthand = false;
            const value = blk: {
                if (!self.check(.colon)) {
                    if (key_name.len == 0) {
                        self.errorAtCurrent("a string-keyed pattern field needs an explicit pattern or binding after ':'");
                        return error.ParseError;
                    }
                    shorthand = true;
                    break :blk try self.declarePatternBinding(key_name, prop_loc);
                }
                try self.expect(.colon, "':'");
                if (self.check(.identifier)) {
                    const text = self.current.text(self.source);
                    if (!std.mem.eql(u8, text, "_")) {
                        const name_loc = self.current.location();
                        self.advance();
                        break :blk try self.declarePatternBinding(text, name_loc);
                    }
                }
                break :blk try self.parseMatchPattern();
            };

            const prop_node = try self.nodes.add(.{
                .tag = .object_property,
                .loc = prop_loc,
                .data = .{ .property = .{
                    .key = key,
                    .value = value,
                    .is_computed = false,
                    .is_shorthand = shorthand,
                } },
            });
            if (props_len >= props.len) {
                self.errorAt(prop_loc, "too many match-pattern properties; limit is 255");
                return error.ParseError;
            }
            props[props_len] = prop_node;
            props_len += 1;

            if (!self.check(.rbrace)) {
                _ = self.match(.comma);
            }
        }

        try self.expect(.rbrace, "'}'");

        const props_start = if (props_len > 0)
            try self.addNodeList(props[0..props_len])
        else
            null_node;

        return try self.nodes.add(.{
            .tag = .match_pattern,
            .loc = loc,
            .data = .{ .match_pattern = .{
                .props_start = props_start,
                .props_count = props_len,
            } },
        });
    }

    fn parseMatchArrayPattern(self: *Parser) anyerror!NodeIndex {
        const loc = self.current.location();
        self.advance(); // consume '['

        var elements = std.ArrayList(NodeIndex).empty;
        defer elements.deinit(self.allocator);

        while (!self.check(.rbracket) and !self.check(.eof)) {
            if (self.check(.comma)) {
                try elements.append(self.allocator, null_node);
                self.advance();
                continue;
            }

            const elem = try self.parseMatchPattern();
            try elements.append(self.allocator, elem);

            if (!self.match(.comma)) break;
        }

        try self.expect(.rbracket, "']'");

        const elements_count = try self.checkedU16Count(loc, elements.items.len, "too many array pattern elements; limit is 65535");
        const elements_start = try self.addNodeList(elements.items);
        return try self.nodes.add(.{
            .tag = .array_pattern,
            .loc = loc,
            .data = .{ .array = .{
                .elements_start = elements_start,
                .elements_count = elements_count,
                .has_spread = false,
            } },
        });
    }

    fn parseBlock(self: *Parser) anyerror!NodeIndex {
        const loc = self.current.location();
        try self.expect(.lbrace, "'{'");

        const scope_id = try self.scopes.pushScope(.block);

        var stmts_sfa = std.heap.stackFallback(temp_list_stack_bytes, self.allocator);
        const stmts_alloc = stmts_sfa.get();
        var stmts = std.ArrayList(NodeIndex).empty;
        defer stmts.deinit(stmts_alloc);

        while (!self.check(.rbrace) and !self.check(.eof)) {
            if (self.parseStatement()) |stmt| {
                try stmts.append(stmts_alloc, stmt);
            } else |_| {
                const before = self.current.location().offset;
                self.synchronize();
                // `synchronize` returns without consuming anything when
                // `previous` is a semicolon or `current` starts a statement, so
                // an error raised at such a token would leave this loop
                // re-parsing it forever. Two error sites already call
                // `advance()` by hand to dodge that; guarantee the progress
                // here instead, so a site that forgets produces a diagnostic
                // rather than a hang.
                if (!self.check(.eof) and self.current.location().offset == before) {
                    self.advance();
                }
            }
        }

        try self.expect(.rbrace, "'}'");
        self.scopes.popScope();

        const stmts_count = try self.checkedU16Count(loc, stmts.items.len, "too many block statements; limit is 65535");
        const stmts_start = if (stmts.items.len > 0)
            try self.addStmtList(stmts.items)
        else
            null_node;

        return try self.nodes.add(.{
            .tag = .block,
            .loc = loc,
            .data = .{ .block = .{
                .stmts_start = stmts_start,
                .stmts_count = stmts_count,
                .scope_id = scope_id,
            } },
        });
    }

    fn parseEmptyStatement(self: *Parser) anyerror!NodeIndex {
        const loc = self.current.location();
        self.advance(); // consume ';'
        return try self.nodes.add(.{
            .tag = .empty_stmt,
            .loc = loc,
            .data = .{ .none = {} },
        });
    }

    fn parseDebuggerStatement(self: *Parser) anyerror!NodeIndex {
        const loc = self.current.location();
        self.advance(); // consume 'debugger'
        try self.expectSemicolon();
        return try self.nodes.add(.{
            .tag = .debugger_stmt,
            .loc = loc,
            .data = .{ .none = {} },
        });
    }

    // ============ Module Declaration Parsing ============

    /// Parse import declaration: import { X, Y } from "specifier"
    /// Rejects unsupported declaration forms (side-effect, default, namespace).
    fn parseImportDeclaration(self: *Parser) anyerror!NodeIndex {
        const loc = self.current.location();
        self.advance(); // consume 'import'

        // Collect specifiers
        var specifiers = std.ArrayList(NodeIndex).empty;
        defer specifiers.deinit(self.allocator);

        // Track binding candidates (confirmed after module string is known)
        var guard_candidate_slot: ?u16 = null;
        var pipe_candidate_slot: ?u16 = null;

        // Must have { for named imports
        if (!self.check(.lbrace)) {
            // Check for `import "module"` (side-effect import) or `import X from`
            if (self.check(.string_literal)) {
                self.errorAt(loc, "'import \"module\"' side-effect imports are not supported; use named imports: import { x } from \"module\"");
                return error.ParseError;
            }
            if (self.check(.star)) {
                self.errorAt(loc, "'import * as X' namespace imports are not supported; use named imports: import { x } from \"module\"");
                return error.ParseError;
            }
            // Assume default import attempt
            self.errorAt(loc, "'import X from' default imports are not supported; use named imports: import { x } from \"module\"");
            return error.ParseError;
        }

        self.advance(); // consume '{'

        // Parse specifier list: { name1, name2, name3 as alias }
        while (!self.check(.rbrace) and !self.check(.eof)) {
            const spec_loc = self.current.location();

            // Accept identifiers and keywords-as-identifiers (e.g., import { default as x })
            const imported_name = if (self.check(.identifier) or self.isKeyword(self.current.type)) blk: {
                const tok = self.current;
                self.advance();
                break :blk tok;
            } else {
                self.errors.addExpectedError(self.current, "import specifier name");
                return error.UnexpectedToken;
            };

            const imported_atom = try self.addAtom(imported_name.text(self.source));

            // Check for 'as' alias
            const local_name = if (self.match(.kw_as))
                try self.expectIdentifier("alias name after 'as'")
            else
                imported_name;

            const local_atom = try self.addAtom(local_name.text(self.source));

            // Declare local binding in scope
            const binding = self.scopes.declareBinding(
                local_name.text(self.source),
                local_atom,
                .variable,
                true, // imports are const
            ) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => {
                    self.errorAt(spec_loc, "duplicate import binding");
                    return error.ParseError;
                },
            };

            const spec_node = try self.nodes.add(.{
                .tag = .import_specifier,
                .loc = spec_loc,
                .data = .{ .import_spec = .{
                    .kind = .named,
                    .imported_atom = imported_atom,
                    .local_binding = binding,
                } },
            });

            try specifiers.append(self.allocator, spec_node);

            // Track binding candidates for zttp:compose detection
            const imported_text = imported_name.text(self.source);
            if (std.mem.eql(u8, imported_text, "guard")) {
                guard_candidate_slot = binding.slot;
            } else if (std.mem.eql(u8, imported_text, "pipe")) {
                pipe_candidate_slot = binding.slot;
            }

            if (!self.match(.comma)) break;
        }

        try self.expect(.rbrace, "'}'");
        try self.expect(.kw_from, "'from'");

        // Parse module specifier string
        if (!self.check(.string_literal)) {
            self.errors.addExpectedError(self.current, "module specifier string");
            return error.UnexpectedToken;
        }
        const module_token = self.current;
        self.advance();

        // Get the string content without quotes
        const raw = module_token.text(self.source);
        const module_str = if (raw.len >= 2) raw[1 .. raw.len - 1] else raw;
        const module_idx = try self.addString(module_str);

        try self.expectSemicolon();

        // Confirm bindings from zttp:compose for compile-time desugaring
        if (std.mem.eql(u8, module_str, "zttp:compose")) {
            if (guard_candidate_slot) |slot| {
                self.guard_binding_slot = slot;
            }
            if (pipe_candidate_slot) |slot| {
                self.pipe_binding_slot = slot;
            }
        }

        const specifiers_count = try self.checkedU8Count(loc, specifiers.items.len, "too many import specifiers; limit is 255");
        const specs_start = if (specifiers.items.len > 0)
            try self.addNodeList(specifiers.items)
        else
            null_node;

        return try self.nodes.add(.{
            .tag = .import_decl,
            .loc = loc,
            .data = .{ .import_decl = .{
                .module_idx = module_idx,
                .specifiers_start = specs_start,
                .specifiers_count = specifiers_count,
            } },
        });
    }

    /// Parse export declaration: export function X() {} or export const X = ...
    fn parseExportDeclaration(self: *Parser) anyerror!NodeIndex {
        const loc = self.current.location();
        self.advance(); // consume 'export'

        // export default function X() {}
        if (self.check(.kw_default)) {
            self.advance();
            if (!self.check(.kw_function)) {
                self.errorAt(loc, "'export default' must be followed by a named function");
                return error.ParseError;
            }
            const decl = try self.parseFunctionDeclaration();
            return try self.nodes.add(.{
                .tag = .export_decl,
                .loc = loc,
                .data = .{ .export_decl = .{
                    .kind = .default,
                    .declaration = decl,
                    .specifiers_start = null_node,
                    .specifiers_count = 0,
                    .from_module_idx = 0,
                } },
            });
        }

        // export { ... } - re-exports, not supported
        if (self.check(.lbrace)) {
            self.errorAt(loc, "'export { }' re-exports are not supported; use named exports: export function handler() {}");
            return error.ParseError;
        }

        // export * from - not supported
        if (self.check(.star)) {
            self.errorAt(loc, "'export *' is not supported; use named exports: export function handler() {}");
            return error.ParseError;
        }

        // export enum - not supported
        if (self.check(.kw_enum)) {
            self.errors.addErrorAt(.unsupported_feature, self.current, "'enum' is not supported; use object literals or discriminated unions instead");
            self.advance();
            return error.ParseError;
        }

        // export namespace - not supported (namespace tokenizes as identifier)
        if (self.current.type == .identifier) {
            const name = self.current.text(self.source);
            if (std.mem.eql(u8, name, "namespace")) {
                self.errors.addErrorAt(.unsupported_feature, self.current, "'namespace' is not supported; use ES6 modules instead");
                self.advance();
                return error.ParseError;
            }
        }

        // export function X() {}
        if (self.check(.kw_function)) {
            const decl = try self.parseFunctionDeclaration();
            return try self.nodes.add(.{
                .tag = .export_decl,
                .loc = loc,
                .data = .{ .export_decl = .{
                    .kind = .named,
                    .declaration = decl,
                    .specifiers_start = null_node,
                    .specifiers_count = 0,
                    .from_module_idx = 0,
                } },
            });
        }

        // export const X = ...
        if (self.check(.kw_const) or self.check(.kw_let)) {
            const decl = try self.parseVarDeclaration();
            return try self.nodes.add(.{
                .tag = .export_decl,
                .loc = loc,
                .data = .{ .export_decl = .{
                    .kind = .named,
                    .declaration = decl,
                    .specifiers_start = null_node,
                    .specifiers_count = 0,
                    .from_module_idx = 0,
                } },
            });
        }

        self.errorAt(loc, "'export' must be followed by 'function', 'const', or 'let'");
        return error.ParseError;
    }

    fn parseExpressionStatement(self: *Parser) anyerror!NodeIndex {
        const loc = self.current.location();
        const expr = try self.parseExpression(.none);
        try self.expectSemicolon();
        return try self.nodes.add(.{
            .tag = .expr_stmt,
            .loc = loc,
            .data = .{ .opt_value = expr },
        });
    }

    // ============ Expression Parsing (Pratt) ============

    /// Parse an expression using Pratt parsing (precedence climbing).
    ///
    /// Pratt parsing handles operator precedence without explicit grammar rules
    /// for each precedence level. It works by:
    /// 1. Parse prefix expression (literal, unary op, grouped expr, etc.)
    /// 2. While next token has higher precedence than min_prec:
    ///    - Parse infix expression with left operand and current precedence
    ///    - Result becomes new left operand
    ///
    /// Special case: Arrow functions are detected via lookahead before parsing
    /// begins, since they have unique syntax that doesn't fit the prefix/infix model.
    ///
    /// min_prec controls how tightly we bind to the right. For example:
    ///   1 + 2 * 3 parses as 1 + (2 * 3) because * has higher precedence than +
    fn parseExpression(self: *Parser, min_prec: Precedence) anyerror!NodeIndex {
        self.recursion_depth += 1;
        defer self.recursion_depth -= 1;
        if (self.recursion_depth > self.recursionLimit()) {
            self.errors.addErrorAt(.nesting_too_deep, self.current, "expression nests too deeply; simplify or split it (nesting limit is 512)");
            return error.ParseError;
        }

        // Check for arrow function
        if (self.isArrowFunction()) {
            return self.parseArrowFunction();
        }

        var left = try self.parsePrefixExpr();

        while (true) {
            const prec = self.getInfixPrecedence(self.current.type);
            if (@intFromEnum(prec) <= @intFromEnum(min_prec)) break;

            left = try self.parseInfixExpr(left, prec);
        }

        return left;
    }

    fn parsePrefixExpr(self: *Parser) anyerror!NodeIndex {
        return switch (self.current.type) {
            // Literals
            .number => self.parseNumber(),
            .string_literal => self.parseString(),
            .true_lit => self.parseBoolLiteral(true),
            .false_lit => self.parseBoolLiteral(false),
            .null_lit => self.parseNullLiteral(),
            .undefined_lit => self.parseUndefinedLiteral(),
            .regex_literal => {
                self.errors.addErrorAt(.unsupported_feature, self.current, "regular expressions are not supported; use string methods instead");
                return error.ParseError;
            },

            // Template literals
            .template_literal, .template_head => self.parseTemplateLiteral(),

            // Identifiers and keywords
            .identifier => self.parseIdentifier(),
            .kw_this => {
                self.errors.addErrorAt(.unsupported_feature, self.current, "'this' is not supported; pass context explicitly as a parameter");
                return error.ParseError;
            },
            .kw_super => {
                self.errors.addErrorAt(.unsupported_feature, self.current, "'super' is not supported; use explicit function calls instead");
                return error.ParseError;
            },
            .kw_new => {
                self.errors.addErrorAt(.unsupported_feature, self.current, "'new' is not supported; use factory functions instead");
                self.advance();
                return error.ParseError;
            },
            .kw_function => {
                self.errors.addErrorAt(.unsupported_feature, self.current, "function expressions are not supported; use arrow functions '(x) => x * 2' or function declarations 'function name() { }' instead");
                self.advance();
                return error.ParseError;
            },
            // class keyword in expression context: const X = class { }
            // Catches class expressions (both .js and .ts files after stripping)
            .kw_match => self.parseMatchExpression(),
            .kw_class => {
                self.errors.addErrorAt(.unsupported_feature, self.current, "'class' is not supported; use plain objects and functions instead");
                self.advance();
                return error.ParseError;
            },
            .kw_async => self.parseAsyncExpression(),
            .kw_yield => {
                self.errors.addErrorAt(.unsupported_feature, self.current, "'yield' is not supported; generators are not available");
                return error.ParseError;
            },
            .kw_await => self.parseAwaitExpression(),
            .kw_typeof => self.parseUnaryKeyword(.typeof_op),
            .kw_void => self.parseUnaryKeyword(.void_op),
            .kw_delete => {
                self.errors.addErrorAt(.unsupported_feature, self.current, "'delete' is not supported; use object spread to omit properties");
                return error.ParseError;
            },

            // Grouping and array/object literals
            .lparen => self.parseGroupedOrArrowParams(),
            .lbracket => self.parseArrayLiteral(),
            .lbrace => self.parseObjectLiteral(),

            // Unary operators
            .bang => self.parseUnaryOp(.not),
            .tilde => self.parseUnaryOp(.bit_not),
            .plus => self.parseUnaryOp(.pos), // Unary +: coerce to number
            .minus => self.parseUnaryOp(.neg),
            // Prefix increment/decrement - not supported
            .plus_plus => {
                self.errors.addErrorAt(.unsupported_feature, self.current, "'++x' is not supported; use 'x = x + 1' instead");
                return error.ParseError;
            },
            .minus_minus => {
                self.errors.addErrorAt(.unsupported_feature, self.current, "'--x' is not supported; use 'x = x - 1' instead");
                return error.ParseError;
            },

            // JSX
            .lt => if (self.tokenizer.jsx_mode) self.parseJsxElement() else error.UnexpectedToken,

            else => {
                self.errorAtCurrent("expected expression");
                return error.UnexpectedToken;
            },
        };
    }

    fn parseInfixExpr(self: *Parser, left: NodeIndex, prec: Precedence) anyerror!NodeIndex {
        const op_tok = self.current;
        const loc = op_tok.location();

        return switch (op_tok.type) {
            // Loose equality is not supported - use strict equality
            .eq => {
                if (self.expression_profile != null) {
                    self.advance();
                    const right = try self.parseExpression(prec);
                    return try self.nodes.add(Node.binaryOp(loc, .loose_eq, left, right));
                }
                self.errors.addErrorAt(.unsupported_feature, self.current, "'==' is not supported; use '===' for strict equality instead");
                return error.ParseError;
            },
            .ne => {
                if (self.expression_profile != null) {
                    self.advance();
                    const right = try self.parseExpression(prec);
                    return try self.nodes.add(Node.binaryOp(loc, .loose_neq, left, right));
                }
                self.errors.addErrorAt(.unsupported_feature, self.current, "'!=' is not supported; use '!==' for strict inequality instead");
                return error.ParseError;
            },

            // Binary operators
            .plus,
            .minus,
            .star,
            .slash,
            .percent,
            .star_star,
            .eq_eq,
            .ne_ne,
            .lt,
            .le,
            .gt,
            .ge,
            .ampersand,
            .pipe,
            .caret,
            .lt_lt,
            .gt_gt,
            .gt_gt_gt,
            .ampersand_ampersand,
            .pipe_pipe,
            .question_question,
            .kw_in,
            => {
                // In JavaScript, a unary operator on the left of ** is a syntax
                // error (e.g. -3**2 is ambiguous). Require parentheses.
                if (self.expression_profile == null and op_tok.type == .star_star and self.nodes.getTag(left) == .unary_op) {
                    self.errors.addErrorAt(.unsupported_feature, op_tok, "unary operator before '**' requires parentheses: (-3)**2 or -(3**2)");
                    return error.ParseError;
                }
                self.advance();
                const right_prec = if (op_tok.type == .star_star)
                    @as(Precedence, @enumFromInt(@intFromEnum(prec) - 1)) // Right associative
                else
                    prec;
                const right = try self.parseExpression(right_prec);
                return try self.nodes.add(Node.binaryOp(loc, self.tokenToBinaryOp(op_tok.type), left, right));
            },

            // Pipe operator: a |> f desugars to f(a)
            // When guard() calls are present, the entire chain is desugared
            // into a flat guard composition function at compile time.
            .pipe_gt => {
                if (self.expression_profile != null) {
                    self.errors.addErrorAt(.unexpected_token, op_tok, "'|>' is not supported in comptime expressions");
                    return error.UnexpectedToken;
                }
                if (self.guard_binding_slot == null) {
                    // Fast path: no guard imports, zero-allocation fold
                    var result = left;
                    while (true) {
                        self.advance(); // consume |>
                        const func = try self.parseExpression(@enumFromInt(@intFromEnum(prec)));
                        const args_start = try self.addNodeList(&[_]NodeIndex{result});
                        result = try self.nodes.add(.{
                            .tag = .call,
                            .loc = loc,
                            .data = .{ .call = .{
                                .callee = func,
                                .args_start = args_start,
                                .args_count = 1,
                                .is_optional = false,
                            } },
                        });
                        if (self.getInfixPrecedence(self.current.type) != .pipe_op) break;
                    }
                    return result;
                }

                // Slow path: guard() may be present, collect chain for analysis
                var chain = std.ArrayList(NodeIndex).empty;
                defer chain.deinit(self.allocator);
                try chain.append(self.allocator, left);

                while (true) {
                    self.advance(); // consume |>
                    const elem = try self.parseExpression(@enumFromInt(@intFromEnum(prec)));
                    try chain.append(self.allocator, elem);
                    if (self.getInfixPrecedence(self.current.type) != .pipe_op) break;
                }

                if (self.chainHasGuards(chain.items)) {
                    return self.desugarGuardComposition(loc, chain.items);
                }

                // No guards found despite import - normal fold
                var result = chain.items[0];
                for (chain.items[1..]) |func| {
                    const args_start = try self.addNodeList(&[_]NodeIndex{result});
                    result = try self.nodes.add(.{
                        .tag = .call,
                        .loc = loc,
                        .data = .{ .call = .{
                            .callee = func,
                            .args_start = args_start,
                            .args_count = 1,
                            .is_optional = false,
                        } },
                    });
                }
                return result;
            },

            // instanceof not supported - use discriminated unions with tag property
            .kw_instanceof => {
                self.errors.addErrorAt(.unsupported_feature, self.current, "'instanceof' is not supported; use discriminated unions with tag property instead");
                return error.ParseError;
            },

            // Simple assignment only
            .assign => {
                self.advance();
                const right = try self.parseExpression(@enumFromInt(@intFromEnum(prec) - 1));
                return try self.nodes.add(.{
                    .tag = .assignment,
                    .loc = loc,
                    .data = .{ .assignment = .{
                        .target = left,
                        .value = right,
                        .op = null,
                    } },
                });
            },

            // Compound assignments: desugar to assignment with binary op
            .plus_assign,
            .minus_assign,
            .star_assign,
            .slash_assign,
            .percent_assign,
            .star_star_assign,
            .ampersand_assign,
            .pipe_assign,
            .caret_assign,
            .lt_lt_assign,
            .gt_gt_assign,
            .gt_gt_gt_assign,
            => {
                const binary_op = self.tokenToBinaryOp(op_tok.type);
                self.advance();
                const right = try self.parseExpression(@enumFromInt(@intFromEnum(prec) - 1));
                return try self.nodes.add(.{
                    .tag = .assignment,
                    .loc = loc,
                    .data = .{ .assignment = .{
                        .target = left,
                        .value = right,
                        .op = binary_op,
                    } },
                });
            },

            // Logical compound assignments need short-circuit semantics (not yet supported)
            .ampersand_ampersand_assign => {
                self.errors.addErrorAt(.unsupported_feature, self.current, "'&&=' is not supported; use 'x = x && value' instead");
                return error.ParseError;
            },
            .pipe_pipe_assign => {
                self.errors.addErrorAt(.unsupported_feature, self.current, "'||=' is not supported; use 'x = x || value' instead");
                return error.ParseError;
            },
            .question_question_assign => {
                self.errors.addErrorAt(.unsupported_feature, self.current, "'??=' is not supported; use 'x = x ?? value' instead");
                return error.ParseError;
            },

            // Ternary
            .question => {
                self.advance();
                // ECMAScript ConditionalExpression branches are AssignmentExpression,
                // so `cond ? a = 1 : b` is valid (`cond ? (a = 1) : b`). Parse at
                // `.comma` (one below `.assignment`) so `=`/compound assignment can
                // bind inside a branch while a top-level comma still terminates it;
                // parsing at `.assignment` left the `=` dangling and errored.
                const then_expr = try self.parseExpression(.comma);
                try self.expect(.colon, "':'");
                const else_expr = try self.parseExpression(.comma);
                return try self.nodes.add(.{
                    .tag = .ternary,
                    .loc = loc,
                    .data = .{ .ternary = .{
                        .condition = left,
                        .then_branch = then_expr,
                        .else_branch = else_expr,
                    } },
                });
            },

            // Member access
            .dot => {
                self.advance();
                const prop = try self.expectPropertyIdentifier("property name");
                const prop_name = prop.text(self.source);

                // Check for removed Object methods
                if (self.nodes.get(left)) |left_node| {
                    if (left_node.tag == .identifier) {
                        const binding = left_node.data.binding;
                        // Check if it's the builtin Object global (undeclared)
                        if (binding.kind == .undeclared_global and binding.name_atom == @intFromEnum(object.Atom.Object)) {
                            if (std.mem.eql(u8, prop_name, "assign")) {
                                self.errors.addErrorAt(.unsupported_feature, prop, "'Object.assign' is not supported; use object spread {...obj1, ...obj2} instead");
                                return error.ParseError;
                            }
                            if (std.mem.eql(u8, prop_name, "freeze")) {
                                self.errors.addErrorAt(.unsupported_feature, prop, "'Object.freeze' is not supported; objects are mutable by design");
                                return error.ParseError;
                            }
                            if (std.mem.eql(u8, prop_name, "isFrozen")) {
                                self.errors.addErrorAt(.unsupported_feature, prop, "'Object.isFrozen' is not supported; objects are mutable by design");
                                return error.ParseError;
                            }
                        }
                    }
                }

                const prop_atom = try self.addAtom(prop_name);
                return try self.nodes.add(.{
                    .tag = .member_access,
                    .loc = loc,
                    .data = .{ .member = .{
                        .object = left,
                        .property = prop_atom,
                        .computed = null_node,
                        .is_optional = false,
                    } },
                });
            },

            // Computed member access
            .lbracket => {
                self.advance();
                const index = try self.parseExpression(.none);
                try self.expect(.rbracket, "']'");
                return try self.nodes.add(.{
                    .tag = .computed_access,
                    .loc = loc,
                    .data = .{ .member = .{
                        .object = left,
                        .property = 0,
                        .computed = index,
                        .is_optional = false,
                    } },
                });
            },

            // Optional chaining
            .question_dot => {
                self.advance();
                if (self.match(.lbracket)) {
                    const index = try self.parseExpression(.none);
                    try self.expect(.rbracket, "']'");
                    // `obj?.[key]` is an optional COMPUTED access. Tag it as
                    // `computed_access` (which preserves the computed key and the
                    // is_optional bit) rather than `optional_chain` (whose IR
                    // packing keeps only `property`, dropping the key, so codegen
                    // read a nonexistent atom 0 and the result was always
                    // undefined).
                    return try self.nodes.add(.{
                        .tag = .computed_access,
                        .loc = loc,
                        .data = .{ .member = .{
                            .object = left,
                            .property = 0,
                            .computed = index,
                            .is_optional = true,
                        } },
                    });
                } else if (self.match(.lparen)) {
                    // Optional call
                    return self.parseCallArgs(left, loc, true);
                } else {
                    const prop = try self.expectPropertyIdentifier("property name");
                    const prop_atom = try self.addAtom(prop.text(self.source));
                    return try self.nodes.add(.{
                        .tag = .optional_chain,
                        .loc = loc,
                        .data = .{ .member = .{
                            .object = left,
                            .property = prop_atom,
                            .computed = null_node,
                            .is_optional = true,
                        } },
                    });
                }
            },

            // Function call
            .lparen => {
                self.advance();
                return self.parseCallArgs(left, loc, false);
            },

            // Postfix operators - not supported
            .plus_plus => {
                self.errors.addErrorAt(.unsupported_feature, self.current, "'x++' is not supported; use 'x = x + 1' instead");
                return error.ParseError;
            },
            .minus_minus => {
                self.errors.addErrorAt(.unsupported_feature, self.current, "'x--' is not supported; use 'x = x - 1' instead");
                return error.ParseError;
            },

            else => left,
        };
    }

    fn parseCallArgs(self: *Parser, callee: NodeIndex, loc: SourceLocation, is_optional: bool) anyerror!NodeIndex {
        // Argument lists are almost always tiny, so a small stack buffer keeps
        // them off the heap entirely; longer lists fall back to the parser
        // allocator, and deinit handles either case. See
        // `temp_list_stack_bytes` for why the buffer is kept small.
        var args_sfa = std.heap.stackFallback(temp_list_stack_bytes, self.allocator);
        const args_alloc = args_sfa.get();
        var args = std.ArrayList(NodeIndex).empty;
        defer args.deinit(args_alloc);

        if (!self.check(.rparen)) {
            while (true) {
                if (self.match(.spread)) {
                    const spread_expr = try self.parseExpression(.assignment);
                    const spread_node = try self.nodes.add(.{
                        .tag = .spread,
                        .loc = loc,
                        .data = .{ .opt_value = spread_expr },
                    });
                    try args.append(args_alloc, spread_node);
                } else {
                    const arg = try self.parseExpression(.assignment);
                    try args.append(args_alloc, arg);
                }
                if (!self.match(.comma)) break;
                if (self.check(.rparen)) break;
            }
        }
        try self.expect(.rparen, "')'");

        // Desugar pipe(f1, f2, ..., fN) into fN(...(f2(f1()))...)
        if (self.isPipeCall(callee)) {
            if (args.items.len == 0) {
                self.errorAt(loc, "pipe() requires at least one function argument");
                return error.ParseError;
            }
            return self.desugarPipeCall(loc, args.items);
        }

        const args_count = try self.checkedU8Count(loc, args.items.len, "too many call arguments; limit is 255");
        const args_start = if (args.items.len > 0)
            try self.addNodeList(args.items)
        else
            null_node;

        return try self.nodes.add(.{
            .tag = if (is_optional) .optional_call else .call,
            .loc = loc,
            .data = .{ .call = .{
                .callee = callee,
                .args_start = args_start,
                .args_count = args_count,
                .is_optional = is_optional,
            } },
        });
    }

    // ============ Literal Parsing ============

    fn parseNumber(self: *Parser) anyerror!NodeIndex {
        const loc = self.current.location();
        const text = self.current.text(self.source);
        const has_separator = self.current.has_separator;
        self.advance();

        if (self.expression_profile != null) {
            return self.parseComptimeNumber(loc, text);
        }

        // Numeric separators belong to the comptime expression profile only.
        // `std.fmt.parseInt` and `parseFloat` both accept `_`, so without this
        // check `1_000` would quietly become a supported literal here.
        if (has_separator) {
            self.errors.addError(.invalid_number, loc, "numeric separators are not supported outside comptime(); write the digits without '_'");
            return error.InvalidNumber;
        }

        // D3 section 1's three numeric divergences, refused before the parse
        // fallbacks below can swallow them. `parseInt` fails on `0x` and
        // `parseFloat` fails after it, and the float path ended `catch 0.0`, so
        // a malformed literal became the number zero with no diagnostic at all.
        if (numericFault(text)) |fault| {
            self.errors.addError(.invalid_number, loc, fault);
            return error.InvalidNumber;
        }

        // Try to parse as integer first
        if (std.fmt.parseInt(i32, text, 0)) |int_val| {
            return try self.nodes.add(Node.litInt(loc, int_val));
        } else |_| {}

        // Parse as float
        const float_val = std.fmt.parseFloat(f64, text) catch 0.0;
        const float_idx = try self.constants.addFloat(float_val);
        return try self.nodes.add(.{
            .tag = .lit_float,
            .loc = loc,
            .data = .{ .float_idx = float_idx },
        });
    }

    /// The message for a malformed numeric literal, or null when the text is a
    /// form this profile admits. Reads the token's own bytes, which is where
    /// the fault lives: the tokenizer scans a radix prefix and an exponent
    /// marker whether or not digits follow them.
    fn numericFault(text: []const u8) ?[]const u8 {
        if (text.len >= 2 and text[0] == '0') {
            const marker = text[1];
            const radix_digits = text[2..];
            if (marker == 'x' or marker == 'X') {
                if (radix_digits.len == 0) return "hexadecimal literal has no digits after `0x`";
            } else if (marker == 'b' or marker == 'B') {
                if (radix_digits.len == 0) return "binary literal has no digits after `0b`";
            } else if (marker == 'o' or marker == 'O') {
                if (radix_digits.len == 0) return "octal literal has no digits after `0o`";
            } else if (std.ascii.isDigit(marker)) {
                // Legacy octal. `0755` is 493 to a reader who knows the C
                // convention and 755 to everyone else, which is why the form is
                // refused rather than assigned one of the two meanings. The
                // code is `invalid_number`; this message is what names the
                // fault, since the code is shared with the cases above.
                return "legacy octal literals are not supported; write `0o755` for octal, or drop the leading zero for decimal";
            }
            // A radix literal has no exponent, so the scan below does not apply.
            if (marker == 'x' or marker == 'X' or marker == 'b' or marker == 'B' or marker == 'o' or marker == 'O') {
                return null;
            }
        }

        // An exponent marker with no digits after it, with or without a sign.
        if (std.mem.indexOfAny(u8, text, "eE")) |at| {
            var i = at + 1;
            if (i < text.len and (text[i] == '+' or text[i] == '-')) i += 1;
            if (i >= text.len) return "exponent has no digits";
            while (i < text.len) : (i += 1) {
                if (!std.ascii.isDigit(text[i])) return "exponent has no digits";
            }
        }
        return null;
    }

    fn parseComptimeNumber(self: *Parser, loc: SourceLocation, text: []const u8) anyerror!NodeIndex {
        var clean: std.ArrayList(u8) = .empty;
        defer clean.deinit(self.allocator);
        for (text) |byte| {
            if (byte != '_') try clean.append(self.allocator, byte);
        }

        const value: f64 = if (clean.items.len >= 2 and clean.items[0] == '0') blk: {
            const radix: ?u8 = switch (clean.items[1]) {
                'x', 'X' => 16,
                'o', 'O' => 8,
                'b', 'B' => 2,
                else => null,
            };
            if (radix) |base| {
                const integer = std.fmt.parseInt(u64, clean.items[2..], base) catch {
                    self.errors.addError(.invalid_number, loc, "invalid number literal");
                    return error.InvalidNumber;
                };
                break :blk @floatFromInt(integer);
            }
            break :blk std.fmt.parseFloat(f64, clean.items) catch {
                self.errors.addError(.invalid_number, loc, "invalid number literal");
                return error.InvalidNumber;
            };
        } else std.fmt.parseFloat(f64, clean.items) catch {
            self.errors.addError(.invalid_number, loc, "invalid number literal");
            return error.InvalidNumber;
        };

        const float_idx = try self.constants.addFloat(value);
        return try self.nodes.add(.{
            .tag = .lit_float,
            .loc = loc,
            .data = .{ .float_idx = float_idx },
        });
    }

    fn parseString(self: *Parser) anyerror!NodeIndex {
        const token = self.current;
        self.advance();

        if (self.expression_profile != null) return self.addComptimeStringNode(token);

        // Strip quotes
        const loc = token.location();
        const text = token.text(self.source);
        const content = if (text.len >= 2) text[1 .. text.len - 1] else "";
        const str_idx = try self.unescapedStringOrDiagnostic(content, loc);
        return try self.nodes.add(Node.litString(loc, str_idx));
    }

    fn addComptimeStringNode(self: *Parser, token: Token) anyerror!NodeIndex {
        const loc = token.location();
        const text = token.text(self.source);
        if (text.len < 2 or text[text.len - 1] != text[0]) {
            self.errors.addError(.unterminated_string, loc, "unterminated string literal");
            return error.UnexpectedToken;
        }

        const str_idx = try self.unescapedStringOrDiagnostic(text[1 .. text.len - 1], loc);
        return try self.nodes.add(Node.litString(loc, str_idx));
    }

    fn parseBoolLiteral(self: *Parser, value: bool) anyerror!NodeIndex {
        const loc = self.current.location();
        self.advance();
        return try self.nodes.add(Node.litBool(loc, value));
    }

    fn parseNullLiteral(self: *Parser) anyerror!NodeIndex {
        const loc = self.current.location();
        self.advance();
        return try self.nodes.add(Node.litNull(loc));
    }

    fn parseUndefinedLiteral(self: *Parser) anyerror!NodeIndex {
        const loc = self.current.location();
        self.advance();
        return try self.nodes.add(Node.litUndefined(loc));
    }

    fn parseTemplateLiteral(self: *Parser) anyerror!NodeIndex {
        const loc = self.current.location();

        if (self.current.type == .template_literal) {
            // Simple template with no interpolation
            const text = self.current.text(self.source);
            self.advance();
            if (self.expression_profile != null and (text.len < 2 or text[text.len - 1] != '`')) {
                self.errors.addError(.unterminated_template, loc, "unterminated template literal");
                return error.UnexpectedToken;
            }
            const content = if (text.len >= 2) text[1 .. text.len - 1] else "";
            const str_idx = try self.addUnescapedString(content);
            return try self.nodes.add(Node.litString(loc, str_idx));
        }

        // Template with interpolation
        var parts = std.ArrayList(NodeIndex).empty;
        defer parts.deinit(self.allocator);

        // template_head: `string${
        var text = self.current.text(self.source);
        self.advance();
        var content = if (text.len >= 3) text[1 .. text.len - 2] else "";
        var str_idx = try self.addUnescapedString(content);
        var str_node = try self.nodes.add(.{
            .tag = .template_part_string,
            .loc = loc,
            .data = .{ .string_idx = str_idx },
        });
        try parts.append(self.allocator, str_node);

        while (self.current.type != .template_tail and self.current.type != .eof) {
            // Expression
            const expr = try self.parseExpression(.none);
            const expr_node = try self.nodes.add(.{
                .tag = .template_part_expr,
                .loc = loc,
                .data = .{ .opt_value = expr },
            });
            try parts.append(self.allocator, expr_node);

            if (self.current.type == .template_middle) {
                text = self.current.text(self.source);
                self.advance();
                content = if (text.len >= 3) text[1 .. text.len - 2] else "";
                str_idx = try self.addUnescapedString(content);
                str_node = try self.nodes.add(.{
                    .tag = .template_part_string,
                    .loc = loc,
                    .data = .{ .string_idx = str_idx },
                });
                try parts.append(self.allocator, str_node);
            } else if (self.current.type == .template_tail) {
                break;
            } else {
                self.errorAtCurrent("expected template continuation");
                break;
            }
        }

        // template_tail: }string`
        if (self.current.type == .template_tail) {
            text = self.current.text(self.source);
            self.advance();
            content = if (text.len >= 2) text[1 .. text.len - 1] else "";
            str_idx = try self.addUnescapedString(content);
            str_node = try self.nodes.add(.{
                .tag = .template_part_string,
                .loc = loc,
                .data = .{ .string_idx = str_idx },
            });
            try parts.append(self.allocator, str_node);
        }

        const parts_count = try self.checkedU8Count(loc, parts.items.len, "too many template literal parts; limit is 255");
        const parts_start = try self.addNodeList(parts.items);
        return try self.nodes.add(.{
            .tag = .template_literal,
            .loc = loc,
            .data = .{ .template = .{
                .parts_start = parts_start,
                .parts_count = parts_count,
                .tag = null_node,
            } },
        });
    }

    fn parseIdentifier(self: *Parser) anyerror!NodeIndex {
        const loc = self.current.location();
        const name = self.current.text(self.source);

        const name_atom = try self.addAtom(name);
        const binding = try self.scopes.resolveBinding(name, name_atom);

        // Check for removed global identifiers (allow user-declared bindings)
        if (binding.kind == .undeclared_global) {
            if (std.mem.eql(u8, name, "Promise")) {
                self.errors.addErrorAt(.unsupported_feature, self.current, "'Promise' is not supported; use Result types or callbacks instead");
                return error.ParseError;
            }
            if (std.mem.eql(u8, name, "RegExp")) {
                self.errors.addErrorAt(.unsupported_feature, self.current, "'RegExp' is not supported; use string methods instead");
                return error.ParseError;
            }
            // Dynamic code and reflection: the program must be closed for the
            // analyzers to see every call. `new Proxy(...)` was already
            // rejected as `new`, and `import(...)` as an unexpected token, but
            // these three names were admitted.
            if (std.mem.eql(u8, name, "eval")) {
                self.errors.addErrorAt(.unsupported_feature, self.current, "'eval' is not supported; call a named function instead");
                return error.ParseError;
            }
            if (std.mem.eql(u8, name, "Proxy")) {
                self.errors.addErrorAt(.unsupported_feature, self.current, "'Proxy' is not supported; use plain objects and explicit functions instead");
                return error.ParseError;
            }
            if (std.mem.eql(u8, name, "Reflect")) {
                self.errors.addErrorAt(.unsupported_feature, self.current, "'Reflect' is not supported; access properties directly instead");
                return error.ParseError;
            }
        }

        self.advance();
        return try self.nodes.add(Node.identifier(loc, binding));
    }

    fn parseUnaryOp(self: *Parser, op: UnaryOp) anyerror!NodeIndex {
        const loc = self.current.location();
        self.advance();
        const operand = try self.parseExpression(.unary);
        return try self.nodes.add(Node.unaryOp(loc, op, operand));
    }

    fn parseUnaryKeyword(self: *Parser, op: UnaryOp) anyerror!NodeIndex {
        const loc = self.current.location();
        self.advance();
        const operand = try self.parseExpression(.unary);
        return try self.nodes.add(Node.unaryOp(loc, op, operand));
    }

    fn parseAsyncExpression(self: *Parser) anyerror!NodeIndex {
        const async_token = self.current;
        const loc = async_token.location();
        self.advance(); // consume 'async'

        // `async function` / `async (...) =>` are unsupported: handlers run
        // synchronously. Reject at parse time so the analyzer never accepts an
        // async handler the runtime would otherwise execute as an empty 200.
        // (Bare `async` as an identifier or property name is still fine.)
        if (self.check(.kw_function) or self.isArrowFunction()) {
            self.errors.addErrorAt(.unsupported_feature, async_token, "'async' functions are not supported; handlers run synchronously - use 'fetch' from zttp:fetch, or 'parallel'/'race' from zttp:io for concurrency");
            return error.ParseError;
        }

        // Just 'async' as identifier
        const name_atom = try self.addAtom("async");
        const binding = try self.scopes.resolveBinding("async", name_atom);
        return try self.nodes.add(Node.identifier(loc, binding));
    }

    fn parseAwaitExpression(self: *Parser) anyerror!NodeIndex {
        // `await` is unsupported: handlers run synchronously. Reject at parse
        // time rather than executing it as a no-op that yields an empty 200.
        self.errors.addErrorAt(.invalid_await, self.current, "'await' is not supported; handlers run synchronously - use 'fetch' from zttp:fetch, or 'parallel'/'race' from zttp:io for concurrency");
        return error.ParseError;
    }

    fn parseGroupedOrArrowParams(self: *Parser) anyerror!NodeIndex {
        // Could be (expr) or arrow function params
        self.advance(); // consume '('

        if (self.check(.rparen)) {
            // () => ... empty params arrow function handled by isArrowFunction
            self.advance();
            self.errorAtCurrent("unexpected ')'");
            return error.UnexpectedToken;
        }

        const expr = try self.parseExpression(.none);
        try self.expect(.rparen, "')'");

        return expr;
    }

    fn parseArrayLiteral(self: *Parser) anyerror!NodeIndex {
        const loc = self.current.location();
        self.advance(); // consume '['

        var elements = std.ArrayList(NodeIndex).empty;
        defer elements.deinit(self.allocator);
        var has_spread = false;

        if (!self.check(.rbracket)) {
            while (true) {
                if (self.check(.comma)) {
                    self.errors.addErrorAt(.unsupported_feature, self.current, "array elisions are not supported; use explicit undefined values instead");
                    return error.ParseError;
                } else if (self.match(.spread)) {
                    has_spread = true;
                    const spread_expr = try self.parseExpression(.assignment);
                    const spread_node = try self.nodes.add(.{
                        .tag = .spread,
                        .loc = loc,
                        .data = .{ .opt_value = spread_expr },
                    });
                    try elements.append(self.allocator, spread_node);
                } else {
                    const elem = try self.parseExpression(.assignment);
                    try elements.append(self.allocator, elem);
                }
                if (!self.match(.comma)) break;
                if (self.check(.rbracket)) break;
            }
        }
        try self.expect(.rbracket, "']'");

        const elements_count = try self.checkedU16Count(loc, elements.items.len, "too many array elements; limit is 65535");
        const elements_start = if (elements.items.len > 0)
            try self.addNodeList(elements.items)
        else
            null_node;

        return try self.nodes.add(.{
            .tag = .array_literal,
            .loc = loc,
            .data = .{ .array = .{
                .elements_start = elements_start,
                .elements_count = elements_count,
                .has_spread = has_spread,
            } },
        });
    }

    fn parseObjectLiteral(self: *Parser) anyerror!NodeIndex {
        const loc = self.current.location();
        self.advance(); // consume '{'

        var properties_sfa = std.heap.stackFallback(temp_list_stack_bytes, self.allocator);
        const properties_alloc = properties_sfa.get();
        var properties = std.ArrayList(NodeIndex).empty;
        defer properties.deinit(properties_alloc);

        if (!self.check(.rbrace)) {
            while (true) {
                const prop_loc = self.current.location();

                // Check for spread
                if (self.match(.spread)) {
                    const spread_expr = try self.parseExpression(.assignment);
                    const spread_node = try self.nodes.add(.{
                        .tag = .object_spread,
                        .loc = prop_loc,
                        .data = .{ .opt_value = spread_expr },
                    });
                    try properties.append(properties_alloc, spread_node);
                } else {
                    // Check for getter/setter
                    var prop_kind: NodeTag = .object_property;
                    if (self.check(.kw_get) and self.peekIsPropertyName()) {
                        self.advance();
                        prop_kind = .object_getter;
                    } else if (self.check(.kw_set) and self.peekIsPropertyName()) {
                        self.advance();
                        prop_kind = .object_setter;
                    }

                    // Property key
                    var key_node: NodeIndex = undefined;
                    var is_computed = false;
                    var is_shorthand = false;

                    if (self.match(.lbracket)) {
                        is_computed = true;
                        key_node = try self.parseExpression(.none);
                        try self.expect(.rbracket, "']'");
                    } else if (self.check(.identifier)) {
                        const key = self.current;
                        self.advance();

                        // Check for shorthand { x } or method { x() {} }
                        if (prop_kind == .object_property and
                            !self.check(.colon) and !self.check(.lparen))
                        {
                            is_shorthand = true;
                            const key_idx = try self.addString(key.text(self.source));
                            key_node = try self.nodes.add(Node.litString(key.location(), key_idx));

                            // Shorthand - value is identifier reference
                            const name_atom = try self.addAtom(key.text(self.source));
                            const binding = try self.scopes.resolveBinding(key.text(self.source), name_atom);
                            const value_node = try self.nodes.add(Node.identifier(key.location(), binding));

                            const prop_node = try self.nodes.add(.{
                                .tag = .object_property,
                                .loc = prop_loc,
                                .data = .{ .property = .{
                                    .key = key_node,
                                    .value = value_node,
                                    .is_computed = false,
                                    .is_shorthand = true,
                                } },
                            });
                            try properties.append(properties_alloc, prop_node);

                            if (!self.match(.comma)) break;
                            if (self.check(.rbrace)) break;
                            continue;
                        }

                        const key_idx = try self.addString(key.text(self.source));
                        key_node = try self.nodes.add(Node.litString(key.location(), key_idx));
                    } else if (self.check(.number)) {
                        // One keyed-collection model: a record has string keys.
                        // A numeric key parses to the same string key, so the
                        // two spellings would be indistinguishable downstream.
                        self.errors.addErrorAt(.unsupported_feature, self.current, "numeric record keys are not supported; use a string key, or an array when the keys are dense indices");
                        return error.ParseError;
                    } else if (self.check(.string_literal)) {
                        const key = self.current;
                        self.advance();
                        if (self.expression_profile != null) {
                            key_node = try self.addComptimeStringNode(key);
                        } else {
                            const text = key.text(self.source);
                            const content = if (text.len >= 2) text[1 .. text.len - 1] else text;
                            const key_idx = try self.addString(content);
                            key_node = try self.nodes.add(Node.litString(key.location(), key_idx));
                        }
                    } else if (self.isKeyword(self.current.type)) {
                        // JavaScript allows reserved keywords as property names
                        // e.g., {class: 'foo', if: 'bar'}
                        const key = self.current;
                        self.advance();
                        const key_idx = try self.addString(key.text(self.source));
                        key_node = try self.nodes.add(Node.litString(key.location(), key_idx));
                    } else {
                        self.errorAtCurrent("expected property name");
                        break;
                    }

                    // Method shorthand or getter/setter. All three are
                    // rejected: codegen emits only `.object_property` and
                    // `.object_spread`, so a parsed method was silently
                    // dropped from the object it appeared in.
                    if (self.check(.lparen)) {
                        const message = switch (prop_kind) {
                            .object_getter => "object getters are not supported; use an explicit function call instead",
                            .object_setter => "object setters are not supported; use an explicit function call instead",
                            else => "object methods are not supported; use a property holding an arrow function instead",
                        };
                        self.errors.addErrorAt(.unsupported_feature, self.current, message);
                        return error.ParseError;
                    }

                    try self.expect(.colon, "':'");
                    const value = try self.parseExpression(.assignment);

                    const prop_node = try self.nodes.add(.{
                        .tag = .object_property,
                        .loc = prop_loc,
                        .data = .{ .property = .{
                            .key = key_node,
                            .value = value,
                            .is_computed = is_computed,
                            .is_shorthand = is_shorthand,
                        } },
                    });
                    try properties.append(properties_alloc, prop_node);
                }

                if (!self.match(.comma)) break;
                if (self.check(.rbrace)) break;
            }
        }
        try self.expect(.rbrace, "'}'");

        const properties_count = try self.checkedU16Count(loc, properties.items.len, "too many object properties; limit is 65535");
        const props_start = if (properties.items.len > 0)
            try self.addNodeList(properties.items)
        else
            null_node;

        return try self.nodes.add(.{
            .tag = .object_literal,
            .loc = loc,
            .data = .{ .object = .{
                .properties_start = props_start,
                .properties_count = properties_count,
            } },
        });
    }

    // ============ Arrow Function Detection ============

    fn isArrowFunction(self: *Parser) bool {
        // Simple cases
        if (self.check(.identifier)) {
            // x => ...
            const state = self.tokenizer.saveState();
            const tok1 = self.tokenizer.next();
            self.tokenizer.restoreState(state);
            return tok1.type == .arrow;
        }

        if (self.check(.lparen)) {
            // (...) => ...
            const state = self.tokenizer.saveState();
            // The current '(' is already consumed by the tokenizer state, so start
            // one level deep and only accept '=>' after the matching top-level ')'.
            var depth: u32 = 1;
            var tok = self.tokenizer.next();

            // Skip past parentheses
            while (tok.type != .eof) {
                if (tok.type == .lparen) depth += 1;
                if (tok.type == .rparen) {
                    depth -= 1;
                    if (depth == 0) break;
                }
                tok = self.tokenizer.next();
            }

            tok = self.tokenizer.next();
            self.tokenizer.restoreState(state);
            return tok.type == .arrow;
        }

        return false;
    }

    fn parseArrowFunction(self: *Parser) anyerror!NodeIndex {
        const loc = self.current.location();
        var flags = FunctionFlags{ .is_arrow = true };

        // Enter function scope
        const scope_id = try self.scopes.pushScope(.function);
        const was_in_function = self.in_function;
        self.in_function = true;

        // See parseFunctionBody: without this, an error while parsing the
        // parameter list or body leaves the scope stack unbalanced and the
        // recovery path invents follow-on diagnostics.
        var scope_active = true;
        errdefer if (scope_active) {
            self.in_function = was_in_function;
            self.scopes.popScope();
        };

        // Parse parameters
        var params_sfa = std.heap.stackFallback(temp_list_stack_bytes, self.allocator);
        const params_alloc = params_sfa.get();
        var params = std.ArrayList(NodeIndex).empty;
        defer params.deinit(params_alloc);

        if (self.check(.identifier)) {
            // Single parameter: x => ...
            const param_name = self.current;
            self.advance();
            const param_atom = try self.addAtom(param_name.text(self.source));
            const param_binding = self.scopes.declareBinding(
                param_name.text(self.source),
                param_atom,
                .parameter,
                false,
            ) catch return error.TooManyLocals;

            const param_node = try self.nodes.add(.{
                .tag = .pattern_element,
                .loc = param_name.location(),
                .data = .{ .pattern_elem = .{
                    .kind = .simple,
                    .binding = param_binding,
                    .key = null_node,
                    .key_atom = 0,
                    .default_value = null_node,
                } },
            });
            try params.append(params_alloc, param_node);
        } else {
            // Parenthesized parameters
            try self.expect(.lparen, "'('");

            if (!self.check(.rparen)) {
                while (true) {
                    if (self.match(.spread)) {
                        self.errors.addErrorAt(.unsupported_feature, self.previous, "rest parameters ('...args') are not supported; accept an explicit array parameter instead");
                        flags.has_rest_param = true;
                    }

                    if (self.check(.lbrace) or self.check(.lbracket)) {
                        self.errors.addErrorAt(.unsupported_feature, self.current, "destructured parameters are not supported; destructure inside the body instead");
                        return error.ParseError;
                    }

                    const param_name = try self.expectIdentifier("parameter name");
                    const param_atom = try self.addAtom(param_name.text(self.source));
                    const param_binding = self.scopes.declareBinding(
                        param_name.text(self.source),
                        param_atom,
                        .parameter,
                        false,
                    ) catch return error.TooManyLocals;

                    // Default params accepted here; flagged by the strict
                    // checker's canonical_default_parameter rule downstream.
                    var default_value: NodeIndex = null_node;
                    if (self.match(.assign)) {
                        flags.has_default_params = true;
                        default_value = try self.parseExpression(.assignment);
                    }

                    const param_node = try self.nodes.add(.{
                        .tag = .pattern_element,
                        .loc = param_name.location(),
                        .data = .{ .pattern_elem = .{
                            .kind = if (flags.has_rest_param) .rest else .simple,
                            .binding = param_binding,
                            .key = null_node,
                            .key_atom = 0,
                            .default_value = default_value,
                        } },
                    });
                    try params.append(params_alloc, param_node);

                    if (flags.has_rest_param) break;
                    if (!self.match(.comma)) break;
                    if (self.check(.rparen)) break;
                }
            }
            try self.expect(.rparen, "')'");
        }

        try self.expect(.arrow, "'=>'");

        // Parse body
        var body: NodeIndex = undefined;
        if (self.check(.lbrace)) {
            body = try self.parseBlock();
        } else {
            // Expression body
            const expr = try self.parseExpression(.assignment);
            body = try self.nodes.add(.{
                .tag = .return_stmt,
                .loc = loc,
                .data = .{ .opt_value = expr },
            });
        }

        self.in_function = was_in_function;
        self.scopes.popScope();
        scope_active = false;

        const params_count = try self.checkedU8Count(loc, params.items.len, "too many arrow function parameters; limit is 255");
        const params_start = if (params.items.len > 0)
            try self.addNodeList(params.items)
        else
            null_node;

        return try self.nodes.add(.{
            .tag = .arrow_function,
            .loc = loc,
            .data = .{ .function = .{
                .scope_id = scope_id,
                .name_atom = 0,
                .params_start = params_start,
                .params_count = params_count,
                .body = body,
                .flags = flags,
            } },
        });
    }

    // ============ JSX Parsing ============

    /// Check if current position is a JSX closing tag (</...).
    /// Uses direct source inspection to avoid tokenizer confusion with regex.
    fn peekJsxClosingTag(self: *Parser) bool {
        // Look ahead from the tokenizer position (right after '<') to see if this is a closing tag.
        // Avoid tokenizer.next() here because it can misclassify `</` as a regex literal.
        var i: usize = self.tokenizer.pos;
        while (i < self.source.len) : (i += 1) {
            switch (self.source[i]) {
                ' ', '\t', '\r', '\n' => continue,
                else => return self.source[i] == '/',
            }
        }
        return false;
    }

    /// Parse JSX element: <Tag attrs>children</Tag> or <Tag />
    ///
    /// JSX is transformed to h() calls (hyperscript pattern) for SSR:
    ///   <div className="foo">text</div>
    ///   => h('div', {className: 'foo'}, 'text')
    ///
    /// Tag classification:
    /// - Lowercase (div, span): String literal tag name
    /// - Uppercase (Button, Card): Component reference (identifier)
    /// - Member (Foo.Bar): Member expression for namespaced components
    ///
    /// Children can be:
    /// - Text nodes (whitespace-trimmed)
    /// - Nested JSX elements
    /// - Expression containers: {expr}
    ///
    /// Self-closing: <Tag /> and void elements (br, img, input, etc.)
    fn parseJsxElement(self: *Parser) anyerror!NodeIndex {
        const loc = self.current.location();
        self.advance(); // consume '<'

        // Check for fragment <>
        if (self.check(.gt)) {
            self.advance();
            return self.parseJsxFragment(loc);
        }

        // Tag name
        var tag_name: []const u8 = "";
        var is_component = false;

        if (self.check(.identifier)) {
            tag_name = self.current.text(self.source);
            is_component = tag_name.len > 0 and tag_name[0] >= 'A' and tag_name[0] <= 'Z';
            self.advance();

            // Handle member expressions: <Foo.Bar />
            while (self.match(.dot)) {
                if (self.check(.identifier)) {
                    self.advance();
                    // Append to tag name (simplified)
                } else {
                    self.errorAtCurrent("expected identifier after '.'");
                    break;
                }
            }
        } else {
            self.errorAtCurrent("expected JSX tag name");
            return error.UnexpectedToken;
        }

        const tag_atom = if (is_component)
            try self.addAtom(tag_name)
        else
            try self.addString(tag_name);

        // Parse attributes
        var props = std.ArrayList(NodeIndex).empty;
        defer props.deinit(self.allocator);

        while (!self.check(.gt) and !self.check(.slash) and !self.check(.eof)) {
            const attr_loc = self.current.location();

            if (self.match(.lbrace)) {
                // Spread attribute: {...props}
                if (self.match(.spread)) {
                    const spread_expr = try self.parseExpression(.assignment);
                    try self.expect(.rbrace, "'}'");

                    const attr_node = try self.nodes.add(.{
                        .tag = .jsx_spread_attribute,
                        .loc = attr_loc,
                        .data = .{ .jsx_attr = .{
                            .name_atom = 0,
                            .value = spread_expr,
                            .is_spread = true,
                        } },
                    });
                    try props.append(self.allocator, attr_node);
                } else {
                    self.errorAtCurrent("expected '...' in JSX spread");
                }
                continue;
            }

            // JSX attribute names can be identifiers or keywords (like "class", "for")
            // and can contain hyphens (like "hx-post", "data-value", "aria-label")
            if (!self.check(.identifier) and !self.isKeyword(self.current.type)) break;

            // Build hyphenated attribute name: start with first identifier
            const attr_name_start: u32 = self.current.start;
            var attr_name_end: u32 = self.current.start + self.current.len;
            self.advance();

            // Continue consuming hyphens and identifiers (allows hx-on--after-request pattern)
            // Handle both single minus (-) and minus_minus (--)
            while (self.check(.minus) or self.check(.minus_minus)) {
                // Include the hyphen(s) in the name
                attr_name_end = self.current.start + self.current.len;
                self.advance(); // consume - or --

                // If followed by identifier/keyword, include it too
                if (self.check(.identifier) or self.isKeyword(self.current.type)) {
                    attr_name_end = self.current.start + self.current.len;
                    self.advance();
                }
                // If not followed by identifier (e.g., another hyphen or =), loop continues
            }

            const attr_name_text = self.source[attr_name_start..attr_name_end];
            const attr_atom = try self.addAtom(attr_name_text);

            var attr_value: NodeIndex = null_node;
            if (self.match(.assign)) {
                if (self.check(.string_literal)) {
                    attr_value = try self.parseString();
                } else if (self.match(.lbrace)) {
                    attr_value = try self.parseExpression(.none);
                    try self.expect(.rbrace, "'}'");
                } else {
                    self.errorAtCurrent("expected attribute value");
                }
            }
            // else: boolean attribute like `disabled`

            const attr_node = try self.nodes.add(.{
                .tag = .jsx_attribute,
                .loc = attr_loc,
                .data = .{ .jsx_attr = .{
                    .name_atom = attr_atom,
                    .value = attr_value,
                    .is_spread = false,
                } },
            });
            try props.append(self.allocator, attr_node);
        }

        // Self-closing or children
        var children = std.ArrayList(NodeIndex).empty;
        defer children.deinit(self.allocator);
        var self_closing = false;

        if (self.match(.slash)) {
            self_closing = true;
            try self.expect(.gt, "'>'");
        } else {
            try self.expect(.gt, "'>'");

            // Parse children
            while (!self.check(.eof)) {
                // Check for closing tag
                if (self.check(.lt)) {
                    if (self.peekJsxClosingTag()) {
                        // Closing tag
                        // Force slash tokenization (avoid regex literal)
                        self.tokenizer.can_be_regex = false;
                        self.advance(); // <
                        try self.expect(.slash, "'/'");

                        var close_tok: ?Token = null;
                        if (self.check(.identifier)) {
                            close_tok = self.current;
                            self.advance();
                        }
                        if (close_tok) |tok| {
                            const close_name = tok.text(self.source);
                            if (!std.mem.eql(u8, close_name, tag_name)) {
                                self.errors.addErrorAt(.mismatched_jsx_tag, tok, "mismatched JSX closing tag");
                            }
                        }

                        try self.expect(.gt, "'>'");
                        break;
                    }

                    // Nested element
                    const child = try self.parseJsxElement();
                    try children.append(self.allocator, child);
                } else if (self.match(.lbrace)) {
                    // Expression child
                    const expr = try self.parseExpression(.none);
                    try self.expect(.rbrace, "'}'");
                    const child = try self.nodes.add(.{
                        .tag = .jsx_expr_container,
                        .loc = loc,
                        .data = .{ .opt_value = expr },
                    });
                    try children.append(self.allocator, child);
                } else {
                    // Raw text content (may include punctuation/whitespace)
                    const text_start: usize = @intCast(self.current.start);
                    var text_end: usize = text_start + self.current.len;

                    while (true) {
                        const state = self.tokenizer.saveState();
                        const next = self.tokenizer.next();
                        self.tokenizer.restoreState(state);

                        if (next.type == .lt or next.type == .lbrace or next.type == .eof) {
                            text_end = @intCast(next.start);
                            break;
                        }

                        // Consume the next token and extend the text range
                        self.advance();
                        text_end = @intCast(self.current.start + self.current.len);
                    }

                    const raw = self.source[text_start..@min(text_end, self.source.len)];
                    const trimmed = std.mem.trim(u8, raw, " \t\n\r");
                    if (trimmed.len > 0) {
                        const text_idx = try self.addString(trimmed);
                        const child = try self.nodes.add(.{
                            .tag = .jsx_text,
                            .loc = loc,
                            .data = .{ .jsx_text = text_idx },
                        });
                        try children.append(self.allocator, child);
                    }

                    // Move to the next token (<, {, or eof) for the outer loop
                    self.advance();
                }
            }
        }

        const props_count = try self.checkedU8Count(loc, props.items.len, "too many JSX props; limit is 255");
        const children_count = try self.checkedU8Count(loc, children.items.len, "too many JSX children; limit is 255");
        const props_start = if (props.items.len > 0)
            try self.addNodeList(props.items)
        else
            null_node;

        const children_start = if (children.items.len > 0)
            try self.addNodeList(children.items)
        else
            null_node;

        return try self.nodes.add(.{
            .tag = .jsx_element,
            .loc = loc,
            .data = .{ .jsx_element = .{
                .tag_atom = tag_atom,
                .is_component = is_component,
                .props_start = props_start,
                .props_count = props_count,
                .children_start = children_start,
                .children_count = children_count,
                .self_closing = self_closing,
            } },
        });
    }

    fn parseJsxFragment(self: *Parser, loc: SourceLocation) anyerror!NodeIndex {
        var children = std.ArrayList(NodeIndex).empty;
        defer children.deinit(self.allocator);

        while (!self.check(.eof)) {
            // Check for closing fragment </>
            if (self.check(.lt)) {
                if (self.peekJsxClosingTag()) {
                    self.tokenizer.can_be_regex = false;
                    self.advance(); // <
                    try self.expect(.slash, "'/'");
                    try self.expect(.gt, "'>'");
                    break;
                }

                const child = try self.parseJsxElement();
                try children.append(self.allocator, child);
            } else if (self.match(.lbrace)) {
                const expr = try self.parseExpression(.none);
                try self.expect(.rbrace, "'}'");
                const child = try self.nodes.add(.{
                    .tag = .jsx_expr_container,
                    .loc = loc,
                    .data = .{ .opt_value = expr },
                });
                try children.append(self.allocator, child);
            } else {
                // Raw text content
                const text_start: usize = @intCast(self.current.start);
                var text_end: usize = text_start + self.current.len;

                while (true) {
                    const state = self.tokenizer.saveState();
                    const next = self.tokenizer.next();
                    self.tokenizer.restoreState(state);

                    if (next.type == .lt or next.type == .lbrace or next.type == .eof) {
                        text_end = @intCast(next.start);
                        break;
                    }

                    self.advance();
                    text_end = @intCast(self.current.start + self.current.len);
                }

                const raw = self.source[text_start..@min(text_end, self.source.len)];
                const trimmed = std.mem.trim(u8, raw, " \t\n\r");
                if (trimmed.len > 0) {
                    const text_idx = try self.addString(trimmed);
                    const child = try self.nodes.add(.{
                        .tag = .jsx_text,
                        .loc = loc,
                        .data = .{ .jsx_text = text_idx },
                    });
                    try children.append(self.allocator, child);
                }

                self.advance();
            }
        }

        const children_count = try self.checkedU8Count(loc, children.items.len, "too many JSX fragment children; limit is 255");
        const children_start = if (children.items.len > 0)
            try self.addNodeList(children.items)
        else
            null_node;

        return try self.nodes.add(.{
            .tag = .jsx_fragment,
            .loc = loc,
            .data = .{ .jsx_element = .{
                .tag_atom = 0,
                .is_component = false,
                .props_start = null_node,
                .props_count = 0,
                .children_start = children_start,
                .children_count = children_count,
                .self_closing = false,
            } },
        });
    }

    // ============ Utility Functions ============

    fn advance(self: *Parser) void {
        self.previous = self.current;
        self.current = self.tokenizer.next();
        self.reportNonAsciiIdentifier();
    }

    /// Report a byte above ASCII inside an identifier, once, at the token that
    /// carries it.
    ///
    /// Identifiers are ASCII by spec 5, and the tokenizer hands the whole run
    /// back as one `invalid` token. Reporting here rather than where the token
    /// is consumed is what makes the count one: every consumer of a token goes
    /// through this funnel, and the panic mode the report enters suppresses the
    /// parse errors that follow from the same fault - `const café = 1` reported
    /// a const with no initializer and a missing expression, neither of which
    /// named the byte that caused them.
    fn reportNonAsciiIdentifier(self: *Parser) void {
        if (self.current.type != .invalid) return;
        const text = self.current.text(self.source);
        var has_non_ascii = false;
        for (text) |byte| {
            if (byte >= 0x80) has_non_ascii = true;
        }
        if (!has_non_ascii) return;
        self.errors.addError(
            .non_ascii_identifier,
            self.current.location(),
            "identifiers are ASCII: letters, digits, `_` and `$`",
        );
        self.errors.enterPanicMode();
    }

    fn check(self: *Parser, token_type: TokenType) bool {
        return self.current.type == token_type;
    }

    fn match(self: *Parser, token_type: TokenType) bool {
        if (!self.check(token_type)) return false;
        self.advance();
        return true;
    }

    fn expect(self: *Parser, token_type: TokenType, message: []const u8) !void {
        if (self.check(token_type)) {
            self.advance();
            return;
        }
        self.errors.addExpectedError(self.current, message);
        return error.UnexpectedToken;
    }

    fn expectSemicolon(self: *Parser) !void {
        if (self.match(.semicolon)) return;
        // ASI: accept implicit semicolon after } or at newline
        if (self.previous.type == .rbrace) return;
        if (self.check(.rbrace) or self.check(.eof)) return;
        // For simplicity, just accept
    }

    fn expectIdentifier(self: *Parser, ctx_label: []const u8) !Token {
        if (self.check(.identifier)) {
            const tok = self.current;
            self.advance();
            return tok;
        }
        self.errors.addExpectedError(self.current, ctx_label);
        return error.UnexpectedToken;
    }

    /// Like expectIdentifier but also accepts keywords (for property names).
    /// JavaScript allows reserved words as property names: obj.class, {public: x}
    fn expectPropertyIdentifier(self: *Parser, ctx_label: []const u8) !Token {
        if (self.check(.identifier) or self.isKeyword(self.current.type)) {
            const tok = self.current;
            self.advance();
            return tok;
        }
        self.errors.addExpectedError(self.current, ctx_label);
        return error.UnexpectedToken;
    }

    fn peekIsPropertyName(self: *Parser) bool {
        const state = self.tokenizer.saveState();
        const tok = self.tokenizer.next();
        self.tokenizer.restoreState(state);
        return tok.type == .identifier or tok.type == .string_literal or
            tok.type == .number or tok.type == .lbracket or self.isKeyword(tok.type);
    }

    /// Check if token type is a keyword (can be used as property name)
    fn isKeyword(self: *Parser, token_type: TokenType) bool {
        _ = self;
        return switch (token_type) {
            // JavaScript keywords that can be used as property names
            .kw_break,
            .kw_case,
            .kw_catch,
            .kw_continue,
            .kw_debugger,
            .kw_default,
            .kw_delete,
            .kw_do,
            .kw_else,
            .kw_finally,
            .kw_for,
            .kw_function,
            .kw_if,
            .kw_in,
            .kw_instanceof,
            .kw_new,
            .kw_return,
            .kw_switch,
            .kw_this,
            .kw_throw,
            .kw_try,
            .kw_typeof,
            .kw_var,
            .kw_void,
            .kw_while,
            .kw_with,
            .kw_class,
            .kw_const,
            .kw_export,
            .kw_extends,
            .kw_import,
            .kw_super,
            .kw_let,
            .kw_static,
            .kw_yield,
            .kw_async,
            .kw_await,
            .kw_get,
            .kw_set,
            .kw_of,
            .kw_from,
            .kw_as,
            // TypeScript keywords (allowed as property names)
            .kw_enum,
            .kw_implements,
            .kw_public,
            .kw_private,
            .kw_protected,
            // Match keywords (allowed as property names)
            .kw_match,
            .kw_when,
            // Literals that look like keywords
            .true_lit,
            .false_lit,
            .null_lit,
            // `undefined` is the documented absent-value sentinel and a valid
            // JS property name (`obj.undefined`, `{ undefined: 1 }`); accept it
            // as a name like the other literal keywords above.
            .undefined_lit,
            => true,
            else => false,
        };
    }

    fn getInfixPrecedence(self: *Parser, token_type: TokenType) Precedence {
        _ = self;
        return switch (token_type) {
            .assign, .plus_assign, .minus_assign, .star_assign, .slash_assign, .percent_assign, .ampersand_assign, .pipe_assign, .caret_assign, .lt_lt_assign, .gt_gt_assign, .gt_gt_gt_assign, .star_star_assign, .ampersand_ampersand_assign, .pipe_pipe_assign, .question_question_assign => .assignment,
            .pipe_gt => .pipe_op,
            .question => .ternary,
            .question_question => .nullish,
            .pipe_pipe => .or_op,
            .ampersand_ampersand => .and_op,
            .pipe => .bit_or,
            .caret => .bit_xor,
            .ampersand => .bit_and,
            .eq, .ne, .eq_eq, .ne_ne => .equality,
            .lt, .le, .gt, .ge, .kw_in, .kw_instanceof => .comparison,
            .lt_lt, .gt_gt, .gt_gt_gt => .shift,
            .plus, .minus => .additive,
            .star, .slash, .percent => .multiplicative,
            .star_star => .exponent,
            .lparen, .lbracket, .dot, .question_dot => .call,
            .plus_plus, .minus_minus => .postfix,
            else => .none,
        };
    }

    fn tokenToBinaryOp(self: *Parser, token_type: TokenType) BinaryOp {
        _ = self;
        return switch (token_type) {
            .plus, .plus_assign => .add,
            .minus, .minus_assign => .sub,
            .star, .star_assign => .mul,
            .slash, .slash_assign => .div,
            .percent, .percent_assign => .mod,
            .star_star, .star_star_assign => .pow,
            .eq_eq => .strict_eq,
            .ne_ne => .strict_neq,
            // `.eq` and `.ne` are deliberately absent. parseInfixExpr consumes
            // both in their own prongs, which build `.loose_eq`/`.loose_neq`
            // only when `expression_profile` is set and otherwise reject the
            // source. Mapping them here would look like the sanctioned spelling
            // while skipping that guard, admitting `==` into handler source.
            .lt => .lt,
            .le => .lte,
            .gt => .gt,
            .ge => .gte,
            .ampersand, .ampersand_assign => .bit_and,
            .pipe, .pipe_assign => .bit_or,
            .caret, .caret_assign => .bit_xor,
            .lt_lt, .lt_lt_assign => .shl,
            .gt_gt, .gt_gt_assign => .shr,
            .gt_gt_gt, .gt_gt_gt_assign => .ushr,
            .ampersand_ampersand => .and_op,
            .pipe_pipe => .or_op,
            .question_question => .nullish,
            .kw_in => .in_op,
            else => .add,
        };
    }

    fn errorAtCurrent(self: *Parser, message: []const u8) void {
        self.errors.addErrorAt(.unexpected_token, self.current, message);
    }

    fn errorAt(self: *Parser, loc: SourceLocation, message: []const u8) void {
        self.errors.addError(.unexpected_token, loc, message);
    }

    fn checkedU8Count(self: *Parser, loc: SourceLocation, count: usize, message: []const u8) !u8 {
        if (count > std.math.maxInt(u8)) {
            self.errorAt(loc, message);
            return error.ParseError;
        }
        return @intCast(count);
    }

    fn checkedU16Count(self: *Parser, loc: SourceLocation, count: usize, message: []const u8) !u16 {
        if (count > std.math.maxInt(u16)) {
            self.errorAt(loc, message);
            return error.ParseError;
        }
        return @intCast(count);
    }

    fn synchronize(self: *Parser) void {
        self.errors.enterPanicMode();

        while (!self.check(.eof)) {
            if (self.previous.type == .semicolon) {
                self.errors.exitPanicMode();
                return;
            }

            switch (self.current.type) {
                .kw_class, .kw_function, .kw_var, .kw_let, .kw_const, .kw_for, .kw_if, .kw_while, .kw_return, .kw_try, .kw_enum => {
                    self.errors.exitPanicMode();
                    return;
                },
                else => {},
            }

            self.advance();
        }
        self.errors.exitPanicMode();
    }

    // ============ Pipe Composition ============

    /// Check if a callee node is the `pipe` binding from zttp:compose
    fn isPipeCall(self: *const Parser, callee: NodeIndex) bool {
        const pipe_slot = self.pipe_binding_slot orelse return false;
        if (self.nodes.getTag(callee) != .identifier) return false;
        const binding = self.nodes.getBinding(callee);
        return binding.slot == pipe_slot;
    }

    /// Desugar pipe(f1, f2, ..., fN) into nested calls: fN(...(f2(f1()))...)
    /// First function is called with no args, each subsequent receives the previous result.
    fn desugarPipeCall(self: *Parser, loc: SourceLocation, funcs: []const NodeIndex) !NodeIndex {
        // Call first function with zero args: f1()
        var result = try self.nodes.add(.{
            .tag = .call,
            .loc = loc,
            .data = .{ .call = .{
                .callee = funcs[0],
                .args_start = null_node,
                .args_count = 0,
                .is_optional = false,
            } },
        });

        // Chain remaining: f2(prev), f3(prev), ...
        for (funcs[1..]) |func| {
            const args_start = try self.addNodeList(&[_]NodeIndex{result});
            result = try self.nodes.add(.{
                .tag = .call,
                .loc = loc,
                .data = .{ .call = .{
                    .callee = func,
                    .args_start = args_start,
                    .args_count = 1,
                    .is_optional = false,
                } },
            });
        }

        return result;
    }

    // ============ Guard Composition ============

    /// Check if a node is a guard() call (callee matches guard_binding_slot)
    fn isGuardCall(self: *const Parser, node_idx: NodeIndex) bool {
        const guard_slot = self.guard_binding_slot orelse return false;
        if (self.nodes.getTag(node_idx) != .call) return false;
        const call = self.nodes.getCallData(node_idx) orelse return false;
        if (call.args_count != 1) return false;
        if (self.nodes.getTag(call.callee) != .identifier) return false;
        const binding = self.nodes.getBinding(call.callee);
        return binding.slot == guard_slot;
    }

    /// Extract the guard function argument from a guard(fn) call node
    fn extractGuardArg(self: *const Parser, node_idx: NodeIndex) ?NodeIndex {
        const call = self.nodes.getCallData(node_idx) orelse return null;
        return self.nodes.getListIndex(call.args_start, 0);
    }

    /// Check if any element in a pipe chain is a guard() call
    fn chainHasGuards(self: *const Parser, chain: []const NodeIndex) bool {
        for (chain) |elem| {
            if (self.isGuardCall(elem)) return true;
        }
        return false;
    }

    /// Desugar a guard pipe chain into a flat arrow function.
    ///
    /// Input chain: [guard(g1), guard(g2), handler, guard(p1)]
    /// Output: (req) => {
    ///     const __g0 = g1(req); if (__g0 !== undefined) return __g0;
    ///     const __g1 = g2(req); if (__g1 !== undefined) return __g1;
    ///     const __res = handler(req);
    ///     const __p0 = p1(__res); if (__p0 !== undefined) return __p0;
    ///     return __res;
    /// }
    fn desugarGuardComposition(self: *Parser, loc: SourceLocation, chain: []const NodeIndex) anyerror!NodeIndex {
        // Classify chain elements into pre-guards, handler, post-guards
        var handler_idx: ?usize = null;
        var non_guard_count: usize = 0;

        for (chain, 0..) |elem, i| {
            if (!self.isGuardCall(elem)) {
                non_guard_count += 1;
                if (handler_idx == null) {
                    handler_idx = i;
                }
            }
        }

        // Validation
        if (non_guard_count == 0) {
            self.errorAt(loc, "guard composition requires a handler function");
            return error.ParseError;
        }
        if (non_guard_count > 1) {
            self.errorAt(loc, "guard composition allows exactly one handler");
            return error.ParseError;
        }

        const handler_pos = handler_idx.?;

        // Create a new function scope for the synthetic arrow function
        const scope_id = try self.scopes.pushScope(.function);
        const was_in_function = self.in_function;
        self.in_function = true;

        // Declare the req parameter
        const req_atom = try self.addAtom("__req");
        const req_binding = self.scopes.declareBinding(
            "__req",
            req_atom,
            .parameter,
            false,
        ) catch return error.TooManyLocals;

        // Create parameter node
        const param_node = try self.nodes.add(.{
            .tag = .pattern_element,
            .loc = loc,
            .data = .{ .pattern_elem = .{
                .kind = .simple,
                .binding = req_binding,
                .key = null_node,
                .key_atom = 0,
                .default_value = null_node,
            } },
        });

        // Build the body statements
        var stmts = std.ArrayList(NodeIndex).empty;
        defer stmts.deinit(self.allocator);

        // Pre-guards: all elements before handler_pos are guards (by classification invariant)
        var local_counter: u16 = 0;
        for (chain[0..handler_pos]) |elem| {
            const guard_fn = self.extractGuardArg(elem) orelse continue;
            try self.emitGuardCheck(&stmts, loc, guard_fn, req_binding, &local_counter);
        }

        // Handler call - check if post-guards exist (all post-handler elements are guards)
        const has_post_guards = handler_pos + 1 < chain.len;

        if (has_post_guards) {
            // Capture handler result for post-guards
            const res_atom = try self.addAtom("__res");
            const res_binding = self.scopes.declareBinding(
                "__res",
                res_atom,
                .variable,
                true,
            ) catch return error.TooManyLocals;

            // __res = handler(req)
            const handler_call = try self.emitCallWithArg(loc, chain[handler_pos], req_binding);
            const res_decl = try self.nodes.add(.{
                .tag = .var_decl,
                .loc = loc,
                .data = .{ .var_decl = .{
                    .binding = res_binding,
                    .pattern = null_node,
                    .init = handler_call,
                    .kind = .@"const",
                } },
            });
            try stmts.append(self.allocator, res_decl);

            // Post-guards: all elements after handler are guards (by classification invariant)
            for (chain[handler_pos + 1 ..]) |elem| {
                const guard_fn = self.extractGuardArg(elem) orelse continue;
                try self.emitGuardCheck(&stmts, loc, guard_fn, res_binding, &local_counter);
            }

            // return __res
            const res_ref = try self.nodes.addIdentifier(loc, res_binding);
            const final_return = try self.nodes.add(.{
                .tag = .return_stmt,
                .loc = loc,
                .data = .{ .opt_value = res_ref },
            });
            try stmts.append(self.allocator, final_return);
        } else {
            // No post-guards: return handler(req) directly
            const handler_call = try self.emitCallWithArg(loc, chain[handler_pos], req_binding);
            const handler_return = try self.nodes.add(.{
                .tag = .return_stmt,
                .loc = loc,
                .data = .{ .opt_value = handler_call },
            });
            try stmts.append(self.allocator, handler_return);
        }

        // Create the block body. Push/pop an empty scope to get a valid scope_id
        // for BlockData (all bindings live in the enclosing function scope).
        const block_scope = try self.scopes.pushScope(.block);
        self.scopes.popScope();

        const stmts_count = try self.checkedU16Count(loc, stmts.items.len, "too many guard-composition statements; limit is 65535");
        const stmts_start = try self.addStmtList(stmts.items);
        const body = try self.nodes.add(.{
            .tag = .block,
            .loc = loc,
            .data = .{ .block = .{
                .stmts_start = stmts_start,
                .stmts_count = stmts_count,
                .scope_id = block_scope,
            } },
        });

        self.in_function = was_in_function;
        self.scopes.popScope();

        // Create the arrow function
        const params_start = try self.addNodeList(&[_]NodeIndex{param_node});
        return try self.nodes.add(.{
            .tag = .arrow_function,
            .loc = loc,
            .data = .{ .function = .{
                .scope_id = scope_id,
                .name_atom = 0,
                .params_start = params_start,
                .params_count = 1,
                .body = body,
                .flags = .{ .is_arrow = true },
            } },
        });
    }

    /// Emit a guard check: const __gN = guard_fn(arg); if (__gN !== undefined) return __gN;
    fn emitGuardCheck(
        self: *Parser,
        stmts: *std.ArrayList(NodeIndex),
        loc: SourceLocation,
        guard_fn: NodeIndex,
        arg_binding: BindingRef,
        counter: *u16,
    ) !void {

        // Create temp variable name: __g0, __g1, etc.
        var name_buf: [16]u8 = undefined;
        const name = std.fmt.bufPrint(&name_buf, "__g{d}", .{counter.*}) catch unreachable;
        counter.* += 1;

        const temp_atom = try self.addAtom(name);
        const temp_binding = self.scopes.declareBinding(
            name,
            temp_atom,
            .variable,
            true,
        ) catch return error.TooManyLocals;

        // const __gN = guard_fn(arg)
        const call_node = try self.emitCallWithArg(loc, guard_fn, arg_binding);
        const var_decl = try self.nodes.add(.{
            .tag = .var_decl,
            .loc = loc,
            .data = .{ .var_decl = .{
                .binding = temp_binding,
                .pattern = null_node,
                .init = call_node,
                .kind = .@"const",
            } },
        });
        try stmts.append(self.allocator, var_decl);

        // if (__gN !== undefined) return __gN
        const temp_ref1 = try self.nodes.addIdentifier(loc, temp_binding);
        const undef_node = try self.nodes.add(.{
            .tag = .lit_undefined,
            .loc = loc,
            .data = .{ .none = {} },
        });
        const condition = try self.nodes.add(Node.binaryOp(loc, .strict_neq, temp_ref1, undef_node));

        const temp_ref2 = try self.nodes.addIdentifier(loc, temp_binding);
        const return_stmt = try self.nodes.add(.{
            .tag = .return_stmt,
            .loc = loc,
            .data = .{ .opt_value = temp_ref2 },
        });

        const if_stmt = try self.nodes.add(.{
            .tag = .if_stmt,
            .loc = loc,
            .data = .{ .if_stmt = .{
                .condition = condition,
                .then_branch = return_stmt,
                .else_branch = null_node,
            } },
        });
        try stmts.append(self.allocator, if_stmt);
    }

    /// Create a call node: callee(arg_binding)
    fn emitCallWithArg(self: *Parser, loc: SourceLocation, callee: NodeIndex, arg_binding: BindingRef) !NodeIndex {
        const arg_ref = try self.nodes.addIdentifier(loc, arg_binding);
        const args_start = try self.addNodeList(&[_]NodeIndex{arg_ref});
        return try self.nodes.add(.{
            .tag = .call,
            .loc = loc,
            .data = .{ .call = .{
                .callee = callee,
                .args_start = args_start,
                .args_count = 1,
                .is_optional = false,
            } },
        });
    }

    // ============ Node List Helpers ============

    fn addNodeList(self: *Parser, indices: []const NodeIndex) anyerror!NodeIndex {
        // Store the list of indices in the node list's index storage
        return try self.nodes.addIndexList(indices);
    }

    fn addStmtList(self: *Parser, stmts: []const NodeIndex) anyerror!NodeIndex {
        return self.addNodeList(stmts);
    }

    fn addString(self: *Parser, str: []const u8) !u16 {
        return try self.constants.addString(str);
    }

    const UnescapedString = struct {
        bytes: []const u8,
        allocation: ?[]u8 = null,

        fn deinit(self: UnescapedString, allocator: std.mem.Allocator) void {
            if (self.allocation) |allocation| allocator.free(allocation);
        }
    };

    /// Unescape `content` then intern it. Frees the unescape buffer when it was
    /// freshly allocated (i.e. the input contained backslashes), regardless of
    /// whether the string was new or a duplicate in the constant pool.
    ///
    /// Template literals unescape through the same table as quoted strings.
    /// They always did on the normal profile, and a comptime-folded literal has
    /// to be byte-identical to the same literal written outside `comptime(...)`.
    /// Decode a string literal's content, reporting a closed-escape-set
    /// violation as a located diagnostic rather than propagating a bare error.
    /// The two faults are distinct to a reader and carry different repairs, so
    /// they carry different codes.
    fn unescapedStringOrDiagnostic(self: *Parser, content: []const u8, loc: SourceLocation) !u16 {
        return self.addUnescapedString(content) catch |err| switch (err) {
            error.InvalidEscapeSequence => {
                self.errors.addError(
                    .invalid_escape_sequence,
                    loc,
                    "unknown escape sequence; the escape set is closed to \\n \\r \\t \\b \\f \\v \\0 \\\\ \\' \\\" \\` \\$ \\xNN \\uNNNN and \\u{N..}",
                );
                return err;
            },
            error.StringLineContinuation => {
                self.errors.addError(
                    .string_line_continuation,
                    loc,
                    "a string may not continue across a line; join the lines, or write the newline as \\n",
                );
                return err;
            },
            else => return err,
        };
    }

    fn addUnescapedString(self: *Parser, content: []const u8) !u16 {
        const unescaped = try self.unescape(content);
        defer unescaped.deinit(self.allocator);
        return self.addString(unescaped.bytes);
    }

    /// Decode the `\uNNNN` or `\u{N..}` escape that starts at the backslash
    /// `input[at]`, and report the index just past it.
    fn decodeUnicodeEscape(input: []const u8, at: usize) !struct { codepoint: u21, next: usize } {
        if (at + 2 < input.len and input[at + 2] == '{') {
            // Only a `}` within six digits can produce an accepted answer, so
            // bound the search there rather than scanning the whole literal to
            // reject it.
            const limit = @min(at + 10, input.len);
            const close = std.mem.indexOfScalarPos(u8, input[0..limit], at + 3, '}') orelse
                return error.InvalidEscapeSequence;
            const hex = input[at + 3 .. close];
            if (hex.len == 0) return error.InvalidEscapeSequence;
            return .{
                .codepoint = std.fmt.parseInt(u21, hex, 16) catch return error.InvalidEscapeSequence,
                .next = close + 1,
            };
        }
        if (at + 5 >= input.len) return error.InvalidEscapeSequence;
        return .{
            .codepoint = std.fmt.parseInt(u16, input[at + 2 .. at + 6], 16) catch
                return error.InvalidEscapeSequence,
            .next = at + 6,
        };
    }

    /// Unescape a JavaScript string literal, converting escape sequences to
    /// actual characters. Handles `\n`, `\r`, `\t`, `\b`, `\f`, `\v`, `\\`,
    /// `\'`, `\"`, `\0`, `\xNN`, `\uNNNN`, and `\u{N..}`; every other escape
    /// emits the character that follows the backslash.
    ///
    /// The two profiles no longer differ here. The comptime profile used to be
    /// the strict one and the normal profile copied a malformed escape through
    /// literally, which meant a literal could be legal outside `comptime(...)`
    /// and refused inside it - and, worse, that a mistyped escape silently
    /// changed the string. The set is closed for both, so there is nothing left
    /// to parameterize.
    ///
    /// Returns the original input on the fast path, or an owned allocation plus
    /// the used byte range when escape decoding shortens the string.
    fn unescape(self: *Parser, input: []const u8) !UnescapedString {
        if (std.mem.indexOfScalar(u8, input, '\\') == null) return .{ .bytes = input };

        // The decoded form is never longer than the input: every escape emits
        // at most as many bytes as its backslash sequence occupies.
        var result = try self.allocator.alloc(u8, input.len);
        errdefer self.allocator.free(result);
        var out_pos: usize = 0;
        var i: usize = 0;

        while (i < input.len) {
            if (input[i] != '\\' or i + 1 >= input.len) {
                // A trailing backslash escapes the closing quote in every
                // reading, so the literal it appears in is malformed.
                if (input[i] == '\\') return error.InvalidEscapeSequence;
                result[out_pos] = input[i];
                out_pos += 1;
                i += 1;
                continue;
            }

            const escaped = input[i + 1];
            switch (escaped) {
                'x' => {
                    const decoded: ?u8 = if (i + 3 < input.len)
                        std.fmt.parseInt(u8, input[i + 2 .. i + 4], 16) catch null
                    else
                        null;
                    if (decoded) |byte| {
                        result[out_pos] = byte;
                        out_pos += 1;
                        i += 4;
                        continue;
                    }
                    return error.InvalidEscapeSequence;
                },
                'u' => {
                    if (decodeUnicodeEscape(input, i)) |decoded| {
                        if (std.unicode.utf8Encode(decoded.codepoint, result[out_pos..])) |len| {
                            out_pos += len;
                            i = decoded.next;
                            continue;
                        } else |_| {}
                    } else |_| {}
                    return error.InvalidEscapeSequence;
                },
                // A backslash before a real newline. JavaScript reads it as a
                // line continuation and emits nothing; D3 section 1 refuses it,
                // because a string that spans a line reads as two strings to
                // everyone but the compiler. Refused in both profiles: a
                // comptime-folded literal and the same literal written outside
                // `comptime(...)` must not disagree about what is legal.
                '\n', '\r' => return error.StringLineContinuation,
                else => {
                    result[out_pos] = switch (escaped) {
                        'n' => '\n',
                        'r' => '\r',
                        't' => '\t',
                        'b' => 0x08, // backspace
                        'f' => 0x0C, // form feed
                        'v' => 0x0B, // vertical tab
                        '0' => 0,
                        // The rest of the closed set: an escaped delimiter or
                        // backslash stands for itself.
                        '\\', '\'', '"', '`', '$' => escaped,
                        // Every other byte closes the set rather than copying
                        // through. `\q` emitted `q`, so a mistyped escape
                        // produced a string the author did not write and no
                        // diagnostic said so.
                        else => return error.InvalidEscapeSequence,
                    };
                    out_pos += 1;
                    i += 2;
                },
            }
        }

        return .{ .bytes = result[0..out_pos], .allocation = result };
    }

    fn addAtom(self: *Parser, name: []const u8) !u16 {
        // Check predefined atoms first (e.g., "handler" -> 159)
        if (object.lookupPredefinedAtom(name)) |atom| {
            return @truncate(@intFromEnum(atom));
        }
        // Intern dynamic atoms if atom table is available
        if (self.atoms) |atoms| {
            const atom = try atoms.intern(name);
            return @truncate(@intFromEnum(atom));
        }
        // Fall back to string constant pool for dynamic atoms (standalone parser)
        return try self.constants.addString(name);
    }

    // ============ Public API ============

    pub fn enableJsx(self: *Parser) void {
        self.tokenizer.enableJsx();
    }

    pub fn hasErrors(self: *const Parser) bool {
        return self.errors.hasErrors();
    }

    pub fn getErrors(self: *const Parser) []const error_mod.ParseError {
        return self.errors.getErrors();
    }
};

// ============ Tests ============

test "ASI: return on its own line has no argument" {
    var parser = try Parser.init(std.testing.allocator,
        \\function handler(req) {
        \\  return
        \\  Response.json({ leaked: true });
        \\}
    );
    defer parser.deinit();
    _ = parser.parse() catch {};

    var found_return = false;
    var return_has_arg = false;
    for (parser.nodes.tags.items, 0..) |tag, i| {
        if (tag == .return_stmt) {
            found_return = true;
            return_has_arg = parser.nodes.getData(@intCast(i)).a != null_node;
        }
    }
    // Per JS ASI, a newline after 'return' forces `return;` -> opt_value should be null_node.
    try std.testing.expect(found_return);
    try std.testing.expect(!return_has_arg);
}

test "parse simple expression" {
    var parser = try Parser.init(std.testing.allocator, "1 + 2;");
    defer parser.deinit();

    const result = parser.parse() catch {
        try std.testing.expect(false);
        return;
    };

    try std.testing.expect(result != null_node);
    try std.testing.expect(!parser.hasErrors());
}

test "parse variable declaration" {
    var parser = try Parser.init(std.testing.allocator, "let x = 42;");
    defer parser.deinit();

    const result = parser.parse() catch {
        try std.testing.expect(false);
        return;
    };

    try std.testing.expect(result != null_node);
    try std.testing.expect(!parser.hasErrors());
}

test "parse escaped string literal owns the full temporary buffer" {
    var parser = try Parser.init(std.testing.allocator, "const s = \"{\\\"type\\\":\\\"object\\\"}\";");
    defer parser.deinit();

    const result = try parser.parse();

    try std.testing.expect(result != null_node);
    try std.testing.expect(!parser.hasErrors());
    var found = false;
    for (parser.constants.strings.items) |value| {
        if (std.mem.eql(u8, value, "{\"type\":\"object\"}")) {
            found = true;
            break;
        }
    }
    try std.testing.expect(found);
}

test "parse function declaration" {
    var parser = try Parser.init(std.testing.allocator,
        \\function add(a, b) {
        \\  return a + b;
        \\}
    );
    defer parser.deinit();

    const result = parser.parse() catch {
        try std.testing.expect(false);
        return;
    };

    try std.testing.expect(result != null_node);
    try std.testing.expect(!parser.hasErrors());
}

test "parse arrow function" {
    var parser = try Parser.init(std.testing.allocator, "const f = (x) => x * 2;");
    defer parser.deinit();

    const result = parser.parse() catch {
        try std.testing.expect(false);
        return;
    };

    try std.testing.expect(result != null_node);
    try std.testing.expect(!parser.hasErrors());
}

test "parse template literal" {
    var parser = try Parser.init(std.testing.allocator, "const s = `hello ${name}!`;");
    defer parser.deinit();

    const result = parser.parse() catch {
        try std.testing.expect(false);
        return;
    };

    try std.testing.expect(result != null_node);
    try std.testing.expect(!parser.hasErrors());
}

test "parse object literal" {
    var parser = try Parser.init(std.testing.allocator, "const obj = { x: 1, y: 2 };");
    defer parser.deinit();

    const result = parser.parse() catch {
        try std.testing.expect(false);
        return;
    };

    try std.testing.expect(result != null_node);
    try std.testing.expect(!parser.hasErrors());
}

test "parse class rejected" {
    var parser = try Parser.init(std.testing.allocator,
        \\class Foo {}
    );
    defer parser.deinit();

    _ = parser.parse() catch {
        // Expected: class is not supported
        try std.testing.expect(parser.hasErrors());
        return;
    };

    // Should have errored
    try std.testing.expect(false);
}

test "parse regex literal rejected" {
    var parser = try Parser.init(std.testing.allocator,
        \\const r = /ab+/;
    );
    defer parser.deinit();

    _ = parser.parse() catch {
        try std.testing.expect(parser.hasErrors());
        return;
    };

    try std.testing.expect(false);
}

test "parse local Promise identifier" {
    var parser = try Parser.init(std.testing.allocator,
        \\const Promise = 1;
        \\Promise;
    );
    defer parser.deinit();

    const result = parser.parse() catch {
        try std.testing.expect(false);
        return;
    };

    try std.testing.expect(result != null_node);
    try std.testing.expect(!parser.hasErrors());
}

test "parse closure creates upvalue" {
    var parser = try Parser.init(std.testing.allocator,
        \\function outer(x) {
        \\  return () => x;
        \\}
    );
    defer parser.deinit();

    const result = parser.parse() catch {
        try std.testing.expect(false);
        return;
    };

    try std.testing.expect(result != null_node);
    try std.testing.expect(!parser.hasErrors());

    // Verify upvalue was created in one of the scopes
    // Scope 0 = global, scope 1 = outer function, scope 2 = outer block, scope 3 = arrow function
    var found_upvalue = false;
    for (parser.scopes.scopes.items) |scope| {
        if (scope.upvalues.items.len > 0) {
            found_upvalue = true;
            break;
        }
    }
    try std.testing.expect(found_upvalue);
}

test "parse object destructuring" {
    const allocator = std.testing.allocator;
    const source =
        \\const { name, age } = obj;
        \\const { x: localX, y = 10 } = point;
    ;

    var parser = try Parser.init(allocator, source);
    defer parser.deinit();

    const result = parser.parse() catch {
        try std.testing.expect(false);
        return;
    };

    try std.testing.expect(result != null_node);
    try std.testing.expect(!parser.hasErrors());
}

test "parse array destructuring" {
    const allocator = std.testing.allocator;
    const source =
        \\const [a, b, c] = arr;
        \\let [x, , y] = [1, 2, 3];
    ;

    var parser = try Parser.init(allocator, source);
    defer parser.deinit();

    const result = parser.parse() catch {
        try std.testing.expect(false);
        return;
    };

    try std.testing.expect(result != null_node);
    try std.testing.expect(!parser.hasErrors());
}

// ============================================================================
// Resource-limit Tests
// ============================================================================

test "resource limit: deeply nested parentheses yield a diagnostic, not a crash" {
    const allocator = std.testing.allocator;
    // Far beyond max_recursion_depth. Before the depth guard this recursed once
    // per paren and stack-overflowed (SIGSEGV), taking down the host process.
    const depth = 5000;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    try buf.appendNTimes(allocator, '(', depth);
    try buf.append(allocator, '1');
    try buf.appendNTimes(allocator, ')', depth);

    var parser = try Parser.init(allocator, buf.items);
    defer parser.deinit();

    _ = parser.parse() catch {
        try std.testing.expect(parser.hasErrors());
        var saw_depth = false;
        for (parser.getErrors()) |e| {
            if (e.kind == .nesting_too_deep) saw_depth = true;
        }
        try std.testing.expect(saw_depth);
        return;
    };
    // Pathological nesting must not parse successfully.
    try std.testing.expect(false);
}

test "resource limit: too many call arguments yields a diagnostic, not a crash" {
    const allocator = std.testing.allocator;
    var source: std.ArrayList(u8) = .empty;
    defer source.deinit(allocator);

    try source.appendSlice(allocator, "f(");
    for (0..256) |i| {
        if (i > 0) try source.append(allocator, ',');
        try source.append(allocator, '1');
    }
    try source.appendSlice(allocator, ");");

    var parser = try Parser.init(allocator, source.items);
    defer parser.deinit();

    _ = parser.parse() catch {
        try std.testing.expect(parser.hasErrors());
        const errors = parser.getErrors();
        try std.testing.expect(errors.len > 0);
        try std.testing.expect(std.mem.indexOf(u8, errors[0].message, "too many call arguments") != null);
        return;
    };

    try std.testing.expect(false);
}

test "resource limit: too many import specifiers yields a diagnostic, not a crash" {
    const allocator = std.testing.allocator;
    var source: std.ArrayList(u8) = .empty;
    defer source.deinit(allocator);

    try source.appendSlice(allocator, "import {");
    for (0..256) |i| {
        if (i > 0) try source.append(allocator, ',');
        var name_buf: [16]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "a{d}", .{i});
        try source.appendSlice(allocator, name);
    }
    try source.appendSlice(allocator, "} from \"zttp:env\";");

    var parser = try Parser.init(allocator, source.items);
    defer parser.deinit();

    _ = parser.parse() catch {
        try std.testing.expect(parser.hasErrors());
        const errors = parser.getErrors();
        try std.testing.expect(errors.len > 0);
        try std.testing.expect(std.mem.indexOf(u8, errors[0].message, "too many import specifiers") != null);
        return;
    };

    try std.testing.expect(false);
}

// ============================================================================
// Unsupported Feature Detection Tests
// ============================================================================

test "unsupported: async function rejected at parse time" {
    const allocator = std.testing.allocator;
    const source = "const h = async function() { return 1; };";
    var parser = try Parser.init(allocator, source);
    defer parser.deinit();
    _ = parser.parse() catch {
        try std.testing.expect(parser.hasErrors());
        const errors = parser.getErrors();
        try std.testing.expect(errors.len > 0);
        try std.testing.expectEqual(error_mod.ErrorKind.unsupported_feature, errors[0].kind);
        try std.testing.expect(std.mem.indexOf(u8, errors[0].message, "async") != null);
        return;
    };
    try std.testing.expect(false);
}

test "unsupported: await rejected at parse time" {
    const allocator = std.testing.allocator;
    const source = "function handler(req) { const x = await foo(); return Response.json({x}); }";
    var parser = try Parser.init(allocator, source);
    defer parser.deinit();
    _ = parser.parse() catch {
        try std.testing.expect(parser.hasErrors());
        const errors = parser.getErrors();
        try std.testing.expect(errors.len > 0);
        try std.testing.expectEqual(error_mod.ErrorKind.invalid_await, errors[0].kind);
        return;
    };
    try std.testing.expect(false);
}

test "unsupported: class statement" {
    const allocator = std.testing.allocator;
    const source = "class Foo { }";

    var parser = try Parser.init(allocator, source);
    defer parser.deinit();

    _ = parser.parse() catch {
        try std.testing.expect(parser.hasErrors());
        const errors = parser.getErrors();
        try std.testing.expect(errors.len > 0);
        const err = errors[0];
        try std.testing.expectEqual(error_mod.ErrorKind.unsupported_feature, err.kind);
        try std.testing.expect(std.mem.indexOf(u8, err.message, "class") != null);
        try std.testing.expect(std.mem.indexOf(u8, err.message, "plain objects") != null);
        return;
    };

    // Should have errored
    try std.testing.expect(false);
}

test "unsupported: class expression" {
    const allocator = std.testing.allocator;
    const source = "const X = class Foo { };";

    var parser = try Parser.init(allocator, source);
    defer parser.deinit();

    _ = parser.parse() catch {
        try std.testing.expect(parser.hasErrors());
        const errors = parser.getErrors();
        try std.testing.expect(errors.len > 0);
        const err = errors[0];
        try std.testing.expectEqual(error_mod.ErrorKind.unsupported_feature, err.kind);
        try std.testing.expect(std.mem.indexOf(u8, err.message, "class") != null);
        try std.testing.expect(std.mem.indexOf(u8, err.message, "plain objects") != null);
        return;
    };

    try std.testing.expect(false);
}

test "unsupported: while loop" {
    const allocator = std.testing.allocator;
    const source = "while (true) { }";

    var parser = try Parser.init(allocator, source);
    defer parser.deinit();

    _ = parser.parse() catch {
        try std.testing.expect(parser.hasErrors());
        const errors = parser.getErrors();
        try std.testing.expect(errors.len > 0);
        const err = errors[0];
        try std.testing.expectEqual(error_mod.ErrorKind.unsupported_feature, err.kind);
        try std.testing.expect(std.mem.indexOf(u8, err.message, "while") != null);
        try std.testing.expect(std.mem.indexOf(u8, err.message, "for-of") != null);
        return;
    };

    try std.testing.expect(false);
}

test "unsupported: do-while loop" {
    const allocator = std.testing.allocator;
    const source = "do { } while (true);";

    var parser = try Parser.init(allocator, source);
    defer parser.deinit();

    _ = parser.parse() catch {
        try std.testing.expect(parser.hasErrors());
        const errors = parser.getErrors();
        try std.testing.expect(errors.len > 0);
        const err = errors[0];
        try std.testing.expectEqual(error_mod.ErrorKind.unsupported_feature, err.kind);
        try std.testing.expect(std.mem.indexOf(u8, err.message, "do-while") != null);
        return;
    };

    try std.testing.expect(false);
}

test "unsupported: switch statement" {
    const allocator = std.testing.allocator;
    const source = "switch (x) { case 1: break; }";

    var parser = try Parser.init(allocator, source);
    defer parser.deinit();

    _ = parser.parse() catch {
        try std.testing.expect(parser.hasErrors());
        const errors = parser.getErrors();
        try std.testing.expect(errors.len > 0);
        const err = errors[0];
        try std.testing.expectEqual(error_mod.ErrorKind.unsupported_feature, err.kind);
        try std.testing.expect(std.mem.indexOf(u8, err.message, "switch") != null);
        try std.testing.expect(std.mem.indexOf(u8, err.message, "match") != null);
        return;
    };

    try std.testing.expect(false);
}

test "assert statement parses" {
    const allocator = std.testing.allocator;
    var parser = try Parser.init(allocator, "assert isString(val);");
    defer parser.deinit();
    _ = parser.parse() catch {
        try std.testing.expect(false);
        return;
    };
    try std.testing.expect(!parser.hasErrors());
}

test "assert statement with error expression parses" {
    const allocator = std.testing.allocator;
    var parser = try Parser.init(allocator, "assert isString(val), Response.json({ error: 'bad' });");
    defer parser.deinit();
    _ = parser.parse() catch {
        try std.testing.expect(false);
        return;
    };
    try std.testing.expect(!parser.hasErrors());
}

test "break in for-of" {
    var parser = try Parser.init(std.testing.allocator, "for (const x of arr) { break; }");
    defer parser.deinit();

    const result = parser.parse() catch {
        try std.testing.expect(false);
        return;
    };

    try std.testing.expect(result != null_node);
    try std.testing.expect(!parser.hasErrors());
}

test "continue in for-of" {
    var parser = try Parser.init(std.testing.allocator, "for (const x of arr) { continue; }");
    defer parser.deinit();

    const result = parser.parse() catch {
        try std.testing.expect(false);
        return;
    };

    try std.testing.expect(result != null_node);
    try std.testing.expect(!parser.hasErrors());
}

test "break outside loop" {
    var parser = try Parser.init(std.testing.allocator, "break;");
    defer parser.deinit();

    _ = parser.parse() catch {
        try std.testing.expect(parser.hasErrors());
        return;
    };

    try std.testing.expect(false);
}

test "continue outside loop" {
    var parser = try Parser.init(std.testing.allocator, "continue;");
    defer parser.deinit();

    _ = parser.parse() catch {
        try std.testing.expect(parser.hasErrors());
        return;
    };

    try std.testing.expect(false);
}

test "labeled break rejected" {
    var parser = try Parser.init(std.testing.allocator, "for (const x of arr) { break label; }");
    defer parser.deinit();

    _ = parser.parse() catch {
        try std.testing.expect(parser.hasErrors());
        const errors = parser.getErrors();
        try std.testing.expect(errors.len > 0);
        try std.testing.expectEqual(error_mod.ErrorKind.unsupported_feature, errors[0].kind);
        try std.testing.expect(std.mem.indexOf(u8, errors[0].message, "labeled break") != null);
        return;
    };

    try std.testing.expect(false);
}

test "break with conditional" {
    var parser = try Parser.init(std.testing.allocator, "for (const x of arr) { if (x === 3) break; }");
    defer parser.deinit();

    const result = parser.parse() catch {
        try std.testing.expect(false);
        return;
    };

    try std.testing.expect(result != null_node);
    try std.testing.expect(!parser.hasErrors());
}

test "unsupported: throw statement" {
    const allocator = std.testing.allocator;
    const source = "throw new Error('test');";

    var parser = try Parser.init(allocator, source);
    defer parser.deinit();

    _ = parser.parse() catch {
        try std.testing.expect(parser.hasErrors());
        const errors = parser.getErrors();
        try std.testing.expect(errors.len > 0);
        const err = errors[0];
        try std.testing.expectEqual(error_mod.ErrorKind.unsupported_feature, err.kind);
        try std.testing.expect(std.mem.indexOf(u8, err.message, "throw") != null);
        try std.testing.expect(std.mem.indexOf(u8, err.message, "Result") != null);
        return;
    };

    try std.testing.expect(false);
}

test "unsupported: try-catch" {
    const allocator = std.testing.allocator;
    const source = "try { foo(); } catch (e) { }";

    var parser = try Parser.init(allocator, source);
    defer parser.deinit();

    _ = parser.parse() catch {
        try std.testing.expect(parser.hasErrors());
        const errors = parser.getErrors();
        try std.testing.expect(errors.len > 0);
        const err = errors[0];
        try std.testing.expectEqual(error_mod.ErrorKind.unsupported_feature, err.kind);
        try std.testing.expect(std.mem.indexOf(u8, err.message, "try") != null or std.mem.indexOf(u8, err.message, "catch") != null);
        try std.testing.expect(std.mem.indexOf(u8, err.message, "Result") != null);
        return;
    };

    try std.testing.expect(false);
}

test "unsupported: var declaration" {
    const allocator = std.testing.allocator;
    const source = "var x = 42;";

    var parser = try Parser.init(allocator, source);
    defer parser.deinit();

    _ = parser.parse() catch {
        try std.testing.expect(parser.hasErrors());
        const errors = parser.getErrors();
        try std.testing.expect(errors.len > 0);
        const err = errors[0];
        try std.testing.expectEqual(error_mod.ErrorKind.unsupported_feature, err.kind);
        try std.testing.expect(std.mem.indexOf(u8, err.message, "var") != null);
        try std.testing.expect(std.mem.indexOf(u8, err.message, "let") != null or std.mem.indexOf(u8, err.message, "const") != null);
        return;
    };

    try std.testing.expect(false);
}

test "unsupported: loose equality ==" {
    const allocator = std.testing.allocator;
    const source = "if (x == y) { }";

    var parser = try Parser.init(allocator, source);
    defer parser.deinit();

    _ = parser.parse() catch {
        try std.testing.expect(parser.hasErrors());
        const errors = parser.getErrors();
        try std.testing.expect(errors.len > 0);
        const err = errors[0];
        try std.testing.expectEqual(error_mod.ErrorKind.unsupported_feature, err.kind);
        try std.testing.expect(std.mem.indexOf(u8, err.message, "==") != null);
        try std.testing.expect(std.mem.indexOf(u8, err.message, "===") != null);
        return;
    };

    try std.testing.expect(false);
}

test "comptime expression profile preserves null and loose equality in IR" {
    const allocator = std.testing.allocator;

    var parser = try Parser.initExpression(allocator, "null == undefined", .comptime_expression);
    defer parser.deinit();

    const root = try parser.parseExpressionOnly();
    const view = ir.IrView.fromIRStore(&parser.nodes, &parser.constants);
    const binary = view.getBinary(root).?;

    try std.testing.expectEqual(BinaryOp.loose_eq, binary.op);
    try std.testing.expectEqual(NodeTag.lit_null, view.getTag(binary.left).?);
    try std.testing.expectEqual(NodeTag.lit_undefined, view.getTag(binary.right).?);
}

test "comptime expression profile parses one aggregate root prefix" {
    const allocator = std.testing.allocator;
    const source = "{ loose: [1, 2] } trailing";

    var parser = try Parser.initExpression(allocator, source, .comptime_expression);
    defer parser.deinit();

    const root = try parser.parseExpressionPrefix();
    try std.testing.expectEqual(NodeTag.object_literal, parser.nodes.getTag(root));
    try std.testing.expectEqual(TokenType.identifier, parser.current.type);
    try std.testing.expectEqualStrings("trailing", parser.current.text(source));
}

test "comptime expression profile rejects pipe before normal desugaring" {
    const allocator = std.testing.allocator;

    var expression_parser = try Parser.initExpression(allocator, "\"value\" |> hash", .comptime_expression);
    defer expression_parser.deinit();
    try std.testing.expectError(error.UnexpectedToken, expression_parser.parseExpressionOnly());
    try std.testing.expectEqual(error_mod.ErrorKind.unexpected_token, expression_parser.getErrors()[0].kind);

    var program_parser = try Parser.init(allocator, "const result = \"value\" |> hash;");
    defer program_parser.deinit();
    _ = try program_parser.parse();
    try std.testing.expect(!program_parser.hasErrors());
}

test "comptime numeric separators remain isolated from normal parsing" {
    const allocator = std.testing.allocator;

    var expression_parser = try Parser.initExpression(allocator, "1_000", .comptime_expression);
    defer expression_parser.deinit();
    const root = try expression_parser.parseExpressionOnly();
    const view = ir.IrView.fromIRStore(&expression_parser.nodes, &expression_parser.constants);
    try std.testing.expectEqual(@as(f64, 1000), view.getFloat(view.getFloatIdx(root).?).?);

    // Outside comptime the separator is a diagnostic, not a silent truncation:
    // the literal used to lex as `1` followed by the identifier statement
    // `_000`, so a handler served 1 where the author wrote 1000.
    var program_parser = try Parser.init(allocator, "const value = 1_000;");
    defer program_parser.deinit();
    try std.testing.expectError(error.InvalidNumber, program_parser.parse());
    const errors = program_parser.getErrors();
    try std.testing.expect(errors.len >= 1);
    try std.testing.expectEqual(error_mod.ErrorKind.invalid_number, errors[0].kind);
}

test "a non-ASCII identifier reports once, not once per cascade" {
    // `const café = 1;` produced three diagnostics - a const with no
    // initializer, a missing expression, and an unexpected token - none of
    // which named the actual fault. The bytes of one character are one fault
    // and get one diagnostic.
    const allocator = std.testing.allocator;
    var parser = try Parser.init(allocator, "const caf\xc3\xa9 = 1;");
    defer parser.deinit();
    _ = parser.parse() catch 0;
    const errors = parser.getErrors();
    try std.testing.expectEqual(@as(usize, 1), errors.len);
    try std.testing.expectEqual(error_mod.ErrorKind.non_ascii_identifier, errors[0].kind);
}

test "an ASCII identifier with digits and underscores still parses" {
    // The floor: refusing bytes above ASCII must not refuse the identifier
    // characters the profile admits.
    const allocator = std.testing.allocator;
    var parser = try Parser.init(allocator, "const _priv$1 = 1; const camelCase2 = _priv$1;");
    defer parser.deinit();
    _ = try parser.parse();
    try std.testing.expect(!parser.hasErrors());
}

test "a radix prefix with no digits is refused" {
    // `0x` parsed as an integer, failed, fell through to `parseFloat`, failed,
    // and became 0.0. The handler ran with a number the author never wrote.
    const allocator = std.testing.allocator;
    for ([_][]const u8{ "const n = 0x;", "const n = 0b;", "const n = 0o;" }) |source| {
        var parser = try Parser.init(allocator, source);
        defer parser.deinit();
        try std.testing.expectError(error.InvalidNumber, parser.parse());
        const errors = parser.getErrors();
        try std.testing.expect(errors.len >= 1);
        try std.testing.expectEqual(error_mod.ErrorKind.invalid_number, errors[0].kind);
    }
}

test "an exponent with no digits is refused" {
    const allocator = std.testing.allocator;
    for ([_][]const u8{ "const n = 1e;", "const n = 1e+;", "const n = 1E-;" }) |source| {
        var parser = try Parser.init(allocator, source);
        defer parser.deinit();
        try std.testing.expectError(error.InvalidNumber, parser.parse());
        const errors = parser.getErrors();
        try std.testing.expect(errors.len >= 1);
        try std.testing.expectEqual(error_mod.ErrorKind.invalid_number, errors[0].kind);
    }
}

test "a legacy octal literal is refused, and the message names it" {
    // `0755` is 493 to one reader and 755 to another. The code is reused; the
    // message is what tells the two apart, so the message is what is asserted.
    const allocator = std.testing.allocator;
    var parser = try Parser.init(allocator, "const mode = 0755;");
    defer parser.deinit();
    try std.testing.expectError(error.InvalidNumber, parser.parse());
    const errors = parser.getErrors();
    try std.testing.expect(errors.len >= 1);
    try std.testing.expectEqual(error_mod.ErrorKind.invalid_number, errors[0].kind);
    try std.testing.expect(std.mem.indexOf(u8, errors[0].message, "octal") != null);
}

test "the legal numeric forms still parse" {
    // The floor under all three refusals above.
    const allocator = std.testing.allocator;
    const legal = "const a = 0; const b = 0x1F; const c = 0b1010; const d = 0o17; " ++
        "const e = 1e3; const f = 1.5e-3; const g = 0.5; const h = 42;";
    var parser = try Parser.init(allocator, legal);
    defer parser.deinit();
    _ = try parser.parse();
    try std.testing.expect(!parser.hasErrors());
}

test "an unknown escape is refused rather than copied" {
    // D3 section 1: the escape set is closed. `\q` used to emit `q`, so a typo
    // in an escape produced a string the author did not write and no
    // diagnostic ever said so.
    const allocator = std.testing.allocator;
    var parser = try Parser.init(allocator, "const s = \"a\\qb\";");
    defer parser.deinit();
    try std.testing.expectError(error.InvalidEscapeSequence, parser.parse());
    const errors = parser.getErrors();
    try std.testing.expect(errors.len >= 1);
    try std.testing.expectEqual(error_mod.ErrorKind.invalid_escape_sequence, errors[0].kind);
    try std.testing.expect(errors[0].location.line >= 1);
}

test "a backslash before a real newline is refused" {
    // The other half of the closed escape set. A line continuation used to
    // yield a literal newline, so a string silently spanned lines.
    const allocator = std.testing.allocator;
    var parser = try Parser.init(allocator, "const s = \"a\\\nb\";");
    defer parser.deinit();
    try std.testing.expectError(error.StringLineContinuation, parser.parse());
    const errors = parser.getErrors();
    try std.testing.expect(errors.len >= 1);
    try std.testing.expectEqual(error_mod.ErrorKind.string_line_continuation, errors[0].kind);
}

test "the legal escapes still parse" {
    // The floor under both refusals: closing the set must not close it on the
    // escapes the profile admits.
    const allocator = std.testing.allocator;
    var parser = try Parser.init(
        allocator,
        "const s = \"n\\nr\\rt\\tb\\bf\\fv\\v0\\0q\\\"d\\\\x\\x41u\\u0041c\\u{1F600}\";",
    );
    defer parser.deinit();
    _ = try parser.parse();
    try std.testing.expect(!parser.hasErrors());
}

test "comptime string folding decodes unicode escapes like the normal parser" {
    const allocator = std.testing.allocator;

    var expression_parser = try Parser.initExpression(allocator, "\"caf\\u00e9\"", .comptime_expression);
    defer expression_parser.deinit();
    const root = try expression_parser.parseExpressionOnly();
    const view = ir.IrView.fromIRStore(&expression_parser.nodes, &expression_parser.constants);
    try std.testing.expectEqualStrings("café", view.getString(view.getStringIdx(root).?).?);
}

test "comptime unary before exponent preserves legacy profile only" {
    const allocator = std.testing.allocator;

    var expression_parser = try Parser.initExpression(allocator, "-3 ** 2", .comptime_expression);
    defer expression_parser.deinit();
    const root = try expression_parser.parseExpressionOnly();
    const view = ir.IrView.fromIRStore(&expression_parser.nodes, &expression_parser.constants);
    const binary = view.getBinary(root).?;
    try std.testing.expectEqual(BinaryOp.pow, binary.op);
    try std.testing.expectEqual(NodeTag.unary_op, view.getTag(binary.left).?);

    var program_parser = try Parser.init(allocator, "const value = -3 ** 2;");
    defer program_parser.deinit();
    try std.testing.expectError(error.ParseError, program_parser.parse());
    try std.testing.expectEqual(error_mod.ErrorKind.unsupported_feature, program_parser.getErrors()[0].kind);
}

test "unsupported: prefix increment ++" {
    const allocator = std.testing.allocator;
    const source = "++x;";

    var parser = try Parser.init(allocator, source);
    defer parser.deinit();

    _ = parser.parse() catch {
        try std.testing.expect(parser.hasErrors());
        const errors = parser.getErrors();
        try std.testing.expect(errors.len > 0);
        const err = errors[0];
        try std.testing.expectEqual(error_mod.ErrorKind.unsupported_feature, err.kind);
        try std.testing.expect(std.mem.indexOf(u8, err.message, "++") != null);
        try std.testing.expect(std.mem.indexOf(u8, err.message, "x + 1") != null);
        return;
    };

    try std.testing.expect(false);
}

test "compound assignment +=" {
    var parser = try Parser.init(std.testing.allocator, "let x = 1; x += 5;");
    defer parser.deinit();

    const result = parser.parse() catch {
        try std.testing.expect(false);
        return;
    };
    try std.testing.expect(result != null_node);
    try std.testing.expect(!parser.hasErrors());
}

test "compound assignments: all arithmetic operators" {
    var parser = try Parser.init(std.testing.allocator, "let x = 10; x += 1; x -= 2; x *= 3; x /= 4; x %= 5; x **= 2;");
    defer parser.deinit();

    const result = parser.parse() catch {
        try std.testing.expect(false);
        return;
    };
    try std.testing.expect(result != null_node);
    try std.testing.expect(!parser.hasErrors());
}

test "compound assignments: bitwise operators" {
    var parser = try Parser.init(std.testing.allocator, "let x = 255; x &= 15; x |= 240; x ^= 255; x <<= 2; x >>= 1; x >>>= 1;");
    defer parser.deinit();

    const result = parser.parse() catch {
        try std.testing.expect(false);
        return;
    };
    try std.testing.expect(result != null_node);
    try std.testing.expect(!parser.hasErrors());
}

test "unsupported: logical compound assignment &&=" {
    var parser = try Parser.init(std.testing.allocator, "x &&= 5;");
    defer parser.deinit();

    _ = parser.parse() catch {
        try std.testing.expect(parser.hasErrors());
        return;
    };
    try std.testing.expect(false);
}

test "array spread parses" {
    var parser = try Parser.init(std.testing.allocator, "const xs = [0, ...rest, 3];");
    defer parser.deinit();

    const result = parser.parse() catch {
        try std.testing.expect(false);
        return;
    };
    try std.testing.expect(result != null_node);
    try std.testing.expect(!parser.hasErrors());
}

test "array literal elisions are rejected" {
    var parser = try Parser.init(std.testing.allocator, "const xs = [1,,2];");
    defer parser.deinit();

    _ = parser.parse() catch {
        try std.testing.expect(parser.hasErrors());
        const errors = parser.getErrors();
        try std.testing.expect(errors.len > 0);
        try std.testing.expectEqual(error_mod.ErrorKind.unsupported_feature, errors[0].kind);
        return;
    };
    try std.testing.expect(false);
}

test "call spread parses before canonical-profile rejection" {
    var parser = try Parser.init(std.testing.allocator, "const r = f(...args);");
    defer parser.deinit();

    const result = parser.parse() catch {
        try std.testing.expect(false);
        return;
    };
    try std.testing.expect(result != null_node);
    try std.testing.expect(!parser.hasErrors());
}

test "pipe operator: simple" {
    var parser = try Parser.init(std.testing.allocator, "const r = 5 |> double;");
    defer parser.deinit();

    const result = parser.parse() catch {
        try std.testing.expect(false);
        return;
    };
    try std.testing.expect(result != null_node);
    try std.testing.expect(!parser.hasErrors());
}

test "pipe operator: chained" {
    var parser = try Parser.init(std.testing.allocator, "const r = x |> f |> g |> h;");
    defer parser.deinit();

    const result = parser.parse() catch {
        try std.testing.expect(false);
        return;
    };
    try std.testing.expect(result != null_node);
    try std.testing.expect(!parser.hasErrors());
}

// ============================================================================
// Guard Composition Tests
// ============================================================================

test "guard composition: pre-guards with handler" {
    const source =
        \\import { guard } from "zttp:compose";
        \\const g1 = (req) => { if (req.method === "OPTIONS") return Response.text(""); };
        \\const g2 = (req) => { if (!req.headers.get("auth")) return Response.json({error: "no"}); };
        \\function handler(req) { return Response.json({ok: true}); }
        \\const h = guard(g1) |> guard(g2) |> handler;
    ;

    var parser = try Parser.init(std.testing.allocator, source);
    defer parser.deinit();

    const result = parser.parse() catch {
        try std.testing.expect(false);
        return;
    };
    try std.testing.expect(result != null_node);
    try std.testing.expect(!parser.hasErrors());
    // Guard binding should have been detected
    try std.testing.expect(parser.guard_binding_slot != null);
}

test "guard composition: pre-guards and post-guards" {
    const source =
        \\import { guard } from "zttp:compose";
        \\const pre = (req) => { };
        \\function handler(req) { return Response.json({ok: true}); }
        \\const post = (res) => { };
        \\const h = guard(pre) |> handler |> guard(post);
    ;

    var parser = try Parser.init(std.testing.allocator, source);
    defer parser.deinit();

    const result = parser.parse() catch {
        try std.testing.expect(false);
        return;
    };
    try std.testing.expect(result != null_node);
    try std.testing.expect(!parser.hasErrors());
}

test "guard composition: single guard with handler" {
    const source =
        \\import { guard } from "zttp:compose";
        \\const authGuard = (req) => { };
        \\function handler(req) { return Response.json({ok: true}); }
        \\const h = guard(authGuard) |> handler;
    ;

    var parser = try Parser.init(std.testing.allocator, source);
    defer parser.deinit();

    const result = parser.parse() catch {
        try std.testing.expect(false);
        return;
    };
    try std.testing.expect(result != null_node);
    try std.testing.expect(!parser.hasErrors());
}

test "guard composition: error on no handler" {
    const source =
        \\import { guard } from "zttp:compose";
        \\const g1 = (req) => { };
        \\const g2 = (req) => { };
        \\const h = guard(g1) |> guard(g2);
    ;

    var parser = try Parser.init(std.testing.allocator, source);
    defer parser.deinit();

    _ = parser.parse() catch {
        try std.testing.expect(parser.hasErrors());
        return;
    };
    try std.testing.expect(false);
}

test "guard composition: error on multiple handlers" {
    const source =
        \\import { guard } from "zttp:compose";
        \\const g1 = (req) => { };
        \\function h1(req) { return Response.json({ok: true}); }
        \\function h2(req) { return Response.json({ok: true}); }
        \\const h = guard(g1) |> h1 |> h2;
    ;

    var parser = try Parser.init(std.testing.allocator, source);
    defer parser.deinit();

    _ = parser.parse() catch {
        try std.testing.expect(parser.hasErrors());
        return;
    };
    try std.testing.expect(false);
}

test "guard composition: normal pipe without guard import" {
    // Without zttp:compose import, pipe should work normally
    const source = "const r = x |> f |> g;";

    var parser = try Parser.init(std.testing.allocator, source);
    defer parser.deinit();

    const result = parser.parse() catch {
        try std.testing.expect(false);
        return;
    };
    try std.testing.expect(result != null_node);
    try std.testing.expect(!parser.hasErrors());
    // No guard binding should be detected
    try std.testing.expect(parser.guard_binding_slot == null);
}

test "unsupported: instanceof operator" {
    const allocator = std.testing.allocator;
    const source = "if (x instanceof Foo) { }";

    var parser = try Parser.init(allocator, source);
    defer parser.deinit();

    _ = parser.parse() catch {
        try std.testing.expect(parser.hasErrors());
        const errors = parser.getErrors();
        try std.testing.expect(errors.len > 0);
        const err = errors[0];
        try std.testing.expectEqual(error_mod.ErrorKind.unsupported_feature, err.kind);
        try std.testing.expect(std.mem.indexOf(u8, err.message, "instanceof") != null);
        try std.testing.expect(std.mem.indexOf(u8, err.message, "discriminated") != null or std.mem.indexOf(u8, err.message, "union") != null);
        return;
    };

    try std.testing.expect(false);
}

test "unsupported: new operator" {
    const allocator = std.testing.allocator;
    const source = "const obj = new Foo();";

    var parser = try Parser.init(allocator, source);
    defer parser.deinit();

    _ = parser.parse() catch {
        try std.testing.expect(parser.hasErrors());
        const errors = parser.getErrors();
        try std.testing.expect(errors.len > 0);
        const err = errors[0];
        try std.testing.expectEqual(error_mod.ErrorKind.unsupported_feature, err.kind);
        try std.testing.expect(std.mem.indexOf(u8, err.message, "new") != null);
        try std.testing.expect(std.mem.indexOf(u8, err.message, "factory") != null);
        return;
    };

    try std.testing.expect(false);
}

test "unsupported: delete operator" {
    const allocator = std.testing.allocator;
    const source = "delete obj.prop;";

    var parser = try Parser.init(allocator, source);
    defer parser.deinit();

    _ = parser.parse() catch {
        try std.testing.expect(parser.hasErrors());
        const errors = parser.getErrors();
        try std.testing.expect(errors.len > 0);
        const err = errors[0];
        try std.testing.expectEqual(error_mod.ErrorKind.unsupported_feature, err.kind);
        try std.testing.expect(std.mem.indexOf(u8, err.message, "delete") != null);
        try std.testing.expect(std.mem.indexOf(u8, err.message, "spread") != null);
        return;
    };

    try std.testing.expect(false);
}

test "a statement error after a semicolon inside a block terminates" {
    // Regression. `parseBlock`'s recovery loop assumed `synchronize()` always
    // consumes a token. It returns immediately when `previous` is a semicolon,
    // so an error raised at the token directly after one left the loop
    // re-parsing that token forever - a hang, not a diagnostic.
    //
    // `delete`, `yield`, and `++x` all reach that path. `class` and `var` only
    // escaped because their error sites call `advance()` by hand, each with a
    // comment naming this same failure; the loop now guarantees progress
    // instead of depending on every error site to remember.
    const allocator = std.testing.allocator;
    const cases = [_][]const u8{
        "function f() { const o = {a: 1}; delete o.a; return 1; }",
        "function f() { const o = 1; yield o; }",
        "function f() { const o = 1; ++o; }",
        // The same shape one block deeper.
        "function f() { if (x) { const o = 1; delete o.a; } return 1; }",
    };

    for (cases) |source| {
        var parser = try Parser.init(allocator, source);
        defer parser.deinit();
        _ = parser.parse() catch {
            try std.testing.expect(parser.hasErrors());
            continue;
        };
        // Reaching here means the parser accepted an unsupported construct.
        try std.testing.expect(false);
    }
}

test "parse import declaration" {
    var parser = try Parser.init(std.testing.allocator,
        \\import { env } from "zttp:env";
        \\const name = env("USER");
    );
    defer parser.deinit();

    const result = parser.parse() catch {
        try std.testing.expect(false);
        return;
    };

    try std.testing.expect(result != null_node);
    try std.testing.expect(!parser.hasErrors());
}

test "parse import multiple specifiers" {
    var parser = try Parser.init(std.testing.allocator,
        \\import { sha256, hmacSha256, base64Encode } from "zttp:crypto";
        \\const h = sha256("test");
    );
    defer parser.deinit();

    const result = parser.parse() catch {
        try std.testing.expect(false);
        return;
    };

    try std.testing.expect(result != null_node);
    try std.testing.expect(!parser.hasErrors());
}

test "parse import with as alias" {
    var parser = try Parser.init(std.testing.allocator,
        \\import { env as getEnv } from "zttp:env";
        \\const name = getEnv("USER");
    );
    defer parser.deinit();

    const result = parser.parse() catch {
        try std.testing.expect(false);
        return;
    };

    try std.testing.expect(result != null_node);
    try std.testing.expect(!parser.hasErrors());
}

test "parse export function" {
    var parser = try Parser.init(std.testing.allocator,
        \\export function handler(req) {
        \\  return req;
        \\}
    );
    defer parser.deinit();

    const result = parser.parse() catch {
        try std.testing.expect(false);
        return;
    };

    try std.testing.expect(result != null_node);
    try std.testing.expect(!parser.hasErrors());
}

test "parse export const" {
    var parser = try Parser.init(std.testing.allocator,
        \\export const version = "1.0";
    );
    defer parser.deinit();

    const result = parser.parse() catch {
        try std.testing.expect(false);
        return;
    };

    try std.testing.expect(result != null_node);
    try std.testing.expect(!parser.hasErrors());
}

test "unsupported: import default" {
    const allocator = std.testing.allocator;
    const source =
        \\import env from "zttp:env";
    ;

    var parser = try Parser.init(allocator, source);
    defer parser.deinit();

    _ = parser.parse() catch {
        try std.testing.expect(parser.hasErrors());
        const errors = parser.getErrors();
        try std.testing.expect(errors.len > 0);
        const err = errors[0];
        try std.testing.expect(std.mem.indexOf(u8, err.message, "default import") != null);
        try std.testing.expect(std.mem.indexOf(u8, err.message, "named import") != null);
        return;
    };

    try std.testing.expect(false);
}

test "unsupported: import namespace star" {
    const allocator = std.testing.allocator;
    const source =
        \\import * as mod from "zttp:env";
    ;

    var parser = try Parser.init(allocator, source);
    defer parser.deinit();

    _ = parser.parse() catch {
        try std.testing.expect(parser.hasErrors());
        const errors = parser.getErrors();
        try std.testing.expect(errors.len > 0);
        const err = errors[0];
        try std.testing.expect(std.mem.indexOf(u8, err.message, "namespace import") != null);
        try std.testing.expect(std.mem.indexOf(u8, err.message, "named import") != null);
        return;
    };

    try std.testing.expect(false);
}

test "export default named function" {
    const allocator = std.testing.allocator;
    const source =
        \\export default function handler() {}
    ;

    var parser = try Parser.init(allocator, source);
    defer parser.deinit();

    const root = try parser.parse();
    const program = parser.nodes.get(root).?;
    const export_idx = parser.nodes.getListIndex(program.data.block.stmts_start, 0);
    try std.testing.expectEqual(NodeTag.export_decl, parser.nodes.getTag(export_idx));
    const ir_view = ir.IrView.fromIRStore(&parser.nodes, &parser.constants);
    const export_decl = ir_view.getExportDecl(export_idx).?;
    try std.testing.expectEqual(Node.ExportDecl.ExportKind.default, export_decl.kind);
}

test "unsupported: export re-export braces" {
    const allocator = std.testing.allocator;
    const source =
        \\export { foo } from "bar";
    ;

    var parser = try Parser.init(allocator, source);
    defer parser.deinit();

    _ = parser.parse() catch {
        try std.testing.expect(parser.hasErrors());
        const errors = parser.getErrors();
        try std.testing.expect(errors.len > 0);
        const err = errors[0];
        try std.testing.expect(std.mem.indexOf(u8, err.message, "export { }") != null);
        try std.testing.expect(std.mem.indexOf(u8, err.message, "named export") != null);
        return;
    };

    try std.testing.expect(false);
}

test "unsupported: export star" {
    const allocator = std.testing.allocator;
    const source =
        \\export * from "bar";
    ;

    var parser = try Parser.init(allocator, source);
    defer parser.deinit();

    _ = parser.parse() catch {
        try std.testing.expect(parser.hasErrors());
        const errors = parser.getErrors();
        try std.testing.expect(errors.len > 0);
        const err = errors[0];
        try std.testing.expect(std.mem.indexOf(u8, err.message, "export *") != null);
        try std.testing.expect(std.mem.indexOf(u8, err.message, "named export") != null);
        return;
    };

    try std.testing.expect(false);
}

// ============ TypeScript Feature Detection (moved from stripper) ============

test "unsupported: enum statement" {
    const allocator = std.testing.allocator;
    const source = "enum Color { Red, Blue }";

    var parser = try Parser.init(allocator, source);
    defer parser.deinit();

    _ = parser.parse() catch {
        try std.testing.expect(parser.hasErrors());
        const errors = parser.getErrors();
        try std.testing.expect(errors.len > 0);
        const err = errors[0];
        try std.testing.expectEqual(error_mod.ErrorKind.unsupported_feature, err.kind);
        try std.testing.expect(std.mem.indexOf(u8, err.message, "enum") != null);
        try std.testing.expect(std.mem.indexOf(u8, err.message, "object literals") != null);
        return;
    };

    try std.testing.expect(false);
}

test "unsupported: const enum" {
    const allocator = std.testing.allocator;
    const source = "const enum Color { Red }";

    var parser = try Parser.init(allocator, source);
    defer parser.deinit();

    _ = parser.parse() catch {
        try std.testing.expect(parser.hasErrors());
        const errors = parser.getErrors();
        try std.testing.expect(errors.len > 0);
        const err = errors[0];
        try std.testing.expectEqual(error_mod.ErrorKind.unsupported_feature, err.kind);
        try std.testing.expect(std.mem.indexOf(u8, err.message, "const enum") != null);
        return;
    };

    try std.testing.expect(false);
}

test "unsupported: export enum" {
    const allocator = std.testing.allocator;
    const source = "export enum Color { Red }";

    var parser = try Parser.init(allocator, source);
    defer parser.deinit();

    _ = parser.parse() catch {
        try std.testing.expect(parser.hasErrors());
        const errors = parser.getErrors();
        try std.testing.expect(errors.len > 0);
        const err = errors[0];
        try std.testing.expectEqual(error_mod.ErrorKind.unsupported_feature, err.kind);
        try std.testing.expect(std.mem.indexOf(u8, err.message, "enum") != null);
        return;
    };

    try std.testing.expect(false);
}

test "unsupported: namespace statement" {
    const allocator = std.testing.allocator;
    const source = "namespace N { }";

    var parser = try Parser.init(allocator, source);
    defer parser.deinit();

    _ = parser.parse() catch {
        try std.testing.expect(parser.hasErrors());
        const errors = parser.getErrors();
        try std.testing.expect(errors.len > 0);
        const err = errors[0];
        try std.testing.expectEqual(error_mod.ErrorKind.unsupported_feature, err.kind);
        try std.testing.expect(std.mem.indexOf(u8, err.message, "namespace") != null);
        try std.testing.expect(std.mem.indexOf(u8, err.message, "ES6 modules") != null);
        return;
    };

    try std.testing.expect(false);
}

test "unsupported: export namespace" {
    const allocator = std.testing.allocator;
    const source = "export namespace N { }";

    var parser = try Parser.init(allocator, source);
    defer parser.deinit();

    _ = parser.parse() catch {
        try std.testing.expect(parser.hasErrors());
        const errors = parser.getErrors();
        try std.testing.expect(errors.len > 0);
        const err = errors[0];
        try std.testing.expectEqual(error_mod.ErrorKind.unsupported_feature, err.kind);
        try std.testing.expect(std.mem.indexOf(u8, err.message, "namespace") != null);
        return;
    };

    try std.testing.expect(false);
}

test "unsupported: implements keyword" {
    const allocator = std.testing.allocator;
    const source = "implements Foo { }";

    var parser = try Parser.init(allocator, source);
    defer parser.deinit();

    _ = parser.parse() catch {
        try std.testing.expect(parser.hasErrors());
        const errors = parser.getErrors();
        try std.testing.expect(errors.len > 0);
        const err = errors[0];
        try std.testing.expectEqual(error_mod.ErrorKind.unsupported_feature, err.kind);
        try std.testing.expect(std.mem.indexOf(u8, err.message, "implements") != null);
        return;
    };

    try std.testing.expect(false);
}

test "unsupported: rest parameter" {
    const allocator = std.testing.allocator;
    const source = "const f = (...xs) => xs;";

    var parser = try Parser.init(allocator, source);
    defer parser.deinit();
    _ = parser.parse() catch {};

    try std.testing.expect(parser.hasErrors());
    var found = false;
    for (parser.getErrors()) |err| {
        if (err.kind == error_mod.ErrorKind.unsupported_feature and
            std.mem.indexOf(u8, err.message, "rest parameters") != null) found = true;
    }
    try std.testing.expect(found);
}

test "unsupported: public modifier" {
    const allocator = std.testing.allocator;
    const source = "public foo() { }";

    var parser = try Parser.init(allocator, source);
    defer parser.deinit();

    _ = parser.parse() catch {
        try std.testing.expect(parser.hasErrors());
        const errors = parser.getErrors();
        try std.testing.expect(errors.len > 0);
        const err = errors[0];
        try std.testing.expectEqual(error_mod.ErrorKind.unsupported_feature, err.kind);
        try std.testing.expect(std.mem.indexOf(u8, err.message, "access modifiers") != null);
        return;
    };

    try std.testing.expect(false);
}

test "unsupported: private modifier" {
    const allocator = std.testing.allocator;
    const source = "private x = 1;";

    var parser = try Parser.init(allocator, source);
    defer parser.deinit();

    _ = parser.parse() catch {
        try std.testing.expect(parser.hasErrors());
        const errors = parser.getErrors();
        try std.testing.expect(errors.len > 0);
        const err = errors[0];
        try std.testing.expectEqual(error_mod.ErrorKind.unsupported_feature, err.kind);
        try std.testing.expect(std.mem.indexOf(u8, err.message, "access modifiers") != null);
        return;
    };

    try std.testing.expect(false);
}

test "unsupported: protected modifier" {
    const allocator = std.testing.allocator;
    const source = "protected foo() { }";

    var parser = try Parser.init(allocator, source);
    defer parser.deinit();

    _ = parser.parse() catch {
        try std.testing.expect(parser.hasErrors());
        const errors = parser.getErrors();
        try std.testing.expect(errors.len > 0);
        const err = errors[0];
        try std.testing.expectEqual(error_mod.ErrorKind.unsupported_feature, err.kind);
        try std.testing.expect(std.mem.indexOf(u8, err.message, "access modifiers") != null);
        return;
    };

    try std.testing.expect(false);
}

test "unsupported: decorator before class" {
    const allocator = std.testing.allocator;
    const source = "@sealed class X {}";

    var parser = try Parser.init(allocator, source);
    defer parser.deinit();

    _ = parser.parse() catch {
        try std.testing.expect(parser.hasErrors());
        const errors = parser.getErrors();
        try std.testing.expect(errors.len > 0);
        const err = errors[0];
        try std.testing.expectEqual(error_mod.ErrorKind.unsupported_feature, err.kind);
        try std.testing.expect(std.mem.indexOf(u8, err.message, "@decorator") != null);
        return;
    };

    try std.testing.expect(false);
}

test "unsupported: decorator before function" {
    const allocator = std.testing.allocator;
    const source = "@log function f() {}";

    var parser = try Parser.init(allocator, source);
    defer parser.deinit();

    _ = parser.parse() catch {
        try std.testing.expect(parser.hasErrors());
        const errors = parser.getErrors();
        try std.testing.expect(errors.len > 0);
        const err = errors[0];
        try std.testing.expectEqual(error_mod.ErrorKind.unsupported_feature, err.kind);
        try std.testing.expect(std.mem.indexOf(u8, err.message, "@decorator") != null);
        return;
    };

    try std.testing.expect(false);
}

test "keyword as property name: obj.enum" {
    const allocator = std.testing.allocator;
    const source = "const x = obj.enum;";

    var parser = try Parser.init(allocator, source);
    defer parser.deinit();

    const result = parser.parse();
    // Should parse successfully - enum is valid as property name
    try std.testing.expect(!parser.hasErrors());
    _ = result catch unreachable;
}

test "keyword in destructuring: {public: x}" {
    const allocator = std.testing.allocator;
    const source = "const {public: x} = obj;";

    var parser = try Parser.init(allocator, source);
    defer parser.deinit();

    const result = parser.parse();
    // Should parse successfully - public is valid as property key in destructuring
    try std.testing.expect(!parser.hasErrors());
    _ = result catch unreachable;
}

test "parse match expression with literals" {
    var parser = try Parser.init(std.testing.allocator,
        \\const x = match (y) {
        \\  when "a": 1,
        \\  when "b": 2,
        \\  default: 0
        \\};
    );
    defer parser.deinit();

    const result = parser.parse() catch {
        try std.testing.expect(false);
        return;
    };

    try std.testing.expect(result != null_node);
    try std.testing.expect(!parser.hasErrors());
}

test "parse match expression with object pattern" {
    var parser = try Parser.init(std.testing.allocator,
        \\const r = match (req) {
        \\  when { method: "GET", path: "/health" }: 200,
        \\  default: 404
        \\};
    );
    defer parser.deinit();

    const result = parser.parse() catch {
        try std.testing.expect(false);
        return;
    };

    try std.testing.expect(result != null_node);
    try std.testing.expect(!parser.hasErrors());
}

test "parse match expression with wildcard" {
    var parser = try Parser.init(std.testing.allocator,
        \\const x = match (v) {
        \\  when 1: "one",
        \\  when _: "other"
        \\};
    );
    defer parser.deinit();

    const result = parser.parse() catch {
        try std.testing.expect(false);
        return;
    };

    try std.testing.expect(result != null_node);
    try std.testing.expect(!parser.hasErrors());
}

test "parse match expression with nested object and array patterns" {
    var parser = try Parser.init(std.testing.allocator,
        \\const x = match (value) {
        \\  when { user: { role: "admin" }, tags: ["a", _, "c"] }: 1,
        \\  default: 0
        \\};
    );
    defer parser.deinit();

    const result = parser.parse() catch {
        try std.testing.expect(false);
        return;
    };

    try std.testing.expect(result != null_node);
    try std.testing.expect(!parser.hasErrors());
}

test "null literal parses as explicit data" {
    const allocator = std.testing.allocator;
    const source = "const x = null;";

    var parser = try Parser.init(allocator, source);
    defer parser.deinit();

    const result = parser.parse() catch {
        try std.testing.expect(false);
        return;
    };

    try std.testing.expect(result != null_node);
    try std.testing.expect(!parser.hasErrors());
}

test "null is a match pattern" {
    const allocator = std.testing.allocator;
    const source =
        \\const x = match (val) {
        \\  when null: "missing",
        \\  default: "present"
        \\};
    ;

    var parser = try Parser.init(allocator, source);
    defer parser.deinit();

    const result = parser.parse() catch {
        try std.testing.expect(false);
        return;
    };

    try std.testing.expect(result != null_node);
    try std.testing.expect(!parser.hasErrors());
}

test "the six admitted type-test patterns parse" {
    // Six is the whole of spec 5.5's list. A seventh identifier is not a type
    // test - it is a binding - so this count is the closed set, not a sample.
    var parser = try Parser.init(std.testing.allocator,
        \\const x = match (v) {
        \\  when boolean: 1,
        \\  when number: 2,
        \\  when string: 3,
        \\  when array: 4,
        \\  when Dict: 5,
        \\  when Bytes: 6
        \\};
    );
    defer parser.deinit();

    const result = parser.parse() catch {
        try std.testing.expect(false);
        return;
    };
    try std.testing.expect(result != null_node);
    try std.testing.expect(!parser.hasErrors());

    const view = ir.IrView.fromIRStore(&parser.nodes, &parser.constants);
    var tests_found: usize = 0;
    var node: NodeIndex = 0;
    while (node < view.nodeCount()) : (node += 1) {
        if (view.getTag(node) == .match_type_test) tests_found += 1;
    }
    try std.testing.expectEqual(@as(usize, 6), tests_found);
}

test "the Bytes type test lowers to an isBytes call" {
    // The test that pinned the refusal now pins the lowering. `when Bytes:`
    // reads the scrutinee a second time through the intrinsic guard, which is
    // the same shape `when Dict:` uses and the reason `isBytes` has to be a
    // real global rather than a checker-only name.
    const source = "const x = match (v) { when Bytes: 1, default: 2 };";

    var parser = try Parser.init(std.testing.allocator, source);
    defer parser.deinit();

    const result = parser.parse() catch {
        try std.testing.expect(false);
        return;
    };
    try std.testing.expect(result != null_node);
    try std.testing.expect(!parser.hasErrors());

    const view = ir.IrView.fromIRStore(&parser.nodes, &parser.constants);
    var found: bool = false;
    var node: NodeIndex = 0;
    while (node < view.nodeCount()) : (node += 1) {
        if (view.getTag(node) != .match_type_test) continue;
        const test_node = view.getMatchTypeTest(node) orelse continue;
        try std.testing.expectEqual(ir.Node.TypeTestKind.bytes, test_node.kind);
        try std.testing.expect(test_node.predicate != null_node);
        try std.testing.expectEqual(ir.NodeTag.call, view.getTag(test_node.predicate));
        found = true;
    }
    try std.testing.expect(found);
}

test "the Dict type test parses now that Dict exists" {
    var parser = try Parser.init(std.testing.allocator,
        \\const x = match (v) {
        \\  when Dict: 1,
        \\  default: 2
        \\};
    );
    defer parser.deinit();

    const result = parser.parse() catch {
        try std.testing.expect(false);
        return;
    };
    try std.testing.expect(result != null_node);
    try std.testing.expect(!parser.hasErrors());
}

test "a type test over a scrutinee that is not a name is refused" {
    // The test reads the scrutinee a second time, so a call in that position
    // would be evaluated twice. Spec 5.5 already requires a name or a member
    // path there; this is the diagnostic that says so.
    var parser = try Parser.init(std.testing.allocator,
        \\const x = match (compute()) {
        \\  when string: 1,
        \\  default: 2
        \\};
    );
    defer parser.deinit();

    _ = parser.parse() catch {
        try std.testing.expect(parser.hasErrors());
        return;
    };
    try std.testing.expect(false);
}

test "a match binding is scoped to its arm" {
    // The binding is declared in a scope opened per arm, so the name is a
    // local inside its own arm and is not one anywhere else. Without the
    // per-arm scope the second arm would resolve `text` to the first arm's
    // slot, which is a value it never bound.
    const allocator = std.testing.allocator;
    var parser = try Parser.init(allocator,
        \\const x = match (command) {
        \\  when { kind: "echo", text }: text,
        \\  when { kind: "ping" }: text
        \\};
    );
    defer parser.deinit();

    const result = parser.parse() catch {
        try std.testing.expect(false);
        return;
    };
    try std.testing.expect(result != null_node);
    try std.testing.expect(!parser.hasErrors());

    const view = ir.IrView.fromIRStore(&parser.nodes, &parser.constants);
    var locals: usize = 0;
    var non_locals: usize = 0;
    var node: NodeIndex = 0;
    while (node < view.nodeCount()) : (node += 1) {
        if (view.getTag(node) != .identifier) continue;
        const binding = view.getBinding(node) orelse continue;
        switch (binding.kind) {
            .local, .argument, .upvalue => locals += 1,
            .global, .undeclared_global => non_locals += 1,
        }
    }
    // The declaration and the first arm's read are locals; the second arm's
    // read of the same name is not, because that binding is out of scope.
    try std.testing.expect(locals >= 2);
    try std.testing.expect(non_locals >= 1);
}

test "match as property name" {
    var parser = try Parser.init(std.testing.allocator, "const obj = { match: 42 };");
    defer parser.deinit();

    const result = parser.parse() catch {
        try std.testing.expect(false);
        return;
    };

    try std.testing.expect(result != null_node);
    try std.testing.expect(!parser.hasErrors());
}

test "parser construction reports allocation failure instead of panicking" {
    // A failing allocator makes ScopeAnalyzer construction fail, which the
    // parser must propagate. Before this was fallible, the same condition
    // reached `catch unreachable` and was undefined behavior.
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, Parser.init(failing.allocator(), "const x = 1;"));
}
