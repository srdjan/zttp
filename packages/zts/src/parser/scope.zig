//! Scope Analysis for JavaScript
//!
//! Tracks variable bindings across scopes and detects closures (upvalues).
//! This is the key component that enables proper closure support.

const std = @import("std");
const ir = @import("ir.zig");

pub const ScopeId = ir.ScopeId;
pub const null_scope = ir.null_scope;
pub const BindingRef = ir.BindingRef;

/// A variable binding within a scope
pub const Binding = struct {
    name: []const u8,
    name_atom: u16,
    slot: u16, // Changed from u8 to support atom indices > 255 for globals
    kind: BindingKind,
    is_const: bool,
    is_captured: bool, // Set when captured by an inner function

    pub const BindingKind = enum {
        variable, // var/let/const
        parameter, // Function parameter
        function, // Function declaration (hoisted)
        catch_param, // catch(e) parameter
        import, // Import binding
    };
};

/// Upvalue - a variable captured from an outer function scope
pub const Upvalue = struct {
    pub const Capture = union(enum) {
        local: u8,
        upvalue: u8,
    };

    /// Stable identity of the source binding. These fields are used to
    /// deduplicate captures when the same binding is referenced more than
    /// once in a function.
    source_scope_id: ScopeId,
    source_slot: u8,

    /// Slot in this function's upvalue array
    slot: u8,

    /// The location from which this function's immediate parent supplies the
    /// value. A transitive capture must first be installed in every
    /// intervening function so the emitted parent-upvalue index is valid.
    capture: Capture,

    /// Name for debugging
    name: []const u8,
};

/// Scope kind determines variable behavior
pub const ScopeKind = enum {
    global, // Global scope
    function, // Function scope (has own 'this', arguments)
    block, // Block scope (let/const are block-scoped)
    for_loop, // For loop initializer scope
    catch_block, // Catch clause scope
    module, // ES module scope
};

/// A single scope in the scope tree
pub const Scope = struct {
    id: ScopeId,
    parent: ?ScopeId,
    kind: ScopeKind,

    /// Bindings declared in this scope
    bindings: std.ArrayList(Binding),

    /// Upvalues captured by this function (only for function scopes)
    upvalues: std.ArrayList(Upvalue),

    /// The function scope this scope belongs to (for finding upvalues)
    enclosing_function: ScopeId,

    /// Maximum local slot used (for bytecode local_count)
    max_local_count: u8,

    /// Current local slot for next declaration
    current_local_slot: u8,

    pub fn init(id: ScopeId, parent: ?ScopeId, kind: ScopeKind, enclosing_fn: ScopeId) Scope {
        return .{
            .id = id,
            .parent = parent,
            .kind = kind,
            .bindings = .empty,
            .upvalues = .empty,
            .enclosing_function = enclosing_fn,
            .max_local_count = 0,
            .current_local_slot = 0,
        };
    }

    pub fn deinit(self: *Scope, allocator: std.mem.Allocator) void {
        self.bindings.deinit(allocator);
        self.upvalues.deinit(allocator);
    }

    /// Find a mutable binding by name_atom (O(1) comparison per binding)
    pub fn findLocalMutByAtom(self: *Scope, name_atom: u16) ?*Binding {
        for (self.bindings.items) |*binding| {
            if (binding.name_atom == name_atom) {
                return binding;
            }
        }
        return null;
    }

    /// Check if this is a function scope
    pub fn isFunction(self: *const Scope) bool {
        return self.kind == .function;
    }
};

