//! Intermediate Representation for core JavaScript syntax.
//!
//! A lightweight IR that captures scope information for proper closure support.
//! Expressions are tree-structured; statements are linearized.

const std = @import("std");
const token = @import("token.zig");

pub const SourceLocation = token.SourceLocation;

/// Index into the node array
pub const NodeIndex = u32;

/// Sentinel value for "no node"
pub const null_node: NodeIndex = std.math.maxInt(NodeIndex);

/// Only property values use the all-ones 24-bit encoding for null. Ordinary
/// operands may use that index, but must never wrap a larger index into it.
fn packNode24(index: NodeIndex, nullable: bool) error{NodeIndexOverflow}!u32 {
    const limit = std.math.maxInt(u24);
    if (nullable and index == null_node) return limit;
    if (index > limit or (nullable and index == limit)) return error.NodeIndexOverflow;
    return index;
}

/// Scope identifier
pub const ScopeId = u16;

/// Sentinel value for "no scope"
pub const null_scope: ScopeId = std.math.maxInt(ScopeId);

/// The first extra word of a pattern or import node: the node's own kind in
/// the low byte and the binding kind above it. The binding kind once sat in
/// bits 29 to 31 of the packed binding, over the top of a 16-bit scope, so a
/// scope at 8192 or above read back truncated and with a corrupted kind.
fn patternKindWord(kind: anytype, binding_kind: BindingRef.BindingKind) u32 {
    return @as(u32, @backingInt(kind)) | (@as(u32, @backingInt(binding_kind)) << 8);
}

const ListRef = struct {
    start: NodeIndex,
    count: u16,
};

/// Reference to a variable binding
pub const BindingRef = struct {
    scope_id: ScopeId,
    /// Runtime storage index: local/upvalue slot, or the global atom-backed slot.
    slot: u16,
    /// Binding identity. Unlike `slot`, this is an atom index for every kind.
    name_atom: u16,
    kind: BindingKind,

    pub const BindingKind = enum(u3) {
        local, // Local variable in current function
        upvalue, // Captured from outer scope
        global, // User-declared global variable
        argument, // Function parameter
        undeclared_global, // Implicit/builtin global (not declared by user)
    };

    /// Create a global reference (slot is atom index)
    pub fn global(atom_idx: u16) BindingRef {
        return .{
            .scope_id = 0,
            .slot = atom_idx,
            .name_atom = atom_idx,
            .kind = .global,
        };
    }
};

/// Binary operator types
pub const BinaryOp = enum(u8) {
    // Arithmetic
    add,
    sub,
    mul,
    div,
    mod,
    pow,

    // Comparison
    strict_eq,
    strict_neq,
    lt,
    lte,
    gt,
    gte,

    // Bitwise
    bit_and,
    bit_or,
    bit_xor,
    shl,
    shr,
    ushr,

    // Logical (short-circuit)
    and_op,
    or_op,
    nullish,

    // The normal ZigTS parser profile rejects loose equality. The comptime
    // expression profile preserves it explicitly so downstream consumers can
    // reject it unless they deliberately implement JavaScript coercion. Keep
    // these at the end so adding the isolated profile does not renumber the
    // established IR operators.
    loose_eq,
    loose_neq,
};

/// Unary operator types
pub const UnaryOp = enum(u4) {
    neg,
    not,
    bit_not,
    typeof_op,
};

/// Function flags
pub const FunctionFlags = packed struct(u8) {
    is_generator: bool = false,
    is_async: bool = false,
    is_arrow: bool = false,
    has_rest_param: bool = false,
    is_method: bool = false,
    // Object getters and setters are rejected at parse time
    // (parse.zig: "object getters are not supported"), so no flag for them.
    _reserved: u3 = 0,
};

/// IR Node tag - determines which payload union field is active
pub const NodeTag = enum(u8) {
    // Literals
    lit_int,
    lit_float,
    lit_string,
    lit_bool,
    lit_null,
    lit_undefined,

    // Identifiers and references
    identifier,

    // Expressions
    binary_op,
    unary_op,
    ternary,
    call,
    method_call,
    member_access,
    computed_access,
    optional_chain,
    assignment,
    array_literal,
    object_literal,
    object_property,
    object_method,
    object_getter,
    object_setter,
    object_spread,
    function_expr,
    arrow_function,
    spread,
    await_expr,
    yield_expr,
    sequence_expr,
    comma_expr,

    // Match expression
    match_expr,
    match_arm,
    match_pattern,
    /// A `match` type-test pattern (spec 5.5): `when string:`, `when array:`.
    /// Carries the value kind it tests and the predicate expression the parser
    /// lowered it to, which is the corresponding narrowing test from the
    /// section 5.4 closed list over the scrutinee.
    match_type_test,

    // Statements
    expr_stmt,
    var_decl,
    if_stmt,
    for_stmt,
    for_of_stmt,
    for_in_stmt,
    while_stmt,
    do_while_stmt,
    switch_stmt,
    case_clause,
    return_stmt,
    assert_stmt,
    throw_stmt,
    break_stmt,
    continue_stmt,
    try_stmt,
    block,
    labeled_stmt,

    // Declarations
    function_decl,

    // Patterns
    array_pattern,
    pattern_element,
    pattern_rest,
    pattern_default,

    // Module
    import_decl,
    import_specifier,
    import_default,
    import_namespace,
    export_decl,
    export_specifier,
    export_default,
    export_all,

    // Internal markers
    program,
    param_list,
    arg_list,
    stmt_list,
};

/// IR Node - tagged union with source location
pub const Node = struct {
    tag: NodeTag,
    loc: SourceLocation,
    data: Data,

    pub const Data = union {
        // Literals
        int_value: i32,
        float_idx: u16, // Index into float constant pool
        string_idx: u16, // Index into string constant pool
        bool_value: bool,

        // Identifier/binding reference
        binding: BindingRef,

        // Binary expression
        binary: BinaryExpr,

        // Unary expression
        unary: UnaryExpr,

        // Ternary expression
        ternary: TernaryExpr,

        // Function call
        call: CallExpr,

        // Property access
        member: MemberExpr,

        // Assignment
        assignment: AssignExpr,

        // Array literal
        array: ArrayExpr,

        // Object literal
        object: ObjectExpr,

        // Object property (key-value)
        property: PropertyExpr,

        // Function expression
        function: FunctionExpr,

        // Variable declaration
        var_decl: VarDecl,

        // If statement
        if_stmt: IfStmt,

        // Loop statements
        loop: LoopStmt,

        // For-of/for-in
        for_iter: ForIterStmt,

        // Switch statement
        switch_stmt: SwitchStmt,

        // Case clause
        case_clause: CaseClause,

        // Match expression
        match_expr: MatchExpr,

        // Match arm
        match_arm: MatchArm,

        // Match pattern (object pattern)
        match_pattern: MatchPatternObj,
        match_type_test: MatchTypeTest,

        // Assert statement
        assert_stmt: AssertStmt,

        // Return/throw with optional value
        opt_value: ?NodeIndex,

        // Break/continue with optional label
        opt_label: ?u16, // atom index of label

        // Try-catch-finally
        try_stmt: TryStmt,

        // Block/program/list
        block: BlockData,

        // Import declaration
        import_decl: ImportDecl,

        // Import specifier
        import_spec: ImportSpec,

        // Export declaration
        export_decl: ExportDecl,

        // Pattern element
        pattern_elem: PatternElem,

        // Labeled statement
        labeled: LabeledStmt,

        // No data needed
        none: void,
    };

    // --- Nested data structures ---

    pub const BinaryExpr = struct {
        op: BinaryOp,
        left: NodeIndex,
        right: NodeIndex,
    };

    pub const UnaryExpr = struct {
        op: UnaryOp,
        operand: NodeIndex,
    };

    pub const TernaryExpr = struct {
        condition: NodeIndex,
        then_branch: NodeIndex,
        else_branch: NodeIndex,
    };

    pub const CallExpr = struct {
        callee: NodeIndex,
        args_start: NodeIndex, // First argument node
        args_count: u8,
    };

    pub const MemberExpr = struct {
        object: NodeIndex,
        property: u16, // Atom index for .property access
        computed: NodeIndex, // For [expr] access, null_node if not computed
        is_optional: bool, // obj?.prop
    };

    pub const AssertStmt = struct {
        condition: NodeIndex,
        error_expr: NodeIndex, // null_node if no explicit error expression
    };

    pub const AssignExpr = struct {
        target: NodeIndex,
        value: NodeIndex,
        op: ?BinaryOp, // null for =, set for +=, etc.
    };

    pub const ArrayExpr = struct {
        elements_start: NodeIndex,
        elements_count: u16,
        has_spread: bool,
    };

    pub const ObjectExpr = struct {
        properties_start: NodeIndex,
        properties_count: u16,
    };

    pub const PropertyExpr = struct {
        key: NodeIndex,
        value: NodeIndex,
        is_shorthand: bool, // match { x } === match { x: x }
    };

    pub const FunctionExpr = struct {
        scope_id: ScopeId,
        name_atom: u16, // 0 for anonymous
        params_start: NodeIndex, // First parameter node
        params_count: u8,
        body: NodeIndex,
        flags: FunctionFlags,
    };

    pub const VarDecl = struct {
        binding: BindingRef,
        init: NodeIndex, // Initializer, null_node if none
        kind: VarKind,

        pub const VarKind = enum(u2) { @"var", let, @"const" };
    };

    pub const IfStmt = struct {
        condition: NodeIndex,
        then_branch: NodeIndex,
        else_branch: NodeIndex, // null_node if no else
    };

    pub const LoopStmt = struct {
        kind: LoopKind,
        init: NodeIndex, // For for-loop, null_node otherwise
        condition: NodeIndex, // null_node for unconditional
        update: NodeIndex, // For for-loop, null_node otherwise
        body: NodeIndex,

        pub const LoopKind = enum(u2) { while_loop, do_while, for_loop };
    };

    pub const ForIterStmt = struct {
        is_for_in: bool, // false = for-of
        binding: BindingRef,
        iterable: NodeIndex,
        body: NodeIndex,
        is_const: bool, // const vs let/var
    };

    pub const SwitchStmt = struct {
        discriminant: NodeIndex,
        cases_start: NodeIndex, // First case clause
        cases_count: u8,
    };

    pub const CaseClause = struct {
        test_expr: NodeIndex, // null_node for default
        body_start: NodeIndex,
        body_count: u16,
    };

    pub const MatchExpr = struct {
        discriminant: NodeIndex,
        arms_start: NodeIndex, // index into list storage
        arms_count: u8,
    };

    pub const MatchArm = struct {
        pattern: NodeIndex, // literal node, match_pattern, or null_node (default)
        body: NodeIndex, // single expression
    };

    pub const MatchPatternObj = struct {
        props_start: NodeIndex, // index into list storage
        props_count: u8,
    };

    /// The closed set of value kinds a type-test pattern may name. Six, which
    /// is what spec 5.5 lists - `Bytes` joined with its type in phase 5.
    pub const TypeTestKind = enum(u8) {
        boolean,
        number,
        string,
        array,
        dict,
        bytes,
    };

    pub const MatchTypeTest = struct {
        kind: TypeTestKind,
        /// The predicate expression this test lowers to: `typeof s === "..."`
        /// for the scalars, `Array.isArray(s)` for the array.
        predicate: NodeIndex,
    };

    pub const TryStmt = struct {
        try_block: NodeIndex,
        catch_binding: BindingRef, // slot=255 means no binding (catch {})
        catch_block: NodeIndex, // null_node if no catch
        finally_block: NodeIndex, // null_node if no finally
    };

    pub const BlockData = struct {
        stmts_start: NodeIndex,
        stmts_count: u16,
        scope_id: ScopeId, // null_scope if block doesn't create scope
    };

    pub const ImportDecl = struct {
        module_idx: u16, // String constant index for module path
        specifiers_start: NodeIndex,
        specifiers_count: u8,
    };

    pub const ImportSpec = struct {
        kind: ImportKind,
        imported_atom: u16, // Original name in source module
        local_binding: BindingRef, // Local binding

        pub const ImportKind = enum(u2) { named, default, namespace };
    };

    pub const ExportDecl = struct {
        kind: ExportKind,
        declaration: NodeIndex, // The exported declaration, or null_node
        specifiers_start: NodeIndex,
        specifiers_count: u8,
        from_module_idx: u16, // For re-exports, 0 if not re-export

        pub const ExportKind = enum(u2) { named, default, all };
    };

    pub const PatternElem = struct {
        kind: PatternKind,
        binding: BindingRef, // Final binding slot
        key: NodeIndex, // For nested patterns, points to the nested pattern
        key_atom: u16, // For object pattern: property name atom (for get_field)
        default_value: NodeIndex, // null_node if no default

        pub const PatternKind = enum(u2) { simple, array, object, rest };
    };

    pub const LabeledStmt = struct {
        label_atom: u16,
        body: NodeIndex,
    };

    /// Create a literal integer node
    pub fn litInt(loc: SourceLocation, value: i32) Node {
        return .{
            .tag = .lit_int,
            .loc = loc,
            .data = .{ .int_value = value },
        };
    }

    /// Create a literal string node
    pub fn litString(loc: SourceLocation, str_idx: u16) Node {
        return .{
            .tag = .lit_string,
            .loc = loc,
            .data = .{ .string_idx = str_idx },
        };
    }

    /// Create a literal boolean node
    pub fn litBool(loc: SourceLocation, value: bool) Node {
        return .{
            .tag = .lit_bool,
            .loc = loc,
            .data = .{ .bool_value = value },
        };
    }

    /// Create a null literal node. Spec 5.3 admits `null` as explicit data,
    /// distinct from `undefined` and permitted only where the type names it.
    pub fn litNull(loc: SourceLocation) Node {
        return .{
            .tag = .lit_null,
            .loc = loc,
            .data = .{ .none = {} },
        };
    }

    /// Create an undefined literal node
    pub fn litUndefined(loc: SourceLocation) Node {
        return .{
            .tag = .lit_undefined,
            .loc = loc,
            .data = .{ .none = {} },
        };
    }

    /// Create an identifier reference node
    pub fn identifier(loc: SourceLocation, binding: BindingRef) Node {
        return .{
            .tag = .identifier,
            .loc = loc,
            .data = .{ .binding = binding },
        };
    }

    /// Create a binary expression node
    pub fn binaryOp(loc: SourceLocation, op: BinaryOp, left: NodeIndex, right: NodeIndex) Node {
        return .{
            .tag = .binary_op,
            .loc = loc,
            .data = .{ .binary = .{ .op = op, .left = left, .right = right } },
        };
    }

    /// Create a unary expression node
    pub fn unaryOp(loc: SourceLocation, op: UnaryOp, operand: NodeIndex) Node {
        return .{
            .tag = .unary_op,
            .loc = loc,
            .data = .{ .unary = .{ .op = op, .operand = operand } },
        };
    }
};

