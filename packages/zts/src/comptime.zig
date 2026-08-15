//! Compile-Time Expression Evaluator
//!
//! Evaluates comptime(<expr>) expressions during TypeScript stripping.
//! Evaluates the canonical parser IR through a closed, deterministic allowlist.
//!
//! Supported:
//! - Literals: number, string, boolean, null, undefined, NaN, Infinity
//! - Unary: + - ! ~
//! - Binary: + - * / % ** | & ^ << >> >>> == != === !== < <= > >= && || ??
//! - Ternary: cond ? a : b
//! - Grouping: (expr)
//! - Arrays: [1, 2, 3]
//! - Objects: { a: 1, b: 2 }
//! - Math: Math.PI, Math.abs(), etc.
//!
//! Disallowed:
//! - Variables (except whitelisted globals)
//! - Function calls (except whitelisted)
//! - new, this, eval, assignments, loops

const std = @import("std");
const AtomTable = @import("atom_table.zig").AtomTable;
const parser = @import("parser/root.zig");
// Shared ECMAScript ToInt32 so compile-time bitwise folding matches the
// interpreter and never hits the `@intFromFloat` out-of-range panic.
const floatToInt32 = @import("interpreter/util.zig").floatToInt32;
// Shared UTF-16 code-unit indexing so compile-time string length/index/slice
// match the runtime builtins on non-ASCII strings (string stores UTF-8 but JS
// indexes by UTF-16 code units).
const string = @import("string.zig");

// ============================================================================
// Error Types
// ============================================================================

pub const ComptimeError = error{
    UnsupportedOp,
    UnknownIdentifier,
    CallNotAllowed,
    SyntaxError,
    DepthExceeded,
    ExpressionTooLong,
    TypeMismatch,
    UnclosedString,
    UnclosedParen,
    UnclosedBracket,
    UnclosedBrace,
    UnexpectedToken,
    UnexpectedEnd,
    OutOfMemory,
    InvalidNumber,
    InvalidEscape,
};

// ============================================================================
// Value Type
// ============================================================================

pub const ComptimeValue = union(enum) {
    number: f64,
    string: []const u8,
    boolean: bool,
    null_val: void,
    undefined_val: void,
    nan_val: void,
    infinity: Infinity,
    array: []const ComptimeValue,
    object: []const ObjectProperty,

    pub const Infinity = struct { negative: bool };

    pub const ObjectProperty = struct {
        key: []const u8,
        value: ComptimeValue,
    };

    /// Convert to f64 for numeric operations
    pub fn toNumber(self: ComptimeValue) ?f64 {
        return switch (self) {
            .number => |n| n,
            .boolean => |b| if (b) 1.0 else 0.0,
            .null_val => 0.0,
            .undefined_val => std.math.nan(f64),
            .nan_val => std.math.nan(f64),
            .infinity => |i| if (i.negative) -std.math.inf(f64) else std.math.inf(f64),
            .string => |s| std.fmt.parseFloat(f64, s) catch null,
            .array, .object => null,
        };
    }

    /// Convert to boolean for logical operations (JS truthiness)
    pub fn toBool(self: ComptimeValue) bool {
        return switch (self) {
            .boolean => |b| b,
            .number => |n| n != 0.0 and !std.math.isNan(n),
            .string => |s| s.len > 0,
            .null_val, .undefined_val => false,
            .nan_val => false,
            .infinity => true,
            .array, .object => true,
        };
    }

    /// Check if value is nullish (null or undefined)
    pub fn isNullish(self: ComptimeValue) bool {
        return switch (self) {
            .null_val, .undefined_val => true,
            else => false,
        };
    }

    /// Strict equality (===)
    pub fn strictEquals(self: ComptimeValue, other: ComptimeValue) bool {
        const self_tag = @intFromEnum(self);
        const other_tag = @intFromEnum(other);
        if (self_tag != other_tag) return false;

        return switch (self) {
            .number => |n| {
                const o = other.number;
                // NaN !== NaN
                if (std.math.isNan(n) or std.math.isNan(o)) return false;
                return n == o;
            },
            .string => |s| std.mem.eql(u8, s, other.string),
            .boolean => |b| b == other.boolean,
            .null_val, .undefined_val => true,
            .nan_val => false, // NaN !== NaN
            .infinity => |i| i.negative == other.infinity.negative,
            .array, .object => false, // Reference equality not supported
        };
    }

    /// Loose equality (==)
    pub fn looseEquals(self: ComptimeValue, other: ComptimeValue) bool {
        // Same type: use strict
        const self_tag = @intFromEnum(self);
        const other_tag = @intFromEnum(other);
        if (self_tag == other_tag) return self.strictEquals(other);

        // null == undefined
        if (self.isNullish() and other.isNullish()) return true;

        // Number comparisons
        const self_num = self.toNumber();
        const other_num = other.toNumber();
        if (self_num != null and other_num != null) {
            const sn = self_num.?;
            const on = other_num.?;
            if (std.math.isNan(sn) or std.math.isNan(on)) return false;
            return sn == on;
        }

        return false;
    }

    /// Free all allocated memory in this value
    pub fn deinit(self: ComptimeValue, allocator: std.mem.Allocator) void {
        switch (self) {
            .string => |s| allocator.free(s),
            .array => |arr| {
                for (arr) |elem| {
                    elem.deinit(allocator);
                }
                allocator.free(arr);
            },
            .object => |props| {
                for (props) |prop| {
                    allocator.free(prop.key);
                    prop.value.deinit(allocator);
                }
                allocator.free(props);
            },
            else => {},
        }
    }
};

// ============================================================================
// Evaluator
// ============================================================================