/// The scope analyzer - manages the scope tree and variable resolution
pub const ScopeAnalyzer = struct {
    allocator: std.mem.Allocator,
    scopes: std.ArrayList(Scope),
    current_scope: ScopeId,
    next_scope_id: ScopeId,

    pub fn init(allocator: std.mem.Allocator) !ScopeAnalyzer {
        var analyzer = ScopeAnalyzer{
            .allocator = allocator,
            .scopes = .empty,
            .current_scope = 0,
            .next_scope_id = 0,
        };

        // Create global scope
        _ = try analyzer.pushScopeInternal(.global, 0);

        return analyzer;
    }

    pub fn deinit(self: *ScopeAnalyzer) void {
        for (self.scopes.items) |*scope| {
            scope.deinit(self.allocator);
        }
        self.scopes.deinit(self.allocator);
    }

    /// Push a new scope onto the stack
    pub fn pushScope(self: *ScopeAnalyzer, kind: ScopeKind) !ScopeId {
        const enclosing_fn = if (kind == .function)
            self.next_scope_id
        else
            self.scopes.items[self.current_scope].enclosing_function;

        return try self.pushScopeInternal(kind, enclosing_fn);
    }

    fn pushScopeInternal(self: *ScopeAnalyzer, kind: ScopeKind, enclosing_fn: ScopeId) !ScopeId {
        const id = self.next_scope_id;
        self.next_scope_id += 1;

        const parent: ?ScopeId = if (self.scopes.items.len > 0) self.current_scope else null;

        // Inherit local slot from parent (for block scopes in same function)
        var initial_slot: u8 = 0;
        if (parent) |p| {
            const parent_scope = &self.scopes.items[p];
            if (kind != .function and parent_scope.enclosing_function == enclosing_fn) {
                initial_slot = parent_scope.current_local_slot;
            }
        }

        var scope = Scope.init(id, parent, kind, enclosing_fn);
        scope.current_local_slot = initial_slot;

        try self.scopes.append(self.allocator, scope);
        self.current_scope = id;

        return id;
    }

    /// Pop the current scope
    pub fn popScope(self: *ScopeAnalyzer) void {
        const scope = &self.scopes.items[self.current_scope];

        // Update parent's max_local_count if needed
        if (scope.parent) |parent_id| {
            const parent = &self.scopes.items[parent_id];
            if (scope.enclosing_function == parent.enclosing_function) {
                // Same function - propagate max
                if (scope.max_local_count > parent.max_local_count) {
                    parent.max_local_count = scope.max_local_count;
                }
            }
            self.current_scope = parent_id;
        }
    }

    /// Declare a new binding in the current scope
    pub fn declareBinding(
        self: *ScopeAnalyzer,
        name: []const u8,
        name_atom: u16,
        kind: Binding.BindingKind,
        is_const: bool,
    ) !BindingRef {
        const scope = &self.scopes.items[self.current_scope];

        // Global scope - use atom index as slot, no local allocation
        if (scope.kind == .global) {
            try scope.bindings.append(self.allocator, .{
                .name = name,
                .name_atom = name_atom,
                .slot = name_atom, // Use atom for globals (no truncation)
                .kind = kind,
                .is_const = is_const,
                .is_captured = false,
            });

            return .{
                .scope_id = self.current_scope,
                .slot = name_atom,
                .name_atom = name_atom,
                .kind = .global,
            };
        }

        // Local scope - allocate local slot
        const slot = scope.current_local_slot;

        // Check for 255 local limit
        if (slot >= 255) {
            return error.TooManyLocals;
        }

        try scope.bindings.append(self.allocator, .{
            .name = name,
            .name_atom = name_atom,
            .slot = slot,
            .kind = kind,
            .is_const = is_const,
            .is_captured = false,
        });

        scope.current_local_slot = slot + 1;
        if (scope.current_local_slot > scope.max_local_count) {
            scope.max_local_count = scope.current_local_slot;
        }

        return .{
            .scope_id = self.current_scope,
            .slot = slot,
            .name_atom = name_atom,
            .kind = if (kind == .parameter) .argument else .local,
        };
    }

    /// Resolve a variable name, potentially creating upvalues
    pub fn resolveBinding(self: *ScopeAnalyzer, name: []const u8, name_atom: u16) !BindingRef {
        var scope_id = self.current_scope;
        var crossed_function = false;
        const current_function_scope: ScopeId = self.scopes.items[scope_id].enclosing_function;

        while (true) {
            const scope = &self.scopes.items[scope_id];

            // Look for binding in current scope (O(1) comparison via atom)
            if (scope.findLocalMutByAtom(name_atom)) |binding| {
                // Check if this is a global scope binding
                if (scope.kind == .global) {
                    return .{
                        .scope_id = scope_id,
                        .slot = binding.slot,
                        .name_atom = binding.name_atom,
                        .kind = .global,
                    };
                }

                if (crossed_function) {
                    // We need to create an upvalue chain
                    binding.is_captured = true;
                    const upvalue_slot = try self.createUpvalueChain(
                        current_function_scope,
                        scope_id,
                        @truncate(binding.slot), // Local slots are u8 (checked at allocation)
                        name,
                    );

                    return .{
                        .scope_id = current_function_scope,
                        .slot = upvalue_slot,
                        .name_atom = name_atom,
                        .kind = .upvalue,
                    };
                } else {
                    // Same function - direct local access
                    return .{
                        .scope_id = scope_id,
                        .slot = binding.slot,
                        .name_atom = binding.name_atom,
                        .kind = if (binding.kind == .parameter) .argument else .local,
                    };
                }
            }

            // Track if we crossed a function boundary
            if (scope.kind == .function) {
                crossed_function = true;
            }

            // Move to parent scope
            if (scope.parent) |parent| {
                scope_id = parent;
            } else {
                // Not found - it's an undeclared/implicit global (builtin or external)
                return .{
                    .scope_id = 0,
                    .slot = name_atom,
                    .name_atom = name_atom,
                    .kind = .undeclared_global,
                };
            }
        }
    }

    /// Create upvalue chain from inner function to captured variable
    fn createUpvalueChain(
        self: *ScopeAnalyzer,
        inner_function_scope: ScopeId,
        outer_scope: ScopeId,
        outer_slot: u8,
        name: []const u8,
    ) !u8 {
        const source_function_scope = self.scopes.items[outer_scope].enclosing_function;
        const parent_scope = self.scopes.items[inner_function_scope].parent orelse
            return error.InvalidScopeChain;
        const parent_function_scope = self.scopes.items[parent_scope].enclosing_function;

        // Check if this source binding is already captured by the inner
        // function. The immediate parent location can differ at each level,
        // so it is not a safe identity for deduplication.
        for (self.scopes.items[inner_function_scope].upvalues.items, 0..) |uv, i| {
            if (uv.source_scope_id == outer_scope and uv.source_slot == outer_slot) {
                return @intCast(i);
            }
        }

        const capture: Upvalue.Capture = if (parent_function_scope == source_function_scope)
            .{ .local = outer_slot }
        else
            .{ .upvalue = try self.createUpvalueChain(
                parent_function_scope,
                outer_scope,
                outer_slot,
                name,
            ) };

        // Create new upvalue
        const inner_scope = &self.scopes.items[inner_function_scope];
        const slot: u8 = @intCast(inner_scope.upvalues.items.len);
        if (slot >= 255) return error.TooManyUpvalues;

        try inner_scope.upvalues.append(self.allocator, .{
            .source_scope_id = outer_scope,
            .source_slot = outer_slot,
            .slot = slot,
            .capture = capture,
            .name = name,
        });

        return slot;
    }

    /// Get the current scope
    pub fn getCurrentScope(self: *ScopeAnalyzer) *Scope {
        return &self.scopes.items[self.current_scope];
    }

    /// Get a scope by ID
    pub fn getScope(self: *ScopeAnalyzer, id: ScopeId) *Scope {
        return &self.scopes.items[id];
    }

    /// Get upvalues for a function scope
    pub fn getUpvalues(self: *const ScopeAnalyzer, function_scope: ScopeId) []const Upvalue {
        return self.scopes.items[function_scope].upvalues.items;
    }

    /// Get local count for a function scope
    pub fn getLocalCount(self: *const ScopeAnalyzer, function_scope: ScopeId) u8 {
        return self.scopes.items[function_scope].max_local_count;
    }
};