/// Constant pool for strings and floats
/// Uses hash maps for O(1) deduplication instead of O(n) linear scan
pub const ConstantPool = struct {
    strings: std.ArrayList([]const u8),
    floats: std.ArrayList(f64),
    allocator: std.mem.Allocator,

    // Hash maps for O(1) deduplication (keys point to indices in arrays)
    string_index: std.StringHashMapUnmanaged(u16),
    float_index: std.AutoHashMapUnmanaged(u64, u16),

    /// Only initBorrowingSource permits source-backed entries. That source must
    /// remain immutable and alive until the pool is deinitialized.
    borrowed_source: ?[]const u8 = null,

    pub fn init(allocator: std.mem.Allocator) ConstantPool {
        return .{
            .strings = .empty,
            .floats = .empty,
            .allocator = allocator,
            .string_index = .{},
            .float_index = .{},
        };
    }

    pub fn deinit(self: *ConstantPool) void {
        for (self.strings.items) |str| {
            if (!self.isSourceSlice(str)) self.allocator.free(str);
        }
        self.string_index.deinit(self.allocator);
        self.float_index.deinit(self.allocator);
        self.strings.deinit(self.allocator);
        self.floats.deinit(self.allocator);
    }

    /// The caller retains source ownership. addString and addOwnedString keep
    /// their owning contracts; only addSourceString may borrow this source.
    pub fn initBorrowingSource(allocator: std.mem.Allocator, source: []const u8) ConstantPool {
        var pool = init(allocator);
        pool.borrowed_source = source;
        return pool;
    }

    fn isSourceSlice(self: *const ConstantPool, str: []const u8) bool {
        const source = self.borrowed_source orelse return false;
        const offset, const underflow = @subWithOverflow(@intFromPtr(str.ptr), @intFromPtr(source.ptr));
        return underflow == 0 and offset <= source.len and str.len <= source.len - offset;
    }

    /// An owning pool copies. A borrowing pool accepts only slices within its
    /// declared source, so unrelated temporary buffers cannot become borrowed.
    pub fn addSourceString(self: *ConstantPool, str: []const u8) !u16 {
        if (self.borrowed_source == null) return self.addString(str);
        if (!self.isSourceSlice(str)) return error.InvalidSourceSlice;
        if (self.string_index.get(str)) |idx| return idx;
        const idx = std.math.cast(u16, self.strings.items.len) orelse return error.TooManyConstants;
        try self.strings.append(self.allocator, str);
        errdefer _ = self.strings.pop();
        try self.string_index.put(self.allocator, str, idx);
        return idx;
    }

    pub fn addString(self: *ConstantPool, str: []const u8) !u16 {
        // O(1) hash lookup for deduplication
        if (self.string_index.get(str)) |idx| return idx;
        // A constant is addressed by a u16, so the 65537th distinct string has no
        // index. Refuse it rather than wrap: a wrapped index would name another
        // constant. The key goes into the map only after the string is stored,
        // so a failure leaves no entry without a value behind.
        const idx = std.math.cast(u16, self.strings.items.len) orelse return error.TooManyConstants;
        // Deep-copy so ConstantPool owns this entry even in borrowing mode
        // (callers may pass slices into source text or
        // freshly-allocated unescape buffers; ownership is not transferred).
        const owned = try self.allocator.dupe(u8, str);
        return self.insertOwnedString(owned, idx);
    }

    /// Consumes a buffer allocated with this pool's allocator on every path.
    /// A duplicate is freed immediately; a new string stays owned by the pool.
    pub fn addOwnedString(self: *ConstantPool, owned: []u8) !u16 {
        if (self.string_index.get(owned)) |idx| {
            self.allocator.free(owned);
            return idx;
        }
        const idx = std.math.cast(u16, self.strings.items.len) orelse {
            self.allocator.free(owned);
            return error.TooManyConstants;
        };
        return self.insertOwnedString(owned, idx);
    }

    fn insertOwnedString(self: *ConstantPool, owned: []u8, idx: u16) !u16 {
        errdefer self.allocator.free(owned);
        try self.strings.append(self.allocator, owned);
        errdefer _ = self.strings.pop();
        try self.string_index.put(self.allocator, owned, idx);
        return idx;
    }

    pub fn addFloat(self: *ConstantPool, f: f64) !u16 {
        // Use bit representation as key for stable hashing
        const bits: u64 = @bitCast(f);
        if (self.float_index.get(bits)) |idx| return idx;
        // Same u16 address space and the same refusal as `addString`.
        const idx = std.math.cast(u16, self.floats.items.len) orelse return error.TooManyConstants;
        try self.floats.append(self.allocator, f);
        errdefer _ = self.floats.pop();
        try self.float_index.put(self.allocator, bits, idx);
        return idx;
    }

    pub fn getString(self: *const ConstantPool, idx: u16) ?[]const u8 {
        if (idx >= self.strings.items.len) return null;
        return self.strings.items[idx];
    }

    pub fn getFloat(self: *const ConstantPool, idx: u16) ?f64 {
        if (idx >= self.floats.items.len) return null;
        return self.floats.items[idx];
    }
};

// ============================================================================
// Phase 3: Optimized IR Storage using MultiArrayList (Zig Compiler Pattern)
// ============================================================================

/// Compact 8-byte data payload for IR nodes
/// Larger data is stored in extra[] and referenced by index
pub const DataPayload = extern struct {
    /// First 4 bytes - primary data
    a: u32,
    /// Second 4 bytes - secondary data or extra index
    b: u32,

    /// Pack an integer directly
    pub fn fromInt(val: i32) DataPayload {
        return .{ .a = @bitCast(val), .b = 0 };
    }

    /// Pack binary expression
    pub fn fromBinary(op: BinaryOp, left: NodeIndex, right: NodeIndex) error{NodeIndexOverflow}!DataPayload {
        return .{
            .a = (@as(u32, @backingInt(op)) << 24) | try packNode24(left, false),
            .b = right,
        };
    }

    /// Unpack binary expression
    pub fn toBinary(self: DataPayload) struct { op: BinaryOp, left: NodeIndex, right: NodeIndex } {
        return .{
            .op = @fromBackingInt(@intCast(@as(u8, @truncate(self.a >> 24)))),
            .left = self.a & 0xFFFFFF,
            .right = self.b,
        };
    }

    /// Get as signed integer
    pub fn toInt(self: DataPayload) i32 {
        return @bitCast(self.a);
    }

    /// Get first index
    pub fn getIndex(self: DataPayload) NodeIndex {
        return self.a;
    }
};

comptime {
    std.debug.assert(@sizeOf(DataPayload) == 8);
    std.debug.assert(@sizeOf(NodeTag) == 1);
    std.debug.assert(@sizeOf(SourceLocation) == 16);
    std.debug.assert(@typeInfo(BinaryOp).@"enum".field_names.len < 256);
}

