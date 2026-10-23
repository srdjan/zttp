//! Shared resolution for functions dispatched through `routerMatch`.
//!
//! The flow checker, handler verifier, effect inference, and fault analysis
//! must agree on which route functions a literal route table can dispatch.
//! This module owns that answer. An unresolved table entry or an unstable
//! binding is explicit in `FunctionSet.unresolved`, so each proof analysis can
//! fail closed for the property it decides.

const std = @import("std");
const ir = @import("zts-engine").parser.ir;
const object = @import("zts-engine").object;
const context = @import("zts-engine").context;
const bool_checker_mod = @import("bool_checker.zig");
const module_facts_mod = @import("module_facts.zig");

const Node = ir.Node;
pub const NodeIndex = ir.NodeIndex;
const IrView = ir.IrView;
const null_node = ir.null_node;
const packBindingKey = bool_checker_mod.packBindingKey;
const max_resolution_depth = 8;

pub const FunctionSet = struct {
    functions: std.ArrayListUnmanaged(NodeIndex) = .empty,
    unresolved: bool = false,

    pub fn deinit(self: *FunctionSet, allocator: std.mem.Allocator) void {
        self.functions.deinit(allocator);
    }

    fn appendUnique(self: *FunctionSet, allocator: std.mem.Allocator, function: NodeIndex) !void {
        if (std.mem.indexOfScalar(NodeIndex, self.functions.items, function) != null) return;
        try self.functions.append(allocator, function);
    }
};

