//! Validation and transparent lowering for compiler-owned intrinsics.

const std = @import("std");
const engine = @import("zts-engine");
const builtin_modules = engine.builtin_modules;
const module_facts_mod = @import("module_facts.zig");
const import_signatures_mod = @import("import_signatures.zig");
const type_checker_mod = @import("type_checker.zig");
const type_env_mod = @import("type_env.zig");
const type_pool_mod = @import("type_pool.zig");

const JsParser = engine.parser.JsParser;
const IrView = engine.parser.IrView;
const Node = engine.parser.Node;
const NodeIndex = engine.parser.NodeIndex;
const null_node = engine.parser.null_node;
const TypeEnv = type_env_mod.TypeEnv;
const ModuleFacts = module_facts_mod.ModuleFacts;

const PatternContext = enum { top, record, array };

const Descriptor = enum {
    any,
    present,
    boolean,
    number,
    string,
    array,
    dict,
    bytes,
};

const PendingMatchArm = struct {
    call: NodeIndex,
    pattern: NodeIndex,
    callback: NodeIndex,
    receiver: NodeIndex,
};

fn atomName(atoms: *engine.atom_table.AtomTable, atom: u16) ?[]const u8 {
    const value: engine.object.Atom = @fromBackingInt(@intCast(atom));
    return value.toPredefinedName() orelse atoms.getName(value);
}

fn importedIntrinsicKind(
    view: IrView,
    facts: *const ModuleFacts,
    node: NodeIndex,
) ?engine.module_binding.IntrinsicKind {
    if (view.getTag(node) != .identifier) return null;
    const binding = view.getBinding(node) orelse return null;
    const imported = facts.importForReference(binding, .module_reference, .builtin) orelse return null;
    const intrinsic = builtin_modules.findIntrinsic(
        imported.module_specifier,
        imported.imported_name,
    ) orelse return null;
    return intrinsic.kind;
}

fn isNamePath(view: IrView, node: NodeIndex) bool {
    var current = node;
    while (true) switch (view.getTag(current) orelse return false) {
        .identifier => return true,
        .member_access => current = (view.getMember(current) orelse return false).object,
        else => return false,
    };
}

fn callbackIsSupported(view: IrView, node: NodeIndex) bool {
    if (view.getTag(node) != .arrow_function) return false;
    const callback = view.getFunction(node) orelse return false;
    if (callback.params_count > 1) return false;
    if (callback.params_count == 0) return true;
    const param = view.getListIndex(callback.params_start, 0);
    if (view.getTag(param) != .pattern_element) return false;
    const element = view.getPatternElem(param) orelse return false;
    return element.kind == .simple and
        element.key == null_node and
        element.default_value == null_node;
}

fn markIntrinsicReferences(
    view: IrView,
    facts: *const ModuleFacts,
    handled: []bool,
    node: NodeIndex,
    depth: usize,
) void {
    if (depth > handled.len or node >= handled.len) return;
    if (view.getTag(node) == .identifier and importedIntrinsicKind(view, facts, node) != null) {
        handled[node] = true;
    }
    var children = view.expressionChildren(node);
    while (children.next()) |child| {
        markIntrinsicReferences(view, facts, handled, child, depth + 1);
    }
}

fn retireMatchChainForDiagnostics(
    parser: *JsParser,
    view: IrView,
    owner: NodeIndex,
    base: NodeIndex,
    base_call: Node.CallExpr,
    arms: []const PendingMatchArm,
) !void {
    if (base_call.args_count != 1) return;
    const subject = view.getListIndex(base_call.args_start, 0);
    try parser.nodes.lowerCallToTransparent(base, subject);
    for (arms) |pending| {
        if (view.getTag(pending.call) == .call) {
            try parser.nodes.lowerCallToTransparent(pending.call, pending.receiver);
        }
    }
    if (view.getTag(owner) == .call) try parser.nodes.lowerCallToTransparent(owner, subject);
}