/// Structure-of-arrays storage: tag(1) + location(16) + payload(8) +
/// binding-name atom(2) = 27 bytes per node, excluding side arrays, allocator
/// overhead, and spare capacity. Tag-only passes read the one-byte column.
pub const IRStore = struct {
    allocator: std.mem.Allocator,

    /// Node tags - 1 byte each, contiguous for fast dispatch
    tags: std.ArrayListUnmanaged(NodeTag),

    /// Source locations - 16 bytes each
    locs: std.ArrayListUnmanaged(SourceLocation),

    /// Compact data payloads - 8 bytes each
    data: std.ArrayListUnmanaged(DataPayload),

    /// Binding-name atom for nodes that carry a BindingRef; zero otherwise.
    /// Kept parallel to `data` so BindingRef gains an explicit identity without
    /// repacking runtime slot/scope operands in the compact payload.
    binding_name_atoms: std.ArrayListUnmanaged(u16),

    /// Extra data for variable-length content
    /// Used for: function params, object properties, switch cases, etc.
    extra: std.ArrayListUnmanaged(u32),

    /// Storage for node index lists (statements, arguments, etc.)
    index_lists: std.ArrayListUnmanaged(NodeIndex),

    pub fn init(allocator: std.mem.Allocator) IRStore {
        return .{
            .allocator = allocator,
            .tags = .empty,
            .locs = .empty,
            .data = .empty,
            .binding_name_atoms = .empty,
            .extra = .empty,
            .index_lists = .empty,
        };
    }

    /// Upper bound on the pre-sized node count. The source-length estimate is
    /// content-blind: a handler that is mostly one large string literal has a
    /// node density far below one node per 5 bytes, and an uncapped estimate
    /// reserved ~5.1 bytes of heap per source byte, which measured as a 2.5x
    /// peak-memory regression (20.5 MB -> 51.1 MB) on a 4 MB blob-heavy
    /// handler. Capping bounds the up-front reservation; sources that
    /// genuinely exceed it fall back to geometric growth, which costs a handful of
    /// reallocations on a parse that is already large.
    const max_reserved_nodes: usize = 16384;
    const max_reserved_side: usize = 4096;

    /// Init with capacity estimated from the source length, so the six
    /// parallel lists do not grow by doubling from zero on every compile.
    /// Across the compile-time microbench corpus the node count runs about
    /// one node per 5 source bytes (77/16, 249/48, 606/101, 1038/206).
    ///
    /// Infallible on purpose: the reservation is an optimization, never a
    /// requirement, so a failed reservation degrades to on-demand growth
    /// instead of failing the parse. It is therefore not a silent failure
    /// path inside the now-fallible `Parser.init`; the allocations that can
    /// genuinely fail there are reported as errors.
    pub fn initCapacity(allocator: std.mem.Allocator, source_len: usize) IRStore {
        var self = init(allocator);

        const node_estimate = @min(@max(32, source_len / 5), max_reserved_nodes);
        self.tags.ensureTotalCapacity(allocator, node_estimate) catch return self;
        self.locs.ensureTotalCapacity(allocator, node_estimate) catch return self;
        self.data.ensureTotalCapacity(allocator, node_estimate) catch return self;
        self.binding_name_atoms.ensureTotalCapacity(allocator, node_estimate) catch return self;

        // `extra` and `index_lists` hold variable-length payloads (params,
        // properties, statement lists), which are far sparser than nodes.
        const side_estimate = @min(@max(16, source_len / 16), max_reserved_side);
        self.extra.ensureTotalCapacity(allocator, side_estimate) catch return self;
        self.index_lists.ensureTotalCapacity(allocator, side_estimate) catch return self;

        return self;
    }

    pub fn deinit(self: *IRStore) void {
        self.tags.deinit(self.allocator);
        self.locs.deinit(self.allocator);
        self.data.deinit(self.allocator);
        self.binding_name_atoms.deinit(self.allocator);
        self.extra.deinit(self.allocator);
        self.index_lists.deinit(self.allocator);
    }

    /// Add a node and return its index
    pub fn addNode(self: *IRStore, tag: NodeTag, loc: SourceLocation, payload: DataPayload) !NodeIndex {
        const idx = std.math.cast(NodeIndex, self.tags.items.len) orelse return error.TooManyNodes;
        if (idx == null_node) return error.TooManyNodes;
        // Publish no column until every allocation succeeds. Recovery may keep
        // walking the retained prefix after an allocation failure.
        try self.tags.ensureUnusedCapacity(self.allocator, 1);
        try self.locs.ensureUnusedCapacity(self.allocator, 1);
        try self.data.ensureUnusedCapacity(self.allocator, 1);
        try self.binding_name_atoms.ensureUnusedCapacity(self.allocator, 1);
        self.tags.appendAssumeCapacity(tag);
        self.locs.appendAssumeCapacity(loc);
        self.data.appendAssumeCapacity(payload);
        self.binding_name_atoms.appendAssumeCapacity(0);
        return idx;
    }

    fn setBindingName(self: *IRStore, idx: NodeIndex, name_atom: u16) void {
        self.binding_name_atoms.items[idx] = name_atom;
    }

    fn bindingName(self: *const IRStore, idx: NodeIndex) u16 {
        return self.binding_name_atoms.items[idx];
    }

    /// Add extra data and return starting index
    pub fn addExtra(self: *IRStore, values: []const u32) !u32 {
        const start = std.math.cast(u32, self.extra.items.len) orelse return error.TooManyNodes;
        if (values.len > std.math.maxInt(u32) - start) return error.TooManyNodes;
        try self.extra.appendSlice(self.allocator, values);
        return start;
    }

    /// Store a list reference without narrowing its 32-bit start offset.
    fn addListRef(self: *IRStore, start: NodeIndex, count: u16) !u32 {
        return self.addExtra(&.{ start, count });
    }

    fn getListRef(self: *const IRStore, extra_start: u32) ?ListRef {
        const start: usize = extra_start;
        if (start >= self.extra.items.len or self.extra.items.len - start < 2) return null;
        return .{
            .start = self.extra.items[start],
            .count = @intCast(self.extra.items[start + 1]),
        };
    }

    /// Get node tag
    pub fn getTag(self: *const IRStore, idx: NodeIndex) NodeTag {
        return self.tags.items[idx];
    }

    /// Get node location
    pub fn getLoc(self: *const IRStore, idx: NodeIndex) SourceLocation {
        return self.locs.items[idx];
    }

    /// Get node data payload
    pub fn getData(self: *const IRStore, idx: NodeIndex) DataPayload {
        return self.data.items[idx];
    }

    /// Add index list and return start position
    pub fn addIndexList(self: *IRStore, indices: []const NodeIndex) !NodeIndex {
        if (indices.len == 0) return null_node;
        const start = std.math.cast(NodeIndex, self.index_lists.items.len) orelse return error.TooManyNodes;
        if (indices.len > std.math.maxInt(NodeIndex) - start) return error.TooManyNodes;
        try self.index_lists.appendSlice(self.allocator, indices);
        return start;
    }

    /// Get index from list
    pub fn getListIndex(self: *const IRStore, list_start: NodeIndex, offset: u16) NodeIndex {
        const pos = list_start + offset;
        if (pos >= self.index_lists.items.len) return null_node;
        return self.index_lists.items[pos];
    }

    /// Node count
    pub fn len(self: *const IRStore) usize {
        return self.tags.items.len;
    }

    /// Unpack identifier binding
    pub fn getBinding(self: *const IRStore, idx: NodeIndex) BindingRef {
        const d = self.getData(idx);
        return .{
            .scope_id = @truncate(d.a >> 16),
            .slot = @truncate(d.a),
            .name_atom = self.bindingName(idx),
            .kind = @fromBackingInt(@intCast(@as(u3, @truncate(d.b)))),
        };
    }

    /// Unpack call expression data
    pub fn getCallData(self: *const IRStore, idx: NodeIndex) ?Node.CallExpr {
        if (idx >= self.data.items.len) return null;
        const d = self.data.items[idx];
        const list_ref = self.getListRef(d.b) orelse return null;
        return .{
            .callee = d.a,
            .args_start = list_ref.start,
            .args_count = @intCast(list_ref.count),
        };
    }

    // ============================================================
    // Node Adapter: Accept full Node struct for seamless migration
    // ============================================================

    /// Add a Node struct, converting to compact SoA representation.
    pub fn add(self: *IRStore, node: Node) !NodeIndex {
        const loc = node.loc;
        const idx = try switch (node.tag) {
            // --- Literals ---
            .lit_int => self.addNode(.lit_int, loc, DataPayload.fromInt(node.data.int_value)),
            .lit_float => self.addNode(.lit_float, loc, .{ .a = node.data.float_idx, .b = 0 }),
            .lit_string => self.addNode(.lit_string, loc, .{ .a = node.data.string_idx, .b = 0 }),
            .lit_bool => self.addNode(.lit_bool, loc, .{ .a = if (node.data.bool_value) 1 else 0, .b = 0 }),
            .lit_null => self.addNode(.lit_null, loc, .{ .a = 0, .b = 0 }),
            .lit_undefined => self.addNode(.lit_undefined, loc, .{ .a = 0, .b = 0 }),
            // --- Expressions ---
            .identifier => blk: {
                const b = node.data.binding;
                break :blk self.addNode(.identifier, loc, .{
                    .a = (@as(u32, b.scope_id) << 16) | b.slot,
                    .b = @backingInt(b.kind),
                });
            },
            .binary_op => self.addNode(.binary_op, loc, try DataPayload.fromBinary(
                node.data.binary.op,
                node.data.binary.left,
                node.data.binary.right,
            )),
            .unary_op => blk: {
                const u = node.data.unary;
                break :blk self.addNode(.unary_op, loc, .{ .a = @backingInt(u.op), .b = u.operand });
            },
            .ternary => blk: {
                const t = node.data.ternary;
                const extra_start = try self.addExtra(&.{ t.condition, t.then_branch, t.else_branch });
                break :blk self.addNode(.ternary, loc, .{ .a = extra_start, .b = 0 });
            },
            .call => blk: {
                const c = node.data.call;
                const list_ref = try self.addListRef(c.args_start, c.args_count);
                break :blk self.addNode(.call, loc, .{ .a = c.callee, .b = list_ref });
            },
            .member_access => blk: {
                const m = node.data.member;
                // Pack: a = object, b = property(16) | is_optional(1) << 16
                const b_val = @as(u32, m.property) | (@as(u32, if (m.is_optional) 1 else 0) << 16);
                break :blk self.addNode(.member_access, loc, .{ .a = m.object, .b = b_val });
            },
            .computed_access => blk: {
                const m = node.data.member;
                break :blk self.addNode(.computed_access, loc, .{ .a = m.object, .b = m.computed });
            },
            .optional_chain => blk: {
                const m = node.data.member;
                const b_val = @as(u32, m.property) | (@as(u32, 1) << 16);
                break :blk self.addNode(.optional_chain, loc, .{ .a = m.object, .b = b_val });
            },
            .assignment => blk: {
                const a = node.data.assignment;
                // Pack: a = target, b = value(24) | op(8) (0 = no op, 1+ = op enum + 1)
                const op_byte: u8 = if (a.op) |op| @as(u8, @backingInt(op)) + 1 else 0;
                const b_val = (try packNode24(a.value, false)) | (@as(u32, op_byte) << 24);
                break :blk self.addNode(.assignment, loc, .{ .a = a.target, .b = b_val });
            },
            .array_literal => blk: {
                const arr = node.data.array;
                // Pack: a = elements_start, b = elements_count(16) | has_spread(1) << 16
                const b_val = @as(u32, arr.elements_count) | (@as(u32, if (arr.has_spread) 1 else 0) << 16);
                break :blk self.addNode(.array_literal, loc, .{ .a = arr.elements_start, .b = b_val });
            },
            .object_literal => blk: {
                const obj = node.data.object;
                break :blk self.addNode(.object_literal, loc, .{ .a = obj.properties_start, .b = obj.properties_count });
            },
            .object_property => blk: {
                const p = node.data.property;
                // Pack: a = key, b = value(24) | is_shorthand(1) << 24.
                const flags: u32 = @as(u32, if (p.is_shorthand) 1 else 0) << 24;
                const b_val = (try packNode24(p.value, true)) | flags;
                break :blk self.addNode(.object_property, loc, .{ .a = p.key, .b = b_val });
            },
            .object_spread => self.addNode(.object_spread, loc, .{ .a = node.data.opt_value orelse null_node, .b = 0 }),
            .spread => self.addNode(.spread, loc, .{ .a = node.data.opt_value orelse null_node, .b = 0 }),
            .yield_expr, .await_expr => self.addNode(node.tag, loc, .{ .a = node.data.opt_value orelse null_node, .b = 0 }),

            // --- Function expressions ---
            .function_expr, .arrow_function => blk: {
                const f = node.data.function;
                // Store in extra: [scope_id, name_atom, params_start, params_count, body, flags]
                const flags_u8: u8 = @bitCast(f.flags);
                const extra_start = try self.addExtra(&.{
                    f.scope_id,
                    f.name_atom,
                    f.params_start,
                    f.params_count,
                    f.body,
                    @as(u32, flags_u8),
                });
                break :blk self.addNode(node.tag, loc, .{ .a = extra_start, .b = 0 });
            },
            // Note: function_decl uses var_decl data (binding + init function)
            .function_decl => blk: {
                const v = node.data.var_decl;
                const binding_packed = (@as(u32, v.binding.scope_id) << 16) | v.binding.slot;
                const kind_and_binding_kind = @as(u32, @backingInt(v.kind)) |
                    (@as(u32, @backingInt(v.binding.kind)) << 2);
                const extra_start = try self.addExtra(&.{ binding_packed, v.init, kind_and_binding_kind });
                break :blk self.addNode(.function_decl, loc, .{ .a = extra_start, .b = 0 });
            },

            // --- Statements ---
            .var_decl => blk: {
                const v = node.data.var_decl;
                // Store in extra: [binding_packed, init, kind]
                const binding_packed = (@as(u32, v.binding.scope_id) << 16) | v.binding.slot;
                const kind_and_binding_kind = @as(u32, @backingInt(v.kind)) |
                    (@as(u32, @backingInt(v.binding.kind)) << 2);
                const extra_start = try self.addExtra(&.{ binding_packed, v.init, kind_and_binding_kind });
                break :blk self.addNode(.var_decl, loc, .{ .a = extra_start, .b = 0 });
            },
            .if_stmt => blk: {
                const i = node.data.if_stmt;
                const extra_start = try self.addExtra(&.{ i.condition, i.then_branch, i.else_branch });
                break :blk self.addNode(.if_stmt, loc, .{ .a = extra_start, .b = 0 });
            },
            .while_stmt, .do_while_stmt, .for_stmt => blk: {
                const l = node.data.loop;
                // Store in extra: [kind, init, condition, update, body]
                const extra_start = try self.addExtra(&.{
                    @backingInt(l.kind),
                    l.init,
                    l.condition,
                    l.update,
                    l.body,
                });
                break :blk self.addNode(node.tag, loc, .{ .a = extra_start, .b = 0 });
            },
            .for_of_stmt, .for_in_stmt => blk: {
                const f = node.data.for_iter;
                const binding_packed = (@as(u32, f.binding.scope_id) << 16) | f.binding.slot;
                const flags = (@as(u32, if (f.is_for_in) 1 else 0)) |
                    (@as(u32, if (f.is_const) 1 else 0) << 1) |
                    (@as(u32, @backingInt(f.binding.kind)) << 2);
                // Store: [binding_packed, iterable, flags, body]
                const extra_start = try self.addExtra(&.{ binding_packed, f.iterable, flags, f.body });
                break :blk self.addNode(node.tag, loc, .{ .a = extra_start, .b = 0 });
            },
            .switch_stmt => blk: {
                const s = node.data.switch_stmt;
                const list_ref = try self.addListRef(s.cases_start, s.cases_count);
                break :blk self.addNode(.switch_stmt, loc, .{
                    .a = s.discriminant,
                    .b = list_ref,
                });
            },
            .case_clause => blk: {
                const c = node.data.case_clause;
                const list_ref = try self.addListRef(c.body_start, c.body_count);
                break :blk self.addNode(.case_clause, loc, .{
                    .a = c.test_expr,
                    .b = list_ref,
                });
            },
            .match_expr => blk: {
                const m = node.data.match_expr;
                const list_ref = try self.addListRef(m.arms_start, m.arms_count);
                break :blk self.addNode(.match_expr, loc, .{
                    .a = m.discriminant,
                    .b = list_ref,
                });
            },
            .match_arm => blk: {
                const a = node.data.match_arm;
                break :blk self.addNode(.match_arm, loc, .{
                    .a = a.pattern,
                    .b = a.body,
                });
            },
            .match_pattern => blk: {
                const p = node.data.match_pattern;
                break :blk self.addNode(.match_pattern, loc, .{
                    .a = p.props_start,
                    .b = @as(u32, p.props_count),
                });
            },
            .match_type_test => blk: {
                const t = node.data.match_type_test;
                break :blk self.addNode(.match_type_test, loc, .{
                    .a = @backingInt(t.kind),
                    .b = t.predicate,
                });
            },
            .return_stmt, .throw_stmt => self.addNode(node.tag, loc, .{ .a = node.data.opt_value orelse null_node, .b = 0 }),
            .assert_stmt => blk: {
                const a = node.data.assert_stmt;
                break :blk self.addNode(.assert_stmt, loc, .{ .a = a.condition, .b = a.error_expr });
            },
            .break_stmt, .continue_stmt => self.addNode(node.tag, loc, .{ .a = node.data.opt_label orelse 0, .b = 0 }),
            .try_stmt => blk: {
                const t = node.data.try_stmt;
                const binding_packed = (@as(u32, t.catch_binding.scope_id) << 16) | t.catch_binding.slot;
                const extra_start = try self.addExtra(&.{
                    t.try_block,
                    binding_packed,
                    t.catch_block,
                    t.finally_block,
                });
                break :blk self.addNode(.try_stmt, loc, .{ .a = extra_start, .b = 0 });
            },
            .block, .program => blk: {
                const b = node.data.block;
                break :blk self.addNode(node.tag, loc, .{
                    .a = b.stmts_start,
                    .b = @as(u32, b.stmts_count) | (@as(u32, b.scope_id) << 16),
                });
            },
            .expr_stmt => self.addNode(.expr_stmt, loc, .{ .a = node.data.opt_value orelse null_node, .b = 0 }),

            // --- Patterns ---
            .pattern_element, .pattern_rest, .array_pattern => blk: {
                if (node.tag == .array_pattern) {
                    const arr = node.data.array;
                    const b_val = @as(u32, arr.elements_count) | (@as(u32, if (arr.has_spread) 1 else 0) << 16);
                    break :blk self.addNode(node.tag, loc, .{ .a = arr.elements_start, .b = b_val });
                }
                const p = node.data.pattern_elem;
                const binding_packed = (@as(u32, p.binding.scope_id) << 16) | p.binding.slot;
                const extra_start = try self.addExtra(&.{
                    patternKindWord(p.kind, p.binding.kind),
                    binding_packed,
                    p.key,
                    p.key_atom,
                    p.default_value,
                });
                break :blk self.addNode(node.tag, loc, .{ .a = extra_start, .b = 0 });
            },

            // --- Imports/Exports ---
            .import_decl => blk: {
                const i = node.data.import_decl;
                const list_ref = try self.addListRef(i.specifiers_start, i.specifiers_count);
                break :blk self.addNode(.import_decl, loc, .{
                    .a = i.module_idx,
                    .b = list_ref,
                });
            },
            .import_specifier => blk: {
                const i = node.data.import_spec;
                const binding_packed = (@as(u32, i.local_binding.scope_id) << 16) | i.local_binding.slot;
                const extra_start = try self.addExtra(&.{
                    patternKindWord(i.kind, i.local_binding.kind),
                    i.imported_atom,
                    binding_packed,
                });
                break :blk self.addNode(.import_specifier, loc, .{ .a = extra_start, .b = 0 });
            },
            .export_decl => blk: {
                const e = node.data.export_decl;
                const extra_start = try self.addExtra(&.{
                    @backingInt(e.kind),
                    e.declaration,
                    e.specifiers_start,
                    e.specifiers_count,
                    e.from_module_idx,
                });
                break :blk self.addNode(.export_decl, loc, .{ .a = extra_start, .b = 0 });
            },

            // --- Labeled ---
            .labeled_stmt => blk: {
                const l = node.data.labeled;
                break :blk self.addNode(.labeled_stmt, loc, .{ .a = l.label_atom, .b = l.body });
            },

            // --- Call variants ---
            .method_call => blk: {
                const c = node.data.call;
                const list_ref = try self.addListRef(c.args_start, c.args_count);
                break :blk self.addNode(.method_call, loc, .{ .a = c.callee, .b = list_ref });
            },

            // --- Object method/accessor ---
            .object_method, .object_getter, .object_setter => blk: {
                const p = node.data.property;
                const b_val = try packNode24(p.value, true);
                break :blk self.addNode(node.tag, loc, .{ .a = p.key, .b = b_val });
            },

            // --- Sequence/Comma ---
            .sequence_expr, .comma_expr => blk: {
                const arr = node.data.array;
                break :blk self.addNode(node.tag, loc, .{
                    .a = arr.elements_start,
                    .b = @as(u32, arr.elements_count),
                });
            },

            // --- Pattern default ---
            .pattern_default => blk: {
                const p = node.data.pattern_elem;
                const binding_packed = (@as(u32, p.binding.scope_id) << 16) | p.binding.slot;
                const extra_start = try self.addExtra(&.{
                    patternKindWord(p.kind, p.binding.kind),
                    binding_packed,
                    p.key,
                    p.key_atom,
                    p.default_value,
                });
                break :blk self.addNode(.pattern_default, loc, .{ .a = extra_start, .b = 0 });
            },

            // --- Import/Export variants ---
            .import_default, .import_namespace => blk: {
                const i = node.data.import_spec;
                const binding_packed = (@as(u32, i.local_binding.scope_id) << 16) | i.local_binding.slot;
                const extra_start = try self.addExtra(&.{
                    patternKindWord(i.kind, i.local_binding.kind),
                    i.imported_atom,
                    binding_packed,
                });
                break :blk self.addNode(node.tag, loc, .{ .a = extra_start, .b = 0 });
            },
            .export_specifier => blk: {
                const e = node.data.export_decl;
                const extra_start = try self.addExtra(&.{
                    @backingInt(e.kind),
                    e.declaration,
                    e.specifiers_start,
                    e.specifiers_count,
                    e.from_module_idx,
                });
                break :blk self.addNode(.export_specifier, loc, .{ .a = extra_start, .b = 0 });
            },
            .export_default, .export_all => self.addNode(node.tag, loc, .{ .a = node.data.opt_value orelse null_node, .b = 0 }),

            // --- Internal markers (no data) ---
            .param_list, .arg_list, .stmt_list => self.addNode(node.tag, loc, .{ .a = 0, .b = 0 }),
        };

        const binding_name: ?u16 = switch (node.tag) {
            .identifier => node.data.binding.name_atom,
            .var_decl, .function_decl => node.data.var_decl.binding.name_atom,
            .for_of_stmt, .for_in_stmt => node.data.for_iter.binding.name_atom,
            .try_stmt => node.data.try_stmt.catch_binding.name_atom,
            .pattern_element, .pattern_rest, .pattern_default => node.data.pattern_elem.binding.name_atom,
            .import_specifier, .import_default, .import_namespace => node.data.import_spec.local_binding.name_atom,
            else => null,
        };
        if (binding_name) |name_atom| self.setBindingName(idx, name_atom);
        return idx;
    }

    /// Get a Node struct from index (for compatibility during migration)
    /// Note: This reconstructs the Node from SoA storage, less efficient than direct access
    pub fn get(self: *const IRStore, idx: NodeIndex) ?Node {
        if (idx >= self.tags.items.len) return null;
        const tag = self.tags.items[idx];
        const loc = self.locs.items[idx];
        const d = self.data.items[idx];

        return Node{
            .tag = tag,
            .loc = loc,
            .data = switch (tag) {
                .lit_int => .{ .int_value = d.toInt() },
                .lit_float => .{ .float_idx = @truncate(d.a) },
                .lit_string => .{ .string_idx = @truncate(d.a) },
                .lit_bool => .{ .bool_value = d.a != 0 },
                .lit_null, .lit_undefined => .{ .none = {} },
                .identifier => .{ .binding = self.getBinding(idx) },
                .binary_op => blk: {
                    const bin = d.toBinary();
                    break :blk .{ .binary = .{ .op = bin.op, .left = bin.left, .right = bin.right } };
                },
                .unary_op => .{ .unary = .{ .op = @fromBackingInt(@intCast(@as(u4, @truncate(d.a)))), .operand = d.b } },
                .return_stmt,
                .throw_stmt,
                .expr_stmt,
                .spread,
                .object_spread,
                .yield_expr,
                .await_expr,
                => .{ .opt_value = if (d.a == null_node) null else d.a },
                .block, .program => .{ .block = .{
                    .stmts_start = d.a,
                    .stmts_count = @truncate(d.b),
                    .scope_id = @truncate(d.b >> 16),
                } },
                // For complex types, return minimal data - full reconstruction available via IrView
                else => .{ .none = {} },
            },
        };
    }
};

test "node creation" {
    const loc = SourceLocation{ .line = 1, .column = 1, .offset = 0 };

    const int_node = Node.litInt(loc, 42);
    try std.testing.expectEqual(NodeTag.lit_int, int_node.tag);
    try std.testing.expectEqual(@as(i32, 42), int_node.data.int_value);

    const bool_node = Node.litBool(loc, true);
    try std.testing.expectEqual(NodeTag.lit_bool, bool_node.tag);
    try std.testing.expect(bool_node.data.bool_value);
}