/// Upvalue info for bytecode generation
pub const UpvalueInfo = struct {
    is_local: bool, // true: from parent's locals, false: from parent's upvalues
    index: u8,
};

// --- Tests ---

test "basic scope and binding" {
    var analyzer = try ScopeAnalyzer.init(std.testing.allocator);
    defer analyzer.deinit();

    // Declare in global scope - returns .global kind (not .local)
    const x_ref = try analyzer.declareBinding("x", 1, .variable, false);
    try std.testing.expectEqual(BindingRef.BindingKind.global, x_ref.kind);
    try std.testing.expectEqual(@as(u8, 1), x_ref.slot); // Atom index stored in slot

    // Resolve x - should find it as global
    const resolved = try analyzer.resolveBinding("x", 1);
    try std.testing.expectEqual(BindingRef.BindingKind.global, resolved.kind);
    try std.testing.expectEqual(@as(u8, 1), resolved.slot);

    // Resolve undefined - should be undeclared_global (not found in any scope)
    const undefined_ref = try analyzer.resolveBinding("undefined", 2);
    try std.testing.expectEqual(BindingRef.BindingKind.undeclared_global, undefined_ref.kind);
}

test "nested function creates upvalue" {
    var analyzer = try ScopeAnalyzer.init(std.testing.allocator);
    defer analyzer.deinit();

    // Global scope: declare x
    _ = try analyzer.declareBinding("x", 1, .variable, false);

    // Enter outer function
    _ = try analyzer.pushScope(.function);
    const outer_y = try analyzer.declareBinding("y", 2, .variable, false);
    try std.testing.expectEqual(@as(u8, 0), outer_y.slot);

    // Enter inner function
    const inner_scope_id = try analyzer.pushScope(.function);

    // Resolve y from inner function - should create upvalue
    const y_ref = try analyzer.resolveBinding("y", 2);
    try std.testing.expectEqual(BindingRef.BindingKind.upvalue, y_ref.kind);
    try std.testing.expectEqual(@as(u8, 0), y_ref.slot);

    // Check upvalue was created
    const upvalues = analyzer.getUpvalues(inner_scope_id);
    try std.testing.expectEqual(@as(usize, 1), upvalues.len);
    try std.testing.expectEqualStrings("y", upvalues[0].name);
    try std.testing.expectEqual(@as(u8, 0), upvalues[0].capture.local);
}