fn descriptorAt(
    view: IrView,
    atoms: *engine.atom_table.AtomTable,
    facts: *const ModuleFacts,
    handled: []bool,
    node: NodeIndex,
) ?Descriptor {
    if (view.getTag(node) != .member_access) return null;
    const member = view.getMember(node) orelse return null;
    if (view.getTag(member.object) != .identifier) return null;
    if (importedIntrinsicKind(view, facts, member.object) != .pattern_namespace) return null;
    if (member.object < handled.len) handled[member.object] = true;
    const name = atomName(atoms, member.property) orelse return null;
    inline for (std.enums.values(Descriptor)) |descriptor| {
        const source_name = switch (descriptor) {
            .dict => "Dict",
            .bytes => "Bytes",
            else => @tagName(descriptor),
        };
        if (std.mem.eql(u8, name, source_name)) return descriptor;
    }
    return null;
}

fn addGlobalReference(
    parser: *JsParser,
    atoms: *engine.atom_table.AtomTable,
    loc: engine.parser.SourceLocation,
    name: []const u8,
) !NodeIndex {
    const atom = try atoms.intern(name);
    const atom_index: u16 = @truncate(@backingInt(atom));
    return parser.nodes.addIdentifier(loc, .{
        .scope_id = 0,
        .slot = atom_index,
        .name_atom = atom_index,
        .kind = .undeclared_global,
    });
}

fn addTypeTestPredicate(
    parser: *JsParser,
    atoms: *engine.atom_table.AtomTable,
    loc: engine.parser.SourceLocation,
    subject: NodeIndex,
    kind: Node.TypeTestKind,
) !NodeIndex {
    switch (kind) {
        .boolean, .number, .string => {
            const typeof_node = try parser.nodes.addUnary(loc, .{ .op = .typeof_op, .operand = subject });
            const string_index = try parser.constants.addString(@tagName(kind));
            const literal = try parser.nodes.addString(loc, string_index);
            return parser.nodes.addBinary(loc, .{ .op = .strict_eq, .left = typeof_node, .right = literal });
        },
        .array => {
            const array_ref = try addGlobalReference(parser, atoms, loc, "Array");
            const method = try atoms.intern("isArray");
            const callee = try parser.nodes.addMember(.member_access, loc, .{
                .object = array_ref,
                .property = @truncate(@backingInt(method)),
                .computed = null_node,
                .is_optional = false,
            });
            const args = try parser.nodes.addIndexList(&.{subject});
            return parser.nodes.addCall(.call, loc, .{ .callee = callee, .args_start = args, .args_count = 1 });
        },
        .dict, .bytes => {
            const callee = try addGlobalReference(
                parser,
                atoms,
                loc,
                if (kind == .dict) "isDict" else "isBytes",
            );
            const args = try parser.nodes.addIndexList(&.{subject});
            return parser.nodes.addCall(.call, loc, .{ .callee = callee, .args_start = args, .args_count = 1 });
        },
    }
}