test "source-backed strings keep borrowing explicit across failures and duplicates" {
    const Probe = struct {
        fn run(allocator: std.mem.Allocator) !void {
            const source = "plain quoted text";
            var pool = ConstantPool.initBorrowingSource(allocator, source);
            defer pool.deinit();
            const plain = try pool.addSourceString(source[0..5]);
            try std.testing.expect(pool.getString(plain).?.ptr == source.ptr);
            try std.testing.expectEqual(plain, try pool.addOwnedString(try allocator.dupe(u8, "plain")));
            const escaped = try pool.addOwnedString(try allocator.dupe(u8, "decoded\nvalue"));
            try std.testing.expectEqualStrings("decoded\nvalue", pool.getString(escaped).?);
            const copied = try pool.addString("generated");
            try std.testing.expect(!pool.isSourceSlice(pool.getString(copied).?));
            try std.testing.expectError(error.InvalidSourceSlice, pool.addSourceString("unrelated"));
            const empty = try pool.addSourceString(source[source.len..]);
            try std.testing.expectEqualStrings("", pool.getString(empty).?);
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Probe.run, .{});

    var source = [_]u8{ 'c', 'o', 'p', 'y' };
    var pool = ConstantPool.init(std.testing.allocator);
    defer pool.deinit();
    const copied = try pool.addSourceString(&source);
    source[0] = 'X';
    try std.testing.expectEqualStrings("copy", pool.getString(copied).?);
}

test "constant pool" {
    var pool = ConstantPool.init(std.testing.allocator);
    defer pool.deinit();

    const idx1 = try pool.addString("hello");
    const idx2 = try pool.addString("world");
    const idx3 = try pool.addString("hello"); // Duplicate

    try std.testing.expectEqual(@as(u16, 0), idx1);
    try std.testing.expectEqual(@as(u16, 1), idx2);
    try std.testing.expectEqual(@as(u16, 0), idx3); // Should return existing

    try std.testing.expectEqualStrings("hello", pool.getString(0).?);
    try std.testing.expectEqualStrings("world", pool.getString(1).?);
}

test "owned strings transfer storage and release duplicates through allocation failures" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn run(allocator: std.mem.Allocator) !void {
            var pool = ConstantPool.init(allocator);
            defer pool.deinit();
            const owned = try allocator.dupe(u8, "decoded\nvalue");
            const address = owned.ptr;
            const idx = try pool.addOwnedString(owned);
            try std.testing.expect(pool.getString(idx).?.ptr == address);
            const duplicate = try allocator.dupe(u8, "decoded\nvalue");
            try std.testing.expectEqual(idx, try pool.addOwnedString(duplicate));
            try std.testing.expectEqual(idx, try pool.addString("decoded\nvalue"));
            try std.testing.expectEqual(@as(usize, 1), pool.strings.items.len);
            try std.testing.expectEqualStrings("decoded\nvalue", pool.getString(idx).?);
        }
    }.run, .{});
}

test "IRStore basic operations" {
    var store = IRStore.init(std.testing.allocator);
    defer store.deinit();

    const loc = SourceLocation{ .line = 1, .column = 1, .offset = 0 };

    // Add integer literal
    const idx1 = try store.add(Node.litInt(loc, 42));
    try std.testing.expectEqual(@as(NodeIndex, 0), idx1);
    try std.testing.expectEqual(NodeTag.lit_int, store.getTag(idx1));
    try std.testing.expectEqual(@as(i32, 42), store.getData(idx1).toInt());

    // Add binary expression
    const idx2 = try store.add(Node.litInt(loc, 10));
    const idx3 = try store.add(Node.binaryOp(loc, .add, idx1, idx2));

    try std.testing.expectEqual(NodeTag.binary_op, store.getTag(idx3));
    const bin = store.getData(idx3).toBinary();
    try std.testing.expectEqual(BinaryOp.add, bin.op);
    try std.testing.expectEqual(idx1, bin.left);
    try std.testing.expectEqual(idx2, bin.right);
}

test "IRStore identifier binding" {
    var store = IRStore.init(std.testing.allocator);
    defer store.deinit();

    const loc = SourceLocation{ .line = 1, .column = 1, .offset = 0 };

    const binding = BindingRef{
        .scope_id = 5,
        .slot = 3,
        .name_atom = 17,
        .kind = .upvalue,
    };

    const idx = try store.add(Node.identifier(loc, binding));
    const unpacked = store.getBinding(idx);

    try std.testing.expectEqual(@as(ScopeId, 5), unpacked.scope_id);
    try std.testing.expectEqual(@as(u16, 3), unpacked.slot);
    try std.testing.expectEqual(@as(u16, 17), unpacked.name_atom);
    try std.testing.expectEqual(BindingRef.BindingKind.upvalue, unpacked.kind);
}

test "pattern and import bindings keep a scope at 8192 and above" {
    // The binding kind sat in bits 29 to 31 of the packed binding, over the
    // top three bits of the scope, so these read back as scope 808 with a
    // corrupted kind.
    var store = IRStore.init(std.testing.allocator);
    defer store.deinit();
    var constants = ConstantPool.init(std.testing.allocator);
    defer constants.deinit();
    const loc = SourceLocation{ .line = 1, .column = 1, .offset = 0 };
    const binding = BindingRef{ .scope_id = 9000, .slot = 7, .name_atom = 0, .kind = .argument };

    const elem: Node.PatternElem = .{ .kind = .simple, .binding = binding, .key = null_node, .key_atom = 0, .default_value = null_node };
    const param = try store.add(.{ .tag = .pattern_element, .loc = loc, .data = .{ .pattern_elem = elem } });
    const defaulted = try store.add(.{ .tag = .pattern_default, .loc = loc, .data = .{ .pattern_elem = elem } });
    var local = binding;
    local.kind = .local;
    const spec: Node.ImportSpec = .{ .kind = .namespace, .imported_atom = 4, .local_binding = local };
    const import = try store.add(.{ .tag = .import_specifier, .loc = loc, .data = .{ .import_spec = spec } });

    const view = IrView.fromIRStore(&store, &constants);
    for ([_]NodeIndex{ param, defaulted }) |idx| {
        const read = view.getPatternElem(idx) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqual(@as(ScopeId, 9000), read.binding.scope_id);
        try std.testing.expectEqual(@as(u16, 7), read.binding.slot);
        try std.testing.expectEqual(BindingRef.BindingKind.argument, read.binding.kind);
        try std.testing.expectEqual(Node.PatternElem.PatternKind.simple, read.kind);
    }
    const read_import = view.getImportSpec(import) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(ScopeId, 9000), read_import.local_binding.scope_id);
    try std.testing.expectEqual(BindingRef.BindingKind.local, read_import.local_binding.kind);
    try std.testing.expectEqual(Node.ImportSpec.ImportKind.namespace, read_import.kind);
    try std.testing.expectEqual(@as(u16, 4), read_import.imported_atom);
}

test "IRStore extra data" {
    var store = IRStore.init(std.testing.allocator);
    defer store.deinit();

    // Add some extra data (e.g., for function parameters)
    const extra_data = [_]u32{ 10, 20, 30, 40 };
    const start = try store.addExtra(&extra_data);

    try std.testing.expectEqual(@as(u32, 0), start);

    const retrieved = store.extra.items[start..][0..4];
    try std.testing.expectEqual(@as(u32, 10), retrieved[0]);
    try std.testing.expectEqual(@as(u32, 20), retrieved[1]);
    try std.testing.expectEqual(@as(u32, 30), retrieved[2]);
    try std.testing.expectEqual(@as(u32, 40), retrieved[3]);
}

test "IRStore list references preserve offsets above u16" {
    const allocator = std.testing.allocator;
    var store = IRStore.init(allocator);
    defer store.deinit();

    var constants = ConstantPool.init(allocator);
    defer constants.deinit();

    const padding = try allocator.alloc(NodeIndex, std.math.maxInt(u16) + 1);
    defer allocator.free(padding);
    @memset(padding, null_node);
    _ = try store.addIndexList(padding);
    const high_start = try store.addIndexList(&.{ 1, 2, 3, 4, 5, 6, 7 });
    try std.testing.expect(high_start > std.math.maxInt(u16));

    const loc = SourceLocation{ .line = 1, .column = 1, .offset = 0 };
    const call_idx = try store.add(.{
        .tag = .call,
        .loc = loc,
        .data = .{ .call = .{ .callee = 10, .args_start = high_start, .args_count = 2 } },
    });
    const method_call_idx = try store.add(.{
        .tag = .method_call,
        .loc = loc,
        .data = .{ .call = .{ .callee = 11, .args_start = high_start, .args_count = 3 } },
    });
    const switch_idx = try store.add(.{
        .tag = .switch_stmt,
        .loc = loc,
        .data = .{ .switch_stmt = .{ .discriminant = 12, .cases_start = high_start, .cases_count = 4 } },
    });
    const case_idx = try store.add(.{
        .tag = .case_clause,
        .loc = loc,
        .data = .{ .case_clause = .{ .test_expr = 13, .body_start = high_start, .body_count = 5 } },
    });
    const match_idx = try store.add(.{
        .tag = .match_expr,
        .loc = loc,
        .data = .{ .match_expr = .{ .discriminant = 14, .arms_start = high_start, .arms_count = 6 } },
    });
    const import_idx = try store.add(.{
        .tag = .import_decl,
        .loc = loc,
        .data = .{ .import_decl = .{ .module_idx = 15, .specifiers_start = high_start, .specifiers_count = 7 } },
    });

    const view = IrView.fromIRStore(&store, &constants);
    try std.testing.expectEqual(high_start, view.getCall(call_idx).?.args_start);
    try std.testing.expectEqual(high_start, view.getCall(method_call_idx).?.args_start);
    try std.testing.expectEqual(high_start, view.getSwitchStmt(switch_idx).?.cases_start);
    try std.testing.expectEqual(high_start, view.getCaseClause(case_idx).?.body_start);
    try std.testing.expectEqual(high_start, view.getMatchExpr(match_idx).?.arms_start);
    try std.testing.expectEqual(high_start, view.getImportDecl(import_idx).?.specifiers_start);
}

test "IRStore memory efficiency" {
    // Verify DataPayload is exactly 8 bytes
    try std.testing.expectEqual(@as(usize, 8), @sizeOf(DataPayload));

    // NodeTag should be 1 byte
    try std.testing.expectEqual(@as(usize, 1), @sizeOf(NodeTag));
}

test "packed node operands reject overflow and preserve nullable sentinels" {
    var store = IRStore.init(std.testing.allocator);
    defer store.deinit();
    var constants = ConstantPool.init(std.testing.allocator);
    defer constants.deinit();
    const view = IrView.fromIRStore(&store, &constants);
    const loc: SourceLocation = .{ .line = 1, .column = 1, .offset = 0 };
    const max = std.math.maxInt(u24);
    const binary = try store.add(Node.binaryOp(loc, .mul, max, 0x1000000));
    try std.testing.expectEqual(@as(NodeIndex, max), view.getBinary(binary).?.left);
    try std.testing.expectEqual(@as(NodeIndex, 0x1000000), view.getBinary(binary).?.right);
    try std.testing.expectError(error.NodeIndexOverflow, store.add(Node.binaryOp(loc, .add, max + 1, 0)));
    try std.testing.expectError(error.NodeIndexOverflow, store.add(Node.binaryOp(loc, .add, null_node, 0)));
    const assignment = Node{ .tag = .assignment, .loc = loc, .data = .{ .assignment = .{ .target = 0, .value = max, .op = .add } } };
    const assigned = try store.add(assignment);
    try std.testing.expectEqual(@as(NodeIndex, max), view.getAssignment(assigned).?.value);
    var overflow_assignment = assignment;
    overflow_assignment.data.assignment.value = max + 1;
    try std.testing.expectError(error.NodeIndexOverflow, store.add(overflow_assignment));
    const property = Node{ .tag = .object_property, .loc = loc, .data = .{ .property = .{ .key = 0, .value = max - 1, .is_shorthand = true } } };
    const prop = try store.add(property);
    try std.testing.expectEqual(@as(NodeIndex, max - 1), view.getProperty(prop).?.value);
    try std.testing.expect(view.getProperty(prop).?.is_shorthand);
    var null_property = property;
    null_property.data.property.value = null_node;
    const absent = try store.add(null_property);
    try std.testing.expectEqual(null_node, view.getProperty(absent).?.value);
    for ([_]NodeTag{ .object_property, .object_method, .object_getter, .object_setter }) |tag| {
        var overflow_property = property;
        overflow_property.tag = tag;
        for ([_]NodeIndex{ max, max + 1 }) |value| {
            overflow_property.data.property.value = value;
            try std.testing.expectError(error.NodeIndexOverflow, store.add(overflow_property));
        }
    }
    try std.testing.expectEqual(@as(usize, 4), store.len());
}

test "failed node append preserves the complete parallel prefix" {
    var no_resize = std.testing.FailingAllocator.init(std.testing.allocator, .{ .resize_fail_index = 0 });
    try std.testing.checkAllAllocationFailures(no_resize.allocator(), struct {
        fn run(allocator: std.mem.Allocator) !void {
            var store = IRStore.init(allocator);
            defer store.deinit();
            const loc: SourceLocation = .{ .line = 1, .column = 1, .offset = 0 };
            // Cross several growth boundaries, including the initially empty
            // store, so failure is tested for each independently growing column.
            for (0..64) |i| {
                _ = store.add(Node.litInt(loc, @intCast(i))) catch |err| {
                    try std.testing.expectEqual(i, store.tags.items.len);
                    try std.testing.expectEqual(i, store.locs.items.len);
                    try std.testing.expectEqual(i, store.data.items.len);
                    try std.testing.expectEqual(i, store.binding_name_atoms.items.len);
                    for (0..i) |kept| try std.testing.expectEqual(@as(i32, @intCast(kept)), store.getData(@intCast(kept)).toInt());
                    return err;
                };
            }
        }
    }.run, .{});
}

// ============================================================================
// IrView
// ============================================================================