pub const ComptimeEvaluator = struct {
    source: []const u8,
    allocator: std.mem.Allocator,

    // Performance guards
    max_depth: u16 = 64,
    current_depth: u16 = 0,
    max_expr_len: usize = 8192,

    // Environment for Env.* lookups
    env: ?*const std.StringHashMap([]const u8) = null,

    // Build metadata
    build_time: ?[]const u8 = null,
    git_commit: ?[]const u8 = null,
    version: ?[]const u8 = null,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, source: []const u8) Self {
        return .{
            .source = source,
            .allocator = allocator,
        };
    }

    /// Main entry point: evaluate the expression
    pub fn evaluate(self: *Self) ComptimeError!ComptimeValue {
        if (self.source.len > self.max_expr_len) {
            return ComptimeError.ExpressionTooLong;
        }

        return self.evaluateExpression(.complete);
    }

    const ExpressionExtent = enum {
        complete,
        root_prefix,
    };

    fn evaluateExpression(self: *Self, extent: ExpressionExtent) ComptimeError!ComptimeValue {
        if (extent == .root_prefix) try self.validateLegacyJsonRoot();

        var atoms = AtomTable.init(self.allocator);
        defer atoms.deinit();

        var expression_parser = parser.JsParser.initExpression(
            self.allocator,
            self.source,
            .comptime_expression,
        ) catch |err| return mapParserInitError(err);
        defer expression_parser.deinit();
        expression_parser.setAtomTable(&atoms);

        const root = switch (extent) {
            .complete => expression_parser.parseExpressionOnly(),
            .root_prefix => expression_parser.parseExpressionPrefix(),
        } catch |err| {
            return self.mapParserError(&expression_parser, err);
        };
        const ir = parser.IrView.fromIRStore(&expression_parser.nodes, &expression_parser.constants);
        return self.evalNode(ir, &atoms, root);
    }

    fn validateLegacyJsonRoot(self: *const Self) ComptimeError!void {
        const source = std.mem.trimStart(u8, self.source, " \t\n\r");
        if (source.len == 0) return ComptimeError.UnexpectedEnd;
        switch (source[0]) {
            '"', '[', '{', 't', 'f', 'n', '0'...'9' => {},
            '-' => {
                if (source.len < 2 or
                    (!isDigit(source[1]) and
                        !(source[1] == '.' and source.len >= 3 and isDigit(source[2]))))
                {
                    return ComptimeError.InvalidNumber;
                }
            },
            else => return ComptimeError.SyntaxError,
        }
    }

    fn evalNode(self: *Self, ir: parser.IrView, atoms: *AtomTable, node_idx: parser.NodeIndex) ComptimeError!ComptimeValue {
        self.current_depth += 1;
        defer self.current_depth -= 1;
        if (self.current_depth > self.max_depth) return ComptimeError.DepthExceeded;

        const tag = ir.getTag(node_idx) orelse return ComptimeError.SyntaxError;
        return switch (tag) {
            .lit_int => .{ .number = @floatFromInt(ir.getIntValue(node_idx) orelse return ComptimeError.SyntaxError) },
            .lit_float => .{ .number = ir.getFloat(ir.getFloatIdx(node_idx) orelse return ComptimeError.SyntaxError) orelse return ComptimeError.SyntaxError },
            .lit_string => blk: {
                const value = ir.getString(ir.getStringIdx(node_idx) orelse return ComptimeError.SyntaxError) orelse return ComptimeError.SyntaxError;
                break :blk .{ .string = self.allocator.dupe(u8, value) catch return ComptimeError.OutOfMemory };
            },
            .lit_bool => .{ .boolean = ir.getBoolValue(node_idx) orelse return ComptimeError.SyntaxError },
            .lit_null => .{ .null_val = {} },
            .lit_undefined => .{ .undefined_val = {} },

            .identifier => self.evalIdentifier(ir, atoms, node_idx),
            .binary_op => self.evalBinary(ir, atoms, node_idx),
            .unary_op => self.evalUnary(ir, atoms, node_idx),
            .ternary => self.evalTernary(ir, atoms, node_idx),
            .call => self.evalCall(ir, atoms, node_idx),
            .member_access => self.evalMember(ir, atoms, node_idx),
            .array_literal => self.evalArray(ir, atoms, node_idx),
            .object_literal => self.evalObject(ir, atoms, node_idx),

            .method_call,
            .computed_access,
            .optional_chain,
            .optional_call,
            .object_property,
            .object_method,
            .object_getter,
            .object_setter,
            .object_spread,
            .function_expr,
            .template_part_string,
            .template_part_expr,
            .spread,
            .await_expr,
            .yield_expr,
            .sequence_expr,
            .comma_expr,
            .match_expr,
            .match_arm,
            .match_pattern,
            .match_type_test,
            .expr_stmt,
            .var_decl,
            .if_stmt,
            .for_stmt,
            .for_of_stmt,
            .for_in_stmt,
            .while_stmt,
            .do_while_stmt,
            .switch_stmt,
            .case_clause,
            .return_stmt,
            .assert_stmt,
            .throw_stmt,
            .break_stmt,
            .continue_stmt,
            .try_stmt,
            .block,
            .empty_stmt,
            .labeled_stmt,
            .debugger_stmt,
            .function_decl,
            .array_pattern,
            .object_pattern,
            .pattern_element,
            .pattern_rest,
            .pattern_default,
            .import_decl,
            .import_specifier,
            .import_default,
            .import_namespace,
            .export_decl,
            .export_specifier,
            .export_default,
            .export_all,
            .program,
            .param_list,
            .arg_list,
            .stmt_list,
            => ComptimeError.UnsupportedOp,
            .assignment, .arrow_function => ComptimeError.UnexpectedToken,
            .template_literal => ComptimeError.UnsupportedOp,
        };
    }

    fn evalIdentifier(self: *Self, ir: parser.IrView, atoms: *AtomTable, node_idx: parser.NodeIndex) ComptimeError!ComptimeValue {
        const binding = ir.getBinding(node_idx) orelse return ComptimeError.SyntaxError;
        const name = atomName(atoms, binding.name_atom) orelse return ComptimeError.UnknownIdentifier;

        if (std.mem.eql(u8, name, "NaN")) return .{ .nan_val = {} };
        if (std.mem.eql(u8, name, "Infinity")) return .{ .infinity = .{ .negative = false } };
        if (std.mem.eql(u8, name, "__BUILD_TIME__")) return self.cloneOptionalString(self.build_time);
        if (std.mem.eql(u8, name, "__GIT_COMMIT__")) return self.cloneOptionalString(self.git_commit);
        if (std.mem.eql(u8, name, "__VERSION__")) return self.cloneOptionalString(self.version);
        return ComptimeError.UnknownIdentifier;
    }

    fn cloneOptionalString(self: *Self, value: ?[]const u8) ComptimeError!ComptimeValue {
        const bytes = value orelse return .{ .undefined_val = {} };
        return .{ .string = self.allocator.dupe(u8, bytes) catch return ComptimeError.OutOfMemory };
    }

    fn evalBinary(self: *Self, ir: parser.IrView, atoms: *AtomTable, node_idx: parser.NodeIndex) ComptimeError!ComptimeValue {
        const binary = ir.getBinary(node_idx) orelse return ComptimeError.SyntaxError;
        const left = try self.evalNode(ir, atoms, binary.left);
        var left_owned = true;
        errdefer if (left_owned) left.deinit(self.allocator);
        const right = try self.evalNode(ir, atoms, binary.right);
        var right_owned = true;
        errdefer if (right_owned) right.deinit(self.allocator);

        switch (binary.op) {
            .and_op => {
                if (!left.toBool()) {
                    right.deinit(self.allocator);
                    right_owned = false;
                    left_owned = false;
                    return left;
                }
                left.deinit(self.allocator);
                left_owned = false;
                right_owned = false;
                return right;
            },
            .or_op => {
                if (left.toBool()) {
                    right.deinit(self.allocator);
                    right_owned = false;
                    left_owned = false;
                    return left;
                }
                left.deinit(self.allocator);
                left_owned = false;
                right_owned = false;
                return right;
            },
            .nullish => {
                if (left.isNullish()) {
                    left.deinit(self.allocator);
                    left_owned = false;
                    right_owned = false;
                    return right;
                }
                right.deinit(self.allocator);
                right_owned = false;
                left_owned = false;
                return left;
            },
            else => {},
        }

        defer left.deinit(self.allocator);
        left_owned = false;
        defer right.deinit(self.allocator);
        right_owned = false;
        return switch (binary.op) {
            .add => self.add(left, right),
            .sub => self.subtract(left, right),
            .mul => self.multiply(left, right),
            .div => self.divide(left, right),
            .mod => self.modulo(left, right),
            .pow => blk: {
                const lhs = left.toNumber() orelse return ComptimeError.TypeMismatch;
                const rhs = right.toNumber() orelse return ComptimeError.TypeMismatch;
                break :blk .{ .number = std.math.pow(f64, lhs, rhs) };
            },
            .strict_eq => .{ .boolean = left.strictEquals(right) },
            .strict_neq => .{ .boolean = !left.strictEquals(right) },
            .loose_eq => .{ .boolean = left.looseEquals(right) },
            .loose_neq => .{ .boolean = !left.looseEquals(right) },
            .lt, .lte, .gt, .gte => self.compare(left, right, binary.op),
            .bit_and => self.bitwiseAnd(left, right),
            .bit_or => self.bitwiseOr(left, right),
            .bit_xor => self.bitwiseXor(left, right),
            .shl => self.bitwiseShift(left, right, .left),
            .shr => self.bitwiseShift(left, right, .right),
            .ushr => self.bitwiseShift(left, right, .unsigned_right),
            .in_op => ComptimeError.UnsupportedOp,
            .and_op, .or_op, .nullish => unreachable,
        };
    }

    fn compare(self: *Self, left: ComptimeValue, right: ComptimeValue, op: parser.BinaryOp) ComptimeError!ComptimeValue {
        _ = self;
        const lhs = left.toNumber() orelse return ComptimeError.TypeMismatch;
        const rhs = right.toNumber() orelse return ComptimeError.TypeMismatch;
        return .{ .boolean = switch (op) {
            .lt => lhs < rhs,
            .lte => lhs <= rhs,
            .gt => lhs > rhs,
            .gte => lhs >= rhs,
            else => unreachable,
        } };
    }

    fn evalUnary(self: *Self, ir: parser.IrView, atoms: *AtomTable, node_idx: parser.NodeIndex) ComptimeError!ComptimeValue {
        const unary = ir.getUnary(node_idx) orelse return ComptimeError.SyntaxError;
        const operand = try self.evalNode(ir, atoms, unary.operand);
        defer operand.deinit(self.allocator);
        return switch (unary.op) {
            .not => .{ .boolean = !operand.toBool() },
            .bit_not => blk: {
                const number = operand.toNumber() orelse return ComptimeError.TypeMismatch;
                if (std.math.isNan(number) or std.math.isInf(number)) break :blk .{ .number = -1 };
                break :blk .{ .number = @floatFromInt(~floatToInt32(number)) };
            },
            .neg => .{ .number = -(operand.toNumber() orelse return ComptimeError.TypeMismatch) },
            .pos => .{ .number = operand.toNumber() orelse return ComptimeError.TypeMismatch },
            .typeof_op => ComptimeError.UnsupportedOp,
        };
    }

    fn evalTernary(self: *Self, ir: parser.IrView, atoms: *AtomTable, node_idx: parser.NodeIndex) ComptimeError!ComptimeValue {
        const ternary = ir.getTernary(node_idx) orelse return ComptimeError.SyntaxError;
        const condition = try self.evalNode(ir, atoms, ternary.condition);
        defer condition.deinit(self.allocator);
        const then_value = try self.evalNode(ir, atoms, ternary.then_branch);
        var then_owned = true;
        errdefer if (then_owned) then_value.deinit(self.allocator);
        const else_value = try self.evalNode(ir, atoms, ternary.else_branch);
        if (condition.toBool()) {
            else_value.deinit(self.allocator);
            then_owned = false;
            return then_value;
        }
        then_value.deinit(self.allocator);
        then_owned = false;
        return else_value;
    }

    fn evalArray(self: *Self, ir: parser.IrView, atoms: *AtomTable, node_idx: parser.NodeIndex) ComptimeError!ComptimeValue {
        const array = ir.getArray(node_idx) orelse return ComptimeError.SyntaxError;
        if (array.has_spread) return ComptimeError.UnsupportedOp;
        const values = self.allocator.alloc(ComptimeValue, array.elements_count) catch return ComptimeError.OutOfMemory;
        var initialized: usize = 0;
        errdefer {
            for (values[0..initialized]) |value| value.deinit(self.allocator);
            self.allocator.free(values);
        }
        while (initialized < values.len) : (initialized += 1) {
            const child = ir.getListIndex(array.elements_start, @intCast(initialized));
            values[initialized] = try self.evalNode(ir, atoms, child);
        }
        return .{ .array = values };
    }

    fn evalObject(self: *Self, ir: parser.IrView, atoms: *AtomTable, node_idx: parser.NodeIndex) ComptimeError!ComptimeValue {
        const object_literal = ir.getObject(node_idx) orelse return ComptimeError.SyntaxError;
        const properties = self.allocator.alloc(ComptimeValue.ObjectProperty, object_literal.properties_count) catch return ComptimeError.OutOfMemory;
        var initialized: usize = 0;
        errdefer {
            for (properties[0..initialized]) |property| {
                self.allocator.free(property.key);
                property.value.deinit(self.allocator);
            }
            self.allocator.free(properties);
        }
        while (initialized < properties.len) : (initialized += 1) {
            const property_idx = ir.getListIndex(object_literal.properties_start, @intCast(initialized));
            if (ir.getTag(property_idx) != .object_property) return ComptimeError.UnsupportedOp;
            const property = ir.getProperty(property_idx) orelse return ComptimeError.SyntaxError;
            if (property.is_computed or property.is_shorthand) return ComptimeError.SyntaxError;
            if (ir.getTag(property.key) != .lit_string) return ComptimeError.SyntaxError;
            const key_idx = ir.getStringIdx(property.key) orelse return ComptimeError.SyntaxError;
            const key = ir.getString(key_idx) orelse return ComptimeError.SyntaxError;
            const owned_key = self.allocator.dupe(u8, key) catch return ComptimeError.OutOfMemory;
            errdefer self.allocator.free(owned_key);
            const value = try self.evalNode(ir, atoms, property.value);
            properties[initialized] = .{ .key = owned_key, .value = value };
        }
        return .{ .object = properties };
    }

    fn evalMember(self: *Self, ir: parser.IrView, atoms: *AtomTable, node_idx: parser.NodeIndex) ComptimeError!ComptimeValue {
        const member = ir.getMember(node_idx) orelse return ComptimeError.SyntaxError;
        if (member.is_optional or member.computed != parser.null_node) return ComptimeError.UnsupportedOp;
        const property = atomName(atoms, member.property) orelse return ComptimeError.SyntaxError;

        // `Math` and `Env` are namespaces, not values: the property decides the
        // result and the receiver is never evaluated. Every other identifier
        // receiver falls through and is evaluated as a value, so a build-metadata
        // identifier keeps its string members. `evalIdentifier` still answers
        // `UnknownIdentifier` for a receiver that names nothing.
        if (identifierName(ir, atoms, member.object)) |base| {
            if (std.mem.eql(u8, base, "Math")) return mathConstant(property) orelse ComptimeError.UnknownIdentifier;
            if (std.mem.eql(u8, base, "Env")) return self.envValue(property);
        }

        const object_value = try self.evalNode(ir, atoms, member.object);
        defer object_value.deinit(self.allocator);
        return switch (object_value) {
            .string => |value| if (std.mem.eql(u8, property, "length"))
                .{ .number = @floatFromInt(string.utf16Length(value)) }
            else
                ComptimeError.UnknownIdentifier,
            .array => |value| if (std.mem.eql(u8, property, "length"))
                .{ .number = @floatFromInt(value.len) }
            else
                ComptimeError.UnknownIdentifier,
            else => ComptimeError.UnsupportedOp,
        };
    }

    fn evalCall(self: *Self, ir: parser.IrView, atoms: *AtomTable, node_idx: parser.NodeIndex) ComptimeError!ComptimeValue {
        const call = ir.getCall(node_idx) orelse return ComptimeError.SyntaxError;
        if (call.is_optional) return ComptimeError.UnsupportedOp;
        const callee_tag = ir.getTag(call.callee) orelse return ComptimeError.SyntaxError;

        if (callee_tag == .identifier) {
            const name = identifierName(ir, atoms, call.callee) orelse return ComptimeError.UnknownIdentifier;
            // A closed set, and `dictFromEntries` is deliberately not in it.
            //
            // Spec 6.2 names `comptime(dictFromEntries([...]))` as the static-
            // table construction form, whose duplicate-key check is discharged
            // at build time. It does not land, and the reason is not that the
            // evaluator cannot reach a module export - that would be a small
            // addition here. It is that this channel's output is source text:
            // `evaluate` produces a `ComptimeValue`, `emitLiteral` writes it
            // back into the program, and the stripper splices the result. A
            // `Dict` has no source literal to write. Spec 6.2 says so itself -
            // construction is a module call - so a `ComptimeValue.dict` case
            // could only be emitted as `dictFromEntries([...])`, which is the
            // expression it started from.
            //
            // Giving `Dict` a literal syntax would add an IR node against a
            // spec that says it has none. Making `comptime` yield a runtime
            // value rather than text is a different mechanism from this one.
            // Either is a decision of its own, not a task-7-sized addition, so
            // the runtime `dictFromEntries` covers the same programs at a
            // runtime check and the spec form fails the build loudly - the
            // stripper turns the error below into
            // `StripError.ComptimeEvaluationFailed`, which is pinned by a test.
            if (!std.mem.eql(u8, name, "hash") and
                !std.mem.eql(u8, name, "parseInt") and
                !std.mem.eql(u8, name, "parseFloat"))
            {
                return ComptimeError.UnknownIdentifier;
            }
            const args = try self.evalArguments(ir, atoms, call);
            defer self.freeArgs(args);
            if (std.mem.eql(u8, name, "hash")) return self.evaluateHash(args);
            if (std.mem.eql(u8, name, "parseInt")) return evaluateParseInt(args);
            return evaluateParseFloat(args);
        }

        if (callee_tag != .member_access) return ComptimeError.CallNotAllowed;
        const member = ir.getMember(call.callee) orelse return ComptimeError.SyntaxError;
        if (member.is_optional or member.computed != parser.null_node) return ComptimeError.UnsupportedOp;
        const method = atomName(atoms, member.property) orelse return ComptimeError.SyntaxError;

        if (identifierName(ir, atoms, member.object)) |base| {
            if (std.mem.eql(u8, base, "Math")) {
                if (std.mem.eql(u8, method, "random")) return ComptimeError.CallNotAllowed;
                const args = try self.evalArguments(ir, atoms, call);
                defer self.freeArgs(args);
                return self.evaluateMathCall(method, args);
            }
            if (std.mem.eql(u8, base, "JSON")) {
                if (!std.mem.eql(u8, method, "parse")) return ComptimeError.CallNotAllowed;
                const args = try self.evalArguments(ir, atoms, call);
                defer self.freeArgs(args);
                return self.evaluateJsonParse(args);
            }
            // Any other identifier receiver is a value, not a namespace: fall
            // through so its string methods resolve. See `evalMember`.
        }

        const receiver = try self.evalNode(ir, atoms, member.object);
        defer receiver.deinit(self.allocator);
        const args = try self.evalArguments(ir, atoms, call);
        defer self.freeArgs(args);
        return switch (receiver) {
            .string => |value| self.evaluateStringCall(value, method, args),
            else => ComptimeError.UnsupportedOp,
        };
    }

    fn evalArguments(self: *Self, ir: parser.IrView, atoms: *AtomTable, call: parser.Node.CallExpr) ComptimeError![]const ComptimeValue {
        const args = self.allocator.alloc(ComptimeValue, call.args_count) catch return ComptimeError.OutOfMemory;
        var initialized: usize = 0;
        errdefer {
            for (args[0..initialized]) |arg| arg.deinit(self.allocator);
            self.allocator.free(args);
        }
        while (initialized < args.len) : (initialized += 1) {
            const arg_idx = ir.getListIndex(call.args_start, @intCast(initialized));
            if (ir.getTag(arg_idx) == .spread) return ComptimeError.UnsupportedOp;
            args[initialized] = try self.evalNode(ir, atoms, arg_idx);
        }
        return args;
    }

    fn evaluateHash(self: *Self, args: []const ComptimeValue) ComptimeError!ComptimeValue {
        if (args.len < 1) return ComptimeError.SyntaxError;
        const input = switch (args[0]) {
            .string => |value| value,
            else => return ComptimeError.TypeMismatch,
        };
        var buf: [8]u8 = undefined;
        _ = std.fmt.bufPrint(&buf, "{x:0>8}", .{fnv1a(input)}) catch return ComptimeError.OutOfMemory;
        return .{ .string = self.allocator.dupe(u8, &buf) catch return ComptimeError.OutOfMemory };
    }

    fn evaluateParseInt(args: []const ComptimeValue) ComptimeValue {
        if (args.len < 1) return .{ .nan_val = {} };
        return switch (args[0]) {
            .string => |value| blk: {
                const radix: u8 = if (args.len >= 2)
                    std.math.lossyCast(u8, @trunc(args[1].toNumber() orelse 10))
                else
                    10;
                const trimmed = std.mem.trim(u8, value, " \t\n\r");
                const parsed = std.fmt.parseInt(i64, trimmed, radix) catch break :blk .{ .nan_val = {} };
                break :blk .{ .number = @floatFromInt(parsed) };
            },
            .number => |value| .{ .number = @trunc(value) },
            else => .{ .nan_val = {} },
        };
    }

    fn evaluateParseFloat(args: []const ComptimeValue) ComptimeValue {
        if (args.len < 1) return .{ .nan_val = {} };
        return switch (args[0]) {
            .string => |value| blk: {
                const trimmed = std.mem.trim(u8, value, " \t\n\r");
                const parsed = std.fmt.parseFloat(f64, trimmed) catch break :blk .{ .nan_val = {} };
                break :blk .{ .number = parsed };
            },
            .number => |value| .{ .number = value },
            else => .{ .nan_val = {} },
        };
    }

    fn evaluateJsonParse(self: *Self, args: []const ComptimeValue) ComptimeError!ComptimeValue {
        if (args.len < 1) return ComptimeError.SyntaxError;
        const bytes = switch (args[0]) {
            .string => |value| value,
            else => return ComptimeError.TypeMismatch,
        };
        var value_evaluator = Self.init(self.allocator, bytes);
        return value_evaluator.evaluateExpression(.root_prefix);
    }

    fn envValue(self: *Self, name: []const u8) ComptimeError!ComptimeValue {
        const value = if (self.env) |map| map.get(name) else null;
        return self.cloneOptionalString(value);
    }

    fn evaluateStringCall(self: *Self, str: []const u8, name: []const u8, args: []const ComptimeValue) ComptimeError!ComptimeValue {
        if (std.mem.eql(u8, name, "toUpperCase")) return self.stringToUpperCase(str);
        if (std.mem.eql(u8, name, "toLowerCase")) return self.stringToLowerCase(str);
        if (std.mem.eql(u8, name, "trim")) return self.stringTrim(str);
        if (std.mem.eql(u8, name, "trimStart") or std.mem.eql(u8, name, "trimLeft")) return self.stringTrimStart(str);
        if (std.mem.eql(u8, name, "trimEnd") or std.mem.eql(u8, name, "trimRight")) return self.stringTrimEnd(str);

        if (std.mem.eql(u8, name, "slice") or std.mem.eql(u8, name, "substring")) return self.stringSlice(str, args);
        if (std.mem.eql(u8, name, "padStart")) return self.stringPadStart(str, args);
        if (std.mem.eql(u8, name, "padEnd")) return self.stringPadEnd(str, args);

        if (args.len >= 1) {
            if (std.mem.eql(u8, name, "includes") or std.mem.eql(u8, name, "startsWith") or
                std.mem.eql(u8, name, "endsWith") or std.mem.eql(u8, name, "indexOf"))
            {
                const search = switch (args[0]) {
                    .string => |value| value,
                    else => return ComptimeError.TypeMismatch,
                };
                if (std.mem.eql(u8, name, "includes")) return .{ .boolean = std.mem.indexOf(u8, str, search) != null };
                if (std.mem.eql(u8, name, "startsWith")) return .{ .boolean = std.mem.startsWith(u8, str, search) };
                if (std.mem.eql(u8, name, "endsWith")) return .{ .boolean = std.mem.endsWith(u8, str, search) };
                const index = std.mem.indexOf(u8, str, search) orelse return .{ .number = -1 };
                return .{ .number = @floatFromInt(string.byteOffsetToUtf16Index(str, index)) };
            }
            if (std.mem.eql(u8, name, "repeat")) {
                const count = args[0].toNumber() orelse return ComptimeError.TypeMismatch;
                if (!std.math.isFinite(count) or count < 0 or count > 10000) return ComptimeError.TypeMismatch;
                var result: std.ArrayList(u8) = .empty;
                errdefer result.deinit(self.allocator);
                for (0..std.math.lossyCast(usize, @trunc(count))) |_| {
                    result.appendSlice(self.allocator, str) catch return ComptimeError.OutOfMemory;
                }
                return .{ .string = result.toOwnedSlice(self.allocator) catch return ComptimeError.OutOfMemory };
            }
            if (std.mem.eql(u8, name, "split")) {
                const delimiter = switch (args[0]) {
                    .string => |value| value,
                    else => return ComptimeError.TypeMismatch,
                };
                return self.stringSplit(str, delimiter);
            }
            if (std.mem.eql(u8, name, "charAt")) {
                const index_value = args[0].toNumber() orelse return ComptimeError.TypeMismatch;
                const index = charAtIndex(index_value);
                const codepoint = if (index) |valid_index|
                    if (valid_index <= std.math.maxInt(u32)) string.charCodepointSliceAt(str, @intCast(valid_index)) else null
                else
                    null;
                return .{ .string = self.allocator.dupe(u8, codepoint orelse "") catch return ComptimeError.OutOfMemory };
            }
        }

        if (std.mem.eql(u8, name, "replace") or std.mem.eql(u8, name, "replaceAll")) {
            if (args.len < 2) return ComptimeError.SyntaxError;
            const search = switch (args[0]) {
                .string => |value| value,
                else => return ComptimeError.TypeMismatch,
            };
            const replacement = switch (args[1]) {
                .string => |value| value,
                else => return ComptimeError.TypeMismatch,
            };
            return self.stringReplace(str, search, replacement, std.mem.eql(u8, name, "replaceAll"));
        }
        return ComptimeError.CallNotAllowed;
    }

    fn charAtIndex(value: f64) ?usize {
        if (std.math.isNan(value) or value == 0) return 0;
        if (!std.math.isFinite(value) or value < 0) return null;
        return std.math.lossyCast(usize, @trunc(value));
    }

    fn identifierName(ir: parser.IrView, atoms: *AtomTable, node_idx: parser.NodeIndex) ?[]const u8 {
        if (ir.getTag(node_idx) != .identifier) return null;
        const binding = ir.getBinding(node_idx) orelse return null;
        return atomName(atoms, binding.name_atom);
    }

    fn atomName(atoms: *AtomTable, atom: u16) ?[]const u8 {
        return atoms.getName(@enumFromInt(@as(u32, atom)));
    }

    fn mathConstant(name: []const u8) ?ComptimeValue {
        if (std.mem.eql(u8, name, "PI")) return .{ .number = 3.141592653589793 };
        if (std.mem.eql(u8, name, "E")) return .{ .number = 2.718281828459045 };
        if (std.mem.eql(u8, name, "LN2")) return .{ .number = 0.6931471805599453 };
        if (std.mem.eql(u8, name, "LN10")) return .{ .number = 2.302585092994046 };
        if (std.mem.eql(u8, name, "LOG2E")) return .{ .number = 1.4426950408889634 };
        if (std.mem.eql(u8, name, "LOG10E")) return .{ .number = 0.4342944819032518 };
        if (std.mem.eql(u8, name, "SQRT2")) return .{ .number = 1.4142135623730951 };
        if (std.mem.eql(u8, name, "SQRT1_2")) return .{ .number = 0.7071067811865476 };
        return null;
    }

    fn mapParserInitError(err: anyerror) ComptimeError {
        return switch (err) {
            error.OutOfMemory => ComptimeError.OutOfMemory,
            else => ComptimeError.SyntaxError,
        };
    }

    fn mapParserError(self: *const Self, expression_parser: *const parser.JsParser, err: anyerror) ComptimeError {
        if (err == error.OutOfMemory or expression_parser.errors.outOfMemory()) return ComptimeError.OutOfMemory;
        const errors = expression_parser.getErrors();
        if (errors.len == 0) return if (self.source.len == 0) ComptimeError.UnexpectedEnd else ComptimeError.UnexpectedToken;

        const parse_error = errors[0];
        const trimmed_source = std.mem.trimStart(u8, self.source, " \t\n\r");
        const starts_with_word = trimmed_source.len > 0 and std.ascii.isAlphabetic(trimmed_source[0]);
        return switch (parse_error.kind) {
            .nesting_too_deep => ComptimeError.DepthExceeded,
            .unterminated_string, .unterminated_template => ComptimeError.UnclosedString,
            .invalid_number => ComptimeError.InvalidNumber,
            .invalid_escape_sequence, .invalid_unicode_escape => ComptimeError.InvalidEscape,
            .unexpected_eof => ComptimeError.UnexpectedEnd,
            .unsupported_feature => ComptimeError.UnsupportedOp,
            .expected_expression => if (starts_with_word)
                ComptimeError.UnknownIdentifier
            else
                ComptimeError.UnexpectedToken,
            .unexpected_token => if (starts_with_word)
                ComptimeError.UnknownIdentifier
            else
                ComptimeError.UnexpectedToken,
            .expected_token => blk: {
                const expected = parse_error.expected orelse break :blk ComptimeError.SyntaxError;
                if (std.mem.eql(u8, expected, "end of expression")) break :blk ComptimeError.UnexpectedToken;
                if (parse_error.token_text == null) {
                    if (std.mem.eql(u8, expected, "')'")) break :blk ComptimeError.UnclosedParen;
                    if (std.mem.eql(u8, expected, "']'")) break :blk ComptimeError.UnclosedBracket;
                    if (std.mem.eql(u8, expected, "'}'")) break :blk ComptimeError.UnclosedBrace;
                }
                break :blk ComptimeError.SyntaxError;
            },
            else => ComptimeError.UnexpectedToken,
        };
    }

    fn evaluateMathCall(self: *Self, name: []const u8, args: []const ComptimeValue) ComptimeError!ComptimeValue {
        _ = self;
        // Single-argument functions
        if (args.len >= 1) {
            const n = args[0].toNumber() orelse return ComptimeError.TypeMismatch;

            if (std.mem.eql(u8, name, "abs")) return .{ .number = @abs(n) };
            if (std.mem.eql(u8, name, "floor")) return .{ .number = @floor(n) };
            if (std.mem.eql(u8, name, "ceil")) return .{ .number = @ceil(n) };
            if (std.mem.eql(u8, name, "round")) return .{ .number = @round(n) };
            if (std.mem.eql(u8, name, "trunc")) return .{ .number = @trunc(n) };
            if (std.mem.eql(u8, name, "sqrt")) {
                if (n < 0) return .{ .nan_val = {} };
                return .{ .number = @sqrt(n) };
            }
            if (std.mem.eql(u8, name, "cbrt")) return .{ .number = std.math.cbrt(n) };
            if (std.mem.eql(u8, name, "sin")) return .{ .number = @sin(n) };
            if (std.mem.eql(u8, name, "cos")) return .{ .number = @cos(n) };
            if (std.mem.eql(u8, name, "tan")) return .{ .number = @tan(n) };
            if (std.mem.eql(u8, name, "asin")) return .{ .number = std.math.asin(n) };
            if (std.mem.eql(u8, name, "acos")) return .{ .number = std.math.acos(n) };
            if (std.mem.eql(u8, name, "atan")) return .{ .number = std.math.atan(n) };
            if (std.mem.eql(u8, name, "sinh")) return .{ .number = std.math.sinh(n) };
            if (std.mem.eql(u8, name, "cosh")) return .{ .number = std.math.cosh(n) };
            if (std.mem.eql(u8, name, "tanh")) return .{ .number = std.math.tanh(n) };
            if (std.mem.eql(u8, name, "asinh")) return .{ .number = std.math.asinh(n) };
            if (std.mem.eql(u8, name, "acosh")) return .{ .number = std.math.acosh(n) };
            if (std.mem.eql(u8, name, "atanh")) return .{ .number = std.math.atanh(n) };
            if (std.mem.eql(u8, name, "log")) return .{ .number = @log(n) };
            if (std.mem.eql(u8, name, "log2")) return .{ .number = std.math.log2(n) };
            if (std.mem.eql(u8, name, "log10")) return .{ .number = std.math.log10(n) };
            if (std.mem.eql(u8, name, "log1p")) return .{ .number = std.math.log1p(n) };
            if (std.mem.eql(u8, name, "exp")) return .{ .number = @exp(n) };
            if (std.mem.eql(u8, name, "expm1")) return .{ .number = std.math.expm1(n) };
            if (std.mem.eql(u8, name, "sign")) {
                if (std.math.isNan(n)) return .{ .nan_val = {} };
                if (n > 0) return .{ .number = 1 };
                if (n < 0) return .{ .number = -1 };
                return .{ .number = 0 };
            }
            if (std.mem.eql(u8, name, "clz32")) {
                const i: u32 = @bitCast(floatToInt32(n));
                return .{ .number = @floatFromInt(@clz(i)) };
            }
            if (std.mem.eql(u8, name, "fround")) {
                const f: f32 = @floatCast(n);
                return .{ .number = @floatCast(f) };
            }
        }

        // Two-argument functions
        if (args.len >= 2) {
            const a = args[0].toNumber() orelse return ComptimeError.TypeMismatch;
            const b = args[1].toNumber() orelse return ComptimeError.TypeMismatch;

            if (std.mem.eql(u8, name, "pow")) return .{ .number = std.math.pow(f64, a, b) };
            if (std.mem.eql(u8, name, "atan2")) return .{ .number = std.math.atan2(a, b) };
            if (std.mem.eql(u8, name, "hypot")) return .{ .number = std.math.hypot(a, b) };
            if (std.mem.eql(u8, name, "imul")) {
                const ai: i32 = floatToInt32(a);
                const bi: i32 = floatToInt32(b);
                return .{ .number = @floatFromInt(ai *% bi) };
            }
        }

        // Variadic: min, max
        if (std.mem.eql(u8, name, "min") or std.mem.eql(u8, name, "max")) {
            if (args.len == 0) return .{ .infinity = .{ .negative = std.mem.eql(u8, name, "max") } };

            var result = args[0].toNumber() orelse return ComptimeError.TypeMismatch;
            for (args[1..]) |arg| {
                const v = arg.toNumber() orelse return ComptimeError.TypeMismatch;
                if (std.math.isNan(v)) return .{ .nan_val = {} };
                result = if (std.mem.eql(u8, name, "min")) @min(result, v) else @max(result, v);
            }
            return .{ .number = result };
        }

        return ComptimeError.CallNotAllowed;
    }

    fn fnv1a(data: []const u8) u32 {
        var hash: u32 = 2166136261; // FNV offset basis
        for (data) |byte| {
            hash ^= byte;
            hash *%= 16777619; // FNV prime
        }
        return hash;
    }

    fn freeArgs(self: *Self, args: []const ComptimeValue) void {
        for (args) |arg| {
            arg.deinit(self.allocator);
        }
        self.allocator.free(args);
    }

    // ========================================================================
    // Arithmetic Operations
    // ========================================================================

    fn add(self: *Self, left: ComptimeValue, right: ComptimeValue) ComptimeError!ComptimeValue {
        // String concatenation. Allocate from the evaluator's allocator - the
        // same one the caller frees the result with (`result.deinit(allocator)`
        // in the stripper); the previous page_allocator made that a
        // cross-allocator free.
        if (left == .string or right == .string) {
            const ls = try valueToStringAlloc(self.allocator, left);
            defer if (left == .number) self.allocator.free(ls);
            const rs = try valueToStringAlloc(self.allocator, right);
            defer if (right == .number) self.allocator.free(rs);
            const result = std.fmt.allocPrint(self.allocator, "{s}{s}", .{ ls, rs }) catch return ComptimeError.OutOfMemory;
            return .{ .string = result };
        }

        const ln = left.toNumber() orelse return ComptimeError.TypeMismatch;
        const rn = right.toNumber() orelse return ComptimeError.TypeMismatch;
        return .{ .number = ln + rn };
    }

    fn subtract(self: *Self, left: ComptimeValue, right: ComptimeValue) ComptimeError!ComptimeValue {
        _ = self;
        const ln = left.toNumber() orelse return ComptimeError.TypeMismatch;
        const rn = right.toNumber() orelse return ComptimeError.TypeMismatch;
        return .{ .number = ln - rn };
    }

    fn multiply(self: *Self, left: ComptimeValue, right: ComptimeValue) ComptimeError!ComptimeValue {
        _ = self;
        const ln = left.toNumber() orelse return ComptimeError.TypeMismatch;
        const rn = right.toNumber() orelse return ComptimeError.TypeMismatch;
        return .{ .number = ln * rn };
    }

    fn divide(self: *Self, left: ComptimeValue, right: ComptimeValue) ComptimeError!ComptimeValue {
        _ = self;
        const ln = left.toNumber() orelse return ComptimeError.TypeMismatch;
        const rn = right.toNumber() orelse return ComptimeError.TypeMismatch;
        return .{ .number = ln / rn };
    }

    fn modulo(self: *Self, left: ComptimeValue, right: ComptimeValue) ComptimeError!ComptimeValue {
        _ = self;
        const ln = left.toNumber() orelse return ComptimeError.TypeMismatch;
        const rn = right.toNumber() orelse return ComptimeError.TypeMismatch;
        // JS % is truncated-toward-zero remainder (same sign as dividend), not floored.
        // @rem matches this; @mod (floored) gives wrong results for negative operands.
        return .{ .number = @rem(ln, rn) };
    }

    // ========================================================================
    // Bitwise Operations
    // ========================================================================

    fn bitwiseOr(self: *Self, left: ComptimeValue, right: ComptimeValue) ComptimeError!ComptimeValue {
        _ = self;
        const ln = left.toNumber() orelse return ComptimeError.TypeMismatch;
        const rn = right.toNumber() orelse return ComptimeError.TypeMismatch;
        const li: i32 = floatToInt32(ln);
        const ri: i32 = floatToInt32(rn);
        return .{ .number = @floatFromInt(li | ri) };
    }

    fn bitwiseAnd(self: *Self, left: ComptimeValue, right: ComptimeValue) ComptimeError!ComptimeValue {
        _ = self;
        const ln = left.toNumber() orelse return ComptimeError.TypeMismatch;
        const rn = right.toNumber() orelse return ComptimeError.TypeMismatch;
        const li: i32 = floatToInt32(ln);
        const ri: i32 = floatToInt32(rn);
        return .{ .number = @floatFromInt(li & ri) };
    }

    fn bitwiseXor(self: *Self, left: ComptimeValue, right: ComptimeValue) ComptimeError!ComptimeValue {
        _ = self;
        const ln = left.toNumber() orelse return ComptimeError.TypeMismatch;
        const rn = right.toNumber() orelse return ComptimeError.TypeMismatch;
        const li: i32 = floatToInt32(ln);
        const ri: i32 = floatToInt32(rn);
        return .{ .number = @floatFromInt(li ^ ri) };
    }

    const ShiftDir = enum { left, right, unsigned_right };

    fn bitwiseShift(self: *Self, left: ComptimeValue, right: ComptimeValue, dir: ShiftDir) ComptimeError!ComptimeValue {
        _ = self;
        const ln = left.toNumber() orelse return ComptimeError.TypeMismatch;
        const rn = right.toNumber() orelse return ComptimeError.TypeMismatch;
        const li: i32 = floatToInt32(ln);
        const shift: u5 = @intCast(@as(u32, @bitCast(floatToInt32(rn))) & 0x1f);

        return switch (dir) {
            .left => .{ .number = @floatFromInt(li << shift) },
            .right => .{ .number = @floatFromInt(li >> shift) },
            .unsigned_right => blk: {
                const ui: u32 = @bitCast(li);
                break :blk .{ .number = @floatFromInt(ui >> shift) };
            },
        };
    }

    // String helper methods
    fn stringToUpperCase(self: *Self, str: []const u8) ComptimeError!ComptimeValue {
        const result = self.allocator.alloc(u8, str.len) catch return ComptimeError.OutOfMemory;
        for (str, 0..) |c, i| {
            result[i] = std.ascii.toUpper(c);
        }
        return .{ .string = result };
    }

    fn stringToLowerCase(self: *Self, str: []const u8) ComptimeError!ComptimeValue {
        const result = self.allocator.alloc(u8, str.len) catch return ComptimeError.OutOfMemory;
        for (str, 0..) |c, i| {
            result[i] = std.ascii.toLower(c);
        }
        return .{ .string = result };
    }

    fn stringTrim(self: *Self, str: []const u8) ComptimeError!ComptimeValue {
        const trimmed = std.mem.trim(u8, str, " \t\n\r");
        const result = self.allocator.dupe(u8, trimmed) catch return ComptimeError.OutOfMemory;
        return .{ .string = result };
    }

    fn stringTrimStart(self: *Self, str: []const u8) ComptimeError!ComptimeValue {
        // Trim leading whitespace
        var start: usize = 0;
        for (str) |c| {
            if (c != ' ' and c != '\t' and c != '\n' and c != '\r') break;
            start += 1;
        }
        const result = self.allocator.dupe(u8, str[start..]) catch return ComptimeError.OutOfMemory;
        return .{ .string = result };
    }

    fn stringTrimEnd(self: *Self, str: []const u8) ComptimeError!ComptimeValue {
        // Trim trailing whitespace
        var end: usize = str.len;
        while (end > 0) {
            const c = str[end - 1];
            if (c != ' ' and c != '\t' and c != '\n' and c != '\r') break;
            end -= 1;
        }
        const result = self.allocator.dupe(u8, str[0..end]) catch return ComptimeError.OutOfMemory;
        return .{ .string = result };
    }

    fn stringSlice(self: *Self, str: []const u8, args: []const ComptimeValue) ComptimeError!ComptimeValue {
        if (args.len < 1) return ComptimeError.SyntaxError;

        const start_f = args[0].toNumber() orelse return ComptimeError.TypeMismatch;
        var start: i64 = std.math.lossyCast(i64, @trunc(start_f));
        // Indices are UTF-16 code units (matches .length and runtime slice).
        const len: i64 = @intCast(string.utf16Length(str));

        // Handle negative start
        if (start < 0) {
            start = @max(0, len + start);
        }
        if (start > len) start = len;

        var end: i64 = len;
        if (args.len >= 2) {
            const end_f = args[1].toNumber() orelse return ComptimeError.TypeMismatch;
            end = std.math.lossyCast(i64, @trunc(end_f));
            if (end < 0) {
                end = @max(0, len + end);
            }
            if (end > len) end = len;
        }

        if (end < start) {
            const empty = self.allocator.alloc(u8, 0) catch return ComptimeError.OutOfMemory;
            return .{ .string = empty };
        }

        // Map the code-unit range to byte offsets at codepoint boundaries.
        const byte_start = string.utf16IndexToByteOffset(str, @intCast(start));
        const byte_end = string.utf16IndexToByteOffset(str, @intCast(end));
        const result = self.allocator.dupe(u8, str[byte_start..byte_end]) catch return ComptimeError.OutOfMemory;
        return .{ .string = result };
    }

    fn stringSplit(self: *Self, str: []const u8, delim: []const u8) ComptimeError!ComptimeValue {
        var parts: std.ArrayList(ComptimeValue) = .empty;
        errdefer {
            for (parts.items) |p| p.deinit(self.allocator);
            parts.deinit(self.allocator);
        }

        if (delim.len == 0) {
            // Split into individual characters
            for (str) |c| {
                const char_str = self.allocator.alloc(u8, 1) catch return ComptimeError.OutOfMemory;
                char_str[0] = c;
                parts.append(self.allocator, .{ .string = char_str }) catch return ComptimeError.OutOfMemory;
            }
        } else {
            var iter = std.mem.splitSequence(u8, str, delim);
            while (iter.next()) |part| {
                const part_copy = self.allocator.dupe(u8, part) catch return ComptimeError.OutOfMemory;
                parts.append(self.allocator, .{ .string = part_copy }) catch return ComptimeError.OutOfMemory;
            }
        }

        return .{ .array = parts.toOwnedSlice(self.allocator) catch return ComptimeError.OutOfMemory };
    }

    fn stringPadStart(self: *Self, str: []const u8, args: []const ComptimeValue) ComptimeError!ComptimeValue {
        if (args.len < 1) return ComptimeError.SyntaxError;

        const target_len_f = args[0].toNumber() orelse return ComptimeError.TypeMismatch;
        const target_len: usize = std.math.lossyCast(usize, @trunc(target_len_f));

        if (target_len <= str.len) {
            return .{ .string = self.allocator.dupe(u8, str) catch return ComptimeError.OutOfMemory };
        }

        const pad_str: []const u8 = if (args.len >= 2)
            switch (args[1]) {
                .string => |s| s,
                else => return ComptimeError.TypeMismatch,
            }
        else
            " ";

        if (pad_str.len == 0) {
            return .{ .string = self.allocator.dupe(u8, str) catch return ComptimeError.OutOfMemory };
        }

        const pad_len = target_len - str.len;
        var result: std.ArrayList(u8) = .empty;

        var i: usize = 0;
        while (i < pad_len) : (i += 1) {
            result.append(self.allocator, pad_str[i % pad_str.len]) catch return ComptimeError.OutOfMemory;
        }
        result.appendSlice(self.allocator, str) catch return ComptimeError.OutOfMemory;

        return .{ .string = result.toOwnedSlice(self.allocator) catch return ComptimeError.OutOfMemory };
    }

    fn stringPadEnd(self: *Self, str: []const u8, args: []const ComptimeValue) ComptimeError!ComptimeValue {
        if (args.len < 1) return ComptimeError.SyntaxError;

        const target_len_f = args[0].toNumber() orelse return ComptimeError.TypeMismatch;
        const target_len: usize = std.math.lossyCast(usize, @trunc(target_len_f));

        if (target_len <= str.len) {
            return .{ .string = self.allocator.dupe(u8, str) catch return ComptimeError.OutOfMemory };
        }

        const pad_str: []const u8 = if (args.len >= 2)
            switch (args[1]) {
                .string => |s| s,
                else => return ComptimeError.TypeMismatch,
            }
        else
            " ";

        if (pad_str.len == 0) {
            return .{ .string = self.allocator.dupe(u8, str) catch return ComptimeError.OutOfMemory };
        }

        const pad_len = target_len - str.len;
        var result: std.ArrayList(u8) = .empty;
        result.appendSlice(self.allocator, str) catch return ComptimeError.OutOfMemory;

        var i: usize = 0;
        while (i < pad_len) : (i += 1) {
            result.append(self.allocator, pad_str[i % pad_str.len]) catch return ComptimeError.OutOfMemory;
        }

        return .{ .string = result.toOwnedSlice(self.allocator) catch return ComptimeError.OutOfMemory };
    }

    fn stringReplace(self: *Self, str: []const u8, search: []const u8, replacement: []const u8, replace_all: bool) ComptimeError!ComptimeValue {
        if (search.len == 0) {
            return .{ .string = self.allocator.dupe(u8, str) catch return ComptimeError.OutOfMemory };
        }

        var result: std.ArrayList(u8) = .empty;
        var i: usize = 0;
        var replaced = false;

        while (i < str.len) {
            if (i + search.len <= str.len and std.mem.eql(u8, str[i .. i + search.len], search)) {
                if (!replaced or replace_all) {
                    result.appendSlice(self.allocator, replacement) catch return ComptimeError.OutOfMemory;
                    replaced = true;
                    i += search.len;
                    continue;
                }
            }
            result.append(self.allocator, str[i]) catch return ComptimeError.OutOfMemory;
            i += 1;
        }

        return .{ .string = result.toOwnedSlice(self.allocator) catch return ComptimeError.OutOfMemory };
    }
};