fn lowerPattern(
    parser: *JsParser,
    atoms: *engine.atom_table.AtomTable,
    facts: *const ModuleFacts,
    handled: []bool,
    subject: NodeIndex,
    node: NodeIndex,
    context: PatternContext,
    depth: usize,
) !NodeIndex {
    if (depth > handled.len) return error.InvalidMatchPattern;
    const view = IrView.fromIRStore(&parser.nodes, &parser.constants);
    if (descriptorAt(view, atoms, facts, handled, node)) |descriptor| {
        return switch (descriptor) {
            .any => if (context == .array) null_node else error.InvalidMatchPattern,
            .present => if (context == .record) null_node else error.InvalidMatchPattern,
            .boolean, .number, .string, .array, .dict, .bytes => if (context != .top)
                error.InvalidMatchPattern
            else blk: {
                const kind: Node.TypeTestKind = switch (descriptor) {
                    .boolean => .boolean,
                    .number => .number,
                    .string => .string,
                    .array => .array,
                    .dict => .dict,
                    .bytes => .bytes,
                    .any, .present => unreachable,
                };
                const loc = view.getLoc(node) orelse return error.InvalidMatchPattern;
                const predicate = try addTypeTestPredicate(parser, atoms, loc, subject, kind);
                break :blk try parser.nodes.addMatchTypeTest(loc, .{ .kind = kind, .predicate = predicate });
            },
        };
    }
    const tag = view.getTag(node) orelse return error.InvalidMatchPattern;
    switch (tag) {
        .lit_int, .lit_float, .lit_string, .lit_bool, .lit_null, .lit_undefined => return node,
        .object_literal => {
            const object = view.getObject(node) orelse return error.InvalidMatchPattern;
            if (object.properties_count > std.math.maxInt(u8)) return error.InvalidMatchPattern;
            var properties: [std.math.maxInt(u8)]NodeIndex = undefined;
            for (0..object.properties_count) |index| {
                const property_node = view.getListIndex(object.properties_start, @intCast(index));
                if (view.getTag(property_node) != .object_property) return error.InvalidMatchPattern;
                const property = view.getProperty(property_node) orelse return error.InvalidMatchPattern;
                const value = try lowerPattern(
                    parser,
                    atoms,
                    facts,
                    handled,
                    subject,
                    property.value,
                    .record,
                    depth + 1,
                );
                const loc = view.getLoc(property_node) orelse return error.InvalidMatchPattern;
                properties[index] = try parser.nodes.addProperty(loc, .{
                    .key = property.key,
                    .value = value,
                    .is_shorthand = false,
                });
            }
            const start = if (object.properties_count == 0)
                null_node
            else
                try parser.nodes.addIndexList(properties[0..object.properties_count]);
            const loc = view.getLoc(node) orelse return error.InvalidMatchPattern;
            return parser.nodes.addMatchPattern(loc, .{
                .props_start = start,
                .props_count = @intCast(object.properties_count),
            });
        },
        .array_literal => {
            const array = view.getArray(node) orelse return error.InvalidMatchPattern;
            if (array.has_spread or array.elements_count > std.math.maxInt(u8)) return error.InvalidMatchPattern;
            const elements = try parser.nodes.allocator.alloc(NodeIndex, array.elements_count);
            defer parser.nodes.allocator.free(elements);
            for (0..array.elements_count) |index| {
                elements[index] = try lowerPattern(
                    parser,
                    atoms,
                    facts,
                    handled,
                    subject,
                    view.getListIndex(array.elements_start, @intCast(index)),
                    .array,
                    depth + 1,
                );
            }
            const start = try parser.nodes.addIndexList(elements);
            const loc = view.getLoc(node) orelse return error.InvalidMatchPattern;
            return parser.nodes.addArray(.array_pattern, loc, .{
                .elements_start = start,
                .elements_count = array.elements_count,
                .has_spread = false,
            });
        },
        else => return error.InvalidMatchPattern,
    }
}

pub const ValidationIssue = union(enum) {
    value_argument_count: struct { node: engine.parser.NodeIndex, got: usize },
    type_argument_count: struct {
        node: engine.parser.NodeIndex,
        expected: usize,
        got: usize,
    },
    target_constraint: struct {
        node: engine.parser.NodeIndex,
        target: type_pool_mod.TypeIndex,
    },
    base_mismatch: struct {
        node: engine.parser.NodeIndex,
        operand: engine.parser.NodeIndex,
        nominal: type_pool_mod.TypeIndex,
    },
    unsupported_reference: struct { node: engine.parser.NodeIndex },
};

pub const ValidationIssues = std.ArrayListUnmanaged(ValidationIssue);

pub fn validateSource(
    allocator: std.mem.Allocator,
    parser: *JsParser,
    atoms: *engine.atom_table.AtomTable,
    env: *TypeEnv,
) !void {
    try validateSourceWithImports(allocator, parser, atoms, env, null);
}