pub const Resolver = struct {
    ir_view: IrView,
    atoms: ?*context.AtomTable,
    facts: *const module_facts_mod.ModuleFacts,

    pub fn init(
        ir_view: IrView,
        atoms: ?*context.AtomTable,
        facts: *const module_facts_mod.ModuleFacts,
    ) Resolver {
        return .{ .ir_view = ir_view, .atoms = atoms, .facts = facts };
    }

    /// Find every route function named by every `routerMatch` call. This root
    /// set is intentionally broader than dispatch resolution: an initially
    /// resolvable function is still checked as a request root when later
    /// mutation makes the dispatch itself unresolved.
    pub fn routeRoots(self: *const Resolver, allocator: std.mem.Allocator) !FunctionSet {
        var result: FunctionSet = .{};
        errdefer result.deinit(allocator);

        for (0..self.ir_view.nodeCount()) |idx_usize| {
            const idx: NodeIndex = @intCast(idx_usize);
            if (self.ir_view.getTag(idx) != .call) continue;
            const call = self.ir_view.getCall(idx) orelse continue;
            if (!self.isRouterMatchCallee(call.callee)) continue;
            if (call.args_count == 0) {
                result.unresolved = true;
                continue;
            }

            const table_arg = self.ir_view.getListIndex(call.args_start, 0);
            const table = self.resolveRouteTableForRoots(table_arg) orelse {
                result.unresolved = true;
                continue;
            };
            const route_object = self.ir_view.getObject(table) orelse {
                result.unresolved = true;
                continue;
            };
            if (route_object.properties_count == 0) result.unresolved = true;
            for (0..route_object.properties_count) |property_index| {
                const property_node = self.ir_view.getListIndex(
                    route_object.properties_start,
                    @intCast(property_index),
                );
                if (self.ir_view.getTag(property_node) != .object_property) {
                    result.unresolved = true;
                    continue;
                }
                const property = self.ir_view.getProperty(property_node) orelse {
                    result.unresolved = true;
                    continue;
                };
                try self.appendInitialFunctions(allocator, &result, property.value);
            }
            try self.appendAssignedTableFunctions(allocator, &result, table_arg);
            if (self.routerMatchResultIsUnstable(idx)) result.unresolved = true;
        }
        return result;
    }

    /// Resolve `found.handler(...)` when `found` is produced by
    /// `routerMatch`. Null means this is not a recognized route dispatch.
    /// A non-null set can contain resolved targets and still be unresolved,
    /// which represents a union with an unknown target.
    pub fn resolveDispatch(
        self: *const Resolver,
        allocator: std.mem.Allocator,
        callee: NodeIndex,
    ) !?FunctionSet {
        if (!self.hasRouterMatchImport()) return null;
        return self.resolveDispatchDepth(allocator, callee, 0);
    }

    fn resolveDispatchDepth(
        self: *const Resolver,
        allocator: std.mem.Allocator,
        callee: NodeIndex,
        depth: u8,
    ) !?FunctionSet {
        if (depth >= max_resolution_depth) return null;
        const tag = self.ir_view.getTag(callee) orelse return null;

        // `const dispatch = found.handler; dispatch(req)` is still a route
        // call, but extracting the method loses the stable receiver relation.
        // Resolve what is visible and mark the selector unresolved.
        if (tag == .identifier) {
            const binding = self.ir_view.getBinding(callee) orelse return null;
            const declaration = self.findBindingDecl(binding) orelse return null;
            if (declaration.init == null_node) return null;
            var extracted = (try self.resolveDispatchDepth(allocator, declaration.init, depth + 1)) orelse return null;
            extracted.unresolved = true;
            return extracted;
        }

        if (tag != .member_access and tag != .optional_chain and tag != .computed_access) return null;
        const member = self.ir_view.getMember(callee) orelse return null;
        const is_computed = tag == .computed_access;
        var result: FunctionSet = .{};
        errdefer result.deinit(allocator);
        const object_tag = self.ir_view.getTag(member.object) orelse return null;
        const matched = if (object_tag == .identifier) blk: {
            const binding = self.ir_view.getBinding(member.object) orelse return null;
            const found = try self.appendBindingRouteTargets(allocator, &result, binding, depth + 1);
            if (found and (self.bindingIsMutated(binding) or
                self.bindingHasAlias(binding) or
                self.bindingEscapesStableResolution(binding, false)))
            {
                result.unresolved = true;
            }
            break :blk found;
        } else if (object_tag == .call) blk: {
            break :blk try self.appendRouterMatchTargets(allocator, &result, member.object);
        } else false;

        if (!matched) {
            result.deinit(allocator);
            return null;
        }
        if (is_computed) {
            const property = self.computedPropertyName(member.computed);
            if (property == null or !std.mem.eql(u8, property.?, "handler")) result.unresolved = true;
            // The original flow resolver modeled only dot access. Keep a
            // computed selector conservative even when its literal is known.
            result.unresolved = true;
        } else {
            const property = self.resolveAtomName(member.property);
            if (property == null or !std.mem.eql(u8, property.?, "handler")) result.unresolved = true;
            if (tag == .optional_chain) result.unresolved = true;
        }
        if (result.functions.items.len == 0) result.unresolved = true;
        return result;
    }

    fn routerMatchResultIsUnstable(self: *const Resolver, call_node: NodeIndex) bool {
        for (0..self.ir_view.nodeCount()) |idx_usize| {
            const idx: NodeIndex = @intCast(idx_usize);
            if (self.ir_view.getTag(idx) != .var_decl) continue;
            const declaration = self.ir_view.getVarDecl(idx) orelse return true;
            if (declaration.init != call_node) continue;
            const binding = declaration.binding;
            return self.bindingIsMutated(binding) or
                self.bindingHasAlias(binding) or
                self.bindingEscapesStableResolution(binding, false) or
                self.bindingHasExtractedOrComputedSelector(binding);
        }
        // An inline result is resolved at its member call. If no binding owns
        // it, there is no alias or mutation surface to inspect here.
        return false;
    }

    fn bindingHasExtractedOrComputedSelector(self: *const Resolver, binding: ir.BindingRef) bool {
        const key = packBindingKey(binding.scope_id, binding.slot);
        for (0..self.ir_view.nodeCount()) |idx_usize| {
            const idx: NodeIndex = @intCast(idx_usize);
            const tag = self.ir_view.getTag(idx) orelse continue;
            if (tag == .computed_access) {
                const member = self.ir_view.getMember(idx) orelse return true;
                if (!self.nodeIsBinding(member.object, key)) continue;
                const property = self.computedPropertyName(member.computed) orelse return true;
                if (std.mem.eql(u8, property, "handler")) return true;
            }
            if (tag != .var_decl) continue;
            const declaration = self.ir_view.getVarDecl(idx) orelse return true;
            const init_tag = self.ir_view.getTag(declaration.init) orelse continue;
            if (init_tag != .member_access and init_tag != .optional_chain and init_tag != .computed_access) continue;
            const member = self.ir_view.getMember(declaration.init) orelse return true;
            if (!self.nodeIsBinding(member.object, key)) continue;
            if (init_tag == .computed_access) {
                const property = self.computedPropertyName(member.computed) orelse return true;
                if (std.mem.eql(u8, property, "handler")) return true;
                continue;
            }
            const property = self.resolveAtomName(member.property) orelse return true;
            if (std.mem.eql(u8, property, "handler")) return true;
        }
        return false;
    }

    fn appendBindingRouteTargets(
        self: *const Resolver,
        allocator: std.mem.Allocator,
        result: *FunctionSet,
        binding: ir.BindingRef,
        depth: u8,
    ) std.mem.Allocator.Error!bool {
        if (depth >= max_resolution_depth) {
            result.unresolved = true;
            return false;
        }
        var matched = false;
        if (self.findBindingDecl(binding)) |declaration| {
            if (declaration.init != null_node) {
                matched = try self.appendRouteSourceTargets(
                    allocator,
                    result,
                    declaration.init,
                    depth + 1,
                ) or matched;
            }
        }

        const key = packBindingKey(binding.scope_id, binding.slot);
        for (0..self.ir_view.nodeCount()) |idx_usize| {
            const idx: NodeIndex = @intCast(idx_usize);
            if (self.ir_view.getTag(idx) != .assignment) continue;
            const assignment = self.ir_view.getAssignment(idx) orelse {
                result.unresolved = true;
                continue;
            };
            if (self.assignmentRootMatch(assignment.target, key, 0) != .match) continue;
            matched = try self.appendRouteSourceTargets(
                allocator,
                result,
                assignment.value,
                depth + 1,
            ) or matched;
        }
        return matched;
    }

    fn appendRouteSourceTargets(
        self: *const Resolver,
        allocator: std.mem.Allocator,
        result: *FunctionSet,
        source: NodeIndex,
        depth: u8,
    ) std.mem.Allocator.Error!bool {
        if (try self.appendRouterMatchTargets(allocator, result, source)) return true;
        if (self.ir_view.getTag(source) != .identifier) {
            result.unresolved = true;
            return false;
        }
        const alias = self.ir_view.getBinding(source) orelse {
            result.unresolved = true;
            return false;
        };
        const matched = try self.appendBindingRouteTargets(allocator, result, alias, depth + 1);
        if (matched) result.unresolved = true;
        return matched;
    }

    fn appendRouterMatchTargets(
        self: *const Resolver,
        allocator: std.mem.Allocator,
        result: *FunctionSet,
        node: NodeIndex,
    ) !bool {
        if (self.ir_view.getTag(node) != .call) return false;
        const call = self.ir_view.getCall(node) orelse return false;
        if (!self.isRouterMatchCallee(call.callee)) return false;
        if (call.args_count == 0) {
            result.unresolved = true;
            return true;
        }

        const table_arg = self.ir_view.getListIndex(call.args_start, 0);
        const table = self.resolveStableRouteTable(table_arg) orelse {
            result.unresolved = true;
            return true;
        };
        const route_object = self.ir_view.getObject(table) orelse {
            result.unresolved = true;
            return true;
        };
        if (route_object.properties_count == 0) result.unresolved = true;
        for (0..route_object.properties_count) |property_index| {
            const property_node = self.ir_view.getListIndex(
                route_object.properties_start,
                @intCast(property_index),
            );
            if (self.ir_view.getTag(property_node) != .object_property) {
                result.unresolved = true;
                continue;
            }
            const property = self.ir_view.getProperty(property_node) orelse {
                result.unresolved = true;
                continue;
            };
            const function = self.resolveFunctionNode(property.value) orelse {
                result.unresolved = true;
                continue;
            };
            try result.appendUnique(allocator, function);
        }
        return true;
    }

    fn appendInitialFunctions(
        self: *const Resolver,
        allocator: std.mem.Allocator,
        result: *FunctionSet,
        value: NodeIndex,
    ) !void {
        if (self.resolveInitialFunctionNode(value)) |function| {
            try result.appendUnique(allocator, function);
        } else {
            result.unresolved = true;
        }
        if (self.ir_view.getTag(value) != .identifier) return;
        const binding = self.ir_view.getBinding(value) orelse {
            result.unresolved = true;
            return;
        };
        const key = packBindingKey(binding.scope_id, binding.slot);
        for (0..self.ir_view.nodeCount()) |idx_usize| {
            const idx: NodeIndex = @intCast(idx_usize);
            if (self.ir_view.getTag(idx) != .assignment) continue;
            const assignment = self.ir_view.getAssignment(idx) orelse {
                result.unresolved = true;
                continue;
            };
            if (self.assignmentRootMatch(assignment.target, key, 0) != .match) continue;
            const function = self.resolveInitialFunctionNode(assignment.value) orelse {
                result.unresolved = true;
                continue;
            };
            try result.appendUnique(allocator, function);
        }
    }

    fn appendAssignedTableFunctions(
        self: *const Resolver,
        allocator: std.mem.Allocator,
        result: *FunctionSet,
        table_arg: NodeIndex,
    ) !void {
        if (self.ir_view.getTag(table_arg) != .identifier) return;
        const binding = self.ir_view.getBinding(table_arg) orelse return;
        const key = packBindingKey(binding.scope_id, binding.slot);
        for (0..self.ir_view.nodeCount()) |idx_usize| {
            const idx: NodeIndex = @intCast(idx_usize);
            if (self.ir_view.getTag(idx) != .assignment) continue;
            const assignment = self.ir_view.getAssignment(idx) orelse {
                result.unresolved = true;
                continue;
            };
            if (self.assignmentRootMatch(assignment.target, key, 0) != .match) continue;
            const function = self.resolveInitialFunctionNode(assignment.value) orelse continue;
            try result.appendUnique(allocator, function);
        }
    }

    fn isRouterMatchCallee(self: *const Resolver, callee: NodeIndex) bool {
        if (self.ir_view.getTag(callee) != .identifier) return false;
        const binding = self.ir_view.getBinding(callee) orelse return false;
        const record = self.facts.importForReference(
            binding,
            .legacy_slot,
            .builtin,
            .first,
        ) orelse return false;
        return std.mem.eql(u8, record.module_specifier, "zttp:router") and
            std.mem.eql(u8, record.imported_name, "routerMatch");
    }

    fn hasRouterMatchImport(self: *const Resolver) bool {
        for (self.facts.imports.items) |record| {
            if (record.resolution != .builtin) continue;
            if (std.mem.eql(u8, record.module_specifier, "zttp:router") and
                std.mem.eql(u8, record.imported_name, "routerMatch")) return true;
        }
        return false;
    }

    fn resolveRouteTableForRoots(self: *const Resolver, node: NodeIndex) ?NodeIndex {
        const tag = self.ir_view.getTag(node) orelse return null;
        if (tag == .object_literal) return node;
        if (tag != .identifier) return null;
        const binding = self.ir_view.getBinding(node) orelse return null;
        if (binding.kind != .global) return null;
        const declaration = self.findBindingDecl(binding) orelse return null;
        return if (self.ir_view.getTag(declaration.init) == .object_literal) declaration.init else null;
    }

    fn resolveStableRouteTable(self: *const Resolver, node: NodeIndex) ?NodeIndex {
        const tag = self.ir_view.getTag(node) orelse return null;
        if (tag == .object_literal) return node;
        if (tag != .identifier) return null;
        const binding = self.ir_view.getBinding(node) orelse return null;
        if (binding.kind != .global) return null;
        const declaration = self.findBindingDecl(binding) orelse return null;
        if (self.bindingIsMutated(binding) or
            self.bindingHasAlias(binding) or
            self.bindingEscapesStableResolution(binding, true)) return null;
        return if (self.ir_view.getTag(declaration.init) == .object_literal) declaration.init else null;
    }

    fn findBindingDecl(self: *const Resolver, binding: ir.BindingRef) ?Node.VarDecl {
        const key = packBindingKey(binding.scope_id, binding.slot);
        for (0..self.ir_view.nodeCount()) |idx_usize| {
            const idx: NodeIndex = @intCast(idx_usize);
            const tag = self.ir_view.getTag(idx) orelse continue;
            if (tag != .var_decl and tag != .function_decl) continue;
            const declaration = self.ir_view.getVarDecl(idx) orelse continue;
            if (packBindingKey(declaration.binding.scope_id, declaration.binding.slot) == key) return declaration;
        }
        return null;
    }

    /// True when a mutation of `binding` may occur anywhere in the program. An
    /// assignment whose target roots at the binding counts. An assignment whose
    /// target has an untracked root (a call result, a literal, a conditional)
    /// also counts, because that root may alias the table: a missed mutation
    /// is the unsound direction. The cost is that one untracked root anywhere
    /// in the file makes every table, and every callee parameter read through
    /// this function, look mutated.
    fn bindingIsMutated(self: *const Resolver, binding: ir.BindingRef) bool {
        const key = packBindingKey(binding.scope_id, binding.slot);
        for (0..self.ir_view.nodeCount()) |idx_usize| {
            const idx: NodeIndex = @intCast(idx_usize);
            if (self.ir_view.getTag(idx) != .assignment) continue;
            const assignment = self.ir_view.getAssignment(idx) orelse return true;
            switch (self.assignmentRootMatch(assignment.target, key, 0)) {
                .match, .untracked => return true,
                .other => {},
            }
        }
        return false;
    }

    fn bindingHasAlias(self: *const Resolver, binding: ir.BindingRef) bool {
        const key = packBindingKey(binding.scope_id, binding.slot);
        for (0..self.ir_view.nodeCount()) |idx_usize| {
            const idx: NodeIndex = @intCast(idx_usize);
            const tag = self.ir_view.getTag(idx) orelse continue;
            if (tag == .var_decl) {
                const declaration = self.ir_view.getVarDecl(idx) orelse continue;
                if (self.ir_view.getTag(declaration.init) != .identifier) continue;
                const source = self.ir_view.getBinding(declaration.init) orelse continue;
                if (packBindingKey(source.scope_id, source.slot) == key) return true;
            } else if (tag == .assignment) {
                const assignment = self.ir_view.getAssignment(idx) orelse continue;
                if (self.ir_view.getTag(assignment.value) != .identifier) continue;
                const source = self.ir_view.getBinding(assignment.value) orelse continue;
                if (packBindingKey(source.scope_id, source.slot) == key) return true;
            }
        }
        return false;
    }

    fn bindingEscapesStableResolution(
        self: *const Resolver,
        binding: ir.BindingRef,
        allow_router_match: bool,
    ) bool {
        return self.bindingEscapesStableResolutionDepth(binding, allow_router_match, 0);
    }

    /// True when `binding` occurs in a value position that is not an
    /// explicitly stable use. The walk visits every node as a parent and reads
    /// its children through `IrView.expressionChildren`, so it reaches a
    /// `for...of` iterable, a `match` discriminant, an `expr_stmt` value, an
    /// array or object element, a nested function body, and every other code
    /// position without a fixed list of node kinds. A parent kind that the walk
    /// does not name is an escape, so a new node kind is unsafe by default.
    ///
    /// A child is checked when its value may be the table itself:
    /// `valueMayBeBinding` is true for the identifier, and for a logical
    /// operator, a conditional, or a sequence that can yield it. These
    /// value-transparent nodes pass the question to their own parent, which
    /// decides. The stable parent positions are:
    /// - the object of a member read, `table["GET /"]`;
    /// - the target of an assignment, because `bindingIsMutated` already
    ///   decides every assignment whose target roots at the binding;
    /// - an operand of a comparison, arithmetic, or unary operator, and the
    ///   test of a conditional, `if`, loop, or `assert`, because the result is
    ///   a primitive that cannot alias the table;
    /// - an expression statement, because the value is dropped;
    /// - call argument 0 of `routerMatch`, when `allow_router_match` is set;
    /// - a call argument that `callKeepsArgumentLocal` proves stays local.
    ///
    /// Every other position is an escape: the value of an assignment, a
    /// variable initializer, a return, an array or object element, a spread,
    /// a loop iterable, a `match` discriminant, a callee, a computed index,
    /// and any call argument that is not proven local.
    fn bindingEscapesStableResolutionDepth(
        self: *const Resolver,
        binding: ir.BindingRef,
        allow_router_match: bool,
        depth: u8,
    ) bool {
        if (depth >= max_resolution_depth) return true;
        const key = packBindingKey(binding.scope_id, binding.slot);
        for (0..self.ir_view.nodeCount()) |idx_usize| {
            const parent: NodeIndex = @intCast(idx_usize);
            const parent_tag = self.ir_view.getTag(parent) orelse continue;
            var children = self.ir_view.expressionChildren(parent);
            while (children.next()) |child| {
                if (!self.valueMayBeBinding(child, key, 0)) continue;
                switch (parent_tag) {
                    .member_access, .optional_chain, .computed_access => {
                        const member = self.ir_view.getMember(parent) orelse return true;
                        // Reading a member does not store or pass the table.
                        // The index of a computed access is a value position.
                        if (member.object == child and member.computed != child) continue;
                        return true;
                    },
                    .assignment => {
                        const assignment = self.ir_view.getAssignment(parent) orelse return true;
                        // The target is a mutation, counted by `bindingIsMutated`.
                        if (assignment.target == child and assignment.value != child) continue;
                        return true;
                    },
                    .call, .method_call => {
                        const call = self.ir_view.getCall(parent) orelse return true;
                        if (call.callee == child) return true;
                        if (!self.nodeIsBinding(child, key)) return true;
                        var argument_position: ?usize = null;
                        for (0..call.args_count) |argument_index| {
                            const argument = self.ir_view.getListIndex(call.args_start, @intCast(argument_index));
                            if (argument == child) {
                                argument_position = argument_index;
                                break;
                            }
                        }
                        const argument_index = argument_position orelse return true;
                        if (allow_router_match and argument_index == 0 and
                            self.isRouterMatchCallee(call.callee)) continue;
                        if (self.callKeepsArgumentLocal(call, argument_index, depth + 1)) continue;
                        return true;
                    },
                    // The result of a comparison, arithmetic, or unary
                    // operator is a primitive. A logical operator, a
                    // conditional, and a sequence yield an operand, so the
                    // question moves to their own parent, which is visited as
                    // a parent of this node.
                    .binary_op, .unary_op, .ternary, .sequence_expr, .comma_expr => continue,
                    // The value is dropped.
                    .expr_stmt => continue,
                    .if_stmt => {
                        const stmt = self.ir_view.getIfStmt(parent) orelse return true;
                        if (stmt.condition == child) continue;
                        return true;
                    },
                    .while_stmt, .for_stmt, .do_while_stmt => {
                        const loop = self.ir_view.getLoop(parent) orelse return true;
                        if (loop.condition == child) continue;
                        return true;
                    },
                    .assert_stmt => {
                        const stmt = self.ir_view.getAssertStmt(parent) orelse return true;
                        if (stmt.condition == child) continue;
                        return true;
                    },
                    // exhaustive: a parent kind that this walk does not name is an
                    // escape, because a missed escape is the unsound direction. Every
                    // other parent position stores, passes, iterates, or returns the
                    // table, so the binding is not stable.
                    else => return true,
                }
            }
        }
        return false;
    }

    /// True when the value of `node` may be the table bound to `key` itself:
    /// the identifier, or a node that yields one of its operands (a logical
    /// operator, a conditional branch, a sequence). A node that builds a new
    /// value from the table, such as an array literal, is not included: its
    /// elements are children and are checked as such.
    fn valueMayBeBinding(self: *const Resolver, node: NodeIndex, key: u32, depth: usize) bool {
        if (node == null_node) return false;
        // Expression edges point to nodes that already exist, so this walk is
        // acyclic. The node count is the structural bound. Past it, answer yes.
        if (depth >= self.ir_view.nodeCount()) return true;
        const tag = self.ir_view.getTag(node) orelse return true;
        switch (tag) {
            .identifier => return self.nodeIsBinding(node, key),
            .binary_op => {
                const binary = self.ir_view.getBinary(node) orelse return true;
                switch (binary.op) {
                    .and_op, .or_op, .nullish => {},
                    // exhaustive: comparison, arithmetic, and bitwise operators yield a
                    // primitive and never the table itself.
                    else => return false,
                }
                return self.valueMayBeBinding(binary.left, key, depth + 1) or
                    self.valueMayBeBinding(binary.right, key, depth + 1);
            },
            .ternary => {
                const ternary = self.ir_view.getTernary(node) orelse return true;
                return self.valueMayBeBinding(ternary.then_branch, key, depth + 1) or
                    self.valueMayBeBinding(ternary.else_branch, key, depth + 1);
            },
            .sequence_expr, .comma_expr => {
                const array = self.ir_view.getArray(node) orelse return true;
                for (0..array.elements_count) |index| {
                    const element = self.ir_view.getListIndex(array.elements_start, @intCast(index));
                    if (self.valueMayBeBinding(element, key, depth + 1)) return true;
                }
                return false;
            },
            // exhaustive: a call result, a member read, and the other shapes
            // build or fetch a different value, never the table itself. A call
            // argument that is the table is checked at the call.
            else => return false,
        }
    }

    fn callKeepsArgumentLocal(
        self: *const Resolver,
        call: Node.CallExpr,
        argument_index: usize,
        depth: u8,
    ) bool {
        if (argument_index == 0 and self.isGlobalMethodCall(call.callee, "Array", &.{"isArray"})) {
            const member = self.ir_view.getMember(call.callee) orelse return false;
            const array_binding = self.ir_view.getBinding(member.object) orelse return false;
            return !self.bindingIsMutated(array_binding) and
                !self.bindingHasAlias(array_binding) and
                !self.bindingEscapesStableResolutionDepth(array_binding, false, depth);
        }
        const function_node = self.resolveFunctionNode(call.callee) orelse return false;
        const function = self.ir_view.getFunction(function_node) orelse return false;
        if (argument_index >= function.params_count) return false;
        const parameter = self.ir_view.getListIndex(function.params_start, @intCast(argument_index));
        const binding = self.ir_view.paramBinding(parameter) orelse return false;
        const key = packBindingKey(binding.scope_id, binding.slot);
        for (0..self.ir_view.nodeCount()) |idx_usize| {
            const idx: NodeIndex = @intCast(idx_usize);
            const tag = self.ir_view.getTag(idx) orelse continue;
            if (tag != .call and tag != .method_call) continue;
            const nested_call = self.ir_view.getCall(idx) orelse return false;
            // A method call on the parameter may mutate it. An untracked
            // receiver root cannot be this parameter, so it does not count here.
            if (self.assignmentRootMatch(nested_call.callee, key, 0) == .match) return false;
        }
        return !self.bindingIsMutated(binding) and
            !self.bindingHasAlias(binding) and
            !self.bindingEscapesStableResolutionDepth(binding, false, depth);
    }

    fn nodeIsBinding(self: *const Resolver, node: NodeIndex, key: u32) bool {
        if (self.ir_view.getTag(node) != .identifier) return false;
        const binding = self.ir_view.getBinding(node) orelse return false;
        return packBindingKey(binding.scope_id, binding.slot) == key;
    }

    fn resolveFunctionNode(self: *const Resolver, node: NodeIndex) ?NodeIndex {
        const tag = self.ir_view.getTag(node) orelse return null;
        return switch (tag) {
            .function_expr, .arrow_function => node,
            .function_decl => blk: {
                const declaration = self.ir_view.getVarDecl(node) orelse break :blk null;
                break :blk if (declaration.init != null_node) declaration.init else null;
            },
            .identifier => blk: {
                const binding = self.ir_view.getBinding(node) orelse break :blk null;
                const declaration = self.findBindingDecl(binding) orelse break :blk null;
                if (self.bindingIsMutated(binding)) break :blk null;
                const init_tag = self.ir_view.getTag(declaration.init) orelse break :blk null;
                if (init_tag != .function_expr and init_tag != .arrow_function) break :blk null;
                break :blk declaration.init;
            },
            // exhaustive: other value shapes do not name one statically
            // resolved function body.
            else => null,
        };
    }

    fn resolveInitialFunctionNode(self: *const Resolver, node: NodeIndex) ?NodeIndex {
        const tag = self.ir_view.getTag(node) orelse return null;
        return switch (tag) {
            .function_expr, .arrow_function => node,
            .identifier => blk: {
                const binding = self.ir_view.getBinding(node) orelse break :blk null;
                const declaration = self.findBindingDecl(binding) orelse break :blk null;
                const init_tag = self.ir_view.getTag(declaration.init) orelse break :blk null;
                if (init_tag != .function_expr and init_tag != .arrow_function) break :blk null;
                break :blk declaration.init;
            },
            // exhaustive: an initial route entry can be only an inline
            // function or an identifier whose initializer is a function.
            else => null,
        };
    }

    const RootMatch = enum {
        /// The root is, or contains, the binding with the given key.
        match,
        /// The root is a shape this resolver cannot follow, such as a call
        /// result or a conditional. It may alias any binding.
        untracked,
        /// The root is a different binding, or an identifier with no binding.
        other,
    };

    /// Classify the root of an assignment target or a call receiver against
    /// the binding `key`. A member chain follows its object. An array literal
    /// root, as in `[table][0]["GET /"] = f`, matches when any element roots
    /// at the binding, because `[table][0]` is the table itself. Any other
    /// non-identifier root is `untracked`: reporting it as `other` would let a
    /// mutation through an unfollowed path leave the table looking stable,
    /// which is the unsound direction. An identifier with no binding keeps the
    /// old answer, `other`.
    fn assignmentRootMatch(
        self: *const Resolver,
        target: NodeIndex,
        key: u32,
        depth: usize,
    ) RootMatch {
        // Expression edges point to nodes that already exist, so this walk is
        // acyclic. The node count is the structural bound.
        if (depth >= self.ir_view.nodeCount()) return .untracked;
        const tag = self.ir_view.getTag(target) orelse return .untracked;
        switch (tag) {
            .identifier => {
                const binding = self.ir_view.getBinding(target) orelse return .other;
                return if (packBindingKey(binding.scope_id, binding.slot) == key) .match else .other;
            },
            .member_access, .optional_chain, .computed_access => {
                const member = self.ir_view.getMember(target) orelse return .untracked;
                return self.assignmentRootMatch(member.object, key, depth + 1);
            },
            .array_literal => {
                const array = self.ir_view.getArray(target) orelse return .untracked;
                var result: RootMatch = .other;
                for (0..array.elements_count) |index| {
                    const element = self.ir_view.getListIndex(array.elements_start, @intCast(index));
                    if (element == null_node) continue;
                    switch (self.assignmentRootMatch(element, key, depth + 1)) {
                        .match => return .match,
                        .untracked => result = .untracked,
                        .other => {},
                    }
                }
                return result;
            },
            // exhaustive: any other target shape is reported as untracked and
            // not ignored, because a missed root is the unsound direction and
            // it may alias the table.
            else => return .untracked,
        }
    }
    fn isGlobalMethodCall(
        self: *const Resolver,
        callee: NodeIndex,
        object_name: []const u8,
        method_names: []const []const u8,
    ) bool {
        const tag = self.ir_view.getTag(callee) orelse return false;
        if (tag != .member_access and tag != .optional_chain) return false;
        const member = self.ir_view.getMember(callee) orelse return false;
        if (self.ir_view.getTag(member.object) != .identifier) return false;
        const binding = self.ir_view.getBinding(member.object) orelse return false;
        if (binding.kind != .undeclared_global) return false;
        const found_object = self.resolveAtomName(binding.name_atom) orelse return false;
        if (!std.mem.eql(u8, found_object, object_name)) return false;
        const found_method = self.resolveAtomName(member.property) orelse return false;
        for (method_names) |method_name| {
            if (std.mem.eql(u8, found_method, method_name)) return true;
        }
        return false;
    }

    fn resolveAtomName(self: *const Resolver, atom_idx: u16) ?[]const u8 {
        if (self.atoms) |table| {
            const atom: object.Atom = @fromBackingInt(@intCast(atom_idx));
            if (atom.toPredefinedName()) |name| return name;
            return table.getName(atom);
        }
        if (self.ir_view.getString(atom_idx)) |name| return name;
        const atom: object.Atom = @fromBackingInt(@intCast(atom_idx));
        return atom.toPredefinedName();
    }

    fn computedPropertyName(self: *const Resolver, node: NodeIndex) ?[]const u8 {
        if (node == null_node or self.ir_view.getTag(node) != .lit_string) return null;
        const string_idx = self.ir_view.getStringIdx(node) orelse return null;
        return self.ir_view.getString(string_idx);
    }
};