// ============================================================================
// Literal Emission
// ============================================================================

/// Convert a ComptimeValue back to JavaScript source code
pub fn emitLiteral(allocator: std.mem.Allocator, value: ComptimeValue) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    try emitValue(&buf, value, allocator);
    return buf.toOwnedSlice(allocator);
}

fn emitValue(buf: *std.ArrayList(u8), value: ComptimeValue, allocator: std.mem.Allocator) !void {
    switch (value) {
        .number => |n| {
            if (std.math.isNan(n)) {
                try buf.appendSlice(allocator, "NaN");
            } else if (std.math.isInf(n)) {
                if (n < 0) {
                    try buf.appendSlice(allocator, "-Infinity");
                } else {
                    try buf.appendSlice(allocator, "Infinity");
                }
            } else if (@trunc(n) == n and @abs(n) < 2147483647) {
                // Integer
                var num_buf: [32]u8 = undefined;
                const s = std.fmt.bufPrint(&num_buf, "{d}", .{@as(i32, @intFromFloat(n))}) catch return error.OutOfMemory;
                try buf.appendSlice(allocator, s);
            } else {
                // Float
                var num_buf: [32]u8 = undefined;
                const s = std.fmt.bufPrint(&num_buf, "{d}", .{n}) catch return error.OutOfMemory;
                try buf.appendSlice(allocator, s);
            }
        },
        .string => |s| {
            try buf.append(allocator, '"');
            for (s) |c| {
                switch (c) {
                    '"' => try buf.appendSlice(allocator, "\\\""),
                    '\\' => try buf.appendSlice(allocator, "\\\\"),
                    '\n' => try buf.appendSlice(allocator, "\\n"),
                    '\r' => try buf.appendSlice(allocator, "\\r"),
                    '\t' => try buf.appendSlice(allocator, "\\t"),
                    else => try buf.append(allocator, c),
                }
            }
            try buf.append(allocator, '"');
        },
        .boolean => |b| {
            try buf.appendSlice(allocator, if (b) "true" else "false");
        },
        .null_val => try buf.appendSlice(allocator, "null"),
        .undefined_val => try buf.appendSlice(allocator, "undefined"),
        .nan_val => try buf.appendSlice(allocator, "NaN"),
        .infinity => |i| {
            if (i.negative) {
                try buf.appendSlice(allocator, "-Infinity");
            } else {
                try buf.appendSlice(allocator, "Infinity");
            }
        },
        .array => |arr| {
            try buf.append(allocator, '[');
            for (arr, 0..) |elem, i| {
                if (i > 0) try buf.append(allocator, ',');
                try emitValue(buf, elem, allocator);
            }
            try buf.append(allocator, ']');
        },
        .object => |props| {
            // Wrap in ({ }) for expression context safety
            try buf.appendSlice(allocator, "({");
            for (props, 0..) |prop, i| {
                if (i > 0) try buf.append(allocator, ',');
                // Emit key (quote if needed)
                if (needsQuotes(prop.key)) {
                    try buf.append(allocator, '"');
                    try buf.appendSlice(allocator, prop.key);
                    try buf.append(allocator, '"');
                } else {
                    try buf.appendSlice(allocator, prop.key);
                }
                try buf.append(allocator, ':');
                try emitValue(buf, prop.value, allocator);
            }
            try buf.appendSlice(allocator, "})");
        },
    }
}