test "transitive capture installs an upvalue in every parent function" {
    var analyzer = try ScopeAnalyzer.init(std.testing.allocator);
    defer analyzer.deinit();

    const outer_scope = try analyzer.pushScope(.function);
    _ = try analyzer.declareBinding("value", 1, .variable, false);
    const middle_scope = try analyzer.pushScope(.function);
    const inner_scope = try analyzer.pushScope(.function);

    const resolved = try analyzer.resolveBinding("value", 1);
    try std.testing.expectEqual(BindingRef.BindingKind.upvalue, resolved.kind);

    const middle_upvalues = analyzer.getUpvalues(middle_scope);
    try std.testing.expectEqual(@as(usize, 1), middle_upvalues.len);
    try std.testing.expectEqual(@as(u8, 0), middle_upvalues[0].capture.local);
    try std.testing.expectEqual(outer_scope, middle_upvalues[0].source_scope_id);

    const inner_upvalues = analyzer.getUpvalues(inner_scope);
    try std.testing.expectEqual(@as(usize, 1), inner_upvalues.len);
    try std.testing.expectEqual(@as(u8, 0), inner_upvalues[0].capture.upvalue);
    try std.testing.expectEqual(outer_scope, inner_upvalues[0].source_scope_id);
}

test "block scope inherits local slots" {
    var analyzer = try ScopeAnalyzer.init(std.testing.allocator);
    defer analyzer.deinit();

    // Enter function
    _ = try analyzer.pushScope(.function);
    _ = try analyzer.declareBinding("a", 1, .variable, false); // slot 0

    // Enter block
    _ = try analyzer.pushScope(.block);
    const b = try analyzer.declareBinding("b", 2, .variable, false); // slot 1

    try std.testing.expectEqual(@as(u8, 1), b.slot);

    // Leave block and enter another
    analyzer.popScope();
    _ = try analyzer.pushScope(.block);
    const c = try analyzer.declareBinding("c", 3, .variable, false);

    // c reuses slot 1 since b is out of scope
    try std.testing.expectEqual(@as(u8, 1), c.slot);
}

test "function parameters" {
    var analyzer = try ScopeAnalyzer.init(std.testing.allocator);
    defer analyzer.deinit();

    // Enter function
    _ = try analyzer.pushScope(.function);

    // Declare parameters
    const param_a = try analyzer.declareBinding("a", 1, .parameter, false);
    const param_b = try analyzer.declareBinding("b", 2, .parameter, false);

    try std.testing.expectEqual(BindingRef.BindingKind.argument, param_a.kind);
    try std.testing.expectEqual(@as(u8, 0), param_a.slot);
    try std.testing.expectEqual(BindingRef.BindingKind.argument, param_b.kind);
    try std.testing.expectEqual(@as(u8, 1), param_b.slot);

    // Resolve parameter
    const resolved = try analyzer.resolveBinding("a", 1);
    try std.testing.expectEqual(BindingRef.BindingKind.argument, resolved.kind);
}

test "captured binding allocation failure propagates" {
    var analyzer = try ScopeAnalyzer.init(std.testing.allocator);
    defer analyzer.deinit();

    _ = try analyzer.pushScope(.function);
    _ = try analyzer.declareBinding("captured", 1, .variable, false);
    _ = try analyzer.pushScope(.function);

    const allocator = analyzer.allocator;
    defer analyzer.allocator = allocator;
    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    analyzer.allocator = failing.allocator();

    try std.testing.expectError(error.OutOfMemory, analyzer.resolveBinding("captured", 1));
}