/// Read-only view over an `IRStore` and its constant pool.
///
/// Usage:
/// ```zig
/// var view = IrView.fromIRStore(&store, &ir_constants);
/// const tag = view.getTag(idx);
/// const binary = view.getBinary(idx);
/// ```
pub const IrView = struct {
    store: *const IRStore,
    ir_constants: *const ConstantPool,

    /// Create view from IRStore (Structure-of-Arrays)
    pub fn fromIRStore(store: *const IRStore, constants: *const ConstantPool) IrView {
        return .{
            .store = store,
            .ir_constants = constants,
        };
    }

    // ============ Core Accessors ============

    /// Get node tag
    pub fn getTag(self: IrView, idx: NodeIndex) ?NodeTag {
        const ir = self.store;
        return if (idx < ir.tags.items.len) ir.tags.items[idx] else null;
    }

    /// Invoke `visit(ctx, child)` for each structural child node-index of `node`,
    /// in source order. This centralizes the plain statement-level descent that
    /// the strict-checker pre-order walkers (`collectStaticLiterals`,
    /// `collectAnnotatedFunctions`) each open-coded; callers keep their own
    /// per-tag leaf actions and use this only for the recursion. Comptime
    /// `visit` is monomorphized per call site, so there is no indirect-call cost.
    ///
    /// This is a pure structural descent with no analysis state and no ordering
    /// policy beyond source order. It does not enter expressions. An
    /// expression-walking analysis (`collectCallCounts`, `collectAssignments`)
    /// uses `expressionChildren`, and a flow-sensitive one (`bool_checker`,
    /// `flow_checker`) keeps its own arms; do not route them through here.
    pub fn forEachChild(
        self: IrView,
        node: NodeIndex,
        ctx: anytype,
        comptime visit: fn (@TypeOf(ctx), NodeIndex) void,
    ) void {
        if (node == null_node) return;
        const tag = self.getTag(node) orelse return;
        switch (tag) {
            .program, .block => {
                const block = self.getBlock(node) orelse return;
                for (0..block.stmts_count) |i| {
                    visit(ctx, self.getListIndex(block.stmts_start, @intCast(i)));
                }
            },
            .export_decl => {
                const export_decl = self.getExportDecl(node) orelse return;
                visit(ctx, export_decl.declaration);
            },
            .var_decl, .function_decl => {
                const decl = self.getVarDecl(node) orelse return;
                visit(ctx, decl.init);
            },
            .function_expr, .arrow_function => {
                if (self.getFunction(node)) |func| visit(ctx, func.body);
            },
            .if_stmt => {
                const if_stmt = self.getIfStmt(node) orelse return;
                visit(ctx, if_stmt.then_branch);
                visit(ctx, if_stmt.else_branch);
            },
            .for_of_stmt => {
                const for_iter = self.getForIter(node) orelse return;
                visit(ctx, for_iter.body);
            },
            else => {},
        }
    }

    /// Whether `target` is `root` or lies below it. Descends through statements
    /// and expressions, including the bodies of nested functions. A tag this
    /// descent does not name is treated as a leaf, so the answer is `false` for a
    /// target inside it: callers that suppress a message on a positive answer
    /// fail toward showing the message.
    pub fn subtreeContains(self: IrView, root: NodeIndex, target: NodeIndex) bool {
        if (root == null_node) return false;
        if (root == target) return true;
        const tag = self.getTag(root) orelse return false;
        switch (tag) {
            .program, .block => {
                const block = self.getBlock(root) orelse return false;
                for (0..block.stmts_count) |i| {
                    if (self.subtreeContains(self.getListIndex(block.stmts_start, @intCast(i)), target)) return true;
                }
            },
            .return_stmt, .expr_stmt => {
                if (self.getOptValue(root)) |value| return self.subtreeContains(value, target);
            },
            .var_decl => {
                const decl = self.getVarDecl(root) orelse return false;
                return self.subtreeContains(decl.init, target);
            },
            .if_stmt => {
                const stmt = self.getIfStmt(root) orelse return false;
                return self.subtreeContains(stmt.condition, target) or
                    self.subtreeContains(stmt.then_branch, target) or
                    self.subtreeContains(stmt.else_branch, target);
            },
            .for_of_stmt => {
                const stmt = self.getForIter(root) orelse return false;
                return self.subtreeContains(stmt.iterable, target) or
                    self.subtreeContains(stmt.body, target);
            },
            .binary_op => {
                const expr = self.getBinary(root) orelse return false;
                return self.subtreeContains(expr.left, target) or self.subtreeContains(expr.right, target);
            },
            .unary_op => {
                const expr = self.getUnary(root) orelse return false;
                return self.subtreeContains(expr.operand, target);
            },
            // The operand of a spread is payload word `a` (`getOptValue`).
            // `getUnary` reads word `b`, which is zero for a spread.
            .spread, .object_spread => {
                if (self.getOptValue(root)) |value| return self.subtreeContains(value, target);
            },
            .assert_stmt => {
                const stmt = self.getAssertStmt(root) orelse return false;
                return self.subtreeContains(stmt.condition, target) or
                    self.subtreeContains(stmt.error_expr, target);
            },
            .ternary => {
                const expr = self.getTernary(root) orelse return false;
                return self.subtreeContains(expr.condition, target) or
                    self.subtreeContains(expr.then_branch, target) or
                    self.subtreeContains(expr.else_branch, target);
            },
            .call, .method_call => {
                const call = self.getCall(root) orelse return false;
                if (self.subtreeContains(call.callee, target)) return true;
                for (0..call.args_count) |i| {
                    if (self.subtreeContains(self.getListIndex(call.args_start, @intCast(i)), target)) return true;
                }
            },
            .member_access, .optional_chain, .computed_access => {
                const member = self.getMember(root) orelse return false;
                return self.subtreeContains(member.object, target) or self.subtreeContains(member.computed, target);
            },
            .assignment => {
                const assign = self.getAssignment(root) orelse return false;
                return self.subtreeContains(assign.target, target) or self.subtreeContains(assign.value, target);
            },
            .array_literal => {
                const arr = self.getArray(root) orelse return false;
                for (0..arr.elements_count) |i| {
                    if (self.subtreeContains(self.getListIndex(arr.elements_start, @intCast(i)), target)) return true;
                }
            },
            .object_literal => {
                const obj = self.getObject(root) orelse return false;
                for (0..obj.properties_count) |i| {
                    const prop_idx = self.getListIndex(obj.properties_start, @intCast(i));
                    if (self.subtreeContains(prop_idx, target)) return true;
                }
            },
            .object_property => {
                const prop = self.getProperty(root) orelse return false;
                return self.subtreeContains(prop.key, target) or self.subtreeContains(prop.value, target);
            },
            .function_decl, .function_expr, .arrow_function => {
                const func = (if (tag == .function_decl)
                    self.getFunctionOfDecl(root)
                else
                    self.getFunction(root)) orelse return false;
                return self.subtreeContains(func.body, target);
            },
            .match_expr => {
                const match = self.getMatchExpr(root) orelse return false;
                if (self.subtreeContains(match.discriminant, target)) return true;
                for (0..match.arms_count) |i| {
                    if (self.subtreeContains(self.getListIndex(match.arms_start, @intCast(i)), target)) return true;
                }
            },
            .match_arm => {
                const arm = self.getMatchArm(root) orelse return false;
                return self.subtreeContains(arm.pattern, target) or self.subtreeContains(arm.body, target);
            },
            // exhaustive: falling through reaches `return false` - the target was
            // not found in this subtree. The arms above cover every node with
            // children to search; the rest are leaves that can only be the
            // target itself, which the identity check at the top already made.
            else => {},
        }
        return false;
    }

    /// Iterator over the expression children of one node. Built by
    /// `expressionChildren`; see that function for the contract.
    ///
    /// A node holds at most four fixed children (a `for` loop) and at most one
    /// index list (call arguments, array elements, block statements, and so
    /// on), and the fixed children always come before the list in source
    /// order. The iterator therefore keeps a four-slot buffer and one list
    /// cursor, with no allocation.
    pub const ExpressionChildren = struct {
        view: IrView,
        fixed: [4]NodeIndex = .{ null_node, null_node, null_node, null_node },
        fixed_len: u8 = 0,
        fixed_pos: u8 = 0,
        list_start: NodeIndex = null_node,
        list_count: u16 = 0,
        list_pos: u16 = 0,

        fn push(self: *ExpressionChildren, child: NodeIndex) void {
            self.fixed[self.fixed_len] = child;
            self.fixed_len += 1;
        }

        fn setList(self: *ExpressionChildren, start: NodeIndex, count: u16) void {
            self.list_start = start;
            self.list_count = count;
        }

        /// The next child node index, or null when the node has no more.
        /// A `null_node` child (an absent `else`, a hole in an array) is
        /// skipped and never returned.
        pub fn next(self: *ExpressionChildren) ?NodeIndex {
            while (self.fixed_pos < self.fixed_len) {
                const child = self.fixed[self.fixed_pos];
                self.fixed_pos += 1;
                if (child != null_node) return child;
            }
            if (self.list_start == null_node) return null;
            while (self.list_pos < self.list_count) {
                const child = self.view.getListIndex(self.list_start, self.list_pos);
                self.list_pos += 1;
                if (child != null_node) return child;
            }
            return null;
        }
    };

    /// The expression children of `node`: every child node that holds code,
    /// in source order, including function bodies. Use it as
    /// `var it = view.expressionChildren(node); while (it.next()) |child| ...`.
    /// An analysis walk names the tags it treats specially and descends through
    /// this map for the rest, so a new node kind is handled by default and
    /// a new `NodeTag` member fails to compile here, in the one place that
    /// knows the storage of every node.
    ///
    /// The map is exhaustive on purpose: the switch below names every
    /// `NodeTag` member and has no `else` arm. A `null_node` child is skipped.
    ///
    /// Excluded, with the reason:
    /// - Binding positions: a declared name, a parameter (`function_expr` and
    ///   `arrow_function` yield the body and not the parameter list), a
    ///   `for...of` binding, a catch binding, and the nested pattern of a
    ///   `pattern_element`. A binding holds no code. A default value inside a
    ///   `pattern_element`, `pattern_rest`, or `pattern_default` is code and
    ///   is yielded.
    /// - Import specifiers: they name bindings, so `import_decl` yields nothing.
    ///   `export_decl` yields its declaration. The specifier list of an export
    ///   is names, and is not yielded.
    /// - `match` patterns: `match_arm` yields its body and not its pattern,
    ///   and `match_pattern`, `array_pattern`, and `match_type_test` yield
    ///   nothing. A pattern test does run at runtime. The parser builds the
    ///   predicate of a type test as a call, for example `isDict(x)`. A walk
    ///   that reached it would send it to a call handler, such as the effect
    ///   walk's `handleCall`, which finds no `importOf` or `userFnOf` match
    ///   and sets `row.lower_bound` on every type-test `match`. No consumer
    ///   needs pattern children today. A consumer that does must read the
    ///   pattern through `getMatchArm` and `getMatchTypeTest`.
    /// - The key of an object property when it is a string literal: it is the
    ///   field name and not code. The parser refuses computed keys today, but
    ///   the storage keeps a key node, and codegen emits a key that is not a
    ///   `lit_string` as a computed key. Such a key is yielded, before the
    ///   value.
    ///
    /// Order: a `do...while` yields its body before its condition, as in
    /// the source. A `for` loop yields init, condition, update, then body.
    ///
    /// Signature choice: the result is an iterator and not a callback taking
    /// a visitor. The callers have different error sets (`WalkError`,
    /// `error{OutOfMemory}`, and `void`). A callback would force one error
    /// set, or `anyerror`, on all of them. With an iterator, the caller's own
    /// loop body returns its own errors with `try` and no signature changes.
    /// An iterator also lets the caller recurse or stop early with `break`.
    pub fn expressionChildren(self: IrView, node: NodeIndex) ExpressionChildren {
        var it: ExpressionChildren = .{ .view = self };
        if (node == null_node) return it;
        const tag = self.getTag(node) orelse return it;
        switch (tag) {
            // Leaves, and internal markers with no payload.
            .lit_int,
            .lit_float,
            .lit_string,
            .lit_bool,
            .lit_null,
            .lit_undefined,
            .identifier,
            .break_stmt,
            .continue_stmt,
            .import_specifier,
            .import_default,
            .import_namespace,
            .param_list,
            .arg_list,
            .stmt_list,
            => {},
            // A module path and binding names only.
            .import_decl => {},
            // Match patterns are excluded; see the doc comment.
            .match_pattern, .match_type_test, .array_pattern => {},
            .binary_op => if (self.getBinary(node)) |expr| {
                it.push(expr.left);
                it.push(expr.right);
            },
            .unary_op => if (self.getUnary(node)) |expr| {
                it.push(expr.operand);
            },
            .ternary => if (self.getTernary(node)) |expr| {
                it.push(expr.condition);
                it.push(expr.then_branch);
                it.push(expr.else_branch);
            },
            .call, .method_call => if (self.getCall(node)) |call| {
                it.push(call.callee);
                it.setList(call.args_start, call.args_count);
            },
            .member_access, .optional_chain, .computed_access => if (self.getMember(node)) |member| {
                it.push(member.object);
                it.push(member.computed);
            },
            .assignment => if (self.getAssignment(node)) |assign| {
                it.push(assign.target);
                it.push(assign.value);
            },
            .array_literal => if (self.getArray(node)) |arr| {
                it.setList(arr.elements_start, arr.elements_count);
            },
            // `sequence_expr` and `comma_expr` store their elements as an
            // array does: the count is the whole of word `b`.
            .sequence_expr, .comma_expr => if (self.getArray(node)) |arr| {
                it.setList(arr.elements_start, arr.elements_count);
            },
            .object_literal => if (self.getObject(node)) |obj| {
                it.setList(obj.properties_start, obj.properties_count);
            },
            .object_property, .object_method, .object_getter, .object_setter => if (self.getProperty(node)) |prop| {
                if (prop.key != null_node and self.getTag(prop.key) != .lit_string) it.push(prop.key);
                it.push(prop.value);
            },
            // The operand is payload word `a`, read by `getOptValue`.
            // `getUnary` reads word `b`, which is zero here, and is wrong.
            .spread,
            .object_spread,
            .await_expr,
            .yield_expr,
            .throw_stmt,
            .return_stmt,
            .expr_stmt,
            .export_default,
            .export_all,
            => if (self.getOptValue(node)) |operand| {
                it.push(operand);
            },
            .function_expr, .arrow_function => if (self.getFunction(node)) |func| {
                it.push(func.body);
            },
            // A `function_decl` holds `var_decl` data: a binding and the
            // function expression as its initializer.
            .function_decl, .var_decl => if (self.getVarDecl(node)) |decl| {
                it.push(decl.init);
            },
            .if_stmt => if (self.getIfStmt(node)) |stmt| {
                it.push(stmt.condition);
                it.push(stmt.then_branch);
                it.push(stmt.else_branch);
            },
            .for_stmt, .while_stmt => if (self.getLoop(node)) |loop| {
                it.push(loop.init);
                it.push(loop.condition);
                it.push(loop.update);
                it.push(loop.body);
            },
            .do_while_stmt => if (self.getLoop(node)) |loop| {
                it.push(loop.body);
                it.push(loop.condition);
            },
            .for_of_stmt, .for_in_stmt => if (self.getForIter(node)) |stmt| {
                it.push(stmt.iterable);
                it.push(stmt.body);
            },
            .switch_stmt => if (self.getSwitchStmt(node)) |stmt| {
                it.push(stmt.discriminant);
                it.setList(stmt.cases_start, stmt.cases_count);
            },
            .case_clause => if (self.getCaseClause(node)) |clause| {
                it.push(clause.test_expr);
                it.setList(clause.body_start, clause.body_count);
            },
            .match_expr => if (self.getMatchExpr(node)) |match| {
                it.push(match.discriminant);
                it.setList(match.arms_start, match.arms_count);
            },
            // The IR has no guard, so the body is the only expression.
            .match_arm => if (self.getMatchArm(node)) |arm| {
                it.push(arm.body);
            },
            .assert_stmt => if (self.getAssertStmt(node)) |stmt| {
                it.push(stmt.condition);
                it.push(stmt.error_expr);
            },
            .try_stmt => if (self.getTryBlocks(node)) |blocks| {
                it.push(blocks.try_block);
                it.push(blocks.catch_block);
                it.push(blocks.finally_block);
            },
            .labeled_stmt => if (self.getLabeledBody(node)) |body| {
                it.push(body);
            },
            .block, .program => if (self.getBlock(node)) |block| {
                it.setList(block.stmts_start, block.stmts_count);
            },
            // The nested pattern is a binding position. The default value is
            // code and runs when the matched value is undefined.
            .pattern_element, .pattern_rest, .pattern_default => if (self.getPatternElem(node)) |elem| {
                it.push(elem.default_value);
            },
            .export_decl => if (self.getExportDecl(node)) |decl| {
                it.push(decl.declaration);
            },
            // `export_specifier` shares the `export_decl` storage. The
            // specifier names a binding. The `declaration` word is null for a
            // specifier, and is read only so that code stored there is not
            // lost.
            .export_specifier => if (self.getExportDecl(node)) |decl| {
                it.push(decl.declaration);
            },
        }
        return it;
    }

    /// Get node source location
    pub fn getLoc(self: IrView, idx: NodeIndex) ?SourceLocation {
        const ir = self.store;
        return if (idx < ir.locs.items.len) ir.locs.items[idx] else null;
    }

    /// Check if node index is valid
    pub fn isValid(self: IrView, idx: NodeIndex) bool {
        if (idx == null_node) return false;
        const ir = self.store;
        return idx < ir.tags.items.len;
    }

    /// Get total node count (useful for capacity pre-allocation)
    pub fn nodeCount(self: IrView) usize {
        const ir = self.store;
        return ir.tags.items.len;
    }

    /// Get index from list storage
    pub fn getListIndex(self: IrView, list_start: NodeIndex, offset: u16) NodeIndex {
        const ir = self.store;
        return ir.getListIndex(list_start, offset);
    }

    // ============ Literal Accessors ============

    /// Get integer literal value
    pub fn getIntValue(self: IrView, idx: NodeIndex) ?i32 {
        const ir = self.store;
        return if (idx < ir.data.items.len) ir.data.items[idx].toInt() else null;
    }

    /// Get float literal index into constant pool
    pub fn getFloatIdx(self: IrView, idx: NodeIndex) ?u16 {
        const ir = self.store;
        return if (idx < ir.data.items.len) @truncate(ir.data.items[idx].a) else null;
    }

    /// Get string literal index into constant pool
    pub fn getStringIdx(self: IrView, idx: NodeIndex) ?u16 {
        const ir = self.store;
        return if (idx < ir.data.items.len) @truncate(ir.data.items[idx].a) else null;
    }

    /// Get boolean literal value
    pub fn getBoolValue(self: IrView, idx: NodeIndex) ?bool {
        const ir = self.store;
        return if (idx < ir.data.items.len) ir.data.items[idx].a != 0 else null;
    }

    // ============ Expression Accessors ============

    /// Get identifier/binding reference
    pub fn getBinding(self: IrView, idx: NodeIndex) ?BindingRef {
        const ir = self.store;
        return if (idx < ir.data.items.len) ir.getBinding(idx) else null;
    }

    /// Get binary expression data
    pub fn getBinary(self: IrView, idx: NodeIndex) ?Node.BinaryExpr {
        const ir = self.store;
        return blk: {
            if (idx >= ir.data.items.len) break :blk null;
            const bin = ir.data.items[idx].toBinary();
            break :blk .{
                .op = bin.op,
                .left = bin.left,
                .right = bin.right,
            };
        };
    }

    /// Get unary expression data
    pub fn getUnary(self: IrView, idx: NodeIndex) ?Node.UnaryExpr {
        const ir = self.store;
        return blk: {
            if (idx >= ir.data.items.len) break :blk null;
            const d = ir.data.items[idx];
            // `op` is a packed u4 but `UnaryOp` has fewer than 16 members,
            // so an out-of-range value (e.g. when this node is not actually
            // a unary op) would make `@enumFromInt` panic. Callers use
            // `getUnary(...) orelse return`, so fail soft to null instead of
            // aborting the whole analyzer process.
            const op_raw: u4 = @truncate(d.a);
            if (op_raw >= @typeInfo(UnaryOp).@"enum".field_names.len) break :blk null;
            break :blk .{
                .op = @fromBackingInt(@intCast(op_raw)),
                .operand = d.b,
            };
        };
    }

    /// Get ternary expression data
    pub fn getTernary(self: IrView, idx: NodeIndex) ?Node.TernaryExpr {
        const ir = self.store;
        return blk: {
            if (idx >= ir.data.items.len) break :blk null;
            const d = ir.data.items[idx];
            // Ternary uses extra data: [condition, then, else]
            const extra_start = d.a;
            break :blk .{
                .condition = ir.extra.items[extra_start],
                .then_branch = ir.extra.items[extra_start + 1],
                .else_branch = ir.extra.items[extra_start + 2],
            };
        };
    }

    /// Get call expression data
    pub fn getCall(self: IrView, idx: NodeIndex) ?Node.CallExpr {
        const ir = self.store;
        return ir.getCallData(idx);
    }

    /// Get member access expression data
    pub fn getMember(self: IrView, idx: NodeIndex) ?Node.MemberExpr {
        const ir = self.store;
        return blk: {
            if (idx >= ir.data.items.len) break :blk null;
            const d = ir.data.items[idx];
            const tag = ir.tags.items[idx];
            // Member packed formats differ by tag.
            switch (tag) {
                .computed_access => {
                    break :blk .{
                        .object = d.a,
                        .property = 0,
                        .computed = d.b,
                        .is_optional = false,
                    };
                },
                else => {
                    // Member packed: a = object, b[0:16] = property, b[16:17] = is_optional
                    break :blk .{
                        .object = d.a,
                        .property = @truncate(d.b),
                        .computed = null_node,
                        .is_optional = (d.b >> 16) != 0,
                    };
                },
            }
        };
    }

    /// Get assignment expression data
    pub fn getAssignment(self: IrView, idx: NodeIndex) ?Node.AssignExpr {
        const ir = self.store;
        return blk: {
            if (idx >= ir.data.items.len) break :blk null;
            const d = ir.data.items[idx];
            // Assignment: a = target, b[0:24] = value, b[24:32] = op (0 = none)
            const op_byte: u8 = @truncate(d.b >> 24);
            break :blk .{
                .target = d.a,
                .value = d.b & 0xFFFFFF,
                .op = if (op_byte == 0) null else @fromBackingInt(@intCast(op_byte - 1)),
            };
        };
    }

    /// Get array literal data
    pub fn getArray(self: IrView, idx: NodeIndex) ?Node.ArrayExpr {
        const ir = self.store;
        return blk: {
            if (idx >= ir.data.items.len) break :blk null;
            const d = ir.data.items[idx];
            break :blk .{
                .elements_start = d.a,
                .elements_count = @truncate(d.b),
                .has_spread = (d.b >> 16) != 0,
            };
        };
    }

    /// Get object literal data
    pub fn getObject(self: IrView, idx: NodeIndex) ?Node.ObjectExpr {
        const ir = self.store;
        return blk: {
            if (idx >= ir.data.items.len) break :blk null;
            const d = ir.data.items[idx];
            break :blk .{
                .properties_start = d.a,
                .properties_count = @truncate(d.b),
            };
        };
    }

    /// Get property expression data
    pub fn getProperty(self: IrView, idx: NodeIndex) ?Node.PropertyExpr {
        const ir = self.store;
        return blk: {
            if (idx >= ir.data.items.len) break :blk null;
            const d = ir.data.items[idx];
            // Property: a = key, b[0:24] = value, b[24] = is_shorthand.
            // Mask the value field: @truncate to NodeIndex (u32) would leave the flag
            // bits in place, so a shorthand property (bit 24) would read back with
            // 0x01000000 OR'd into the node index and resolve to garbage.
            // The 24-bit field also holds `null_node` (a match-pattern field
            // `_`, which has no pattern node), truncated on the way in. Widen
            // the all-ones value back to `null_node`, or a field `_` would
            // read as a node index no tree holds and lose its presence test.
            const packed_value: u24 = @truncate(d.b);
            break :blk .{
                .key = d.a,
                .value = if (packed_value == std.math.maxInt(u24)) null_node else @as(NodeIndex, packed_value),
                .is_shorthand = (d.b >> 24) & 1 != 0,
            };
        };
    }

    /// Get function expression data of a `function_expr` or `arrow_function`.
    /// A `function_decl` holds `var_decl` data (a binding and the function
    /// expression as `init`), not function data, so this returns null for it
    /// on both implementations. Read a declaration with `getFunctionOfDecl`.
    pub fn getFunction(self: IrView, idx: NodeIndex) ?Node.FunctionExpr {
        if (self.getTag(idx) == .function_decl) return null;
        const ir = self.store;
        return blk: {
            if (idx >= ir.data.items.len) break :blk null;
            const d = ir.data.items[idx];
            // Function uses extra data for full structure
            const extra_start = d.a;
            const extra = ir.extra.items;
            if (extra_start + 5 >= extra.len) break :blk null;
            break :blk .{
                .scope_id = @truncate(extra[extra_start]),
                .name_atom = @truncate(extra[extra_start + 1]),
                .params_start = extra[extra_start + 2],
                .params_count = @truncate(extra[extra_start + 3]),
                .body = extra[extra_start + 4],
                .flags = @bitCast(@as(u8, @truncate(extra[extra_start + 5]))),
            };
        };
    }

    /// Get the function data of a `function_decl`, read from the `init` of
    /// its `var_decl` data. Returns null for any other node tag.
    pub fn getFunctionOfDecl(self: IrView, idx: NodeIndex) ?Node.FunctionExpr {
        if (self.getTag(idx) != .function_decl) return null;
        const decl = self.getVarDecl(idx) orelse return null;
        return self.getFunction(decl.init);
    }

    /// The offset the parser reports for the `(` that opens the parameter list
    /// of the function `idx` names: a `function_expr`, an `arrow_function`, or
    /// the function inside a `function_decl`. A signature is identified by
    /// this offset (see `TypeEnv.getFnSigAt`). The location of a
    /// `function_decl` node is its `function` keyword, which is not this
    /// offset, so a declaration is read through its function. Null for any
    /// other node, and for a single-identifier arrow, which has no `(`.
    pub fn signatureOffset(self: IrView, idx: NodeIndex) ?u32 {
        const fn_node = switch (self.getTag(idx) orelse return null) {
            .function_expr, .arrow_function => idx,
            .function_decl => (self.getVarDecl(idx) orelse return null).init,
            else => return null,
        };
        return (self.getLoc(fn_node) orelse return null).offset;
    }

    // ============ Statement Accessors ============

    /// Get variable declaration data
    pub fn getVarDecl(self: IrView, idx: NodeIndex) ?Node.VarDecl {
        const ir = self.store;
        return blk: {
            if (idx >= ir.data.items.len) break :blk null;
            const d = ir.data.items[idx];
            const extra_start = d.a;
            const extra = ir.extra.items;
            // VarDecl in extra: [binding_packed, init, kind]
            const binding_packed = extra[extra_start];
            break :blk .{
                .binding = .{
                    .scope_id = @truncate(binding_packed >> 16),
                    .slot = @truncate(binding_packed),
                    .name_atom = ir.bindingName(idx),
                    .kind = @fromBackingInt(@intCast(@as(u3, @truncate(extra[extra_start + 2] >> 2)))),
                },
                .init = extra[extra_start + 1],
                .kind = @fromBackingInt(@intCast(@as(u2, @truncate(extra[extra_start + 2])))),
            };
        };
    }

    /// Get if statement data
    pub fn getIfStmt(self: IrView, idx: NodeIndex) ?Node.IfStmt {
        const ir = self.store;
        return blk: {
            if (idx >= ir.data.items.len) break :blk null;
            const d = ir.data.items[idx];
            const extra_start = d.a;
            const extra = ir.extra.items;
            break :blk .{
                .condition = extra[extra_start],
                .then_branch = extra[extra_start + 1],
                .else_branch = extra[extra_start + 2],
            };
        };
    }

    /// Get loop statement data
    pub fn getLoop(self: IrView, idx: NodeIndex) ?Node.LoopStmt {
        const ir = self.store;
        return blk: {
            if (idx >= ir.data.items.len) break :blk null;
            const d = ir.data.items[idx];
            const extra_start = d.a;
            const extra = ir.extra.items;
            break :blk .{
                .kind = @fromBackingInt(@intCast(@as(u2, @truncate(extra[extra_start])))),
                .init = extra[extra_start + 1],
                .condition = extra[extra_start + 2],
                .update = extra[extra_start + 3],
                .body = extra[extra_start + 4],
            };
        };
    }

    /// Get for-of/for-in statement data
    pub fn getForIter(self: IrView, idx: NodeIndex) ?Node.ForIterStmt {
        const ir = self.store;
        return blk: {
            if (idx >= ir.data.items.len) break :blk null;
            const d = ir.data.items[idx];
            const extra_start = d.a;
            const extra = ir.extra.items;
            const binding_packed = extra[extra_start];
            const flags = extra[extra_start + 2];
            break :blk .{
                .is_for_in = (flags & 1) != 0,
                .binding = .{
                    .scope_id = @truncate(binding_packed >> 16),
                    .slot = @truncate(binding_packed),
                    .name_atom = ir.bindingName(idx),
                    .kind = @fromBackingInt(@intCast(@as(u3, @truncate(flags >> 2)))),
                },
                .iterable = extra[extra_start + 1],
                .body = extra[extra_start + 3],
                .is_const = (flags >> 1) & 1 != 0,
            };
        };
    }

    /// Get switch statement data
    pub fn getSwitchStmt(self: IrView, idx: NodeIndex) ?Node.SwitchStmt {
        const ir = self.store;
        return blk: {
            if (idx >= ir.data.items.len) break :blk null;
            const d = ir.data.items[idx];
            const list_ref = ir.getListRef(d.b) orelse break :blk null;
            break :blk .{
                .discriminant = d.a,
                .cases_start = list_ref.start,
                .cases_count = @intCast(list_ref.count),
            };
        };
    }

    /// Get case clause data
    pub fn getCaseClause(self: IrView, idx: NodeIndex) ?Node.CaseClause {
        const ir = self.store;
        return blk: {
            if (idx >= ir.data.items.len) break :blk null;
            const d = ir.data.items[idx];
            const list_ref = ir.getListRef(d.b) orelse break :blk null;
            break :blk .{
                .test_expr = d.a,
                .body_start = list_ref.start,
                .body_count = list_ref.count,
            };
        };
    }

    /// Get match expression data
    pub fn getMatchExpr(self: IrView, idx: NodeIndex) ?Node.MatchExpr {
        const ir = self.store;
        return blk: {
            if (idx >= ir.data.items.len) break :blk null;
            const d = ir.data.items[idx];
            const list_ref = ir.getListRef(d.b) orelse break :blk null;
            break :blk .{
                .discriminant = d.a,
                .arms_start = list_ref.start,
                .arms_count = @intCast(list_ref.count),
            };
        };
    }

    /// Get match arm data
    pub fn getMatchArm(self: IrView, idx: NodeIndex) ?Node.MatchArm {
        const ir = self.store;
        return blk: {
            if (idx >= ir.data.items.len) break :blk null;
            const d = ir.data.items[idx];
            break :blk .{
                .pattern = d.a,
                .body = d.b,
            };
        };
    }

    /// Get match pattern (object pattern) data
    pub fn getMatchPattern(self: IrView, idx: NodeIndex) ?Node.MatchPatternObj {
        const ir = self.store;
        return blk: {
            if (idx >= ir.data.items.len) break :blk null;
            const d = ir.data.items[idx];
            break :blk .{
                .props_start = d.a,
                .props_count = @truncate(d.b),
            };
        };
    }

    /// Get a type-test pattern's kind and lowered predicate (spec 5.5).
    pub fn getMatchTypeTest(self: IrView, idx: NodeIndex) ?Node.MatchTypeTest {
        if (self.getTag(idx) != .match_type_test) return null;
        const ir = self.store;
        return blk: {
            if (idx >= ir.data.items.len) break :blk null;
            const d = ir.data.items[idx];
            break :blk .{
                .kind = @fromBackingInt(@intCast(@as(u8, @truncate(d.a)))),
                .predicate = d.b,
            };
        };
    }

    /// Get block data
    pub fn getBlock(self: IrView, idx: NodeIndex) ?Node.BlockData {
        const ir = self.store;
        return blk: {
            if (idx >= ir.data.items.len) break :blk null;
            const d = ir.data.items[idx];
            break :blk .{
                .stmts_start = d.a,
                .stmts_count = @truncate(d.b),
                .scope_id = @truncate(d.b >> 16),
            };
        };
    }

    /// Get optional value (for return, expr_stmt, etc.)
    pub fn getOptValue(self: IrView, idx: NodeIndex) ?NodeIndex {
        const ir = self.store;
        return blk: {
            if (idx >= ir.data.items.len) break :blk null;
            const val = ir.data.items[idx].a;
            break :blk if (val == null_node) null else val;
        };
    }

    /// Get assert statement data: condition and optional error expression
    pub fn getAssertStmt(self: IrView, idx: NodeIndex) ?Node.AssertStmt {
        const ir = self.store;
        return blk: {
            if (idx >= ir.data.items.len) break :blk null;
            const d = ir.data.items[idx];
            break :blk .{
                .condition = d.a,
                .error_expr = d.b,
            };
        };
    }

    /// The blocks of a `try_stmt`: the try block, the catch block, and the
    /// finally block. A `null_node` block is absent. The catch binding is not
    /// part of this view: it is a binding position, and its kind is not stored.
    /// Packing: a = extra_start -> extra = [try_block, binding_packed, catch_block, finally_block]
    pub fn getTryBlocks(self: IrView, idx: NodeIndex) ?TryBlocks {
        const ir = self.store;
        return blk: {
            if (idx >= ir.data.items.len) break :blk null;
            const extra_start = ir.data.items[idx].a;
            const extra = ir.extra.items;
            break :blk .{
                .try_block = extra[extra_start],
                .catch_block = extra[extra_start + 2],
                .finally_block = extra[extra_start + 3],
            };
        };
    }

    pub const TryBlocks = struct {
        try_block: NodeIndex,
        catch_block: NodeIndex,
        finally_block: NodeIndex,
    };

    /// The body of a `labeled_stmt`. The label is an atom and holds no code.
    /// Packing: a = label_atom, b = body
    pub fn getLabeledBody(self: IrView, idx: NodeIndex) ?NodeIndex {
        const ir = self.store;
        return if (idx < ir.data.items.len) ir.data.items[idx].b else null;
    }

    // ============ Module Accessors ============

    /// Get import declaration data
    pub fn getImportDecl(self: IrView, idx: NodeIndex) ?Node.ImportDecl {
        const ir = self.store;
        return blk: {
            if (idx >= ir.data.items.len) break :blk null;
            const d = ir.data.items[idx];
            const list_ref = ir.getListRef(d.b) orelse break :blk null;
            break :blk .{
                .module_idx = @truncate(d.a),
                .specifiers_start = list_ref.start,
                .specifiers_count = @intCast(list_ref.count),
            };
        };
    }

    /// Get import specifier data
    /// Packing: a = extra_start -> extra = [kind, imported_atom, binding_packed]
    pub fn getImportSpec(self: IrView, idx: NodeIndex) ?Node.ImportSpec {
        const ir = self.store;
        return blk: {
            if (idx >= ir.data.items.len) break :blk null;
            const d = ir.data.items[idx];
            const extra_start = d.a;
            const extra = ir.extra.items;
            const binding_packed = extra[extra_start + 2];
            break :blk .{
                .kind = @fromBackingInt(@intCast(@as(u2, @truncate(extra[extra_start])))),
                .imported_atom = @truncate(extra[extra_start + 1]),
                .local_binding = .{
                    .scope_id = @truncate(binding_packed >> 16),
                    .slot = @truncate(binding_packed),
                    .name_atom = ir.bindingName(idx),
                    .kind = @fromBackingInt(@intCast(@as(u3, @truncate(extra[extra_start] >> 8)))),
                },
            };
        };
    }

    /// Get export declaration data
    /// Packing: a = extra_start -> extra = [kind, declaration, specifiers_start, specifiers_count, from_module_idx]
    pub fn getExportDecl(self: IrView, idx: NodeIndex) ?Node.ExportDecl {
        const ir = self.store;
        return blk: {
            if (idx >= ir.data.items.len) break :blk null;
            const d = ir.data.items[idx];
            const extra_start = d.a;
            const extra = ir.extra.items;
            break :blk .{
                .kind = @fromBackingInt(@intCast(@as(u2, @truncate(extra[extra_start])))),
                .declaration = extra[extra_start + 1],
                .specifiers_start = extra[extra_start + 2],
                .specifiers_count = @truncate(extra[extra_start + 3]),
                .from_module_idx = @truncate(extra[extra_start + 4]),
            };
        };
    }

    // ============ Pattern Accessors ============

    /// Single-binding parameter extraction. The parser emits each function
    /// parameter either as a bare `.identifier` node or as a
    /// `.pattern_element` wrapper. Shared by the type checker and flow checker
    /// so the parameter-node shape is encoded once.
    pub fn paramBinding(self: IrView, param_idx: NodeIndex) ?BindingRef {
        const tag = self.getTag(param_idx) orelse return null;
        if (tag == .identifier) {
            return self.getBinding(param_idx);
        }
        if (tag == .pattern_element) {
            const pe = self.getPatternElem(param_idx) orelse return null;
            return pe.binding;
        }
        return null;
    }

    /// Get pattern element data
    pub fn getPatternElem(self: IrView, idx: NodeIndex) ?Node.PatternElem {
        const ir = self.store;
        return blk: {
            if (idx >= ir.data.items.len) break :blk null;
            const d = ir.data.items[idx];
            const extra_start = d.a;
            const extra = ir.extra.items;
            const binding_packed = extra[extra_start + 1];
            break :blk .{
                .kind = @fromBackingInt(@intCast(@as(u2, @truncate(extra[extra_start])))),
                .binding = .{
                    .scope_id = @truncate(binding_packed >> 16),
                    .slot = @truncate(binding_packed),
                    .name_atom = ir.bindingName(idx),
                    .kind = @fromBackingInt(@intCast(@as(u3, @truncate(extra[extra_start] >> 8)))),
                },
                .key = extra[extra_start + 2],
                .key_atom = @truncate(extra[extra_start + 3]),
                .default_value = extra[extra_start + 4],
            };
        };
    }

    // ============ Constant Pool Access ============

    /// Get string from constant pool
    pub fn getString(self: IrView, str_idx: u16) ?[]const u8 {
        return self.ir_constants.getString(str_idx);
    }

    /// Get float from constant pool
    pub fn getFloat(self: IrView, float_idx: u16) ?f64 {
        return self.ir_constants.getFloat(float_idx);
    }
};