fn needsQuotes(key: []const u8) bool {
    if (key.len == 0) return true;
    if (!isIdentifierStart(key[0])) return true;
    for (key[1..]) |c| {
        if (!isIdentifierChar(c)) return true;
    }
    return false;
}

// ============================================================================
// Character Classification
// ============================================================================

fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

fn isIdentifierStart(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_' or c == '$';
}

fn isIdentifierChar(c: u8) bool {
    return isIdentifierStart(c) or isDigit(c);
}

fn valueToString(value: ComptimeValue) []const u8 {
    return switch (value) {
        .string => |s| s,
        .number => |n| blk: {
            if (std.math.isNan(n)) break :blk "NaN";
            if (std.math.isInf(n)) break :blk if (n < 0) "-Infinity" else "Infinity";
            break :blk ""; // finite numbers need allocation; use valueToStringAlloc
        },
        .boolean => |b| if (b) "true" else "false",
        .null_val => "null",
        .undefined_val => "undefined",
        .nan_val => "NaN",
        .infinity => |i| if (i.negative) "-Infinity" else "Infinity",
        .array => "",
        .object => "[object Object]",
    };
}

fn valueToStringAlloc(allocator: std.mem.Allocator, value: ComptimeValue) error{OutOfMemory}![]const u8 {
    if (value == .number) {
        const n = value.number;
        if (std.math.isNan(n)) return try allocator.dupe(u8, "NaN");
        if (std.math.isInf(n)) return try allocator.dupe(u8, if (n < 0) "-Infinity" else "Infinity");
        // Format like JS: integer values as integers, floats with minimal digits.
        if (n == @trunc(n) and @abs(n) < 1e15) {
            return std.fmt.allocPrint(allocator, "{d}", .{@as(i64, @intFromFloat(n))});
        }
        return std.fmt.allocPrint(allocator, "{}", .{n});
    }
    return valueToString(value);
}

