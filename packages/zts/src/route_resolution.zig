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

    /// Resolve one catalog route key to the function held by the stable
    /// `routerMatch` table. The tool catalog uses the same `METHOD /path`
    /// spelling as the table. A non-null result can still be unresolved: that
    /// means a matching function was found, but another table shape or later
    /// mutation prevents the caller from treating the answer as closed.
    pub fn resolveRouteKey(
        self: *const Resolver,
        allocator: std.mem.Allocator,
        route_key: []const u8,
    ) !FunctionSet {
        var result: FunctionSet = .{};
        errdefer result.deinit(allocator);

        const wanted = parseRouteKey(route_key) orelse {
            result.unresolved = true;
            return result;
        };
        var matched_count: usize = 0;
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
            const table = self.resolveStableRouteTable(table_arg) orelse {
                result.unresolved = true;
                continue;
            };
            const route_object = self.ir_view.getObject(table) orelse {
                result.unresolved = true;
                continue;
            };
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
                const raw_key = self.propertyKey(property.key) orelse {
                    result.unresolved = true;
                    continue;
                };
                const found = parseRouteKey(raw_key) orelse {
                    result.unresolved = true;
                    continue;
                };
                if (!std.ascii.eqlIgnoreCase(wanted.method, found.method) or
                    !std.mem.eql(u8, wanted.path, found.path)) continue;

                matched_count += 1;
                const function = self.resolveInitialFunctionNode(property.value) orelse {
                    result.unresolved = true;
                    continue;
                };
                try result.appendUnique(allocator, function);
            }
            if (self.routerMatchResultIsUnstable(idx)) result.unresolved = true;
        }
        if (matched_count != 1 or result.functions.items.len != 1) result.unresolved = true;
        return result;
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
            const target = self.assignmentRootBinding(assignment.target) orelse continue;
            if (packBindingKey(target.scope_id, target.slot) != key) continue;
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
            const target = self.assignmentRootBinding(assignment.target) orelse continue;
            if (packBindingKey(target.scope_id, target.slot) != key) continue;
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
            const target = self.assignmentRootBinding(assignment.target) orelse continue;
            if (packBindingKey(target.scope_id, target.slot) != key) continue;
            const function = self.resolveInitialFunctionNode(assignment.value) orelse continue;
            try result.appendUnique(allocator, function);
        }
    }

    fn isRouterMatchCallee(self: *const Resolver, callee: NodeIndex) bool {
        if (self.ir_view.getTag(callee) != .identifier) return false;
        const binding = self.ir_view.getBinding(callee) orelse return false;
        for (self.facts.imports.items) |record| {
            if (record.slot != binding.slot or record.resolution != .builtin) continue;
            return std.mem.eql(u8, record.module_specifier, "zttp:router") and
                std.mem.eql(u8, record.imported_name, "routerMatch");
        }
        return false;
    }

    fn propertyKey(self: *const Resolver, node: NodeIndex) ?[]const u8 {
        const tag = self.ir_view.getTag(node) orelse return null;
        return switch (tag) {
            .lit_string => blk: {
                const string_idx = self.ir_view.getStringIdx(node) orelse break :blk null;
                break :blk self.ir_view.getString(string_idx);
            },
            .identifier => blk: {
                const binding = self.ir_view.getBinding(node) orelse break :blk null;
                break :blk self.resolveAtomName(binding.name_atom);
            },
            // exhaustive: other expressions are not static route keys; the caller marks the route unresolved.
            else => null,
        };
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

    fn bindingIsMutated(self: *const Resolver, binding: ir.BindingRef) bool {
        const key = packBindingKey(binding.scope_id, binding.slot);
        for (0..self.ir_view.nodeCount()) |idx_usize| {
            const idx: NodeIndex = @intCast(idx_usize);
            if (self.ir_view.getTag(idx) != .assignment) continue;
            const assignment = self.ir_view.getAssignment(idx) orelse return true;
            const root = self.assignmentRootBinding(assignment.target) orelse continue;
            if (packBindingKey(root.scope_id, root.slot) == key) return true;
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

    fn bindingEscapesStableResolutionDepth(
        self: *const Resolver,
        binding: ir.BindingRef,
        allow_router_match: bool,
        depth: u8,
    ) bool {
        if (depth >= max_resolution_depth) return true;
        const key = packBindingKey(binding.scope_id, binding.slot);
        for (0..self.ir_view.nodeCount()) |idx_usize| {
            const idx: NodeIndex = @intCast(idx_usize);
            const tag = self.ir_view.getTag(idx) orelse continue;
            switch (tag) {
                .var_decl => {
                    const declaration = self.ir_view.getVarDecl(idx) orelse return true;
                    if (declaration.init == null_node) continue;
                    if (packBindingKey(declaration.binding.scope_id, declaration.binding.slot) == key) continue;
                    if (self.nodeContainsBinding(declaration.init, key, 0)) return true;
                },
                .assignment => {
                    const assignment = self.ir_view.getAssignment(idx) orelse return true;
                    if (self.nodeContainsBinding(assignment.value, key, 0)) return true;
                },
                .call, .method_call => {
                    const call = self.ir_view.getCall(idx) orelse return true;
                    for (0..call.args_count) |argument_index| {
                        const argument = self.ir_view.getListIndex(call.args_start, @intCast(argument_index));
                        if (!self.nodeContainsBinding(argument, key, 0)) continue;
                        if (allow_router_match and argument_index == 0 and
                            self.isRouterMatchCallee(call.callee) and
                            self.nodeIsBinding(argument, key)) continue;
                        if (self.nodeIsBinding(argument, key) and
                            self.callKeepsArgumentLocal(call, argument_index, depth + 1)) continue;
                        return true;
                    }
                },
                .return_stmt => {
                    const value = self.ir_view.getOptValue(idx) orelse continue;
                    if (self.nodeContainsBinding(value, key, 0)) return true;
                },
                // exhaustive: all other nodes cannot themselves store, pass,
                // or return the binding. Their enclosing expression is read
                // by one of the cases above.
                else => {},
            }
        }
        return false;
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
            const receiver = self.assignmentRootBinding(nested_call.callee) orelse continue;
            if (packBindingKey(receiver.scope_id, receiver.slot) == key) return false;
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

    fn nodeContainsBinding(self: *const Resolver, node: NodeIndex, key: u32, depth: usize) bool {
        if (node == null_node) return false;
        // Expression edges point to nodes that already exist, so this walk is
        // acyclic. Use the parsed node count as the structural bound. The
        // route-resolution depth bounds alias chains and must not make a deep
        // object literal look as if it contains every binding.
        if (depth >= self.ir_view.nodeCount()) return true;
        const tag = self.ir_view.getTag(node) orelse return true;
        if (tag == .identifier) return self.nodeIsBinding(node, key);
        return switch (tag) {
            .member_access, .optional_chain, .computed_access => blk: {
                const member = self.ir_view.getMember(node) orelse break :blk true;
                if (self.nodeIsBinding(member.object, key)) break :blk false;
                break :blk self.nodeContainsBinding(member.object, key, depth + 1);
            },
            .array_literal => blk: {
                const array = self.ir_view.getArray(node) orelse break :blk true;
                for (0..array.elements_count) |index| {
                    const element = self.ir_view.getListIndex(array.elements_start, @intCast(index));
                    if (self.nodeContainsBinding(element, key, depth + 1)) break :blk true;
                }
                break :blk false;
            },
            .object_literal => blk: {
                const literal = self.ir_view.getObject(node) orelse break :blk true;
                for (0..literal.properties_count) |index| {
                    const property = self.ir_view.getListIndex(literal.properties_start, @intCast(index));
                    if (self.nodeContainsBinding(property, key, depth + 1)) break :blk true;
                }
                break :blk false;
            },
            .object_property => blk: {
                const property = self.ir_view.getProperty(node) orelse break :blk true;
                break :blk self.nodeContainsBinding(property.value, key, depth + 1);
            },
            .spread, .object_spread => blk: {
                const value = self.ir_view.getOptValue(node) orelse break :blk true;
                break :blk self.nodeContainsBinding(value, key, depth + 1);
            },
            .ternary => blk: {
                const ternary = self.ir_view.getTernary(node) orelse break :blk true;
                break :blk self.nodeContainsBinding(ternary.condition, key, depth + 1) or
                    self.nodeContainsBinding(ternary.then_branch, key, depth + 1) or
                    self.nodeContainsBinding(ternary.else_branch, key, depth + 1);
            },
            .binary_op => blk: {
                const binary = self.ir_view.getBinary(node) orelse break :blk true;
                break :blk self.nodeContainsBinding(binary.left, key, depth + 1) or
                    self.nodeContainsBinding(binary.right, key, depth + 1);
            },
            .unary_op => blk: {
                const unary = self.ir_view.getUnary(node) orelse break :blk true;
                break :blk self.nodeContainsBinding(unary.operand, key, depth + 1);
            },
            .match_expr => blk: {
                const match_expr = self.ir_view.getMatchExpr(node) orelse break :blk true;
                for (0..match_expr.arms_count) |index| {
                    const arm_node = self.ir_view.getListIndex(match_expr.arms_start, @intCast(index));
                    const arm = self.ir_view.getMatchArm(arm_node) orelse break :blk true;
                    if (self.nodeContainsBinding(arm.body, key, depth + 1)) break :blk true;
                }
                break :blk false;
            },
            // exhaustive: leaves and statement-only nodes cannot contain a
            // value reference below this expression walk.
            else => false,
        };
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

    fn assignmentRootBinding(self: *const Resolver, target: NodeIndex) ?ir.BindingRef {
        var node = target;
        while (true) {
            const tag = self.ir_view.getTag(node) orelse return null;
            switch (tag) {
                .identifier => return self.ir_view.getBinding(node),
                .member_access, .optional_chain, .computed_access => {
                    const member = self.ir_view.getMember(node) orelse return null;
                    node = member.object;
                },
                // exhaustive: no other assignment target shape has a root
                // binding that this resolver can track.
                else => return null,
            }
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
            const atom: object.Atom = @enumFromInt(atom_idx);
            if (atom.toPredefinedName()) |name| return name;
            return table.getName(atom);
        }
        if (self.ir_view.getString(atom_idx)) |name| return name;
        const atom: object.Atom = @enumFromInt(atom_idx);
        return atom.toPredefinedName();
    }

    fn computedPropertyName(self: *const Resolver, node: NodeIndex) ?[]const u8 {
        if (node == null_node or self.ir_view.getTag(node) != .lit_string) return null;
        const string_idx = self.ir_view.getStringIdx(node) orelse return null;
        return self.ir_view.getString(string_idx);
    }
};

const ParsedRouteKey = struct {
    method: []const u8,
    path: []const u8,
};

fn parseRouteKey(raw: []const u8) ?ParsedRouteKey {
    const separator = std.mem.indexOfScalar(u8, raw, ' ') orelse return null;
    if (separator == 0 or separator + 1 >= raw.len) return null;
    const path = raw[separator + 1 ..];
    if (path.len == 0 or path[0] != '/') return null;
    return .{ .method = raw[0..separator], .path = path };
}