pub fn validateSourceWithImports(
    allocator: std.mem.Allocator,
    parser: *JsParser,
    atoms: *engine.atom_table.AtomTable,
    env: *TypeEnv,
    file_imports: ?*const import_signatures_mod.FileImportSignatures,
) !void {
    try validateSourceInternal(allocator, parser, atoms, env, file_imports, null);
}

pub fn validateSourceForAnalysis(
    allocator: std.mem.Allocator,
    parser: *JsParser,
    atoms: *engine.atom_table.AtomTable,
    env: *TypeEnv,
    file_imports: ?*const import_signatures_mod.FileImportSignatures,
    issues: *ValidationIssues,
) !void {
    try validateSourceInternal(allocator, parser, atoms, env, file_imports, issues);
}

fn validateSourceInternal(
    allocator: std.mem.Allocator,
    parser: *JsParser,
    atoms: *engine.atom_table.AtomTable,
    env: *TypeEnv,
    file_imports: ?*const import_signatures_mod.FileImportSignatures,
    issues: ?*ValidationIssues,
) !void {
    var facts = try ModuleFacts.build(
        allocator,
        IrView.fromIRStore(&parser.nodes, &parser.constants),
        atoms,
        null,
    );
    defer facts.deinit();
    try validateAndLowerNominalConstructorsInternal(
        allocator,
        parser,
        atoms,
        env,
        &facts,
        file_imports,
        issues,
    );
}

pub fn validateAndLowerNominalConstructorsForAnalysis(
    allocator: std.mem.Allocator,
    parser: *JsParser,
    atoms: *engine.atom_table.AtomTable,
    env: *TypeEnv,
    facts: *const ModuleFacts,
    file_imports: ?*const import_signatures_mod.FileImportSignatures,
    issues: *ValidationIssues,
) !void {
    try validateAndLowerNominalConstructorsInternal(
        allocator,
        parser,
        atoms,
        env,
        facts,
        file_imports,
        issues,
    );
}