// ============================================================================
// Tests
// ============================================================================

test "comptime number literals" {
    const allocator = std.testing.allocator;

    var eval1 = ComptimeEvaluator.init(allocator, "42");
    const r1 = try eval1.evaluate();
    try std.testing.expectEqual(@as(f64, 42), r1.number);

    var eval2 = ComptimeEvaluator.init(allocator, "3.14");
    const r2 = try eval2.evaluate();
    try std.testing.expectApproxEqAbs(@as(f64, 3.14), r2.number, 0.001);

    var eval3 = ComptimeEvaluator.init(allocator, "0xFF");
    const r3 = try eval3.evaluate();
    try std.testing.expectEqual(@as(f64, 255), r3.number);
}

test "comptime arithmetic" {
    const allocator = std.testing.allocator;

    var eval1 = ComptimeEvaluator.init(allocator, "1 + 2");
    const r1 = try eval1.evaluate();
    try std.testing.expectEqual(@as(f64, 3), r1.number);

    var eval2 = ComptimeEvaluator.init(allocator, "1 + 2 * 3");
    const r2 = try eval2.evaluate();
    try std.testing.expectEqual(@as(f64, 7), r2.number);

    var eval3 = ComptimeEvaluator.init(allocator, "2 ** 10");
    const r3 = try eval3.evaluate();
    try std.testing.expectEqual(@as(f64, 1024), r3.number);

    // JS % is truncated-toward-zero (not floored): -5 % 3 = -2, not 1.
    var eval4 = ComptimeEvaluator.init(allocator, "-5 % 3");
    const r4 = try eval4.evaluate();
    try std.testing.expectEqual(@as(f64, -2), r4.number);
}

