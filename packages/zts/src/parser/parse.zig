//! Core JavaScript syntax parser.
//!
//! Pratt parser producing IR nodes with integrated scope analysis.
//! Supports the ZigTS profile: ES5 plus selected ES6 syntax such as arrow
//! functions and template literals. Classes are rejected with diagnostics.

const std = @import("std");
const builtin = @import("builtin");
const retired_types_module = @import("zts-base").module_specifier.retired_types_module;
const tokenizer_mod = @import("tokenizer.zig");
const ir = @import("ir.zig");
const scope_mod = @import("scope.zig");
const error_mod = @import("error.zig");
const token_mod = @import("token.zig");
const type_syntax = @import("type_syntax.zig");
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

pub const AdmissionFailure = union(enum) {
    diagnostic: type_syntax.AdmissionDiagnostic,
    unterminated_comment: type_syntax.AdmissionCommentFailure,
};

pub const AdmissionParseOutcome = union(enum) {
    accepted: NodeIndex,
    recovered_admission_refused,
    parser_refused: struct {
        first_error: anyerror,
        projected_error_count: usize,
    },
    terminal_admission_refused: AdmissionFailure,
};

pub const PrintableRegion = union(enum) {
    raw_type: type_syntax.Span,
    recorded_generic: type_syntax.Span,
    declaration: struct { name: type_syntax.Span, body: type_syntax.Span },
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
    unary = 17, // ! ~ - + typeof
    postfix = 18, // ++ --
    call = 19, // () [] .
    primary = 20,
};

/// Safe-build assertion that a parser loop makes progress.
///
/// A loop that parses a list or a block must consume at least one token each
/// time round, or exit. One that does neither re-reads the same token forever:
/// the hang that `parse()` and `parseBlock` already guard by hand. `iteration`
/// goes first in the loop body and compares the parser's token counter with
/// the value the previous iteration started at, so `continue` paths are
/// covered and a loop that exits never trips it. Release builds compile it to
/// nothing.
const ProgressGuard = struct {
    seen: u32 = 0,
    started: bool = false,

    fn iteration(self: *ProgressGuard, parser: *const Parser) void {
        if (!@import("builtin").mode.runtimeSafety()) return;
        if (self.started) std.debug.assert(parser.tokens_advanced != self.seen);
        self.started = true;
        self.seen = parser.tokens_advanced;
    }
};

const ParserCursorCheckpoint = struct {
    tokenizer: Tokenizer,
    current: Token,
    previous: Token,
    tokens_advanced: u32,
    brace_depth: u32,
    primed: bool,
    last_erased_type_span: ?type_syntax.Span,
    pending_admission_trivia: ?type_syntax.AdmissionCommentFailure,
    admission_in_import: bool,
    admission_parameter_header: bool,
};

const AdmissionRecovery = struct {
    cursor: ParserCursorCheckpoint,
    presentation: type_syntax.AdmissionPresentation,
    erasures: std.ArrayListUnmanaged(tokenizer_mod.RecoveryErasure) = .empty,
    covered_until: u32,
    quoted_region: type_syntax.Span,
};

const ParsedFunctionBody = struct {
    function_node: NodeIndex,
    pending_signature: ?type_syntax.PendingFunctionSignature,
};

const HeaderKind = enum {
    named,
    arrow,
};

const AdmissionHeaderFailure = struct {
    first_error: anyerror,
    error_count: usize,
};

const SourceObservationContext = struct {
    in_expression: bool = false,
    expect_binding: bool = false,
    brace_stack: std.ArrayListUnmanaged(bool) = .empty,

    fn deinit(self: *SourceObservationContext, allocator: std.mem.Allocator) void {
        self.brace_stack.deinit(allocator);
    }

    fn consume(self: *SourceObservationContext, allocator: std.mem.Allocator, token: Token, source: []const u8) !void {
        const text = token.text(source);
        if (text.len > 0 and Parser.isAsciiIdentifierStart(text[0])) {
            self.expect_binding = false;
            switch (token.type) {
                .kw_const, .kw_let, .kw_var => {
                    self.in_expression = false;
                    self.expect_binding = true;
                },
                .kw_return, .kw_throw, .kw_new, .kw_typeof, .kw_delete, .kw_void, .kw_await, .kw_yield, .kw_when => self.in_expression = true,
                else => {},
            }
            return;
        }
        switch (token.type) {
            .number, .string_literal, .template_literal => return,
            .lbrace => {
                try self.brace_stack.append(allocator, self.in_expression);
                if (self.expect_binding) self.in_expression = true;
            },
            .rbrace => self.in_expression = self.brace_stack.pop() orelse false,
            .lparen, .lbracket, .question, .question_question, .question_dot, .question_question_assign => self.in_expression = true,
            .semicolon => self.in_expression = false,
            else => {},
        }
        self.expect_binding = false;
    }
};

pub const Parser = struct {
    allocator: std.mem.Allocator,
    tokenizer: Tokenizer,
    source: []const u8,

    // Output
    nodes: IRStore,
    scratch_nodes: std.ArrayListUnmanaged(NodeIndex) = .empty,
    constants: ConstantPool,
    scopes: ScopeAnalyzer,
    errors: ErrorList,
    type_store: type_syntax.Store,
    last_erased_type_span: ?type_syntax.Span,
    type_only_module_refusal: ?type_syntax.TypeOnlyModuleRefusal,
    type_only_module_diagnostics: std.ArrayListUnmanaged(type_syntax.TypeOnlyModuleDiagnostic),
    admission: ?type_syntax.AdmissionCollector,
    admission_observations: ?type_syntax.AdmissionObservationHistory,
    admission_failure: ?AdmissionFailure,
    pending_admission_trivia: ?type_syntax.AdmissionCommentFailure,
    admission_error_prefix: ?usize,
    admission_first_error: ?anyerror,
    first_statement_failure_nodes: ?usize = null,
    admission_in_import: bool,
    admission_presentation: type_syntax.AdmissionPresentation,
    admission_parameter_header: bool,
    admission_recovery: ?AdmissionRecovery = null,
    admission_recovery_observing: bool = false,
    source_only: bool = false,
    printable_regions: ?std.ArrayListUnmanaged(PrintableRegion) = null,

    // Current state
    current: Token,
    previous: Token,

    // Optional atom table for interning identifiers/properties
    atoms: ?*atom_table.AtomTable,

    /// When true, a statement missing its `;` is accepted instead of refused.
    /// Spec 5.5 mandates no ASI, so the default is false and every normal
    /// parse refuses.
    ///
    /// Two callers need ASI acceptance (`allow_asi`) and say so: the repair producer,
    /// which has to find the insertion points in a source that no longer
    /// parses, and M2, which compares the tree of the unrepaired original
    /// against the tree of the repaired file - the unique-parse argument
    /// spec 5.5 makes.
    allow_asi: bool = false,

    // Context flags
    in_loop: bool,
    in_function: bool,
    expression_profile: bool,
    /// The scrutinee of the `match` currently being parsed. A type-test pattern
    /// lowers to a narrowing test over it (spec 5.5), so the pattern parser
    /// needs the node the arms are selecting on.
    current_match_scrutinee: NodeIndex = null_node,

    // Recursive-descent depth, shared across statement and expression nesting.
    // Bounds stack growth so pathological input (minified/generated JS with
    // thousands of nested parens, unary ops, or blocks) yields a clean
    // diagnostic instead of a stack-overflow SIGSEGV that crashes the host.
    recursion_depth: u32 = 0,

    // The largest infix/postfix path built by a nested expression. Propagate
    // it to the enclosing Pratt loop when a grouped or aggregate expression
    // becomes the left operand of another chain.
    expression_chain_depth: u32 = 0,
    expression_frames: u32 = 0,

    /// Tokens consumed so far, counted in safe builds only. `ProgressGuard`
    /// compares it between loop iterations; a release build never reads it.
    tokens_advanced: u32 = 0,

    /// `{` consumed minus `}` consumed. `synchronize` reads it to tell how many
    /// braces the failed statement opened and left open. False until the first
    /// token is read, so `advance` does not account for a token that is not
    /// there yet.
    brace_depth: u32 = 0,
    primed: bool = false,

    /// Maximum recursive-descent nesting. Far above any hand-written handler
    /// (real code rarely nests past ~30) yet well under the worker-thread stack
    /// budget. Roughly V8's parser nesting tolerance.
    const max_recursion_depth: u32 = 512;

    /// Each active list owns a suffix of this parser's scratch stack. Nested
    /// lists truncate their suffix on exit; parents retain offsets, never
    /// slices that a recursive parse could invalidate by growing the buffer.
    const ScratchList = struct {
        parser: *Parser,
        start: usize,

        fn append(self: ScratchList, node: NodeIndex) !void {
            try self.parser.scratch_nodes.append(self.parser.allocator, node);
        }

        fn slice(self: ScratchList) []const NodeIndex {
            return self.parser.scratch_nodes.items[self.start..];
        }

        fn deinit(self: ScratchList) void {
            self.parser.scratch_nodes.shrinkRetainingCapacity(self.start);
        }
    };

    fn beginScratchList(self: *Parser) ScratchList {
        return .{ .parser = self, .start = self.scratch_nodes.items.len };
    }

    pub fn init(allocator: std.mem.Allocator, source: []const u8) !Parser {
        return initWithProfile(allocator, allocator, source, false, null, false);
    }

    /// Opt in before parsing only when source outlives this parser and any
    /// transferred constant pool. The default parser owns its string copies.
    pub fn borrowSourceStrings(self: *Parser) void {
        std.debug.assert(self.constants.strings.items.len == 0);
        self.constants.borrowed_source = self.source;
    }

    pub fn initExpression(allocator: std.mem.Allocator, source: []const u8) !Parser {
        return initWithProfile(allocator, allocator, source, true, null, false);
    }

    /// Private direct-source admission parser. It owns the syntax collector and
    /// never changes the behavior of `init`.
    pub fn initAdmission(
        allocator: std.mem.Allocator,
        type_allocator: std.mem.Allocator,
        source: []const u8,
        mode: type_syntax.AdmissionMode,
    ) !Parser {
        return initWithProfile(allocator, type_allocator, source, false, mode, false);
    }

    pub fn initSourceObserver(
        allocator: std.mem.Allocator,
        type_allocator: std.mem.Allocator,
        source: []const u8,
        mode: type_syntax.AdmissionMode,
    ) !Parser {
        return initWithProfile(allocator, type_allocator, source, false, mode, true);
    }

    fn initWithProfile(
        allocator: std.mem.Allocator,
        type_allocator: std.mem.Allocator,
        source: []const u8,
        expression_profile: bool,
        admission_mode: ?type_syntax.AdmissionMode,
        source_only: bool,
    ) !Parser {
        var nodes = IRStore.initCapacity(allocator, source.len);
        errdefer nodes.deinit();

        const no_token = Token.synthetic(.eof, .{
            .line = 1,
            .column = 1,
            .offset = 0,
        });

        var parser = Parser{
            .allocator = allocator,
            .tokenizer = Tokenizer.init(source),
            .source = source,
            .nodes = nodes,
            .constants = ConstantPool.init(allocator),
            .scopes = try ScopeAnalyzer.init(allocator),
            .errors = ErrorList.init(allocator, source),
            .type_store = type_syntax.Store.init(type_allocator, source),
            .last_erased_type_span = null,
            .type_only_module_refusal = null,
            .type_only_module_diagnostics = .empty,
            .admission = if (admission_mode) |mode|
                type_syntax.AdmissionCollector.init(type_allocator, mode)
            else
                null,
            .admission_observations = if (admission_mode != null)
                type_syntax.AdmissionObservationHistory.init(type_allocator)
            else
                null,
            .admission_failure = null,
            .pending_admission_trivia = null,
            .admission_error_prefix = null,
            .admission_first_error = null,
            .admission_in_import = false,
            .admission_presentation = .{ .source = source },
            .admission_parameter_header = false,
            .source_only = source_only,
            .admission_recovery_observing = source_only,
            .current = no_token,
            .previous = no_token,
            .atoms = null,
            .in_loop = false,
            .in_function = false,
            .expression_profile = expression_profile,
        };
        if (parser.admission) |*collector| collector.source = source;
        if (parser.admission_observations) |*history| history.source = source;
        if (source_only) parser.admission_recovery = .{
            .cursor = parser.cursorCheckpoint(),
            .presentation = parser.admission_presentation,
            .covered_until = 0,
            .quoted_region = .{ .start = 0, .end = 0 },
        };
        // Prime the parser with first token
        parser.advance();
        return parser;
    }

    pub fn deinit(self: *Parser) void {
        if (self.printable_regions) |*regions| regions.deinit(self.type_store.allocator);
        self.scratch_nodes.deinit(self.allocator);
        self.nodes.deinit();
        self.constants.deinit();
        self.scopes.deinit();
        self.errors.deinit();
        self.type_only_module_diagnostics.deinit(self.type_store.allocator);
        if (self.admission) |*collector| collector.deinit();
        if (self.admission_observations) |*observations| observations.deinit();
        if (self.admission_recovery) |*recovery| recovery.erasures.deinit(self.type_store.allocator);
        self.type_store.deinit();
    }

    pub fn setAtomTable(self: *Parser, atoms: *atom_table.AtomTable) void {
        self.atoms = atoms;
    }

    /// Parse the entire program
    pub fn parse(self: *Parser) anyerror!NodeIndex {
        if (self.admission != null) {
            return switch (try self.parseAdmission()) {
                .accepted => |root| root,
                .recovered_admission_refused => error.AdmissionRefused,
                .parser_refused => |refusal| refusal.first_error,
                .terminal_admission_refused => |failure| switch (failure) {
                    .diagnostic => error.AdmissionRefused,
                    .unterminated_comment => error.UnterminatedComment,
                },
            };
        }
        return self.parseProgram();
    }

    pub fn parseAdmission(self: *Parser) anyerror!AdmissionParseOutcome {
        if (self.admission == null) return error.InvalidParserMode;
        const root = self.parseProgram() catch |err| {
            if (self.errors.outOfMemory()) return error.OutOfMemory;
            switch (err) {
                error.OutOfMemory => return err,
                error.AdmissionRefused,
                error.TypeOnlyModuleRefused,
                error.UnterminatedComment,
                => {
                    try self.replaySourceAdmission();
                    if (self.terminalAdmissionFailure()) |failure| {
                        return .{ .terminal_admission_refused = failure };
                    }
                    if (self.admissionSelected()) return .recovered_admission_refused;
                    return err;
                },
                error.InvalidEscapeSequence,
                error.InvalidNumber,
                error.MissingSemicolon,
                error.ParseError,
                error.StringLineContinuation,
                error.TooManyConstants,
                error.TooManyLocals,
                error.UnexpectedToken,
                => {
                    try self.replaySourceAdmission();
                    if (self.terminalAdmissionFailure()) |failure| {
                        return .{ .terminal_admission_refused = failure };
                    }
                    if (self.admissionSelected()) return .recovered_admission_refused;
                    const first_error = self.admission_first_error orelse err;
                    return .{ .parser_refused = .{
                        .first_error = first_error,
                        .projected_error_count = self.getProjectedErrors().len,
                    } };
                },
                else => return err,
            }
        };
        return .{ .accepted = root };
    }

    fn replaySourceAdmission(self: *Parser) !void {
        var observer = try Parser.initSourceObserver(
            self.allocator,
            self.type_store.allocator,
            self.source,
            self.admission.?.mode,
        );
        defer observer.deinit();
        observer.observeSourceProgram() catch |err| switch (err) {
            error.AdmissionRefused, error.UnterminatedComment, error.TypeOnlyModuleRefused => {},
            else => return err,
        };
        const failure = observer.terminalAdmissionFailure();
        if ((self.admissionSelected() or self.terminalAdmissionFailure() != null) and
            !observer.admissionSelected() and failure == null)
        {
            // The parser already observed a refusal in the authored source.
            // Source-only replay can find no diagnostic in malformed input.
            // Keep the original refusal instead of replacing it with an
            // empty observation.
            return;
        }
        self.admission.?.deinit();
        self.admission = observer.admission;
        observer.admission = null;
        self.admission_observations.?.deinit();
        self.admission_observations = observer.admission_observations;
        observer.admission_observations = null;
        self.admission_failure = failure;
    }

    pub fn observeSourceProgram(self: *Parser) !void {
        if (!self.source_only or self.admission == null) return error.InvalidParserMode;
        if (self.admission_recovery == null) return error.InvalidAdmissionRecovery;
        var context: SourceObservationContext = .{};
        defer context.deinit(self.type_store.allocator);
        var progress: ProgressGuard = .{};
        while (true) {
            try self.reachAdmissionBoundary();
            if (self.current.type == .eof) break;
            progress.iteration(self);
            if (self.current.type == .string_literal and
                try self.observeCommittedString(self.current)) continue;
            if (self.current.type == .template_head) {
                try self.skipAdmissionTemplateCurrent();
                continue;
            }
            if (try self.tryConsumeTypeOnlyModule() or
                try self.tryConsumeTypeDeclaration() or
                try self.tryConsumeAdmissionDeclaration())
            {
                if (self.last_erased_type_span) |span| try self.recordRecoveryErasure(span);
                continue;
            }
            if (try self.tryConsumeAdmissionAssertion()) continue;
            // A leading colon has no declaration before it. Treating it as
            // an annotation can hide a malformed string after the colon.
            if (self.current.type == .colon and self.previous.type != .eof and
                !context.in_expression and
                !self.observedLabelColon() and !self.observedMatchArmColon())
            {
                if (try self.collectVariableTypeAdmission(self.current)) |input| {
                    const colon = self.current;
                    try self.recordRecoveryErasure(.{ .start = colon.start, .end = input.admission_end });
                    try self.resumeAfterRawErasureObserved(input.admission_end, self.previous);
                    continue;
                }
            }
            if (try self.observeRecoveryExport()) {
                context.expect_binding = false;
                continue;
            }
            if (self.current.type == .kw_function) {
                _ = try self.observeRecoveryFunction();
                context.in_expression = false;
                context.expect_binding = false;
                continue;
            }
            if (self.current.type == .lparen and try self.observeSourceHeader(.arrow)) {
                try self.observeRecoveryHeader(.arrow);
                context.in_expression = true;
                context.expect_binding = false;
                continue;
            }
            if (try self.observeRecoveryGeneric()) continue;
            if (sourceTokenContainsAssignment(self.current, self.source)) {
                const assignment = self.current;
                self.advance();
                if (self.current.type == .lparen and
                    type_syntax.hasDedicatedAssignmentArrowWindow(self.source, assignment, self.current.start) and
                    try self.observeSourceHeader(.return_colon))
                {
                    try self.observeRecoveryHeader(.arrow);
                }
                context.in_expression = true;
                context.expect_binding = false;
                continue;
            }
            try context.consume(self.type_store.allocator, self.current, self.source);
            self.advance();
        }
    }

    pub fn observePrintableSource(self: *Parser) ![]const PrintableRegion {
        if (self.printable_regions != null) return error.InvalidParserPhase;
        self.printable_regions = .empty;
        try self.observeSourceProgram();
        return self.printable_regions.?.items;
    }

    fn recordPrintableRegion(self: *Parser, region: PrintableRegion) !void {
        if (self.printable_regions) |*regions| try regions.append(self.type_store.allocator, region);
    }

    const HeaderConfirmation = enum { return_colon, arrow };

    fn observeSourceHeader(self: *Parser, confirmation: HeaderConfirmation) !bool {
        return self.observeSourceHeaderAt(self.current.start, confirmation);
    }

    fn observeSourceHeaderAt(self: *Parser, opener: u32, confirmation: HeaderConfirmation) !bool {
        var caught: std.ArrayListUnmanaged(type_syntax.AdmissionDiagnostic) = .empty;
        defer caught.deinit(self.type_store.allocator);
        const result = try type_syntax.scanAdmissionHeaderProbe(self.type_store.allocator, .{
            .source = self.source,
            .opener = opener,
            .confirmation = switch (confirmation) {
                .return_colon => .return_colon,
                .arrow => .arrow,
            },
            .position = try self.admission_presentation.positionAt(opener),
            .caught = &caught,
        });
        try self.commitAdmissionCaught(caught.items);
        return switch (result) {
            .matched => true,
            .not_matched => false,
            .nesting_too_deep => |diagnostic| {
                try self.recordFatalAdmission(diagnostic);
                return error.AdmissionRefused;
            },
        };
    }

    fn sourceTokenContainsAssignment(token: Token, source: []const u8) bool {
        return switch (token.type) {
            .number, .string_literal, .template_literal, .regex_literal => false,
            else => std.mem.indexOfScalar(u8, token.text(source), '=') != null,
        };
    }

    fn observedByte(self: *const Parser, offset: usize) u8 {
        const original = self.source[offset];
        const erasures = self.admission_recovery.?.erasures.items;
        var start: usize = 0;
        var end = erasures.len;
        while (start < end) {
            const middle = start + (end - start) / 2;
            if (erasures[middle].end <= offset) start = middle + 1 else end = middle;
        }
        if (start < erasures.len and erasures[start].start <= offset) {
            return if (original == '\n') original else ' ';
        }
        return original;
    }

    fn observedSkipWhitespace(self: *const Parser, from: usize) usize {
        var position = from;
        while (position > 0 and switch (self.observedByte(position - 1)) {
            ' ', '\t', '\r', '\n' => true,
            else => false,
        }) position -= 1;
        return position;
    }

    fn observedLabelColon(self: *const Parser) bool {
        const colon = self.current.start;
        var start: usize = colon;
        while (start > 0 and isAsciiIdentifierContinue(self.observedByte(start - 1))) start -= 1;
        if (start == colon or !isAsciiIdentifierStart(self.observedByte(start))) return false;
        if (start == 0) return true;
        var before = start - 1;
        while (before > 0 and (self.observedByte(before) == ' ' or
            self.observedByte(before) == '\t')) before -= 1;
        return switch (self.observedByte(before)) {
            ';', '{', '}', '\n' => true,
            else => false,
        };
    }

    fn observedMatchArmColon(self: *const Parser) bool {
        var position = self.observedSkipWhitespace(self.current.start);
        if (position == 0 or self.observedByte(position - 1) != '}') return false;
        position -= 1;
        var depth: u32 = 1;
        while (position > 0 and depth > 0) {
            position -= 1;
            switch (self.observedByte(position)) {
                '}' => depth += 1,
                '{' => depth -= 1,
                else => {},
            }
        }
        if (depth != 0) return false;
        position = self.observedSkipWhitespace(position);
        if (position < 4) return false;
        for ("when", 0..) |byte, index| {
            if (self.observedByte(position - 4 + index) != byte) return false;
        }
        return position == 4 or !isAsciiIdentifierContinue(self.observedByte(position - 5));
    }

    fn parseProgram(self: *Parser) anyerror!NodeIndex {
        const stmts = self.beginScratchList();
        defer stmts.deinit();

        var progress: ProgressGuard = .{};
        while (true) {
            try self.reachAdmissionBoundary();
            if (self.check(.eof)) break;
            progress.iteration(self);
            if (self.admission) |collector| {
                if (collector.shouldStop()) return error.AdmissionRefused;
            }
            if (try self.tryConsumeTypeOnlyModule()) continue;
            if (try self.tryConsumeAdmissionDeclaration()) continue;
            if (try self.tryConsumeTypeDeclaration()) continue;
            const statement_start = self.current.start;
            if (self.parseStatement()) |stmt| {
                try stmts.append(stmt);
            } else |err| {
                if (self.first_statement_failure_nodes == null) {
                    self.first_statement_failure_nodes = self.nodes.tags.items.len;
                }
                if (self.shouldPropagateAdmissionError(err)) return err;
                try self.reachAdmissionBoundary();
                try self.recordUnreportedStatementError(err);
                if (self.admission) |collector| if (collector.hasFatal()) {
                    return error.AdmissionRefused;
                };
                // An error the list could not record is an out-of-memory, not a
                // syntax error. Report it as one: `hasErrors` counts it, so the
                // loop stops, but `err` would name the wrong cause. Without this
                // the whole loop would spin forever, because a truncated error
                // left `hasErrors` false and `synchronize` returns without
                // advancing when the current token starts a statement.
                if (self.errors.outOfMemory()) return error.OutOfMemory;
                // Plain parsers preserve the immediate failure. The admission
                // parser continues only to find a higher-priority refusal.
                if (self.errors.hasErrors()) {
                    if (self.admission == null) return err;
                    if (self.admission_error_prefix == null) {
                        self.admission_error_prefix = self.errors.getErrors().len;
                        self.admission_first_error = err;
                    }
                }
                try self.synchronize(0);
                if (self.current.start == statement_start and !self.check(.eof)) self.advance();
            }
        }

        if (self.admissionFailureResult()) |failure| return failure;
        if (self.type_only_module_refusal != null) return error.TypeOnlyModuleRefused;

        if (self.admissionSelected()) return error.AdmissionRefused;
        if (self.admission_first_error) |first| return first;

        // If any errors were recorded during parsing, fail
        if (self.errors.hasErrors()) {
            return error.ParseError;
        }

        // Create program node
        const stmts_count = try self.checkedU16Count(.{ .line = 1, .column = 1, .offset = 0 }, stmts.slice().len, "too many top-level statements; limit is 65535");
        const stmts_start = try self.addStmtList(stmts.slice());
        return try self.nodes.addBlock(.program, .{ .line = 1, .column = 1, .offset = 0 }, .{
            .stmts_start = stmts_start,
            .stmts_count = stmts_count,
            .scope_id = 0,
        });
    }

    fn admissionSelected(self: *const Parser) bool {
        return if (self.admission) |collector| collector.items().len != 0 else false;
    }

    fn terminalAdmissionFailure(self: *const Parser) ?AdmissionFailure {
        if (self.admission) |collector| {
            if (collector.isCompile() and collector.items().len != 0) {
                return .{ .diagnostic = collector.items()[0] };
            }
        }
        return self.admission_failure;
    }

    fn admissionFailureResult(self: *const Parser) ?anyerror {
        if (self.admission_failure == null) return null;
        if (self.admission) |collector| {
            if (collector.hasFatal() or
                (collector.isCompile() and collector.items().len != 0))
            {
                return error.AdmissionRefused;
            }
        }
        return switch (self.admission_failure.?) {
            .diagnostic => error.AdmissionRefused,
            .unterminated_comment => error.UnterminatedComment,
        };
    }

    fn shouldPropagateAdmissionError(self: *const Parser, err: anyerror) bool {
        if (self.admission == null) return false;
        return switch (err) {
            error.AdmissionRefused,
            error.InvalidEscapeSequence,
            error.InvalidNumber,
            error.MissingSemicolon,
            error.ParseError,
            error.StringLineContinuation,
            error.TooManyConstants,
            error.TooManyLocals,
            error.TypeOnlyModuleRefused,
            error.UnexpectedToken,
            error.UnterminatedComment,
            => false,
            else => true,
        };
    }

    fn admissionSink(self: *Parser) ?type_syntax.AdmissionSink {
        const collector = if (self.admission) |*active| active else return null;
        const observations = if (self.admission_observations) |*active| active else null;
        var sink = type_syntax.AdmissionSink.init(collector, observations);
        sink.presentation = self.admission_presentation;
        return sink;
    }

    fn recordAdmission(
        self: *Parser,
        kind: type_syntax.AdmissionKind,
        span: type_syntax.Span,
        fatal: bool,
    ) !void {
        if (self.admissionSink()) |sink| {
            const diagnostic: type_syntax.AdmissionDiagnostic = .{ .kind = kind, .span = span };
            if (fatal) {
                try self.recordFatalAdmission(diagnostic);
            } else {
                try sink.recordRecoverable(diagnostic);
            }
            if (sink.shouldStop()) return error.AdmissionRefused;
        }
    }

    fn recordFatalAdmission(
        self: *Parser,
        diagnostic: type_syntax.AdmissionDiagnostic,
    ) !void {
        const sink = self.admissionSink() orelse return;
        const presented = try sink.present(diagnostic);
        try sink.recordFatal(presented);
        self.admission_failure = .{ .diagnostic = presented };
    }

    fn recordRecoveryErasure(self: *Parser, span: type_syntax.Span) !void {
        if (!self.admission_recovery_observing or span.start == span.end) return;
        if (span.start > span.end or @as(usize, span.end) > self.source.len) {
            return error.InvalidAdmissionSpan;
        }
        const recovery = if (self.admission_recovery) |*active| active else return error.InvalidAdmissionRecovery;
        var merged = tokenizer_mod.RecoveryErasure{ .start = span.start, .end = span.end };
        while (recovery.erasures.items.len > 0) {
            const last = recovery.erasures.items[recovery.erasures.items.len - 1];
            if (last.end < merged.start) break;
            if (last.start > merged.end) return error.InvalidAdmissionRecovery;
            merged.start = @min(last.start, merged.start);
            merged.end = @max(last.end, merged.end);
            recovery.erasures.items.len -= 1;
        }
        try recovery.erasures.append(self.type_store.allocator, merged);
    }

    fn collectTypeAdmission(
        self: *Parser,
        raw_start: u32,
        endpoint_policy: type_syntax.AdmissionEndpointPolicy,
        type_policy: type_syntax.AdmissionTypePolicy,
        failure_policy: enum { propagate, recover },
        raw_end_out: ?*u32,
    ) !void {
        if (self.admission == null) return;
        var caught: std.ArrayListUnmanaged(type_syntax.AdmissionDiagnostic) = .empty;
        defer caught.deinit(self.type_store.allocator);
        var progress: type_syntax.AdmissionEndpointProgress = .{
            .sink = self.admissionSink().?,
            .policy = type_policy,
            .classification_start = raw_start,
        };
        defer self.admission_presentation = progress.sink.presentation.?;
        const endpoint = try type_syntax.scanAdmissionEndpointWithPresentation(
            self.type_store.allocator,
            self.source,
            raw_start,
            endpoint_policy,
            &caught,
            &progress,
        );
        self.admission_presentation = progress.sink.presentation.?;
        const sink = progress.sink;
        switch (endpoint) {
            .complete => |span| {
                const erases_type = switch (endpoint_policy) {
                    .general => |kind| kind != .arrow_return or self.hasArrowAt(span.end),
                    else => true,
                };
                if (erases_type) try self.recordRecoveryErasure(span);
                if (raw_end_out) |out| out.* = span.end;
                if (erases_type) try self.recordPrintableRegion(.{ .raw_type = .{ .start = raw_start, .end = span.end } });
                try type_syntax.classifyTypeSpan(
                    self.source,
                    .{
                        .span = .{ .start = progress.classification_start, .end = span.end },
                        .policy = type_policy,
                        .caught_lexical = caught.items,
                        .removed_span = span,
                    },
                    sink,
                );
                if (sink.shouldStop()) return error.AdmissionRefused;
            },
            .nesting_too_deep => |offset| {
                if (raw_end_out) |out| out.* = offset;
                try type_syntax.classifyTypeSpanPrefix(
                    self.source,
                    .{
                        .span = .{ .start = progress.classification_start, .end = offset },
                        .policy = type_policy,
                        .caught_lexical = caught.items,
                    },
                    sink,
                );
                if (sink.shouldStop()) return error.AdmissionRefused;
                if (failure_policy == .propagate) {
                    try self.recordFatalAdmission(.{
                        .kind = .nesting_too_deep,
                        .span = .{ .start = offset, .end = offset +| 1 },
                    });
                    return error.AdmissionRefused;
                }
            },
            .unterminated_comment => |failure| {
                if (raw_end_out) |out| out.* = failure.@"resume";
                try type_syntax.classifyTypeSpanPrefix(
                    self.source,
                    .{
                        .span = .{ .start = progress.classification_start, .end = failure.opener },
                        .policy = type_policy,
                        .caught_lexical = caught.items,
                    },
                    sink,
                );
                if (sink.shouldStop()) return error.AdmissionRefused;
                if (failure_policy == .propagate) {
                    if (self.admission_failure == null) {
                        self.admission_failure = .{ .unterminated_comment = failure };
                    }
                    return error.UnterminatedComment;
                }
            },
        }
    }

    fn classifyAdmissionSpan(
        self: *Parser,
        span: type_syntax.Span,
        policy: type_syntax.AdmissionTypePolicy,
    ) !void {
        if (self.admissionSink()) |sink| {
            try type_syntax.classifyTypeSpan(
                self.source,
                .{ .span = span, .policy = policy },
                sink,
            );
            if (sink.shouldStop()) return error.AdmissionRefused;
        }
    }

    fn classifyAdmissionGenericList(self: *Parser, span: type_syntax.Span) !void {
        if (self.admission == null) return;
        if (span.start >= span.end or
            @as(usize, span.end) > self.source.len or
            span.end - span.start < 2 or
            self.source[span.start] != '<' or
            self.source[span.end - 1] != '>')
        {
            return error.InvalidAdmissionSpan;
        }
        try self.classifyAdmissionSpan(.{
            .start = span.start + 1,
            .end = span.end - 1,
        }, .removed_only);
    }

    fn commitAdmissionCaught(
        self: *Parser,
        caught: []const type_syntax.AdmissionDiagnostic,
    ) !void {
        const sink = self.admissionSink() orelse return;
        for (caught) |diagnostic| try sink.recordCaught(diagnostic);
    }

    fn scanAdmissionGenericListStaged(
        self: *Parser,
        start: u32,
        caught: *std.ArrayListUnmanaged(type_syntax.AdmissionDiagnostic),
    ) !type_syntax.AdmissionGenericScan {
        return type_syntax.scanAdmissionGenericList(
            self.type_store.allocator,
            .{ .source = self.source, .start = start, .caught = caught },
        );
    }

    fn scanAdmissionCallTypeArgumentsStaged(
        self: *Parser,
        start: u32,
        caught: *std.ArrayListUnmanaged(type_syntax.AdmissionDiagnostic),
    ) !type_syntax.AdmissionGenericScan {
        return type_syntax.scanAdmissionCallTypeArguments(
            self.type_store.allocator,
            .{ .source = self.source, .start = start, .caught = caught },
        );
    }

    fn scanObservedGenericList(
        self: *Parser,
        start: u32,
    ) !type_syntax.AdmissionGenericScan {
        var caught: std.ArrayListUnmanaged(type_syntax.AdmissionDiagnostic) = .empty;
        defer caught.deinit(self.type_store.allocator);
        const result = try self.scanAdmissionGenericListStaged(start, &caught);
        try self.commitAdmissionCaught(caught.items);
        return result;
    }

    fn scanObservedCallTypeArguments(
        self: *Parser,
        start: u32,
    ) !type_syntax.AdmissionGenericScan {
        var caught: std.ArrayListUnmanaged(type_syntax.AdmissionDiagnostic) = .empty;
        defer caught.deinit(self.type_store.allocator);
        const result = try self.scanAdmissionCallTypeArgumentsStaged(start, &caught);
        try self.commitAdmissionCaught(caught.items);
        return result;
    }

    fn cursorAfterAdmittedGeneric(
        self: *const Parser,
        list_end: u32,
        runtime_previous: Token,
    ) type_syntax.Cursor {
        var tokenizer = self.tokenizer;
        tokenizer.resumeAfterRawErasure(list_end, runtime_previous);
        return type_syntax.Cursor.afterCurrent(tokenizer);
    }

    fn scanObservedBraceBody(
        self: *Parser,
        start: u32,
    ) !type_syntax.AdmissionBraceScan {
        var caught: std.ArrayListUnmanaged(type_syntax.AdmissionDiagnostic) = .empty;
        defer caught.deinit(self.type_store.allocator);
        const result = try type_syntax.scanAdmissionBraceBody(
            self.type_store.allocator,
            .{ .source = self.source, .start = start, .caught = &caught },
        );
        try self.commitAdmissionCaught(caught.items);
        return result;
    }

    fn refuseAdmissionNesting(self: *Parser, offset: u32) !noreturn {
        try self.recordFatalAdmission(.{
            .kind = .nesting_too_deep,
            .span = .{ .start = offset, .end = offset +| 1 },
        });
        return error.AdmissionRefused;
    }

    fn tryConsumeAdmissionAssertion(self: *Parser) !bool {
        if (self.admissionCoveredByRecovery(self.current.start)) return false;
        if (self.admission == null) return false;
        const kind: type_syntax.AdmissionKind = if (self.current.type == .kw_as)
            .as_assertion
        else if (self.current.type == .identifier and
            std.mem.eql(u8, self.current.text(self.source), "satisfies"))
            .satisfies_assertion
        else
            return false;
        if (kind == .as_assertion and self.admission_in_import) return false;
        if (!self.admissionAssertionHasTypeStart(self.current)) return false;
        const marker_start = self.current.start;
        self.admission_presentation = try self.admission_presentation.trackedWhitespaceAt(self.current.start + self.current.len);
        const runtime_previous = self.previous;
        var survivor_tokenizer = self.tokenizer;
        self.advance();
        const raw_start = self.current.start;
        try self.recordAdmission(kind, .{
            .start = raw_start,
            .end = @min(raw_start +| self.current.len, @as(u32, @intCast(self.source.len))),
        }, false);
        var raw_end = raw_start;
        try self.collectTypeAdmission(
            raw_start,
            .{ .general = .assertion },
            .any_only,
            .recover,
            &raw_end,
        );
        try self.recordRecoveryErasure(.{ .start = marker_start, .end = raw_end });
        survivor_tokenizer.resumeAfterRawErasure(raw_end, runtime_previous);
        self.tokenizer = survivor_tokenizer;
        self.previous = runtime_previous;
        self.current = self.nextTokenStagingAdmissionTrivia();
        if (@import("builtin").mode.runtimeSafety()) self.tokens_advanced +%= 1;
        self.reportNonAscii();
        return true;
    }

    fn admissionAssertionHasTypeStart(self: *const Parser, keyword: Token) bool {
        return self.hasAdmissionTypeStart(keyword.start + keyword.len);
    }

    /// True when the current colon is followed, after whitespace, by a single
    /// `=`: a declaration that names no type before its initializer.
    fn colonBeforeAssign(self: *const Parser) bool {
        if (self.admission != null and self.admissionCoveredByRecovery(self.current.start)) return false;
        var pos: usize = self.current.start + self.current.len;
        while (pos < self.source.len and switch (self.source[pos]) {
            ' ', '\t', '\r', '\n' => true,
            else => false,
        }) pos += 1;
        if (pos >= self.source.len or self.source[pos] != '=') return false;
        return pos + 1 >= self.source.len or self.source[pos + 1] != '=';
    }

    fn hasAdmissionTypeStart(self: *const Parser, after_marker: u32) bool {
        if (self.admissionCoveredByRecovery(after_marker -| 1)) return false;
        var pos: usize = after_marker;
        while (pos < self.source.len and switch (self.source[pos]) {
            ' ', '\t', '\r', '\n' => true,
            else => false,
        }) pos += 1;
        if (pos == self.source.len) return false;
        const byte = self.source[pos];
        return isAsciiIdentifierStart(byte) or switch (byte) {
            '{', '(', '[', '<', '\'', '"', '`' => true,
            else => false,
        };
    }

    fn malformedStringLf(self: *const Parser, token_value: Token) ?u32 {
        if (token_value.type != .string_literal) return null;
        const text = token_value.text(self.source);
        var pos: usize = 1;
        while (pos < text.len) {
            if (text[pos] == '\\' and pos + 1 < text.len) {
                pos += 2;
                continue;
            }
            if (text[pos] == '\n') return token_value.start + @as(u32, @intCast(pos));
            pos += 1;
        }
        return null;
    }

    fn observeCommittedString(self: *Parser, token_value: Token) !bool {
        if (self.admission == null or self.admissionCoveredByRecovery(token_value.start)) return false;
        const lf = self.malformedStringLf(token_value) orelse return false;
        try self.recordAdmission(.unterminated_string, .{ .start = lf, .end = lf + 1 }, true);
        const runtime_previous = self.previous;
        self.tokenizer.resumeMalformedStringAt(token_value, lf, runtime_previous);
        self.previous = runtime_previous;
        self.current = self.nextTokenStagingAdmissionTrivia();
        if (@import("builtin").mode.runtimeSafety()) self.tokens_advanced +%= 1;
        self.reportNonAscii();
        return true;
    }

    fn skipAdmissionTemplateCurrent(self: *Parser) !void {
        if (self.admission == null or self.current.type != .template_head) return;
        const head = self.current;
        var caught: std.ArrayListUnmanaged(type_syntax.AdmissionDiagnostic) = .empty;
        defer caught.deinit(self.type_store.allocator);
        const scan = try type_syntax.scanAdmissionTemplate(
            self.type_store.allocator,
            self.source,
            head.start,
            &caught,
        );
        const sink = self.admissionSink().?;
        for (caught.items) |diagnostic| try sink.recordCaught(diagnostic);
        const raw_end = switch (scan) {
            .complete => |end| end,
            .nesting_too_deep => |offset| {
                try self.recordFatalAdmission(.{
                    .kind = .nesting_too_deep,
                    .span = .{ .start = offset, .end = offset +| 1 },
                });
                return error.AdmissionRefused;
            },
        };
        self.tokenizer.resumeAfterRawTemplate(head, raw_end);
        self.current = self.nextTokenStagingAdmissionTrivia();
        if (@import("builtin").mode.runtimeSafety()) self.tokens_advanced +%= 1;
        self.reportNonAscii();
    }

    /// Parse exactly one expression with the profile selected by
    /// `initExpression`, using the same Pratt parser as full programs.
    pub fn parseExpressionOnly(self: *Parser) anyerror!NodeIndex {
        if (!self.expression_profile) return error.InvalidParserMode;
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

    fn recursionLimit(self: *const Parser) u32 {
        return if (self.expression_profile) 64 else max_recursion_depth;
    }

    fn tryConsumeTypeOnlyModule(self: *Parser) !bool {
        if (self.admissionCoveredByRecovery(self.current.start)) return false;
        if (self.admission == null or !self.isTypeDeclarationBoundary()) return false;
        if (self.current.type != .kw_import and self.current.type != .kw_export) return false;

        const cursor_checkpoint = self.cursorCheckpoint();
        const store_checkpoint = self.type_store.checkpoint();
        const diagnostic_start = self.type_only_module_diagnostics.items.len;
        errdefer {
            self.restoreCursorCheckpoint(cursor_checkpoint);
            self.type_store.rollback(store_checkpoint);
        }

        const presentation_origin = self.admission_presentation;
        const keyword = self.current;
        const scan = try type_syntax.scanTypeOnlyModule(self.type_store.allocator, .{
            .source = self.source,
            .keyword = self.current,
            .diagnostics = &self.type_only_module_diagnostics,
        });
        switch (scan) {
            .not_type_only => return false,
            else => {},
        }
        {
            var selected = try presentation_origin.trackedWhitespaceAt(keyword.start + keyword.len);
            if (keyword.type == .kw_export) {
                selected = try selected.trackedWhitespaceAt(selected.offset + @as(u32, "type".len));
            }
            self.admission_presentation = selected;
        }
        if (self.admissionSink()) |sink| {
            for (self.type_only_module_diagnostics.items[diagnostic_start..]) |diagnostic| {
                try sink.recordCaught(.{
                    .kind = switch (diagnostic.kind) {
                        .unterminated_string => .unterminated_string,
                        .nesting_too_deep => .nesting_too_deep,
                    },
                    .span = .{ .start = diagnostic.offset, .end = diagnostic.offset +| 1 },
                });
            }
        }
        const module = switch (scan) {
            .not_type_only => return false,
            .refused => |refusal| {
                var origin_sink = self.admissionSink();
                if (origin_sink) |*sink| sink.presentation = presentation_origin;
                const raw_diagnostic: type_syntax.AdmissionDiagnostic = .{
                    .kind = .legacy_types_import,
                    .span = .{
                        .start = refusal.original_location.offset,
                        .end = refusal.original_location.end_offset,
                    },
                };
                if (self.type_only_module_refusal == null) {
                    self.type_only_module_refusal = refusal;
                }
                const diagnostic = if (origin_sink) |sink| try sink.present(raw_diagnostic) else raw_diagnostic;
                try self.recordFatalAdmission(diagnostic);
                return error.TypeOnlyModuleRefused;
            },
            .excluded, .scanned => |module| module,
        };

        if (!self.source_only) try self.type_store.appendTypeOnlyModule(module);

        try self.resumeAfterRawErasureObserved(
            module.raw_span.end,
            cursor_checkpoint.previous,
        );
        self.last_erased_type_span = module.raw_span;
        return true;
    }

    fn tryConsumeTypeDeclaration(self: *Parser) !bool {
        if (self.admissionCoveredByRecovery(self.current.start)) return false;
        if (self.admission == null or !self.isTypeDeclarationBoundary()) return false;
        const publication_checkpoint = self.typePublicationCheckpoint();
        const store_checkpoint = self.type_store.checkpoint();
        errdefer self.type_store.rollback(store_checkpoint);
        const saved_previous = self.previous;
        const presentation_checkpoint = self.admission_presentation;
        var presentation_committed = false;
        defer if (!presentation_committed) {
            self.admission_presentation = presentation_checkpoint;
        };
        var cursor = type_syntax.Cursor.afterCurrent(self.tokenizer);
        var keyword = self.current;
        var export_span: ?type_syntax.Span = null;
        if (self.current.type == .kw_export) {
            export_span = .{
                .start = self.current.start,
                .end = self.current.start + self.current.len,
            };
            keyword = cursor.current;
            if (!containsOnlyAdmissionWhitespace(
                self.source,
                export_span.?.end,
                keyword.start,
            )) return false;
            cursor.advance();
        }
        if (keyword.type != .identifier) return false;
        const kind: type_syntax.DeclarationKind = if (std.mem.eql(u8, keyword.text(self.source), "structural"))
            .structural
        else if (std.mem.eql(u8, keyword.text(self.source), "nominal"))
            .nominal
        else
            return false;

        const name = cursor.current;
        if (!type_syntax.tokenIsDeclarationName(name, self.source) or
            !containsOnlyAdmissionWhitespace(
                self.source,
                keyword.start + keyword.len,
                name.start,
            )) return false;
        if (export_span) |span| {
            self.admission_presentation = try self.admission_presentation.trackedWhitespaceAt(span.end);
        }
        self.admission_presentation = try self.admission_presentation.trackedWhitespaceAt(keyword.start + keyword.len);
        self.admission_presentation = try self.admission_presentation.trackedWhitespaceAt(name.start + name.len);
        var raw_header_end: ?u32 = null;
        var body_cursor = cursor;
        body_cursor.advance();
        if (!containsOnlyAdmissionWhitespace(
            self.source,
            name.start + name.len,
            body_cursor.current.start,
        )) {
            if (kind == .nominal) {
                presentation_committed = true;
                try self.consumeAdmissionNominalAbsentBody(
                    keyword,
                    export_span,
                    name.start + name.len,
                    saved_previous,
                    store_checkpoint,
                );
                return true;
            }
            if (!self.admissionCommentAt(self.admission_presentation.offset)) return false;
            raw_header_end = self.admission_presentation.offset;
        }

        var generic_list: ?type_syntax.Span = null;
        if (raw_header_end == null and type_syntax.tokenStartsGenericList(self.source, body_cursor.current)) {
            const scanned = switch (try self.scanObservedGenericList(body_cursor.current.start)) {
                .scanned => |value| value,
                .not_matched, .lexical_nonmatch => return false,
                .nesting_too_deep => |offset| return try self.refuseAdmissionNesting(offset),
            };
            generic_list = scanned.span;
            presentation_committed = true;
            try self.classifyAdmissionGenericList(scanned.span);
            self.admission_presentation = try self.admission_presentation.trackedWhitespaceAt(scanned.span.end);
            var tokenizer = body_cursor.tokenizer;
            tokenizer.resumeAfterRawErasure(scanned.span.end, name);
            body_cursor = type_syntax.Cursor.afterCurrent(tokenizer);
            if (!containsOnlyAdmissionWhitespace(
                self.source,
                scanned.span.end,
                body_cursor.current.start,
            )) {
                if (kind == .nominal) {
                    try self.consumeAdmissionNominalAbsentBody(
                        keyword,
                        export_span,
                        scanned.span.end,
                        saved_previous,
                        store_checkpoint,
                    );
                    return true;
                }
                if (!self.admissionCommentAt(self.admission_presentation.offset)) {
                    presentation_committed = false;
                    return false;
                }
                raw_header_end = self.admission_presentation.offset;
            }
        }

        presentation_committed = true;
        var body: ?type_syntax.AdmittedTypeInput = null;
        if (raw_header_end == null and body_cursor.current.type == .assign) {
            const after_equals = body_cursor.current.start + body_cursor.current.len;
            self.admission_presentation = try self.admission_presentation.trackedWhitespaceAt(after_equals);
            var admission_end = after_equals;
            try self.collectTypeAdmission(
                after_equals,
                .declaration,
                if (kind == .nominal) .any_only else .general_type,
                .propagate,
                &admission_end,
            );
            body = try self.admittedTypeInput(after_equals, admission_end, true);
        }

        if (self.source_only) {
            var erased_end = raw_header_end orelse if (body) |input|
                input.admission_end
            else
                body_cursor.current.start;
            const body_span = if (body) |input| input.raw_span else type_syntax.Span{
                .start = erased_end,
                .end = erased_end,
            };
            if (generic_list) |span| try self.recordPrintableRegion(.{ .recorded_generic = span });
            if (body != null and body_span.end > body_span.start) {
                try self.recordPrintableRegion(.{ .declaration = .{
                    .name = .{ .start = name.start, .end = name.start + name.len },
                    .body = body_span,
                } });
            }
            if (kind == .nominal and (body == null or
                !type_syntax.isScalarNominalBase(body_span.text(self.source))))
            {
                try self.recordAdmission(.nominal_base_not_scalar, body_span, false);
            }
            if (body) |input| {
                self.admission_presentation = try self.admission_presentation.trackedWhitespaceAt(input.admission_end);
            }
            while (@as(usize, erased_end) < self.source.len and switch (self.source[erased_end]) {
                ' ', '\t', '\r', '\n' => true,
                else => false,
            }) erased_end += 1;
            if (@as(usize, erased_end) < self.source.len and self.source[erased_end] == ';') erased_end += 1;
            try self.resumeAfterRawErasureObserved(erased_end, saved_previous);
            self.last_erased_type_span = .{
                .start = if (export_span) |span| span.start else keyword.start,
                .end = erased_end,
            };
            return true;
        }

        const outcome = try type_syntax.parseAdmittedDeclarationAndStore(
            &self.type_store,
            .{
                .keyword = keyword,
                .export_span = export_span,
                .kind = kind,
                .authored_scope = self.scopes.getCurrentScope().id,
                .generic_list = generic_list,
                .body = body,
                .raw_header_end = raw_header_end,
            },
            &cursor,
        );
        const erased = switch (outcome) {
            .not_declaration => {
                presentation_committed = false;
                return false;
            },
            .excluded => |excluded| {
                if (excluded.reason != .nominal_base_not_scalar) {
                    presentation_committed = false;
                    return false;
                }
                try self.recordAdmission(.nominal_base_not_scalar, excluded.raw_span, false);
                if (self.admission.?.shouldStop()) return error.AdmissionRefused;
                self.admission_presentation = try self.admission_presentation.trackedWhitespaceAt(excluded.admission_end);
                var erased_end = excluded.admission_end;
                while (@as(usize, erased_end) < self.source.len and switch (self.source[erased_end]) {
                    ' ', '\t', '\r', '\n' => true,
                    else => false,
                }) erased_end += 1;
                if (@as(usize, erased_end) < self.source.len and
                    self.source[erased_end] == ';')
                {
                    erased_end += 1;
                }
                while (@as(usize, erased_end) < self.source.len and switch (self.source[erased_end]) {
                    ' ', '\t', '\r', '\n' => true,
                    else => false,
                }) erased_end += 1;
                try self.resumeAfterRawErasureObserved(erased_end, saved_previous);
                self.last_erased_type_span = .{
                    .start = if (export_span) |span| span.start else keyword.start,
                    .end = erased_end,
                };
                self.type_store.rollback(store_checkpoint);
                return true;
            },
            .parsed => |span| span,
        };
        if (body) |input| {
            self.admission_presentation = try self.admission_presentation.trackedWhitespaceAt(input.admission_end);
        }
        try self.resumeAfterRawErasureObserved(erased.end, saved_previous);
        self.last_erased_type_span = erased;
        if (!self.typeSyntaxPublicationHealthy(publication_checkpoint)) {
            self.type_store.rollback(store_checkpoint);
        }
        return true;
    }

    fn admissionCommentAt(self: *const Parser, offset: u32) bool {
        return self.source.len >= 2 and @as(usize, offset) <= self.source.len - 2 and
            self.source[offset] == '/' and
            (self.source[offset + 1] == '/' or self.source[offset + 1] == '*');
    }

    fn consumeAdmissionNominalAbsentBody(
        self: *Parser,
        keyword: Token,
        export_span: ?type_syntax.Span,
        raw_header_end: u32,
        runtime_previous: Token,
        store_checkpoint: type_syntax.Store.Checkpoint,
    ) !void {
        var erased_end = raw_header_end;
        while (@as(usize, erased_end) < self.source.len and switch (self.source[erased_end]) {
            ' ', '\t', '\r', '\n' => true,
            else => false,
        }) erased_end += 1;
        try self.recordAdmission(.nominal_base_not_scalar, .{
            .start = erased_end,
            .end = @min(erased_end +| 1, @as(u32, @intCast(self.source.len))),
        }, false);
        if (@as(usize, erased_end) < self.source.len and self.source[erased_end] == ';') {
            erased_end += 1;
        }
        while (@as(usize, erased_end) < self.source.len and switch (self.source[erased_end]) {
            ' ', '\t', '\r', '\n' => true,
            else => false,
        }) erased_end += 1;
        try self.resumeAfterRawErasureObserved(erased_end, runtime_previous);
        self.last_erased_type_span = .{
            .start = if (export_span) |span| span.start else keyword.start,
            .end = erased_end,
        };
        self.type_store.rollback(store_checkpoint);
    }

    fn tryConsumeAdmissionDeclaration(self: *Parser) !bool {
        if (self.admissionCoveredByRecovery(self.current.start)) return false;
        if (self.admission == null or !self.isTypeDeclarationBoundary()) return false;
        const outer_start = self.current.start;
        const presentation_checkpoint = self.admission_presentation;
        var presentation_committed = false;
        defer if (!presentation_committed) {
            self.admission_presentation = presentation_checkpoint;
        };
        var cursor = type_syntax.Cursor.afterCurrent(self.tokenizer);
        var keyword = self.current;
        if (keyword.type == .kw_export) {
            const export_keyword = keyword;
            keyword = cursor.current;
            if (!containsOnlyAdmissionWhitespace(
                self.source,
                export_keyword.start + export_keyword.len,
                keyword.start,
            )) return false;
            cursor.advance();
        }
        if (keyword.type != .identifier) return false;

        const keyword_text = keyword.text(self.source);
        var kind: type_syntax.AdmissionKind = undefined;
        var distinct_keyword: ?Token = null;
        if (std.mem.eql(u8, keyword_text, "interface")) {
            kind = .interface_declaration;
        } else if (std.mem.eql(u8, keyword_text, "type")) {
            kind = .type_alias_declaration;
        } else if (std.mem.eql(u8, keyword_text, "distinct")) {
            distinct_keyword = keyword;
            const type_keyword = cursor.current;
            if (type_keyword.type != .identifier or
                !std.mem.eql(u8, type_keyword.text(self.source), "type") or
                !containsOnlyAdmissionWhitespace(
                    self.source,
                    keyword.start + keyword.len,
                    type_keyword.start,
                )) return false;
            cursor.advance();
            keyword = type_keyword;
            kind = .distinct_type_declaration;
        } else return false;
        const refusal = try self.admissionSink().?.present(.{
            .kind = kind,
            .span = .{ .start = outer_start, .end = keyword.start + keyword.len },
        });

        if (!type_syntax.tokenIsDeclarationName(cursor.current, self.source) or
            !containsOnlyAdmissionWhitespace(
                self.source,
                keyword.start + keyword.len,
                cursor.current.start,
            )) return false;
        const name = cursor.current;
        cursor.advance();
        if (self.current.type == .kw_export) {
            self.admission_presentation = try self.admission_presentation.trackedWhitespaceAt(self.current.start + self.current.len);
        }
        if (distinct_keyword) |token| {
            self.admission_presentation = try self.admission_presentation.trackedWhitespaceAt(token.start + token.len);
        }
        self.admission_presentation = try self.admission_presentation.trackedWhitespaceAt(keyword.start + keyword.len);
        self.admission_presentation = try self.admission_presentation.trackedWhitespaceAt(name.start + name.len);
        var body_header_start = name.start + name.len;
        var body_header_is_whitespace = containsOnlyAdmissionWhitespace(
            self.source,
            body_header_start,
            cursor.current.start,
        );
        if (body_header_is_whitespace and
            type_syntax.tokenStartsGenericList(self.source, cursor.current))
        {
            const generic = switch (try self.scanObservedGenericList(cursor.current.start)) {
                .scanned => |value| value,
                .not_matched, .lexical_nonmatch => return false,
                .nesting_too_deep => |offset| return try self.refuseAdmissionNesting(offset),
            };
            presentation_committed = true;
            try self.classifyAdmissionGenericList(generic.span);
            self.admission_presentation = try self.admission_presentation.trackedWhitespaceAt(generic.span.end);
            var tokenizer = cursor.tokenizer;
            tokenizer.resumeAfterRawErasure(generic.span.end, name);
            cursor = type_syntax.Cursor.afterCurrent(tokenizer);
            body_header_start = generic.span.end;
            body_header_is_whitespace = containsOnlyAdmissionWhitespace(
                self.source,
                body_header_start,
                cursor.current.start,
            );
        }

        presentation_committed = true;
        var raw_end = cursor.current.start;
        if (!body_header_is_whitespace) {
            raw_end = body_header_start;
            while (@as(usize, raw_end) < self.source.len and switch (self.source[raw_end]) {
                ' ', '\t', '\r', '\n' => true,
                else => false,
            }) raw_end += 1;
        } else if (kind == .interface_declaration) {
            var body_cursor = cursor;
            if (cursor.current.type == .kw_extends) {
                const extends_start = cursor.current.start + cursor.current.len;
                self.admission_presentation = try self.admission_presentation.trackedWhitespaceAt(extends_start);
                try self.collectTypeAdmission(
                    extends_start,
                    .{ .general = .interface_extends },
                    .any_only,
                    .propagate,
                    &raw_end,
                );
                var candidate = body_cursor.tokenizer;
                candidate.resumeAfterRawErasure(raw_end, name);
                body_cursor = type_syntax.Cursor.afterCurrent(candidate);
            }
            if (body_cursor.current.type == .lbrace) {
                raw_end = switch (try self.scanObservedBraceBody(body_cursor.current.start)) {
                    .complete => |end| end,
                    .nesting_too_deep => |offset| return try self.refuseAdmissionNesting(offset),
                };
            }
        } else {
            if (cursor.current.type == .assign) {
                const body_start = cursor.current.start + cursor.current.len;
                self.admission_presentation = try self.admission_presentation.trackedWhitespaceAt(body_start);
                try self.collectTypeAdmission(
                    body_start,
                    .declaration,
                    .any_only,
                    .propagate,
                    &raw_end,
                );
            }
        }
        const sink = self.admissionSink().?;
        try sink.recordRecoverable(refusal);
        if (sink.shouldStop()) return error.AdmissionRefused;
        self.admission_presentation = try self.admission_presentation.trackedWhitespaceAt(raw_end);

        while (@as(usize, raw_end) < self.source.len and switch (self.source[raw_end]) {
            ' ', '\t', '\r', '\n' => true,
            else => false,
        }) raw_end += 1;
        if (@as(usize, raw_end) < self.source.len and self.source[raw_end] == ';') raw_end += 1;
        const runtime_previous = self.previous;
        try self.resumeAfterRawErasureObserved(raw_end, runtime_previous);
        self.last_erased_type_span = .{ .start = outer_start, .end = raw_end };
        return true;
    }

    fn isTypeDeclarationBoundary(self: *const Parser) bool {
        return self.isAdmissionStatementBoundaryAt(self.current.start);
    }

    fn isAdmissionStatementBoundaryAt(self: *const Parser, offset: u32) bool {
        const start: usize = offset;
        if (start == 0) return true;
        const previous_offset = start - 1;
        const previous_byte = if (self.last_erased_type_span) |span|
            if (previous_offset >= span.start and previous_offset < span.end)
                if (self.source[previous_offset] == '\n') @as(u8, '\n') else @as(u8, ' ')
            else
                self.source[previous_offset]
        else
            self.source[previous_offset];
        return previous_byte == ';' or previous_byte == '{' or previous_byte == '}' or
            previous_byte == '\n';
    }

    const TypePublicationCheckpoint = struct {
        error_count: usize,
        module_diagnostic_count: usize,
        admission_generation: ?u64,
        admission_failure: ?AdmissionFailure,
    };

    fn typePublicationCheckpoint(self: *const Parser) TypePublicationCheckpoint {
        return .{
            .error_count = self.errors.getErrors().len,
            .module_diagnostic_count = self.type_only_module_diagnostics.items.len,
            .admission_generation = if (self.admission) |collector| collector.generation() else null,
            .admission_failure = self.admission_failure,
        };
    }

    fn typeSyntaxPublicationHealthy(self: *const Parser, checkpoint: TypePublicationCheckpoint) bool {
        const admission_unchanged = if (checkpoint.admission_generation) |generation|
            self.admission.?.generation() == generation
        else
            true;
        const module_state_healthy = if (self.admission != null)
            true
        else
            self.type_only_module_diagnostics.items.len == checkpoint.module_diagnostic_count and
                self.type_only_module_refusal == null;
        return self.errors.getErrors().len == checkpoint.error_count and
            !self.errors.outOfMemory() and
            module_state_healthy and
            admission_unchanged and
            std.meta.eql(self.admission_failure, checkpoint.admission_failure);
    }

    // ============ Statement Parsing ============

    fn parseStatement(self: *Parser) anyerror!NodeIndex {
        const type_checkpoint = self.type_store.checkpoint();
        const publication_checkpoint = self.typePublicationCheckpoint();
        errdefer self.type_store.rollback(type_checkpoint);
        defer if (!self.typeSyntaxPublicationHealthy(publication_checkpoint)) {
            self.type_store.rollback(type_checkpoint);
        };
        self.recursion_depth += 1;
        defer self.recursion_depth -= 1;
        if (self.recursion_depth > self.recursionLimit()) {
            self.errors.addErrorAt(.nesting_too_deep, self.current, "statements nest too deeply; simplify or split (nesting limit is 512)");
            return error.ParseError;
        }
        if (try self.tryParseErasedBlockPrefix()) |block_node| return block_node;
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
            // Catches class declarations after TypeScript preparation.
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
            .semicolon => {
                self.errors.addErrorAt(.unsupported_feature, self.current, "empty statements are not supported; remove the standalone `;`");
                self.advance();
                return error.ParseError;
            },
            .kw_debugger => {
                self.errors.addErrorAt(.unsupported_feature, self.current, "`debugger` statements are not supported; remove the statement");
                self.advance();
                return error.ParseError;
            },
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
        const type_checkpoint = self.type_store.checkpoint();
        const publication_checkpoint = self.typePublicationCheckpoint();
        var retain_type_records = false;
        defer if (!retain_type_records) self.type_store.rollback(type_checkpoint);

        // Reject 'var' - only 'let' and 'const' are supported
        if (self.current.type == .kw_var) {
            const var_keyword = self.current;
            self.errors.addErrorAt(.unsupported_feature, var_keyword, "'var' is not supported; use 'let' or 'const' instead");
            if (!try self.collectVarDeclarationAdmission(var_keyword)) {
                self.advance(); // consume 'var' so synchronize() doesn't loop on it
            }
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

        // Model-1 declarations bind one name. Explicit member/index reads keep
        // every introduced binding visible and give declaration parsing one
        // shape instead of a second pattern language.
        if (self.check(.lbrace)) {
            self.errors.addErrorAt(.unsupported_feature, self.current, "declaration destructuring is not supported; bind the source to a name, then read each member with explicit `const` bindings");
            self.advance();
            return error.ParseError;
        } else if (self.check(.lbracket)) {
            self.errors.addErrorAt(.unsupported_feature, self.current, "declaration destructuring is not supported; bind the source to a name, then read each element with explicit indexed `const` bindings");
            self.advance();
            return error.ParseError;
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
        ) catch |err| {
            if (self.admission != null) switch (err) {
                error.OutOfMemory => return err,
                else => {},
            };
            self.errorAtCurrent("too many local variables");
            return error.TooManyLocals;
        };

        const annotation_index = if (self.admission != null and self.check(.colon) and
            self.hasAdmissionTypeStart(self.current.start + self.current.len))
            try self.parseVariableType(binding, name)
        else
            null;

        // A colon followed by `=` names no type. Report the missing type at the
        // colon and parse the initializer, rather than reading the colon as a
        // missing initializer and the declaration as unterminated.
        if (self.admission != null and self.check(.colon) and self.colonBeforeAssign()) {
            self.errors.addErrorFmt(.unexpected_token, self.current.location(), "expected a type after `:`", .{}, "Write the type after the colon, or remove the colon.");
            self.advance();
        }

        // Parse initializer
        var init_node: NodeIndex = null_node;
        if (self.match(.assign)) {
            init_node = try self.parseExpression(.assignment);
        } else if (kind == .@"const") {
            self.errorAtCurrent("const declarations must have an initializer");
        }

        try self.expectSemicolon();

        const declaration = try self.nodes.addVarDecl(.var_decl, loc, .{
            .binding = binding,
            .init = init_node,
            .kind = kind,
        });
        if (!self.typeSyntaxPublicationHealthy(publication_checkpoint)) return declaration;
        if (annotation_index) |index| {
            try self.type_store.finishAnnotationOwner(index, .{
                .declaration = declaration,
                .declaration_start = loc.offset,
            }, ir.IrView.fromIRStore(&self.nodes, &self.constants));
        }
        retain_type_records = true;
        return declaration;
    }

    fn collectVarDeclarationAdmission(self: *Parser, var_keyword: Token) !bool {
        if (self.admission == null) return false;
        var cursor = type_syntax.Cursor.afterCurrent(self.tokenizer);
        const name = cursor.current;
        if (name.type != .identifier) return false;
        cursor.advance();
        const colon = cursor.current;
        const input = try self.collectVariableTypeAdmission(colon) orelse return false;
        try self.recordRecoveryErasure(.{ .start = colon.start, .end = input.admission_end });
        try self.resumeAfterRawErasureObserved(input.admission_end, var_keyword);
        return true;
    }

    fn collectVariableTypeAdmission(self: *Parser, colon: Token) !?type_syntax.AdmittedTypeInput {
        if (self.admission == null or colon.type != .colon) return null;
        const after_colon = std.math.add(u32, colon.start, colon.len) catch
            return error.InvalidAdmissionSpan;
        if (@as(usize, after_colon) > self.source.len) return error.InvalidAdmissionSpan;
        if (!self.hasAdmissionTypeStart(after_colon)) return null;
        self.admission_presentation = try self.admission_presentation.trackedWhitespaceAt(after_colon);
        var admission_end = after_colon;
        try self.collectTypeAdmission(
            after_colon,
            .{ .general = .variable },
            .general_type,
            .propagate,
            &admission_end,
        );
        return try self.admittedTypeInput(after_colon, admission_end, true);
    }

    fn parseVariableType(self: *Parser, binding: BindingRef, binding_token: Token) !u32 {
        if (self.admission != null) {
            return self.parseAdmittedVariableType(binding, binding_token);
        }
        const annotation_index = std.math.cast(u32, self.type_store.annotations.items.len) orelse
            return error.TooManyTypeItems;
        try self.collectTypeAdmission(
            self.current.start + self.current.len,
            .{ .general = .variable },
            .general_type,
            .propagate,
            null,
        );
        var cursor = type_syntax.Cursor.afterCurrent(self.tokenizer);
        const outcome = try type_syntax.parseAndStore(
            &self.type_store,
            binding,
            self.source,
            self.current.start + self.current.len,
            &cursor,
        );
        switch (outcome) {
            .parsed => if (self.type_store.annotations.items.len !=
                @as(usize, annotation_index) + 1)
            {
                return error.InvalidTypeRange;
            },
            .excluded => |exclusion| {
                switch (exclusion.reason) {
                    .implementation_budget => self.errorAtCurrent("type syntax exceeds the private parser budget"),
                    .unsupported_syntax, .malformed_syntax => self.errorAtCurrent("type syntax is outside private parser comparison"),
                }
                return error.ParseError;
            },
            .failure => |failure| {
                const tok = switch (failure) {
                    .missing_type => |at| at,
                    .unmatched_parenthesis => |at| at,
                    .nesting_too_deep => |at| at,
                    .unsupported_suffix => |at| at,
                };
                switch (failure) {
                    .nesting_too_deep => self.errors.addErrorAt(
                        .nesting_too_deep,
                        tok,
                        "type syntax nests too deeply; simplify or split it (nesting limit is 512)",
                    ),
                    .unmatched_parenthesis => self.errors.addExpectedError(tok, "')' to close type annotation"),
                    .missing_type => self.errors.addExpectedError(tok, "primitive type annotation"),
                    .unsupported_suffix => self.errors.addExpectedError(tok, "end of primitive type annotation"),
                }
                if (self.errors.outOfMemory()) return error.OutOfMemory;
                return error.ParseError;
            },
        }

        self.tokenizer = cursor.tokenizer;
        self.current = cursor.current;
        self.previous = binding_token;
        if (@import("builtin").mode.runtimeSafety()) self.tokens_advanced +%= cursor.consumed;
        return annotation_index;
    }

    fn parseAdmittedVariableType(self: *Parser, binding: BindingRef, binding_token: Token) !u32 {
        const annotation_index = std.math.cast(u32, self.type_store.annotations.items.len) orelse
            return error.TooManyTypeItems;
        const input = try self.collectVariableTypeAdmission(self.current) orelse
            return error.InvalidAdmissionSpan;
        if (input.raw_span.start == input.raw_span.end) {
            const cursor = type_syntax.Cursor.afterCurrent(self.tokenizer);
            self.errors.addExpectedError(cursor.current, "type annotation");
            if (self.errors.outOfMemory()) return error.OutOfMemory;
            return error.ParseError;
        }
        switch (try type_syntax.parseAdmittedAnnotationAndStore(
            &self.type_store,
            binding,
            input,
        )) {
            .parsed => if (self.type_store.annotations.items.len !=
                @as(usize, annotation_index) + 1)
            {
                return error.InvalidTypeRange;
            },
            .excluded => |exclusion| {
                switch (exclusion.reason) {
                    .implementation_budget => self.errorAtCurrent("type syntax exceeds the private parser budget"),
                    .unsupported_syntax, .malformed_syntax => self.errorAtCurrent("type syntax is outside private parser comparison"),
                }
                return error.ParseError;
            },
        }

        try self.resumeAfterRawErasureObserved(input.admission_end, binding_token);
        return annotation_index;
    }

    fn parseFunctionTypeValue(self: *Parser, previous_token: Token) !type_syntax.TypeValue {
        if (self.admission != null) {
            return self.parseAdmittedFunctionTypeValue(previous_token);
        }
        const colon = self.current;
        try self.collectTypeAdmission(
            colon.start + colon.len,
            .parameter,
            .parameter_type,
            .propagate,
            null,
        );
        var cursor = type_syntax.Cursor.afterCurrent(self.tokenizer);
        const outcome = try type_syntax.parseTypeValueAndStore(
            &self.type_store,
            colon.start + colon.len,
            &cursor,
        );
        const value = switch (outcome) {
            .parsed => |parsed| parsed,
            .excluded => |exclusion| {
                switch (exclusion.reason) {
                    .implementation_budget => self.errorAtCurrent("type syntax exceeds the private parser budget"),
                    .unsupported_syntax, .malformed_syntax => self.errorAtCurrent("type syntax is outside private parser comparison"),
                }
                return error.ParseError;
            },
            .failure => |failure| {
                const tok = switch (failure) {
                    .missing_type => |at| at,
                    .unmatched_parenthesis => |at| at,
                    .nesting_too_deep => |at| at,
                    .unsupported_suffix => |at| at,
                };
                switch (failure) {
                    .nesting_too_deep => self.errors.addErrorAt(
                        .nesting_too_deep,
                        tok,
                        "type syntax nests too deeply; simplify or split it (nesting limit is 512)",
                    ),
                    .unmatched_parenthesis => self.errors.addExpectedError(tok, "')' to close type annotation"),
                    .missing_type => self.errors.addExpectedError(tok, "type annotation"),
                    .unsupported_suffix => self.errors.addExpectedError(tok, "end of type annotation"),
                }
                if (self.errors.outOfMemory()) return error.OutOfMemory;
                return error.ParseError;
            },
        };

        self.tokenizer = cursor.tokenizer;
        self.current = cursor.current;
        self.previous = previous_token;
        if (@import("builtin").mode.runtimeSafety()) self.tokens_advanced +%= cursor.consumed;
        return value;
    }

    fn parseAdmittedFunctionTypeValue(self: *Parser, previous_token: Token) !type_syntax.TypeValue {
        const colon = self.current;
        const after_colon = colon.start + colon.len;
        self.admission_presentation = try self.admission_presentation.trackedWhitespaceAt(after_colon);
        var admission_end = after_colon;
        try self.collectTypeAdmission(
            after_colon,
            .parameter,
            .parameter_type,
            .propagate,
            &admission_end,
        );
        const input = try self.admittedTypeInput(after_colon, admission_end, true);
        if (input.raw_span.start == input.raw_span.end) {
            const cursor = type_syntax.Cursor.afterCurrent(self.tokenizer);
            self.errors.addExpectedError(cursor.current, "type annotation");
            if (self.errors.outOfMemory()) return error.OutOfMemory;
            return error.ParseError;
        }
        const value = switch (try type_syntax.parseAdmittedTypeValueOutcome(
            &self.type_store,
            input,
        )) {
            .parsed => |parsed| parsed,
            .excluded => |exclusion| {
                switch (exclusion.reason) {
                    .implementation_budget => self.errorAtCurrent("type syntax exceeds the private parser budget"),
                    .unsupported_syntax, .malformed_syntax => self.errorAtCurrent("type syntax is outside private parser comparison"),
                }
                return error.ParseError;
            },
        };

        try self.resumeAfterRawErasureObserved(admission_end, previous_token);
        return value;
    }

    fn parseFunctionDeclaration(self: *Parser) anyerror!NodeIndex {
        const type_checkpoint = self.type_store.checkpoint();
        const publication_checkpoint = self.typePublicationCheckpoint();
        var retain_type_records = false;
        defer if (!retain_type_records) self.type_store.rollback(type_checkpoint);

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
        const generic_reservation = try self.tryReserveFunctionGenericOwner(
            name,
            loc.offset + @as(u32, "function".len),
        );
        var pending_owner = generic_reservation.pending_owner;

        // Declare function in current scope (hoisted)
        const binding = self.scopes.declareBinding(
            name.text(self.source),
            name_atom,
            .function,
            false,
        ) catch |err| {
            if (self.admission != null) switch (err) {
                error.OutOfMemory => return err,
                else => {},
            };
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
        const parsed_body = try self.parseFunctionBody(
            name_atom,
            flags,
            generic_reservation.header_admission,
        );
        const func_node = parsed_body.function_node;
        var pending_signature = parsed_body.pending_signature;
        defer if (pending_signature) |*pending| self.type_store.cancelFunctionSignature(pending);

        // Create function declaration node
        // Note: function declarations use .let for binding (no var support)
        const declaration = try self.nodes.addVarDecl(.function_decl, loc, .{
            .binding = binding,
            .init = func_node,
            .kind = .let,
        });
        if (!self.typeSyntaxPublicationHealthy(publication_checkpoint)) {
            if (pending_owner) |*pending| self.type_store.cancelGenericOwner(pending);
            return declaration;
        }
        const view = ir.IrView.fromIRStore(&self.nodes, &self.constants);
        if (pending_signature != null or pending_owner != null) {
            try self.type_store.validateFunctionDeclarationWrapper(
                func_node,
                declaration,
                view,
            );
        }
        if (pending_signature) |*pending| {
            try self.type_store.finishFunctionSignature(pending, func_node, view);
        }
        if (pending_owner) |*pending| {
            try self.type_store.finishGenericOwner(pending, .{ .runtime = .{
                .owner = func_node,
                .view = view,
            } });
        }
        retain_type_records = true;
        return declaration;
    }

    const FunctionHeaderAdmission = enum {
        typed,
        runtime_only,
    };

    const FunctionGenericOwnerReservation = struct {
        pending_owner: ?type_syntax.PendingGenericOwner = null,
        header_admission: FunctionHeaderAdmission = .typed,
    };

    const FunctionGenericSelection = struct {
        options: ?type_syntax.GenericOwnerOptions = null,
        header_admission: FunctionHeaderAdmission = .typed,
        cursor: ?type_syntax.Cursor = null,
        previous: ?Token = null,
    };

    fn adoptAdmissionCursor(self: *Parser, cursor: type_syntax.Cursor, previous: Token) void {
        self.tokenizer = cursor.tokenizer;
        self.current = cursor.current;
        self.previous = previous;
        if (@import("builtin").mode.runtimeSafety()) self.tokens_advanced +%= cursor.consumed;
    }

    fn tryReserveFunctionGenericOwner(
        self: *Parser,
        name: Token,
        keyword_end: u32,
    ) !FunctionGenericOwnerReservation {
        const selected = try self.selectFunctionGeneric(name, keyword_end);
        const pending = if (selected.options) |options| try self.type_store.reserveGenericOwner(options) else null;
        if (selected.cursor) |cursor| self.adoptAdmissionCursor(cursor, selected.previous.?);
        return .{ .pending_owner = pending, .header_admission = selected.header_admission };
    }

    fn selectFunctionGeneric(
        self: *Parser,
        name: Token,
        keyword_end: u32,
    ) !FunctionGenericSelection {
        if (self.admissionCoveredByRecovery(name.start)) return .{ .header_admission = .runtime_only };
        const spaced_call_list = self.admission != null and
            type_syntax.tokenStartsGenericList(self.source, self.current) and
            name.start + name.len < self.current.start and
            containsOnlyAdmissionWhitespace(self.source, name.start + name.len, self.current.start);
        if (self.admission == null or !type_syntax.tokenStartsGenericList(self.source, self.current) or
            (name.start + name.len != self.current.start and !spaced_call_list))
        {
            if (self.admission != null) {
                const typed_header = self.current.type == .lparen and
                    containsOnlyAdmissionWhitespace(self.source, keyword_end, name.start) and
                    containsOnlyAdmissionWhitespace(self.source, name.start + name.len, self.current.start);
                return .{ .header_admission = if (typed_header) .typed else .runtime_only };
            }
            return .{};
        }
        const name_gap = type_syntax.classifyNamedFunctionGap(self.source, .{
            .start = keyword_end,
            .end = name.start,
        });
        if (name_gap == .forbidden) return .{};
        const named_header = name_gap == .whitespace and !spaced_call_list;

        const cursor_checkpoint = self.cursorCheckpoint();
        var accepted = false;
        var cursor_committed = false;
        defer if (!accepted) {
            if (!cursor_committed) self.restoreCursorCheckpoint(cursor_checkpoint);
        };

        const scanned = blk: {
            var caught: std.ArrayListUnmanaged(type_syntax.AdmissionDiagnostic) = .empty;
            defer caught.deinit(self.type_store.allocator);
            const result = if (spaced_call_list)
                try self.scanAdmissionCallTypeArgumentsStaged(self.current.start, &caught)
            else switch (name_gap) {
                .whitespace => try self.scanAdmissionGenericListStaged(
                    self.current.start,
                    &caught,
                ),
                .block_comment, .line_comment => try self.scanAdmissionCallTypeArgumentsStaged(
                    self.current.start,
                    &caught,
                ),
                .forbidden => unreachable,
            };
            try self.commitAdmissionCaught(caught.items);
            break :blk switch (result) {
                .scanned => |value| value,
                .not_matched, .lexical_nonmatch => return .{},
                .nesting_too_deep => |offset| return try self.refuseAdmissionNesting(offset),
            };
        };
        if (named_header) {
            try self.classifyAdmissionGenericList(scanned.span);
        }

        if (named_header) {
            self.admission_presentation = try self.admission_presentation.trackedWhitespaceAt(scanned.span.end);
        }
        const cursor = committed: {
            if (named_header) {
                try self.resumeAfterRawErasureObserved(scanned.span.end, name);
                cursor_committed = true;
                try self.recordRecoveryErasure(scanned.span);
                try self.recordPrintableRegion(.{ .recorded_generic = .{
                    .start = scanned.span.start + 1,
                    .end = scanned.span.end - 1,
                } });
                break :committed type_syntax.Cursor{
                    .tokenizer = self.tokenizer,
                    .current = self.current,
                    .consumed = 0,
                };
            }
            break :committed self.cursorAfterAdmittedGeneric(scanned.span.end, name);
        };
        const previous = name;
        if (cursor.current.type != .lparen) return .{};
        const opener_gap = type_syntax.classifyNamedFunctionGap(self.source, .{
            .start = scanned.span.end,
            .end = cursor.current.start,
        });
        if (opener_gap == .forbidden) return .{};

        const OwnerReservation = struct {
            policy: type_syntax.GenericOwnerPolicy,
            capture_spans: type_syntax.GenericCaptureSpans,
            header_admission: FunctionHeaderAdmission,
        };
        const reservation: OwnerReservation = if (spaced_call_list) .{
            .policy = .legacy_call,
            .capture_spans = .{
                .actual_erased_span = scanned.span,
                .legacy_recorded_span = .{ .start = scanned.span.start + 1, .end = scanned.span.end - 1 },
            },
            .header_admission = .runtime_only,
        } else switch (name_gap) {
            .whitespace => switch (opener_gap) {
                .whitespace => .{
                    .policy = .callable,
                    .capture_spans = .{
                        .actual_erased_span = scanned.span,
                        .legacy_recorded_span = .{
                            .start = scanned.span.start + 1,
                            .end = scanned.span.end - 1,
                        },
                    },
                    .header_admission = .typed,
                },
                .block_comment, .line_comment => .{
                    .policy = .ignored,
                    .capture_spans = .{
                        .actual_erased_span = scanned.span,
                        .legacy_recorded_span = .{
                            .start = scanned.span.start + 1,
                            .end = scanned.span.end - 1,
                        },
                    },
                    .header_admission = .runtime_only,
                },
                .forbidden => unreachable,
            },
            .block_comment, .line_comment => switch (opener_gap) {
                .whitespace => if (scanned.span.end == cursor.current.start)
                    .{
                        .policy = .legacy_call,
                        .capture_spans = .{
                            .actual_erased_span = scanned.span,
                            .legacy_recorded_span = .{
                                .start = scanned.span.start + 1,
                                .end = scanned.span.end - 1,
                            },
                        },
                        .header_admission = .runtime_only,
                    }
                else
                    return .{},
                .block_comment, .line_comment => return .{},
                .forbidden => unreachable,
            },
            .forbidden => unreachable,
        };

        if (spaced_call_list and scanned.span.end != cursor.current.start) return .{ .header_admission = .runtime_only };

        if (reservation.policy == .legacy_call) {
            try self.classifyAdmissionGenericList(scanned.span);
        }
        const options: type_syntax.GenericOwnerOptions = .{
            .list_span = scanned.span,
            .capture_spans = reservation.capture_spans,
            .policy = reservation.policy,
        };
        try self.recordRecoveryErasure(options.capture_spans.actual_erased_span);
        try self.recordPrintableRegion(.{ .recorded_generic = options.capture_spans.legacy_recorded_span });
        accepted = true;
        return .{
            .options = options,
            .cursor = cursor,
            .previous = previous,
            .header_admission = reservation.header_admission,
        };
    }

    const ArrowGenericOwnerProbe = union(enum) {
        not_generic,
        rejected_call_grammar,
        reserved: type_syntax.PendingGenericOwner,
    };

    const GenericSourceSelection = struct {
        options: type_syntax.GenericOwnerOptions,
        cursor: type_syntax.Cursor,
        previous: Token,
    };

    const ArrowGenericSelection = union(enum) {
        not_generic,
        rejected_call_grammar,
        selected: GenericSourceSelection,
    };

    fn tryReserveArrowGenericOwner(self: *Parser) !ArrowGenericOwnerProbe {
        return switch (try self.selectArrowGeneric()) {
            .not_generic => .not_generic,
            .rejected_call_grammar => .rejected_call_grammar,
            .selected => |selected| blk: {
                const pending = try self.type_store.reserveGenericOwner(selected.options);
                self.adoptAdmissionCursor(selected.cursor, selected.previous);
                break :blk .{ .reserved = pending };
            },
        };
    }

    fn selectArrowGeneric(self: *Parser) !ArrowGenericSelection {
        if (self.admissionCoveredByRecovery(self.current.start)) return .not_generic;
        if (self.admission == null or
            !type_syntax.tokenStartsGenericList(self.source, self.current)) return .not_generic;

        const cursor_checkpoint = self.cursorCheckpoint();
        var accepted = false;
        var cursor_committed = false;
        defer if (!accepted) {
            if (!cursor_committed) self.restoreCursorCheckpoint(cursor_checkpoint);
        };

        const runtime_previous = self.previous;
        const has_dedicated_window = type_syntax.hasDedicatedAssignmentArrowWindow(
            self.source,
            runtime_previous,
            self.current.start,
        );
        const looks_like_comparison = type_syntax.rawLooksLikeComparison(
            self.source,
            self.current.start,
        );
        const use_call_scanner = !has_dedicated_window and looks_like_comparison;
        const scanned = blk: {
            var caught: std.ArrayListUnmanaged(type_syntax.AdmissionDiagnostic) = .empty;
            defer caught.deinit(self.type_store.allocator);
            const result = if (use_call_scanner)
                try self.scanAdmissionCallTypeArgumentsStaged(self.current.start, &caught)
            else
                try self.scanAdmissionGenericListStaged(self.current.start, &caught);
            try self.commitAdmissionCaught(caught.items);
            break :blk switch (result) {
                .scanned => |value| value,
                .not_matched, .lexical_nonmatch => if (use_call_scanner)
                    return .rejected_call_grammar
                else
                    return .not_generic,
                .nesting_too_deep => |offset| return try self.refuseAdmissionNesting(offset),
            };
        };
        try self.classifyAdmissionGenericList(scanned.span);

        const cursor = self.cursorAfterAdmittedGeneric(scanned.span.end, runtime_previous);
        const previous = runtime_previous;
        if (!use_call_scanner and cursor.current.type == .kw_extends and
            containsOnlyAdmissionWhitespace(self.source, scanned.span.end, cursor.current.start))
        {
            self.admission_presentation = try self.admission_presentation.trackedWhitespaceAt(scanned.span.end);
            try self.resumeAfterRawErasureObserved(scanned.span.end, runtime_previous);
            self.last_erased_type_span = .{ .start = scanned.span.start, .end = self.current.start };
            cursor_committed = true;
            try self.recordRecoveryErasure(self.last_erased_type_span.?);
            try self.recordPrintableRegion(.{ .recorded_generic = .{
                .start = scanned.span.start + 1,
                .end = self.current.start - 1,
            } });
            return .not_generic;
        }
        if (cursor.current.type != .lparen) return .not_generic;

        const gap = self.source[@as(usize, scanned.span.end)..@as(usize, cursor.current.start)];
        if (std.mem.trim(u8, gap, " \t\r\n").len != 0) return .not_generic;
        var after_opener = cursor;
        after_opener.advance();
        if (!self.source_only and type_syntax.scanParenthesizedArrowHeader(
            self.source,
            cursor.current.start,
            after_opener,
        ) == null) return .not_generic;

        const dedicated_header = has_dedicated_window and
            std.mem.indexOfScalar(u8, gap, '\r') == null;
        const OwnerReservation = struct {
            policy: type_syntax.GenericOwnerPolicy,
            capture_spans: type_syntax.GenericCaptureSpans,
        };
        const reservation: OwnerReservation = if (has_dedicated_window and
            (!self.source_only or dedicated_header))
            .{ .policy = .callable, .capture_spans = .{
                .actual_erased_span = scanned.span,
                .legacy_recorded_span = .{
                    .start = scanned.span.start + 1,
                    .end = scanned.span.end - 1,
                },
            } }
        else if (looks_like_comparison) blk: {
            if (scanned.span.end != cursor.current.start) {
                return .rejected_call_grammar;
            }
            break :blk .{ .policy = .legacy_call, .capture_spans = .{
                .actual_erased_span = scanned.span,
                .legacy_recorded_span = .{
                    .start = scanned.span.start + 1,
                    .end = scanned.span.end - 1,
                },
            } };
        } else .{ .policy = .callable, .capture_spans = .{
            .actual_erased_span = .{
                .start = scanned.span.start,
                .end = cursor.current.start,
            },
            .legacy_recorded_span = .{
                .start = scanned.span.start + 1,
                .end = cursor.current.start - 1,
            },
        } };
        if (reservation.policy != .legacy_call) {
            self.admission_presentation = try self.admission_presentation.trackedWhitespaceAt(scanned.span.end);
        }
        const options: type_syntax.GenericOwnerOptions = .{
            .list_span = scanned.span,
            .capture_spans = reservation.capture_spans,
            .policy = reservation.policy,
        };
        try self.recordRecoveryErasure(options.capture_spans.actual_erased_span);
        try self.recordPrintableRegion(.{ .recorded_generic = options.capture_spans.legacy_recorded_span });
        accepted = true;
        return .{ .selected = .{ .options = options, .cursor = cursor, .previous = previous } };
    }

    const ErasedPrefixSelection = struct {
        options: type_syntax.ErasedTypePrefixOptions,
        cursor: type_syntax.Cursor,
        previous: Token,
    };

    fn selectErasedTypePrefix(self: *Parser, context: enum { expression, block }) !?ErasedPrefixSelection {
        if (self.admissionCoveredByRecovery(self.current.start)) return null;
        if (self.admission == null or
            !type_syntax.tokenStartsGenericList(self.source, self.current) or
            type_syntax.rawLooksLikeComparison(self.source, self.current.start))
        {
            return null;
        }

        const scanned = switch (try self.scanObservedGenericList(
            self.current.start,
        )) {
            .scanned => |value| value,
            .not_matched, .lexical_nonmatch => return null,
            .nesting_too_deep => |offset| return try self.refuseAdmissionNesting(offset),
        };
        try self.classifyAdmissionGenericList(scanned.span);

        const runtime_previous = self.previous;
        const cursor = self.cursorAfterAdmittedGeneric(scanned.span.end, runtime_previous);
        const previous = runtime_previous;
        if (cursor.current.type != .lbrace and (context == .block or cursor.current.type != .lparen)) {
            return null;
        }
        const gap = self.source[@as(usize, scanned.span.end)..@as(usize, cursor.current.start)];
        if (std.mem.trim(u8, gap, " \t\r\n").len != 0) return null;

        const dedicated = cursor.current.type == .lparen and
            type_syntax.hasDedicatedAssignmentArrowWindow(
                self.source,
                self.previous,
                scanned.span.start,
            );
        const capture_spans: type_syntax.GenericCaptureSpans = if (dedicated)
            .{
                .actual_erased_span = scanned.span,
                .legacy_recorded_span = .{
                    .start = scanned.span.start + 1,
                    .end = scanned.span.end - 1,
                },
            }
        else
            .{
                .actual_erased_span = .{
                    .start = scanned.span.start,
                    .end = cursor.current.start,
                },
                .legacy_recorded_span = .{
                    .start = scanned.span.start + 1,
                    .end = cursor.current.start - 1,
                },
            };
        const policy: type_syntax.ErasedTypePrefixPolicy = if (cursor.current.type == .lparen)
            .legacy_parameter_projection
        else
            .ignored_parameters;

        self.admission_presentation = try self.admission_presentation.trackedWhitespaceAt(scanned.span.end);
        const options: type_syntax.ErasedTypePrefixOptions = .{
            .list_span = scanned.span,
            .capture_spans = capture_spans,
            .policy = policy,
        };
        try self.recordRecoveryErasure(options.capture_spans.actual_erased_span);
        try self.recordPrintableRegion(.{ .recorded_generic = options.capture_spans.legacy_recorded_span });
        return .{ .options = options, .cursor = cursor, .previous = previous };
    }

    fn tryParseErasedExpressionPrefix(self: *Parser) !?NodeIndex {
        const selected = try self.selectErasedTypePrefix(.expression) orelse return null;
        return try self.parseErasedExpressionPrefix(selected);
    }

    fn parseErasedExpressionPrefix(self: *Parser, selected: ErasedPrefixSelection) !NodeIndex {
        const cursor = selected.cursor;
        const previous = selected.previous;
        var pending = try self.type_store.reserveErasedTypePrefix(selected.options);
        errdefer self.type_store.cancelErasedTypePrefix(&pending);

        self.adoptAdmissionCursor(cursor, previous);

        const publication_checkpoint = self.typePublicationCheckpoint();
        const operand_start = self.current.start;
        const expression_node = switch (self.current.type) {
            .lbrace => try self.parseObjectLiteral(),
            .lparen => try self.parseGroupedOrArrowParams(),
            else => unreachable,
        };
        if (!self.typeSyntaxPublicationHealthy(publication_checkpoint)) {
            self.type_store.cancelErasedTypePrefix(&pending);
            return expression_node;
        }
        const expected_closer: TokenType = if (self.source[operand_start] == '{') .rbrace else .rparen;
        if (self.previous.type != expected_closer) return error.InvalidErasedTypePrefix;
        const operand_end = std.math.add(u32, self.previous.start, self.previous.len) catch
            return error.InvalidErasedTypePrefix;
        try self.type_store.finishErasedTypePrefix(&pending, .{
            .owner = .{ .expression = expression_node },
            .operand_span = .{ .start = operand_start, .end = operand_end },
            .view = ir.IrView.fromIRStore(&self.nodes, &self.constants),
        });
        return expression_node;
    }

    fn tryParseErasedBlockPrefix(self: *Parser) !?NodeIndex {
        const selected = try self.selectErasedTypePrefix(.block) orelse return null;
        const cursor = selected.cursor;
        const previous = selected.previous;
        var pending = try self.type_store.reserveErasedTypePrefix(selected.options);
        errdefer self.type_store.cancelErasedTypePrefix(&pending);

        self.adoptAdmissionCursor(cursor, previous);

        const publication_checkpoint = self.typePublicationCheckpoint();
        const operand_start = self.current.start;
        const block_node = try self.parseBlock();
        if (!self.typeSyntaxPublicationHealthy(publication_checkpoint)) {
            self.type_store.cancelErasedTypePrefix(&pending);
            return block_node;
        }
        if (self.previous.type != .rbrace) return error.InvalidErasedTypePrefix;
        const operand_end = std.math.add(u32, self.previous.start, self.previous.len) catch
            return error.InvalidErasedTypePrefix;
        try self.type_store.finishErasedTypePrefix(&pending, .{
            .owner = .{ .block = block_node },
            .operand_span = .{ .start = operand_start, .end = operand_end },
            .view = ir.IrView.fromIRStore(&self.nodes, &self.constants),
        });
        return block_node;
    }

    const ExplicitCallSelection = struct {
        options: type_syntax.ExplicitCallOptions,
        cursor: type_syntax.Cursor,
        previous: Token,
    };

    fn tryReserveExplicitCall(self: *Parser) !?type_syntax.PendingExplicitCall {
        const selected = try self.selectExplicitCall() orelse return null;
        const pending = try self.type_store.reserveExplicitCall(selected.options);
        self.adoptAdmissionCursor(selected.cursor, selected.previous);
        return pending;
    }

    fn selectExplicitCall(self: *Parser) !?ExplicitCallSelection {
        if (self.admissionCoveredByRecovery(self.current.start)) return null;
        if (self.admission == null or
            !type_syntax.tokenStartsGenericList(self.source, self.current) or
            !type_syntax.rawLooksLikeComparison(self.source, self.current.start))
        {
            return null;
        }
        const scanned = switch (try self.scanObservedCallTypeArguments(
            self.current.start,
        )) {
            .scanned => |value| value,
            .not_matched, .lexical_nonmatch => return null,
            .nesting_too_deep => |offset| return try self.refuseAdmissionNesting(offset),
        };
        try self.classifyAdmissionGenericList(scanned.span);

        const cursor_checkpoint = self.cursorCheckpoint();
        var accepted = false;
        defer if (!accepted) {
            self.restoreCursorCheckpoint(cursor_checkpoint);
        };

        const runtime_previous = self.previous;
        const cursor = self.cursorAfterAdmittedGeneric(scanned.span.end, runtime_previous);
        const previous = runtime_previous;
        if (cursor.current.type != .lparen or cursor.current.start != scanned.span.end) return null;
        const options: type_syntax.ExplicitCallOptions = .{
            .list_span = scanned.span,
            .capture_spans = .{
                .actual_erased_span = scanned.span,
                .legacy_recorded_span = .{
                    .start = scanned.span.start + 1,
                    .end = scanned.span.end - 1,
                },
            },
        };
        try self.recordRecoveryErasure(options.capture_spans.actual_erased_span);
        try self.recordPrintableRegion(.{ .recorded_generic = options.capture_spans.legacy_recorded_span });
        accepted = true;
        return .{ .options = options, .cursor = cursor, .previous = previous };
    }

    fn cursorCheckpoint(self: *const Parser) ParserCursorCheckpoint {
        return .{
            .tokenizer = self.tokenizer,
            .current = self.current,
            .previous = self.previous,
            .tokens_advanced = self.tokens_advanced,
            .brace_depth = self.brace_depth,
            .primed = self.primed,
            .last_erased_type_span = self.last_erased_type_span,
            .pending_admission_trivia = self.pending_admission_trivia,
            .admission_in_import = self.admission_in_import,
            .admission_parameter_header = self.admission_parameter_header,
        };
    }

    fn restoreCursorCheckpoint(self: *Parser, checkpoint: ParserCursorCheckpoint) void {
        self.tokenizer = checkpoint.tokenizer;
        self.current = checkpoint.current;
        self.previous = checkpoint.previous;
        self.tokens_advanced = checkpoint.tokens_advanced;
        self.brace_depth = checkpoint.brace_depth;
        self.primed = checkpoint.primed;
        self.last_erased_type_span = checkpoint.last_erased_type_span;
        self.pending_admission_trivia = checkpoint.pending_admission_trivia;
        self.admission_in_import = checkpoint.admission_in_import;
        self.admission_parameter_header = checkpoint.admission_parameter_header;
    }

    fn parseFunctionReturnSyntax(
        self: *Parser,
        kind: HeaderKind,
        previous_token: Token,
        params: []const NodeIndex,
    ) !type_syntax.ReturnSyntax {
        if (self.admission != null) {
            return self.parseAdmittedFunctionReturnSyntax(kind, previous_token, params);
        }
        const colon = self.current;
        try self.collectTypeAdmission(
            colon.start + colon.len,
            .{ .general = switch (kind) {
                .named => .named_return,
                .arrow => .arrow_return,
            } },
            .general_type,
            .propagate,
            null,
        );
        var cursor = type_syntax.Cursor.afterCurrent(self.tokenizer);
        const outcome = try type_syntax.parseFunctionReturnAndStore(
            &self.type_store,
            colon.start + colon.len,
            &cursor,
        );
        var value = switch (outcome) {
            .parsed => |parsed| parsed,
            .excluded => |exclusion| {
                switch (exclusion.reason) {
                    .implementation_budget => self.errorAtCurrent("type syntax exceeds the private parser budget"),
                    .unsupported_syntax, .malformed_syntax => self.errorAtCurrent("type syntax is outside private parser comparison"),
                }
                return error.ParseError;
            },
            .failure => |failure| {
                const tok = switch (failure) {
                    .missing_type => |at| at,
                    .unmatched_parenthesis => |at| at,
                    .nesting_too_deep => |at| at,
                    .unsupported_suffix => |at| at,
                };
                switch (failure) {
                    .nesting_too_deep => self.errors.addErrorAt(
                        .nesting_too_deep,
                        tok,
                        "type syntax nests too deeply; simplify or split it (nesting limit is 512)",
                    ),
                    .unmatched_parenthesis => self.errors.addExpectedError(tok, "')' to close type annotation"),
                    .missing_type => self.errors.addExpectedError(tok, "type annotation"),
                    .unsupported_suffix => self.errors.addExpectedError(tok, "end of type annotation"),
                }
                if (self.errors.outOfMemory()) return error.OutOfMemory;
                return error.ParseError;
            },
        };

        switch (value.structure) {
            .value => {},
            .predicate => |*predicate| {
                const target_text = predicate.target_span.text(self.source);
                const view = ir.IrView.fromIRStore(&self.nodes, &self.constants);
                for (params) |pattern| {
                    const tag = view.getTag(pattern) orelse return error.InvalidPredicateTarget;
                    if (tag != .pattern_element) return error.InvalidPredicateTarget;
                    const location = view.getLoc(pattern) orelse return error.InvalidPredicateTarget;
                    const start: usize = location.offset;
                    if (start >= self.source.len or !isAsciiIdentifierStart(self.source[start])) {
                        return error.InvalidPredicateTarget;
                    }
                    var end = start + 1;
                    while (end < self.source.len and isAsciiIdentifierContinue(self.source[end])) end += 1;
                    if (!std.mem.eql(u8, self.source[start..end], target_text)) continue;
                    const binding = view.paramBinding(pattern) orelse return error.InvalidPredicateTarget;
                    predicate.target = .{ .resolved = .{
                        .pattern = pattern,
                        .binding = binding,
                    } };
                    break;
                }
            },
        }

        self.tokenizer = cursor.tokenizer;
        self.current = cursor.current;
        self.previous = previous_token;
        if (@import("builtin").mode.runtimeSafety()) self.tokens_advanced +%= cursor.consumed;
        return value;
    }

    fn collectAdmissionFunctionReturn(self: *Parser, kind: HeaderKind) !type_syntax.AdmittedTypeInput {
        const colon = self.current;
        const after_colon = colon.start + colon.len;
        var admission_end = after_colon;
        try self.collectTypeAdmission(
            after_colon,
            .{ .general = switch (kind) {
                .named => .named_return,
                .arrow => .arrow_return,
            } },
            .general_type,
            .propagate,
            &admission_end,
        );
        if (kind == .named or self.hasArrowAt(admission_end)) {
            try self.recordRecoveryErasure(.{ .start = colon.start, .end = admission_end });
        }
        return self.admittedTypeInput(after_colon, admission_end, false);
    }

    fn hasArrowAt(self: *const Parser, offset: u32) bool {
        const start: usize = offset;
        return start < self.source.len and self.source.len - start >= 2 and
            self.source[start] == '=' and self.source[start + 1] == '>';
    }

    fn parseAdmittedFunctionReturnSyntax(
        self: *Parser,
        kind: HeaderKind,
        previous_token: Token,
        params: []const NodeIndex,
    ) !type_syntax.ReturnSyntax {
        const input = try self.collectAdmissionFunctionReturn(kind);
        if (input.raw_span.start == input.raw_span.end) {
            const cursor = type_syntax.Cursor.afterCurrent(self.tokenizer);
            self.errors.addExpectedError(cursor.current, "type annotation");
            if (self.errors.outOfMemory()) return error.OutOfMemory;
            return error.ParseError;
        }
        var value = switch (try type_syntax.parseAdmittedFunctionReturnAndStore(
            &self.type_store,
            input,
        )) {
            .parsed => |parsed| parsed,
            .excluded => |exclusion| {
                switch (exclusion.reason) {
                    .implementation_budget => self.errorAtCurrent("type syntax exceeds the private parser budget"),
                    .unsupported_syntax, .malformed_syntax => self.errorAtCurrent("type syntax is outside private parser comparison"),
                }
                return error.ParseError;
            },
            .failure => |failure| {
                const tok = switch (failure) {
                    .missing_type => |at| at,
                    .unmatched_parenthesis => |at| at,
                    .nesting_too_deep => |at| at,
                    .unsupported_suffix => |at| at,
                };
                switch (failure) {
                    .nesting_too_deep => self.errors.addErrorAt(
                        .nesting_too_deep,
                        tok,
                        "type syntax nests too deeply; simplify or split it (nesting limit is 512)",
                    ),
                    .unmatched_parenthesis => self.errors.addExpectedError(tok, "')' to close type annotation"),
                    .missing_type => self.errors.addExpectedError(tok, "type annotation"),
                    .unsupported_suffix => self.errors.addExpectedError(tok, "end of type annotation"),
                }
                if (self.errors.outOfMemory()) return error.OutOfMemory;
                return error.ParseError;
            },
        };
        try self.resolveAdmittedPredicateTarget(&value, params);
        try self.resumeAfterRawErasureObserved(input.admission_end, previous_token);
        return value;
    }

    fn resolveAdmittedPredicateTarget(
        self: *Parser,
        value: *type_syntax.ReturnSyntax,
        params: []const NodeIndex,
    ) !void {
        switch (value.structure) {
            .value => {},
            .predicate => |*predicate| {
                const target_text = predicate.target_span.text(self.source);
                const view = ir.IrView.fromIRStore(&self.nodes, &self.constants);
                for (params) |pattern| {
                    const tag = view.getTag(pattern) orelse return error.InvalidPredicateTarget;
                    if (tag != .pattern_element) return error.InvalidPredicateTarget;
                    const location = view.getLoc(pattern) orelse return error.InvalidPredicateTarget;
                    const start: usize = location.offset;
                    if (start >= self.source.len or !isAsciiIdentifierStart(self.source[start])) {
                        return error.InvalidPredicateTarget;
                    }
                    var end = start + 1;
                    while (end < self.source.len and isAsciiIdentifierContinue(self.source[end])) end += 1;
                    if (!std.mem.eql(u8, self.source[start..end], target_text)) continue;
                    const binding = view.paramBinding(pattern) orelse return error.InvalidPredicateTarget;
                    predicate.target = .{ .resolved = .{
                        .pattern = pattern,
                        .binding = binding,
                    } };
                    break;
                }
            },
        }
    }

    fn recoverAdmissionFunctionExpression(self: *Parser, keyword: Token) !void {
        const checkpoint = self.type_store.checkpoint();
        defer self.type_store.rollback(checkpoint);
        var pending_owner: ?type_syntax.PendingGenericOwner = null;
        defer if (pending_owner) |*owner| self.type_store.cancelGenericOwner(owner);

        const keyword_end = keyword.start + keyword.len;
        if (!containsOnlyAdmissionWhitespace(self.source, keyword_end, self.current.start)) return;
        if (self.current.type == .identifier) {
            const name = self.current;
            self.advance();
            const reservation = try self.tryReserveFunctionGenericOwner(name, keyword_end);
            pending_owner = reservation.pending_owner;
            if (reservation.header_admission != .typed) return;
        } else if (type_syntax.tokenStartsGenericList(self.source, self.current)) {
            const scanned = switch (try self.scanObservedGenericList(self.current.start)) {
                .scanned => |value| value,
                .not_matched, .lexical_nonmatch => return,
                .nesting_too_deep => |offset| return try self.refuseAdmissionNesting(offset),
            };
            try self.classifyAdmissionGenericList(scanned.span);
            self.admission_presentation = try self.admission_presentation.trackedWhitespaceAt(scanned.span.end);
            const previous = self.previous;
            try self.resumeAfterRawErasureObserved(scanned.span.end, previous);
            if (!containsOnlyAdmissionWhitespace(self.source, scanned.span.end, self.current.start)) return;
        }
        if (self.current.type != .lparen) return;

        _ = try self.scopes.pushScope(.function);
        defer self.scopes.popScope();
        const params = self.beginScratchList();
        defer params.deinit();
        var signature = self.type_store.beginFunctionSignature();
        defer self.type_store.cancelFunctionSignature(&signature);
        var flags: FunctionFlags = .{};
        try self.parseParenthesizedFunctionHeader(.named, &flags, params, &signature);
    }

    fn retainAdmissionHeaderFailure(
        self: *Parser,
        err: anyerror,
        errors_before: usize,
        saved: *?AdmissionHeaderFailure,
    ) !void {
        switch (err) {
            error.OutOfMemory => return err,
            else => {},
        }
        if (self.errors.outOfMemory()) return error.OutOfMemory;
        if (self.terminalAdmissionFailure() != null) return err;
        if (self.admission) |collector| if (collector.shouldStop()) return err;
        if (self.shouldPropagateAdmissionError(err)) return err;

        const error_count = self.errors.errorCount();
        if (saved.*) |retained| {
            if (error_count < retained.error_count) {
                return error.InvalidAdmissionErrorCheckpoint;
            }
            self.errors.errors.items.len = retained.error_count;
            return;
        }
        if (error_count <= errors_before) return err;
        saved.* = .{ .first_error = err, .error_count = error_count };
    }

    fn selectAdmissionHeaderFailure(
        self: *Parser,
        err: anyerror,
        saved: ?AdmissionHeaderFailure,
    ) anyerror {
        if (self.admission == null) return err;
        switch (err) {
            error.OutOfMemory => return err,
            else => {},
        }
        if (self.errors.outOfMemory()) return error.OutOfMemory;
        if (self.terminalAdmissionFailure() != null) return err;
        if (self.admission) |collector| if (collector.shouldStop()) return err;
        if (self.shouldPropagateAdmissionError(err)) return err;
        const retained = saved orelse return err;
        if (self.errors.errorCount() < retained.error_count) {
            return error.InvalidAdmissionErrorCheckpoint;
        }
        self.errors.errors.items.len = retained.error_count;
        return retained.first_error;
    }

    fn recoverAdmissionHeaderItem(
        self: *Parser,
        raw_start: u32,
        saved_tokenizer: Tokenizer,
        runtime_previous: Token,
        allow_annotation: bool,
    ) !void {
        var caught: std.ArrayListUnmanaged(type_syntax.AdmissionDiagnostic) = .empty;
        defer caught.deinit(self.type_store.allocator);
        var pos: usize = raw_start;
        var paren_depth: u16 = 0;
        var brace_depth: u16 = 0;
        var bracket_depth: u16 = 0;
        var can_start_annotation = allow_annotation;

        while (pos < self.source.len) {
            const byte = self.source[pos];
            if (byte == '\'' or byte == '"' or byte == '`') {
                switch (try type_syntax.scanAdmissionQuotedRegion(
                    self.type_store.allocator,
                    .{
                        .source = self.source,
                        .start = @intCast(pos),
                        .caught = &caught,
                    },
                )) {
                    .complete => |end| {
                        pos = end;
                        continue;
                    },
                    .terminal => |diagnostic| {
                        try self.commitAdmissionCaught(caught.items);
                        try self.recordFatalAdmission(diagnostic);
                        return error.AdmissionRefused;
                    },
                }
            }

            // The enclosing parameter parenthesis contributes one depth level.
            const total_depth = 1 + @as(u32, paren_depth) +
                @as(u32, brace_depth) + @as(u32, bracket_depth);
            switch (byte) {
                '(', '{', '[' => {
                    if (total_depth >= type_syntax.max_type_depth) {
                        try self.commitAdmissionCaught(caught.items);
                        return try self.refuseAdmissionNesting(@intCast(pos));
                    }
                    switch (byte) {
                        '(' => paren_depth += 1,
                        '{' => brace_depth += 1,
                        '[' => bracket_depth += 1,
                        else => unreachable,
                    }
                },
                ')' => if (paren_depth > 0) {
                    paren_depth -= 1;
                } else {
                    break;
                },
                '}' => if (brace_depth > 0) {
                    brace_depth -= 1;
                },
                ']' => if (bracket_depth > 0) {
                    bracket_depth -= 1;
                },
                '?' => if (can_start_annotation and total_depth == 1) {
                    var colon = pos + 1;
                    while (colon < self.source.len and switch (self.source[colon]) {
                        ' ', '\t', '\r', '\n' => true,
                        else => false,
                    }) colon += 1;
                    if (colon < self.source.len and self.source[colon] == ':') {
                        try self.commitAdmissionCaught(caught.items);
                        caught.clearRetainingCapacity();
                        try self.recordAdmission(.optional_parameter, .{
                            .start = @intCast(pos),
                            .end = @intCast(pos + 1),
                        }, false);
                        self.admission_presentation = try self.admission_presentation.trackedWhitespaceAt(@intCast(pos + 1));
                        pos = colon;
                        continue;
                    }
                },
                ':' => if (can_start_annotation and total_depth == 1) {
                    try self.commitAdmissionCaught(caught.items);
                    caught.clearRetainingCapacity();
                    if (self.hasAdmissionTypeStart(@intCast(pos + 1))) {
                        self.admission_presentation = try self.admission_presentation.trackedWhitespaceAt(@intCast(pos + 1));
                        var end: u32 = @intCast(pos + 1);
                        try self.collectTypeAdmission(
                            @intCast(pos + 1),
                            .parameter,
                            .parameter_type,
                            .propagate,
                            &end,
                        );
                        try self.recordRecoveryErasure(.{ .start = @intCast(pos), .end = end });
                        pos = end;
                        continue;
                    }
                    self.admission_presentation = try self.admission_presentation.declinedParameterColon(@intCast(pos));
                },
                '=' => if (total_depth == 1) {
                    try self.commitAdmissionCaught(caught.items);
                    caught.clearRetainingCapacity();
                    try self.recordAdmission(.default_parameter, .{
                        .start = @intCast(pos),
                        .end = @intCast(pos + 1),
                    }, false);
                    can_start_annotation = false;
                },
                ',' => if (total_depth == 1) break,
                else => {},
            }
            pos += 1;
        }

        try self.commitAdmissionCaught(caught.items);
        self.tokenizer = saved_tokenizer;
        try self.resumeAfterRawErasureObserved(@intCast(pos), runtime_previous);
    }

    fn trackAdmissionReturnPrefix(self: *Parser, enabled: bool) !void {
        if (!enabled or self.admission == null or self.admissionCoveredByRecovery(self.previous.start)) return;
        self.admission_presentation = try self.admission_presentation.trackedWhitespaceAt(self.previous.start + self.previous.len);
        if (self.current.type == .colon) {
            self.admission_presentation = try self.admission_presentation.trackedWhitespaceAt(self.current.start + self.current.len);
        }
    }

    fn parseParenthesizedFunctionHeader(
        self: *Parser,
        kind: HeaderKind,
        flags: *FunctionFlags,
        params: ScratchList,
        pending_signature: ?*type_syntax.PendingFunctionSignature,
    ) !void {
        const saved_parameter_header = self.admission_parameter_header;
        self.admission_parameter_header = self.admission != null and pending_signature != null;
        defer self.admission_parameter_header = saved_parameter_header;
        try self.expect(.lparen, "'('");
        var saved_failure: ?AdmissionHeaderFailure = null;
        if (!self.check(.rparen)) {
            var progress: ProgressGuard = .{};
            while (true) {
                progress.iteration(self);
                const item_checkpoint = self.type_store.checkpoint();
                const errors_before = self.errors.errorCount();
                const flags_before = flags.*;
                if (self.match(.spread)) {
                    self.errors.addErrorAt(.unsupported_feature, self.previous, "rest parameters ('...args') are not supported; accept an explicit array parameter instead");
                    flags.has_rest_param = true;
                }
                if (self.check(.lbrace) or self.check(.lbracket)) {
                    if (self.admission == null or pending_signature == null) {
                        self.errors.addErrorAt(.unsupported_feature, self.current, "destructured parameters are not supported; bind one parameter, then read its members explicitly in the body");
                        return error.ParseError;
                    }
                    const raw_start = self.current.start;
                    const saved_tokenizer = self.tokenizer;
                    const runtime_previous = self.previous;
                    self.errors.addErrorAt(.unsupported_feature, self.current, "destructured parameters are not supported; bind one parameter, then read its members explicitly in the body");
                    try self.retainAdmissionHeaderFailure(
                        error.ParseError,
                        errors_before,
                        &saved_failure,
                    );
                    try self.recoverAdmissionHeaderItem(
                        raw_start,
                        saved_tokenizer,
                        runtime_previous,
                        true,
                    );
                    self.type_store.rollback(item_checkpoint);
                    flags.* = flags_before;
                    if (!self.match(.comma)) break;
                    if (self.check(.rparen)) break;
                    continue;
                }

                const param_name = self.expectIdentifier("parameter name") catch |err| {
                    return self.selectAdmissionHeaderFailure(err, saved_failure);
                };
                const param_atom = try self.addAtom(param_name.text(self.source));
                const param_binding = self.scopes.declareBinding(
                    param_name.text(self.source),
                    param_atom,
                    .parameter,
                    false,
                ) catch |err| switch (kind) {
                    .named => {
                        if (self.admission != null) switch (err) {
                            error.OutOfMemory => return err,
                            else => {},
                        };
                        self.errorAtCurrent("too many parameters");
                        return self.selectAdmissionHeaderFailure(
                            error.TooManyLocals,
                            saved_failure,
                        );
                    },
                    .arrow => return self.selectAdmissionHeaderFailure(
                        self.bindingFailure(err),
                        saved_failure,
                    ),
                };
                if (self.admission != null and pending_signature != null and self.check(.question)) {
                    const question = self.current;
                    var candidate = self.tokenizer;
                    const colon = candidate.next();
                    const gap = self.source[question.start + question.len .. colon.start];
                    if (colon.type == .colon and
                        std.mem.trim(u8, gap, " \t\r\n").len == 0)
                    {
                        try self.recordAdmission(.optional_parameter, .{
                            .start = question.start,
                            .end = question.start + question.len,
                        }, false);
                        self.admission_presentation = try self.admission_presentation.trackedWhitespaceAt(question.start + question.len);
                        self.advance();
                    }
                }
                if (self.admission != null and pending_signature != null and
                    self.check(.colon) and
                    !self.hasAdmissionTypeStart(self.current.start + self.current.len))
                {
                    const colon = self.current;
                    const saved_tokenizer = self.tokenizer;
                    const runtime_previous = self.previous;
                    self.expect(.rparen, "')'") catch |err| {
                        try self.retainAdmissionHeaderFailure(err, errors_before, &saved_failure);
                    };
                    try self.recoverAdmissionHeaderItem(
                        colon.start,
                        saved_tokenizer,
                        runtime_previous,
                        true,
                    );
                    self.type_store.rollback(item_checkpoint);
                    flags.* = flags_before;
                    if (!self.match(.comma)) break;
                    if (self.check(.rparen)) break;
                    continue;
                }
                const parameter_type = if (pending_signature != null and self.check(.colon) and
                    (self.admission == null or
                        self.hasAdmissionTypeStart(self.current.start + self.current.len)))
                    self.parseFunctionTypeValue(param_name) catch |err| {
                        return self.selectAdmissionHeaderFailure(err, saved_failure);
                    }
                else
                    null;
                if (self.check(.assign)) {
                    if (self.admission != null and pending_signature != null) {
                        const assign = self.current;
                        const saved_tokenizer = self.tokenizer;
                        self.advance();
                        try self.recordAdmission(.default_parameter, .{
                            .start = assign.start,
                            .end = assign.start + assign.len,
                        }, false);
                        self.errors.addErrorAt(.unsupported_feature, assign, "default parameters are not supported; accept `T | undefined` and resolve the default at the start of the body");
                        try self.retainAdmissionHeaderFailure(
                            error.ParseError,
                            errors_before,
                            &saved_failure,
                        );
                        try self.recoverAdmissionHeaderItem(
                            assign.start + assign.len,
                            saved_tokenizer,
                            assign,
                            false,
                        );
                        self.type_store.rollback(item_checkpoint);
                        flags.* = flags_before;
                        if (!self.match(.comma)) break;
                        if (self.check(.rparen)) break;
                        continue;
                    } else {
                        self.advance();
                        self.errors.addErrorAt(.unsupported_feature, self.previous, "default parameters are not supported; accept `T | undefined` and resolve the default at the start of the body");
                        return error.ParseError;
                    }
                }
                const param_node = try self.nodes.addPatternElem(.pattern_element, param_name.location(), .{
                    .kind = if (flags.has_rest_param) .rest else .simple,
                    .binding = param_binding,
                    .key = null_node,
                    .key_atom = 0,
                    .default_value = null_node,
                });
                try params.append(param_node);
                if (parameter_type) |value| {
                    try self.type_store.appendParameterAnnotation(pending_signature.?, .{
                        .owner = .{ .pattern = param_node, .binding = param_binding },
                        .value = value,
                    });
                }
                if (flags.has_rest_param) break;
                if (!self.match(.comma)) break;
                if (self.check(.rparen)) break;
            }
        }
        self.expect(.rparen, "')'") catch |err| {
            return self.selectAdmissionHeaderFailure(err, saved_failure);
        };
        try self.trackAdmissionReturnPrefix(pending_signature != null);
        if (pending_signature != null and self.check(.colon) and
            (self.admission == null or
                self.hasAdmissionTypeStart(self.current.start + self.current.len)))
        {
            const value = self.parseFunctionReturnSyntax(kind, self.previous, params.slice()) catch |err| {
                return self.selectAdmissionHeaderFailure(err, saved_failure);
            };
            try self.type_store.setFunctionReturn(pending_signature.?, value);
        }
        if (saved_failure) |retained| {
            if (self.errors.outOfMemory()) return error.OutOfMemory;
            if (self.errors.errorCount() < retained.error_count) {
                return error.InvalidAdmissionErrorCheckpoint;
            }
            self.errors.errors.items.len = retained.error_count;
            return retained.first_error;
        }
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
    fn parseFunctionBody(
        self: *Parser,
        name_atom: u16,
        flags: FunctionFlags,
        header_admission: FunctionHeaderAdmission,
    ) anyerror!ParsedFunctionBody {
        const loc = self.current.location();
        const parameter_opener = self.current.start;
        const signature_publication_checkpoint = self.typePublicationCheckpoint();
        var pending_signature: ?type_syntax.PendingFunctionSignature = if (self.admission != null and
            !self.admissionCoveredByRecovery(self.current.start) and header_admission == .typed)
            self.type_store.beginFunctionSignature()
        else
            null;
        errdefer if (pending_signature) |*pending| self.type_store.cancelFunctionSignature(pending);

        // Enter function scope
        const scope_id = try self.scopes.pushScope(.function);
        const was_in_function = self.in_function;
        self.in_function = true;
        // A loop outside the function is not a target for `break` or
        // `continue` inside it: code generation starts the body with an
        // empty loop stack, so an accepted `break` would be a silent no-op.
        const was_in_loop = self.in_loop;
        self.in_loop = false;

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
            self.in_loop = was_in_loop;
            self.scopes.popScope();
        };

        const params = self.beginScratchList();
        defer params.deinit();

        var param_flags = flags;
        try self.parseParenthesizedFunctionHeader(
            .named,
            &param_flags,
            params,
            if (pending_signature) |*pending| pending else null,
        );
        if (pending_signature) |*pending| {
            try self.type_store.reserveFunctionSignature(pending, .{
                .start = parameter_opener,
                .end = self.current.start,
            });
        }

        // Parse body
        const body = try self.parseBlock();
        if (!self.typeSyntaxPublicationHealthy(signature_publication_checkpoint)) {
            if (pending_signature) |*pending| self.type_store.cancelFunctionSignature(pending);
            pending_signature = null;
        }

        self.in_function = was_in_function;
        self.in_loop = was_in_loop;
        self.scopes.popScope();
        scope_active = false;

        // Create function expression node
        const params_count = try self.checkedU8Count(loc, params.slice().len, "too many function parameters; limit is 255");
        const params_start = if (params.slice().len > 0)
            try self.addNodeList(params.slice())
        else
            null_node;

        const function_node = try self.nodes.addFunction(.function_expr, loc, .{
            .scope_id = scope_id,
            .name_atom = name_atom,
            .params_start = params_start,
            .params_count = params_count,
            .body = body,
            .flags = param_flags,
        });
        const transferred_signature = pending_signature;
        pending_signature = null;
        return .{
            .function_node = function_node,
            .pending_signature = transferred_signature,
        };
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

        return try self.nodes.addIf(loc, .{
            .condition = condition,
            .then_branch = then_branch,
            .else_branch = else_branch,
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
                ) catch |err| return self.bindingFailure(err);

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

                    return try self.nodes.addForIter(.for_of_stmt, loc, .{
                        .is_for_in = false,
                        .binding = binding,
                        .iterable = iterable,
                        .body = body,
                        .is_const = is_const,
                    });
                }

                // Regular for loop with var declaration
                var var_init: NodeIndex = null_node;
                if (self.match(.assign)) {
                    var_init = try self.parseExpression(.assignment);
                }

                init_node = try self.nodes.addVarDecl(.var_decl, name.location(), .{
                    .binding = binding,
                    .init = var_init,
                    .kind = kind,
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
        // With no ASI, a newline after `return` means nothing: `return` binds
        // the next expression wherever it sits, and `return;` is how a value is
        // omitted. Under `allow_asi` the line rule still runs,
        // so M2 can compare what the ASI parse built against the repaired file.
        const stops_here = self.check(.semicolon) or self.check(.rbrace) or self.check(.eof);
        const asi_ends_it = self.allow_asi and self.current.line > self.previous.line;
        if (!stops_here and !asi_ends_it) {
            value = try self.parseExpression(.none);
        }
        try self.expectSemicolon();

        return try self.nodes.addOptValue(.return_stmt, loc, value);
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

        return try self.nodes.addLabelJump(.break_stmt, loc, null);
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

        return try self.nodes.addLabelJump(.continue_stmt, loc, null);
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
        return try self.nodes.addAssert(loc, .{
            .condition = condition,
            .error_expr = error_expr,
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
        // The `default` arm seen so far. Spec 5.5 grammar is
        // `MatchArm+ [DefaultArm]`: nothing may follow it.
        var default_arm: ?Token = null;

        var progress: ProgressGuard = .{};
        while (!self.check(.rbrace) and !self.check(.eof)) {
            progress.iteration(self);
            if (default_arm) |seen| {
                if (self.check(.kw_when)) {
                    self.errors.addErrorAt(.misplaced_default_arm, seen, "a `default` arm must be the last arm of a match; move it after the `when` arms");
                    return error.ParseError;
                }
                if (self.check(.kw_default)) {
                    self.errors.addErrorAt(.misplaced_default_arm, self.current, "a match has at most one `default` arm; remove this one or merge it into the first");
                    return error.ParseError;
                }
            }
            const arm_loc = self.current.location();
            var pattern: NodeIndex = null_node;

            // One scope per arm, opened before the pattern so a binding it
            // declares is live for this arm's body and dead for the next one.
            _ = try self.scopes.pushScope(.block);
            errdefer self.scopes.popScope();

            if (self.match(.kw_when)) {
                if (self.check(.identifier) and std.mem.eql(u8, self.current.text(self.source), "_")) {
                    self.errors.addErrorAt(.unsupported_feature, self.current, "`when _:` is not supported; write `default:`");
                    self.advance();
                    return error.ParseError;
                }
                pattern = try self.parseMatchPattern(false);
            } else if (self.check(.kw_default)) {
                // default arm - pattern stays null_node
                default_arm = self.current;
                self.advance();
            } else {
                self.scopes.popScope();
                self.errorAtCurrent("expected 'when' or 'default'");
                break;
            }
            try self.expect(.colon, "':'");

            const body = try self.parseExpression(.none);
            self.scopes.popScope();

            const arm_node = try self.nodes.addMatchArm(arm_loc, .{
                .pattern = pattern,
                .body = body,
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

        return try self.nodes.addMatch(loc, .{
            .discriminant = discriminant,
            .arms_start = arms_start,
            .arms_count = arms_len,
        });
    }

    /// `nested` is true below the arm's top-level pattern. A type test reads the
    /// scrutinee, so it exists only at the top level (spec 5.5).
    fn parseMatchPattern(self: *Parser, nested: bool) anyerror!NodeIndex {
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
            if (typeTestKindFor(text)) |kind| {
                if (nested) return self.refuseNestedTypeTest(text);
                return self.parseTypeTestPattern(kind);
            }
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

    /// Refuse a type-test name below the top level of a pattern. In a renamed
    /// field (`{ v: string }`) it is a binding named `string`, which matches
    /// every value; in an array element it would test the whole scrutinee. Only
    /// a shorthand binding (`{ string }`) is a variable of that name on purpose.
    fn refuseNestedTypeTest(self: *Parser, name: []const u8) anyerror {
        // The suggestion follows the "; " that json_diagnostics splits on. The
        // message is static, so one is built per name.
        inline for (.{ "boolean", "number", "string", "array", "Dict", "Bytes" }) |type_test| {
            if (std.mem.eql(u8, name, type_test)) {
                self.errors.addErrorAt(.unsupported_feature, self.current, "`" ++ type_test ++ "` below the top level of a pattern is not a type test; nested type tests are not supported, so bind the field and match it in a nested `match`, or use a top-level type test (`when " ++ type_test ++ ":`)");
                return error.ParseError;
            }
        }
        self.errors.addErrorAt(.unsupported_feature, self.current, "a type-test name below the top level of a pattern is not a type test; nested type tests are not supported, so bind the field and match it in a nested `match`, or use a top-level type test");
        return error.ParseError;
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

        return try self.nodes.addMatchTypeTest(loc, .{ .kind = kind, .predicate = predicate });
    }

    fn buildTypeofTest(self: *Parser, loc: SourceLocation, scrutinee: NodeIndex, name: []const u8) anyerror!NodeIndex {
        const typeof_node = try self.nodes.addUnary(loc, .{ .op = .typeof_op, .operand = scrutinee });
        const str_idx = try self.constants.addString(name);
        const literal = try self.nodes.addString(loc, str_idx);
        return try self.nodes.addBinary(loc, .{ .op = .strict_eq, .left = typeof_node, .right = literal });
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
        const callee = try self.nodes.addIdentifier(loc, binding);
        const args_start = try self.addNodeList(&[_]NodeIndex{scrutinee});
        return try self.nodes.addCall(.call, loc, .{
            .callee = callee,
            .args_start = args_start,
            .args_count = 1,
        });
    }

    fn buildIsArrayCall(self: *Parser, loc: SourceLocation, scrutinee: NodeIndex) anyerror!NodeIndex {
        const array_atom = try self.addAtom("Array");
        const array_binding = try self.scopes.resolveBinding("Array", array_atom);
        const array_ref = try self.nodes.addIdentifier(loc, array_binding);
        const method_atom = try self.addAtom("isArray");
        const callee = try self.nodes.addMember(.member_access, loc, .{
            .object = array_ref,
            .property = method_atom,
            .computed = null_node,
            .is_optional = false,
        });
        const args_start = try self.addNodeList(&[_]NodeIndex{scrutinee});
        return try self.nodes.addCall(.call, loc, .{
            .callee = callee,
            .args_start = args_start,
            .args_count = 1,
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
        ) catch |err| return self.bindingFailure(err);
        return try self.nodes.addIdentifier(loc, binding);
    }

    fn parseMatchObjectPattern(self: *Parser) anyerror!NodeIndex {
        const loc = self.current.location();
        self.advance(); // consume '{'

        var props: [255]NodeIndex = undefined;
        var props_len: u8 = 0;

        var progress: ProgressGuard = .{};
        while (!self.check(.rbrace) and !self.check(.eof)) {
            progress.iteration(self);
            const prop_loc = self.current.location();

            var key_name: []const u8 = "";
            const key = switch (self.current.type) {
                .identifier => blk: {
                    const text = self.current.text(self.source);
                    key_name = text;
                    const str_idx = try self.constants.addString(text);
                    self.advance();
                    break :blk try self.nodes.addString(prop_loc, str_idx);
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
                        if (typeTestKindFor(text) != null) return self.refuseNestedTypeTest(text);
                        const name_loc = self.current.location();
                        self.advance();
                        break :blk try self.declarePatternBinding(text, name_loc);
                    }
                }
                break :blk try self.parseMatchPattern(true);
            };

            const prop_node = try self.nodes.addProperty(prop_loc, .{
                .key = key,
                .value = value,
                .is_shorthand = shorthand,
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

        return try self.nodes.addMatchPattern(loc, .{
            .props_start = props_start,
            .props_count = props_len,
        });
    }

    fn parseMatchArrayPattern(self: *Parser) anyerror!NodeIndex {
        const loc = self.current.location();
        self.advance(); // consume '['

        const elements = self.beginScratchList();
        defer elements.deinit();

        var progress: ProgressGuard = .{};
        while (!self.check(.rbracket) and !self.check(.eof)) {
            progress.iteration(self);
            if (self.check(.comma)) {
                try elements.append(null_node);
                self.advance();
                continue;
            }

            const elem = try self.parseMatchPattern(true);
            try elements.append(elem);

            if (!self.match(.comma)) break;
        }

        try self.expect(.rbracket, "']'");

        const elements_count = try self.checkedU16Count(loc, elements.slice().len, "too many array pattern elements; limit is 65535");
        const elements_start = try self.addNodeList(elements.slice());
        return try self.nodes.addArray(.array_pattern, loc, .{
            .elements_start = elements_start,
            .elements_count = elements_count,
            .has_spread = false,
        });
    }

    /// Statement recovery skips a statement that failed to parse. That is safe
    /// only when the failure recorded a diagnostic, because the recorded error is
    /// what fails the parse at the end. An out-of-memory error, a constant pool
    /// past its u16 address space, or any other error that recorded nothing
    /// would let recovery drop the statement and accept a program with part of
    /// the source gone.
    fn recordUnreportedStatementError(self: *Parser, err: anyerror) anyerror!void {
        if (err == error.OutOfMemory) return err;
        if (err == error.TooManyConstants) {
            // The error passes through block recovery and then program
            // recovery; report it once.
            for (self.errors.getErrors()) |recorded| {
                if (recorded.kind == .too_many_constants) return err;
            }
            self.errors.addErrorAt(.too_many_constants, self.current, "the program has more than 65536 distinct string or number constants");
            return err;
        }
        if (self.errors.outOfMemory()) return error.OutOfMemory;
        switch (err) {
            error.TypeOnlyModuleRefused => return,
            else => {},
        }
        if (!self.errors.hasErrors()) {
            self.errors.addErrorAt(.expected_statement, self.current, "this statement could not be parsed");
        }
    }

    fn parseBlock(self: *Parser) anyerror!NodeIndex {
        const loc = self.current.location();
        try self.expect(.lbrace, "'{'");

        const scope_id = try self.scopes.pushScope(.block);
        var scope_active = true;
        errdefer if (scope_active) self.scopes.popScope();
        // The brace level this block's statements sit at. Recovery returns here.
        const block_depth = self.brace_depth;

        const stmts = self.beginScratchList();
        defer stmts.deinit();

        var progress: ProgressGuard = .{};
        while (true) {
            try self.reachAdmissionBoundary();
            if (self.check(.rbrace)) {
                if (self.admission != null and self.brace_depth > block_depth) {
                    self.advance();
                    continue;
                }
                break;
            }
            if (self.check(.eof)) break;
            progress.iteration(self);
            if (try self.tryConsumeTypeOnlyModule()) continue;
            if (try self.tryConsumeAdmissionDeclaration()) continue;
            if (try self.tryConsumeTypeDeclaration()) continue;
            const failed_statement_start = self.current.location().offset;
            if (self.parseStatement()) |stmt| {
                try stmts.append(stmt);
            } else |err| {
                if (self.shouldPropagateAdmissionError(err)) return err;
                try self.reachAdmissionBoundary();
                try self.recordUnreportedStatementError(err);
                if (self.admission) |collector| if (collector.hasFatal()) {
                    return error.AdmissionRefused;
                };
                const recovery_progress_start = if (self.admission == null)
                    self.current.location().offset
                else
                    failed_statement_start;
                try self.synchronize(block_depth);
                // `synchronize` returns without consuming anything when
                // `previous` is a semicolon or `current` starts a statement, so
                // an error raised at such a token would leave this loop
                // re-parsing it forever. Two error sites already call
                // `advance()` by hand to dodge that; guarantee the progress
                // here instead, so a site that forgets produces a diagnostic
                // rather than a hang.
                //
                // Not when the token is this block's own `}`: the loop ends on
                // it and `expect` consumes it, and skipping it here would end
                // the enclosing block early.
                if (!self.check(.eof) and
                    !self.check(.rbrace) and
                    self.current.location().offset == recovery_progress_start)
                {
                    self.advance();
                }
            }
        }

        try self.expect(.rbrace, "'}'");
        self.scopes.popScope();
        scope_active = false;

        const stmts_count = try self.checkedU16Count(loc, stmts.slice().len, "too many block statements; limit is 65535");
        const stmts_start = if (stmts.slice().len > 0)
            try self.addStmtList(stmts.slice())
        else
            null_node;

        return try self.nodes.addBlock(.block, loc, .{
            .stmts_start = stmts_start,
            .stmts_count = stmts_count,
            .scope_id = scope_id,
        });
    }

    // ============ Module Declaration Parsing ============

    /// Parse import declaration: import { X, Y } from "specifier"
    /// Rejects unsupported declaration forms (side-effect, default, namespace).
    fn parseImportDeclaration(self: *Parser) anyerror!NodeIndex {
        const loc = self.current.location();
        self.advance(); // consume 'import'

        // Collect specifiers
        const specifiers = self.beginScratchList();
        defer specifiers.deinit();

        // Must have { for named imports
        if (!self.check(.lbrace)) {
            // Check for `import "module"` (side-effect import) or `import X from`
            if (self.check(.string_literal)) {
                if (try self.observeCommittedString(self.current)) return error.AdmissionRefused;
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
        var progress: ProgressGuard = .{};
        while (!self.check(.rbrace) and !self.check(.eof)) {
            progress.iteration(self);
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

            const spec_node = try self.nodes.addImportSpec(.import_specifier, spec_loc, .{
                .kind = .named,
                .imported_atom = imported_atom,
                .local_binding = binding,
            });

            try specifiers.append(spec_node);

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
        if (try self.observeCommittedString(module_token)) return error.AdmissionRefused;
        self.advance();

        // Get the string content without quotes
        const raw = module_token.text(self.source);
        const module_str = if (raw.len >= 2) raw[1 .. raw.len - 1] else raw;
        const module_idx = try self.addString(module_str);

        try self.expectSemicolon();

        const specifiers_count = try self.checkedU8Count(loc, specifiers.slice().len, "too many import specifiers; limit is 255");
        const specs_start = if (specifiers.slice().len > 0)
            try self.addNodeList(specifiers.slice())
        else
            null_node;

        return try self.nodes.addImportDecl(loc, .{
            .module_idx = module_idx,
            .specifiers_start = specs_start,
            .specifiers_count = specifiers_count,
        });
    }

    fn collectAdmissionExport(
        self: *Parser,
        keyword: Token,
        origin: type_syntax.AdmissionPresentation,
    ) !?type_syntax.AdmissionKind {
        if (self.admission == null or self.admissionCoveredByRecovery(keyword.start) or
            !self.isAdmissionStatementBoundaryAt(keyword.start) or
            !containsOnlyAdmissionWhitespace(self.source, keyword.start + keyword.len, self.current.start)) return null;
        const kind: type_syntax.AdmissionKind = switch (self.current.type) {
            .kw_default => .default_export,
            .kw_let => .mutable_export,
            else => return null,
        };
        var origin_sink = self.admissionSink().?;
        origin_sink.presentation = origin;
        const diagnostic = try origin_sink.present(.{
            .kind = kind,
            .span = .{ .start = keyword.start, .end = keyword.start + keyword.len },
        });
        var selected = try origin.trackedWhitespaceAt(keyword.start + keyword.len);
        if (kind == .default_export) {
            selected = try selected.trackedWhitespaceAt(self.current.start + self.current.len);
        }
        self.admission_presentation = selected;
        const sink = self.admissionSink().?;
        try sink.recordRecoverable(diagnostic);
        if (sink.shouldStop()) return error.AdmissionRefused;
        try self.recordRecoveryErasure(.{ .start = keyword.start, .end = selected.offset });
        return kind;
    }

    /// Parse export declaration: export function X() {} or export const X = ...
    fn parseExportDeclaration(self: *Parser) anyerror!NodeIndex {
        const type_checkpoint = self.type_store.checkpoint();
        const publication_checkpoint = self.typePublicationCheckpoint();
        var retain_type_records = false;
        defer if (!retain_type_records) self.type_store.rollback(type_checkpoint);

        const keyword = self.current;
        const loc = keyword.location();
        const presentation_origin = self.admission_presentation;
        self.advance(); // consume 'export'
        const admission_export = try self.collectAdmissionExport(keyword, presentation_origin);

        // A public declaration has one spelling and one stable imported name.
        if (self.check(.kw_default)) {
            if (admission_export == .default_export) {
                self.advance();
                return switch (self.current.type) {
                    .kw_function => self.parseFunctionDeclaration(),
                    .kw_const, .kw_let => self.parseVarDeclaration(),
                    else => self.parseExpressionStatement(),
                };
            }
            self.errors.addErrorAt(.unsupported_feature, self.current, "default exports are not supported; write a named export, for example `export function handler(...) { ... }`");
            self.advance();
            return error.ParseError;
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
            const export_node = try self.nodes.addExportDecl(.export_decl, loc, .{
                .kind = .named,
                .declaration = decl,
                .specifiers_start = null_node,
                .specifiers_count = 0,
                .from_module_idx = 0,
            });
            retain_type_records = self.typeSyntaxPublicationHealthy(publication_checkpoint);
            return export_node;
        }

        if (self.check(.kw_let)) {
            if (admission_export == .mutable_export) return self.parseVarDeclaration();
            self.errors.addErrorAt(.unsupported_feature, self.current, "mutable exports are not supported; use `export const` for module values and keep reassignment inside a function activation");
            self.advance();
            return error.ParseError;
        }

        // export const X = ...
        if (self.check(.kw_const)) {
            const decl = try self.parseVarDeclaration();
            const export_node = try self.nodes.addExportDecl(.export_decl, loc, .{
                .kind = .named,
                .declaration = decl,
                .specifiers_start = null_node,
                .specifiers_count = 0,
                .from_module_idx = 0,
            });
            retain_type_records = self.typeSyntaxPublicationHealthy(publication_checkpoint);
            return export_node;
        }

        self.errorAt(loc, "'export' must be followed by 'function', 'const', or 'let'");
        return error.ParseError;
    }

    fn parseExpressionStatement(self: *Parser) anyerror!NodeIndex {
        const loc = self.current.location();
        const expr = try self.parseExpression(.none);
        try self.expectSemicolon();
        return try self.nodes.addOptValue(.expr_stmt, loc, expr);
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
        const type_checkpoint = self.type_store.checkpoint();
        const publication_checkpoint = self.typePublicationCheckpoint();
        errdefer self.type_store.rollback(type_checkpoint);
        defer if (!self.typeSyntaxPublicationHealthy(publication_checkpoint)) {
            self.type_store.rollback(type_checkpoint);
        };
        self.recursion_depth += 1;
        defer self.recursion_depth -= 1;
        if (self.recursion_depth > self.recursionLimit()) {
            self.errors.addErrorAt(.nesting_too_deep, self.current, "expression nests too deeply; simplify or split it (nesting limit is 512)");
            return error.ParseError;
        }

        const parent_chain_depth = self.expression_chain_depth;
        const has_parent_expression = self.expression_frames > 0;
        self.expression_frames += 1;
        self.expression_chain_depth = 0;
        defer {
            self.expression_frames -= 1;
            self.expression_chain_depth = if (has_parent_expression)
                @max(parent_chain_depth, self.expression_chain_depth)
            else
                0;
        }

        switch (try self.tryReserveArrowGenericOwner()) {
            .not_generic => {},
            .rejected_call_grammar => return self.parsePrefixExpr(),
            .reserved => |pending_value| {
                var pending = pending_value;
                return self.parseArrowFunction(&pending);
            },
        }

        // Check for arrow function
        if (self.isArrowFunction()) {
            return self.parseArrowFunction(null);
        }

        var left = if (try self.tryParseErasedExpressionPrefix()) |prefix_node|
            prefix_node
        else
            try self.parsePrefixExpr();

        // Pratt parsing builds left-deep trees without increasing
        // recursion_depth. Bound those trees before later AST walkers recurse
        // through one frame per binary, call, or member node.
        var chain_depth = self.expression_chain_depth;
        var progress: ProgressGuard = .{};
        while (true) {
            progress.iteration(self);
            if (try self.tryConsumeAdmissionAssertion()) continue;
            var pending_call: ?type_syntax.PendingExplicitCall = null;
            var prec = self.getInfixPrecedence(self.current.type);
            if (type_syntax.tokenStartsGenericList(self.source, self.current) and
                @backingInt(Precedence.call) > @backingInt(min_prec))
            {
                pending_call = try self.tryReserveExplicitCall();
                if (pending_call != null) prec = .call;
            }
            if (@backingInt(prec) <= @backingInt(min_prec)) break;

            if (@max(chain_depth, self.expression_chain_depth) >= self.recursionLimit()) {
                if (pending_call) |*pending| self.type_store.cancelExplicitCall(pending);
                self.errors.addErrorAt(.nesting_too_deep, self.current, "expression chain nests too deeply; simplify or split it (nesting limit is 512)");
                return error.ParseError;
            }
            if (pending_call) |*pending| {
                const loc = self.current.location();
                self.advance();
                left = try self.parseCallArgs(left, loc, pending);
            } else {
                left = try self.parseInfixExpr(left, prec);
            }
            chain_depth = @max(chain_depth, self.expression_chain_depth) + 1;
            if (chain_depth > self.recursionLimit()) {
                self.errors.addErrorAt(.nesting_too_deep, self.previous, "expression chain nests too deeply; simplify or split it (nesting limit is 512)");
                return error.ParseError;
            }
            self.expression_chain_depth = chain_depth;
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
                const keyword = self.current;
                self.errors.addErrorAt(.unsupported_feature, self.current, "function expressions are not supported; use arrow functions '(x) => x * 2' or function declarations 'function name() { }' instead");
                const retained: AdmissionHeaderFailure = .{
                    .first_error = error.ParseError,
                    .error_count = self.errors.errorCount(),
                };
                self.advance();
                if (self.admission != null) {
                    self.recoverAdmissionFunctionExpression(keyword) catch |err| {
                        return self.selectAdmissionHeaderFailure(err, retained);
                    };
                    return self.selectAdmissionHeaderFailure(error.ParseError, retained);
                }
                return error.ParseError;
            },
            // class keyword in expression context: const X = class { }
            // Catches class expressions after TypeScript preparation.
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
            .kw_void => {
                self.errors.addErrorAt(.unsupported_feature, self.current, "unary `void` is not supported; evaluate the operand as a statement when its effects are required, then use `undefined` explicitly");
                self.advance();
                return error.ParseError;
            },
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
            .plus => {
                self.errors.addErrorAt(.unsupported_feature, self.current, "unary `+` is not supported; remove it from a number expression, or use an admitted boundary parser for text");
                return error.ParseError;
            },
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

            // A leading `<` is never a core expression.
            .lt => {
                self.errorAtCurrent("raw JSX is not supported; use ordinary TypeScript expressions");
                return error.UnexpectedToken;
            },

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
                if (self.expression_profile) {
                    self.advance();
                    const right = try self.parseExpression(prec);
                    return try self.nodes.addBinary(loc, .{ .op = .loose_eq, .left = left, .right = right });
                }
                self.errors.addErrorAt(.unsupported_feature, self.current, "'==' is not supported; use '===' for strict equality instead");
                return error.ParseError;
            },
            .ne => {
                if (self.expression_profile) {
                    self.advance();
                    const right = try self.parseExpression(prec);
                    return try self.nodes.addBinary(loc, .{ .op = .loose_neq, .left = left, .right = right });
                }
                self.errors.addErrorAt(.unsupported_feature, self.current, "'!=' is not supported; use '!==' for strict inequality instead");
                return error.ParseError;
            },

            .kw_in => {
                self.errors.addErrorAt(.unsupported_feature, op_tok, "`in` is not supported; use the explicit predicate for the value kind, such as `dictHas`");
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
            => {
                // In JavaScript, a unary operator on the left of ** is a syntax
                // error (e.g. -3**2 is ambiguous). Require parentheses.
                if (!self.expression_profile and op_tok.type == .star_star and self.nodes.getTag(left) == .unary_op) {
                    self.errors.addErrorAt(.unsupported_feature, op_tok, "unary operator before '**' requires parentheses: (-3)**2 or -(3**2)");
                    return error.ParseError;
                }
                self.advance();
                const right_prec = if (op_tok.type == .star_star)
                    @as(Precedence, @fromBackingInt(@intCast(@backingInt(prec) - 1))) // Right associative
                else
                    prec;
                const right = try self.parseExpression(right_prec);
                return try self.nodes.addBinary(loc, .{ .op = self.tokenToBinaryOp(op_tok.type), .left = left, .right = right });
            },

            // `|>` keeps its precedence row so it is recognized here rather
            // than falling out as an unexpected token wherever the expression
            // happens to end. Recognition-only: the operator is named, the
            // span is the operator's, and no IR is built for it.
            .pipe_gt => {
                self.errors.addErrorAt(.unsupported_feature, op_tok, "'|>' is not supported; write the call directly, as `f(a)` for `a |> f`");
                return error.ParseError;
            },

            // instanceof not supported - use discriminated unions with tag property
            .kw_instanceof => {
                self.errors.addErrorAt(.unsupported_feature, self.current, "'instanceof' is not supported; use discriminated unions with tag property instead");
                return error.ParseError;
            },

            // Simple assignment only
            .assign => {
                self.advance();
                const right = try self.parseExpression(@fromBackingInt(@intCast(@backingInt(prec) - 1)));
                return try self.nodes.addAssignment(loc, .{
                    .target = left,
                    .value = right,
                    .op = null,
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
                const right = try self.parseExpression(@fromBackingInt(@intCast(@backingInt(prec) - 1)));
                return try self.nodes.addAssignment(loc, .{
                    .target = left,
                    .value = right,
                    .op = binary_op,
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
                return try self.nodes.addTernary(loc, .{
                    .condition = left,
                    .then_branch = then_expr,
                    .else_branch = else_expr,
                });
            },

            // Member access
            .dot => {
                self.advance();
                const prop = try self.expectPropertyIdentifier("property name");
                const prop_name = prop.text(self.source);

                // Check for removed Object methods
                if (self.nodes.getTag(left) == .identifier) {
                    const binding = self.nodes.getBinding(left);
                    // Check if it's the builtin Object global (undeclared)
                    if (binding.kind == .undeclared_global and binding.name_atom == @backingInt(object.Atom.Object)) {
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

                const prop_atom = try self.addAtom(prop_name);
                return try self.nodes.addMember(.member_access, loc, .{
                    .object = left,
                    .property = prop_atom,
                    .computed = null_node,
                    .is_optional = false,
                });
            },

            // Computed member access
            .lbracket => {
                self.advance();
                const index = try self.parseExpression(.none);
                try self.expect(.rbracket, "']'");
                return try self.nodes.addMember(.computed_access, loc, .{
                    .object = left,
                    .property = 0,
                    .computed = index,
                    .is_optional = false,
                });
            },

            // Optional chaining
            .question_dot => {
                self.advance();
                if (self.check(.lparen)) {
                    self.errors.addErrorAt(.unsupported_feature, op_tok, "optional calls are not supported; check for `undefined`, then call the function directly");
                    return error.ParseError;
                }
                if (self.check(.lbracket)) {
                    self.errors.addErrorAt(.unsupported_feature, op_tok, "optional computed access is not supported; check for `undefined`, then use indexed access");
                    return error.ParseError;
                }
                const prop = try self.expectPropertyIdentifier("property name");
                const prop_atom = try self.addAtom(prop.text(self.source));
                return try self.nodes.addMember(.optional_chain, loc, .{
                    .object = left,
                    .property = prop_atom,
                    .computed = null_node,
                    .is_optional = true,
                });
            },

            // Function call
            .lparen => {
                self.advance();
                return self.parseCallArgs(left, loc, null);
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

    fn parseCallArgs(
        self: *Parser,
        callee: NodeIndex,
        loc: SourceLocation,
        pending_call: ?*type_syntax.PendingExplicitCall,
    ) anyerror!NodeIndex {
        const publication_checkpoint = self.typePublicationCheckpoint();
        errdefer if (pending_call) |pending| self.type_store.cancelExplicitCall(pending);
        const args = self.beginScratchList();
        defer args.deinit();

        if (!self.check(.rparen)) {
            var progress: ProgressGuard = .{};
            while (true) {
                progress.iteration(self);
                if (self.match(.spread)) {
                    const spread_expr = try self.parseExpression(.assignment);
                    const spread_node = try self.nodes.addOptValue(.spread, loc, spread_expr);
                    try args.append(spread_node);
                } else {
                    const arg = try self.parseExpression(.assignment);
                    try args.append(arg);
                }
                if (!self.match(.comma)) break;
                if (self.check(.rparen)) break;
            }
        }
        try self.expect(.rparen, "')'");

        const args_count = try self.checkedU8Count(loc, args.slice().len, "too many call arguments; limit is 255");
        const args_start = if (args.slice().len > 0)
            try self.addNodeList(args.slice())
        else
            null_node;

        const call = try self.nodes.addCall(.call, loc, .{
            .callee = callee,
            .args_start = args_start,
            .args_count = args_count,
        });
        if (pending_call) |pending| {
            if (!self.typeSyntaxPublicationHealthy(publication_checkpoint)) {
                self.type_store.cancelExplicitCall(pending);
            } else {
                try self.type_store.finishExplicitCall(
                    pending,
                    call,
                    ir.IrView.fromIRStore(&self.nodes, &self.constants),
                );
            }
        }
        return call;
    }

    // ============ Literal Parsing ============

    fn parseNumber(self: *Parser) anyerror!NodeIndex {
        const loc = self.current.location();
        const text = self.current.text(self.source);
        const has_separator = self.current.has_separator;
        self.advance();

        if (self.expression_profile) {
            return self.parseExpressionNumber(loc, text);
        }

        // Numeric separators belong to the internal expression profile only.
        // `std.fmt.parseInt` and `parseFloat` both accept `_`, so without this
        // check `1_000` would quietly become a supported literal here.
        if (has_separator) {
            self.errors.addError(.invalid_number, loc, "numeric separators are not supported; write the digits without '_'");
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
            return try self.nodes.addInt(loc, int_val);
        } else |_| {}

        // Radix literals above i32 and decimal floats: one parser, which refuses
        // rather than reading a failed parse as 0.0.
        return self.parseExpressionNumber(loc, text);
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

    fn parseExpressionNumber(self: *Parser, loc: SourceLocation, text: []const u8) anyerror!NodeIndex {
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
        return try self.nodes.addFloat(loc, float_idx);
    }

    fn parseString(self: *Parser) anyerror!NodeIndex {
        const token = self.current;
        if (try self.observeCommittedString(token)) return error.AdmissionRefused;
        self.advance();

        if (self.expression_profile) return self.addExpressionStringNode(token);

        // Strip quotes
        const loc = token.location();
        const text = token.text(self.source);
        const content = if (text.len >= 2) text[1 .. text.len - 1] else "";
        const str_idx = try self.unescapedStringOrDiagnostic(content, loc, token.has_escape);
        return try self.nodes.addString(loc, str_idx);
    }

    fn addExpressionStringNode(self: *Parser, token: Token) anyerror!NodeIndex {
        const loc = token.location();
        const text = token.text(self.source);
        if (text.len < 2 or text[text.len - 1] != text[0]) {
            self.errors.addError(.unterminated_string, loc, "unterminated string literal");
            return error.UnexpectedToken;
        }

        const str_idx = try self.unescapedStringOrDiagnostic(text[1 .. text.len - 1], loc, token.has_escape);
        return try self.nodes.addString(loc, str_idx);
    }

    fn parseBoolLiteral(self: *Parser, value: bool) anyerror!NodeIndex {
        const loc = self.current.location();
        self.advance();
        return try self.nodes.addBool(loc, value);
    }

    fn parseNullLiteral(self: *Parser) anyerror!NodeIndex {
        const loc = self.current.location();
        self.advance();
        return try self.nodes.addPlain(.lit_null, loc);
    }

    fn parseUndefinedLiteral(self: *Parser) anyerror!NodeIndex {
        const loc = self.current.location();
        self.advance();
        return try self.nodes.addPlain(.lit_undefined, loc);
    }

    fn parseTemplateLiteral(self: *Parser) anyerror!NodeIndex {
        const token = self.current;
        const loc = token.location();

        if (self.current.type == .template_head) {
            self.errors.addErrorAt(.unsupported_feature, self.current, "template interpolation is not supported; build a string array with explicit `String(...)` conversions and call `.join(\"\")`");
            try self.skipAdmissionTemplateCurrent();
            return error.ParseError;
        }

        // A no-substitution template is only a lexical spelling of a string;
        // it does not survive as a distinct core IR node.
        const text = self.current.text(self.source);
        self.advance();
        if (self.expression_profile and (text.len < 2 or text[text.len - 1] != '`')) {
            self.errors.addError(.unterminated_template, loc, "unterminated template literal");
            return error.UnexpectedToken;
        }
        const content = if (text.len >= 2) text[1 .. text.len - 1] else "";
        const str_idx = try self.unescapedStringOrDiagnostic(content, loc, token.has_escape);
        return try self.nodes.addString(loc, str_idx);
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
        return try self.nodes.addIdentifier(loc, binding);
    }

    fn parseUnaryOp(self: *Parser, op: UnaryOp) anyerror!NodeIndex {
        const loc = self.current.location();
        self.advance();
        const operand = try self.parseExpression(.unary);
        return try self.nodes.addUnary(loc, .{ .op = op, .operand = operand });
    }

    fn parseUnaryKeyword(self: *Parser, op: UnaryOp) anyerror!NodeIndex {
        const loc = self.current.location();
        self.advance();
        const operand = try self.parseExpression(.unary);
        return try self.nodes.addUnary(loc, .{ .op = op, .operand = operand });
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
            self.errors.addErrorAt(.unsupported_feature, async_token, "'async' functions are not supported; handlers run synchronously - use 'fetch' from zttp:fetch for outbound I/O");
            return error.ParseError;
        }

        // Just 'async' as identifier
        const name_atom = try self.addAtom("async");
        const binding = try self.scopes.resolveBinding("async", name_atom);
        return try self.nodes.addIdentifier(loc, binding);
    }

    fn parseAwaitExpression(self: *Parser) anyerror!NodeIndex {
        // `await` is unsupported: handlers run synchronously. Reject at parse
        // time rather than executing it as a no-op that yields an empty 200.
        self.errors.addErrorAt(.invalid_await, self.current, "'await' is not supported; handlers run synchronously - use 'fetch' from zttp:fetch for outbound I/O");
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

        const elements = self.beginScratchList();
        defer elements.deinit();
        var has_spread = false;

        if (!self.check(.rbracket)) {
            var progress: ProgressGuard = .{};
            while (true) {
                progress.iteration(self);
                if (self.check(.comma)) {
                    self.errors.addErrorAt(.unsupported_feature, self.current, "array elisions are not supported; use explicit undefined values instead");
                    return error.ParseError;
                } else if (self.match(.spread)) {
                    has_spread = true;
                    const spread_expr = try self.parseExpression(.assignment);
                    const spread_node = try self.nodes.addOptValue(.spread, loc, spread_expr);
                    try elements.append(spread_node);
                } else {
                    const elem = try self.parseExpression(.assignment);
                    try elements.append(elem);
                }
                if (!self.match(.comma)) break;
                if (self.check(.rbracket)) break;
            }
        }
        try self.expect(.rbracket, "']'");

        const elements_count = try self.checkedU16Count(loc, elements.slice().len, "too many array elements; limit is 65535");
        const elements_start = if (elements.slice().len > 0)
            try self.addNodeList(elements.slice())
        else
            null_node;

        return try self.nodes.addArray(.array_literal, loc, .{
            .elements_start = elements_start,
            .elements_count = elements_count,
            .has_spread = has_spread,
        });
    }

    fn parseObjectLiteral(self: *Parser) anyerror!NodeIndex {
        const loc = self.current.location();
        self.advance(); // consume '{'

        const properties = self.beginScratchList();
        defer properties.deinit();

        if (!self.check(.rbrace)) {
            var progress: ProgressGuard = .{};
            while (true) {
                progress.iteration(self);
                const prop_loc = self.current.location();

                // Check for spread
                if (self.match(.spread)) {
                    const spread_expr = try self.parseExpression(.assignment);
                    const spread_node = try self.nodes.addOptValue(.object_spread, prop_loc, spread_expr);
                    try properties.append(spread_node);
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

                    if (self.check(.lbracket)) {
                        self.errors.addErrorAt(.unsupported_feature, self.current, "computed record keys are not supported; use a literal field name, or `Dict` for dynamic keys");
                        return error.ParseError;
                    } else if (self.check(.identifier)) {
                        const key = self.current;
                        self.advance();

                        // Check for shorthand { x } or method { x() {} }
                        if (prop_kind == .object_property and
                            !self.check(.colon) and !self.check(.lparen))
                        {
                            self.errors.addErrorAt(.unsupported_feature, key, "object literal shorthand is not supported; write the field and value explicitly, for example `{ value: value }`");
                            return error.ParseError;
                        }

                        const key_idx = try self.addString(key.text(self.source));
                        key_node = try self.nodes.addString(key.location(), key_idx);
                    } else if (self.check(.number)) {
                        // One keyed-collection model: a record has string keys.
                        // A numeric key parses to the same string key, so the
                        // two spellings would be indistinguishable downstream.
                        self.errors.addErrorAt(.unsupported_feature, self.current, "numeric record keys are not supported; use a string key, or an array when the keys are dense indices");
                        return error.ParseError;
                    } else if (self.check(.string_literal)) {
                        const key = self.current;
                        if (try self.observeCommittedString(key)) return error.AdmissionRefused;
                        self.advance();
                        if (self.expression_profile) {
                            key_node = try self.addExpressionStringNode(key);
                        } else {
                            const text = key.text(self.source);
                            const content = if (text.len >= 2) text[1 .. text.len - 1] else text;
                            const key_idx = try self.addString(content);
                            key_node = try self.nodes.addString(key.location(), key_idx);
                        }
                    } else if (self.isKeyword(self.current.type)) {
                        // JavaScript allows reserved keywords as property names
                        // e.g., {class: 'foo', if: 'bar'}
                        const key = self.current;
                        self.advance();
                        const key_idx = try self.addString(key.text(self.source));
                        key_node = try self.nodes.addString(key.location(), key_idx);
                    } else {
                        self.errorAtCurrent("expected property name");
                        break;
                    }

                    // Method shorthand or getter/setter. All three are
                    // rejected: codegen emits only `.object_property` and
                    // `.object_spread`, so a parsed method was silently
                    // dropped from the object it appeared in.
                    if (self.check(.lparen) or prop_kind != .object_property) {
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

                    const prop_node = try self.nodes.addProperty(prop_loc, .{
                        .key = key_node,
                        .value = value,
                        .is_shorthand = false,
                    });
                    try properties.append(prop_node);
                }

                if (!self.match(.comma)) break;
                if (self.check(.rbrace)) break;
            }
        }
        try self.expect(.rbrace, "'}'");

        const properties_count = try self.checkedU16Count(loc, properties.slice().len, "too many object properties; limit is 65535");
        const props_start = if (properties.slice().len > 0)
            try self.addNodeList(properties.slice())
        else
            null_node;

        return try self.nodes.addObject(loc, .{
            .properties_start = props_start,
            .properties_count = properties_count,
        });
    }

    // ============ Arrow Function Detection ============

    fn isArrowFunction(self: *Parser) bool {
        if (self.check(.lparen) and self.admission != null) {
            const cursor = type_syntax.Cursor.afterCurrent(self.tokenizer);
            return type_syntax.scanParenthesizedArrowHeader(
                self.source,
                self.current.start,
                cursor,
            ) != null;
        }
        return self.isRuntimeArrowFunction();
    }

    fn isRuntimeArrowFunction(self: *Parser) bool {
        if (self.check(.identifier)) {
            const state = self.tokenizer.saveState();
            const tok = self.tokenizer.next();
            self.tokenizer.restoreState(state);
            return tok.type == .arrow;
        }
        if (!self.check(.lparen)) return false;
        const state = self.tokenizer.saveState();
        defer self.tokenizer.restoreState(state);
        var depth: u32 = 1;
        var tok = self.tokenizer.next();
        while (tok.type != .eof) {
            if (tok.type == .lparen) depth += 1;
            if (tok.type == .rparen) {
                depth -= 1;
                if (depth == 0) break;
            }
            tok = self.tokenizer.next();
        }
        return self.tokenizer.next().type == .arrow;
    }

    fn parseArrowFunction(
        self: *Parser,
        pending_owner: ?*type_syntax.PendingGenericOwner,
    ) anyerror!NodeIndex {
        const publication_checkpoint = self.typePublicationCheckpoint();
        errdefer if (pending_owner) |pending| self.type_store.cancelGenericOwner(pending);
        const loc = self.current.location();
        var flags = FunctionFlags{ .is_arrow = true };
        const parameter_opener: ?u32 = if (self.check(.lparen)) self.current.start else null;
        var typed_header = self.admission != null and
            !self.admissionCoveredByRecovery(self.current.start) and parameter_opener != null;
        if (typed_header) {
            const generic_span = if (pending_owner) |pending| pending.list_span else null;
            const dedicated = type_syntax.hasDedicatedAssignmentArrowWindow(
                self.source,
                self.previous,
                if (generic_span) |span| span.start else self.current.start,
            ) and (if (generic_span) |span|
                std.mem.indexOfScalar(u8, self.source[span.end..self.current.start], '\r') == null
            else
                true);
            typed_header = try self.observeSourceHeader(if (dedicated) .return_colon else .arrow);
            if (!typed_header and !self.isRuntimeArrowFunction()) {
                if (pending_owner) |pending| {
                    const selected: ErasedPrefixSelection = .{
                        .options = .{
                            .list_span = pending.list_span,
                            .capture_spans = pending.capture_spans,
                            .policy = .legacy_parameter_projection,
                        },
                        .cursor = .{ .tokenizer = self.tokenizer, .current = self.current, .consumed = 0 },
                        .previous = self.previous,
                    };
                    self.type_store.cancelGenericOwner(pending);
                    return self.parseErasedExpressionPrefix(selected);
                }
                return self.parseGroupedOrArrowParams();
            }
        }
        var pending_signature: ?type_syntax.PendingFunctionSignature = if (typed_header)
            self.type_store.beginFunctionSignature()
        else
            null;
        errdefer if (pending_signature) |*pending| self.type_store.cancelFunctionSignature(pending);

        // Enter function scope
        const scope_id = try self.scopes.pushScope(.function);
        const was_in_function = self.in_function;
        self.in_function = true;
        // See parseFunctionBody for why `in_loop` is cleared.
        const was_in_loop = self.in_loop;
        self.in_loop = false;

        // See parseFunctionBody: without this, an error while parsing the
        // parameter list or body leaves the scope stack unbalanced and the
        // recovery path invents follow-on diagnostics.
        var scope_active = true;
        errdefer if (scope_active) {
            self.in_function = was_in_function;
            self.in_loop = was_in_loop;
            self.scopes.popScope();
        };

        // Parse parameters
        const params = self.beginScratchList();
        defer params.deinit();

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
            ) catch |err| return self.bindingFailure(err);

            const param_node = try self.nodes.addPatternElem(.pattern_element, param_name.location(), .{
                .kind = .simple,
                .binding = param_binding,
                .key = null_node,
                .key_atom = 0,
                .default_value = null_node,
            });
            try params.append(param_node);
        } else {
            try self.parseParenthesizedFunctionHeader(
                .arrow,
                &flags,
                params,
                if (pending_signature) |*pending| pending else null,
            );
        }

        try self.expect(.arrow, "'=>'");
        if (pending_signature) |*pending| {
            try self.type_store.reserveFunctionSignature(pending, .{
                .start = parameter_opener.?,
                .end = self.current.start,
            });
        }

        // Parse body
        var body: NodeIndex = undefined;
        if (self.check(.lbrace)) {
            body = try self.parseBlock();
        } else {
            // Expression body
            const expr = try self.parseExpression(.assignment);
            body = try self.nodes.addOptValue(.return_stmt, loc, expr);
        }
        if (!self.typeSyntaxPublicationHealthy(publication_checkpoint)) {
            if (pending_signature) |*pending| self.type_store.cancelFunctionSignature(pending);
            pending_signature = null;
        }

        self.in_function = was_in_function;
        self.in_loop = was_in_loop;
        self.scopes.popScope();
        scope_active = false;

        const params_count = try self.checkedU8Count(loc, params.slice().len, "too many arrow function parameters; limit is 255");
        const params_start = if (params.slice().len > 0)
            try self.addNodeList(params.slice())
        else
            null_node;

        const arrow = try self.nodes.addFunction(.arrow_function, loc, .{
            .scope_id = scope_id,
            .name_atom = 0,
            .params_start = params_start,
            .params_count = params_count,
            .body = body,
            .flags = flags,
        });
        if (pending_signature) |*pending| {
            try self.type_store.finishFunctionSignature(
                pending,
                arrow,
                ir.IrView.fromIRStore(&self.nodes, &self.constants),
            );
        }
        if (pending_owner) |pending| {
            if (!self.typeSyntaxPublicationHealthy(publication_checkpoint)) {
                self.type_store.cancelGenericOwner(pending);
            } else {
                try self.type_store.finishGenericOwner(
                    pending,
                    .{ .runtime = .{
                        .owner = arrow,
                        .view = ir.IrView.fromIRStore(&self.nodes, &self.constants),
                    } },
                );
            }
        }
        return arrow;
    }

    // ============ Utility Functions ============

    fn nextTokenStagingAdmissionTrivia(self: *Parser) Token {
        if (self.admission_recovery_observing) self.tokenizer.can_be_regex = false;
        if (self.admission == null) return self.tokenizer.next();
        self.pending_admission_trivia = null;
        var observation: ?tokenizer_mod.TriviaObservation = null;
        const token_value = self.tokenizer.nextObserved(&observation);
        if (observation) |event| switch (event) {
            .unterminated_comment => |failure| {
                self.pending_admission_trivia = .{
                    .opener = failure.opener,
                    .@"resume" = failure.@"resume",
                };
            },
        };
        return token_value;
    }

    fn commitPendingAdmissionTrivia(self: *Parser) void {
        const failure = self.pending_admission_trivia orelse return;
        self.pending_admission_trivia = null;
        if (self.admission_failure != null) return;
        if (self.admission) |collector| {
            if (collector.shouldStop()) return;
        }
        self.admission_failure = .{ .unterminated_comment = failure };
    }

    fn reachAdmissionBoundary(self: *Parser) !void {
        self.commitPendingAdmissionTrivia();
        if (self.admission_failure) |failure| return switch (failure) {
            .diagnostic => error.AdmissionRefused,
            .unterminated_comment => error.UnterminatedComment,
        };
        if (self.admission) |collector| {
            if (collector.shouldStop()) return error.AdmissionRefused;
        }
    }

    fn resumeAfterRawErasureObserved(
        self: *Parser,
        raw_end: u32,
        runtime_previous: Token,
    ) !void {
        self.tokenizer.resumeAfterRawErasure(raw_end, runtime_previous);
        self.previous = runtime_previous;
        self.current = self.nextTokenStagingAdmissionTrivia();
        if (@import("builtin").mode.runtimeSafety()) self.tokens_advanced +%= 1;
        self.reportNonAscii();
    }

    fn advanceAdmissionPresentation(self: *Parser) void {
        if (self.admission == null or !self.primed or self.admission_parameter_header or
            self.admissionCoveredByRecovery(self.current.start)) return;
        const token = self.current;
        const end = token.start + token.len;
        if (end <= self.admission_presentation.offset) return;
        const tracks_whitespace = switch (token.type) {
            .kw_function => true,
            .identifier => self.previous.type == .kw_function and containsOnlyAdmissionWhitespace(
                self.source,
                self.previous.start + self.previous.len,
                token.start,
            ),
            .assign,
            .plus_assign,
            .minus_assign,
            .star_assign,
            .slash_assign,
            .percent_assign,
            .ampersand_assign,
            .pipe_assign,
            .caret_assign,
            .lt_lt_assign,
            .gt_gt_assign,
            .gt_gt_gt_assign,
            .star_star_assign,
            .ampersand_ampersand_assign,
            .pipe_pipe_assign,
            .question_question_assign,
            .eq,
            .eq_eq,
            .ne,
            .ne_ne,
            .le,
            .ge,
            => true,
            else => false,
        };
        if (tracks_whitespace) {
            self.admission_presentation = self.admission_presentation.trackedWhitespaceAt(end) catch |err|
                @panic(@errorName(err));
        }
    }

    fn advance(self: *Parser) void {
        self.advanceAdmissionPresentation();
        if (@import("builtin").mode.runtimeSafety()) self.tokens_advanced +%= 1;
        if (self.admission != null and !self.admissionCoveredByRecovery(self.current.start)) switch (self.current.type) {
            .kw_import => self.admission_in_import = true,
            .semicolon => if (self.admission_in_import) {
                self.admission_in_import = false;
            },
            else => {},
        };
        if (self.primed) switch (self.current.type) {
            .lbrace => self.brace_depth +|= 1,
            .rbrace => self.brace_depth -|= 1,
            else => {},
        };
        self.commitPendingAdmissionTrivia();
        self.primed = true;
        self.previous = self.current;
        self.current = self.nextTokenStagingAdmissionTrivia();
        self.finishAdmissionRecoveryIfRejoined();
        self.reportNonAscii();
    }

    /// A character that looks like an ASCII one and is not, with the ASCII
    /// spelling the author meant. Characters outside this table are still
    /// refused and named by code point; they just carry no replacement.
    const Lookalike = struct {
        code_point: u21,
        name: []const u8,
        suggestion: []const u8,
    };

    const ascii_lookalikes = [_]Lookalike{
        .{ .code_point = 0x2212, .name = "MINUS SIGN", .suggestion = "write the ASCII hyphen-minus `-`" },
        .{ .code_point = 0x2013, .name = "EN DASH", .suggestion = "write the ASCII hyphen-minus `-`" },
        .{ .code_point = 0x2014, .name = "EM DASH", .suggestion = "write the ASCII hyphen-minus `-`" },
        .{ .code_point = 0x201C, .name = "LEFT DOUBLE QUOTATION MARK", .suggestion = "write the ASCII double quote `\"`" },
        .{ .code_point = 0x201D, .name = "RIGHT DOUBLE QUOTATION MARK", .suggestion = "write the ASCII double quote `\"`" },
        .{ .code_point = 0x2018, .name = "LEFT SINGLE QUOTATION MARK", .suggestion = "write the ASCII apostrophe `'`" },
        .{ .code_point = 0x2019, .name = "RIGHT SINGLE QUOTATION MARK", .suggestion = "write the ASCII apostrophe `'`" },
        .{ .code_point = 0x00A0, .name = "NO-BREAK SPACE", .suggestion = "write an ASCII space" },
        .{ .code_point = 0x3000, .name = "IDEOGRAPHIC SPACE", .suggestion = "write an ASCII space" },
        .{ .code_point = 0xFEFF, .name = "ZERO WIDTH NO-BREAK SPACE (byte order mark)", .suggestion = "delete it; the file needs no byte order mark" },
        .{ .code_point = 0x00D7, .name = "MULTIPLICATION SIGN", .suggestion = "write the ASCII asterisk `*`" },
        .{ .code_point = 0x2026, .name = "HORIZONTAL ELLIPSIS", .suggestion = "write three ASCII dots `...`" },
    };

    fn isAsciiIdentifierStart(byte: u8) bool {
        return std.ascii.isAlphabetic(byte) or byte == '_' or byte == '$';
    }

    fn isAsciiIdentifierContinue(byte: u8) bool {
        return isAsciiIdentifierStart(byte) or std.ascii.isDigit(byte);
    }

    fn containsOnlyAdmissionWhitespace(
        source: []const u8,
        start_offset: u32,
        end_offset: u32,
    ) bool {
        const start: usize = start_offset;
        const end: usize = end_offset;
        if (start > end or end > source.len) return false;
        for (source[start..end]) |byte| switch (byte) {
            ' ', '\t', '\r', '\n' => {},
            else => return false,
        };
        return true;
    }

    fn admittedTypeInput(
        self: *const Parser,
        start_offset: u32,
        admission_end: u32,
        trim_trailing: bool,
    ) !type_syntax.AdmittedTypeInput {
        if (start_offset > admission_end or @as(usize, admission_end) > self.source.len) {
            return error.InvalidTypeSpan;
        }
        var raw_start: usize = start_offset;
        const end: usize = admission_end;
        while (raw_start < end) switch (self.source[raw_start]) {
            ' ', '\t', '\r', '\n' => raw_start += 1,
            else => break,
        };
        var raw_end = end;
        if (trim_trailing) while (raw_end > raw_start) switch (self.source[raw_end - 1]) {
            ' ', '\t', '\r', '\n' => raw_end -= 1,
            else => break,
        };
        return .{
            .raw_span = .{ .start = @intCast(raw_start), .end = @intCast(raw_end) },
            .admission_end = admission_end,
        };
    }

    /// Report the first character above ASCII in an `invalid` token, once.
    ///
    /// The tokenizer hands back one `invalid` token for a whole run of such
    /// bytes and the identifier characters around them. Reporting here rather
    /// than where the token is consumed is what makes the count one: every
    /// consumer of a token goes through this funnel, and the panic mode the
    /// report enters suppresses the parse errors that follow from the same
    /// fault - `const café = 1` reported a const with no initializer and a
    /// missing expression, neither of which named the byte that caused them.
    ///
    /// The span is the one code point, and the text names it: a lookalike gets
    /// its name and the ASCII spelling, a character inside an identifier gets
    /// the identifier rule, and any other character is named without a claim
    /// about identifiers. A character that is not in an identifier (`a − 1`,
    /// a no-break space, a curly quote) must not be described as one.
    fn reportNonAscii(self: *Parser) void {
        if (self.admission_recovery_observing) return;
        if (self.current.type != .invalid) return;
        const text = self.current.text(self.source);
        const first = for (text, 0..) |byte, index| {
            if (byte >= 0x80) break index;
        } else return;

        const sequence_len: usize = std.unicode.utf8ByteSequenceLength(text[first]) catch 0;
        const decoded: ?u21 = decode: {
            if (sequence_len == 0 or first + sequence_len > text.len) break :decode null;
            const view = std.unicode.Utf8View.init(text[first..][0..sequence_len]) catch break :decode null;
            var iterator = view.iterator();
            break :decode iterator.nextCodepoint();
        };

        const width: u32 = if (decoded != null) @intCast(sequence_len) else 1;
        const at: u32 = @intCast(first);
        const loc: SourceLocation = .{
            .line = self.current.line,
            .column = self.current.column + at,
            .offset = self.current.start + at,
            .end_offset = self.current.start + at + width,
        };

        const code_point = decoded orelse {
            self.errors.addErrorFmt(
                .non_ascii_identifier,
                loc,
                "invalid UTF-8 byte 0x{X:0>2}",
                .{text[first]},
                "the file is not valid UTF-8; save it as UTF-8, or remove the byte",
            );
            self.errors.enterPanicMode();
            return;
        };

        for (ascii_lookalikes) |lookalike| {
            if (lookalike.code_point != code_point) continue;
            self.errors.addErrorFmt(
                .non_ascii_identifier,
                loc,
                "U+{X:0>4} {s} is not ASCII",
                .{ code_point, lookalike.name },
                lookalike.suggestion,
            );
            self.errors.enterPanicMode();
            return;
        }

        const after = first + sequence_len;
        const in_identifier = (first > 0 and isAsciiIdentifierStart(text[0]) and
            (isAsciiIdentifierStart(text[first - 1]) or std.ascii.isDigit(text[first - 1]))) or
            (after < text.len and isAsciiIdentifierStart(text[after]));
        if (in_identifier) {
            self.errors.addErrorFmt(
                .non_ascii_identifier,
                loc,
                "U+{X:0>4} is not allowed in an identifier",
                .{code_point},
                "identifiers are ASCII: letters, digits, `_` and `$`; rename it",
            );
        } else {
            self.errors.addErrorFmt(
                .non_ascii_identifier,
                loc,
                "U+{X:0>4} is not an ASCII character",
                .{code_point},
                "source outside strings and comments is ASCII; remove the character, or put it inside a string",
            );
        }
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
        // A statement whose previous token is `}` is a block or a declaration,
        // which section 8 terminates with the brace rather than with a `;`.
        // This arm is not insertion and stays.
        if (self.previous.type == .rbrace) return;
        if (self.check(.rbrace)) {
            if (!self.allow_asi) return self.refuseMissingSemicolon();
            return;
        }
        if (self.check(.eof)) {
            if (!self.allow_asi) return self.refuseMissingSemicolon();
            return;
        }
        // Missing `;` before a newline: refused unless `allow_asi`
        // is on. Spec 5.5 mandates no automatic semicolon insertion.
        if (!self.allow_asi) return self.refuseMissingSemicolon();
    }

    /// Spec 5.5: statement termination is explicit. The diagnostic points at
    /// the token the `;` belongs after, which is where the repair writes it.
    fn refuseMissingSemicolon(self: *Parser) error{MissingSemicolon} {
        self.errors.addError(
            .missing_semicolon,
            self.previous.location(),
            "statement is not terminated; this profile has no automatic semicolon insertion",
        );
        return error.MissingSemicolon;
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
            else => .add,
        };
    }

    fn errorAtCurrent(self: *Parser, message: []const u8) void {
        self.errors.addErrorAt(.unexpected_token, self.current, message);
    }

    /// The error to return when `declareBinding` fails. It fails on an
    /// allocation, or when a scope has no local slot left. The slot failure
    /// must be recorded here: `parse` recovers from an error that recorded
    /// nothing by skipping the statement, which drops it without a trace.
    fn bindingFailure(self: *Parser, err: anyerror) anyerror {
        if (err == error.OutOfMemory) return err;
        self.errorAtCurrent("too many local variables");
        return error.TooManyLocals;
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

    fn finishAdmissionRecoveryIfRejoined(self: *Parser) void {
        if (self.admission_recovery_observing) return;
        const recovery = if (self.admission_recovery) |*active| active else return;
        if (self.current.start != recovery.cursor.current.start or
            self.current.start < recovery.covered_until) return;
        self.admission_presentation = recovery.presentation;
        self.admission_in_import = recovery.cursor.admission_in_import;
        self.admission_parameter_header = recovery.cursor.admission_parameter_header;
        self.last_erased_type_span = recovery.cursor.last_erased_type_span;
        recovery.erasures.deinit(self.type_store.allocator);
        self.admission_recovery = null;
    }

    fn admissionCoveredByRecovery(self: *const Parser, offset: u32) bool {
        const recovery = self.admission_recovery orelse return false;
        return !self.admission_recovery_observing and offset < recovery.covered_until;
    }

    fn beginAdmissionRecovery(self: *Parser) !bool {
        if (self.admission == null or self.current.type != .string_literal or
            self.previous.type != .regex_literal) return false;
        const regex_end = self.previous.start + self.previous.len;
        if (regex_end > self.current.start) return false;
        var caught: std.ArrayListUnmanaged(type_syntax.AdmissionDiagnostic) = .empty;
        defer caught.deinit(self.type_store.allocator);
        var pos = self.previous.start;
        while (pos < regex_end) : (pos += 1) {
            if (self.source[pos] != '\'' and self.source[pos] != '"' and
                self.source[pos] != '`') continue;
            const opener = pos;
            switch (try type_syntax.scanAdmissionQuotedRegion(self.type_store.allocator, .{
                .source = self.source,
                .start = opener,
                .caught = &caught,
            })) {
                .terminal => return false,
                .complete => |end| {
                    if (end != self.current.start + 1) {
                        pos = end - 1;
                        continue;
                    }
                    if (self.source[opener] != self.source[self.current.start]) return false;
                    const runtime_cursor = self.cursorCheckpoint();
                    defer self.restoreCursorCheckpoint(runtime_cursor);
                    self.tokenizer = Tokenizer.init(self.source);
                    self.tokenizer.resumeAfterRawErasure(opener, self.previous);
                    self.tokenizer.can_be_regex = false;
                    self.current = self.nextTokenStagingAdmissionTrivia();
                    self.admission_recovery = .{
                        .cursor = self.cursorCheckpoint(),
                        .presentation = self.admission_presentation,
                        .covered_until = opener,
                        .quoted_region = .{ .start = opener, .end = end },
                    };
                    return true;
                },
            }
        }
        return false;
    }

    fn observeAdmissionRecoveryThrough(self: *Parser, boundary: u32) !void {
        const runtime_cursor = self.cursorCheckpoint();
        const runtime_presentation = self.admission_presentation;
        const store_checkpoint = self.type_store.checkpoint();
        const module_diagnostic_count = self.type_only_module_diagnostics.items.len;
        const module_refusal = self.type_only_module_refusal;
        defer {
            self.type_store.rollback(store_checkpoint);
            self.type_only_module_diagnostics.items.len = module_diagnostic_count;
            self.type_only_module_refusal = module_refusal;
            self.restoreCursorCheckpoint(runtime_cursor);
            self.admission_presentation = runtime_presentation;
            self.admission_recovery_observing = false;
        }
        const saved = self.admission_recovery orelse return error.InvalidAdmissionRecovery;
        self.restoreCursorCheckpoint(saved.cursor);
        self.admission_presentation = saved.presentation;
        self.admission_recovery_observing = true;
        var progress: ProgressGuard = .{};
        while (self.current.start < boundary) {
            try self.reachAdmissionBoundary();
            if (self.current.type == .eof) break;
            progress.iteration(self);
            if (self.current.type == .string_literal) {
                self.admission_recovery.?.quoted_region = .{
                    .start = self.current.start,
                    .end = self.current.start + self.current.len,
                };
                if (try self.observeCommittedString(self.current)) continue;
            }
            if (self.current.type == .template_head) {
                try self.skipAdmissionTemplateCurrent();
                continue;
            }
            if (try self.tryConsumeTypeOnlyModule() or
                try self.tryConsumeTypeDeclaration() or
                try self.tryConsumeAdmissionDeclaration())
            {
                if (self.last_erased_type_span) |span| try self.recordRecoveryErasure(span);
                continue;
            }
            if (try self.tryConsumeAdmissionAssertion()) continue;
            if (self.current.type == .kw_const or self.current.type == .kw_let or
                self.current.type == .kw_var)
            {
                if (try self.collectVarDeclarationAdmission(self.current)) continue;
            }
            if (try self.observeRecoveryExport()) continue;
            if (try self.observeRecoveryFunction()) continue;
            if (try self.observeRecoveryGeneric()) continue;
            self.advance();
        }
        if (self.pending_admission_trivia) |failure| {
            if (failure.opener < boundary) try self.reachAdmissionBoundary();
        }
        const recovery = &self.admission_recovery.?;
        recovery.cursor = self.cursorCheckpoint();
        recovery.presentation = self.admission_presentation;
        recovery.covered_until = if (self.pending_admission_trivia) |failure|
            @min(self.current.start, failure.opener)
        else
            self.current.start;
    }

    fn alignAdmissionRecoveryString(self: *Parser) !bool {
        if (self.admission == null or self.current.type != .string_literal) return false;
        if (self.admission_recovery == null and !try self.beginAdmissionRecovery()) return false;
        var recovery = &self.admission_recovery.?;
        const quoted = recovery.quoted_region;
        if (quoted.end != self.current.start + 1 or quoted.start >= self.current.start) return false;
        while (true) {
            const prior_end = self.current.start + self.current.len;
            try self.observeAdmissionRecoveryThrough(prior_end);
            recovery = &self.admission_recovery.?;
            var first: usize = 0;
            while (first < recovery.erasures.items.len and
                recovery.erasures.items[first].end <= self.current.start) first += 1;
            self.current = try self.tokenizer.rescanRecoveryString(self.current, recovery.erasures.items[first..]);
            self.pending_admission_trivia = null;
            if (self.current.start + self.current.len <= prior_end) break;
        }
        return true;
    }

    fn observeRecoveryExport(self: *Parser) !bool {
        if (self.current.type != .kw_export) return false;
        const keyword = self.current;
        const origin = self.admission_presentation;
        self.advance();
        _ = try self.collectAdmissionExport(keyword, origin);
        if (self.current.type == .kw_default) self.advance();
        return true;
    }

    fn observeRecoveryHeader(self: *Parser, kind: HeaderKind) !void {
        if (self.current.type != .lparen) return error.InvalidAdmissionRecovery;
        const saved_header = self.admission_parameter_header;
        self.admission_parameter_header = true;
        defer self.admission_parameter_header = saved_header;
        var raw_start = self.current.start + self.current.len;
        var item_tokenizer = self.tokenizer;
        self.advance();
        while (true) {
            try self.recoverAdmissionHeaderItem(raw_start, item_tokenizer, self.previous, true);
            if (self.current.type != .comma) break;
            raw_start = self.current.start + self.current.len;
            item_tokenizer = self.tokenizer;
            self.advance();
        }
        if (self.current.type != .rparen) return;
        self.advance();
        try self.trackAdmissionReturnPrefix(true);
        if (self.current.type == .colon and self.hasAdmissionTypeStart(self.current.start + self.current.len)) {
            const input = try self.collectAdmissionFunctionReturn(kind);
            try self.resumeAfterRawErasureObserved(input.admission_end, self.previous);
        }
    }

    fn observeRecoveryFunction(self: *Parser) !bool {
        if (self.current.type == .lparen) {
            const after_opener = type_syntax.Cursor.afterCurrent(self.tokenizer);
            if (type_syntax.scanParenthesizedArrowHeader(self.source, self.current.start, after_opener) == null) return false;
            try self.observeRecoveryHeader(.arrow);
            return true;
        }
        if (self.current.type != .kw_function) return false;
        const keyword = self.current;
        const keyword_end = keyword.start + keyword.len;
        self.advance();
        if (!containsOnlyAdmissionWhitespace(self.source, keyword_end, self.current.start)) return true;
        if (self.current.type == .identifier or
            (self.source_only and type_syntax.tokenIsDeclarationName(self.current, self.source)))
        {
            const name = self.current;
            if (self.source_only) {
                self.admission_presentation = try self.admission_presentation.trackedWhitespaceAt(name.start + name.len);
            }
            self.advance();
            const selected = try self.selectFunctionGeneric(name, keyword_end);
            if (selected.cursor) |cursor| self.adoptAdmissionCursor(cursor, selected.previous.?);
            if (selected.header_admission != .typed) return true;
        } else if (type_syntax.tokenStartsGenericList(self.source, self.current)) {
            const scanned = switch (try self.scanObservedGenericList(self.current.start)) {
                .scanned => |value| value,
                .not_matched, .lexical_nonmatch => return true,
                .nesting_too_deep => |offset| return try self.refuseAdmissionNesting(offset),
            };
            try self.classifyAdmissionGenericList(scanned.span);
            self.admission_presentation = try self.admission_presentation.trackedWhitespaceAt(scanned.span.end);
            try self.recordRecoveryErasure(scanned.span);
            try self.recordPrintableRegion(.{ .recorded_generic = .{
                .start = scanned.span.start + 1,
                .end = scanned.span.end - 1,
            } });
            const previous = self.previous;

            try self.resumeAfterRawErasureObserved(scanned.span.end, previous);
            if (!containsOnlyAdmissionWhitespace(self.source, scanned.span.end, self.current.start)) return true;
        }
        if (self.current.type == .lparen) try self.observeRecoveryHeader(.named);
        return true;
    }

    fn observeRecoveryGeneric(self: *Parser) !bool {
        if (!type_syntax.tokenStartsGenericList(self.source, self.current)) return false;
        const start = self.current.start;
        switch (try self.selectArrowGeneric()) {
            .selected => |selected| {
                const dedicated = self.source_only and
                    type_syntax.hasDedicatedAssignmentArrowWindow(
                        self.source,
                        selected.previous,
                        selected.options.list_span.start,
                    ) and std.mem.indexOfScalar(u8, self.source[selected.options.list_span.end..selected.cursor.current.start], '\r') == null;
                self.adoptAdmissionCursor(selected.cursor, selected.previous);
                if (!self.source_only or try self.observeSourceHeader(if (dedicated) .return_colon else .arrow)) {
                    try self.observeRecoveryHeader(.arrow);
                }
                return true;
            },
            .rejected_call_grammar => return false,
            .not_generic => if (self.current.start != start) return true,
        }
        if (try self.selectErasedTypePrefix(.expression)) |selected| {
            self.adoptAdmissionCursor(selected.cursor, selected.previous);
            return true;
        }
        if (try self.selectExplicitCall()) |selected| {
            self.adoptAdmissionCursor(selected.cursor, selected.previous);
            return true;
        }
        return false;
    }

    /// Skip to the next point where parsing can safely resume, recording no
    /// error on the way. `block_depth` is the brace level of the block whose
    /// statement failed (0 at the top level). A synchronization point is a `;`
    /// or a statement keyword at that level, or the `}` that closes that block,
    /// which is left unconsumed for the block's own loop.
    ///
    /// Braces the failed statement opened are skipped whole. Stopping at a `;`
    /// or a keyword inside them resumed in the middle of a construct that the
    /// failed statement owned (the body of an unsupported `while`, the arms of
    /// a `switch`) and reported the rest of it as new faults: a `return`
    /// "outside of function", an expression "expected" at a `}`. Those follow
    /// from the first fault and name nothing the author can fix separately.
    fn synchronize(self: *Parser, block_depth: u32) !void {
        self.errors.enterPanicMode();
        defer self.errors.exitPanicMode();

        var progress: ProgressGuard = .{};
        while (true) {
            _ = try self.alignAdmissionRecoveryString();
            try self.reachAdmissionBoundary();
            if (self.check(.eof)) break;
            progress.iteration(self);
            const at_level = self.brace_depth <= block_depth;
            if (self.admission != null and self.current.type == .string_literal and
                try self.observeCommittedString(self.current)) return;
            if (self.admission != null and !self.admissionCoveredByRecovery(self.current.start) and self.current.type == .template_head) {
                try self.skipAdmissionTemplateCurrent();
                continue;
            }
            if (try self.tryConsumeAdmissionAssertion()) continue;
            if (at_level and self.previous.type == .semicolon) {
                return;
            }
            if (!at_level and self.admission != null and
                self.isAdmissionRecoveryRestart()) return;

            switch (self.current.type) {
                // At the failed block's level this `}` closes that block.
                // Above it, the `}` closes a brace the failed statement opened.
                .rbrace => if (at_level) {
                    return;
                },
                .kw_class, .kw_function, .kw_var, .kw_let, .kw_const, .kw_for, .kw_if, .kw_while, .kw_return, .kw_try, .kw_enum => if (at_level) {
                    return;
                },
                .kw_import, .kw_export => if (at_level and self.admission != null and
                    self.isTypeDeclarationBoundary()) return,
                .identifier => if (at_level and self.admission != null and
                    self.isAdmissionDeclarationStart()) return,
                else => {},
            }

            self.advance();
        }
    }

    fn isAdmissionDeclarationStart(self: *const Parser) bool {
        if (!self.isTypeDeclarationBoundary() or self.current.type != .identifier) return false;
        const text = self.current.text(self.source);
        if (std.mem.eql(u8, text, "structural") or
            std.mem.eql(u8, text, "nominal") or
            std.mem.eql(u8, text, "interface") or
            std.mem.eql(u8, text, "type")) return true;
        if (!std.mem.eql(u8, text, "distinct")) return false;
        var candidate = self.tokenizer;
        const next = candidate.next();
        return next.type == .identifier and std.mem.eql(u8, next.text(self.source), "type");
    }

    fn isAdmissionRecoveryRestart(self: *const Parser) bool {
        return switch (self.current.type) {
            .kw_var, .kw_let, .kw_const, .kw_function, .kw_import, .kw_export => true,
            .identifier => self.isAdmissionDeclarationStart(),
            else => false,
        };
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

    /// Both string spellings use the same closed decoding table.
    /// Decode a string literal's content, reporting a closed-escape-set
    /// violation as a located diagnostic rather than propagating a bare error.
    /// The two faults are distinct to a reader and carry different repairs, so
    /// they carry different codes.
    fn unescapedStringOrDiagnostic(self: *Parser, content: []const u8, loc: SourceLocation, has_escape: bool) !u16 {
        return self.addUnescapedString(content, has_escape) catch |err| switch (err) {
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

    fn addUnescapedString(self: *Parser, content: []const u8, has_escape: bool) !u16 {
        // Recovery for a lone quote uses a synthetic empty slice. Normalize it
        // to a source slice so borrowing preserves the existing diagnostic.
        if (!has_escape) return self.constants.addSourceString(if (content.len == 0) self.source[0..0] else content);
        // addOwnedString consumes the decoded allocation on success, duplicate,
        // and error. It never makes a second copy of a newly decoded value.
        return self.constants.addOwnedString(try self.unescape(content));
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
    /// `\'`, `\"`, `\0`, `\xNN`, `\uNNNN`, and `\u{N..}`; other escapes are
    /// refused rather than silently changing the value.
    ///
    /// The two profiles use the same closed escape set. A mistyped escape must
    /// not change the string silently, so there is nothing to parameterize.
    ///
    /// Called only for tokens the scanner marked as escaped. The returned
    /// allocation is exact-sized so the constant pool can own and free it.
    fn unescape(self: *Parser, input: []const u8) ![]u8 {
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
                // everyone but the compiler. Both profiles refuse it.
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

        return self.allocator.realloc(result, out_pos);
    }

    fn addAtom(self: *Parser, name: []const u8) !u16 {
        // Check predefined atoms first (e.g., "handler" -> 159)
        if (object.lookupPredefinedAtom(name)) |atom| {
            return @truncate(@backingInt(atom));
        }
        // Intern dynamic atoms if atom table is available
        if (self.atoms) |atoms| {
            const atom = try atoms.intern(name);
            return @truncate(@backingInt(atom));
        }
        // Fall back to string constant pool for dynamic atoms (standalone parser)
        return try self.constants.addString(name);
    }

    // ============ Public API ============
    pub fn hasErrors(self: *const Parser) bool {
        return self.errors.hasErrors();
    }

    pub fn getErrors(self: *const Parser) []const error_mod.ParseError {
        return self.errors.getErrors();
    }

    /// Bound tolerant import observation at the first failed top-level dispatch.
    /// A recovered block remains one complete statement batch.
    pub fn getRetainedImportNodeCount(self: *const Parser) usize {
        return self.first_statement_failure_nodes orelse self.nodes.tags.items.len;
    }

    pub fn getAdmissionDiagnostics(self: *const Parser) []const type_syntax.AdmissionDiagnostic {
        return if (self.admission) |collector| collector.items() else &.{};
    }

    pub fn getAdmissionFailure(self: *const Parser) ?AdmissionFailure {
        return self.terminalAdmissionFailure();
    }

    pub fn getLastAdmissionObservation(self: *const Parser) ?type_syntax.AdmissionDiagnostic {
        return if (self.admission_observations) |observations| observations.last() else null;
    }

    pub fn getProjectedErrors(self: *const Parser) []const error_mod.ParseError {
        const errors = self.errors.getErrors();
        const count = self.admission_error_prefix orelse errors.len;
        return errors[0..@min(count, errors.len)];
    }
};

// ============ Tests ============

test "typed block consumes a declaration without a runtime node" {
    const source =
        "{\n" ++
        "structural Alias = number;\n" ++
        "const value: Alias = 1;\n" ++
        "}";
    var parser = try Parser.initAdmission(std.testing.allocator, std.testing.allocator, source, .compile);
    defer parser.deinit();
    _ = try parser.parse();

    try std.testing.expectEqual(@as(usize, 1), parser.type_store.declarations.items.len);
    try std.testing.expectEqual(@as(u16, 1), parser.type_store.declarations.items[0].authored_scope);
    var variable_count: usize = 0;
    const declaration_offset: u32 = @intCast(std.mem.indexOf(u8, source, "structural").?);
    for (parser.nodes.tags.items, 0..) |tag, index| {
        if (tag == .var_decl) variable_count += 1;
        try std.testing.expect(parser.nodes.getLoc(@intCast(index)).offset != declaration_offset);
    }
    try std.testing.expectEqual(@as(usize, 1), variable_count);
}

fn expectAdmissionKindFromSource(
    source: []const u8,
    expected: type_syntax.AdmissionKind,
    seen: *std.EnumSet(type_syntax.AdmissionKind),
) !void {
    var parser = try Parser.initAdmission(
        std.testing.allocator,
        std.testing.allocator,
        source,
        .collect,
    );
    defer parser.deinit();
    switch (try parser.parseAdmission()) {
        .recovered_admission_refused => {},
        .terminal_admission_refused => |failure| switch (failure) {
            .diagnostic => {},
            .unterminated_comment => return error.TestUnexpectedResult,
        },
        else => return error.TestUnexpectedResult,
    }
    for (parser.getAdmissionDiagnostics()) |diagnostic| {
        seen.insert(diagnostic.kind);
        if (diagnostic.kind == expected) return;
    }
    return error.TestExpectedAdmissionKind;
}

test "admission parser reaches each syntax-owned refusal producer" {
    const cases = [_]struct {
        source: []const u8,
        kind: type_syntax.AdmissionKind,
    }{
        .{ .source = "const value: any = 1;\n", .kind = .any_type },
        .{ .source = "const value = source as string;\n", .kind = .as_assertion },
        .{ .source = "const value = source satisfies string;\n", .kind = .satisfies_assertion },
        .{ .source = "const value = \"open\nconst after = 1;\n", .kind = .unterminated_string },
        .{ .source = "nominal Box = T;\n", .kind = .nominal_base_not_scalar },
        .{ .source = "interface Box { value: string }\n", .kind = .interface_declaration },
        .{ .source = "type Box = string;\n", .kind = .type_alias_declaration },
        .{ .source = "distinct type Box = string;\n", .kind = .distinct_type_declaration },
        .{ .source = "import type { Value } from \"" ++ retired_types_module ++ "\";\n", .kind = .legacy_types_import },
        .{ .source = "function f(value = 1) { return value; }\n", .kind = .default_parameter },
        .{ .source = "function f(value?: string) { return value; }\n", .kind = .optional_parameter },
        .{ .source = "export default 1;\n", .kind = .default_export },
        .{ .source = "export let value = 1;\n", .kind = .mutable_export },
        .{ .source = "structural Box = Array<string>;\n", .kind = .array_type_alias },
        .{ .source = "structural Box = ReadonlyArray<string>;\n", .kind = .readonly_array_type_alias },
        .{ .source = "structural Box = void;\n", .kind = .void_type },
    };
    try std.testing.expectEqual(@as(usize, 16), cases.len);
    var seen = std.EnumSet(type_syntax.AdmissionKind).empty;
    for (cases) |case| try expectAdmissionKindFromSource(case.source, case.kind, &seen);

    var deep: std.ArrayList(u8) = .empty;
    defer deep.deinit(std.testing.allocator);
    try deep.appendSlice(std.testing.allocator, "const value: ");
    try deep.appendNTimes(std.testing.allocator, '{', type_syntax.max_type_depth + 1);
    try deep.appendSlice(std.testing.allocator, " string;\n");
    try expectAdmissionKindFromSource(deep.items, .nesting_too_deep, &seen);
    inline for (@typeInfo(type_syntax.AdmissionKind).@"enum".field_names) |field| {
        const kind: type_syntax.AdmissionKind = @fromBackingInt(@intCast(@backingInt(@field(type_syntax.AdmissionKind, field))));
        try std.testing.expect(seen.contains(kind));
    }
}

test "nested lists retain parent elements across scratch growth" {
    const allocator = std.testing.allocator;
    var source: std.Io.Writer.Allocating = .init(allocator);
    defer source.deinit();
    try source.writer.writeAll("function outer(first, last) { return [first, collect([");
    for (0..256) |i| try source.writer.print("{d},", .{i});
    try source.writer.writeAll("], {value: [11, 12]}, (x, y) => [x, y]), last]; }");
    var parser = try Parser.init(allocator, source.written());
    defer parser.deinit();
    const root = try parser.parse();
    const view = ir.IrView.fromIRStore(&parser.nodes, &parser.constants);
    const program = view.getBlock(root).?;
    const declaration = view.getVarDecl(view.getListIndex(program.stmts_start, 0)).?;
    const outer = view.getFunction(declaration.init).?;
    try std.testing.expectEqual(@as(u8, 2), outer.params_count);
    for ([_][]const u8{ "first", "last" }, 0..) |name, i| {
        const param = view.getPatternElem(view.getListIndex(outer.params_start, @intCast(i))).?;
        try std.testing.expectEqualStrings(name, view.getString(param.binding.name_atom).?);
    }
    var counts = [_]usize{ 0, 0, 0 };
    for (parser.nodes.tags.items, 0..) |tag, i| {
        if (tag == .array_literal) {
            const array = view.getArray(@intCast(i)).?;
            switch (array.elements_count) {
                256 => {
                    counts[0] += 1;
                    for (0..256) |element| try std.testing.expectEqual(@as(i32, @intCast(element)), view.getIntValue(view.getListIndex(array.elements_start, @intCast(element))).?);
                },
                3 => {
                    counts[1] += 1;
                    try std.testing.expectEqual(NodeTag.identifier, view.getTag(view.getListIndex(array.elements_start, 0)).?);
                    const call = view.getCall(view.getListIndex(array.elements_start, 1)).?;
                    try std.testing.expectEqual(@as(u8, 3), call.args_count);
                    try std.testing.expectEqual(NodeTag.array_literal, view.getTag(view.getListIndex(call.args_start, 0)).?);
                    try std.testing.expectEqual(NodeTag.object_literal, view.getTag(view.getListIndex(call.args_start, 1)).?);
                    const arrow = view.getFunction(view.getListIndex(call.args_start, 2)).?;
                    try std.testing.expectEqual(@as(u8, 2), arrow.params_count);
                    try std.testing.expectEqual(NodeTag.identifier, view.getTag(view.getListIndex(array.elements_start, 2)).?);
                },
                2 => counts[2] += 1,
                else => return error.TestUnexpectedResult,
            }
        }
    }
    try std.testing.expectEqualDeep([_]usize{ 1, 1, 2 }, counts);
    try std.testing.expectEqual(@as(usize, 0), parser.scratch_nodes.items.len);
}

test "list scratch unwinds on allocation failure and parser refusal" {
    const source = "function f(a, b) { return [a, {x: [1, 2, 3]}, g([4, 5], x => [x, b])]; }";
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn run(allocator: std.mem.Allocator, text: []const u8) !void {
            var parser = try Parser.init(allocator, text);
            defer parser.deinit();
            defer std.debug.assert(parser.scratch_nodes.items.len == 0);
            _ = try parser.parse();
        }
    }.run, .{source});
    var refused = try Parser.init(std.testing.allocator, "function f(a) { return [a, {x: [1, , 2]}]; }");
    defer refused.deinit();
    try std.testing.expectError(error.ParseError, refused.parse());
    try std.testing.expectEqual(@as(usize, 0), refused.scratch_nodes.items.len);
}

test "admission parser recovers var annotations without hiding ordinary var errors" {
    const Case = struct {
        source: []const u8,
        expected: enum { admission, parser },
        expected_kind: ?type_syntax.AdmissionKind,
        expected_marker: ?[]const u8,
    };
    const cases = [_]Case{
        .{ .source = "var x: any = 1;\n", .expected = .admission, .expected_kind = .any_type, .expected_marker = "any" },
        .{ .source = "var x: number = 1;\n", .expected = .parser, .expected_kind = null, .expected_marker = null },
        .{ .source = "var x: number = 1;\nconst later: any = 2;\n", .expected = .admission, .expected_kind = .any_type, .expected_marker = "any" },
        .{ .source = "var/*comment*/ x: any = 1;\n", .expected = .admission, .expected_kind = .any_type, .expected_marker = "any" },
        .{ .source = "var x/*comment*/: any = 1;\n", .expected = .admission, .expected_kind = .any_type, .expected_marker = "any" },
        .{ .source = "var a = 1, b: any = 2;\n", .expected = .parser, .expected_kind = null, .expected_marker = null },
        .{ .source = "var x = value as any;\n", .expected = .admission, .expected_kind = .as_assertion, .expected_marker = "any" },
    };
    try std.testing.expectEqual(@as(usize, 7), cases.len);
    for (cases) |case| {
        var parser = try Parser.initAdmission(
            std.testing.allocator,
            std.testing.allocator,
            case.source,
            .collect,
        );
        defer parser.deinit();
        const outcome = try parser.parseAdmission();
        switch (case.expected) {
            .admission => {
                switch (outcome) {
                    .recovered_admission_refused => {},
                    else => return error.TestUnexpectedResult,
                }
                const diagnostics = parser.getAdmissionDiagnostics();
                try std.testing.expectEqual(@as(usize, 1), diagnostics.len);
                try std.testing.expectEqual(case.expected_kind.?, diagnostics[0].kind);
                try std.testing.expectEqual(
                    @as(u32, @intCast(std.mem.indexOf(u8, case.source, case.expected_marker.?).?)),
                    diagnostics[0].span.start,
                );
            },
            .parser => switch (outcome) {
                .parser_refused => |refusal| try std.testing.expectEqual(error.ParseError, refusal.first_error),
                else => return error.TestUnexpectedResult,
            },
        }
    }
}

test "admission declaration recognition rejects comment gaps and still refuses a missing equals" {
    const comment_gaps = [_][]const u8{
        "type/*comment*/ Alias = any;\n",
        "export/*comment*/ type Alias = any;\n",
        "distinct/*comment*/ type Alias = any;\n",
        "interface/*comment*/ Shape { value: any };\n",
    };
    for (comment_gaps) |source| {
        var parser = try Parser.initAdmission(
            std.testing.allocator,
            std.testing.allocator,
            source,
            .collect,
        );
        defer parser.deinit();
        switch (try parser.parseAdmission()) {
            .parser_refused => {},
            else => return error.TestUnexpectedResult,
        }
        try std.testing.expectEqual(@as(usize, 0), parser.getAdmissionDiagnostics().len);
    }

    var missing_equals = try Parser.initAdmission(
        std.testing.allocator,
        std.testing.allocator,
        "type Alias any;\n",
        .collect,
    );
    defer missing_equals.deinit();
    switch (try missing_equals.parseAdmission()) {
        .recovered_admission_refused => {},
        else => return error.TestUnexpectedResult,
    }
    const diagnostics = missing_equals.getAdmissionDiagnostics();
    try std.testing.expectEqual(@as(usize, 1), diagnostics.len);
    try std.testing.expectEqual(type_syntax.AdmissionKind.type_alias_declaration, diagnostics[0].kind);
}

test "admission block recovery preserves a later typed declaration after a template failure" {
    const source =
        "function handler() {\n" ++
        "  const broken = `${function nested() {}}`;\n" ++
        "  const after: any = 1;\n" ++
        "}\n";
    var parser = try Parser.initAdmission(
        std.testing.allocator,
        std.testing.allocator,
        source,
        .collect,
    );
    defer parser.deinit();
    switch (try parser.parseAdmission()) {
        .recovered_admission_refused => {},
        else => return error.TestUnexpectedResult,
    }
    const diagnostics = parser.getAdmissionDiagnostics();
    try std.testing.expectEqual(@as(usize, 1), diagnostics.len);
    try std.testing.expectEqual(type_syntax.AdmissionKind.any_type, diagnostics[0].kind);
    try std.testing.expectEqual(
        @as(u32, @intCast(std.mem.indexOf(u8, source, "any").?)),
        diagnostics[0].span.start,
    );
}

test "admission parser commits an initial unfinished comment at EOF" {
    var parser = try Parser.initAdmission(
        std.testing.allocator,
        std.testing.allocator,
        "/* unfinished",
        .collect,
    );
    defer parser.deinit();
    switch (try parser.parseAdmission()) {
        .terminal_admission_refused => |failure| switch (failure) {
            .unterminated_comment => |comment| {
                try std.testing.expectEqual(@as(u32, 0), comment.opener);
                try std.testing.expect(comment.@"resume" > comment.opener);
            },
            else => return error.TestUnexpectedResult,
        },
        else => return error.TestUnexpectedResult,
    }
}

test "admission parser preserves seven measured string and recovery boundaries" {
    const cases = [_]struct {
        source: []const u8,
        kind: type_syntax.AdmissionKind,
        marker: []const u8,
    }{
        .{ .source = "const value = \"open\n\";\nimport type { Spec } from \"" ++ retired_types_module ++ "\";\n", .kind = .unterminated_string, .marker = "\n" },
        .{ .source = "const value = { \"open\nkey\": 1 };\n", .kind = .unterminated_string, .marker = "\n" },
        .{ .source = "import { value } from \"open\npath\";\n", .kind = .unterminated_string, .marker = "\n" },
        .{ .source = "const value = `${\"open\n}`;\nimport type { Spec } from \"" ++ retired_types_module ++ "\";\n", .kind = .legacy_types_import, .marker = "import type" },
        .{ .source = "const value: \"open\n = 1;\nimport type { Spec } from \"" ++ retired_types_module ++ "\";\n", .kind = .legacy_types_import, .marker = "import type" },
        .{ .source = "const broken = ;\n\"open\n\";\n", .kind = .unterminated_string, .marker = "\n\"open\n" },
        .{ .source = "const broken =\nimport type { Spec } from \"" ++ retired_types_module ++ "\";\n", .kind = .legacy_types_import, .marker = "import type" },
    };
    try std.testing.expectEqual(@as(usize, 7), cases.len);
    for (cases) |case| {
        var parser = try Parser.initAdmission(
            std.testing.allocator,
            std.testing.allocator,
            case.source,
            .collect,
        );
        defer parser.deinit();
        switch (try parser.parseAdmission()) {
            .recovered_admission_refused => {},
            .terminal_admission_refused => {},
            else => return error.TestUnexpectedResult,
        }
        const expected_offset: u32 = @intCast(std.mem.indexOf(u8, case.source, case.marker).? +
            if (std.mem.eql(u8, case.marker, "\n\"open\n")) case.marker.len - 1 else 0);
        var found = false;
        for (parser.getAdmissionDiagnostics()) |diagnostic| {
            if (diagnostic.kind != case.kind) continue;
            if (diagnostic.span.start == expected_offset) found = true;
        }
        try std.testing.expect(found);
        if (case.kind == .legacy_types_import) {
            try std.testing.expect(parser.type_only_module_refusal != null);
        }
    }
}

test "admission parser merges type any and caught string in source order" {
    const cases = [_]struct {
        source: []const u8,
        first: type_syntax.AdmissionKind,
        second: type_syntax.AdmissionKind,
    }{
        .{ .source = "const value: any | \"open\n | void = 1;\n", .first = .any_type, .second = .unterminated_string },
        .{ .source = "const value: \"open\n | any | void = 1;\n", .first = .unterminated_string, .second = .any_type },
        .{ .source = "function f(value: any | \"open\n | void) { return 1; }\n", .first = .any_type, .second = .unterminated_string },
        .{ .source = "function f(value: \"open\n | any | void) { return 1; }\n", .first = .unterminated_string, .second = .any_type },
    };
    try std.testing.expectEqual(@as(usize, 4), cases.len);
    for (cases) |case| {
        var parser = try Parser.initAdmission(
            std.testing.allocator,
            std.testing.allocator,
            case.source,
            .collect,
        );
        defer parser.deinit();
        switch (try parser.parseAdmission()) {
            .recovered_admission_refused => {},
            else => return error.TestUnexpectedResult,
        }
        const diagnostics = parser.getAdmissionDiagnostics();
        try std.testing.expect(diagnostics.len >= 2);
        try std.testing.expectEqual(case.first, diagnostics[0].kind);
        try std.testing.expectEqual(case.second, diagnostics[1].kind);
        try std.testing.expect(diagnostics[0].span.start < diagnostics[1].span.start);
    }
}

test "admission parser preserves observed generic probe outcomes" {
    const Cases = enum { named_quote, rejected_call, unfinished_comment };
    const cases = [_]struct {
        case: Cases,
        source: []const u8,
    }{
        .{ .case = .named_quote, .source = "function f<\"open\n>(x: number): number { return x; }\n" },
        .{ .case = .rejected_call, .source = "const value = f<`a${\"open\n 1}tail` || T>(x);\n" },
        .{ .case = .unfinished_comment, .source = "function f<T /* unfinished\n" },
    };
    var seen = std.EnumSet(Cases).empty;
    for (cases) |case| {
        var parser = try Parser.initAdmission(
            std.testing.allocator,
            std.testing.allocator,
            case.source,
            .collect,
        );
        defer parser.deinit();
        const outcome = try parser.parseAdmission();
        switch (case.case) {
            .named_quote, .rejected_call => {
                if (case.case == .named_quote) {
                    switch (outcome) {
                        .terminal_admission_refused => |failure| switch (failure) {
                            .diagnostic => |diagnostic| {
                                try std.testing.expectEqual(type_syntax.AdmissionKind.unterminated_string, diagnostic.kind);
                                try std.testing.expectEqual(
                                    @as(u32, @intCast(std.mem.indexOfScalar(u8, case.source, '\n').?)),
                                    diagnostic.span.start,
                                );
                            },
                            else => return error.TestUnexpectedResult,
                        },
                        else => return error.TestUnexpectedResult,
                    }
                } else {
                    switch (outcome) {
                        .recovered_admission_refused => {},
                        else => return error.TestUnexpectedResult,
                    }
                }
                const diagnostics = parser.getAdmissionDiagnostics();
                try std.testing.expectEqual(@as(usize, 1), diagnostics.len);
                try std.testing.expectEqual(
                    type_syntax.AdmissionKind.unterminated_string,
                    diagnostics[0].kind,
                );
                try std.testing.expectEqual(
                    @as(u32, @intCast(std.mem.indexOfScalar(u8, case.source, '\n').?)),
                    diagnostics[0].span.start,
                );
            },
            .unfinished_comment => switch (outcome) {
                .terminal_admission_refused => |failure| switch (failure) {
                    .unterminated_comment => |comment| {
                        try std.testing.expectEqual(
                            @as(u32, @intCast(std.mem.indexOf(u8, case.source, "/*").?)),
                            comment.opener,
                        );
                        try std.testing.expect(comment.@"resume" > comment.opener);
                    },
                    else => return error.TestUnexpectedResult,
                },
                else => return error.TestUnexpectedResult,
            },
        }
        seen.insert(case.case);
    }
    try std.testing.expectEqual(@typeInfo(Cases).@"enum".field_names.len, seen.count());
}

test "admission parser preserves interface body observation order" {
    const cases = [_]struct {
        source: []const u8,
        first: type_syntax.AdmissionKind,
        second: type_syntax.AdmissionKind,
        second_marker: []const u8,
    }{
        .{
            .source = "interface Shape { value: \"open\n any };\n",
            .first = .unterminated_string,
            .second = .interface_declaration,
            .second_marker = "interface",
        },
        .{
            .source = "interface Shape { /* } */ const x: any = 1;\n",
            .first = .interface_declaration,
            .second = .any_type,
            .second_marker = "any",
        },
    };
    for (cases) |case| {
        var parser = try Parser.initAdmission(
            std.testing.allocator,
            std.testing.allocator,
            case.source,
            .collect,
        );
        defer parser.deinit();
        switch (try parser.parseAdmission()) {
            .recovered_admission_refused => {},
            else => return error.TestUnexpectedResult,
        }
        const diagnostics = parser.getAdmissionDiagnostics();
        try std.testing.expectEqual(@as(usize, 2), diagnostics.len);
        try std.testing.expectEqual(case.first, diagnostics[0].kind);
        try std.testing.expectEqual(case.second, diagnostics[1].kind);
        try std.testing.expectEqual(
            @as(u32, @intCast(std.mem.indexOf(u8, case.source, case.second_marker).?)),
            diagnostics[1].span.start,
        );
    }
}

test "admission assertion recovery resumes from the keyword boundary" {
    const cases = [_]struct {
        source: []const u8,
        kind: type_syntax.AdmissionKind,
        raw_marker: []const u8,
    }{
        .{
            .source = "const x = value as \"open\n; const later: any = 1;\n",
            .kind = .as_assertion,
            .raw_marker = "\"open",
        },
        .{
            .source = "const x = value satisfies \"open\n; const later: any = 1;\n",
            .kind = .satisfies_assertion,
            .raw_marker = "\"open",
        },
        .{
            .source = "const x = value as `x${\"open\n}`; const later: any = 1;\n",
            .kind = .as_assertion,
            .raw_marker = "`x${",
        },
    };
    for (cases) |case| {
        var collect = try Parser.initAdmission(
            std.testing.allocator,
            std.testing.allocator,
            case.source,
            .collect,
        );
        defer collect.deinit();
        switch (try collect.parseAdmission()) {
            .recovered_admission_refused => {},
            else => return error.TestUnexpectedResult,
        }
        const diagnostics = collect.getAdmissionDiagnostics();
        try std.testing.expectEqual(@as(usize, 3), diagnostics.len);
        try std.testing.expectEqual(case.kind, diagnostics[0].kind);
        try std.testing.expectEqual(type_syntax.AdmissionKind.unterminated_string, diagnostics[1].kind);
        try std.testing.expectEqual(type_syntax.AdmissionKind.any_type, diagnostics[2].kind);
        try std.testing.expectEqual(
            @as(u32, @intCast(std.mem.indexOf(u8, case.source, case.raw_marker).?)),
            diagnostics[0].span.start,
        );
        try std.testing.expectEqual(
            @as(u32, @intCast(std.mem.indexOfScalar(u8, case.source, '\n').?)),
            diagnostics[1].span.start,
        );
        try std.testing.expectEqual(
            @as(u32, @intCast(std.mem.indexOf(u8, case.source, "any").?)),
            diagnostics[2].span.start,
        );

        var compile = try Parser.initAdmission(
            std.testing.allocator,
            std.testing.allocator,
            case.source,
            .compile,
        );
        defer compile.deinit();
        switch (try compile.parseAdmission()) {
            .terminal_admission_refused => |failure| switch (failure) {
                .diagnostic => |diagnostic| {
                    try std.testing.expectEqual(case.kind, diagnostic.kind);
                    try std.testing.expectEqual(diagnostics[0].span, diagnostic.span);
                },
                else => return error.TestUnexpectedResult,
            },
            else => return error.TestUnexpectedResult,
        }
        try std.testing.expectEqual(@as(usize, 1), compile.getAdmissionDiagnostics().len);
    }
}

test "admission type call sites preserve comment and empty colon errors" {
    const refused = [_]struct {
        source: []const u8,
        projected_errors: usize,
    }{
        .{ .source = "const x: /* closed */ any = 1;\n", .projected_errors = 2 },
        .{ .source = "function f(x: /* closed */ any) { return x; }\n", .projected_errors = 1 },
        .{ .source = "function f(): /* closed */ any { return 1; }\n", .projected_errors = 1 },
        // One error: the missing type at the colon. The initializer then parses.
        .{ .source = "const x: = 1;\n", .projected_errors = 1 },
        .{ .source = "function f(x:) { return 1; }\n", .projected_errors = 1 },
    };
    for (refused) |case| {
        var parser = try Parser.initAdmission(
            std.testing.allocator,
            std.testing.allocator,
            case.source,
            .collect,
        );
        defer parser.deinit();
        switch (try parser.parseAdmission()) {
            .parser_refused => {},
            else => return error.TestUnexpectedResult,
        }
        try std.testing.expectEqual(@as(usize, 0), parser.getAdmissionDiagnostics().len);
        try std.testing.expectEqual(case.projected_errors, parser.getProjectedErrors().len);
    }

    const recovered_source =
        "const x: /* closed */ any = 1;\n" ++
        "const later: any = 2;\n";
    var recovered = try Parser.initAdmission(
        std.testing.allocator,
        std.testing.allocator,
        recovered_source,
        .collect,
    );
    defer recovered.deinit();
    switch (try recovered.parseAdmission()) {
        .recovered_admission_refused => {},
        else => return error.TestUnexpectedResult,
    }
    const diagnostics = recovered.getAdmissionDiagnostics();
    try std.testing.expectEqual(@as(usize, 1), diagnostics.len);
    try std.testing.expectEqual(type_syntax.AdmissionKind.any_type, diagnostics[0].kind);
    try std.testing.expectEqual(
        @as(u32, @intCast(std.mem.lastIndexOf(u8, recovered_source, "any").?)),
        diagnostics[0].span.start,
    );
}

test "admission export recognition keeps raw statement and gap guards" {
    const sources = [_][]const u8{
        " export default 1;\n",
        "export/*c*/let x = 1;\n",
    };
    for (sources) |source| {
        var parser = try Parser.initAdmission(
            std.testing.allocator,
            std.testing.allocator,
            source,
            .collect,
        );
        defer parser.deinit();
        switch (try parser.parseAdmission()) {
            .parser_refused => {},
            else => return error.TestUnexpectedResult,
        }
        try std.testing.expectEqual(@as(usize, 0), parser.getAdmissionDiagnostics().len);
        try std.testing.expectEqual(@as(usize, 1), parser.getProjectedErrors().len);
    }
}

test "admission recovery preserves import context until a committed semicolon" {
    const cases = [_]struct {
        source: []const u8,
        admission: bool,
    }{
        .{ .source = "import * as ns from \"./dep.ts\";\n", .admission = false },
        .{ .source = "import * as ns from \"./dep.ts\";\nconst x = value as number;\n", .admission = true },
        .{ .source = "import * as ns from \"./dep.ts\"\nconst x = value as number;\n", .admission = false },
    };
    for (cases) |case| {
        var parser = try Parser.initAdmission(
            std.testing.allocator,
            std.testing.allocator,
            case.source,
            .collect,
        );
        defer parser.deinit();
        const outcome = try parser.parseAdmission();
        const diagnostics = parser.getAdmissionDiagnostics();
        if (case.admission) {
            switch (outcome) {
                .recovered_admission_refused => {},
                else => return error.TestUnexpectedResult,
            }
            try std.testing.expectEqual(@as(usize, 1), diagnostics.len);
            try std.testing.expectEqual(type_syntax.AdmissionKind.as_assertion, diagnostics[0].kind);
        } else {
            switch (outcome) {
                .parser_refused => {},
                else => return error.TestUnexpectedResult,
            }
            try std.testing.expectEqual(@as(usize, 0), diagnostics.len);
        }
        try std.testing.expectEqual(@as(usize, 1), parser.getProjectedErrors().len);
    }
}

test "admission recovery restarts typed producers below failed statement depth" {
    const admitted_source = "while (true) { const x: any = 1; }\n";
    var admitted = try Parser.initAdmission(
        std.testing.allocator,
        std.testing.allocator,
        admitted_source,
        .collect,
    );
    defer admitted.deinit();
    switch (try admitted.parseAdmission()) {
        .recovered_admission_refused => {},
        else => return error.TestUnexpectedResult,
    }
    const diagnostics = admitted.getAdmissionDiagnostics();
    try std.testing.expectEqual(@as(usize, 1), diagnostics.len);
    try std.testing.expectEqual(type_syntax.AdmissionKind.any_type, diagnostics[0].kind);
    try std.testing.expectEqual(
        @as(u32, @intCast(std.mem.indexOf(u8, admitted_source, "any").?)),
        diagnostics[0].span.start,
    );

    const healthy_type_source =
        "function f(): number {\n" ++
        "  while (true) { const x: number = 1; }\n" ++
        "  return 1;\n" ++
        "}\n";
    var healthy_type = try Parser.initAdmission(
        std.testing.allocator,
        std.testing.allocator,
        healthy_type_source,
        .collect,
    );
    defer healthy_type.deinit();
    switch (try healthy_type.parseAdmission()) {
        .parser_refused => {},
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expectEqual(@as(usize, 0), healthy_type.getAdmissionDiagnostics().len);
    const projected = healthy_type.getProjectedErrors();
    try std.testing.expectEqual(@as(usize, 1), projected.len);
    try std.testing.expectEqual(
        @as(u32, @intCast(std.mem.indexOf(u8, healthy_type_source, "while").?)),
        projected[0].location.offset,
    );
}

test "admission binding allocation failures retain native out of memory" {
    const BindingCase = enum { variable, function, parameter };
    const cases = [_]struct {
        case: BindingCase,
        source: []const u8,
        name: []const u8,
        witness: []const u8,
    }{
        .{
            .case = .variable,
            .source = "var seed = 1;\nconst Response = 2;\n",
            .name = "Response",
            .witness = "= 2",
        },
        .{
            .case = .function,
            .source = "var seed = 1;\nfunction handler() { return 1; }\n",
            .name = "handler",
            .witness = "()",
        },
        .{
            .case = .parameter,
            .source = "var seed = 1;\nfunction handler(Response) { return Response; }\n",
            .name = "Response",
            .witness = ")",
        },
    };
    const Sweep = struct {
        fn run(
            allocator: std.mem.Allocator,
            case: BindingCase,
            source: []const u8,
            name: []const u8,
            witness_offset: u32,
            witnessed: *std.EnumSet(BindingCase),
        ) !void {
            var parser = try Parser.initAdmission(allocator, allocator, source, .collect);
            defer parser.deinit();
            const outcome = parser.parseAdmission() catch |err| switch (err) {
                error.OutOfMemory => {
                    if (parser.current.start == witness_offset and parser.getErrors().len > 0) {
                        var target_scope_seen = false;
                        var binding_present = false;
                        for (parser.scopes.scopes.items) |scope| {
                            const target_scope = switch (case) {
                                .variable, .function => scope.kind == .global,
                                .parameter => scope.kind == .function,
                            };
                            if (!target_scope) continue;
                            target_scope_seen = true;
                            for (scope.bindings.items) |binding| {
                                if (std.mem.eql(u8, name, binding.name)) binding_present = true;
                            }
                        }
                        if (target_scope_seen and !binding_present and
                            !parser.errors.outOfMemory()) witnessed.insert(case);
                    }
                    return err;
                },
                else => return err,
            };
            switch (outcome) {
                .parser_refused => {},
                else => return error.TestUnexpectedResult,
            }
        }
    };
    var witnessed = std.EnumSet(BindingCase).empty;
    for (cases) |case| {
        const marker = std.mem.indexOf(u8, case.source, case.witness) orelse
            return error.TestUnexpectedResult;
        const witness_offset: u32 = @intCast(marker);
        try std.testing.checkAllAllocationFailures(
            std.testing.allocator,
            Sweep.run,
            .{ case.case, case.source, case.name, witness_offset, &witnessed },
        );
    }
    inline for (@typeInfo(BindingCase).@"enum".field_names) |field| {
        try std.testing.expect(witnessed.contains(@fromBackingInt(@intCast(@backingInt(@field(BindingCase, field))))));
    }
}

test "admission declaration failure preserves the prior Store checkpoint" {
    const seed_source = "const seed: number = 1;\n";
    var seed = try Parser.initAdmission(
        std.testing.allocator,
        std.testing.allocator,
        seed_source,
        .collect,
    );
    defer seed.deinit();
    switch (try seed.parseAdmission()) {
        .accepted => {},
        else => return error.TestUnexpectedResult,
    }
    const expected = seed.type_store.checkpoint();

    const source = seed_source ++ "nominal Box<T> = T;\n";
    var parser = try Parser.initAdmission(
        std.testing.allocator,
        std.testing.allocator,
        source,
        .collect,
    );
    defer parser.deinit();
    switch (try parser.parseAdmission()) {
        .recovered_admission_refused => {},
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expectEqual(
        type_syntax.AdmissionKind.nominal_base_not_scalar,
        parser.getAdmissionDiagnostics()[0].kind,
    );
    try std.testing.expect(std.meta.eql(expected, parser.type_store.checkpoint()));
}

test "admission type allocation failures preserve a published seed" {
    const source =
        "const seed: number = 1;\n" ++
        "function f<\"open\n>(value: number): number { return value; }\n";
    const Sweep = struct {
        fn run(type_allocator: std.mem.Allocator, post_seed_failures: *usize) !void {
            var parser = try Parser.initAdmission(
                std.testing.allocator,
                type_allocator,
                source,
                .collect,
            );
            defer parser.deinit();
            const outcome = parser.parseAdmission() catch |err| switch (err) {
                error.OutOfMemory => {
                    var seed_published = false;
                    for (parser.nodes.tags.items, 0..) |tag, index| {
                        if (tag == .var_decl and parser.nodes.getLoc(@intCast(index)).offset == 0) {
                            seed_published = true;
                            break;
                        }
                    }
                    if (seed_published) {
                        post_seed_failures.* += 1;
                        var expected = std.mem.zeroes(type_syntax.Store.Checkpoint);
                        expected.nodes = 1;
                        expected.annotations = 1;
                        try std.testing.expect(std.meta.eql(
                            expected,
                            parser.type_store.checkpoint(),
                        ));
                    }
                    return err;
                },
                else => return err,
            };
            switch (outcome) {
                .terminal_admission_refused => |failure| switch (failure) {
                    .diagnostic => |diagnostic| {
                        try std.testing.expectEqual(type_syntax.AdmissionKind.unterminated_string, diagnostic.kind);
                        try std.testing.expectEqual(
                            @as(u32, @intCast(std.mem.indexOfScalarPos(u8, source, "const seed: number = 1;\n".len, '\n').?)),
                            diagnostic.span.start,
                        );
                    },
                    else => return error.TestUnexpectedResult,
                },
                else => return error.TestUnexpectedResult,
            }
            const diagnostics = parser.getAdmissionDiagnostics();
            try std.testing.expectEqual(@as(usize, 1), diagnostics.len);
            try std.testing.expectEqual(
                type_syntax.AdmissionKind.unterminated_string,
                diagnostics[0].kind,
            );
            var expected = std.mem.zeroes(type_syntax.Store.Checkpoint);
            expected.nodes = 1;
            expected.annotations = 1;
            try std.testing.expect(std.meta.eql(expected, parser.type_store.checkpoint()));
        }
    };
    var post_seed_failures: usize = 0;
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        Sweep.run,
        .{&post_seed_failures},
    );
    try std.testing.expect(post_seed_failures > 0);
}

test "admission header recovery preserves ordered legacy events without owners" {
    const Expected = struct { kind: type_syntax.AdmissionKind, offset: u32 };
    const cases = [_]struct {
        source: []const u8,
        expected: []const Expected,
        compile_first: usize,
    }{
        .{ .source = "function f({ x } = {}, y: any) { return 1; }\n", .expected = &.{ .{ .kind = .default_parameter, .offset = 17 }, .{ .kind = .any_type, .offset = 26 } }, .compile_first = 0 },
        .{ .source = "function f({ x }: any = {}, y: any) { return 1; }\n", .expected = &.{ .{ .kind = .any_type, .offset = 18 }, .{ .kind = .default_parameter, .offset = 22 }, .{ .kind = .any_type, .offset = 31 } }, .compile_first = 0 },
        .{ .source = "function f({ x }: /* closed */ any, y: any) { return 1; }\n", .expected = &.{.{ .kind = .any_type, .offset = 39 }}, .compile_first = 0 },
        .{ .source = "function f({ x }: Box<number, string>, y: any) { return 1; }\n", .expected = &.{.{ .kind = .any_type, .offset = 42 }}, .compile_first = 0 },
        .{ .source = "function f({ x }: \"open\n, y: any) { return 1; }\n", .expected = &.{ .{ .kind = .unterminated_string, .offset = 23 }, .{ .kind = .any_type, .offset = 29 } }, .compile_first = 1 },
        .{ .source = "function f(x = y => y, z: any) { return 1; }\n", .expected = &.{ .{ .kind = .default_parameter, .offset = 13 }, .{ .kind = .default_parameter, .offset = 17 }, .{ .kind = .any_type, .offset = 26 } }, .compile_first = 0 },
        .{ .source = "function f(x = a == b, z: any) { return 1; }\n", .expected = &.{ .{ .kind = .default_parameter, .offset = 13 }, .{ .kind = .default_parameter, .offset = 17 }, .{ .kind = .default_parameter, .offset = 18 }, .{ .kind = .any_type, .offset = 26 } }, .compile_first = 0 },
        .{ .source = "function f({ x }?: number, y: any) { return 1; }\n", .expected = &.{ .{ .kind = .optional_parameter, .offset = 16 }, .{ .kind = .any_type, .offset = 30 } }, .compile_first = 0 },
    };
    try std.testing.expectEqual(@as(usize, 8), cases.len);
    for (cases) |case| {
        var collect = try Parser.initAdmission(
            std.testing.allocator,
            std.testing.allocator,
            case.source,
            .collect,
        );
        defer collect.deinit();
        switch (try collect.parseAdmission()) {
            .recovered_admission_refused => {},
            else => return error.TestUnexpectedResult,
        }
        const diagnostics = collect.getAdmissionDiagnostics();
        try std.testing.expectEqual(case.expected.len, diagnostics.len);
        for (diagnostics, case.expected) |actual, expected| {
            try std.testing.expectEqual(expected.kind, actual.kind);
            try std.testing.expectEqual(expected.offset, actual.span.start);
        }
        try std.testing.expectEqual(@as(usize, 0), collect.type_store.function_signatures.items.len);
        try std.testing.expectEqual(@as(usize, 0), collect.type_store.parameter_annotations.items.len);

        var compile = try Parser.initAdmission(
            std.testing.allocator,
            std.testing.allocator,
            case.source,
            .compile,
        );
        defer compile.deinit();
        switch (try compile.parseAdmission()) {
            .terminal_admission_refused => |failure| switch (failure) {
                .diagnostic => |diagnostic| {
                    try std.testing.expectEqual(case.expected[case.compile_first].kind, diagnostic.kind);
                    try std.testing.expectEqual(case.expected[case.compile_first].offset, diagnostic.span.start);
                },
                else => return error.TestUnexpectedResult,
            },
            else => return error.TestUnexpectedResult,
        }
        try std.testing.expectEqual(@as(usize, 1), compile.getAdmissionDiagnostics().len);
    }
}

test "admission header depth includes the enclosing parameter parenthesis" {
    const prefix = "function f({ x: ";
    const admitted_nesting = type_syntax.max_type_depth - 2;
    for ([_]usize{ admitted_nesting, admitted_nesting + 1 }) |count| {
        var source: std.ArrayListUnmanaged(u8) = .empty;
        defer source.deinit(std.testing.allocator);
        try source.appendSlice(std.testing.allocator, prefix);
        try source.appendNTimes(std.testing.allocator, '(', count);
        try source.appendSlice(std.testing.allocator, "x");
        try source.appendNTimes(std.testing.allocator, ')', count);
        try source.appendSlice(std.testing.allocator, "}, y: any) { return 1; }\n");
        var parser = try Parser.initAdmission(
            std.testing.allocator,
            std.testing.allocator,
            source.items,
            .collect,
        );
        defer parser.deinit();
        const outcome = try parser.parseAdmission();
        if (count == admitted_nesting) {
            switch (outcome) {
                .recovered_admission_refused => {},
                else => return error.TestUnexpectedResult,
            }
            try std.testing.expectEqual(type_syntax.AdmissionKind.any_type, parser.getAdmissionDiagnostics()[0].kind);
        } else {
            switch (outcome) {
                .terminal_admission_refused => |failure| switch (failure) {
                    .diagnostic => |diagnostic| {
                        try std.testing.expectEqual(type_syntax.AdmissionKind.nesting_too_deep, diagnostic.kind);
                        try std.testing.expectEqual(@as(u32, @intCast(prefix.len + count - 1)), diagnostic.span.start);
                    },
                    else => return error.TestUnexpectedResult,
                },
                else => return error.TestUnexpectedResult,
            }
        }
        try std.testing.expectEqual(@as(usize, 1), parser.getAdmissionDiagnostics().len);
        try std.testing.expectEqual(@as(usize, 0), parser.type_store.function_signatures.items.len);
        try std.testing.expectEqual(@as(usize, 0), parser.type_store.parameter_annotations.items.len);
    }
}

test "admission generic scanner stops before an unreachable later quote" {
    const prefix = "function /* gap */ f<";
    var source: std.ArrayListUnmanaged(u8) = .empty;
    defer source.deinit(std.testing.allocator);
    try source.appendSlice(std.testing.allocator, prefix);
    try source.appendNTimes(std.testing.allocator, '(', type_syntax.max_type_depth);
    try source.appendSlice(std.testing.allocator, "T");
    try source.appendNTimes(std.testing.allocator, ')', type_syntax.max_type_depth);
    try source.appendSlice(std.testing.allocator, "`a${\"open\n}`>(x: number): number { return x; }\n");
    var parser = try Parser.initAdmission(
        std.testing.allocator,
        std.testing.allocator,
        source.items,
        .collect,
    );
    defer parser.deinit();
    switch (try parser.parseAdmission()) {
        .terminal_admission_refused => |failure| switch (failure) {
            .diagnostic => |diagnostic| {
                try std.testing.expectEqual(type_syntax.AdmissionKind.nesting_too_deep, diagnostic.kind);
                try std.testing.expectEqual(@as(u32, @intCast(prefix.len + type_syntax.max_type_depth - 1)), diagnostic.span.start);
            },
            else => return error.TestUnexpectedResult,
        },
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expectEqual(@as(usize, 1), parser.getAdmissionDiagnostics().len);
    const last = parser.getLastAdmissionObservation() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(type_syntax.AdmissionKind.nesting_too_deep, last.kind);
}

test "admission header recovery retains later nested block errors" {
    const cases = [_]struct { source: []const u8, while_offset: u32 }{
        .{ .source = "function outer(): number { function inner({ x }) { return 1; } while (true) {} return 1; }\n", .while_offset = 63 },
        .{ .source = "function outer(): number { function inner({ x }: /* gap */ number) { return 1; } while (true) {} return 1; }\n", .while_offset = 81 },
    };
    try std.testing.expectEqual(@as(usize, 2), cases.len);
    for (cases) |case| {
        var parser = try Parser.initAdmission(
            std.testing.allocator,
            std.testing.allocator,
            case.source,
            .collect,
        );
        defer parser.deinit();
        switch (try parser.parseAdmission()) {
            .parser_refused => {},
            else => return error.TestUnexpectedResult,
        }
        const errors = parser.getProjectedErrors();
        try std.testing.expectEqual(@as(usize, 2), errors.len);
        try std.testing.expectEqual(@as(u32, 42), errors[0].location.offset);
        try std.testing.expectEqual(case.while_offset, errors[1].location.offset);
        try std.testing.expectEqual(error_mod.ErrorKind.unsupported_feature, errors[0].kind);
        try std.testing.expectEqual(error_mod.ErrorKind.unsupported_feature, errors[1].kind);
        try std.testing.expectEqual(@as(usize, 0), parser.type_store.function_signatures.items.len);
        try std.testing.expectEqual(@as(usize, 0), parser.type_store.parameter_annotations.items.len);
    }
}

test "admission header recovery propagates allocation failures after refusal" {
    const frame_count = type_syntax.max_type_depth + 1;
    const source = "function f({ x } = `outer${\"open\n" ++
        (@as([(frame_count) * ("`nested${").len]u8, @bitCast(@as([frame_count][("`nested${").len]u8, @splat(("`nested${").*))))) ++ "value" ++ (@as([(frame_count) * ("}`").len]u8, @bitCast(@as([frame_count][("}`").len]u8, @splat(("}`").*))))) ++
        "}`, y: any) { return 1; }\n";
    const Sweep = struct {
        fn run(allocator: std.mem.Allocator, post_refusal_failures: *usize) !void {
            var parser = try Parser.initAdmission(allocator, allocator, source, .collect);
            defer parser.deinit();
            const outcome = parser.parseAdmission() catch |err| switch (err) {
                error.OutOfMemory => {
                    const diagnostics = parser.getAdmissionDiagnostics();
                    if (diagnostics.len > 0 and diagnostics[0].kind == .default_parameter) {
                        post_refusal_failures.* += 1;
                        try std.testing.expect(std.meta.eql(
                            std.mem.zeroes(type_syntax.Store.Checkpoint),
                            parser.type_store.checkpoint(),
                        ));
                    }
                    return err;
                },
                else => return err,
            };
            switch (outcome) {
                .recovered_admission_refused => {},
                else => return error.TestUnexpectedResult,
            }
            try std.testing.expectEqual(type_syntax.AdmissionKind.default_parameter, parser.getAdmissionDiagnostics()[0].kind);
            try std.testing.expect(std.meta.eql(
                std.mem.zeroes(type_syntax.Store.Checkpoint),
                parser.type_store.checkpoint(),
            ));
        }
    };
    var post_refusal_failures: usize = 0;
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        Sweep.run,
        .{&post_refusal_failures},
    );
    try std.testing.expect(post_refusal_failures > 0);
}

test "a newline after return no longer swallows the value" {
    // Under JS ASI the newline terminates the statement, so the handler would
    // return nothing and the `Response.json` below it would become
    // unreachable - silently. Spec 5.5 has no
    // insertion, so the newline means nothing and `return` binds the expression
    // that follows it.
    var parser = try Parser.init(std.testing.allocator,
        \\function handler(req) {
        \\  return
        \\  Response.json({ leaked: true });
        \\}
    );
    defer parser.deinit();
    _ = parser.parse() catch 0;

    var found_return = false;
    var return_has_arg = false;
    for (parser.nodes.tags.items, 0..) |tag, i| {
        if (tag == .return_stmt) {
            found_return = true;
            return_has_arg = parser.nodes.getData(@intCast(i)).a != null_node;
        }
    }
    try std.testing.expect(found_return);
    try std.testing.expect(return_has_arg);
    try std.testing.expect(!parser.hasErrors());
}

test "a bare return with no semicolon is refused, with the insertion repair" {
    // The other half: `return` genuinely returning nothing still needs its
    // terminator written, and the refusal names the rule rather than reporting
    // that some token was expected.
    var parser = try Parser.init(std.testing.allocator,
        \\function handler(req) {
        \\  return
        \\}
    );
    defer parser.deinit();
    _ = parser.parse() catch 0;

    const errors = parser.getErrors();
    try std.testing.expect(errors.len >= 1);
    try std.testing.expectEqual(error_mod.ErrorKind.missing_semicolon, errors[0].kind);
}

test "break and continue in a function nested in a loop are refused" {
    // Code generation gives each function body an empty loop stack, so a
    // `break` that names the enclosing function's loop compiled to nothing
    // and the statements after it ran.
    const refused = [_][]const u8{
        "function f(xs) { for (const x of xs) { const g = () => { break; }; } }",
        "function f(xs) { for (const x of xs) { const g = () => { continue; }; } }",
        "function f(xs) { for (const x of xs) { function g() { break; } } }",
        "function f(xs) { for (const x of xs) { const g = (y) => { if (y) { continue; } return y; }; } }",
    };
    for (refused) |source| {
        var parser = try Parser.init(std.testing.allocator, source);
        defer parser.deinit();
        _ = parser.parse() catch 0;
        const errors = parser.getErrors();
        try std.testing.expect(errors.len >= 1);
        try std.testing.expect(std.mem.indexOf(u8, errors[0].message, "outside of loop") != null);
    }

    // The loop flag comes back after the nested function, so the outer
    // loop's own `break` and `continue` still parse.
    const accepted = [_][]const u8{
        "function f(xs) { for (const x of xs) { const g = () => 1; break; } }",
        "function f(xs) { for (const x of xs) { function g() { return 1; } continue; } }",
        "function f(xs) { for (const x of xs) { const g = () => { for (const y of xs) { break; } return 1; }; continue; } }",
    };
    for (accepted) |source| {
        var parser = try Parser.init(std.testing.allocator, source);
        defer parser.deinit();
        _ = try parser.parse();
        try std.testing.expect(!parser.hasErrors());
    }
}

test "the compatibility mode still parses what insertion accepted" {
    // M2 compares the tree of the unrepaired original against the repaired
    // file, so the original has to keep parsing somewhere. That somewhere is
    // this flag, and this is the test that it still does what it did.
    var parser = try Parser.init(std.testing.allocator, "const a = 1\nconst b = 2\n");
    defer parser.deinit();
    parser.allow_asi = true;
    _ = try parser.parse();
    try std.testing.expect(!parser.hasErrors());
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

test "parse escaped string literal transfers an exact-sized owned value" {
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

test "escaped strings decode and deduplicate through allocation failures" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn run(allocator: std.mem.Allocator) !void {
            var parser = try Parser.init(
                allocator,
                "const values = [\"line\\nvalue\", `line\\nvalue`, \"\\u{1F600}\", \"\\x41\"];",
            );
            defer parser.deinit();
            _ = try parser.parse();
            try std.testing.expect(!parser.hasErrors());
            var decoded: usize = 0;
            for (parser.constants.strings.items) |bytes| {
                if (std.mem.eql(u8, bytes, "line\nvalue") or std.mem.eql(u8, bytes, "😀") or std.mem.eql(u8, bytes, "A")) decoded += 1;
            }
            try std.testing.expectEqual(@as(usize, 3), decoded);
        }
    }.run, .{});
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

test "failed generic speculation restores the complete parser cursor" {
    {
        const source = "left < right && other > (value);";
        var parser = try Parser.initAdmission(std.testing.allocator, std.testing.allocator, source, .compile);
        defer parser.deinit();
        _ = try parser.parsePrefixExpr();
        try std.testing.expectEqual(TokenType.lt, parser.current.type);
        const cursor_before = parser.cursorCheckpoint();
        const store_before = parser.type_store.checkpoint();
        try std.testing.expect((try parser.tryReserveExplicitCall()) == null);
        try std.testing.expect(std.meta.eql(cursor_before, parser.cursorCheckpoint()));
        try std.testing.expect(std.meta.eql(store_before, parser.type_store.checkpoint()));
    }
    {
        const source = "(<T> /* gap */ (value)=>value);";
        var parser = try Parser.initAdmission(std.testing.allocator, std.testing.allocator, source, .compile);
        defer parser.deinit();
        parser.advance();
        try std.testing.expectEqual(TokenType.lt, parser.current.type);
        const cursor_before = parser.cursorCheckpoint();
        const store_before = parser.type_store.checkpoint();
        switch (try parser.tryReserveArrowGenericOwner()) {
            .not_generic => {},
            .rejected_call_grammar, .reserved => return error.TestUnexpectedResult,
        }
        try std.testing.expect(std.meta.eql(cursor_before, parser.cursorCheckpoint()));
        try std.testing.expect(std.meta.eql(store_before, parser.type_store.checkpoint()));
    }
}

test "named function comment with spaced opener restores generic speculation" {
    const source =
        "function /* gap */ identity<T> (value) { return value; }";
    var parser = try Parser.initAdmission(std.testing.allocator, std.testing.allocator, source, .compile);
    defer parser.deinit();
    try std.testing.expectEqual(TokenType.kw_function, parser.current.type);
    parser.advance();
    const name = try parser.expectIdentifier("function name");
    try std.testing.expectEqual(TokenType.lt, parser.current.type);
    const cursor_before = parser.cursorCheckpoint();
    const store_before = parser.type_store.checkpoint();
    const reservation = try parser.tryReserveFunctionGenericOwner(
        name,
        @intCast("function".len),
    );
    try std.testing.expect(reservation.pending_owner == null);
    try std.testing.expectEqual(Parser.FunctionHeaderAdmission.typed, reservation.header_admission);
    try std.testing.expect(std.meta.eql(cursor_before, parser.cursorCheckpoint()));
    try std.testing.expect(std.meta.eql(store_before, parser.type_store.checkpoint()));
}

test "named function comment call grammar refusal restores seeded speculation" {
    const sources = [_][]const u8{
        "const seed: number = 1; function /* gap */ identity<T = string>(value) { return value; }",
        "const seed: number = 1; function /* gap */ identity<T || U>(value) { return value; }",
        "const seed: number = 1; function /* gap */ identity<T + U>(value) { return value; }",
    };
    for (sources) |source| {
        var parser = try Parser.initAdmission(std.testing.allocator, std.testing.allocator, source, .compile);
        defer parser.deinit();
        _ = try parser.parseStatement();
        try std.testing.expectEqual(TokenType.kw_function, parser.current.type);
        const keyword_end = parser.current.start + @as(u32, "function".len);
        parser.advance();
        const name = try parser.expectIdentifier("function name");
        try std.testing.expectEqual(TokenType.lt, parser.current.type);
        const cursor_before = parser.cursorCheckpoint();
        const store_before = parser.type_store.checkpoint();
        try std.testing.expectEqual(@as(usize, 1), store_before.nodes);
        try std.testing.expectEqual(@as(usize, 1), store_before.annotations);
        const reservation = try parser.tryReserveFunctionGenericOwner(name, keyword_end);
        try std.testing.expect(reservation.pending_owner == null);
        try std.testing.expect(std.meta.eql(cursor_before, parser.cursorCheckpoint()));
        try std.testing.expect(std.meta.eql(store_before, parser.type_store.checkpoint()));
        try parser.type_store.validate();
    }
    try std.testing.expectEqual(@as(usize, 3), sources.len);
}

test "parse no-substitution template as string literal" {
    var parser = try Parser.init(std.testing.allocator, "const s = `hello!`;");
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

test "refuse object declaration destructuring" {
    const allocator = std.testing.allocator;
    const source =
        \\const { name, age } = obj;
        \\const { x: localX, y = 10 } = point;
    ;

    var parser = try Parser.init(allocator, source);
    defer parser.deinit();

    try std.testing.expectError(error.ParseError, parser.parse());
    try std.testing.expect(parser.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, parser.getErrors()[0].message, "read each member") != null);
}

test "refuse array declaration destructuring" {
    const allocator = std.testing.allocator;
    const source =
        \\const [a, b, c] = arr;
        \\let [x, , y] = [1, 2, 3];
    ;

    var parser = try Parser.init(allocator, source);
    defer parser.deinit();

    try std.testing.expectError(error.ParseError, parser.parse());
    try std.testing.expect(parser.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, parser.getErrors()[0].message, "indexed `const` bindings") != null);
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

test "resource limit: left-deep expression chains yield nesting diagnostic" {
    const allocator = std.testing.allocator;
    const cases = [_]struct { prefix: []const u8, step: []const u8 }{
        .{ .prefix = "const x = 1", .step = " + 1" },
        .{ .prefix = "const x = f", .step = "()" },
        .{ .prefix = "const x = o", .step = ".b" },
        .{ .prefix = "const x = o", .step = "[0]" },
    };

    for (cases) |case| {
        var source: std.ArrayList(u8) = .empty;
        defer source.deinit(allocator);
        try source.appendSlice(allocator, case.prefix);
        for (0..Parser.max_recursion_depth + 1) |_| {
            try source.appendSlice(allocator, case.step);
        }
        try source.append(allocator, ';');

        var parser = try Parser.init(allocator, source.items);
        defer parser.deinit();
        try std.testing.expectError(error.ParseError, parser.parse());
        try std.testing.expect(parser.hasErrors());
        try std.testing.expectEqual(error_mod.ErrorKind.nesting_too_deep, parser.getErrors()[0].kind);
    }
}

test "resource limit: left-deep chain at limit parses" {
    const allocator = std.testing.allocator;
    var source: std.ArrayList(u8) = .empty;
    defer source.deinit(allocator);
    try source.appendSlice(allocator, "const x = 1");
    for (0..Parser.max_recursion_depth) |_| {
        try source.appendSlice(allocator, " + 1");
    }
    try source.appendSlice(allocator, "; const y = 1");
    for (0..Parser.max_recursion_depth) |_| {
        try source.appendSlice(allocator, " + 1");
    }
    try source.append(allocator, ';');

    var parser = try Parser.init(allocator, source.items);
    defer parser.deinit();
    _ = try parser.parse();
    try std.testing.expect(!parser.hasErrors());
}

test "resource limit: grouped chains share one depth budget" {
    const allocator = std.testing.allocator;
    var source: std.ArrayList(u8) = .empty;
    defer source.deinit(allocator);
    try source.appendSlice(allocator, "const x = (1");
    for (0..300) |_| try source.appendSlice(allocator, " + 1");
    try source.append(allocator, ')');
    for (0..300) |_| try source.appendSlice(allocator, " + 1");
    try source.append(allocator, ';');

    var parser = try Parser.init(allocator, source.items);
    defer parser.deinit();
    try std.testing.expectError(error.ParseError, parser.parse());
    try std.testing.expectEqual(error_mod.ErrorKind.nesting_too_deep, parser.getErrors()[0].kind);
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
    const source = "function handler(req) { const x = await foo(); return Response.json({ x: x }); }";
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

test "kernel expression profile preserves null and loose equality in IR" {
    const allocator = std.testing.allocator;

    var parser = try Parser.initExpression(allocator, "null == undefined");
    defer parser.deinit();

    const root = try parser.parseExpressionOnly();
    const view = ir.IrView.fromIRStore(&parser.nodes, &parser.constants);
    const binary = view.getBinary(root).?;

    try std.testing.expectEqual(BinaryOp.loose_eq, binary.op);
    try std.testing.expectEqual(NodeTag.lit_null, view.getTag(binary.left).?);
    try std.testing.expectEqual(NodeTag.lit_undefined, view.getTag(binary.right).?);
}

test "both profiles refuse the pipe operator with the same diagnostic" {
    // Both profiles refuse `|>` with one kind and one message.
    const allocator = std.testing.allocator;

    var expression_parser = try Parser.initExpression(allocator, "\"value\" |> hash");
    defer expression_parser.deinit();
    try std.testing.expectError(error.ParseError, expression_parser.parseExpressionOnly());
    try std.testing.expectEqual(error_mod.ErrorKind.unsupported_feature, expression_parser.getErrors()[0].kind);

    var program_parser = try Parser.init(allocator, "const result = \"value\" |> hash;");
    defer program_parser.deinit();
    _ = program_parser.parse() catch {};
    try std.testing.expect(program_parser.hasErrors());
    try std.testing.expectEqual(error_mod.ErrorKind.unsupported_feature, program_parser.getErrors()[0].kind);
}

test "kernel expression numeric separators remain isolated from programs" {
    const allocator = std.testing.allocator;

    var expression_parser = try Parser.initExpression(allocator, "1_000");
    defer expression_parser.deinit();
    const root = try expression_parser.parseExpressionOnly();
    const view = ir.IrView.fromIRStore(&expression_parser.nodes, &expression_parser.constants);
    try std.testing.expectEqual(@as(f64, 1000), view.getFloat(view.getFloatIdx(root).?).?);

    // In a program, the separator is a diagnostic, not a silent truncation:
    // the literal must not lex as `1` followed by the identifier statement
    // `_000`, or a handler would serve 1 where the author wrote 1000.
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

test "a radix literal above i32 keeps its value" {
    // `parseFloat` reads only base 10 and 16, so `0b` and `0o` literals above
    // i32 must not become 0.0 with no diagnostic. The pool dedups the hex value.
    const allocator = std.testing.allocator;
    var parser = try Parser.init(allocator, "const a = 0b100000000000000000000000000000000; const b = 0o100000000000; const c = 0x100000000;");
    defer parser.deinit();
    _ = try parser.parse();
    try std.testing.expect(!parser.hasErrors());
    try std.testing.expectEqualSlices(f64, &.{ 4294967296.0, 8589934592.0 }, parser.constants.floats.items);
}

test "get and set before a key without a parenthesis are refused" {
    const allocator = std.testing.allocator;
    for ([_][]const u8{ "const o = { get x: 1 };", "const o = { set x: 1 };" }) |source| {
        var parser = try Parser.init(allocator, source);
        defer parser.deinit();
        try std.testing.expectError(error.ParseError, parser.parse());
        try std.testing.expect(parser.hasErrors());
    }
    // `get` and `set` stay ordinary keys.
    var keys = try Parser.init(allocator, "const o = { get: 1, set: 2 };");
    defer keys.deinit();
    _ = try keys.parse();
    try std.testing.expect(!keys.hasErrors());
}

test "an unknown escape is refused rather than copied" {
    // D3 section 1: the escape set is closed. `\q` must not emit `q`: a typo
    // in an escape would produce a string the author did not write, with no
    // diagnostic.
    const allocator = std.testing.allocator;
    var parser = try Parser.init(allocator, "const s = \"a\\qb\";");
    defer parser.deinit();
    try std.testing.expectError(error.InvalidEscapeSequence, parser.parse());
    const errors = parser.getErrors();
    try std.testing.expect(errors.len >= 1);
    try std.testing.expectEqual(error_mod.ErrorKind.invalid_escape_sequence, errors[0].kind);
    // The source is one line.
    try std.testing.expectEqual(@as(u32, 1), errors[0].location.line);
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

test "kernel expression parsing decodes unicode escapes like programs" {
    const allocator = std.testing.allocator;

    var expression_parser = try Parser.initExpression(allocator, "\"caf\\u00e9\"");
    defer expression_parser.deinit();
    const root = try expression_parser.parseExpressionOnly();
    const view = ir.IrView.fromIRStore(&expression_parser.nodes, &expression_parser.constants);
    try std.testing.expectEqualStrings("café", view.getString(view.getStringIdx(root).?).?);
}

test "kernel expression unary before exponent preserves its legacy grammar" {
    const allocator = std.testing.allocator;

    var expression_parser = try Parser.initExpression(allocator, "-3 ** 2");
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

test "unsupported: pipe operator names the direct call" {
    var parser = try Parser.init(std.testing.allocator, "const r = 5 |> double;");
    defer parser.deinit();

    _ = parser.parse() catch {
        try std.testing.expect(parser.hasErrors());
        const errors = parser.getErrors();
        try std.testing.expect(errors.len > 0);
        const err = errors[0];
        try std.testing.expectEqual(error_mod.ErrorKind.unsupported_feature, err.kind);
        try std.testing.expect(std.mem.indexOf(u8, err.message, "|>") != null);
        try std.testing.expect(std.mem.indexOf(u8, err.message, "f(a)") != null);
        // The span is the operator's, not the whole statement's: a repair
        // client rewrites `a |> f` in place and needs to know where it sits.
        try std.testing.expectEqual(@as(u32, 1), err.location.line);
        try std.testing.expectEqual(@as(u32, 13), err.location.column);
        return;
    };

    try std.testing.expect(false);
}

test "unsupported: a pipe chain is refused at its first operator" {
    // Refusing at the first operator is what keeps the reported column on a
    // span the author can act on rather than on the end of the chain.
    var parser = try Parser.init(std.testing.allocator, "const r = x |> f |> g |> h;");
    defer parser.deinit();

    _ = parser.parse() catch {
        try std.testing.expect(parser.hasErrors());
        const err = parser.getErrors()[0];
        try std.testing.expectEqual(error_mod.ErrorKind.unsupported_feature, err.kind);
        try std.testing.expectEqual(@as(u32, 13), err.location.column);
        return;
    };

    try std.testing.expect(false);
}

test "unsupported: guard and pipe are ordinary names once compose is gone" {
    // `guard(f) |> h` was one desugared construct. The refusal must come from
    // the operator, not from the callee: with no module to import them from,
    // `guard` and `pipe` are undeclared identifiers like any other.
    var parser = try Parser.init(std.testing.allocator, "const h = guard(a) |> route;");
    defer parser.deinit();

    _ = parser.parse() catch {
        const err = parser.getErrors()[0];
        try std.testing.expectEqual(error_mod.ErrorKind.unsupported_feature, err.kind);
        try std.testing.expect(std.mem.indexOf(u8, err.message, "|>") != null);
        return;
    };

    try std.testing.expect(false);
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

test "unsupported: unary void names the explicit undefined repair" {
    const allocator = std.testing.allocator;
    const source = "const ignored = void sideEffect();";

    var parser = try Parser.init(allocator, source);
    defer parser.deinit();

    try std.testing.expectError(error.ParseError, parser.parse());
    try std.testing.expectEqual(error_mod.ErrorKind.unsupported_feature, parser.getErrors()[0].kind);
    try std.testing.expect(std.mem.indexOf(u8, parser.getErrors()[0].message, "undefined") != null);
}

test "unsupported: debugger statement names removal" {
    var parser = try Parser.init(std.testing.allocator, "debugger;");
    defer parser.deinit();

    try std.testing.expectError(error.ParseError, parser.parse());
    try std.testing.expectEqual(error_mod.ErrorKind.unsupported_feature, parser.getErrors()[0].kind);
    try std.testing.expect(std.mem.indexOf(u8, parser.getErrors()[0].message, "remove the statement") != null);
}

test "unsupported: empty statement names removal" {
    var parser = try Parser.init(std.testing.allocator, ";");
    defer parser.deinit();

    try std.testing.expectError(error.ParseError, parser.parse());
    try std.testing.expectEqual(error_mod.ErrorKind.unsupported_feature, parser.getErrors()[0].kind);
    try std.testing.expect(std.mem.indexOf(u8, parser.getErrors()[0].message, "standalone `;`") != null);
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

test "export default is refused with a named export repair" {
    const allocator = std.testing.allocator;
    const source =
        \\export default function handler() {}
    ;

    var parser = try Parser.init(allocator, source);
    defer parser.deinit();

    try std.testing.expectError(error.ParseError, parser.parse());
    try std.testing.expectEqual(error_mod.ErrorKind.unsupported_feature, parser.getErrors()[0].kind);
    try std.testing.expect(std.mem.indexOf(u8, parser.getErrors()[0].message, "named export") != null);
}

test "export let is refused with an export const repair" {
    const allocator = std.testing.allocator;
    const source =
        \\export let version = 1;
    ;

    var parser = try Parser.init(allocator, source);
    defer parser.deinit();

    try std.testing.expectError(error.ParseError, parser.parse());
    try std.testing.expectEqual(error_mod.ErrorKind.unsupported_feature, parser.getErrors()[0].kind);
    try std.testing.expect(std.mem.indexOf(u8, parser.getErrors()[0].message, "export const") != null);
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

test "unsupported: default parameter" {
    const allocator = std.testing.allocator;
    const source = "function label(prefix = 'item') { return prefix; }";

    var parser = try Parser.init(allocator, source);
    defer parser.deinit();
    _ = parser.parse() catch {};

    try std.testing.expect(parser.hasErrors());
    var found = false;
    for (parser.getErrors()) |err| {
        if (err.kind == error_mod.ErrorKind.unsupported_feature and
            std.mem.indexOf(u8, err.message, "default parameters") != null) found = true;
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

test "parse match expression refuses top-level wildcard" {
    var parser = try Parser.init(std.testing.allocator,
        \\const x = match (v) {
        \\  when 1: "one",
        \\  when _: "other"
        \\};
    );
    defer parser.deinit();

    try std.testing.expectError(error.ParseError, parser.parse());
    try std.testing.expectEqual(error_mod.ErrorKind.unsupported_feature, parser.getErrors()[0].kind);
    try std.testing.expect(std.mem.indexOf(u8, parser.getErrors()[0].message, "default:") != null);
}

test "parse match expression refuses a default arm that is not last" {
    // Spec 5.5 grammar is `MatchArm+ [DefaultArm]`. Codegen tests every `when`
    // in order and takes `default` last, so `when 2` below would be accepted
    // and then answered by `default`.
    var parser = try Parser.init(std.testing.allocator,
        \\const x = match (v) {
        \\  when 1: "one",
        \\  default: "other",
        \\  when 2: "two"
        \\};
    );
    defer parser.deinit();

    try std.testing.expectError(error.ParseError, parser.parse());
    const errors = parser.getErrors();
    try std.testing.expectEqual(@as(usize, 1), errors.len);
    try std.testing.expectEqual(error_mod.ErrorKind.misplaced_default_arm, errors[0].kind);
    // The diagnostic points at the misplaced `default`, which is line 3.
    try std.testing.expectEqual(@as(u32, 3), errors[0].location.line);
    try std.testing.expectEqual(@as(u32, 3), errors[0].location.column);
    try std.testing.expect(std.mem.indexOf(u8, errors[0].message, "last") != null);
}

test "parse match expression refuses a second default arm" {
    var parser = try Parser.init(std.testing.allocator,
        \\const x = match (v) {
        \\  when 1: "one",
        \\  default: "other",
        \\  default: "again"
        \\};
    );
    defer parser.deinit();

    try std.testing.expectError(error.ParseError, parser.parse());
    const errors = parser.getErrors();
    try std.testing.expectEqual(@as(usize, 1), errors.len);
    try std.testing.expectEqual(error_mod.ErrorKind.misplaced_default_arm, errors[0].kind);
    // The diagnostic points at the second `default`, which is line 4.
    try std.testing.expectEqual(@as(u32, 4), errors[0].location.line);
    try std.testing.expect(std.mem.indexOf(u8, errors[0].message, "at most one") != null);
}

test "parse match expression accepts default as the only or the last arm" {
    var only = try Parser.init(std.testing.allocator, "const x = match (v) { default: 0 };");
    defer only.deinit();
    _ = try only.parse();
    try std.testing.expect(!only.hasErrors());

    var last = try Parser.init(std.testing.allocator,
        \\const x = match (v) {
        \\  when 1: "one",
        \\  when 2: "two",
        \\  default: "other"
        \\};
    );
    defer last.deinit();
    _ = try last.parse();
    try std.testing.expect(!last.hasErrors());
}

test "parse match expression refuses a renamed binding named like a type test" {
    // Spec 5.5: `value: v` binds the field under a new name. `{ v: string }`
    // therefore bound a variable called `string` and matched every value, which
    // is never what an author who wrote a type name meant.
    const names = [_][]const u8{ "boolean", "number", "string", "array", "Dict", "Bytes" };
    for (names) |name| {
        var source_buf: [128]u8 = undefined;
        const source = try std.fmt.bufPrint(&source_buf, "const x = match (v) {{ when {{ k: {s} }}: 1, default: 0 }};", .{name});

        var parser = try Parser.init(std.testing.allocator, source);
        defer parser.deinit();

        try std.testing.expectError(error.ParseError, parser.parse());
        const errors = parser.getErrors();
        try std.testing.expectEqual(@as(usize, 1), errors.len);
        try std.testing.expectEqual(error_mod.ErrorKind.unsupported_feature, errors[0].kind);
        try std.testing.expect(std.mem.indexOf(u8, errors[0].message, name) != null);
        try std.testing.expect(std.mem.indexOf(u8, errors[0].message, "nested type tests are not supported") != null);
        try std.testing.expect(std.mem.indexOf(u8, errors[0].message, "nested `match`") != null);
        // Located at the name, which starts at column 33 for every spelling.
        try std.testing.expectEqual(@as(u32, 1), errors[0].location.line);
        try std.testing.expectEqual(@as(u32, 33), errors[0].location.column);
    }
}

test "parse match expression refuses a type-test name as an array element" {
    // The element must not parse as a type test of the whole scrutinee.
    var parser = try Parser.init(std.testing.allocator, "const x = match (v) { when [string]: 1, default: 0 };");
    defer parser.deinit();

    try std.testing.expectError(error.ParseError, parser.parse());
    const errors = parser.getErrors();
    try std.testing.expectEqual(@as(usize, 1), errors.len);
    try std.testing.expectEqual(error_mod.ErrorKind.unsupported_feature, errors[0].kind);
    try std.testing.expect(std.mem.indexOf(u8, errors[0].message, "nested type tests are not supported") != null);
}

test "parse match expression keeps shorthand bindings and top-level type tests" {
    // `{ string }` binds a field literally named `string`; only the renamed
    // and array-element spellings are the trap.
    var shorthand = try Parser.init(std.testing.allocator, "const x = match (v) { when { string }: string, default: 0 };");
    defer shorthand.deinit();
    _ = try shorthand.parse();
    try std.testing.expect(!shorthand.hasErrors());

    var mixed = try Parser.init(std.testing.allocator, "const x = match (v) { when { kind: \"a\", Dict }: Dict, default: 0 };");
    defer mixed.deinit();
    _ = try mixed.parse();
    try std.testing.expect(!mixed.hasErrors());

    var top_level = try Parser.init(std.testing.allocator, "const x = match (v) { when string: 1, when Dict: 2, default: 0 };");
    defer top_level.deinit();
    _ = try top_level.parse();
    try std.testing.expect(!top_level.hasErrors());

    var renamed = try Parser.init(std.testing.allocator, "const x = match (v) { when { k: other }: other, default: 0 };");
    defer renamed.deinit();
    _ = try renamed.parse();
    try std.testing.expect(!renamed.hasErrors());
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

    // Pin the second arm itself: it is the only source line that holds the
    // out-of-scope read, and `command` on line 1 would satisfy the counts above.
    var second_arm_locals: usize = 0;
    var second_arm_non_locals: usize = 0;
    node = 0;
    while (node < view.nodeCount()) : (node += 1) {
        if (view.getTag(node) != .identifier) continue;
        const loc = view.getLoc(node) orelse continue;
        if (loc.line != 3) continue;
        const binding = view.getBinding(node) orelse continue;
        switch (binding.kind) {
            .local, .argument, .upvalue => second_arm_locals += 1,
            .global, .undeclared_global => second_arm_non_locals += 1,
        }
    }
    try std.testing.expectEqual(@as(usize, 0), second_arm_locals);
    try std.testing.expectEqual(@as(usize, 1), second_arm_non_locals);
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

// Regression: four binding sites returned `error.TooManyLocals` from a failed
// `declareBinding` without recording a parse error. `parse` then took its
// recovery path, skipped the statement, and returned a program that was
// missing it, with no error at all. An out-of-memory error inside
// `declareBinding` took the same path under the same name. Found by the
// allocation sweep in tests/frontend_fuzz.zig.
test "a statement that needs more local slots than a scope has fails the parse" {
    const allocator = std.testing.allocator;

    // 300 parameters, as an arrow function and as a function declaration.
    const parameter_shapes = [_]struct { open: []const u8, close: []const u8 }{
        .{ .open = "const f = (", .close = ") => 1;" },
        .{ .open = "function f(", .close = ") { return 1; }" },
    };
    for (parameter_shapes) |shape| {
        var source: std.ArrayList(u8) = .empty;
        defer source.deinit(allocator);
        try source.appendSlice(allocator, shape.open);
        for (0..300) |index| {
            if (index > 0) try source.appendSlice(allocator, ", ");
            try source.print(allocator, "p{d}", .{index});
        }
        try source.appendSlice(allocator, shape.close);
        try expectParseFailsWithTooMany(allocator, source.items);
    }

    // 255 locals fill a function scope. The next binding, made by a `for`
    // loop or by a `match` pattern, has no slot.
    const tails = [_][]const u8{
        "for (const x of xs) { }",
        "match (v) { when { t }: t default: 0 };",
    };
    for (tails) |tail| {
        var source: std.ArrayList(u8) = .empty;
        defer source.deinit(allocator);
        try source.appendSlice(allocator, "function f(xs, v) {\n");
        for (0..253) |index| try source.print(allocator, "const a{d} = 1;\n", .{index});
        try source.appendSlice(allocator, tail);
        try source.appendSlice(allocator, "\n}");
        try expectParseFailsWithTooMany(allocator, source.items);
    }
}

fn expectParseFailsWithTooMany(allocator: std.mem.Allocator, source: []const u8) !void {
    var parser = try Parser.init(allocator, source);
    defer parser.deinit();
    if (parser.parse()) |_| return error.ProgramWithTooManyLocalsWasAccepted else |_| {}
    try std.testing.expect(parser.hasErrors());
    for (parser.getErrors()) |recorded| {
        if (std.mem.startsWith(u8, recorded.message, "too many ")) return;
    }
    return error.NoTooManyDiagnostic;
}

// Regression: an out-of-memory error inside a statement recorded no parse
// error, so `parse` took its recovery path, skipped to the next statement, and
// returned a program that was missing the statement. The parse succeeded with
// part of the source gone. Found by the allocation sweep in
// tests/frontend_fuzz.zig on "const x = 1;".
test "an out-of-memory error inside a statement fails the parse" {
    const Sweep = struct {
        fn parseWholeProgram(allocator: std.mem.Allocator, source: []const u8) !void {
            var parser = try Parser.init(allocator, source);
            defer parser.deinit();
            _ = try parser.parse();
        }
    };
    const sources = [_][]const u8{
        "const x = 1;",
        "let y = 2;",
        "function f(a) { return a; }",
        "const o = { k: 1 };",
    };
    for (sources) |source| {
        try std.testing.checkAllAllocationFailures(std.testing.allocator, Sweep.parseWholeProgram, .{source});
    }
}

// Regression: a float table index was narrowed with @intCast, so an array of
// 70000 distinct floats panicked `zts check` (found by the U2.3 corpus ratchet,
// which had to allowlist ZTS031 as a defect). The pool now refuses the
// constant past its u16 address space and the parser records ZTS031.
test "a program with more distinct constants than a u16 indexes fails the parse with too_many_constants" {
    const allocator = std.testing.allocator;
    var source: std.ArrayList(u8) = .empty;
    defer source.deinit(allocator);
    try source.appendSlice(allocator, "const xs = [");
    for (0..70_000) |index| try source.print(allocator, "{d}.5, ", .{index});
    try source.appendSlice(allocator, "0.5];");

    var parser = try Parser.init(allocator, source.items);
    defer parser.deinit();
    try std.testing.expectError(error.TooManyConstants, parser.parse());
    var found = false;
    for (parser.getErrors()) |recorded| {
        if (recorded.kind == .too_many_constants) found = true;
    }
    try std.testing.expect(found);
}

// Regression: block recovery discarded every statement error, so the same
// constant overflow inside a function body dropped the statement, the parse
// succeeded, and the type checker later failed on the missing binding with no
// diagnostic. Block and program recovery now share one rule for an error that
// recorded nothing.
test "a constant overflow inside a function body fails the parse once with too_many_constants" {
    const allocator = std.testing.allocator;
    var source: std.ArrayList(u8) = .empty;
    defer source.deinit(allocator);
    try source.appendSlice(allocator, "function f() { const xs = [");
    for (0..70_000) |index| try source.print(allocator, "{d}.5, ", .{index});
    try source.appendSlice(allocator, "0.5]; return xs; }");

    var parser = try Parser.init(allocator, source.items);
    defer parser.deinit();
    try std.testing.expectError(error.TooManyConstants, parser.parse());
    var found: usize = 0;
    for (parser.getErrors()) |recorded| {
        if (recorded.kind == .too_many_constants) found += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), found);
}

test "an out-of-memory error inside a function body fails the parse" {
    const Sweep = struct {
        fn parseWholeProgram(allocator: std.mem.Allocator, source: []const u8) !void {
            var parser = try Parser.init(allocator, source);
            defer parser.deinit();
            _ = try parser.parse();
        }
    };
    const sources = [_][]const u8{
        "function f() { const x = 1; const y = \"s\"; return x; }",
        "function f(a) { if (a) { const o = { k: 1.5 }; return o; } return a; }",
    };
    for (sources) |source| {
        try std.testing.checkAllAllocationFailures(std.testing.allocator, Sweep.parseWholeProgram, .{source});
    }
}

fn firstNonAsciiError(allocator: std.mem.Allocator, source: []const u8, out: *Parser) !error_mod.ParseError {
    out.* = try Parser.init(allocator, source);
    _ = out.parse() catch 0;
    const errors = out.getErrors();
    try std.testing.expect(errors.len >= 1);
    try std.testing.expectEqual(error_mod.ErrorKind.non_ascii_identifier, errors[0].kind);
    return errors[0];
}

test "ZTS046 names a minus sign outside an identifier and says what to write" {
    const allocator = std.testing.allocator;
    var parser: Parser = undefined;
    // `a − 1` holds U+2212, three bytes, at column 13 of line 2.
    const err = try firstNonAsciiError(allocator, "const a = 2;\nconst b = a \xe2\x88\x92 1;", &parser);
    defer parser.deinit();
    try std.testing.expectEqualStrings("U+2212 MINUS SIGN is not ASCII", err.message);
    try std.testing.expectEqualStrings("write the ASCII hyphen-minus `-`", err.suggestion.?);
    try std.testing.expectEqual(@as(u32, 2), err.location.line);
    try std.testing.expectEqual(@as(u32, 13), err.location.column);
    const span = err.location.span();
    try std.testing.expectEqual(@as(u32, 3), span.end - span.start);
    // The text must not call this an identifier problem.
    try std.testing.expect(std.mem.indexOf(u8, err.message, "identifier") == null);
}

test "ZTS046 narrows the span to the character inside an identifier run" {
    const allocator = std.testing.allocator;
    var parser: Parser = undefined;
    const err = try firstNonAsciiError(allocator, "const caf\xc3\xa9 = 1;", &parser);
    defer parser.deinit();
    try std.testing.expectEqualStrings("U+00E9 is not allowed in an identifier", err.message);
    try std.testing.expectEqualStrings(
        "identifiers are ASCII: letters, digits, `_` and `$`; rename it",
        err.suggestion.?,
    );
    // `const caf` is nine bytes, so the character starts at column 10.
    try std.testing.expectEqual(@as(u32, 10), err.location.column);
    const span = err.location.span();
    try std.testing.expectEqual(@as(u32, 9), span.start);
    try std.testing.expectEqual(@as(u32, 11), span.end);
}

test "ZTS046 does not call a stray symbol an identifier" {
    const allocator = std.testing.allocator;
    var parser: Parser = undefined;
    const err = try firstNonAsciiError(allocator, "const price = \xe2\x82\xac5;", &parser);
    defer parser.deinit();
    try std.testing.expectEqualStrings("U+20AC is not an ASCII character", err.message);
    try std.testing.expect(std.mem.indexOf(u8, err.message, "identifier") == null);
    try std.testing.expect(std.mem.indexOf(u8, err.suggestion.?, "identifier") == null);
}

test "ZTS046 reports invalid UTF-8 in its own words" {
    const allocator = std.testing.allocator;
    var parser: Parser = undefined;
    const err = try firstNonAsciiError(allocator, "const a = \xff;", &parser);
    defer parser.deinit();
    try std.testing.expectEqualStrings("invalid UTF-8 byte 0xFF", err.message);
    try std.testing.expectEqual(@as(u32, 11), err.location.column);
    const span = err.location.span();
    try std.testing.expectEqual(@as(u32, 1), span.end - span.start);
}

test "ZTS046 names a truncated UTF-8 sequence as invalid" {
    const allocator = std.testing.allocator;
    var parser: Parser = undefined;
    // A three-byte lead with one continuation byte before the token ends.
    const err = try firstNonAsciiError(allocator, "const a = \xe2\x88;", &parser);
    defer parser.deinit();
    try std.testing.expectEqualStrings("invalid UTF-8 byte 0xE2", err.message);
}

test "ZTS046 knows every lookalike in the table" {
    const allocator = std.testing.allocator;
    const cases = [_]struct { bytes: []const u8, name: []const u8, replacement: []const u8 }{
        .{ .bytes = "\xe2\x88\x92", .name = "U+2212 MINUS SIGN", .replacement = "`-`" },
        .{ .bytes = "\xe2\x80\x93", .name = "U+2013 EN DASH", .replacement = "`-`" },
        .{ .bytes = "\xe2\x80\x94", .name = "U+2014 EM DASH", .replacement = "`-`" },
        .{ .bytes = "\xe2\x80\x9c", .name = "U+201C LEFT DOUBLE QUOTATION MARK", .replacement = "`\"`" },
        .{ .bytes = "\xe2\x80\x9d", .name = "U+201D RIGHT DOUBLE QUOTATION MARK", .replacement = "`\"`" },
        .{ .bytes = "\xe2\x80\x98", .name = "U+2018 LEFT SINGLE QUOTATION MARK", .replacement = "`'`" },
        .{ .bytes = "\xe2\x80\x99", .name = "U+2019 RIGHT SINGLE QUOTATION MARK", .replacement = "`'`" },
        .{ .bytes = "\xc2\xa0", .name = "U+00A0 NO-BREAK SPACE", .replacement = "ASCII space" },
        .{ .bytes = "\xe3\x80\x80", .name = "U+3000 IDEOGRAPHIC SPACE", .replacement = "ASCII space" },
        .{ .bytes = "\xef\xbb\xbf", .name = "U+FEFF ZERO WIDTH NO-BREAK SPACE", .replacement = "delete it" },
        .{ .bytes = "\xc3\x97", .name = "U+00D7 MULTIPLICATION SIGN", .replacement = "`*`" },
        .{ .bytes = "\xe2\x80\xa6", .name = "U+2026 HORIZONTAL ELLIPSIS", .replacement = "`...`" },
    };
    for (cases) |case| {
        const source = try std.mem.concat(allocator, u8, &.{ "const a = 1 ", case.bytes, " 2;" });
        defer allocator.free(source);
        var parser: Parser = undefined;
        const err = try firstNonAsciiError(allocator, source, &parser);
        defer parser.deinit();
        try std.testing.expect(std.mem.startsWith(u8, err.message, case.name));
        try std.testing.expect(std.mem.endsWith(u8, err.message, "is not ASCII") or
            std.mem.indexOf(u8, err.message, "is not ASCII") != null);
        try std.testing.expect(std.mem.indexOf(u8, err.suggestion.?, case.replacement) != null);
        const span = err.location.span();
        try std.testing.expectEqual(@as(u32, @intCast(case.bytes.len)), span.end - span.start);
    }
}

test "ZTS046 reports a byte order mark at the start of the file" {
    const allocator = std.testing.allocator;
    var parser: Parser = undefined;
    const err = try firstNonAsciiError(allocator, "\xef\xbb\xbfconst a = 1;", &parser);
    defer parser.deinit();
    try std.testing.expect(std.mem.startsWith(u8, err.message, "U+FEFF"));
    try std.testing.expectEqual(@as(u32, 1), err.location.column);
}

fn parseErrorCount(allocator: std.mem.Allocator, source: []const u8) !usize {
    var parser = try Parser.init(allocator, source);
    defer parser.deinit();
    _ = parser.parse() catch 0;
    return parser.getErrors().len;
}

test "an unsupported while loop reports once, not once per resumed fragment" {
    // Recovery must not stop at the first `;` inside the loop body and parse
    // the rest of the body as new statements. That would report a `return`
    // "outside of function" and an expression "expected" at a `}`. Both follow
    // from the `while` and name nothing the author could fix separately.
    const source =
        \\function handler(req) {
        \\  let n = 0;
        \\  while (n < 3) {
        \\    n = n + 1;
        \\  }
        \\  return n;
        \\}
    ;
    try std.testing.expectEqual(@as(usize, 1), try parseErrorCount(std.testing.allocator, source));
}

test "an unsupported switch and try report once" {
    const switch_source =
        \\function handler(req) {
        \\  switch (req.method) {
        \\    case "GET":
        \\      return 1;
        \\    default:
        \\      return 2;
        \\  }
        \\}
    ;
    const try_source =
        \\function handler(req) {
        \\  try {
        \\    return 1;
        \\  } catch (e) {
        \\    return 2;
        \\  }
        \\}
    ;
    try std.testing.expectEqual(@as(usize, 1), try parseErrorCount(std.testing.allocator, switch_source));
    try std.testing.expectEqual(@as(usize, 1), try parseErrorCount(std.testing.allocator, try_source));
}

test "recovery in a nested block leaves the enclosing block intact" {
    // The skipped braces belong to the failed statement. Treating the `}` of
    // the `while` body as the end of the `if` block would end the function body
    // early and report the statements after it as top-level code.
    const source =
        \\function handler(req) {
        \\  if (req) {
        \\    let n = 0;
        \\    while (n < 3) { n = n + 1; }
        \\    return n;
        \\  }
        \\  return 0;
        \\}
    ;
    try std.testing.expectEqual(@as(usize, 1), try parseErrorCount(std.testing.allocator, source));
}

test "recovery from an error inside a match still lands on the statement after it" {
    // The failed statement is the `match`, and the error is raised inside its
    // braces, so the match's own `{` is open when recovery starts. Recovery
    // returns to the enclosing block's level and stops after the match's `;`.
    const source =
        \\function handler(req) {
        \\  const v = match (req.method) {
        \\    when "GET": 1,
        \\    default: 2,
        \\    when "POST": 3,
        \\  };
        \\  return v;
        \\}
    ;
    try std.testing.expectEqual(@as(usize, 1), try parseErrorCount(std.testing.allocator, source));
}

test "recovery still reports a second, independent fault in a later statement" {
    // Silence ends at the synchronization point. Two separate unsupported
    // statements are two faults and get two reports.
    const source =
        \\function handler(req) {
        \\  let n = 0;
        \\  while (n < 3) { n = n + 1; }
        \\  let z = 1;
        \\  var q = 2;
        \\  return n;
        \\}
    ;
    try std.testing.expectEqual(@as(usize, 2), try parseErrorCount(std.testing.allocator, source));
}

test "an error list records one error per offset" {
    var list = error_mod.ErrorList.init(std.testing.allocator, "abc def");
    defer list.deinit();
    const at: SourceLocation = .{ .line = 1, .column = 1, .offset = 0 };
    list.addError(.unexpected_token, at, "first");
    list.addError(.expected_expression, at, "second at the same offset");
    list.addError(.unexpected_token, .{ .line = 1, .column = 5, .offset = 4 }, "third, elsewhere");
    try std.testing.expectEqual(@as(usize, 2), list.errorCount());
    try std.testing.expectEqualStrings("first", list.getErrors()[0].message);
    try std.testing.expectEqualStrings("third, elsewhere", list.getErrors()[1].message);
}

test "type-only module speculation restores the complete cursor and store" {
    {
        const source =
            "import type { Seed } from \"./seed\";\n" ++
            "import { live } from \"./live\";";
        var parser = try Parser.initAdmission(std.testing.allocator, std.testing.allocator, source, .compile);
        defer parser.deinit();
        try std.testing.expect(try parser.tryConsumeTypeOnlyModule());
        const cursor_checkpoint = parser.cursorCheckpoint();
        const store_checkpoint = parser.type_store.checkpoint();
        const diagnostics_checkpoint = parser.type_only_module_diagnostics.items.len;
        try std.testing.expect(!try parser.tryConsumeTypeOnlyModule());
        try std.testing.expect(std.meta.eql(cursor_checkpoint, parser.cursorCheckpoint()));
        try std.testing.expect(std.meta.eql(store_checkpoint, parser.type_store.checkpoint()));
        try std.testing.expectEqual(diagnostics_checkpoint, parser.type_only_module_diagnostics.items.len);
        try std.testing.expect(parser.last_erased_type_span != null);
    }

    {
        const source =
            "import type { Seed } from \"./seed\";\n" ++
            "import type { Spec } from \"" ++ retired_types_module ++ "\";";
        var parser = try Parser.initAdmission(std.testing.allocator, std.testing.allocator, source, .compile);
        defer parser.deinit();
        try std.testing.expect(try parser.tryConsumeTypeOnlyModule());
        const cursor_checkpoint = parser.cursorCheckpoint();
        const store_checkpoint = parser.type_store.checkpoint();
        try std.testing.expectError(error.TypeOnlyModuleRefused, parser.tryConsumeTypeOnlyModule());
        try std.testing.expect(std.meta.eql(cursor_checkpoint, parser.cursorCheckpoint()));
        try std.testing.expect(std.meta.eql(store_checkpoint, parser.type_store.checkpoint()));
        const refusal = parser.type_only_module_refusal orelse return error.TestUnexpectedResult;
        const second_import = std.mem.lastIndexOf(u8, source, "import") orelse
            return error.TestUnexpectedResult;
        try std.testing.expectEqual(@as(u32, @intCast(second_import)), refusal.original_location.offset);
        try std.testing.expectEqual(@as(usize, 0), parser.errors.getErrors().len);
    }
}

test "type-only module append failure retains a prior full checkpoint" {
    var source: std.ArrayListUnmanaged(u8) = .empty;
    defer source.deinit(std.testing.allocator);
    for (0..128) |_| {
        try source.appendSlice(std.testing.allocator, "import type { A } from \"./a\";\n");
    }

    var parser = try Parser.initAdmission(std.testing.allocator, std.testing.allocator, source.items, .compile);
    defer parser.deinit();
    while (parser.type_store.type_only_modules.items.len == 0 or
        parser.type_store.type_only_modules.items.len < parser.type_store.type_only_modules.capacity)
    {
        if (parser.current.type == .eof) return error.TestUnexpectedResult;
        try std.testing.expect(try parser.tryConsumeTypeOnlyModule());
    }
    try std.testing.expect(parser.type_store.type_only_modules.items.len > 0);
    try std.testing.expect(parser.current.type == .kw_import);

    const cursor_checkpoint = parser.cursorCheckpoint();
    const store_checkpoint = parser.type_store.checkpoint();
    var failing = std.testing.FailingAllocator.init(
        std.testing.allocator,
        .{ .fail_index = 0, .resize_fail_index = 0 },
    );
    const stable_allocator = parser.type_store.allocator;
    parser.type_store.allocator = failing.allocator();
    defer parser.type_store.allocator = stable_allocator;
    try std.testing.expectError(error.OutOfMemory, parser.tryConsumeTypeOnlyModule());
    parser.type_store.allocator = stable_allocator;
    try std.testing.expect(failing.has_induced_failure);
    try std.testing.expect(std.meta.eql(cursor_checkpoint, parser.cursorCheckpoint()));
    try std.testing.expect(std.meta.eql(store_checkpoint, parser.type_store.checkpoint()));
    try parser.type_store.validate();
}

test "type-only module scan failure restores prior diagnostics" {
    var source: std.ArrayListUnmanaged(u8) = .empty;
    defer source.deinit(std.testing.allocator);
    try source.appendSlice(std.testing.allocator, "import type \"open\nimport type ");
    for (0..type_syntax.max_template_levels + 1) |_| {
        try source.appendSlice(std.testing.allocator, "`${");
    }
    try source.appendSlice(std.testing.allocator, "value");

    var parser = try Parser.initAdmission(std.testing.allocator, std.testing.allocator, source.items, .compile);
    defer parser.deinit();
    try std.testing.expect(try parser.tryConsumeTypeOnlyModule());
    // Admission records the excluded module as a diagnostic and publishes it.
    try std.testing.expectEqual(@as(usize, 1), parser.type_only_module_diagnostics.items.len);
    const prior_diagnostic = parser.type_only_module_diagnostics.items[0];
    const cursor_checkpoint = parser.cursorCheckpoint();
    const store_checkpoint = parser.type_store.checkpoint();

    var failing = std.testing.FailingAllocator.init(
        std.testing.allocator,
        .{ .fail_index = 0 },
    );
    const stable_allocator = parser.type_store.allocator;
    parser.type_store.allocator = failing.allocator();
    defer parser.type_store.allocator = stable_allocator;
    try std.testing.expectError(error.OutOfMemory, parser.tryConsumeTypeOnlyModule());
    parser.type_store.allocator = stable_allocator;
    try std.testing.expect(failing.has_induced_failure);
    try std.testing.expect(std.meta.eql(cursor_checkpoint, parser.cursorCheckpoint()));
    try std.testing.expect(std.meta.eql(store_checkpoint, parser.type_store.checkpoint()));
    try std.testing.expectEqual(@as(usize, 1), parser.type_only_module_diagnostics.items.len);
    try std.testing.expect(std.meta.eql(prior_diagnostic, parser.type_only_module_diagnostics.items[0]));
}

test "type-only module lexical exclusion and refusal keep root priority" {
    {
        const source =
            "import type \"open\n" ++
            "import type { Spec } from \"" ++ retired_types_module ++ "\";";
        var parser = try Parser.initAdmission(std.testing.allocator, std.testing.allocator, source, .compile);
        defer parser.deinit();
        try std.testing.expectError(error.AdmissionRefused, parser.parse());
        try std.testing.expect(parser.type_only_module_refusal != null);
        try std.testing.expect(parser.getAdmissionDiagnostics().len > 0);
        try std.testing.expectEqual(type_syntax.AdmissionKind.legacy_types_import, parser.getAdmissionDiagnostics()[parser.getAdmissionDiagnostics().len - 1].kind);
        try std.testing.expectEqual(@as(usize, 1), parser.type_only_module_diagnostics.items.len);
        try std.testing.expectEqual(@as(usize, 0), parser.errors.getErrors().len);
    }

    {
        const source =
            "import type \"open\n" ++
            "const broken = ;\n" ++
            "import type { Spec } from \"" ++ retired_types_module ++ "\";";
        var parser = try Parser.initAdmission(std.testing.allocator, std.testing.allocator, source, .compile);
        defer parser.deinit();
        try std.testing.expectError(error.AdmissionRefused, parser.parse());
        // Admission records the refusal beside the lexical exclusion.
        try std.testing.expect(parser.type_only_module_refusal != null);
        try std.testing.expectEqual(type_syntax.AdmissionKind.legacy_types_import, parser.getAdmissionDiagnostics()[0].kind);
        // The retired import is line 3 of the source.
        try std.testing.expectEqual(@as(u32, 3), parser.getAdmissionDiagnostics()[0].positionIn(source).line);
        try std.testing.expect(parser.errors.getErrors().len > 0);
        // `const broken = ;` is line 2 of the source.
        try std.testing.expectEqual(@as(u32, 2), parser.errors.getErrors()[0].location.line);
    }
}

test "retained type-only module refusal outranks a later ordinary error" {
    const source = "const broken = ;";
    var parser = try Parser.initAdmission(std.testing.allocator, std.testing.allocator, source, .compile);
    defer parser.deinit();
    parser.type_only_module_refusal = .{
        .reason = .zttp_types,
        .raw_span = .{ .start = 0, .end = 6 },
        .original_location = .{
            .line = 1,
            .column = 1,
            .offset = 0,
            .end_offset = 6,
        },
    };

    try std.testing.expectError(error.TypeOnlyModuleRefused, parser.parse());
    try std.testing.expect(parser.errors.getErrors().len > 0);
    // The `;` that cannot start an expression is byte 15 of the source.
    try std.testing.expectEqual(@as(u32, 15), parser.errors.getErrors()[0].location.offset);
}

test "native allocation failure outranks a retained type-only module refusal" {
    const source = "const live = { value: 1 };";
    const Context = struct {
        fn run(allocator: std.mem.Allocator, observed_native_oom: *usize) !void {
            var parser = try Parser.initAdmission(allocator, std.testing.allocator, source, .compile);
            defer parser.deinit();
            parser.type_only_module_refusal = .{
                .reason = .zttp_types,
                .raw_span = .{ .start = 0, .end = 6 },
                .original_location = .{
                    .line = 1,
                    .column = 1,
                    .offset = 0,
                    .end_offset = 6,
                },
            };
            _ = parser.parse() catch |err| switch (err) {
                error.OutOfMemory => {
                    observed_native_oom.* += 1;
                    return err;
                },
                error.TypeOnlyModuleRefused => return,
                else => return err,
            };
            return error.TestUnexpectedResult;
        }
    };
    var observed_native_oom: usize = 0;
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        Context.run,
        .{&observed_native_oom},
    );
    try std.testing.expect(observed_native_oom > 0);
}

test "error-list allocation failure outranks a retained type-only module refusal" {
    const source = "const broken = ;";
    var parser = try Parser.initAdmission(std.testing.allocator, std.testing.allocator, source, .compile);
    defer parser.deinit();
    parser.type_only_module_refusal = .{
        .reason = .zttp_types,
        .raw_span = .{ .start = 0, .end = 6 },
        .original_location = .{
            .line = 1,
            .column = 1,
            .offset = 0,
            .end_offset = 6,
        },
    };
    var failing = std.testing.FailingAllocator.init(
        std.testing.allocator,
        .{ .fail_index = 0 },
    );
    const stable_allocator = parser.errors.allocator;
    parser.errors.allocator = failing.allocator();
    defer parser.errors.allocator = stable_allocator;

    try std.testing.expectError(error.OutOfMemory, parser.parse());
    parser.errors.allocator = stable_allocator;
    try std.testing.expect(failing.has_induced_failure);
    try std.testing.expect(parser.errors.outOfMemory());
}

test "nested type-only module refusal removes enclosing type syntax" {
    const tails = [_][]const u8{
        "function helper<T>(value: string): string {import type { Spec } from \"" ++ retired_types_module ++ "\";return value;}",
        "const helper=<T>(value)=>{import type { Spec } from \"" ++ retired_types_module ++ "\";return value;};",
        "export const helper=<T>(value)=>{import type { Spec } from \"" ++ retired_types_module ++ "\";return value;};",
    };
    for (tails) |tail| {
        const source = try std.mem.concat(
            std.testing.allocator,
            u8,
            &.{ "const seed: number = 1;\n", tail },
        );
        defer std.testing.allocator.free(source);
        var parser = try Parser.initAdmission(std.testing.allocator, std.testing.allocator, source, .compile);
        defer parser.deinit();
        try std.testing.expectError(error.AdmissionRefused, parser.parse());
        const refusal = parser.type_only_module_refusal orelse return error.TestUnexpectedResult;
        const refusal_offset = std.mem.indexOf(u8, source, "import type") orelse
            return error.TestUnexpectedResult;
        var refusal_line: u32 = 1;
        var refusal_column: u32 = 1;
        for (source[0..refusal_offset]) |byte| {
            if (byte == '\n') {
                refusal_line += 1;
                refusal_column = 1;
            } else {
                refusal_column += 1;
            }
        }
        try std.testing.expectEqual(@as(u32, @intCast(refusal_offset)), refusal.original_location.offset);
        try std.testing.expectEqual(@as(u32, @intCast(refusal_offset + "import".len)), refusal.original_location.end_offset);
        try std.testing.expectEqual(refusal_line, refusal.original_location.line);
        try std.testing.expectEqual(refusal_column, refusal.original_location.column);
        const diagnostics = parser.getAdmissionDiagnostics();
        try std.testing.expectEqual(@as(usize, 1), diagnostics.len);
        try std.testing.expectEqual(type_syntax.AdmissionKind.legacy_types_import, diagnostics[0].kind);
        const diagnostic_position = diagnostics[0].positionIn(source);
        try std.testing.expectEqual(refusal_line, diagnostic_position.line);
        try std.testing.expectEqual(refusal_column, diagnostic_position.column);
        try std.testing.expectEqual(@as(usize, 1), parser.type_store.nodes.items.len);
        try std.testing.expectEqual(@as(usize, 1), parser.type_store.annotations.items.len);
        try std.testing.expectEqualStrings(
            "number",
            parser.type_store.annotations.items[0].raw_span.text(source),
        );
        try std.testing.expectEqual(@as(usize, 0), parser.type_store.generic_parameters.items.len);
        try std.testing.expectEqual(@as(usize, 0), parser.type_store.projected_generic_parameters.items.len);
        try std.testing.expectEqual(@as(usize, 0), parser.type_store.generic_owners.items.len);
        try std.testing.expectEqual(@as(usize, 0), parser.type_store.parameter_annotations.items.len);
        try std.testing.expectEqual(@as(usize, 0), parser.type_store.function_signatures.items.len);
        try std.testing.expectEqual(@as(usize, 0), parser.type_store.type_only_modules.items.len);
        try std.testing.expectEqual(@as(usize, 0), parser.errors.getErrors().len);
        try parser.type_store.validate();
    }
}

test "later wrapper failures remove nested type-only module records" {
    const cases = [_]struct { tail: []const u8, closing: []const u8, signatures: usize }{
        .{ .tail = "function helper<T>(value: string): string {import type { A } from \"./a\";return value;", .closing = "}", .signatures = 1 },
        .{ .tail = "const helper=<T>(value)=>{import type { A } from \"./a\";return value;", .closing = "};", .signatures = 0 },
        .{ .tail = "export const helper=<T>(value)=>{import type { A } from \"./a\";return value;", .closing = "};", .signatures = 0 },
    };
    for (cases) |case| {
        const control_source = try std.mem.concat(
            std.testing.allocator,
            u8,
            &.{ "const seed: number = 1;", case.tail, case.closing },
        );
        defer std.testing.allocator.free(control_source);
        var control_atoms = atom_table.AtomTable.init(std.testing.allocator);
        defer control_atoms.deinit();
        var control = try Parser.initAdmission(std.testing.allocator, std.testing.allocator, control_source, .compile);
        defer control.deinit();
        control.setAtomTable(&control_atoms);
        _ = try control.parse();
        try std.testing.expectEqual(@as(usize, 0), control.errors.getErrors().len);
        try std.testing.expectEqual(@as(usize, 1), control.type_store.type_only_modules.items.len);
        try std.testing.expectEqualStrings(
            "import type { A } from \"./a\";",
            control.type_store.type_only_modules.items[0].raw_span.text(control_source),
        );
        try std.testing.expectEqual(@as(usize, 1), control.type_store.generic_owners.items.len);
        try std.testing.expectEqual(case.signatures, control.type_store.function_signatures.items.len);
        try control.type_store.validateRuntimeOwners(
            std.testing.allocator,
            ir.IrView.fromIRStore(&control.nodes, &control.constants),
        );
        const source = try std.mem.concat(
            std.testing.allocator,
            u8,
            &.{ "const seed: number = 1;", case.tail },
        );
        defer std.testing.allocator.free(source);
        var atoms = atom_table.AtomTable.init(std.testing.allocator);
        defer atoms.deinit();
        var parser = try Parser.initAdmission(std.testing.allocator, std.testing.allocator, source, .compile);
        defer parser.deinit();
        parser.setAtomTable(&atoms);
        try std.testing.expectError(error.UnexpectedToken, parser.parse());
        try std.testing.expectEqual(TokenType.eof, parser.current.type);
        try std.testing.expectEqual(@as(usize, 1), parser.errors.getErrors().len);
        const diagnostic = parser.errors.getErrors()[0];
        try std.testing.expectEqual(error_mod.ErrorKind.expected_token, diagnostic.kind);
        try std.testing.expectEqualStrings("'}'", diagnostic.expected orelse return error.TestUnexpectedResult);
        try std.testing.expectEqual(@as(u32, @intCast(source.len)), diagnostic.location.offset);
        try std.testing.expectEqual(@as(u32, @intCast(source.len)), diagnostic.location.end_offset);
        try std.testing.expectEqual(@as(u32, 1), diagnostic.location.line);
        try std.testing.expectEqual(@as(u32, @intCast(source.len + 1)), diagnostic.location.column);
        try std.testing.expect(parser.type_only_module_refusal == null);
        var expected = std.mem.zeroes(type_syntax.Store.Checkpoint);
        expected.nodes = 1;
        expected.annotations = 1;
        try std.testing.expect(std.meta.eql(expected, parser.type_store.checkpoint()));
        try std.testing.expectEqualStrings(
            "number",
            parser.type_store.annotations.items[0].raw_span.text(source),
        );
        try parser.type_store.validate();
    }
    try std.testing.expectEqual(@as(usize, 3), cases.len);
}

test "admission keeps original spans and measured parameter presentation" {
    const cases = [_]struct {
        source: []const u8,
        diagnostics: []const type_syntax.AdmissionDiagnostic,
    }{
        .{
            .source = "function f(x: /* closed */ any, y: any) { return 1; }\n",
            .diagnostics = &.{
                .{ .kind = .any_type, .span = .{ .start = 35, .end = 38 }, .presentation = .{ .line = 1, .column = 38 } },
            },
        },
        .{
            .source = "function f({ x }:\n /* closed */ any, y: any) { return 1; }\n",
            .diagnostics = &.{
                .{ .kind = .any_type, .span = .{ .start = 40, .end = 43 }, .presentation = .{ .line = 3, .column = 23 } },
            },
        },
        .{
            .source = "function f({ x }: /* closed */ any, y: void) { return 1; }\n",
            .diagnostics = &.{
                .{ .kind = .void_type, .span = .{ .start = 39, .end = 43 }, .presentation = .{ .line = 1, .column = 40 } },
            },
        },
        .{
            .source = "function f({ x }:\n /* closed */ any,\n y: any) { return 1; }\n",
            .diagnostics = &.{
                .{ .kind = .any_type, .span = .{ .start = 41, .end = 44 }, .presentation = .{ .line = 4, .column = 5 } },
            },
        },
        .{
            .source = "function f(x: /* closed */ any, y = 1) { return 1; }\n",
            .diagnostics = &.{
                .{ .kind = .default_parameter, .span = .{ .start = 34, .end = 35 }, .presentation = .{ .line = 1, .column = 37 } },
            },
        },
        .{
            .source = "function f(x:\t/* closed */ any, y: any) { return 1; }\n",
            .diagnostics = &.{
                .{ .kind = .any_type, .span = .{ .start = 35, .end = 38 }, .presentation = .{ .line = 1, .column = 38 } },
            },
        },
        .{
            .source = "function f(x:\r /* closed */ any, y: any) { return 1; }\n",
            .diagnostics = &.{
                .{ .kind = .any_type, .span = .{ .start = 36, .end = 39 }, .presentation = .{ .line = 1, .column = 39 } },
            },
        },
        .{
            .source = "function f(x: /* closed */ any, y: /* closed */ any, z: any) { return 1; }\n",
            .diagnostics = &.{
                .{ .kind = .any_type, .span = .{ .start = 56, .end = 59 }, .presentation = .{ .line = 1, .column = 61 } },
            },
        },
        .{ .source = "function f(x: /* closed */ number, y: number) { return 1; }\n", .diagnostics = &.{} },
        .{
            .source = "const x:\n /* closed */ number = 1; const y: any = 1;\n",
            .diagnostics = &.{
                .{ .kind = .any_type, .span = .{ .start = 44, .end = 47 }, .presentation = .{ .line = 2, .column = 36 } },
            },
        },
        .{
            .source = "function f():\n /* closed */ number { return 1; } const y: any = 1;\n",
            .diagnostics = &.{
                .{ .kind = .any_type, .span = .{ .start = 58, .end = 61 }, .presentation = .{ .line = 2, .column = 45 } },
            },
        },
        .{
            .source = "function f(x:\r any) { return 1; }\n",
            .diagnostics = &.{
                .{ .kind = .any_type, .span = .{ .start = 15, .end = 18 }, .presentation = .{ .line = 1, .column = 15 } },
            },
        },
        .{
            .source = "const x:\r any = 1;\n",
            .diagnostics = &.{
                .{ .kind = .any_type, .span = .{ .start = 10, .end = 13 }, .presentation = .{ .line = 1, .column = 10 } },
            },
        },
        .{
            .source = "function f():\r any { return 1; }\n",
            .diagnostics = &.{
                .{ .kind = .any_type, .span = .{ .start = 15, .end = 18 }, .presentation = .{ .line = 1, .column = 15 } },
            },
        },
        .{
            .source = "function f(x?\r: any) { return 1; }\n",
            .diagnostics = &.{
                .{ .kind = .optional_parameter, .span = .{ .start = 12, .end = 13 }, .presentation = .{ .line = 1, .column = 13 } },
                .{ .kind = .any_type, .span = .{ .start = 16, .end = 19 }, .presentation = .{ .line = 1, .column = 16 } },
            },
        },
        .{
            .source = "function f(x:\r number, y: any) { return 1; }\n",
            .diagnostics = &.{
                .{ .kind = .any_type, .span = .{ .start = 26, .end = 29 }, .presentation = .{ .line = 1, .column = 26 } },
            },
        },
        .{
            .source = "const x:\r /* closed */ number = 1; const y: any = 1;\n",
            .diagnostics = &.{
                .{ .kind = .any_type, .span = .{ .start = 44, .end = 47 }, .presentation = .{ .line = 1, .column = 45 } },
            },
        },
        .{
            .source = "function f():\r /* closed */ number { return 1; } const y: any = 1;\n",
            .diagnostics = &.{
                .{ .kind = .any_type, .span = .{ .start = 58, .end = 61 }, .presentation = .{ .line = 1, .column = 58 } },
            },
        },
    };
    try std.testing.expectEqual(@as(usize, 18), cases.len);
    for (cases) |case| {
        errdefer std.debug.print("admission presentation failed: {s}\n", .{case.source});
        for ([_]type_syntax.AdmissionMode{ .collect, .compile }) |mode| {
            var parser = try Parser.initAdmission(std.testing.allocator, std.testing.allocator, case.source, mode);
            defer parser.deinit();
            const outcome = try parser.parseAdmission();
            if (case.diagnostics.len == 0) {
                const refused = switch (outcome) {
                    .parser_refused => |refusal| refusal,
                    else => return error.TestUnexpectedResult,
                };
                try std.testing.expectEqual(error.UnexpectedToken, refused.first_error);
                const errors = parser.getProjectedErrors();
                try std.testing.expectEqual(@as(usize, 1), errors.len);
                try std.testing.expectEqual(error_mod.ErrorKind.expected_token, errors[0].kind);
                try std.testing.expectEqualStrings("')'", errors[0].expected orelse return error.TestUnexpectedResult);
                try std.testing.expectEqual(@as(u32, 12), errors[0].location.offset);
                try std.testing.expectEqual(@as(u32, 13), errors[0].location.column);
            } else if (mode == .collect) {
                switch (outcome) {
                    .recovered_admission_refused => {},
                    else => return error.TestUnexpectedResult,
                }
                try std.testing.expectEqualDeep(case.diagnostics, parser.getAdmissionDiagnostics());
            } else {
                const terminal = switch (outcome) {
                    .terminal_admission_refused => |failure| switch (failure) {
                        .diagnostic => |diagnostic| diagnostic,
                        else => return error.TestUnexpectedResult,
                    },
                    else => return error.TestUnexpectedResult,
                };
                try std.testing.expectEqualDeep(case.diagnostics[0], terminal);
                try std.testing.expectEqualDeep(case.diagnostics[0], parser.getLastAdmissionObservation().?);
            }
            try parser.type_store.validate();
        }
    }
}

test "admission preserves cursor operations at function type continuations" {
    const cases = [_]struct {
        source: []const u8,
        diagnostics: []const type_syntax.AdmissionDiagnostic,
    }{
        .{
            .source = "const f: (x: any) =>\r any = value;\n",
            .diagnostics = &.{
                .{ .kind = .any_type, .span = .{ .start = 13, .end = 16 }, .presentation = .{ .line = 1, .column = 14 } },
                .{ .kind = .any_type, .span = .{ .start = 22, .end = 25 }, .presentation = .{ .line = 1, .column = 22 } },
            },
        },
        .{
            .source = "const f: (x: void) =>\r number = value;\n",
            .diagnostics = &.{
                .{ .kind = .void_type, .span = .{ .start = 13, .end = 17 }, .presentation = .{ .line = 1, .column = 14 } },
            },
        },
        .{
            .source = "const f: (x: void) =>\r any = value;\n",
            .diagnostics = &.{
                .{ .kind = .any_type, .span = .{ .start = 23, .end = 26 }, .presentation = .{ .line = 1, .column = 23 } },
                .{ .kind = .void_type, .span = .{ .start = 13, .end = 17 }, .presentation = .{ .line = 1, .column = 14 } },
            },
        },
        .{
            .source = "const f: (x: \"open\n) =>\r any = value;\n",
            .diagnostics = &.{
                .{ .kind = .unterminated_string, .span = .{ .start = 18, .end = 19 }, .presentation = .{ .line = 1, .column = 19 } },
                .{ .kind = .any_type, .span = .{ .start = 25, .end = 28 }, .presentation = .{ .line = 2, .column = 6 } },
            },
        },
        .{
            .source = "interface X extends () =>\r any {};\n",
            .diagnostics = &.{
                .{ .kind = .any_type, .span = .{ .start = 27, .end = 30 }, .presentation = .{ .line = 1, .column = 28 } },
                .{ .kind = .interface_declaration, .span = .{ .start = 0, .end = 9 }, .presentation = .{ .line = 1, .column = 1 } },
            },
        },
        .{
            .source = "const f = value as () =>\r any;\n",
            .diagnostics = &.{
                .{ .kind = .as_assertion, .span = .{ .start = 19, .end = 20 }, .presentation = .{ .line = 1, .column = 20 } },
                .{ .kind = .any_type, .span = .{ .start = 26, .end = 29 }, .presentation = .{ .line = 1, .column = 27 } },
            },
        },
        .{
            .source = "function f(x: () =>\r any) { return 1; }\n",
            .diagnostics = &.{
                .{ .kind = .any_type, .span = .{ .start = 21, .end = 24 }, .presentation = .{ .line = 1, .column = 22 } },
            },
        },
        .{
            .source = "function f(): () =>\r any { return value; }\n",
            .diagnostics = &.{
                .{ .kind = .any_type, .span = .{ .start = 21, .end = 24 }, .presentation = .{ .line = 1, .column = 21 } },
            },
        },
    };
    try std.testing.expectEqual(@as(usize, 8), cases.len);
    for (cases) |case| {
        errdefer std.debug.print("function type presentation failed: {s}\n", .{case.source});
        for ([_]type_syntax.AdmissionMode{ .collect, .compile }) |mode| {
            var parser = try Parser.initAdmission(std.testing.allocator, std.testing.allocator, case.source, mode);
            defer parser.deinit();
            const outcome = try parser.parseAdmission();
            if (mode == .collect) {
                switch (outcome) {
                    .recovered_admission_refused => {},
                    else => return error.TestUnexpectedResult,
                }
                try std.testing.expectEqualDeep(case.diagnostics, parser.getAdmissionDiagnostics());
            } else {
                const terminal = switch (outcome) {
                    .terminal_admission_refused => |failure| switch (failure) {
                        .diagnostic => |diagnostic| diagnostic,
                        else => return error.TestUnexpectedResult,
                    },
                    else => return error.TestUnexpectedResult,
                };
                var selected: ?type_syntax.AdmissionDiagnostic = null;
                for (case.diagnostics) |diagnostic| {
                    if (diagnostic.kind == .unterminated_string) continue;
                    selected = diagnostic;
                    break;
                }
                try std.testing.expectEqualDeep(selected orelse return error.TestUnexpectedResult, terminal);
                try std.testing.expectEqualDeep(terminal, parser.getLastAdmissionObservation().?);
            }
            try parser.type_store.validate();
        }
    }
}

test "admission preserves runtime prefixes and excludes commented parameter producers" {
    const cases = [_]struct {
        source: []const u8,
        parser_error: ?anyerror = null,
        parser_kind: ?error_mod.ErrorKind = null,
        parser_column: u32 = 0,
        diagnostics: []const type_syntax.AdmissionDiagnostic,
    }{
        .{ .source = "const seed =\r 1; const later: any = 1;\n", .diagnostics = &.{
            .{ .kind = .any_type, .span = .{ .start = 30, .end = 33 }, .presentation = .{ .line = 1, .column = 30 } },
        } },
        .{ .source = "const seed = 1 ===\r 1; const later: any = 1;\n", .diagnostics = &.{
            .{ .kind = .any_type, .span = .{ .start = 36, .end = 39 }, .presentation = .{ .line = 1, .column = 36 } },
        } },
        .{ .source = "function f(x =\r 1, y: any) { return 1; }\n", .diagnostics = &.{
            .{ .kind = .default_parameter, .span = .{ .start = 13, .end = 14 }, .presentation = .{ .line = 1, .column = 14 } },
            .{ .kind = .any_type, .span = .{ .start = 22, .end = 25 }, .presentation = .{ .line = 1, .column = 23 } },
        } },
        .{ .source = "function\r f(x: any) { return 1; }\n", .diagnostics = &.{
            .{ .kind = .any_type, .span = .{ .start = 15, .end = 18 }, .presentation = .{ .line = 1, .column = 15 } },
        } },
        .{ .source = "function f\r(x: any) { return 1; }\n", .diagnostics = &.{
            .{ .kind = .any_type, .span = .{ .start = 15, .end = 18 }, .presentation = .{ .line = 1, .column = 15 } },
        } },
        .{ .source = "const f = function\r (x: any) { return 1; };\n", .diagnostics = &.{
            .{ .kind = .any_type, .span = .{ .start = 24, .end = 27 }, .presentation = .{ .line = 1, .column = 24 } },
        } },
        .{ .source = "function f<T>\r(x: any) { return 1; }\n", .diagnostics = &.{
            .{ .kind = .any_type, .span = .{ .start = 18, .end = 21 }, .presentation = .{ .line = 1, .column = 18 } },
        } },
        .{ .source = "function f<T>\r; const later: any = 1;\n", .diagnostics = &.{
            .{ .kind = .any_type, .span = .{ .start = 29, .end = 32 }, .presentation = .{ .line = 1, .column = 29 } },
        } },
        .{ .source = "const f = <T>\r(x: any) => x;\n", .diagnostics = &.{
            .{ .kind = .any_type, .span = .{ .start = 18, .end = 21 }, .presentation = .{ .line = 1, .column = 18 } },
        } },
        .{ .source = "const f = <T>\r value; const later: any = 1;\n", .diagnostics = &.{
            .{ .kind = .any_type, .span = .{ .start = 35, .end = 38 }, .presentation = .{ .line = 1, .column = 36 } },
        } },
        .{ .source = "const f = id<T>\r(1); const later: any = 1;\n", .diagnostics = &.{
            .{ .kind = .any_type, .span = .{ .start = 34, .end = 37 }, .presentation = .{ .line = 1, .column = 35 } },
        } },
        .{ .source = "const seed = value as\r any;\n", .diagnostics = &.{
            .{ .kind = .as_assertion, .span = .{ .start = 23, .end = 26 }, .presentation = .{ .line = 1, .column = 23 } },
        } },
        .{ .source = "const seed = value satisfies\r any;\n", .diagnostics = &.{
            .{ .kind = .satisfies_assertion, .span = .{ .start = 30, .end = 33 }, .presentation = .{ .line = 1, .column = 30 } },
        } },
        .{ .source = "function/* gap */f<T>(x =\r 1, y: any) { return 1; }\n", .parser_error = error.ParseError, .parser_kind = .unsupported_feature, .parser_column = 25, .diagnostics = &.{} },
        .{ .source = "function/* gap */f<T>(x?\r: any) { return 1; }\n", .parser_error = error.UnexpectedToken, .parser_kind = .expected_token, .parser_column = 24, .diagnostics = &.{} },
        .{ .source = "function/* gap */f(x =\r 1, y: any) { return 1; }\n", .parser_error = error.ParseError, .parser_kind = .unsupported_feature, .parser_column = 22, .diagnostics = &.{} },
        .{ .source = "function f<T>/* gap */(x =\r 1, y: any) { return 1; }\n", .parser_error = error.ParseError, .parser_kind = .unsupported_feature, .parser_column = 26, .diagnostics = &.{} },
        .{ .source = "function/* gap */f<T>({x}: /* gap */ number, y: any) { return 1; }\n", .parser_error = error.ParseError, .parser_kind = .unsupported_feature, .parser_column = 23, .diagnostics = &.{} },
        .{ .source = "function/* gap */f(x: any) { return 1; }\n", .parser_error = error.UnexpectedToken, .parser_kind = .expected_token, .parser_column = 21, .diagnostics = &.{} },
        .{ .source = "function f/* gap */(x: any) { return 1; }\n", .parser_error = error.UnexpectedToken, .parser_kind = .expected_token, .parser_column = 22, .diagnostics = &.{} },
        .{ .source = "function f/* gap */(x?: any) { return 1; }\n", .parser_error = error.UnexpectedToken, .parser_kind = .expected_token, .parser_column = 22, .diagnostics = &.{} },
        .{ .source = "function f/* gap */(x =\r 1, y: any) { return 1; }\n", .parser_error = error.ParseError, .parser_kind = .unsupported_feature, .parser_column = 23, .diagnostics = &.{} },
        .{ .source = "function f<T = string>\r; const later: any = 1;\n", .diagnostics = &.{
            .{ .kind = .any_type, .span = .{ .start = 38, .end = 41 }, .presentation = .{ .line = 1, .column = 38 } },
        } },
        .{ .source = "function f<T = string>\r; const seed =\r1; const later: any = 1;\n", .diagnostics = &.{
            .{ .kind = .any_type, .span = .{ .start = 54, .end = 57 }, .presentation = .{ .line = 1, .column = 53 } },
        } },
        .{ .source = "function f(x: number) { const seed =\r1; const later: any = 1; }\n", .diagnostics = &.{
            .{ .kind = .any_type, .span = .{ .start = 53, .end = 56 }, .presentation = .{ .line = 1, .column = 53 } },
        } },
        .{ .source = "function f(x: /* gap */ number) {} const seed =\r1; const later: any = 1;\n", .diagnostics = &.{
            .{ .kind = .any_type, .span = .{ .start = 64, .end = 67 }, .presentation = .{ .line = 1, .column = 66 } },
        } },
        .{ .source = "const f = function(x: number) { return 1; };\n", .parser_error = error.ParseError, .parser_kind = .unsupported_feature, .parser_column = 11, .diagnostics = &.{} },
        .{ .source = "const f = function(x?: any) { return 1; };\n", .diagnostics = &.{
            .{ .kind = .optional_parameter, .span = .{ .start = 20, .end = 21 }, .presentation = .{ .line = 1, .column = 21 } },
            .{ .kind = .any_type, .span = .{ .start = 23, .end = 26 }, .presentation = .{ .line = 1, .column = 24 } },
        } },
        .{ .source = "const f = function(x = 1, y: any) { return 1; };\n", .diagnostics = &.{
            .{ .kind = .default_parameter, .span = .{ .start = 21, .end = 22 }, .presentation = .{ .line = 1, .column = 22 } },
            .{ .kind = .any_type, .span = .{ .start = 29, .end = 32 }, .presentation = .{ .line = 1, .column = 30 } },
        } },
        .{ .source = "const f = function<T>\r(x: any) { return 1; };\n", .diagnostics = &.{
            .{ .kind = .any_type, .span = .{ .start = 26, .end = 29 }, .presentation = .{ .line = 1, .column = 26 } },
        } },
        .{ .source = "const f = function g<T>\r(x: any) { return 1; };\n", .diagnostics = &.{
            .{ .kind = .any_type, .span = .{ .start = 28, .end = 31 }, .presentation = .{ .line = 1, .column = 28 } },
        } },
        .{ .source = "const f = function/* gap */(x: any) { return 1; };\n", .parser_error = error.ParseError, .parser_kind = .unsupported_feature, .parser_column = 11, .diagnostics = &.{} },
        .{ .source = "function f<T as number>\r; const later: any = 1;\n", .diagnostics = &.{
            .{ .kind = .any_type, .span = .{ .start = 39, .end = 42 }, .presentation = .{ .line = 1, .column = 39 } },
        } },
        .{ .source = "function f<T = string>\r;\n", .parser_error = error.UnexpectedToken, .parser_kind = .expected_token, .parser_column = 24, .diagnostics = &.{} },
    };
    try std.testing.expectEqual(@as(usize, 34), cases.len);
    for (cases) |case| {
        errdefer std.debug.print("runtime presentation failed: {s}\n", .{case.source});
        for ([_]type_syntax.AdmissionMode{ .collect, .compile }) |mode| {
            var parser = try Parser.initAdmission(std.testing.allocator, std.testing.allocator, case.source, mode);
            defer parser.deinit();
            const outcome = try parser.parseAdmission();
            if (case.parser_error) |expected_error| {
                const refused = switch (outcome) {
                    .parser_refused => |value| value,
                    else => return error.TestUnexpectedResult,
                };
                try std.testing.expectEqual(expected_error, refused.first_error);
                const errors = parser.getProjectedErrors();
                try std.testing.expectEqual(@as(usize, 1), errors.len);
                try std.testing.expectEqual(case.parser_kind.?, errors[0].kind);
                try std.testing.expectEqual(@as(u32, 1), errors[0].location.line);
                try std.testing.expectEqual(case.parser_column, errors[0].location.column);
                try std.testing.expectEqual(@as(usize, 0), parser.getAdmissionDiagnostics().len);
                try std.testing.expect(parser.getLastAdmissionObservation() == null);
            } else if (mode == .collect) {
                switch (outcome) {
                    .recovered_admission_refused => {},
                    else => return error.TestUnexpectedResult,
                }
                try std.testing.expectEqualDeep(case.diagnostics, parser.getAdmissionDiagnostics());
            } else {
                const diagnostic = switch (outcome) {
                    .terminal_admission_refused => |failure| switch (failure) {
                        .diagnostic => |value| value,
                        else => return error.TestUnexpectedResult,
                    },
                    else => return error.TestUnexpectedResult,
                };
                try std.testing.expectEqualDeep(case.diagnostics[0], diagnostic);
                try std.testing.expectEqualDeep(diagnostic, parser.getLastAdmissionObservation().?);
            }
            try parser.type_store.validate();
        }
    }
}

test "committed named generics retain unfinished survivor comments" {
    const source = "function f<T> /* unfinished\n";
    for ([_]type_syntax.AdmissionMode{ .collect, .compile }) |mode| {
        var parser = try Parser.initAdmission(std.testing.allocator, std.testing.allocator, source, mode);
        defer parser.deinit();
        const failure = switch (try parser.parseAdmission()) {
            .terminal_admission_refused => |failure| switch (failure) {
                .unterminated_comment => |comment| comment,
                else => return error.TestUnexpectedResult,
            },
            else => return error.TestUnexpectedResult,
        };
        try std.testing.expectEqual(@as(u32, @intCast(std.mem.indexOf(u8, source, "/*").?)), failure.opener);
        try std.testing.expectEqual(@as(usize, 0), parser.getAdmissionDiagnostics().len);
        try std.testing.expect(parser.getLastAdmissionObservation() == null);
        try std.testing.expectEqualDeep(std.mem.zeroes(type_syntax.Store.Checkpoint), parser.type_store.checkpoint());
    }
}

test "function expression recovery cleans pending syntax through allocation failures" {
    for ([_]type_syntax.AdmissionMode{ .collect, .compile }) |mode| {
        try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
            fn run(allocator: std.mem.Allocator, admission_mode: type_syntax.AdmissionMode) !void {
                const source = "const f = function<T>(x: T, y: any): T { return x; };\n";
                var parser = try Parser.initAdmission(allocator, allocator, source, admission_mode);
                defer parser.deinit();
                const outcome = parser.parseAdmission() catch |err| {
                    switch (err) {
                        error.OutOfMemory => {
                            try std.testing.expectEqual(scope_mod.ScopeKind.global, parser.scopes.getCurrentScope().kind);
                            try std.testing.expectEqualDeep(std.mem.zeroes(type_syntax.Store.Checkpoint), parser.type_store.checkpoint());
                        },
                        else => {},
                    }
                    return err;
                };
                switch (outcome) {
                    .recovered_admission_refused => {
                        try std.testing.expectEqual(type_syntax.AdmissionMode.collect, admission_mode);
                        try std.testing.expectEqual(@as(usize, 1), parser.getAdmissionDiagnostics().len);
                        try std.testing.expectEqual(type_syntax.AdmissionKind.any_type, parser.getAdmissionDiagnostics()[0].kind);
                    },
                    .terminal_admission_refused => |failure| {
                        try std.testing.expectEqual(type_syntax.AdmissionMode.compile, admission_mode);
                        switch (failure) {
                            .diagnostic => |diagnostic| try std.testing.expectEqual(type_syntax.AdmissionKind.any_type, diagnostic.kind),
                            else => return error.TestUnexpectedResult,
                        }
                    },
                    else => return error.TestUnexpectedResult,
                }
                try std.testing.expectEqual(scope_mod.ScopeKind.global, parser.scopes.getCurrentScope().kind);
                try std.testing.expectEqualDeep(std.mem.zeroes(type_syntax.Store.Checkpoint), parser.type_store.checkpoint());
                try parser.type_store.validate();
            }
        }.run, .{mode});
    }
}

test "admission captures absent structural aliases before comments" {
    const cases = [_][]const u8{
        "structural X/* c */\nconst live = 1;\n",
        "structural X<T>/* c */\nconst live = 1;\n",
        "structural X\r /* c */\nconst live = 1;\n",
        "export structural X<T> // c\nconst live = 1;\n",
    };
    try std.testing.expectEqual(@as(usize, 4), cases.len);
    for (cases) |source| {
        for ([_]type_syntax.AdmissionMode{ .collect, .compile }) |mode| {
            var parser = try Parser.initAdmission(std.testing.allocator, std.testing.allocator, source, mode);
            defer parser.deinit();
            const root = switch (try parser.parseAdmission()) {
                .accepted => |value| value,
                else => return error.TestUnexpectedResult,
            };
            const view = ir.IrView.fromIRStore(&parser.nodes, &parser.constants);
            const program = view.getBlock(root).?;
            try std.testing.expectEqual(NodeTag.program, view.getTag(root).?);
            try std.testing.expectEqual(@as(u16, 1), program.stmts_count);
            const surviving_index = parser.nodes.getListIndex(program.stmts_start, 0);
            try std.testing.expectEqual(NodeTag.var_decl, view.getTag(surviving_index).?);
            try std.testing.expectEqual(@as(u32, @intCast(std.mem.indexOf(u8, source, "const live").?)), view.getLoc(surviving_index).?.offset);
            const initializer = view.getVarDecl(surviving_index).?.init;
            try std.testing.expectEqual(NodeTag.lit_int, view.getTag(initializer).?);
            try std.testing.expectEqual(@as(i32, 1), view.getIntValue(initializer).?);

            try std.testing.expectEqual(@as(usize, 0), parser.getAdmissionDiagnostics().len);
            try std.testing.expect(parser.getLastAdmissionObservation() == null);
            try std.testing.expectEqual(@as(usize, 1), parser.type_store.declarations.items.len);
            const declaration = parser.type_store.declarations.items[0];
            switch (declaration.body) {
                .absent => {},
                else => return error.TestUnexpectedResult,
            }
            try std.testing.expectEqual(@as(u32, @intCast(std.mem.indexOfScalar(u8, source, '/').?)), declaration.full_span.end);
            const generic = std.mem.indexOfScalar(u8, source, '<') != null;
            try std.testing.expectEqual(generic, declaration.generic_owner != null);
            try parser.type_store.validate();
        }
    }
}

test "admission preserves measured declaration prefixes and saved origins" {
    const cases = [_]struct {
        source: []const u8,
        parser_error: ?anyerror = null,
        parser_kind: ?error_mod.ErrorKind = null,
        parser_column: u32 = 0,
        diagnostics: []const type_syntax.AdmissionDiagnostic,
    }{
        .{ .source = "structural\r X = number; const later: any = 1;\n", .diagnostics = &.{
            .{ .kind = .any_type, .span = .{ .start = 37, .end = 40 }, .presentation = .{ .line = 1, .column = 37 } },
        } },
        .{ .source = "structural X\r = number; const later: any = 1;\n", .diagnostics = &.{
            .{ .kind = .any_type, .span = .{ .start = 37, .end = 40 }, .presentation = .{ .line = 1, .column = 37 } },
        } },
        .{ .source = "structural X<T>\r = number; const later: any = 1;\n", .diagnostics = &.{
            .{ .kind = .any_type, .span = .{ .start = 40, .end = 43 }, .presentation = .{ .line = 1, .column = 40 } },
        } },
        .{ .source = "structural X =\r number; const later: any = 1;\n", .diagnostics = &.{
            .{ .kind = .any_type, .span = .{ .start = 37, .end = 40 }, .presentation = .{ .line = 1, .column = 37 } },
        } },
        .{ .source = "structural X = number\n\r; const later: any = 1;\n", .diagnostics = &.{
            .{ .kind = .any_type, .span = .{ .start = 38, .end = 41 }, .presentation = .{ .line = 2, .column = 16 } },
        } },
        .{ .source = "nominal N =\r any;\n", .diagnostics = &.{
            .{ .kind = .any_type, .span = .{ .start = 13, .end = 16 }, .presentation = .{ .line = 1, .column = 13 } },
        } },
        .{ .source = "interface X extends\r any {};\n", .diagnostics = &.{
            .{ .kind = .any_type, .span = .{ .start = 21, .end = 24 }, .presentation = .{ .line = 1, .column = 21 } },
            .{ .kind = .interface_declaration, .span = .{ .start = 0, .end = 9 }, .presentation = .{ .line = 1, .column = 1 } },
        } },
        .{ .source = "export\r structural X = number; const later: any = 1;\n", .diagnostics = &.{
            .{ .kind = .any_type, .span = .{ .start = 44, .end = 47 }, .presentation = .{ .line = 1, .column = 44 } },
        } },
    };
    try std.testing.expectEqual(@as(usize, 8), cases.len);
    for (cases) |case| {
        errdefer std.debug.print("declaration presentation failed: {s}\n", .{case.source});
        for ([_]type_syntax.AdmissionMode{ .collect, .compile }) |mode| {
            var parser = try Parser.initAdmission(std.testing.allocator, std.testing.allocator, case.source, mode);
            defer parser.deinit();
            const outcome = try parser.parseAdmission();
            if (case.parser_error) |expected_error| {
                const refused = switch (outcome) {
                    .parser_refused => |value| value,
                    else => return error.TestUnexpectedResult,
                };
                try std.testing.expectEqual(expected_error, refused.first_error);
                const errors = parser.getProjectedErrors();
                try std.testing.expectEqual(@as(usize, 1), errors.len);
                try std.testing.expectEqual(case.parser_kind.?, errors[0].kind);
                try std.testing.expectEqual(@as(u32, 1), errors[0].location.line);
                try std.testing.expectEqual(case.parser_column, errors[0].location.column);
                try std.testing.expectEqual(@as(usize, 0), parser.getAdmissionDiagnostics().len);
                try std.testing.expect(parser.getLastAdmissionObservation() == null);
            } else if (mode == .collect) {
                switch (outcome) {
                    .recovered_admission_refused => {},
                    else => return error.TestUnexpectedResult,
                }
                try std.testing.expectEqualDeep(case.diagnostics, parser.getAdmissionDiagnostics());
            } else {
                const diagnostic = switch (outcome) {
                    .terminal_admission_refused => |failure| switch (failure) {
                        .diagnostic => |value| value,
                        else => return error.TestUnexpectedResult,
                    },
                    else => return error.TestUnexpectedResult,
                };
                try std.testing.expectEqualDeep(case.diagnostics[0], diagnostic);
                try std.testing.expectEqualDeep(diagnostic, parser.getLastAdmissionObservation().?);
            }
            try parser.type_store.validate();
        }
    }
}

test "admission preserves measured module export and operand prefixes" {
    const cases = [_]struct {
        source: []const u8,
        fatal: bool,
        diagnostics: []const type_syntax.AdmissionDiagnostic,
    }{
        .{ .source = "import\r { value } from './x.ts'; const later: any = 1;\n", .fatal = false, .diagnostics = &.{
            .{ .kind = .any_type, .span = .{ .start = 46, .end = 49 }, .presentation = .{ .line = 1, .column = 47 } },
        } },
        .{ .source = "export type\r { X }; const later: any = 1;\n", .fatal = false, .diagnostics = &.{
            .{ .kind = .any_type, .span = .{ .start = 33, .end = 36 }, .presentation = .{ .line = 1, .column = 34 } },
        } },
        .{ .source = "import\r type { X } from \"open\nconst later: any = 1;\n", .fatal = false, .diagnostics = &.{
            .{ .kind = .unterminated_string, .span = .{ .start = 29, .end = 30 }, .presentation = .{ .line = 1, .column = 29 } },
            .{ .kind = .any_type, .span = .{ .start = 43, .end = 46 }, .presentation = .{ .line = 2, .column = 14 } },
        } },
        .{ .source = "const seed =\r1;import\r type { X } from '" ++ retired_types_module ++ "';\n", .fatal = true, .diagnostics = &.{
            .{ .kind = .legacy_types_import, .span = .{ .start = 15, .end = 21 }, .presentation = .{ .line = 1, .column = 15 } },
        } },
        .{ .source = "import\r type `${\"open\n}` from '" ++ retired_types_module ++ "';\n", .fatal = true, .diagnostics = &.{
            .{ .kind = .legacy_types_import, .span = .{ .start = 0, .end = 6 }, .presentation = .{ .line = 1, .column = 1 } },
        } },
        .{ .source = "const seed =\r1;export\r default\r 1; const later: any = 1;\n", .fatal = false, .diagnostics = &.{
            .{ .kind = .default_export, .span = .{ .start = 15, .end = 21 }, .presentation = .{ .line = 1, .column = 15 } },
            .{ .kind = .any_type, .span = .{ .start = 48, .end = 51 }, .presentation = .{ .line = 1, .column = 46 } },
        } },
        .{ .source = "export\r const seed = 1; const later: any = 1;\n", .fatal = false, .diagnostics = &.{
            .{ .kind = .any_type, .span = .{ .start = 37, .end = 40 }, .presentation = .{ .line = 1, .column = 38 } },
        } },
        .{ .source = "const value = <T>\r(1); const later: any = 1;\n", .fatal = false, .diagnostics = &.{
            .{ .kind = .any_type, .span = .{ .start = 36, .end = 39 }, .presentation = .{ .line = 1, .column = 36 } },
        } },
        .{ .source = "const value = <T>\r{ ok: 1 }; const later: any = 1;\n", .fatal = false, .diagnostics = &.{
            .{ .kind = .any_type, .span = .{ .start = 42, .end = 45 }, .presentation = .{ .line = 1, .column = 42 } },
        } },
        .{ .source = "<T>\r{ const later: any = 1; }\n", .fatal = false, .diagnostics = &.{
            .{ .kind = .any_type, .span = .{ .start = 19, .end = 22 }, .presentation = .{ .line = 1, .column = 19 } },
        } },
        .{ .source = "const value = <T>\r(1 + ); const later: any = 1;\n", .fatal = false, .diagnostics = &.{
            .{ .kind = .any_type, .span = .{ .start = 39, .end = 42 }, .presentation = .{ .line = 1, .column = 39 } },
        } },
        .{ .source = "const value = <T>\r/* gap */(1); const later: any = 1;\n", .fatal = false, .diagnostics = &.{
            .{ .kind = .any_type, .span = .{ .start = 45, .end = 48 }, .presentation = .{ .line = 1, .column = 46 } },
        } },
        .{ .source = "const value = <T>\r extends Missing; const later: any = 1;\n", .fatal = false, .diagnostics = &.{
            .{ .kind = .any_type, .span = .{ .start = 49, .end = 52 }, .presentation = .{ .line = 1, .column = 49 } },
        } },
        .{ .source = "import\r type { X } from './x.ts'; const later: any = 1;\n", .fatal = false, .diagnostics = &.{
            .{ .kind = .any_type, .span = .{ .start = 47, .end = 50 }, .presentation = .{ .line = 1, .column = 47 } },
        } },
        .{ .source = "export\r type { X } from './x.ts'; const later: any = 1;\n", .fatal = false, .diagnostics = &.{
            .{ .kind = .any_type, .span = .{ .start = 47, .end = 50 }, .presentation = .{ .line = 1, .column = 47 } },
        } },
        .{ .source = "export\r default\r 1; const later: any = 1;\n", .fatal = false, .diagnostics = &.{
            .{ .kind = .default_export, .span = .{ .start = 0, .end = 6 }, .presentation = .{ .line = 1, .column = 1 } },
            .{ .kind = .any_type, .span = .{ .start = 33, .end = 36 }, .presentation = .{ .line = 1, .column = 32 } },
        } },
        .{ .source = "export\r let value: any = 1;\n", .fatal = false, .diagnostics = &.{
            .{ .kind = .mutable_export, .span = .{ .start = 0, .end = 6 }, .presentation = .{ .line = 1, .column = 1 } },
            .{ .kind = .any_type, .span = .{ .start = 19, .end = 22 }, .presentation = .{ .line = 1, .column = 19 } },
        } },
    };
    try std.testing.expectEqual(@as(usize, 17), cases.len);
    for (cases) |case| {
        errdefer std.debug.print("module presentation failed: {s}\n", .{case.source});
        for ([_]type_syntax.AdmissionMode{ .collect, .compile }) |mode| {
            var parser = try Parser.initAdmission(std.testing.allocator, std.testing.allocator, case.source, mode);
            defer parser.deinit();
            const outcome = try parser.parseAdmission();
            if (mode == .collect and !case.fatal) {
                switch (outcome) {
                    .recovered_admission_refused => {},
                    else => return error.TestUnexpectedResult,
                }
                try std.testing.expectEqualDeep(case.diagnostics, parser.getAdmissionDiagnostics());
            } else {
                const diagnostic = switch (outcome) {
                    .terminal_admission_refused => |failure| switch (failure) {
                        .diagnostic => |value| value,
                        else => return error.TestUnexpectedResult,
                    },
                    else => return error.TestUnexpectedResult,
                };
                const expected = for (case.diagnostics) |item| {
                    if (item.kind != .unterminated_string) break item;
                } else return error.TestUnexpectedResult;
                try std.testing.expectEqualDeep(expected, diagnostic);
            }
            try parser.type_store.validate();
        }
    }
}

test "retired module refusal retains caught history under its selected prefix" {
    const source = "import\r type `${\"open\n}` from '" ++ retired_types_module ++ "';\n";
    for ([_]type_syntax.AdmissionMode{ .collect, .compile }) |mode| {
        var parser = try Parser.initAdmission(std.testing.allocator, std.testing.allocator, source, mode);
        defer parser.deinit();
        const diagnostic = switch (try parser.parseAdmission()) {
            .terminal_admission_refused => |failure| switch (failure) {
                .diagnostic => |value| value,
                else => return error.TestUnexpectedResult,
            },
            else => return error.TestUnexpectedResult,
        };
        try std.testing.expectEqual(type_syntax.AdmissionKind.legacy_types_import, diagnostic.kind);
        const history = parser.admission_observations.?.items();
        try std.testing.expectEqual(@as(usize, 2), history.len);
        try std.testing.expectEqualDeep(type_syntax.AdmissionDiagnostic{
            .kind = .unterminated_string,
            .span = .{ .start = 21, .end = 22 },
            .presentation = .{ .line = 1, .column = 21 },
        }, history[0]);
        try std.testing.expectEqualDeep(diagnostic, history[1]);
        try std.testing.expectEqual(@as(usize, 1), parser.getAdmissionDiagnostics().len);
        try std.testing.expectEqualDeep(diagnostic, parser.getAdmissionDiagnostics()[0]);
        try std.testing.expectEqual(@as(u32, 1), diagnostic.positionIn(source).column);
    }
}

test "admission spaced function lists retain call arguments and runtime headers" {
    const source = "function id <T>(x) { return x; }\n";
    for ([_]type_syntax.AdmissionMode{ .collect, .compile }) |mode| {
        var parser = try Parser.initAdmission(std.testing.allocator, std.testing.allocator, source, mode);
        defer parser.deinit();
        const root = switch (try parser.parseAdmission()) {
            .accepted => |value| value,
            else => return error.TestUnexpectedResult,
        };
        const view = ir.IrView.fromIRStore(&parser.nodes, &parser.constants);
        const program = view.getBlock(root).?;
        try std.testing.expectEqual(@as(u16, 1), program.stmts_count);
        const wrapper = parser.nodes.getListIndex(program.stmts_start, 0);
        try std.testing.expectEqual(NodeTag.function_decl, view.getTag(wrapper).?);
        const function = view.getVarDecl(wrapper).?.init;

        try std.testing.expectEqual(NodeTag.function_expr, view.getTag(function).?);
        try std.testing.expectEqual(@as(usize, 1), parser.type_store.generic_owners.items.len);
        const owner = parser.type_store.generic_owners.items[0];
        switch (owner.identity) {
            .function => |node| try std.testing.expectEqual(function, node),
            else => return error.TestUnexpectedResult,
        }
        try std.testing.expectEqualStrings("<T>", owner.list_span.text(source));
        try std.testing.expectEqualStrings("T", owner.capture_spans.legacy_recorded_span.text(source));
        try std.testing.expectEqual(@as(u32, 1), owner.authored_parameters.count);
        try std.testing.expectEqual(@as(u32, 1), owner.projected_parameters.count);
        const arguments = switch (owner.compatibility) {
            .legacy_call_arguments => |value| value,
            else => return error.TestUnexpectedResult,
        };
        try std.testing.expectEqual(@as(u32, 1), arguments.authored_arguments.count);
        try std.testing.expectEqual(@as(u32, 1), arguments.semantic_fragments.count);
        try std.testing.expectEqualStrings("T", parser.type_store.authored_call_arguments.items[arguments.authored_arguments.start].full_span.text(source));
        try std.testing.expectEqual(@as(usize, 0), parser.type_store.function_signatures.items.len);
        try std.testing.expectEqual(@as(usize, 0), parser.getAdmissionDiagnostics().len);
        try parser.type_store.validateRuntimeOwners(std.testing.allocator, view);
    }
    const refused_cases = [_]struct { source: []const u8, column: u32 }{
        .{ .source = "function id <T>(x: T): T { return x; }\n", .column = 18 },
        .{ .source = "function id <T> (x) { return x; }\n", .column = 13 },
    };
    try std.testing.expectEqual(@as(usize, 2), refused_cases.len);
    for (refused_cases) |case| {
        for ([_]type_syntax.AdmissionMode{ .collect, .compile }) |mode| {
            var parser = try Parser.initAdmission(std.testing.allocator, std.testing.allocator, case.source, mode);
            defer parser.deinit();
            const refusal = switch (try parser.parseAdmission()) {
                .parser_refused => |value| value,
                else => return error.TestUnexpectedResult,
            };
            try std.testing.expectEqual(error.UnexpectedToken, refusal.first_error);
            const errors = parser.getProjectedErrors();
            try std.testing.expectEqual(@as(usize, 1), errors.len);
            try std.testing.expectEqual(error_mod.ErrorKind.expected_token, errors[0].kind);
            try std.testing.expectEqual(@as(u32, 1), errors[0].location.line);
            try std.testing.expectEqual(case.column, errors[0].location.column);
            try std.testing.expectEqual(@as(usize, 0), parser.type_store.generic_owners.items.len);
            try std.testing.expectEqual(@as(usize, 0), parser.type_store.function_signatures.items.len);
            try parser.type_store.validate();
        }
    }
}

test "admission declaration names retain the existing keyword vocabulary" {
    const names = [_][]const u8{ "true", "null", "undefined", "function" };
    try std.testing.expectEqual(@as(usize, 4), names.len);
    for (names) |name| {
        const source = try std.testing.allocator.print("structural {s} = number;\nconst live = 1;\n", .{name});
        defer std.testing.allocator.free(source);
        for ([_]type_syntax.AdmissionMode{ .collect, .compile }) |mode| {
            var parser = try Parser.initAdmission(std.testing.allocator, std.testing.allocator, source, mode);
            defer parser.deinit();
            const root = switch (try parser.parseAdmission()) {
                .accepted => |value| value,
                else => return error.TestUnexpectedResult,
            };
            try std.testing.expectEqual(@as(usize, 1), parser.type_store.declarations.items.len);
            try std.testing.expectEqualStrings(name, parser.type_store.declarations.items[0].name_span.text(source));
            const view = ir.IrView.fromIRStore(&parser.nodes, &parser.constants);
            const program = view.getBlock(root).?;
            try std.testing.expectEqual(@as(u16, 1), program.stmts_count);
            try std.testing.expectEqual(NodeTag.var_decl, parser.nodes.getTag(parser.nodes.getListIndex(program.stmts_start, 0)));
            try parser.type_store.validateRuntimeOwners(std.testing.allocator, view);
        }
    }
}

test "spaced function allocation failures preserve the prior declaration" {
    const source = "structural Seed = number;\nfunction id <T>(x) { return x; }\n";
    const Context = struct {
        fn run(type_allocator: std.mem.Allocator, mode: type_syntax.AdmissionMode, seed: type_syntax.Store.Checkpoint, function_start: u32, later_failures: *usize) !void {
            var parser = try Parser.initAdmission(std.testing.allocator, type_allocator, source, mode);
            defer parser.deinit();
            const outcome = parser.parseAdmission() catch |err| {
                switch (err) {
                    error.OutOfMemory => if (parser.current.start >= function_start) {
                        later_failures.* += 1;
                        try std.testing.expectEqual(scope_mod.ScopeKind.global, parser.scopes.getCurrentScope().kind);
                        try std.testing.expectEqualDeep(seed, parser.type_store.checkpoint());
                        try parser.type_store.validate();
                    },
                    else => {},
                }
                return err;
            };
            switch (outcome) {
                .accepted => {},
                else => return error.TestUnexpectedResult,
            }
            try std.testing.expectEqual(@as(usize, 1), parser.type_store.declarations.items.len);
            try std.testing.expectEqual(@as(usize, 1), parser.type_store.generic_owners.items.len);
            try parser.type_store.validateRuntimeOwners(std.testing.allocator, ir.IrView.fromIRStore(&parser.nodes, &parser.constants));
        }
    };
    for ([_]type_syntax.AdmissionMode{ .collect, .compile }) |mode| {
        var baseline = try Parser.initAdmission(std.testing.allocator, std.testing.allocator, source, mode);
        defer baseline.deinit();
        try std.testing.expect(try baseline.tryConsumeTypeDeclaration());
        const seed = baseline.type_store.checkpoint();
        try std.testing.expect(seed.declarations > 0);
        try std.testing.expect(seed.nodes > 0);
        try std.testing.expectEqualStrings("function", baseline.current.text(source));
        var later_failures: usize = 0;
        try std.testing.checkAllAllocationFailures(std.testing.allocator, Context.run, .{ mode, seed, baseline.current.start, &later_failures });
        try std.testing.expect(later_failures > 0);
    }
}

test "recovery allocation failures retain native errors after observation and erasure" {
    const source =
        "function f() {\n" ++
        "import type { A } /* ; */ from \"./a\";\n" ++
        "const live: \"const\" = 1;\n" ++
        "const later: any = 1;\n" ++
        "structural Box = string;\n" ++
        "}\n";
    const Floors = struct { after_observation: usize = 0, after_erasure: usize = 0 };
    const Context = struct {
        fn run(type_allocator: std.mem.Allocator, mode: type_syntax.AdmissionMode, floors: *Floors) !void {
            var parser = try Parser.initAdmission(std.testing.allocator, type_allocator, source, mode);
            defer parser.deinit();
            const outcome = parser.parseAdmission() catch |err| {
                switch (err) {
                    error.OutOfMemory => {
                        if (parser.admission_recovery) |recovery| {
                            if (parser.admission_observations.?.items().len > 0) floors.after_observation += 1;
                            if (recovery.erasures.items.len > 0) floors.after_erasure += 1;
                        }
                        try std.testing.expectEqual(scope_mod.ScopeKind.global, parser.scopes.getCurrentScope().kind);
                        try std.testing.expectEqualDeep(std.mem.zeroes(type_syntax.Store.Checkpoint), parser.type_store.checkpoint());
                        try parser.type_store.validate();
                    },
                    else => {},
                }
                return err;
            };
            switch (mode) {
                .collect => switch (outcome) {
                    .recovered_admission_refused => {},
                    else => return error.TestUnexpectedResult,
                },
                .compile => switch (outcome) {
                    .terminal_admission_refused => |failure| switch (failure) {
                        .diagnostic => |diagnostic| try std.testing.expectEqual(type_syntax.AdmissionKind.any_type, diagnostic.kind),
                        else => return error.TestUnexpectedResult,
                    },
                    else => return error.TestUnexpectedResult,
                },
            }
            try std.testing.expectEqual(@as(usize, 1), parser.getAdmissionDiagnostics().len);
            try std.testing.expectEqual(type_syntax.AdmissionKind.any_type, parser.getAdmissionDiagnostics()[0].kind);
            try std.testing.expectEqual(scope_mod.ScopeKind.global, parser.scopes.getCurrentScope().kind);
            try std.testing.expectEqualDeep(std.mem.zeroes(type_syntax.Store.Checkpoint), parser.type_store.checkpoint());
        }
    };
    for ([_]type_syntax.AdmissionMode{ .collect, .compile }) |mode| {
        var floors: Floors = .{};
        try std.testing.checkAllAllocationFailures(std.testing.allocator, Context.run, .{ mode, &floors });
        try std.testing.expect(floors.after_observation > 0);
        try std.testing.expect(floors.after_erasure > 0);
    }
}

test "source observation preserves measured colon and generic refusal boundaries" {
    const cases = [_]struct { source: []const u8, refuses_any: bool }{
        .{ .source = "const { value }: { value: any } = input;", .refuses_any = true },
        .{ .source = "const [value]: any[] = input;", .refuses_any = false },
        .{ .source = "let first: number, second: any;", .refuses_any = true },
        .{ .source = "let first = 1, second: any;", .refuses_any = false },
        .{ .source = "let value!: any;", .refuses_any = true },
        .{ .source = "const f = (value: any): string;", .refuses_any = true },
        .{ .source = "const f = /* gap */ (value: any): string;", .refuses_any = false },
        .{ .source = "const f = (value /* ( */): any;", .refuses_any = false },
        .{ .source = "function default(value: any): number { return 1; }", .refuses_any = true },
        .{ .source = "const f = <T>(value: any): string;", .refuses_any = true },
        .{ .source = "const f = <T>(value /* ( */): any => value;", .refuses_any = false },
        .{ .source = "const f = <T>\n(value: any): string;", .refuses_any = true },
        .{ .source = "const f = <T>\r(value: any): string;", .refuses_any = false },
        .{ .source = "const f = [<T>(value: any): string];", .refuses_any = false },
        .{ .source = "const f = invoke<T> (value /* ( */): any => value;", .refuses_any = false },
        .{ .source = "const f = invoke<T>(value /* x */): any => value;", .refuses_any = true },
    };
    try std.testing.expectEqual(@as(usize, 16), cases.len);
    for ([_]type_syntax.AdmissionMode{ .compile, .collect }) |mode| {
        for (cases) |case| {
            var parser = try Parser.initAdmission(std.testing.allocator, std.testing.allocator, case.source, mode);
            defer parser.deinit();
            const outcome = try parser.parseAdmission();
            if (case.refuses_any) {
                switch (mode) {
                    .compile => switch (outcome) {
                        .terminal_admission_refused => |failure| switch (failure) {
                            .diagnostic => |diagnostic| try std.testing.expectEqual(type_syntax.AdmissionKind.any_type, diagnostic.kind),
                            else => return error.TestUnexpectedResult,
                        },
                        else => return error.TestUnexpectedResult,
                    },
                    .collect => try std.testing.expect(outcome == .recovered_admission_refused),
                }
                try std.testing.expectEqual(@as(usize, 1), parser.getAdmissionDiagnostics().len);
                const diagnostic = parser.getAdmissionDiagnostics()[0];
                try std.testing.expectEqual(type_syntax.AdmissionKind.any_type, diagnostic.kind);
                try std.testing.expectEqualStrings("any", diagnostic.span.text(case.source));
                try std.testing.expectEqualDeep(diagnostic, parser.getLastAdmissionObservation().?);
            } else {
                try std.testing.expect(outcome == .parser_refused);
                try std.testing.expectEqual(@as(usize, 0), parser.getAdmissionDiagnostics().len);
            }
        }
    }
}

test "fresh replay allocation failure preserves the runtime prefix and original observations" {
    const source = "const seed: number = 1;\nconst broken = ;\nconst later: string = \"ok\";\n";
    var baseline_allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var baseline = try Parser.initAdmission(std.testing.allocator, baseline_allocator.allocator(), source, .compile);
    defer baseline.deinit();
    try std.testing.expect(try baseline.parseAdmission() == .parser_refused);
    try std.testing.expect(baseline_allocator.alloc_index > 0);
    try std.testing.expect(baseline.getErrors().len > 0);
    try std.testing.expect(baseline.nodes.tags.items.len > 0);
    try std.testing.expectEqual(@as(usize, 0), baseline.getAdmissionDiagnostics().len);

    var faulted_allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = baseline_allocator.alloc_index - 1 });
    var faulted = try Parser.initAdmission(std.testing.allocator, faulted_allocator.allocator(), source, .compile);
    defer faulted.deinit();
    try std.testing.expectError(error.OutOfMemory, faulted.parseAdmission());
    try std.testing.expect(faulted_allocator.has_induced_failure);
    try std.testing.expectEqualDeep(baseline.getErrors(), faulted.getErrors());
    try std.testing.expectEqualDeep(baseline.type_store.checkpoint(), faulted.type_store.checkpoint());
    try std.testing.expectEqualSlices(ir.NodeTag, baseline.nodes.tags.items, faulted.nodes.tags.items);
    try std.testing.expectEqual(@as(usize, 0), faulted.getAdmissionDiagnostics().len);
    try std.testing.expectEqualDeep(baseline.getLastAdmissionObservation(), faulted.getLastAdmissionObservation());
}

test "source observer cleans partial printable captures through allocation failures" {
    const source = "structural Pair<T> = { left: T };\nfunction id<U>(value: U): U { return value; }\nconst { value }: { value: string } = input;\n";
    const Context = struct {
        fn run(type_allocator: std.mem.Allocator, partial_failures: *usize) !void {
            var observer = try Parser.initSourceObserver(std.testing.allocator, type_allocator, source, .compile);
            defer observer.deinit();
            const captures = observer.observePrintableSource() catch |err| {
                switch (err) {
                    error.OutOfMemory => if (observer.printable_regions) |regions| {
                        if (regions.items.len > 0) partial_failures.* += 1;
                    },
                    else => {},
                }
                return err;
            };
            try std.testing.expect(captures.len >= 4);
            try std.testing.expectEqual(@as(usize, 0), observer.nodes.tags.items.len);
            try std.testing.expectEqualDeep(std.mem.zeroes(type_syntax.Store.Checkpoint), observer.type_store.checkpoint());
        }
    };
    var partial_failures: usize = 0;
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Context.run, .{&partial_failures});
    try std.testing.expect(partial_failures > 0);
}

test "a parse refusal carries a fixed help string" {
    const Case = struct { source: []const u8, help: []const u8 };
    const cases = [_]Case{
        .{ .source = "const x = ;", .help = "Write a complete expression or statement at this position." },
        .{ .source = "const x = 0x;", .help = "Write decimal digits, or 0x, 0o, 0b with digits. Use no underscore and no leading zero. Give an exponent a digit." },
        .{ .source = "const s = \"a\\qb\";", .help = "Replace the escape with a supported one, or remove the backslash." },
        .{ .source = "const s = \"a\\\nb\";", .help = "Join the string onto one line, or write the newline as \\n." },
        .{ .source = "const x = 1\nconst y = 2;", .help = "Add a semicolon at the end of the statement." },
        .{ .source = "function f() { return await g(); }", .help = "Remove await. Handlers run synchronously, so call the function directly." },
    };
    for (cases) |case| {
        var parser = try Parser.init(std.testing.allocator, case.source);
        defer parser.deinit();
        _ = parser.parse() catch {};
        const errors = parser.getErrors();
        try std.testing.expect(errors.len >= 1);
        try std.testing.expectEqualStrings(case.help, errors[0].suggestion orelse "(null)");
    }
}