fn validateAndLowerNominalConstructorsInternal(
    allocator: std.mem.Allocator,
    parser: *JsParser,
    atoms: *engine.atom_table.AtomTable,
    env: *TypeEnv,
    facts: *const ModuleFacts,
    file_imports: ?*const import_signatures_mod.FileImportSignatures,
    issues: ?*ValidationIssues,
) !void {
    if (parser.type_store.intrinsics_validated) return;
    const original_node_count = parser.nodes.tags.items.len;
    const initial_issue_count = if (issues) |out| out.items.len else 0;
    const checkpoint = parser.type_store.checkpoint();
    errdefer parser.type_store.rollback(checkpoint);
    const handled = try allocator.alloc(bool, original_node_count);
    defer allocator.free(handled);
    @memset(handled, false);
    var checker = type_checker_mod.TypeChecker.init(
        allocator,
        IrView.fromIRStore(&parser.nodes, &parser.constants),
        atoms,
        env,
    );
    defer checker.deinit();
    if (file_imports) |imports| try checker.prepareFileImports(imports);

    for (0..original_node_count) |raw_statement| {
        const statement: engine.parser.NodeIndex = @intCast(raw_statement);
        const view = IrView.fromIRStore(&parser.nodes, &parser.constants);
        if (view.getTag(statement) != .expr_stmt) continue;
        const owner = view.getOptValue(statement) orelse continue;
        if (view.getTag(owner) != .call) continue;
        const call = view.getCall(owner) orelse continue;
        if (view.getTag(call.callee) != .identifier) continue;
        const binding = view.getBinding(call.callee) orelse continue;
        const imported = facts.importForReference(binding, .module_reference, .builtin) orelse continue;
        const intrinsic = builtin_modules.findIntrinsic(
            imported.module_specifier,
            imported.imported_name,
        ) orelse continue;
        if (intrinsic.kind != .assert) continue;
        handled[call.callee] = true;
        if (call.args_count != 1) {
            if (issues) |out| {
                try out.append(allocator, .{ .value_argument_count = .{
                    .node = owner,
                    .got = call.args_count,
                } });
                continue;
            }
            return error.InvalidAssertionCall;
        }
        if (env.getCallTypeArgsForCall(view, owner)) |type_arguments| {
            if (type_arguments.count != 0) {
                if (issues) |out| {
                    try out.append(allocator, .{ .type_argument_count = .{
                        .node = owner,
                        .expected = 0,
                        .got = type_arguments.count,
                    } });
                    continue;
                }
                return error.InvalidAssertionCall;
            }
        }
        const condition = view.getListIndex(call.args_start, 0);
        try parser.nodes.lowerCallStatementToAssert(statement, owner, condition);
    }

    for (0..original_node_count) |raw_owner| {
        const owner: NodeIndex = @intCast(raw_owner);
        const view = IrView.fromIRStore(&parser.nodes, &parser.constants);
        if (view.getTag(owner) != .call) continue;
        const terminal_call = view.getCall(owner) orelse continue;
        if (view.getTag(terminal_call.callee) != .member_access) continue;
        const terminal_member = view.getMember(terminal_call.callee) orelse continue;
        const terminal_name = atomName(atoms, terminal_member.property) orelse continue;
        const is_exhaustive = std.mem.eql(u8, terminal_name, "exhaustive");
        const is_otherwise = std.mem.eql(u8, terminal_name, "otherwise");
        if (!is_exhaustive and !is_otherwise) continue;

        var reversed: [std.math.maxInt(u8)]PendingMatchArm = undefined;
        var arm_count: usize = 0;
        var cursor = terminal_member.object;
        var chain_shape_valid = true;
        while (view.getTag(cursor) == .call) {
            const with_call = view.getCall(cursor) orelse {
                chain_shape_valid = false;
                break;
            };
            if (view.getTag(with_call.callee) != .member_access) break;
            const with_member = view.getMember(with_call.callee) orelse {
                chain_shape_valid = false;
                break;
            };
            const with_name = atomName(atoms, with_member.property) orelse break;
            if (!std.mem.eql(u8, with_name, "with")) break;
            if (arm_count == reversed.len) {
                chain_shape_valid = false;
                break;
            }
            reversed[arm_count] = .{
                .call = cursor,
                .pattern = if (with_call.args_count > 0)
                    view.getListIndex(with_call.args_start, 0)
                else
                    null_node,
                .callback = if (with_call.args_count > 1)
                    view.getListIndex(with_call.args_start, 1)
                else
                    null_node,
                .receiver = with_member.object,
            };
            arm_count += 1;
            cursor = with_member.object;
        }

        if (view.getTag(cursor) != .call) continue;
        const base_call = view.getCall(cursor) orelse continue;
        if (view.getTag(base_call.callee) != .identifier) continue;
        if (importedIntrinsicKind(view, facts, base_call.callee) != .match) continue;
        handled[base_call.callee] = true;

        var valid = chain_shape_valid;
        valid = valid and base_call.args_count == 1;
        valid = valid and (if (env.getCallTypeArgsForCall(view, cursor)) |args| args.count == 0 else true);
        valid = valid and isNamePath(
            view,
            if (base_call.args_count == 1) view.getListIndex(base_call.args_start, 0) else null_node,
        );
        valid = valid and (if (env.getCallTypeArgsForCall(view, owner)) |args| args.count == 0 else true);
        valid = valid and if (is_exhaustive)
            terminal_call.args_count == 0 and arm_count != 0
        else
            terminal_call.args_count == 1 and callbackIsSupported(
                view,
                if (terminal_call.args_count == 1)
                    view.getListIndex(terminal_call.args_start, 0)
                else
                    null_node,
            );
        if (is_otherwise and arm_count == reversed.len) valid = false;
        for (reversed[0..arm_count]) |pending| {
            const pending_call = view.getCall(pending.call) orelse {
                valid = false;
                continue;
            };
            valid = valid and pending_call.args_count == 2;
            valid = valid and callbackIsSupported(view, pending.callback);
            valid = valid and (if (env.getCallTypeArgsForCall(view, pending.call)) |args| args.count == 0 else true);
        }
        if (!valid) {
            if (issues) |out| {
                for (reversed[0..arm_count]) |pending| {
                    markIntrinsicReferences(view, facts, handled, pending.pattern, 0);
                }
                try out.append(allocator, .{ .unsupported_reference = .{ .node = owner } });
                try retireMatchChainForDiagnostics(parser, view, owner, cursor, base_call, reversed[0..arm_count]);
                continue;
            }
            return error.InvalidMatchIntrinsic;
        }

        const subject = view.getListIndex(base_call.args_start, 0);
        const lowered_count = arm_count + @intFromBool(is_otherwise);
        var lowered_arms: [std.math.maxInt(u8)]NodeIndex = undefined;
        for (0..arm_count) |forward_index| {
            const pending = reversed[arm_count - forward_index - 1];
            const pattern = lowerPattern(
                parser,
                atoms,
                facts,
                handled,
                subject,
                pending.pattern,
                .top,
                0,
            ) catch |err| switch (err) {
                error.InvalidMatchPattern => {
                    if (issues) |out| {
                        try out.append(allocator, .{ .unsupported_reference = .{ .node = pending.pattern } });
                        valid = false;
                        break;
                    }
                    return error.InvalidMatchPattern;
                },
                else => return err,
            };
            const loc = view.getLoc(pending.call) orelse return error.InvalidMatchIntrinsic;
            lowered_arms[forward_index] = try parser.nodes.addMatchArm(loc, .{
                .pattern = pattern,
                .body = pending.callback,
                .kind = .callback,
            });
        }
        if (!valid) {
            try retireMatchChainForDiagnostics(parser, view, owner, cursor, base_call, reversed[0..arm_count]);
            continue;
        }
        if (is_otherwise) {
            const callback = view.getListIndex(terminal_call.args_start, 0);
            const loc = view.getLoc(owner) orelse return error.InvalidMatchIntrinsic;
            lowered_arms[arm_count] = try parser.nodes.addMatchArm(loc, .{
                .pattern = null_node,
                .body = callback,
                .kind = .callback,
            });
        }
        const arms_start = try parser.nodes.addIndexList(lowered_arms[0..lowered_count]);
        try parser.nodes.lowerCallToTransparent(cursor, subject);
        for (reversed[0..arm_count]) |pending| {
            try parser.nodes.lowerCallToTransparent(pending.call, pending.receiver);
        }
        try parser.nodes.lowerCallToMatch(owner, .{
            .discriminant = subject,
            .arms_start = arms_start,
            .arms_count = @intCast(lowered_count),
        });
    }

    for (0..original_node_count) |raw_owner| {
        const owner: engine.parser.NodeIndex = @intCast(raw_owner);
        const view = IrView.fromIRStore(&parser.nodes, &parser.constants);
        if (view.getTag(owner) != .call) continue;
        const call = view.getCall(owner) orelse continue;
        if (view.getTag(call.callee) != .identifier) continue;
        const binding = view.getBinding(call.callee) orelse continue;
        const imported = facts.importForReference(binding, .module_reference, .builtin) orelse continue;
        const intrinsic = builtin_modules.findIntrinsic(
            imported.module_specifier,
            imported.imported_name,
        ) orelse continue;
        if (intrinsic.kind != .nominal) continue;
        if (call.args_count != 1) {
            if (issues) |out| {
                try out.append(allocator, .{ .value_argument_count = .{
                    .node = owner,
                    .got = call.args_count,
                } });
                handled[call.callee] = true;
                continue;
            }
            return error.InvalidNominalConstructor;
        }
        const type_arguments = env.getCallTypeArgsForCall(view, owner) orelse {
            if (issues) |out| {
                try out.append(allocator, .{ .type_argument_count = .{
                    .node = owner,
                    .expected = 1,
                    .got = 0,
                } });
                handled[call.callee] = true;
                continue;
            }
            return error.InvalidNominalConstructor;
        };
        if (type_arguments.count != 1) {
            if (issues) |out| {
                try out.append(allocator, .{ .type_argument_count = .{
                    .node = owner,
                    .expected = 1,
                    .got = type_arguments.count,
                } });
                handled[call.callee] = true;
                continue;
            }
            return error.InvalidNominalConstructor;
        }
        const nominal = env.resolveRef(type_arguments.args[0]);
        if (!env.pool.isNominal(nominal) or
            env.pool.nominalConstruction(nominal) != .explicit_only)
        {
            if (issues) |out| {
                try out.append(allocator, .{ .target_constraint = .{
                    .node = owner,
                    .target = nominal,
                } });
                handled[call.callee] = true;
                continue;
            }
            return error.InvalidNominalConstructor;
        }
        const operand = view.getListIndex(call.args_start, 0);
        const inferred = checker.inferTypeWithoutDiagnostics(operand);
        const base = env.pool.unwrapNominal(nominal);
        if (base == nominal or env.pool.isNominal(inferred) or !env.isAssignableTo(inferred, base)) {
            if (issues) |out| {
                try out.append(allocator, .{ .base_mismatch = .{
                    .node = owner,
                    .operand = operand,
                    .nominal = nominal,
                } });
            } else {
                return error.InvalidNominalConstructorBase;
            }
        }
        try env.recordNominalConstructor(owner, nominal);
        try parser.type_store.nominal_constructors.append(
            parser.type_store.allocator,
            .{ .owner = owner, .operand = operand },
        );
        handled[call.callee] = true;
        try parser.nodes.lowerCallToTransparent(owner, operand);
    }
    const view = IrView.fromIRStore(&parser.nodes, &parser.constants);
    for (0..original_node_count) |raw| {
        const node: engine.parser.NodeIndex = @intCast(raw);
        if (view.getTag(node) != .identifier) continue;
        const binding = view.getBinding(node) orelse continue;
        const imported = facts.importForReference(binding, .module_reference, .builtin) orelse continue;
        if (builtin_modules.findIntrinsic(imported.module_specifier, imported.imported_name) == null) continue;
        if (handled[node]) continue;
        if (issues) |out| {
            try out.append(allocator, .{ .unsupported_reference = .{ .node = node } });
            continue;
        }
        return error.UnsupportedIntrinsicReference;
    }
    parser.type_store.intrinsics_validated = if (issues) |out|
        out.items.len == initial_issue_count
    else
        true;
}