test "comptime boolean operations" {
    const allocator = std.testing.allocator;

    var eval1 = ComptimeEvaluator.init(allocator, "true && false");
    const r1 = try eval1.evaluate();
    try std.testing.expectEqual(false, r1.boolean);

    var eval2 = ComptimeEvaluator.init(allocator, "true || false");
    const r2 = try eval2.evaluate();
    try std.testing.expectEqual(true, r2.boolean);

    var eval3 = ComptimeEvaluator.init(allocator, "!true");
    const r3 = try eval3.evaluate();
    try std.testing.expectEqual(false, r3.boolean);
}

test "comptime comparison" {
    const allocator = std.testing.allocator;

    var eval1 = ComptimeEvaluator.init(allocator, "5 > 3");
    const r1 = try eval1.evaluate();
    try std.testing.expectEqual(true, r1.boolean);

    var eval2 = ComptimeEvaluator.init(allocator, "5 === 5");
    const r2 = try eval2.evaluate();
    try std.testing.expectEqual(true, r2.boolean);
}

test "comptime ternary" {
    const allocator = std.testing.allocator;

    var eval1 = ComptimeEvaluator.init(allocator, "true ? 1 : 2");
    const r1 = try eval1.evaluate();
    try std.testing.expectEqual(@as(f64, 1), r1.number);

    var eval2 = ComptimeEvaluator.init(allocator, "false ? 1 : 2");
    const r2 = try eval2.evaluate();
    try std.testing.expectEqual(@as(f64, 2), r2.number);
}

test "comptime Math" {
    const allocator = std.testing.allocator;

    var eval1 = ComptimeEvaluator.init(allocator, "Math.PI");
    const r1 = try eval1.evaluate();
    try std.testing.expectApproxEqAbs(@as(f64, 3.141592653589793), r1.number, 0.0001);

    var eval2 = ComptimeEvaluator.init(allocator, "Math.abs(-5)");
    const r2 = try eval2.evaluate();
    try std.testing.expectEqual(@as(f64, 5), r2.number);

    var eval3 = ComptimeEvaluator.init(allocator, "Math.max(1, 5, 3)");
    const r3 = try eval3.evaluate();
    try std.testing.expectEqual(@as(f64, 5), r3.number);
}

test "comptime bitwise ops fold via ToInt32 without panicking on large operands" {
    const allocator = std.testing.allocator;

    // Regression: the bitwise ops did a raw @intFromFloat into i32, which is
    // illegal behavior for |operand| >= 2^31 (e.g. 0xFFFFFFFF). They now share
    // the interpreter's ECMAScript ToInt32, so compile-time folding matches the
    // runtime instead of crashing the analyzer.
    const Case = struct { src: []const u8, want: f64 };
    const cases = [_]Case{
        .{ .src = "0xFFFFFFFF & 1", .want = 1 }, // 0xFFFFFFFF -> -1, -1 & 1 = 1
        .{ .src = "2147483648 | 0", .want = -2147483648 }, // wraps to i32 min
        .{ .src = "~3000000000", .want = 1294967295 }, // ToInt32(3e9) = -1294967296, ~ = 1294967295
        .{ .src = "1 << 31", .want = -2147483648 },
    };
    for (cases) |c| {
        var ev = ComptimeEvaluator.init(allocator, c.src);
        const r = try ev.evaluate();
        try std.testing.expectEqual(c.want, r.number);
    }
}

test "comptime string" {
    const allocator = std.testing.allocator;

    var eval1 = ComptimeEvaluator.init(allocator, "\"hello\"");
    const r1 = try eval1.evaluate();
    defer r1.deinit(allocator);
    try std.testing.expectEqualStrings("hello", r1.string);
}

test "comptime string indexes by UTF-16 code units ENG-utf16" {
    const allocator = std.testing.allocator;

    // .length counts UTF-16 code units, matching the runtime (not UTF-8 bytes).
    var e_len = ComptimeEvaluator.init(allocator, "\"é\".length");
    const r_len = try e_len.evaluate();
    defer r_len.deinit(allocator);
    try std.testing.expectEqual(@as(f64, 1), r_len.number);

    var e_astral = ComptimeEvaluator.init(allocator, "\"😀\".length");
    const r_astral = try e_astral.evaluate();
    defer r_astral.deinit(allocator);
    try std.testing.expectEqual(@as(f64, 2), r_astral.number);

    // slice clamps by code units and cuts on codepoint boundaries.
    var e_slice = ComptimeEvaluator.init(allocator, "\"héllo\".slice(0, 2)");
    const r_slice = try e_slice.evaluate();
    defer r_slice.deinit(allocator);
    try std.testing.expectEqualStrings("hé", r_slice.string);

    // indexOf returns a code-unit index (was a byte offset).
    var e_idx = ComptimeEvaluator.init(allocator, "\"café-x\".indexOf(\"x\")");
    const r_idx = try e_idx.evaluate();
    defer r_idx.deinit(allocator);
    try std.testing.expectEqual(@as(f64, 5), r_idx.number);
}

test "comptime array" {
    const allocator = std.testing.allocator;

    var eval1 = ComptimeEvaluator.init(allocator, "[1, 2, 3]");
    const r1 = try eval1.evaluate();
    defer r1.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 3), r1.array.len);
    try std.testing.expectEqual(@as(f64, 1), r1.array[0].number);
}

test "comptime hash" {
    const allocator = std.testing.allocator;

    var eval1 = ComptimeEvaluator.init(allocator, "hash(\"test\")");
    const r1 = try eval1.evaluate();
    defer r1.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 8), r1.string.len);
}

test "emit literal" {
    const allocator = std.testing.allocator;

    const s1 = try emitLiteral(allocator, .{ .number = 42 });
    defer allocator.free(s1);
    try std.testing.expectEqualStrings("42", s1);

    const s2 = try emitLiteral(allocator, .{ .boolean = true });
    defer allocator.free(s2);
    try std.testing.expectEqualStrings("true", s2);
}

test "comptime string methods" {
    const allocator = std.testing.allocator;

    // toUpperCase
    {
        var eval = ComptimeEvaluator.init(allocator, "\"hello\".toUpperCase()");
        const r = try eval.evaluate();
        defer r.deinit(allocator);
        try std.testing.expectEqualStrings("HELLO", r.string);
    }

    // toLowerCase
    {
        var eval = ComptimeEvaluator.init(allocator, "\"HELLO\".toLowerCase()");
        const r = try eval.evaluate();
        defer r.deinit(allocator);
        try std.testing.expectEqualStrings("hello", r.string);
    }

    // trim
    {
        var eval = ComptimeEvaluator.init(allocator, "\"  hello  \".trim()");
        const r = try eval.evaluate();
        defer r.deinit(allocator);
        try std.testing.expectEqualStrings("hello", r.string);
    }

    // slice
    {
        var eval = ComptimeEvaluator.init(allocator, "\"hello\".slice(1, 4)");
        const r = try eval.evaluate();
        defer r.deinit(allocator);
        try std.testing.expectEqualStrings("ell", r.string);
    }

    // includes
    {
        var eval = ComptimeEvaluator.init(allocator, "\"hello\".includes(\"ell\")");
        const r = try eval.evaluate();
        try std.testing.expect(r.boolean);
    }

    // startsWith
    {
        var eval = ComptimeEvaluator.init(allocator, "\"hello\".startsWith(\"he\")");
        const r = try eval.evaluate();
        try std.testing.expect(r.boolean);
    }

    // endsWith
    {
        var eval = ComptimeEvaluator.init(allocator, "\"hello\".endsWith(\"lo\")");
        const r = try eval.evaluate();
        try std.testing.expect(r.boolean);
    }

    // split
    {
        var eval = ComptimeEvaluator.init(allocator, "\"a,b,c\".split(\",\")");
        const r = try eval.evaluate();
        defer r.deinit(allocator);
        try std.testing.expectEqual(@as(usize, 3), r.array.len);
        try std.testing.expectEqualStrings("a", r.array[0].string);
        try std.testing.expectEqualStrings("b", r.array[1].string);
        try std.testing.expectEqualStrings("c", r.array[2].string);
    }

    // repeat
    {
        var eval = ComptimeEvaluator.init(allocator, "\"ab\".repeat(3)");
        const r = try eval.evaluate();
        defer r.deinit(allocator);
        try std.testing.expectEqualStrings("ababab", r.string);
    }

    // replace
    {
        var eval = ComptimeEvaluator.init(allocator, "\"hello\".replace(\"l\", \"L\")");
        const r = try eval.evaluate();
        defer r.deinit(allocator);
        try std.testing.expectEqualStrings("heLlo", r.string);
    }

    // replaceAll
    {
        var eval = ComptimeEvaluator.init(allocator, "\"hello\".replaceAll(\"l\", \"L\")");
        const r = try eval.evaluate();
        defer r.deinit(allocator);
        try std.testing.expectEqualStrings("heLLo", r.string);
    }

    // length property
    {
        var eval = ComptimeEvaluator.init(allocator, "\"hello\".length");
        const r = try eval.evaluate();
        try std.testing.expectEqual(@as(f64, 5), r.number);
    }

    // padStart
    {
        var eval = ComptimeEvaluator.init(allocator, "\"5\".padStart(3, \"0\")");
        const r = try eval.evaluate();
        defer r.deinit(allocator);
        try std.testing.expectEqualStrings("005", r.string);
    }

    // padEnd
    {
        var eval = ComptimeEvaluator.init(allocator, "\"5\".padEnd(3, \"0\")");
        const r = try eval.evaluate();
        defer r.deinit(allocator);
        try std.testing.expectEqualStrings("500", r.string);
    }
}

test "comptime string method chaining" {
    const allocator = std.testing.allocator;

    // Chain multiple string methods
    var eval = ComptimeEvaluator.init(allocator, "\"  hello world  \".trim().toUpperCase()");
    const r = try eval.evaluate();
    defer r.deinit(allocator);
    try std.testing.expectEqualStrings("HELLO WORLD", r.string);
}