test "IrView IRStore basic operations" {
    const allocator = std.testing.allocator;

    var store = IRStore.init(allocator);
    defer store.deinit();

    var constants = ConstantPool.init(allocator);
    defer constants.deinit();

    const loc = SourceLocation{ .line = 1, .column = 1, .offset = 0 };

    const int_idx = try store.add(Node.litInt(loc, 42));
    const bool_idx = try store.add(Node.litBool(loc, true));
    const left = try store.add(Node.litInt(loc, 10));
    const right = try store.add(Node.litInt(loc, 20));
    const binary_idx = try store.add(Node.binaryOp(loc, .add, left, right));

    // Create view
    const view = IrView.fromIRStore(&store, &constants);

    // Test basic accessors
    try std.testing.expectEqual(NodeTag.lit_int, view.getTag(int_idx).?);
    try std.testing.expectEqual(@as(i32, 42), view.getIntValue(int_idx).?);

    try std.testing.expectEqual(NodeTag.lit_bool, view.getTag(bool_idx).?);
    try std.testing.expect(view.getBoolValue(bool_idx).?);

    // Test binary expression
    try std.testing.expectEqual(NodeTag.binary_op, view.getTag(binary_idx).?);
    const binary = view.getBinary(binary_idx).?;
    try std.testing.expectEqual(BinaryOp.add, binary.op);
    try std.testing.expectEqual(left, binary.left);
    try std.testing.expectEqual(right, binary.right);

    // Test validity
    try std.testing.expect(view.isValid(int_idx));
    try std.testing.expect(!view.isValid(null_node));
}