test "a foreign match-like chain is not a compiler intrinsic" {
    const allocator = std.testing.allocator;
    const source =
        "import { select } from \"./foreign.ts\";\n" ++
        "const value = select().otherwise();\n";
    var atoms = engine.atom_table.AtomTable.init(allocator);
    defer atoms.deinit();
    var parser = try JsParser.initAdmission(allocator, allocator, source, .compile);
    defer parser.deinit();
    parser.setAtomTable(&atoms);
    _ = try parser.parse();
    var pool = type_pool_mod.TypePool.init(allocator);
    defer pool.deinit(allocator);
    var env = TypeEnv.init(allocator, &pool);
    defer env.deinit();
    try env.populateSourceTypes(.{ .direct = .{
        .store = &parser.type_store,
        .ir_view = IrView.fromIRStore(&parser.nodes, &parser.constants),
        .atoms = &atoms,
        .module_path = "/app/main.ts",
    } });
    try validateSource(allocator, &parser, &atoms, &env);
}

test "a retained nominal constructor keeps its type in a fresh analysis" {
    const allocator = std.testing.allocator;
    const source =
        "import type { Nominal as N } from \"zttp:core\";\n" ++
        "import { nominal as make } from \"zttp:core\";\n" ++
        "declare const idBrand: unique symbol;\n" ++
        "type Id = N<string, typeof idBrand>;\n" ++
        "function identity<T>(value: T): T { return value; }\n" ++
        "const id = make<Id>(identity<string>(\"x\"));\n";
    var atoms = engine.atom_table.AtomTable.init(allocator);
    defer atoms.deinit();
    var parser = try JsParser.initAdmission(allocator, allocator, source, .compile);
    defer parser.deinit();
    parser.setAtomTable(&atoms);
    _ = try parser.parse();

    var first_pool = type_pool_mod.TypePool.init(allocator);
    defer first_pool.deinit(allocator);
    var first_env = TypeEnv.init(allocator, &first_pool);
    defer first_env.deinit();
    try first_env.populateSourceTypes(.{ .direct = .{
        .store = &parser.type_store,
        .ir_view = IrView.fromIRStore(&parser.nodes, &parser.constants),
        .atoms = &atoms,
        .module_path = "/app/id.ts",
    } });
    try validateSource(allocator, &parser, &atoms, &first_env);

    var second_pool = type_pool_mod.TypePool.init(allocator);
    defer second_pool.deinit(allocator);
    var second_env = TypeEnv.init(allocator, &second_pool);
    defer second_env.deinit();
    const lowered_view = IrView.fromIRStore(&parser.nodes, &parser.constants);
    try second_env.populateSourceTypes(.{ .direct = .{
        .store = &parser.type_store,
        .ir_view = lowered_view,
        .atoms = &atoms,
        .module_path = "/app/id.ts",
    } });
    var wrapper: ?engine.parser.NodeIndex = null;
    for (0..lowered_view.nodeCount()) |raw| {
        const node: engine.parser.NodeIndex = @intCast(raw);
        const unary = lowered_view.getUnary(node) orelse continue;
        if (unary.op == .transparent) wrapper = node;
    }
    var checker = type_checker_mod.TypeChecker.init(allocator, lowered_view, &atoms, &second_env);
    defer checker.deinit();
    const retained = checker.inferTypeWithoutDiagnostics(wrapper orelse return error.TestUnexpectedResult);
    try std.testing.expect(second_pool.isNominal(retained));
    try std.testing.expectEqualStrings("Id", second_pool.nominalName(retained));
    const origin = second_pool.nominalOrigin(retained) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("/app/id.ts", origin.module_path);
}