test "comptime string concatenation frees with the evaluator allocator" {
    // Regression: `add` allocated the concatenation from page_allocator while
    // the caller freed it with the evaluator's allocator. Under the leak-
    // detecting testing allocator that cross-allocator free is caught here.
    const allocator = std.testing.allocator;

    var eval = ComptimeEvaluator.init(allocator, "\"foo\" + \"bar\"");
    const r = try eval.evaluate();
    defer r.deinit(allocator);
    try std.testing.expectEqualStrings("foobar", r.string);
}

test "comptime behavior matrix preserves exact values operators builtins and capabilities" {
    const allocator = std.testing.allocator;
    const Matrix = struct {
        fn expectLiteral(source: []const u8, expected: []const u8) !void {
            var evaluator = ComptimeEvaluator.init(std.testing.allocator, source);
            const value = try evaluator.evaluate();
            defer value.deinit(std.testing.allocator);
            const literal = try emitLiteral(std.testing.allocator, value);
            defer std.testing.allocator.free(literal);
            try std.testing.expectEqualStrings(expected, literal);
        }
    };
    const cases = [_]struct {
        source: []const u8,
        expected: []const u8,
    }{
        // Literals, numeric syntax, strings, and aggregates.
        .{ .source = "42", .expected = "42" },
        .{ .source = ".5", .expected = "0.5" },
        .{ .source = "3.125", .expected = "3.125" },
        .{ .source = "1_000", .expected = "1000" },
        .{ .source = "0xFF_FF", .expected = "65535" },
        .{ .source = "0o17", .expected = "15" },
        .{ .source = "0b1010", .expected = "10" },
        .{ .source = "1e3", .expected = "1000" },
        .{ .source = "1.5e-2", .expected = "0.015" },
        .{ .source = "null", .expected = "null" },
        .{ .source = "undefined", .expected = "undefined" },
        .{ .source = "NaN", .expected = "NaN" },
        .{ .source = "Infinity", .expected = "Infinity" },
        .{ .source = "-Infinity", .expected = "-Infinity" },
        .{ .source = "-0", .expected = "0" },
        .{ .source = "\"line\\n\\\"quote\\\"\"", .expected = "\"line\\n\\\"quote\\\"\"" },
        .{ .source = "\"\\x41\"", .expected = "\"A\"" },
        .{ .source = "`plain\\ntext`", .expected = "\"plain\\ntext\"" },
        .{ .source = "[1, true, null]", .expected = "[1,true,null]" },
        .{ .source = "[1, 2, 3].length", .expected = "3" },
        .{ .source = "{ plain: 1, \"hyphen-key\": \"x\" }", .expected = "({plain:1,\"hyphen-key\":\"x\"})" },

        // Every documented operator, including coercion and value-returning
        // logical operators. Division by zero follows JavaScript and emits
        // Infinity, which is what the same expression does at runtime.
        .{ .source = "1 + 2", .expected = "3" },
        .{ .source = "5 - 2", .expected = "3" },
        .{ .source = "3 * 4", .expected = "12" },
        .{ .source = "8 / 2", .expected = "4" },
        .{ .source = "5 % 2", .expected = "1" },
        .{ .source = "2 ** 3", .expected = "8" },
        .{ .source = "5 | 2", .expected = "7" },
        .{ .source = "7 & 3", .expected = "3" },
        .{ .source = "5 ^ 3", .expected = "6" },
        .{ .source = "1 << 3", .expected = "8" },
        .{ .source = "-8 >> 2", .expected = "-2" },
        .{ .source = "-1 >>> 1", .expected = "2147483647" },
        .{ .source = "\"5\" == 5", .expected = "true" },
        .{ .source = "\"5\" != 5", .expected = "false" },
        .{ .source = "\"5\" === 5", .expected = "false" },
        .{ .source = "\"5\" !== 5", .expected = "true" },
        .{ .source = "2 < 3", .expected = "true" },
        .{ .source = "2 <= 2", .expected = "true" },
        .{ .source = "3 > 2", .expected = "true" },
        .{ .source = "3 >= 3", .expected = "true" },
        .{ .source = "\"left\" && \"right\"", .expected = "\"right\"" },
        .{ .source = "\"\" || \"fallback\"", .expected = "\"fallback\"" },
        .{ .source = "null ?? 7", .expected = "7" },
        .{ .source = "false ? 1 : 2", .expected = "2" },
        .{ .source = "+5", .expected = "5" },
        .{ .source = "-5", .expected = "-5" },
        .{ .source = "!0", .expected = "true" },
        .{ .source = "~0", .expected = "-1" },
        .{ .source = "1 + 2 * 3", .expected = "7" },
        .{ .source = "null == undefined", .expected = "true" },
        .{ .source = "1 / 0", .expected = "Infinity" },

        // Precedence and associativity categories, from ternary through member
        // access and grouping.
        .{ .source = "false ? 1 : true ? 2 : 3", .expected = "2" },
        .{ .source = "null ?? 0 || 2", .expected = "2" },
        .{ .source = "false || true && false", .expected = "false" },
        .{ .source = "true && 1 | 2", .expected = "3" },
        .{ .source = "1 | 2 ^ 3", .expected = "1" },
        .{ .source = "1 ^ 3 & 1", .expected = "0" },
        .{ .source = "7 & 3 == 2", .expected = "0" },
        .{ .source = "1 == 1 < 2", .expected = "true" },
        .{ .source = "1 < 2 << 1", .expected = "true" },
        .{ .source = "1 << 1 + 1", .expected = "4" },
        .{ .source = "10 - 3 - 2", .expected = "5" },
        .{ .source = "8 / 2 % 3", .expected = "1" },
        .{ .source = "2 ** 3 ** 2", .expected = "512" },
        .{ .source = "~1 + 4", .expected = "2" },
        .{ .source = "-3 ** 2", .expected = "9" },
        .{ .source = "\" x \".trim().length", .expected = "1" },
        .{ .source = "(1 + 2) * 3", .expected = "9" },

        // Every documented Math constant and function.
        .{ .source = "Math.PI", .expected = "3.141592653589793" },
        .{ .source = "Math.E", .expected = "2.718281828459045" },
        .{ .source = "Math.LN2", .expected = "0.6931471805599453" },
        .{ .source = "Math.LN10", .expected = "2.302585092994046" },
        .{ .source = "Math.LOG2E", .expected = "1.4426950408889634" },
        .{ .source = "Math.LOG10E", .expected = "0.4342944819032518" },
        .{ .source = "Math.SQRT2", .expected = "1.4142135623730951" },
        .{ .source = "Math.SQRT1_2", .expected = "0.7071067811865476" },
        .{ .source = "Math.abs(-5)", .expected = "5" },
        .{ .source = "Math.floor(1.9)", .expected = "1" },
        .{ .source = "Math.ceil(1.1)", .expected = "2" },
        .{ .source = "Math.round(1.5)", .expected = "2" },
        .{ .source = "Math.trunc(-1.9)", .expected = "-1" },
        .{ .source = "Math.sqrt(9)", .expected = "3" },
        .{ .source = "Math.cbrt(8)", .expected = "2" },
        .{ .source = "Math.sin(0)", .expected = "0" },
        .{ .source = "Math.cos(0)", .expected = "1" },
        .{ .source = "Math.tan(0)", .expected = "0" },
        .{ .source = "Math.asin(0)", .expected = "0" },
        .{ .source = "Math.acos(1)", .expected = "0" },
        .{ .source = "Math.atan(0)", .expected = "0" },
        .{ .source = "Math.atan2(0, 1)", .expected = "0" },
        .{ .source = "Math.log(1)", .expected = "0" },
        .{ .source = "Math.log2(8)", .expected = "3" },
        .{ .source = "Math.log10(100)", .expected = "2" },
        .{ .source = "Math.exp(0)", .expected = "1" },
        .{ .source = "Math.pow(2, 3)", .expected = "8" },
        .{ .source = "Math.min(3, 1, 2)", .expected = "1" },
        .{ .source = "Math.max(3, 1, 2)", .expected = "3" },
        .{ .source = "Math.sign(-2)", .expected = "-1" },
        .{ .source = "Math.clz32(1)", .expected = "31" },
        .{ .source = "Math.imul(0xFFFFFFFF, 5)", .expected = "-5" },
        .{ .source = "Math.fround(1.5)", .expected = "1.5" },
        .{ .source = "Math.hypot(3, 4)", .expected = "5" },

        // Every documented string property and method.
        .{ .source = "\"hello\".length", .expected = "5" },
        .{ .source = "\"hello\".toUpperCase()", .expected = "\"HELLO\"" },
        .{ .source = "\"HELLO\".toLowerCase()", .expected = "\"hello\"" },
        .{ .source = "\"  hello  \".trim()", .expected = "\"hello\"" },
        .{ .source = "\"  hello\".trimStart()", .expected = "\"hello\"" },
        .{ .source = "\"hello  \".trimEnd()", .expected = "\"hello\"" },
        .{ .source = "\"hello\".slice(1, 4)", .expected = "\"ell\"" },
        .{ .source = "\"hello\".substring(1, 4)", .expected = "\"ell\"" },
        .{ .source = "\"hello\".includes(\"ell\")", .expected = "true" },
        .{ .source = "\"hello\".startsWith(\"he\")", .expected = "true" },
        .{ .source = "\"hello\".endsWith(\"lo\")", .expected = "true" },
        .{ .source = "\"hello\".indexOf(\"l\")", .expected = "2" },
        .{ .source = "\"hello\".charAt(1)", .expected = "\"e\"" },
        .{ .source = "\"abc\".charAt(NaN)", .expected = "\"a\"" },
        .{ .source = "\"abc\".charAt(-0)", .expected = "\"a\"" },
        .{ .source = "\"abc\".charAt(-1)", .expected = "\"\"" },
        .{ .source = "\"abc\".charAt(Infinity)", .expected = "\"\"" },
        .{ .source = "\"abc\".charAt(1.9)", .expected = "\"b\"" },
        .{ .source = "\"a,b,c\".split(\",\")", .expected = "[\"a\",\"b\",\"c\"]" },
        .{ .source = "\"ab\".repeat(3)", .expected = "\"ababab\"" },
        .{ .source = "\"hello\".replace(\"l\", \"L\")", .expected = "\"heLlo\"" },
        .{ .source = "\"hello\".replaceAll(\"l\", \"L\")", .expected = "\"heLLo\"" },
        .{ .source = "\"5\".padStart(3, \"0\")", .expected = "\"005\"" },
        .{ .source = "\"5\".padEnd(3, \"0\")", .expected = "\"500\"" },

        // Every documented built-in.
        .{ .source = "parseInt(\"ff\", 16)", .expected = "255" },
        .{ .source = "parseFloat(\" 3.5 \")", .expected = "3.5" },
        .{ .source = "JSON.parse(\"{\\\"ok\\\":true}\")", .expected = "({ok:true})" },
        .{ .source = "JSON.parse(\"{loose:1} trailing\")", .expected = "({loose:1})" },
        .{ .source = "JSON.parse(\"[1, undefined] trailing\")", .expected = "[1,undefined]" },
        .{ .source = "hash(\"test\")", .expected = "\"afd071e5\"" },
    };
    for (cases) |case| try Matrix.expectLiteral(case.source, case.expected);

    var env = std.StringHashMap([]const u8).init(allocator);
    defer env.deinit();
    const env_value = try allocator.dupe(u8, "https://example.test");
    defer allocator.free(env_value);
    try env.put("API_URL", env_value);
    var env_evaluator = ComptimeEvaluator.init(allocator, "Env.API_URL");
    env_evaluator.env = &env;
    const env_result = try env_evaluator.evaluate();
    defer env_result.deinit(allocator);
    try std.testing.expectEqualStrings(env_value, env_result.string);
    try std.testing.expect(env_value.ptr != env_result.string.ptr);

    const metadata_cases = [_]struct {
        source: []const u8,
        field: enum { build_time, git_commit, version },
        value: []const u8,
    }{
        .{ .source = "__BUILD_TIME__", .field = .build_time, .value = "2026-08-05T12:00:00Z" },
        .{ .source = "__GIT_COMMIT__", .field = .git_commit, .value = "0123456789abcdef" },
        .{ .source = "__VERSION__", .field = .version, .value = "0.18.0" },
    };
    for (metadata_cases) |case| {
        const owned_value = try allocator.dupe(u8, case.value);
        defer allocator.free(owned_value);
        var evaluator = ComptimeEvaluator.init(allocator, case.source);
        switch (case.field) {
            .build_time => evaluator.build_time = owned_value,
            .git_commit => evaluator.git_commit = owned_value,
            .version => evaluator.version = owned_value,
        }
        const result = try evaluator.evaluate();
        defer result.deinit(allocator);
        try std.testing.expectEqualStrings(case.value, result.string);
        try std.testing.expect(owned_value.ptr != result.string.ptr);
    }

    // A build-metadata identifier is a string value, so the documented string
    // members apply to it. `Math` and `Env` are namespaces and keep their own
    // handling; every other identifier receiver is evaluated as a value.
    const member_cases = [_]struct {
        source: []const u8,
        expected: []const u8,
    }{
        .{ .source = "__VERSION__.toUpperCase()", .expected = "0.18.0" },
        .{ .source = "__GIT_COMMIT__.slice(0, 7)", .expected = "0123456" },
        .{ .source = "__BUILD_TIME__.slice(0, 10)", .expected = "2026-08-05" },
    };
    for (member_cases) |case| {
        var evaluator = ComptimeEvaluator.init(allocator, case.source);
        evaluator.build_time = "2026-08-05T12:00:00Z";
        evaluator.git_commit = "0123456789abcdef";
        evaluator.version = "0.18.0";
        const result = try evaluator.evaluate();
        defer result.deinit(allocator);
        try std.testing.expectEqualStrings(case.expected, result.string);
    }

    // `__VERSION__` is a string, so `.length` counts its UTF-16 units.
    {
        var evaluator = ComptimeEvaluator.init(allocator, "__VERSION__.length");
        evaluator.version = "0.18.0";
        const result = try evaluator.evaluate();
        defer result.deinit(allocator);
        try std.testing.expectEqual(@as(f64, 6), result.number);
    }

    // An identifier that names nothing still fails as an unknown identifier,
    // whether it is read as a property or called as a method.
    {
        var evaluator = ComptimeEvaluator.init(allocator, "Nope.field");
        try std.testing.expectError(ComptimeError.UnknownIdentifier, evaluator.evaluate());
    }
    {
        var evaluator = ComptimeEvaluator.init(allocator, "Nope.method()");
        try std.testing.expectError(ComptimeError.UnknownIdentifier, evaluator.evaluate());
    }
}