/// A `function_decl` holds `var_decl` data: a binding and the function
/// expression as its `init`. `getFunction` must not read it as a function.
fn buildDeclFixture(store: *IRStore) !struct { decl: NodeIndex, func: NodeIndex, body: NodeIndex } {
    const loc = SourceLocation{ .line = 1, .column = 1, .offset = 0 };
    const body = try store.add(.{ .tag = .block, .loc = loc, .data = .{ .block = .{
        .stmts_start = 0,
        .stmts_count = 0,
        .scope_id = null_scope,
    } } });
    const func = try store.add(.{ .tag = .function_expr, .loc = loc, .data = .{ .function = .{
        .scope_id = 3,
        .name_atom = 9,
        .params_start = 0,
        .params_count = 0,
        .body = body,
        .flags = .{},
    } } });
    const decl = try store.add(.{ .tag = .function_decl, .loc = loc, .data = .{ .var_decl = .{
        .binding = .{ .scope_id = 1, .slot = 2, .name_atom = 9, .kind = .local },
        .init = func,
        .kind = .let,
    } } });
    // A second function after the declaration: on the IRStore the misread
    // of the declaration then finds enough extra slots to return garbage.
    _ = try store.add(.{ .tag = .function_expr, .loc = loc, .data = .{ .function = .{
        .scope_id = 4,
        .name_atom = 10,
        .params_start = 0,
        .params_count = 0,
        .body = body,
        .flags = .{},
    } } });
    return .{ .decl = decl, .func = func, .body = body };
}

test "IrView reads a function_decl through getFunctionOfDecl on the IRStore" {
    const allocator = std.testing.allocator;
    var store = IRStore.init(allocator);
    defer store.deinit();
    var constants = ConstantPool.init(allocator);
    defer constants.deinit();
    const fx = try buildDeclFixture(&store);
    const view = IrView.fromIRStore(&store, &constants);

    try std.testing.expect(view.getFunction(fx.decl) == null);
    const func = view.getFunctionOfDecl(fx.decl) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(ScopeId, 3), func.scope_id);
    try std.testing.expectEqual(fx.body, func.body);
    try std.testing.expect(view.getFunction(fx.func) != null);
    try std.testing.expect(view.getFunctionOfDecl(fx.func) == null);
    try std.testing.expect(view.getFunctionOfDecl(fx.body) == null);
}

test "ConstantPool refuses the 65537th distinct constant and keeps deduplicating" {
    var pool = ConstantPool.init(std.testing.allocator);
    defer pool.deinit();

    var buf: [16]u8 = undefined;
    var i: usize = 0;
    while (i <= std.math.maxInt(u16)) : (i += 1) {
        const text = try std.fmt.bufPrint(&buf, "s{d}", .{i});
        try std.testing.expectEqual(@as(u16, @intCast(i)), try pool.addString(text));
        try std.testing.expectEqual(@as(u16, @intCast(i)), try pool.addFloat(@floatFromInt(i)));
    }
    try std.testing.expectError(error.TooManyConstants, pool.addString("one more"));
    try std.testing.expectError(error.TooManyConstants, pool.addOwnedString(try std.testing.allocator.dupe(u8, "owned overflow")));
    try std.testing.expectError(error.TooManyConstants, pool.addFloat(-1.5));
    // A refused constant leaves no entry behind, and existing ones still resolve.
    try std.testing.expectEqual(@as(?u16, null), pool.string_index.get("one more"));
    try std.testing.expectEqual(@as(u16, 7), try pool.addString("s7"));
    try std.testing.expectEqual(@as(u16, 7), try pool.addOwnedString(try std.testing.allocator.dupe(u8, "s7")));
    try std.testing.expectEqual(@as(u16, 7), try pool.addFloat(7));
}

// ============================================================
// IrView.expressionChildren and subtreeContains tests
// ============================================================

const ExpectedChild = struct {
    tag: NodeTag,
    /// Checked for a `lit_int` child, to tell siblings of one tag apart.
    int: ?i32 = null,
};

/// Parse `source`, take the `nth` node (in index order) with tag `tag`, and
/// require that its expression children are exactly `expected`, in order.
fn expectChildrenOf(source: []const u8, tag: NodeTag, nth: usize, expected: []const ExpectedChild) !void {
    const allocator = std.testing.allocator;
    var parser = try @import("parse.zig").Parser.init(allocator, source);
    defer parser.deinit();
    _ = try parser.parse();
    try std.testing.expect(!parser.errors.hasErrors());
    const view = IrView.fromIRStore(&parser.nodes, &parser.constants);

    var seen: usize = 0;
    var node: NodeIndex = null_node;
    var i: NodeIndex = 0;
    while (i < view.nodeCount()) : (i += 1) {
        if (view.getTag(i) != tag) continue;
        if (seen == nth) {
            node = i;
            break;
        }
        seen += 1;
    }
    if (node == null_node) return error.TestNodeNotFound;

    try expectViewChildren(view, node, expected);
}

fn expectViewChildren(view: IrView, node: NodeIndex, expected: []const ExpectedChild) !void {
    var it = view.expressionChildren(node);
    var count: usize = 0;
    while (it.next()) |child| : (count += 1) {
        if (count >= expected.len) {
            std.debug.print("extra child {d} of tag {s}\n", .{ child, @tagName(view.getTag(child).?) });
            return error.TestUnexpectedChild;
        }
        try std.testing.expectEqual(expected[count].tag, view.getTag(child).?);
        if (expected[count].int) |want| {
            try std.testing.expectEqual(want, view.getIntValue(child).?);
        }
    }
    try std.testing.expectEqual(expected.len, count);
}

test "expressionChildren of a binary operation are its operands" {
    try expectChildrenOf("const r = a + 1;", .binary_op, 0, &.{
        .{ .tag = .identifier },
        .{ .tag = .lit_int, .int = 1 },
    });
}

test "expressionChildren of a unary operation is its operand" {
    try expectChildrenOf("const r = !a;", .unary_op, 0, &.{.{ .tag = .identifier }});
}

test "expressionChildren of a ternary are condition then and else" {
    try expectChildrenOf("const r = a ? 1 : 2;", .ternary, 0, &.{
        .{ .tag = .identifier },
        .{ .tag = .lit_int, .int = 1 },
        .{ .tag = .lit_int, .int = 2 },
    });
}

test "expressionChildren of a call are the callee then each argument" {
    try expectChildrenOf("f(1, 2, a);", .call, 0, &.{
        .{ .tag = .identifier },
        .{ .tag = .lit_int, .int = 1 },
        .{ .tag = .lit_int, .int = 2 },
        .{ .tag = .identifier },
    });
    try expectChildrenOf("f();", .call, 0, &.{.{ .tag = .identifier }});
}

test "expressionChildren of a member access is its object" {
    try expectChildrenOf("const r = a.b;", .member_access, 0, &.{.{ .tag = .identifier }});
}

test "expressionChildren of a computed access are the object then the index" {
    try expectChildrenOf("const r = a[1];", .computed_access, 0, &.{
        .{ .tag = .identifier },
        .{ .tag = .lit_int, .int = 1 },
    });
}

test "expressionChildren of an optional chain is its object" {
    try expectChildrenOf("const r = a?.b;", .optional_chain, 0, &.{.{ .tag = .identifier }});
}

test "expressionChildren of an assignment are the target then the value" {
    try expectChildrenOf("a.b = 1;", .assignment, 0, &.{
        .{ .tag = .member_access },
        .{ .tag = .lit_int, .int = 1 },
    });
}

test "expressionChildren of an array literal are its elements in order" {
    try expectChildrenOf("const r = [1, a, ...b, 2];", .array_literal, 0, &.{
        .{ .tag = .lit_int, .int = 1 },
        .{ .tag = .identifier },
        .{ .tag = .spread },
        .{ .tag = .lit_int, .int = 2 },
    });
    try expectChildrenOf("const r = [];", .array_literal, 0, &.{});
}

test "expressionChildren of an object literal are its properties and spreads" {
    try expectChildrenOf("const r = { k: 1, ...b, m: 2 };", .object_literal, 0, &.{
        .{ .tag = .object_property },
        .{ .tag = .object_spread },
        .{ .tag = .object_property },
    });
}

test "expressionChildren of an object property is its value and not its string key" {
    try expectChildrenOf("const r = { k: 7 };", .object_property, 0, &.{
        .{ .tag = .lit_int, .int = 7 },
    });
}

test "expressionChildren of an object spread is its operand" {
    try expectChildrenOf("const r = { ...b };", .object_spread, 0, &.{.{ .tag = .identifier }});
}

test "expressionChildren of a spread is its operand" {
    try expectChildrenOf("const r = [...b];", .spread, 0, &.{.{ .tag = .identifier }});
}

test "expressionChildren of a function expression is its body and not its parameters" {
    // The parser refuses a `function` expression; a declaration holds one as its initializer.
    try expectChildrenOf("function f(a) { return a; }", .function_expr, 0, &.{
        .{ .tag = .block },
    });
}

test "expressionChildren of an arrow function is its body and not its parameters" {
    try expectChildrenOf("const f = (a) => { return a; };", .arrow_function, 0, &.{
        .{ .tag = .block },
    });
    // An expression body is wrapped in a return statement.
    try expectChildrenOf("const f = (a) => a + 1;", .arrow_function, 0, &.{
        .{ .tag = .return_stmt },
    });
}

test "expressionChildren of a function declaration is its function expression" {
    try expectChildrenOf("function f(a) { return a; }", .function_decl, 0, &.{
        .{ .tag = .function_expr },
    });
}

test "expressionChildren of a match are the discriminant then each arm" {
    try expectChildrenOf(
        \\const r = match (a) {
        \\  when 1: "one"
        \\  when 2: "two"
        \\  default: "other"
        \\};
    , .match_expr, 0, &.{
        .{ .tag = .identifier },
        .{ .tag = .match_arm },
        .{ .tag = .match_arm },
        .{ .tag = .match_arm },
    });
}

test "expressionChildren of a match arm is its body and not its pattern" {
    try expectChildrenOf(
        \\const r = match (a) {
        \\  when 1: "one"
        \\  default: 2
        \\};
    , .match_arm, 0, &.{.{ .tag = .lit_string }});
    try expectChildrenOf(
        \\const r = match (a) {
        \\  when 1: "one"
        \\  default: 2
        \\};
    , .match_arm, 1, &.{.{ .tag = .lit_int, .int = 2 }});
}

test "expressionChildren of an object match pattern is empty" {
    try expectChildrenOf(
        \\const r = match (a) {
        \\  when { kind: "x" }: 1
        \\  default: 2
        \\};
    , .match_pattern, 0, &.{});
}

test "expressionChildren of a type test is empty so its isDict predicate is not reached" {
    const source =
        \\const r = match (a) {
        \\  when Dict: 1
        \\  default: 2
        \\};
    ;
    try expectChildrenOf(source, .match_type_test, 0, &.{});
    // The predicate exists in the IR as a call. No walk from the match
    // reaches it through the map.
    try expectChildrenOf(source, .match_expr, 0, &.{
        .{ .tag = .identifier },
        .{ .tag = .match_arm },
        .{ .tag = .match_arm },
    });
}