test "a refused nominal constructor cannot generate bytecode after analysis" {
    const allocator = std.testing.allocator;
    const source =
        \\import type { Nominal } from "zttp:core";
        \\import { nominal } from "zttp:core";
        \\declare const idBrand: unique symbol;
        \\type Id = Nominal<string, typeof idBrand>;
        \\const id: Id = nominal<Id>(1);
    ;
    var atoms = engine.atom_table.AtomTable.init(allocator);
    defer atoms.deinit();
    var strings = engine.string.StringTable.init(allocator);
    defer strings.deinit();
    var parser = try engine.parser.Parser.initTyped(allocator, allocator, source, &strings, &atoms);
    defer parser.deinit();
    try std.testing.expect((try parser.parseTypedIr()) == .accepted);
    var pool = type_pool_mod.TypePool.init(allocator);
    defer pool.deinit(allocator);
    var env = TypeEnv.init(allocator, &pool);
    defer env.deinit();
    try env.populateSourceTypes(.{ .direct = .{
        .store = &parser.js_parser.type_store,
        .ir_view = IrView.fromIRStore(&parser.js_parser.nodes, &parser.js_parser.constants),
        .atoms = &atoms,
        .module_path = "/app/refused-id.ts",
    } });
    var issues: ValidationIssues = .empty;
    defer issues.deinit(allocator);
    try validateSourceForAnalysis(allocator, &parser.js_parser, &atoms, &env, null, &issues);
    try std.testing.expectError(error.UnvalidatedIntrinsicSource, parser.generateParsed(allocator));
}