test "comptime behavior matrix rejects nondeterminism and malformed expressions" {
    const allocator = std.testing.allocator;
    const cases = [_]struct {
        source: []const u8,
        expected: ComptimeError,
    }{
        // Every documented forbidden syntax family is rejected under its
        // current error identity.
        .{ .source = "Math.random()", .expected = ComptimeError.CallNotAllowed },
        .{ .source = "Date.now()", .expected = ComptimeError.UnknownIdentifier },
        .{ .source = "arbitrary()", .expected = ComptimeError.UnknownIdentifier },
        .{ .source = "variable", .expected = ComptimeError.UnknownIdentifier },
        .{ .source = "new Thing()", .expected = ComptimeError.UnsupportedOp },
        .{ .source = "this", .expected = ComptimeError.UnsupportedOp },
        .{ .source = "eval(\"1\")", .expected = ComptimeError.UnsupportedOp },
        .{ .source = "1 = 2", .expected = ComptimeError.UnexpectedToken },
        .{ .source = "while (true) 1", .expected = ComptimeError.UnknownIdentifier },
        .{ .source = "const value = 1", .expected = ComptimeError.UnknownIdentifier },
        .{ .source = "() => 1", .expected = ComptimeError.UnexpectedToken },
        // Parser-owned feature refusals keep their semantic identity in the
        // comptime profile instead of being mislabeled as misspelled names.
        .{ .source = "\"value\" |> hash", .expected = ComptimeError.UnsupportedOp },
        .{ .source = "1 |> Math.abs", .expected = ComptimeError.UnsupportedOp },

        // Logical and ternary evaluation stays eager so an invalid expression
        // cannot hide in either selected or unselected children.
        .{ .source = "arbitrary() && false", .expected = ComptimeError.UnknownIdentifier },
        .{ .source = "false && arbitrary()", .expected = ComptimeError.UnknownIdentifier },
        .{ .source = "arbitrary() || true", .expected = ComptimeError.UnknownIdentifier },
        .{ .source = "true || arbitrary()", .expected = ComptimeError.UnknownIdentifier },
        .{ .source = "arbitrary() ?? 1", .expected = ComptimeError.UnknownIdentifier },
        .{ .source = "1 ?? arbitrary()", .expected = ComptimeError.UnknownIdentifier },
        .{ .source = "true ? arbitrary() : 0", .expected = ComptimeError.UnknownIdentifier },
        .{ .source = "true ? 1 : arbitrary()", .expected = ComptimeError.UnknownIdentifier },

        // Canonical parser nodes outside the explicit evaluator ADT stay
        // reachable in tests and fail closed under their current identities.
        .{ .source = "[...[]]", .expected = ComptimeError.UnsupportedOp },
        .{ .source = "{...{a: 1}}", .expected = ComptimeError.UnsupportedOp },
        .{ .source = "{[\"a\"]: 1}", .expected = ComptimeError.SyntaxError },
        .{ .source = "\"x\"[0]", .expected = ComptimeError.UnsupportedOp },
        .{ .source = "Env?.VALUE", .expected = ComptimeError.UnsupportedOp },
        .{ .source = "hash?.(\"x\")", .expected = ComptimeError.UnsupportedOp },
        .{ .source = "Math.max(...[1, 2])", .expected = ComptimeError.UnsupportedOp },
        .{ .source = "typeof 1", .expected = ComptimeError.UnsupportedOp },
        .{ .source = "void 0", .expected = ComptimeError.UnsupportedOp },
        .{ .source = "\"a\" in {a: 1}", .expected = ComptimeError.UnsupportedOp },

        // Stable malformed-input and evaluation error classes that can be
        // reached without allocator fault injection.
        .{ .source = "`value: ${1}`", .expected = ComptimeError.UnsupportedOp },
        .{ .source = "\"x\" - {}", .expected = ComptimeError.TypeMismatch },
        .{ .source = "{a 1}", .expected = ComptimeError.SyntaxError },
        .{ .source = "\"unterminated", .expected = ComptimeError.UnclosedString },
        .{ .source = "{\"unterminated", .expected = ComptimeError.UnclosedString },
        .{ .source = "(1 + 2", .expected = ComptimeError.UnclosedParen },
        .{ .source = "[1, 2", .expected = ComptimeError.UnclosedBracket },
        .{ .source = "{a: 1", .expected = ComptimeError.UnclosedBrace },
        .{ .source = "1 2", .expected = ComptimeError.UnexpectedToken },
        .{ .source = "", .expected = ComptimeError.UnexpectedEnd },
        .{ .source = "0x", .expected = ComptimeError.InvalidNumber },
        .{ .source = "\"\\xGG\"", .expected = ComptimeError.InvalidEscape },
        .{ .source = "{\"\\xGG\": 1}", .expected = ComptimeError.InvalidEscape },
        .{ .source = "JSON.parse(\"'single-root'\")", .expected = ComptimeError.SyntaxError },
        .{ .source = "JSON.parse(\".5\")", .expected = ComptimeError.SyntaxError },
        .{ .source = "JSON.parse(\"{loose 1}\")", .expected = ComptimeError.SyntaxError },
    };
    for (cases) |case| {
        var evaluator = ComptimeEvaluator.init(allocator, case.source);
        try std.testing.expectError(case.expected, evaluator.evaluate());
    }

    const long_expression = try allocator.alloc(u8, 8193);
    defer allocator.free(long_expression);
    @memset(long_expression, '1');
    var long_evaluator = ComptimeEvaluator.init(allocator, long_expression);
    try std.testing.expectError(ComptimeError.ExpressionTooLong, long_evaluator.evaluate());

    const nesting = 65;
    const deep_expression = try allocator.alloc(u8, nesting * 2 + 1);
    defer allocator.free(deep_expression);
    @memset(deep_expression[0..nesting], '(');
    deep_expression[nesting] = '1';
    @memset(deep_expression[nesting + 1 ..], ')');
    var deep_evaluator = ComptimeEvaluator.init(allocator, deep_expression);
    try std.testing.expectError(ComptimeError.DepthExceeded, deep_evaluator.evaluate());
}

fn nestedJsonExpression(allocator: std.mem.Allocator, nesting: usize) ![]u8 {
    var json: std.ArrayList(u8) = .empty;
    defer json.deinit(allocator);
    for (0..nesting) |_| try json.append(allocator, '[');
    try json.append(allocator, '0');
    for (0..nesting) |_| try json.append(allocator, ']');
    return std.fmt.allocPrint(allocator, "JSON.parse(\"{s}\")", .{json.items});
}

test "JSON.parse root prefix stays inside the 64-node depth contract" {
    const allocator = std.testing.allocator;

    const accepted_source = try nestedJsonExpression(allocator, 63);
    defer allocator.free(accepted_source);
    var accepted = ComptimeEvaluator.init(allocator, accepted_source);
    const value = try accepted.evaluate();
    defer value.deinit(allocator);

    const rejected_source = try nestedJsonExpression(allocator, 64);
    defer allocator.free(rejected_source);
    var rejected = ComptimeEvaluator.init(allocator, rejected_source);
    try std.testing.expectError(ComptimeError.DepthExceeded, rejected.evaluate());
}

test "the comptime channel emits source text, which a Dict has none of" {
    // The measurement behind not landing spec 6.2's static-table form. This
    // channel's whole output is a literal spliced back into the program, and
    // every value it can produce has a spelling. `emitLiteral` over the value
    // model is the enumeration: a `Dict` is absent from it not because the
    // model is small but because spec 6.2 gives `Dict` no literal at all.
    const allocator = std.testing.allocator;

    // Every arm of the model round-trips through source and back.
    const spellable = [_][]const u8{
        "1",      "\"s\"",  "true", "null", "undefined", "NaN", "Infinity",
        "[1, 2]", "{a: 1}",
    };
    for (spellable) |source| {
        var evaluator = ComptimeEvaluator.init(allocator, source);
        const value = try evaluator.evaluate();
        defer value.deinit(allocator);
        const emitted = try emitLiteral(allocator, value);
        defer allocator.free(emitted);
        try std.testing.expect(emitted.len > 0);
    }

    // And the form spec 6.2 names fails loudly rather than evaluating to
    // something else. A silent answer here would be the dangerous outcome: the
    // duplicate-key check the form exists for would appear to have run.
    var refused = ComptimeEvaluator.init(allocator, "dictFromEntries([[\"a\", 1], [\"a\", 2]])");
    try std.testing.expectError(ComptimeError.UnknownIdentifier, refused.evaluate());
}

fn evaluateAllocationFixture(allocator: std.mem.Allocator, source: []const u8) !void {
    var evaluator = ComptimeEvaluator.init(allocator, source);
    const value = try evaluator.evaluate();
    defer value.deinit(allocator);
}

test "comptime evaluation cleans every aggregate and call allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        evaluateAllocationFixture,
        .{"[[\"owned\"], {nested: [\"value\"]}]"},
    );
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        evaluateAllocationFixture,
        .{"Math.max(1, 2, 3)"},
    );
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        evaluateAllocationFixture,
        .{"parseInt(\"42\", 10)"},
    );
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        evaluateAllocationFixture,
        .{"hash(\"owned\")"},
    );
}