test "expressionChildren of an array match pattern is empty" {
    try expectChildrenOf(
        \\const r = match (a) {
        \\  when [1, 2]: 1
        \\  default: 2
        \\};
    , .array_pattern, 0, &.{});
}

test "expressionChildren of an expression statement is its expression" {
    try expectChildrenOf("f();", .expr_stmt, 0, &.{.{ .tag = .call }});
}

test "expressionChildren of a variable declaration is its initializer" {
    try expectChildrenOf("const a = 1;", .var_decl, 0, &.{.{ .tag = .lit_int, .int = 1 }});
}

test "expressionChildren of an if statement are condition then and else" {
    try expectChildrenOf("if (a) { f(); } else { g(); }", .if_stmt, 0, &.{
        .{ .tag = .identifier },
        .{ .tag = .block },
        .{ .tag = .block },
    });
    try expectChildrenOf("if (a) { f(); }", .if_stmt, 0, &.{
        .{ .tag = .identifier },
        .{ .tag = .block },
    });
}

test "expressionChildren of a for-of are the iterable then the body" {
    try expectChildrenOf("for (const x of xs) { f(x); }", .for_of_stmt, 0, &.{
        .{ .tag = .identifier },
        .{ .tag = .block },
    });
}

test "expressionChildren of a return statement is its value" {
    try expectChildrenOf("function f() { return 5; }", .return_stmt, 0, &.{
        .{ .tag = .lit_int, .int = 5 },
    });
    try expectChildrenOf("function f() { return; }", .return_stmt, 0, &.{});
}

test "expressionChildren of an assert are the condition then the error expression" {
    try expectChildrenOf("assert a, 7;", .assert_stmt, 0, &.{
        .{ .tag = .identifier },
        .{ .tag = .lit_int, .int = 7 },
    });
    try expectChildrenOf("assert a;", .assert_stmt, 0, &.{.{ .tag = .identifier }});
}

test "expressionChildren of a block are its statements in order" {
    try expectChildrenOf("function f() { g(); return 1; }", .block, 0, &.{
        .{ .tag = .expr_stmt },
        .{ .tag = .return_stmt },
    });
}

test "expressionChildren of a program are its top-level statements in order" {
    try expectChildrenOf("const a = 1; f();", .program, 0, &.{
        .{ .tag = .var_decl },
        .{ .tag = .expr_stmt },
    });
}

test "expressionChildren of a parameter without a default is empty" {
    try expectChildrenOf("function f(a) { return a; }", .pattern_element, 0, &.{});
}

test "expressionChildren of an import declaration is empty" {
    try expectChildrenOf("import { cacheGet } from \"zttp:cache\";", .import_decl, 0, &.{});
}

test "expressionChildren of an export declaration is its declaration" {
    try expectChildrenOf("export function f() { return 1; }", .export_decl, 0, &.{
        .{ .tag = .function_decl },
    });
    try expectChildrenOf("export const x = 1;", .export_decl, 0, &.{
        .{ .tag = .var_decl },
    });
}

fn testLoc() SourceLocation {
    return .{ .line = 1, .column = 1, .offset = 0 };
}

fn addOpt(store: *IRStore, tag: NodeTag, operand: NodeIndex) !NodeIndex {
    return store.add(.{
        .tag = tag,
        .loc = testLoc(),
        .data = .{ .opt_value = if (operand == null_node) null else operand },
    });
}

fn addPatternNode(store: *IRStore, tag: NodeTag, default_value: NodeIndex) !NodeIndex {
    return store.add(.{
        .tag = tag,
        .loc = testLoc(),
        .data = .{ .pattern_elem = .{
            .kind = .simple,
            .binding = BindingRef.global(3),
            .key = null_node,
            .key_atom = 0,
            .default_value = default_value,
        } },
    });
}

test "expressionChildren reads the operand of the operand-carrying tags from payload word a" {
    var store = IRStore.init(std.testing.allocator);
    defer store.deinit();
    var constants = ConstantPool.init(std.testing.allocator);
    defer constants.deinit();
    const view = IrView.fromIRStore(&store, &constants);

    const operand = try store.add(Node.litInt(testLoc(), 9));
    const tags = [_]NodeTag{
        .spread,      .object_spread, .await_expr,     .yield_expr, .throw_stmt,
        .return_stmt, .expr_stmt,     .export_default, .export_all,
    };
    for (tags) |tag| {
        const node = try addOpt(&store, tag, operand);
        try expectViewChildren(view, node, &.{.{ .tag = .lit_int, .int = 9 }});
        const bare = try addOpt(&store, tag, null_node);
        try expectViewChildren(view, bare, &.{});
    }
}

test "expressionChildren of a pattern with a default is the default value only" {
    var store = IRStore.init(std.testing.allocator);
    defer store.deinit();
    var constants = ConstantPool.init(std.testing.allocator);
    defer constants.deinit();
    const view = IrView.fromIRStore(&store, &constants);

    const default_value = try store.add(Node.litInt(testLoc(), 4));
    for ([_]NodeTag{ .pattern_element, .pattern_rest, .pattern_default }) |tag| {
        const with_default = try addPatternNode(&store, tag, default_value);
        try expectViewChildren(view, with_default, &.{.{ .tag = .lit_int, .int = 4 }});
        const without = try addPatternNode(&store, tag, null_node);
        try expectViewChildren(view, without, &.{});
    }
}

test "expressionChildren of a loop reads init condition update and body in source order" {
    var store = IRStore.init(std.testing.allocator);
    defer store.deinit();
    var constants = ConstantPool.init(std.testing.allocator);
    defer constants.deinit();
    const view = IrView.fromIRStore(&store, &constants);

    const init_node = try store.add(Node.litInt(testLoc(), 1));
    const condition = try store.add(Node.litInt(testLoc(), 2));
    const update = try store.add(Node.litInt(testLoc(), 3));
    const body = try store.add(Node.litInt(testLoc(), 4));
    const for_node = try store.add(.{
        .tag = .for_stmt,
        .loc = testLoc(),
        .data = .{ .loop = .{ .kind = .for_loop, .init = init_node, .condition = condition, .update = update, .body = body } },
    });
    try expectViewChildren(view, for_node, &.{
        .{ .tag = .lit_int, .int = 1 },
        .{ .tag = .lit_int, .int = 2 },
        .{ .tag = .lit_int, .int = 3 },
        .{ .tag = .lit_int, .int = 4 },
    });
    const while_node = try store.add(.{
        .tag = .while_stmt,
        .loc = testLoc(),
        .data = .{ .loop = .{ .kind = .while_loop, .init = null_node, .condition = condition, .update = null_node, .body = body } },
    });
    try expectViewChildren(view, while_node, &.{
        .{ .tag = .lit_int, .int = 2 },
        .{ .tag = .lit_int, .int = 4 },
    });
    // A do-while runs its body before it tests its condition.
    const do_node = try store.add(.{
        .tag = .do_while_stmt,
        .loc = testLoc(),
        .data = .{ .loop = .{ .kind = .do_while, .init = null_node, .condition = condition, .update = null_node, .body = body } },
    });
    try expectViewChildren(view, do_node, &.{
        .{ .tag = .lit_int, .int = 4 },
        .{ .tag = .lit_int, .int = 2 },
    });
}

test "expressionChildren of a for-in are the iterable then the body" {
    var store = IRStore.init(std.testing.allocator);
    defer store.deinit();
    var constants = ConstantPool.init(std.testing.allocator);
    defer constants.deinit();
    const view = IrView.fromIRStore(&store, &constants);

    const iterable = try store.add(Node.litInt(testLoc(), 1));
    const body = try store.add(Node.litInt(testLoc(), 2));
    const node = try store.add(.{
        .tag = .for_in_stmt,
        .loc = testLoc(),
        .data = .{ .for_iter = .{
            .is_for_in = true,
            .binding = BindingRef.global(3),
            .iterable = iterable,
            .body = body,
            .is_const = true,
        } },
    });
    try expectViewChildren(view, node, &.{
        .{ .tag = .lit_int, .int = 1 },
        .{ .tag = .lit_int, .int = 2 },
    });
}

test "expressionChildren of a switch and its case clauses read the test and the body list" {
    var store = IRStore.init(std.testing.allocator);
    defer store.deinit();
    var constants = ConstantPool.init(std.testing.allocator);
    defer constants.deinit();
    const view = IrView.fromIRStore(&store, &constants);

    const discriminant = try store.add(Node.litInt(testLoc(), 1));
    const test_expr = try store.add(Node.litInt(testLoc(), 2));
    const stmt_a = try store.add(Node.litInt(testLoc(), 3));
    const stmt_b = try store.add(Node.litInt(testLoc(), 4));
    const body_list = try store.addIndexList(&.{ stmt_a, stmt_b });
    const clause = try store.add(.{
        .tag = .case_clause,
        .loc = testLoc(),
        .data = .{ .case_clause = .{ .test_expr = test_expr, .body_start = body_list, .body_count = 2 } },
    });
    const default_clause = try store.add(.{
        .tag = .case_clause,
        .loc = testLoc(),
        .data = .{ .case_clause = .{ .test_expr = null_node, .body_start = body_list, .body_count = 1 } },
    });
    try expectViewChildren(view, clause, &.{
        .{ .tag = .lit_int, .int = 2 },
        .{ .tag = .lit_int, .int = 3 },
        .{ .tag = .lit_int, .int = 4 },
    });
    try expectViewChildren(view, default_clause, &.{.{ .tag = .lit_int, .int = 3 }});

    const case_list = try store.addIndexList(&.{ clause, default_clause });
    const switch_node = try store.add(.{
        .tag = .switch_stmt,
        .loc = testLoc(),
        .data = .{ .switch_stmt = .{ .discriminant = discriminant, .cases_start = case_list, .cases_count = 2 } },
    });
    try expectViewChildren(view, switch_node, &.{
        .{ .tag = .lit_int, .int = 1 },
        .{ .tag = .case_clause },
        .{ .tag = .case_clause },
    });
}

test "expressionChildren of an object method yields a non-string key before the value" {
    var store = IRStore.init(std.testing.allocator);
    defer store.deinit();
    var constants = ConstantPool.init(std.testing.allocator);
    defer constants.deinit();
    const view = IrView.fromIRStore(&store, &constants);

    const string_key = try store.add(Node.litString(testLoc(), 0));
    const computed_key = try store.add(Node.litInt(testLoc(), 5));
    const value = try store.add(Node.litInt(testLoc(), 6));
    for ([_]NodeTag{ .object_property, .object_method, .object_getter, .object_setter }) |tag| {
        const literal_keyed = try store.add(.{
            .tag = tag,
            .loc = testLoc(),
            .data = .{ .property = .{ .key = string_key, .value = value, .is_shorthand = false } },
        });
        try expectViewChildren(view, literal_keyed, &.{.{ .tag = .lit_int, .int = 6 }});
        const computed = try store.add(.{
            .tag = tag,
            .loc = testLoc(),
            .data = .{ .property = .{ .key = computed_key, .value = value, .is_shorthand = false } },
        });
        try expectViewChildren(view, computed, &.{
            .{ .tag = .lit_int, .int = 5 },
            .{ .tag = .lit_int, .int = 6 },
        });
    }
}

test "expressionChildren of try and labeled statements reads the blocks and the body" {
    var store = IRStore.init(std.testing.allocator);
    defer store.deinit();
    var constants = ConstantPool.init(std.testing.allocator);
    defer constants.deinit();
    const view = IrView.fromIRStore(&store, &constants);

    const try_block = try store.add(Node.litInt(testLoc(), 1));
    const catch_block = try store.add(Node.litInt(testLoc(), 2));
    const finally_block = try store.add(Node.litInt(testLoc(), 3));
    const try_node = try store.add(.{
        .tag = .try_stmt,
        .loc = testLoc(),
        .data = .{ .try_stmt = .{
            .try_block = try_block,
            .catch_binding = BindingRef.global(3),
            .catch_block = catch_block,
            .finally_block = finally_block,
        } },
    });
    try expectViewChildren(view, try_node, &.{
        .{ .tag = .lit_int, .int = 1 },
        .{ .tag = .lit_int, .int = 2 },
        .{ .tag = .lit_int, .int = 3 },
    });
    const no_catch = try store.add(.{
        .tag = .try_stmt,
        .loc = testLoc(),
        .data = .{ .try_stmt = .{
            .try_block = try_block,
            .catch_binding = BindingRef.global(3),
            .catch_block = null_node,
            .finally_block = finally_block,
        } },
    });
    try expectViewChildren(view, no_catch, &.{
        .{ .tag = .lit_int, .int = 1 },
        .{ .tag = .lit_int, .int = 3 },
    });
    const labeled = try store.add(.{
        .tag = .labeled_stmt,
        .loc = testLoc(),
        .data = .{ .labeled = .{ .label_atom = 7, .body = try_block } },
    });
    try expectViewChildren(view, labeled, &.{.{ .tag = .lit_int, .int = 1 }});
}

test "expressionChildren of an export specifier is its declaration word only" {
    var store = IRStore.init(std.testing.allocator);
    defer store.deinit();
    var constants = ConstantPool.init(std.testing.allocator);
    defer constants.deinit();
    const view = IrView.fromIRStore(&store, &constants);

    const declaration = try store.add(Node.litInt(testLoc(), 8));
    const specifier_list = try store.addIndexList(&.{declaration});
    const specifier = try store.add(.{
        .tag = .export_specifier,
        .loc = testLoc(),
        .data = .{ .export_decl = .{
            .kind = .named,
            .declaration = null_node,
            .specifiers_start = specifier_list,
            .specifiers_count = 1,
            .from_module_idx = 0,
        } },
    });
    try expectViewChildren(view, specifier, &.{});
}

test "subtreeContains finds a node inside an array spread operand" {
    const allocator = std.testing.allocator;
    var parser = try @import("parse.zig").Parser.init(allocator, "const z = 1; const r = [...a.b];");
    defer parser.deinit();
    const root = try parser.parse();
    const view = IrView.fromIRStore(&parser.nodes, &parser.constants);
    var spread: NodeIndex = null_node;
    var target: NodeIndex = null_node;
    var i: NodeIndex = 0;
    while (i < view.nodeCount()) : (i += 1) {
        if (view.getTag(i) == .spread) spread = i;
        if (view.getTag(i) == .identifier) target = i;
    }
    try std.testing.expect(spread != null_node and target != null_node);
    try std.testing.expect(view.subtreeContains(spread, target));
    try std.testing.expect(view.subtreeContains(root, target));
}

test "subtreeContains finds a node inside an object spread operand" {
    const allocator = std.testing.allocator;
    var parser = try @import("parse.zig").Parser.init(allocator, "const z = 1; const r = { ...a };");
    defer parser.deinit();
    const root = try parser.parse();
    const view = IrView.fromIRStore(&parser.nodes, &parser.constants);
    var target: NodeIndex = null_node;
    var i: NodeIndex = 0;
    while (i < view.nodeCount()) : (i += 1) {
        if (view.getTag(i) == .identifier) target = i;
    }
    try std.testing.expect(target != null_node);
    try std.testing.expect(view.subtreeContains(root, target));
}

test "subtreeContains finds a node inside an assert condition and an assert error expression" {
    const allocator = std.testing.allocator;
    var parser = try @import("parse.zig").Parser.init(allocator, "assert a, b;");
    defer parser.deinit();
    const root = try parser.parse();
    const view = IrView.fromIRStore(&parser.nodes, &parser.constants);
    var assert_node: NodeIndex = null_node;
    var i: NodeIndex = 0;
    while (i < view.nodeCount()) : (i += 1) {
        if (view.getTag(i) == .assert_stmt) assert_node = i;
    }
    try std.testing.expect(assert_node != null_node);
    const stmt = view.getAssertStmt(assert_node).?;
    try std.testing.expect(view.subtreeContains(root, stmt.condition));
    try std.testing.expect(view.subtreeContains(root, stmt.error_expr));
    try std.testing.expect(!view.subtreeContains(stmt.condition, stmt.error_expr));
}
