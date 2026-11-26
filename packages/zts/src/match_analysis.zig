//! Coverage analysis for `match` (spec 5.5).
//!
//! The analysis is Maranget's usefulness algorithm over a pattern matrix. An
//! arm is simplified to one of: anything, a literal, a type test, a fixed
//! record, or an array of exact length. Each column carries the type of the
//! values that reach it, and the type decides which constructors ("heads") a
//! value in that column can have. A match is exhaustive when a wildcard row is
//! not useful after the arms; an arm is redundant when it is not useful after
//! the arms before it.
//!
//! The model is the runtime as `emitMatchExpr` in `parser/codegen.zig` lowers it:
//!
//! - A record pattern, at every depth, first tests that the value is a record
//!   (a plain object or a `Result`), then reads its fields. A binding-only
//!   record pattern therefore does not cover a string.
//! - An array pattern, at every depth, tests the array shape, then the exact
//!   length, then the elements. A `T[]` has unbounded length, so only a
//!   `default:` or the `array` type test covers it.
//! - A field `_` is a presence check that fails on `undefined`. A field binding
//!   matches any value, `undefined` included. An array element `_` is a plain
//!   wildcard.
//! - A type test exists at the top level of an arm only.
//!
//! A type the model cannot enumerate is open: it is covered by a binding or a
//! `default:`, never by literals. A field the record type does not declare is
//! open for the same reason, because a structural record may carry more fields
//! at run time than its type names.
//!
//! The analysis spends a work budget. When it runs out, the match is reported
//! as not exhaustive and no redundancy verdict is made in either direction.

const std = @import("std");
const ir = @import("zts-engine").parser.ir;
const type_pool_mod = @import("type_pool.zig");
const type_env_mod = @import("type_env.zig");

const IrView = ir.IrView;
const NodeIndex = ir.NodeIndex;
const null_node = ir.null_node;
const TypePool = type_pool_mod.TypePool;
const TypeIndex = type_pool_mod.TypeIndex;
const TypeEnv = type_env_mod.TypeEnv;
const null_type_idx = type_pool_mod.null_type_idx;

/// Work units one analysis may spend per phase (exhaustiveness, then
/// redundancy). One unit is one matrix row visited, so a 255-arm match over 8
/// boolean fields uses a few hundred thousand and an ordinary match uses
/// hundreds.
pub const work_budget: u64 = 4_000_000;

/// Deepest chain of aliases or union members the type walk follows.
const max_resolve_depth: u8 = 8;

/// Deepest recursion of the usefulness walk. Patterns bound it in practice.
const max_walk_depth: u16 = 256;

/// True when the match has a catch-all `default:` arm, which the
/// parser records with a null pattern. A catch-all handles every residual case,
/// so its presence alone makes the match exhaustive. Single owner of the rule,
/// shared by the type checker and the strict checker.
pub fn hasDefaultArm(ir_view: IrView, me: ir.Node.MatchExpr) bool {
    for (0..me.arms_count) |i| {
        const arm_idx = ir_view.getListIndex(me.arms_start, @intCast(i));
        const arm = ir_view.getMatchArm(arm_idx) orelse continue;
        if (arm.pattern == null_node) return true;
    }
    return false;
}

/// Why an analysis could not reach a verdict.
pub const Incomplete = enum {
    /// The work budget ran out.
    budget,
    /// An arm held a pattern the model does not simplify.
    unmodelled,
    /// The type of the matched value is not known.
    untyped,
};

/// The first arm no value reaches.
pub const Redundant = struct {
    /// Index of the arm in source order.
    arm: u16,
    /// True when the arm is the `default:` arm.
    is_default: bool,
};

pub const Coverage = struct {
    /// True when a `default:` arm exists or the wildcard row is not useful.
    exhaustive: bool = false,
    /// Set when the analysis could not decide. Then `exhaustive` is false
    /// unless a `default:` arm exists, and `redundant` is null.
    incomplete: ?Incomplete = null,
    /// The first missing pattern, such as `{ kind: "c" }`, or the
    /// `.otherwise()` terminal for an open domain. Owned by the allocator given to
    /// `analyze`. Null when the match is exhaustive or no witness was found.
    witness: ?[]u8 = null,
    /// The first arm that no value can reach. Null when the analysis was
    /// incomplete.
    redundant: ?Redundant = null,

    pub fn deinit(self: *Coverage, allocator: std.mem.Allocator) void {
        if (self.witness) |w| allocator.free(w);
        self.* = .{};
    }
};

/// The one help string both checkers give for a match that is not exhaustive.
/// Deterministic: `edit_simulate` and the agent loop key on its text.
pub fn missingCaseHelp(allocator: std.mem.Allocator, coverage: Coverage) std.mem.Allocator.Error![]u8 {
    if (coverage.incomplete) |why| {
        return allocator.dupe(u8, switch (why) {
            .budget => "the analysis budget ran out before the arms were proved exhaustive. End the match with .otherwise(callback).",
            .unmodelled => "an arm uses a pattern the analysis does not model, so the arms were not proved exhaustive. End the match with .otherwise(callback).",
            .untyped => "the type of the matched value is not known, so the arms were not proved exhaustive. End the match with .otherwise(callback).",
        });
    }
    const witness = coverage.witness orelse
        return allocator.dupe(u8, "cover every case of the matched type, or end the match with .otherwise(callback).");
    if (std.mem.eql(u8, witness, ".otherwise()")) {
        return allocator.dupe(u8, "uncovered values remain. End the match with .otherwise(callback).");
    }
    return allocator.print("missing pattern: {s}. Add a .with(pattern, callback) arm, or end the match with .otherwise(callback).", .{witness});
}

pub const MatchAnalysis = struct {
    allocator: std.mem.Allocator,
    ir_view: IrView,
    pool: *TypePool,
    /// Resolves a named type to its definition. Without it, every named type
    /// is open.
    env: ?*const TypeEnv,
    budget: u64 = work_budget,

    pub fn init(allocator: std.mem.Allocator, ir_view: IrView, pool: *TypePool, env: ?*const TypeEnv) MatchAnalysis {
        return .{
            .allocator = allocator,
            .ir_view = ir_view,
            .pool = pool,
            .env = env,
        };
    }

    /// Decide exhaustiveness of `me`, and redundancy when `want_redundancy` is
    /// set. The witness in the result is allocated with `allocator`.
    pub fn analyze(
        self: *const MatchAnalysis,
        allocator: std.mem.Allocator,
        disc_type: TypeIndex,
        me: ir.Node.MatchExpr,
        want_redundancy: bool,
    ) std.mem.Allocator.Error!Coverage {
        var cov = Coverage{};
        const has_default = hasDefaultArm(self.ir_view, me);
        cov.exhaustive = has_default;
        if (disc_type == null_type_idx) {
            if (!has_default) cov.incomplete = .untyped;
            return cov;
        }

        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const a = arena.allocator();

        var simplifier = Simplifier{ .ir_view = self.ir_view, .alloc = a };
        const rows = try a.alloc(Row, me.arms_count);
        for (0..me.arms_count) |i| {
            const arm_idx = self.ir_view.getListIndex(me.arms_start, @intCast(i));
            const arm = self.ir_view.getMatchArm(arm_idx);
            const pat: SPat = if (arm) |m|
                (if (m.pattern == null_node) SPat.any else try simplifier.simplify(m.pattern, .top))
            else
                SPat.any;
            const row = try a.alloc(SPat, 1);
            row[0] = pat;
            rows[i] = row;
        }
        if (simplifier.unmodelled) {
            if (!has_default) cov.incomplete = .unmodelled;
            return cov;
        }

        const tys = [_]ColTy{.{ .ty = disc_type }};
        const wildcard = [_]SPat{.any};

        // Phase 1: exhaustiveness. A `default:` arm is the wildcard row, so
        // with one the wildcard is never useful and the phase is skipped.
        if (!has_default) {
            var engine = Engine{ .ma = self, .gpa = self.allocator, .budget = self.budget };
            const found = engine.useful(a, rows, &wildcard, &tys, 0) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.Exhausted => {
                    cov.incomplete = .budget;
                    return cov;
                },
            };
            if (found) |witness| {
                cov.witness = try self.renderTop(allocator, witness[0], disc_type);
            } else {
                cov.exhaustive = true;
            }
        }

        // Phase 2: redundancy, with a fresh budget. Exhaustion here drops the
        // redundancy verdict and keeps the exhaustiveness verdict.
        if (!want_redundancy) return cov;
        var engine = Engine{ .ma = self, .gpa = self.allocator, .budget = self.budget };
        for (0..me.arms_count) |i| {
            const useful_arm = engine.useful(a, rows[0..i], rows[i], &tys, 0) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.Exhausted => return cov,
            };
            if (useful_arm == null) {
                cov.redundant = .{ .arm = @intCast(i), .is_default = self.armIsDefault(me, i) };
                return cov;
            }
        }
        return cov;
    }

    fn armIsDefault(self: *const MatchAnalysis, me: ir.Node.MatchExpr, i: usize) bool {
        const arm_idx = self.ir_view.getListIndex(me.arms_start, @intCast(i));
        const arm = self.ir_view.getMatchArm(arm_idx) orelse return false;
        return arm.pattern == null_node;
    }

    // ---------------------------------------------------------------------
    // Narrowing (flow typing of an arm body)
    // ---------------------------------------------------------------------

    pub fn narrowTypeForPattern(self: *const MatchAnalysis, source_type: TypeIndex, pattern: NodeIndex) std.mem.Allocator.Error!TypeIndex {
        if (source_type == null_type_idx) return null_type_idx;
        if (pattern == null_node) return source_type;
        return self.matchedType(source_type, pattern, 0);
    }

    pub fn remainingTypeAfterPattern(self: *const MatchAnalysis, source_type: TypeIndex, pattern: NodeIndex) std.mem.Allocator.Error!TypeIndex {
        if (source_type == null_type_idx or pattern == null_node) return self.pool.idx_never;

        var remaining = std.ArrayList(TypeIndex).empty;
        defer remaining.deinit(self.allocator);
        try self.appendRemainingTypes(source_type, pattern, &remaining, 0);
        return switch (remaining.items.len) {
            0 => self.pool.idx_never,
            1 => remaining.items[0],
            else => self.pool.addUnion(self.allocator, remaining.items),
        };
    }

    fn matchedType(self: *const MatchAnalysis, source_type: TypeIndex, pattern: NodeIndex, depth: u16) std.mem.Allocator.Error!TypeIndex {
        if (depth >= max_walk_depth or pattern == null_node) return source_type;
        const resolved = if (self.env) |env| env.resolveRef(source_type) else source_type;
        if (resolved != source_type) return self.matchedType(resolved, pattern, depth + 1);
        const type_tag = self.pool.getTag(resolved) orelse return null_type_idx;
        // Scalar brands have no branded-literal representation. Keep their identity.
        if (self.pool.unwrapNominal(resolved) != resolved) {
            return if (self.patternCanMatchType(pattern, resolved)) resolved else null_type_idx;
        }
        if (type_tag == .t_union or type_tag == .t_nullable) {
            var variants = std.ArrayList(TypeIndex).empty;
            defer variants.deinit(self.allocator);
            try self.collectVariants(resolved, &variants);
            var matched = std.ArrayList(TypeIndex).empty;
            defer matched.deinit(self.allocator);
            for (variants.items) |variant| {
                const narrowed = try self.matchedType(variant, pattern, depth + 1);
                if (narrowed != null_type_idx and narrowed != self.pool.idx_never) try self.appendUnique(&matched, narrowed);
            }
            return switch (matched.items.len) {
                0 => null_type_idx,
                1 => matched.items[0],
                else => self.pool.addUnion(self.allocator, matched.items),
            };
        }

        const pattern_tag = self.ir_view.getTag(pattern) orelse return null_type_idx;
        if (type_tag == .t_intersection and pattern_tag == .match_pattern) {
            const structural = try self.structuralRecordForIntersection(resolved, depth + 1);
            if (structural != null_type_idx) {
                const refined = try self.matchedRecordType(structural, pattern, depth + 1);
                if (refined == null_type_idx or refined == self.pool.idx_never) return null_type_idx;
                if (self.patternFullyCoversType(pattern, structural)) return source_type;
                return self.pool.addIntersection(self.allocator, &.{ source_type, refined });
            }
        }
        if (type_tag == .t_intersection or
            type_tag == .t_generic_param or
            type_tag == .t_generic_app)
        {
            const refinement = try self.matchedType(self.pool.idx_unknown, pattern, depth + 1);
            if (refinement == null_type_idx or refinement == self.pool.idx_unknown) return source_type;
            return self.pool.addIntersection(self.allocator, &.{ source_type, refinement });
        }
        if (type_tag == .t_unknown_type) {
            return switch (pattern_tag) {
                .match_type_test => self.typeForTest(pattern),
                .lit_string => self.literalStringType(pattern),
                .lit_int => self.literalNumberType(pattern),
                .lit_float => self.pool.idx_number,
                .lit_bool => self.literalBoolType(pattern),
                .lit_null => self.pool.idx_null,
                .lit_undefined => self.pool.idx_undefined,
                .match_pattern => self.matchedUnknownRecordType(pattern, depth + 1),
                .array_pattern => self.matchedArrayType(resolved, pattern, depth + 1),
                // exhaustive: identifier wildcards retain unknown; other nodes supply no recognized refinement.
                else => source_type,
            };
        }
        return switch (pattern_tag) {
            .lit_string => if (self.stringPatternCanMatchType(pattern, resolved))
                self.literalStringType(pattern)
            else
                null_type_idx,
            .lit_int => if (self.intPatternCanMatchType(pattern, resolved))
                self.literalNumberType(pattern)
            else
                null_type_idx,
            .lit_float => if (self.floatPatternCanMatchType(pattern, resolved)) resolved else null_type_idx,
            .lit_bool => if (self.boolPatternCanMatchType(pattern, resolved))
                self.literalBoolType(pattern)
            else
                null_type_idx,
            .lit_null => if (type_tag == .t_null) resolved else null_type_idx,
            .lit_undefined => if (type_tag == .t_undefined) resolved else null_type_idx,
            .match_type_test => if (self.typeTestCoversType(pattern, resolved)) resolved else null_type_idx,
            .match_pattern => self.matchedRecordType(resolved, pattern, depth + 1),
            .array_pattern => self.matchedArrayType(resolved, pattern, depth + 1),
            .identifier => resolved,
            // exhaustive: non-pattern expressions cannot select a typed value.
            else => null_type_idx,
        };
    }

    fn structuralRecordForIntersection(
        self: *const MatchAnalysis,
        source_type: TypeIndex,
        depth: u16,
    ) std.mem.Allocator.Error!TypeIndex {
        if (depth >= max_walk_depth) return null_type_idx;
        var fields = std.ArrayList(type_pool_mod.RecordField).empty;
        defer fields.deinit(self.allocator);
        try self.appendIntersectionFields(source_type, &fields, depth + 1);
        if (fields.items.len == 0) return null_type_idx;
        return self.pool.addRecord(self.allocator, fields.items);
    }

    fn appendIntersectionFields(
        self: *const MatchAnalysis,
        source_type: TypeIndex,
        fields: *std.ArrayList(type_pool_mod.RecordField),
        depth: u16,
    ) std.mem.Allocator.Error!void {
        if (depth >= max_walk_depth) return;
        const resolved = if (self.env) |env| env.resolveRef(source_type) else source_type;
        const tag = self.pool.getTag(resolved) orelse return;
        if (tag == .t_intersection) {
            for (self.pool.getIntersectionMembers(resolved)) |member| {
                try self.appendIntersectionFields(member, fields, depth + 1);
            }
            return;
        }
        if (tag != .t_record) return;
        for (self.pool.getRecordFields(resolved)) |field| {
            const name = self.pool.getName(field.name_start, field.name_len);
            if (self.recordFieldIndex(fields.items, name)) |index| {
                fields.items[index].type_idx = self.pool.addIntersection(
                    self.allocator,
                    &.{ fields.items[index].type_idx, field.type_idx },
                );
                fields.items[index].optional = fields.items[index].optional and field.optional;
                fields.items[index].readonly = fields.items[index].readonly or field.readonly;
            } else {
                try fields.append(self.allocator, field);
            }
        }
    }

    fn appendRemainingTypes(
        self: *const MatchAnalysis,
        source_type: TypeIndex,
        pattern: NodeIndex,
        out: *std.ArrayList(TypeIndex),
        depth: u16,
    ) std.mem.Allocator.Error!void {
        if (depth >= max_walk_depth) return self.appendUnique(out, source_type);
        const resolved = if (self.env) |env| env.resolveRef(source_type) else source_type;
        if (resolved != source_type) return self.appendRemainingTypes(resolved, pattern, out, depth + 1);
        const type_tag = self.pool.getTag(resolved) orelse return;
        if (self.pool.unwrapNominal(resolved) != resolved) {
            if (!self.patternFullyCoversType(pattern, resolved)) try self.appendUnique(out, resolved);
            return;
        }
        if (type_tag == .t_union or type_tag == .t_nullable) {
            var variants = std.ArrayList(TypeIndex).empty;
            defer variants.deinit(self.allocator);
            try self.collectVariants(resolved, &variants);
            for (variants.items) |variant| try self.appendRemainingTypes(variant, pattern, out, depth + 1);
            return;
        }
        if (self.ir_view.getTag(pattern) == .match_pattern and type_tag == .t_record) {
            try self.appendRemainingRecordTypes(resolved, pattern, out, depth + 1);
            return;
        }
        if (type_tag == .t_boolean and self.ir_view.getTag(pattern) == .lit_bool) {
            const selected = self.ir_view.getBoolValue(pattern) orelse return self.appendUnique(out, resolved);
            return self.appendUnique(out, self.pool.addLiteralBool(self.allocator, !selected));
        }
        if (!self.patternFullyCoversType(pattern, resolved)) try self.appendUnique(out, resolved);
    }

    fn matchedRecordType(self: *const MatchAnalysis, source_type: TypeIndex, pattern: NodeIndex, depth: u16) std.mem.Allocator.Error!TypeIndex {
        if (self.pool.getTag(source_type) != .t_record) return null_type_idx;
        const record = self.ir_view.getMatchPattern(pattern) orelse return null_type_idx;
        const source_fields = self.pool.getRecordFields(source_type);
        var fields = std.ArrayList(type_pool_mod.RecordField).empty;
        defer fields.deinit(self.allocator);
        try fields.appendSlice(self.allocator, source_fields);
        for (0..record.props_count) |i| {
            const property_node = self.ir_view.getListIndex(record.props_start, @intCast(i));
            const property = self.ir_view.getProperty(property_node) orelse return null_type_idx;
            const name = self.patternPropertyName(property.key) orelse return null_type_idx;
            const field_index = self.recordFieldIndex(fields.items, name) orelse blk: {
                const added = try self.fieldForUnknownPattern(name, property.value, depth + 1);
                try fields.append(self.allocator, added);
                break :blk fields.items.len - 1;
            };
            const narrowed = if (property.value == null_node)
                try self.withoutUndefined(fields.items[field_index].type_idx, depth + 1)
            else
                try self.matchedType(fields.items[field_index].type_idx, property.value, depth + 1);
            if (narrowed == null_type_idx or narrowed == self.pool.idx_never) return null_type_idx;
            fields.items[field_index].type_idx = narrowed;
            fields.items[field_index].optional = false;
        }
        return self.pool.copyUnknownFieldMetadata(self.allocator, source_type, self.pool.addRecord(self.allocator, fields.items));
    }

    fn matchedUnknownRecordType(self: *const MatchAnalysis, pattern: NodeIndex, depth: u16) std.mem.Allocator.Error!TypeIndex {
        const record = self.ir_view.getMatchPattern(pattern) orelse return null_type_idx;
        var fields = std.ArrayList(type_pool_mod.RecordField).empty;
        defer fields.deinit(self.allocator);
        for (0..record.props_count) |i| {
            const property_node = self.ir_view.getListIndex(record.props_start, @intCast(i));
            const property = self.ir_view.getProperty(property_node) orelse return null_type_idx;
            const name = self.patternPropertyName(property.key) orelse return null_type_idx;
            try fields.append(self.allocator, try self.fieldForUnknownPattern(name, property.value, depth + 1));
        }
        return self.pool.markUnknownFieldRecord(
            self.allocator,
            self.pool.addRecord(self.allocator, fields.items),
        );
    }

    fn fieldForUnknownPattern(
        self: *const MatchAnalysis,
        name: []const u8,
        pattern: NodeIndex,
        depth: u16,
    ) std.mem.Allocator.Error!type_pool_mod.RecordField {
        const field_name = self.pool.addName(self.allocator, name);
        const field_type = if (pattern == null_node)
            self.pool.idx_unknown
        else
            try self.matchedType(self.pool.idx_unknown, pattern, depth + 1);
        return .{
            .name_start = field_name.start,
            .name_len = field_name.len,
            .type_idx = if (field_type == null_type_idx) self.pool.idx_unknown else field_type,
            .optional = false,
        };
    }

    fn matchedArrayType(self: *const MatchAnalysis, source_type: TypeIndex, pattern: NodeIndex, depth: u16) std.mem.Allocator.Error!TypeIndex {
        const array = self.ir_view.getArray(pattern) orelse return null_type_idx;
        const source_tag = self.pool.getTag(source_type) orelse return null_type_idx;
        const tuple_source = if (source_tag == .t_tuple) self.pool.getTupleElements(source_type) else &.{};
        if (source_tag == .t_tuple and tuple_source.len != array.elements_count) return null_type_idx;
        if (source_tag != .t_unknown_type and source_tag != .t_array and source_tag != .t_tuple) return null_type_idx;
        const elements = try self.allocator.alloc(TypeIndex, array.elements_count);
        defer self.allocator.free(elements);
        for (0..array.elements_count) |i| {
            const element_pattern = self.ir_view.getListIndex(array.elements_start, @intCast(i));
            const source_element = switch (source_tag) {
                .t_array => self.pool.getArrayElement(source_type),
                .t_tuple => tuple_source[i],
                // exhaustive: the source-tag guard leaves only an unknown source here.
                else => self.pool.idx_unknown,
            };
            elements[i] = if (element_pattern == null_node)
                source_element
            else
                try self.matchedType(source_element, element_pattern, depth + 1);
            if (elements[i] == null_type_idx or elements[i] == self.pool.idx_never) return null_type_idx;
        }
        const tuple = self.pool.addTuple(self.allocator, elements);
        return if (self.pool.isReadonlyArray(source_type) or self.pool.isReadonlyTuple(source_type))
            self.pool.addReadonlyTuple(self.allocator, tuple)
        else
            tuple;
    }

    fn appendRemainingRecordTypes(
        self: *const MatchAnalysis,
        source_type: TypeIndex,
        pattern: NodeIndex,
        out: *std.ArrayList(TypeIndex),
        depth: u16,
    ) std.mem.Allocator.Error!void {
        const record = self.ir_view.getMatchPattern(pattern) orelse return self.appendUnique(out, source_type);
        const source_fields = self.pool.getRecordFields(source_type);
        const prefix = try self.allocator.dupe(type_pool_mod.RecordField, source_fields);
        defer self.allocator.free(prefix);
        for (0..record.props_count) |i| {
            const property_node = self.ir_view.getListIndex(record.props_start, @intCast(i));
            const property = self.ir_view.getProperty(property_node) orelse return self.appendUnique(out, source_type);
            const name = self.patternPropertyName(property.key) orelse return self.appendUnique(out, source_type);
            const field_index = self.recordFieldIndex(prefix, name) orelse return self.appendUnique(out, source_type);
            const original = prefix[field_index];
            var field_remainders = std.ArrayList(TypeIndex).empty;
            defer field_remainders.deinit(self.allocator);
            const matched = if (property.value == null_node) blk: {
                if (original.optional or self.typeCanBeUndefined(original.type_idx)) {
                    try self.appendUnique(&field_remainders, self.pool.idx_undefined);
                }
                break :blk try self.withoutUndefined(original.type_idx, depth + 1);
            } else blk: {
                try self.appendRemainingTypes(original.type_idx, property.value, &field_remainders, depth + 1);
                if (original.optional and field_remainders.items.len == 0) {
                    try self.appendUnique(&field_remainders, self.pool.idx_never);
                }
                break :blk try self.matchedType(original.type_idx, property.value, depth + 1);
            };
            for (field_remainders.items) |field_type| {
                const failed_fields = try self.allocator.dupe(type_pool_mod.RecordField, prefix);
                defer self.allocator.free(failed_fields);
                failed_fields[field_index].type_idx = field_type;
                failed_fields[field_index].optional = original.optional;
                const failed = self.pool.copyUnknownFieldMetadata(self.allocator, source_type, self.pool.addRecord(self.allocator, failed_fields));
                try self.appendUnique(out, failed);
            }
            if (matched == null_type_idx or matched == self.pool.idx_never) return;
            prefix[field_index].type_idx = matched;
            prefix[field_index].optional = false;
        }
    }

    fn withoutUndefined(self: *const MatchAnalysis, source_type: TypeIndex, depth: u16) std.mem.Allocator.Error!TypeIndex {
        if (depth >= max_walk_depth) return source_type;
        const resolved = if (self.env) |env| env.resolveRef(source_type) else source_type;
        const tag = self.pool.getTag(resolved) orelse return null_type_idx;
        if (tag == .t_undefined) return self.pool.idx_never;
        if (tag == .t_nullable) return self.pool.getNullableInner(resolved);
        if (tag != .t_union) return resolved;
        var kept = std.ArrayList(TypeIndex).empty;
        defer kept.deinit(self.allocator);
        for (self.pool.getUnionMembers(resolved)) |member| {
            const present = try self.withoutUndefined(member, depth + 1);
            if (present != null_type_idx and present != self.pool.idx_never) try self.appendUnique(&kept, present);
        }
        return switch (kept.items.len) {
            0 => self.pool.idx_never,
            1 => kept.items[0],
            else => self.pool.addUnion(self.allocator, kept.items),
        };
    }

    fn typeForTest(self: *const MatchAnalysis, pattern: NodeIndex) TypeIndex {
        const type_test = self.ir_view.getMatchTypeTest(pattern) orelse return self.pool.idx_unknown;
        return switch (type_test.kind) {
            .boolean => self.pool.idx_boolean,
            .number => self.pool.idx_number,
            .string => self.pool.idx_string,
            .array => self.pool.addArray(self.allocator, self.pool.idx_unknown),
            .dict => self.pool.addDict(self.allocator, self.pool.idx_unknown, self.pool.idx_unknown),
            .bytes => self.pool.idx_bytes,
        };
    }

    fn literalStringType(self: *const MatchAnalysis, pattern: NodeIndex) TypeIndex {
        const value = self.patternString(pattern) orelse return null_type_idx;
        return self.pool.addLiteralString(self.allocator, value);
    }

    fn literalNumberType(self: *const MatchAnalysis, pattern: NodeIndex) TypeIndex {
        const value = self.ir_view.getIntValue(pattern) orelse return null_type_idx;
        return self.pool.addLiteralNumber(self.allocator, std.math.cast(i16, value) orelse return self.pool.idx_number);
    }

    fn literalBoolType(self: *const MatchAnalysis, pattern: NodeIndex) TypeIndex {
        return self.pool.addLiteralBool(self.allocator, self.ir_view.getBoolValue(pattern) orelse return null_type_idx);
    }

    fn recordFieldIndex(self: *const MatchAnalysis, fields: []const type_pool_mod.RecordField, name: []const u8) ?usize {
        for (fields, 0..) |field, index| {
            if (std.mem.eql(u8, self.pool.getName(field.name_start, field.name_len), name)) return index;
        }
        return null;
    }

    fn collectVariants(self: *const MatchAnalysis, type_idx: TypeIndex, out: *std.ArrayList(TypeIndex)) !void {
        if (type_idx == null_type_idx) return;

        const tag = self.pool.getTag(type_idx) orelse return;
        switch (tag) {
            .t_union => {
                for (self.pool.getUnionMembers(type_idx)) |member| {
                    try self.collectVariants(member, out);
                }
            },
            .t_nullable => {
                try self.collectVariants(self.pool.getNullableInner(type_idx), out);
                try self.appendUnique(out, self.pool.idx_undefined);
            },
            else => try self.appendUnique(out, type_idx),
        }
    }

    fn appendUnique(self: *const MatchAnalysis, out: *std.ArrayList(TypeIndex), type_idx: TypeIndex) !void {
        for (out.items) |existing| {
            if (existing == type_idx) return;
        }
        try out.append(self.allocator, type_idx);
    }

    /// Whether a pattern can match a value of the given type, for narrowing the
    /// type of the scrutinee inside an arm. This answers a flow-typing
    /// question, not a coverage one: a record pattern that names a field the
    /// record type does not declare is taken not to match that record, so the
    /// arm narrows to the members that do declare it. Coverage uses the more
    /// careful rule (an undeclared field is open).
    fn patternCanMatchType(self: *const MatchAnalysis, pattern: NodeIndex, type_idx: TypeIndex) bool {
        if (pattern == null_node or type_idx == null_type_idx) return pattern == null_node;

        // A named member narrows by its definition. Judging the bare name by its
        // tag would answer false for a name that can match, and the arm would lose
        // that member from its type.
        if (self.env) |env| {
            const resolved = env.resolveRef(type_idx);
            if (resolved != type_idx) return self.patternCanMatchType(pattern, resolved);
        }

        const type_tag = self.pool.getTag(type_idx) orelse return false;
        switch (type_tag) {
            .t_union => {
                for (self.pool.getUnionMembers(type_idx)) |member| {
                    if (self.patternCanMatchType(pattern, member)) return true;
                }
                return false;
            },
            .t_nullable => {
                if (self.patternCanMatchType(pattern, self.pool.getNullableInner(type_idx))) return true;
                return self.patternCanMatchType(pattern, self.pool.idx_undefined);
            },
            // Narrowing cannot judge these. Keeping the member widens the arm type,
            // and dropping it would narrow the arm below the values it can see.
            .t_intersection, .t_generic_param, .t_generic_app, .t_unknown_type => return true,
            // exhaustive: the remaining type tags are judged by the pattern tag below.
            else => {},
        }

        const pattern_tag = self.ir_view.getTag(pattern) orelse return false;
        return switch (pattern_tag) {
            .lit_string => self.stringPatternCanMatchType(pattern, type_idx),
            .lit_int => self.intPatternCanMatchType(pattern, type_idx),
            .lit_float => self.floatPatternCanMatchType(pattern, type_idx),
            .lit_bool => self.boolPatternCanMatchType(pattern, type_idx),
            .lit_null => type_tag == .t_null,
            .lit_undefined => type_tag == .t_undefined,
            .match_pattern => self.objectPatternCanMatchType(pattern, type_idx),
            .array_pattern => self.arrayPatternCanMatchType(pattern, type_idx),
            // A binding (spec 5.5) reads the field; it constrains nothing, so
            // it matches whatever the field holds - the same answer the
            // wildcard gives, with a name attached.
            .identifier => true,
            .match_type_test => self.typeTestCoversType(pattern, type_idx),
            // exhaustive: a pattern form with no rule here answers false for every member, so no member
            //     matches and narrowing is skipped.
            else => false,
        };
    }

    fn patternFullyCoversType(self: *const MatchAnalysis, pattern: NodeIndex, type_idx: TypeIndex) bool {
        if (pattern == null_node) return true;
        if (type_idx == null_type_idx) return false;
        if (self.env) |env| {
            const resolved = env.resolveRef(type_idx);
            if (resolved != type_idx) return self.patternFullyCoversType(pattern, resolved);
        }

        const type_tag = self.pool.getTag(type_idx) orelse return false;
        switch (type_tag) {
            .t_union => {
                for (self.pool.getUnionMembers(type_idx)) |member| {
                    if (!self.patternFullyCoversType(pattern, member)) return false;
                }
                return true;
            },
            .t_nullable => return self.patternFullyCoversType(pattern, self.pool.getNullableInner(type_idx)) and
                self.patternFullyCoversType(pattern, self.pool.idx_undefined),
            .t_intersection, .t_generic_param, .t_generic_app, .t_unknown_type => return false,
            // exhaustive: concrete types use the pattern checks below.
            else => {},
        }

        const pattern_tag = self.ir_view.getTag(pattern) orelse return false;
        return switch (pattern_tag) {
            .lit_string => type_tag == .t_literal_string and self.stringPatternCanMatchType(pattern, type_idx),
            .lit_int => type_tag == .t_literal_number and self.intPatternCanMatchType(pattern, type_idx),
            .lit_float => type_tag == .t_literal_number and self.floatPatternCanMatchType(pattern, type_idx),
            .lit_bool => type_tag == .t_literal_bool and self.boolPatternCanMatchType(pattern, type_idx),
            .lit_null => type_tag == .t_null,
            .lit_undefined => type_tag == .t_undefined,
            .identifier => true,
            .match_type_test => self.typeTestCoversType(pattern, type_idx),
            .match_pattern => self.objectPatternFullyCoversType(pattern, type_idx),
            .array_pattern => self.arrayPatternFullyCoversType(pattern, type_idx),
            // exhaustive: non-pattern expressions establish no coverage.
            else => false,
        };
    }

    fn objectPatternFullyCoversType(self: *const MatchAnalysis, pattern: NodeIndex, type_idx: TypeIndex) bool {
        if (self.pool.getTag(type_idx) != .t_record) return false;
        const match_pattern = self.ir_view.getMatchPattern(pattern) orelse return false;
        for (0..match_pattern.props_count) |i| {
            const prop_idx = self.ir_view.getListIndex(match_pattern.props_start, @intCast(i));
            const prop = self.ir_view.getProperty(prop_idx) orelse return false;
            const prop_name = self.patternPropertyName(prop.key) orelse return false;
            const field = self.findRecordField(type_idx, prop_name) orelse return false;
            if (field.optional) return false;
            if (prop.value == null_node) {
                if (self.typeCanBeUndefined(field.type_idx)) return false;
                continue;
            }
            if (!self.patternFullyCoversType(prop.value, field.type_idx)) return false;
        }
        return true;
    }

    fn arrayPatternFullyCoversType(self: *const MatchAnalysis, pattern: NodeIndex, type_idx: TypeIndex) bool {
        if (self.pool.getTag(type_idx) != .t_tuple) return false;
        const array = self.ir_view.getArray(pattern) orelse return false;
        const members = self.pool.getTupleElements(type_idx);
        if (members.len != array.elements_count) return false;
        for (0..array.elements_count) |i| {
            const element = self.ir_view.getListIndex(array.elements_start, @intCast(i));
            if (element != null_node and !self.patternFullyCoversType(element, members[i])) return false;
        }
        return true;
    }

    fn typeCanBeUndefined(self: *const MatchAnalysis, type_idx: TypeIndex) bool {
        const resolved = if (self.env) |env| env.resolveRef(type_idx) else type_idx;
        return switch (self.pool.getTag(resolved) orelse return true) {
            .t_undefined, .t_nullable, .t_unknown_type, .t_generic_param, .t_generic_app => true,
            .t_union => blk: {
                for (self.pool.getUnionMembers(resolved)) |member| {
                    if (self.typeCanBeUndefined(member)) break :blk true;
                }
                break :blk false;
            },
            // exhaustive: concrete non-union types other than undefined cannot contain undefined.
            else => false,
        };
    }

    /// A type-test pattern (spec 5.5) selects the value kind it names: it
    /// matches a union member of that kind, so `string` answers for `string`
    /// and for the literal `"a"`, and `array` answers for an array or a fixed
    /// tuple.
    fn typeTestCoversType(self: *const MatchAnalysis, pattern: NodeIndex, type_idx: TypeIndex) bool {
        const test_node = self.ir_view.getMatchTypeTest(pattern) orelse return false;
        const type_tag = self.pool.getTag(type_idx) orelse return false;
        return switch (test_node.kind) {
            .boolean => type_tag == .t_boolean or type_tag == .t_literal_bool,
            .number => type_tag == .t_number or type_tag == .t_literal_number,
            .string => type_tag == .t_string or type_tag == .t_literal_string or type_tag == .t_template_literal,
            .array => type_tag == .t_array or type_tag == .t_tuple,
            .dict => type_tag == .t_dict,
            .bytes => type_tag == .t_bytes,
        };
    }

    fn stringPatternCanMatchType(self: *const MatchAnalysis, pattern: NodeIndex, type_idx: TypeIndex) bool {
        const type_tag = self.pool.getTag(type_idx) orelse return false;
        return switch (type_tag) {
            .t_string => true,
            // A template literal type holds strings, and the pattern text is not matched
            // against its parts here. Keeping it widens the arm type.
            .t_template_literal => true,
            .t_literal_string => blk: {
                const pattern_str = self.patternString(pattern) orelse break :blk false;
                const data = self.pool.getData(type_idx) orelse break :blk false;
                break :blk std.mem.eql(u8, pattern_str, self.pool.getName(data.a, @truncate(data.b)));
            },
            // exhaustive: any other type tag cannot hold a string.
            else => false,
        };
    }

    fn intPatternCanMatchType(self: *const MatchAnalysis, pattern: NodeIndex, type_idx: TypeIndex) bool {
        const type_tag = self.pool.getTag(type_idx) orelse return false;
        return switch (type_tag) {
            .t_number => true,
            .t_literal_number => blk: {
                const pattern_int = self.ir_view.getIntValue(pattern) orelse break :blk false;
                const pattern_i16 = std.math.cast(i16, pattern_int) orelse break :blk false;
                const data = self.pool.getData(type_idx) orelse break :blk false;
                const member_val: i16 = @bitCast(data.a);
                break :blk member_val == pattern_i16;
            },
            // exhaustive: any other type tag cannot hold an integer.
            else => false,
        };
    }

    fn floatPatternCanMatchType(self: *const MatchAnalysis, pattern: NodeIndex, type_idx: TypeIndex) bool {
        const float_index = self.ir_view.getFloatIdx(pattern) orelse return false;
        const pattern_value = self.ir_view.getFloat(float_index) orelse return false;
        return switch (self.pool.getTag(type_idx) orelse return false) {
            .t_number => true,
            .t_literal_number => blk: {
                const data = self.pool.getData(type_idx) orelse break :blk false;
                const member_value: i16 = @bitCast(data.a);
                break :blk pattern_value == @as(f64, @floatFromInt(member_value));
            },
            // exhaustive: other type tags cannot hold a number.
            else => false,
        };
    }

    fn boolPatternCanMatchType(self: *const MatchAnalysis, pattern: NodeIndex, type_idx: TypeIndex) bool {
        const type_tag = self.pool.getTag(type_idx) orelse return false;
        return switch (type_tag) {
            .t_boolean => true,
            .t_literal_bool => blk: {
                const pattern_bool = self.ir_view.getBoolValue(pattern) orelse break :blk false;
                const data = self.pool.getData(type_idx) orelse break :blk false;
                break :blk (data.a != 0) == pattern_bool;
            },
            // exhaustive: any other type tag cannot hold a boolean.
            else => false,
        };
    }

    fn objectPatternCanMatchType(self: *const MatchAnalysis, pattern: NodeIndex, type_idx: TypeIndex) bool {
        if (self.pool.getTag(type_idx) != .t_record) return false;

        const match_pattern = self.ir_view.getMatchPattern(pattern) orelse return false;
        for (0..match_pattern.props_count) |i| {
            const prop_idx = self.ir_view.getListIndex(match_pattern.props_start, @intCast(i));
            const prop = self.ir_view.getProperty(prop_idx) orelse return false;
            const prop_name = self.patternPropertyName(prop.key) orelse return false;
            const field = self.findRecordField(type_idx, prop_name) orelse return false;
            if (!self.patternCanMatchType(prop.value, field.type_idx)) return false;
        }
        return true;
    }

    fn arrayPatternCanMatchType(self: *const MatchAnalysis, pattern: NodeIndex, type_idx: TypeIndex) bool {
        const array = self.ir_view.getArray(pattern) orelse return false;
        const type_tag = self.pool.getTag(type_idx) orelse return false;

        return switch (type_tag) {
            .t_tuple => blk: {
                const members = self.pool.getTupleElements(type_idx);
                if (members.len != array.elements_count) break :blk false;
                for (0..array.elements_count) |i| {
                    const elem_pattern = self.ir_view.getListIndex(array.elements_start, @intCast(i));
                    if (!self.patternCanMatchType(elem_pattern, members[i])) break :blk false;
                }
                break :blk true;
            },
            .t_array => blk: {
                const elem_type = self.pool.getArrayElement(type_idx);
                for (0..array.elements_count) |i| {
                    const elem_pattern = self.ir_view.getListIndex(array.elements_start, @intCast(i));
                    if (!self.patternCanMatchType(elem_pattern, elem_type)) break :blk false;
                }
                break :blk true;
            },
            // exhaustive: only a tuple or an array can match an array pattern.
            else => false,
        };
    }

    fn patternString(self: *const MatchAnalysis, pattern: NodeIndex) ?[]const u8 {
        const str_idx = self.ir_view.getStringIdx(pattern) orelse return null;
        return self.ir_view.getString(str_idx);
    }

    fn patternPropertyName(self: *const MatchAnalysis, node: NodeIndex) ?[]const u8 {
        const tag = self.ir_view.getTag(node) orelse return null;
        return switch (tag) {
            .lit_string => self.patternString(node),
            // exhaustive: only a string literal names a record field. Any other key form names none, and the
            //     caller answers false.
            else => null,
        };
    }

    fn findRecordField(self: *const MatchAnalysis, record_type: TypeIndex, name: []const u8) ?type_pool_mod.RecordField {
        for (self.pool.getRecordFields(record_type)) |field| {
            const field_name = self.pool.getName(field.name_start, field.name_len);
            if (std.mem.eql(u8, field_name, name)) return field;
        }
        return null;
    }

    // ---------------------------------------------------------------------
    // Witness rendering
    // ---------------------------------------------------------------------

    /// Render a pattern for the whole scrutinee, or the fallback terminal
    /// where no pattern names the missing values.
    fn renderTop(self: *const MatchAnalysis, allocator: std.mem.Allocator, w: Witness, disc_type: TypeIndex) std.mem.Allocator.Error![]u8 {
        var list = std.ArrayList(u8).empty;
        errdefer list.deinit(allocator);

        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        var engine = Engine{ .ma = self, .gpa = self.allocator, .budget = work_budget };
        var members = std.ArrayList(Member).empty;
        var open = false;
        engine.collectMembers(arena.allocator(), disc_type, &members, &open, 0) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            // `collectMembers` spends no budget; the arm is unreachable.
            error.Exhausted => open = true,
        };
        const families = familyCount(members.items);

        switch (w) {
            .any, .other => try list.appendSlice(allocator, ".otherwise()"),
            .other_string => try list.appendSlice(allocator, if (open or families <= 1) ".otherwise()" else "P.string"),
            .other_number => try list.appendSlice(allocator, if (open or families <= 1) ".otherwise()" else "P.number"),
            .other_array => try list.appendSlice(allocator, if (open or families <= 1) ".otherwise()" else "P.array"),
            else => if (open)
                try list.appendSlice(allocator, ".otherwise()")
            else
                try writeWitness(allocator, &list, w, .subject),
        }
        return list.toOwnedSlice(allocator);
    }
};

// -------------------------------------------------------------------------
// Simplified patterns
// -------------------------------------------------------------------------

const Lit = union(enum) {
    str: []const u8,
    num: f64,
    boolean: bool,
    null_,
    undef,
};

const FieldPat = struct {
    name: []const u8,
    pat: SPat,
};

const SPat = union(enum) {
    /// A binding, an array element `_`, or the `default:` arm.
    any,
    /// A record field `_`: anything except `undefined`.
    present,
    lit: Lit,
    /// A top-level type test.
    kind: ir.Node.TypeTestKind,
    record: []const FieldPat,
    array: []const SPat,
};

const Row = []const SPat;

const Context = enum { top, field, elem };

const Simplifier = struct {
    ir_view: IrView,
    alloc: std.mem.Allocator,
    unmodelled: bool = false,

    fn simplify(self: *Simplifier, pattern: NodeIndex, ctx: Context) std.mem.Allocator.Error!SPat {
        if (pattern == null_node) {
            return switch (ctx) {
                .top, .elem => .any,
                .field => .present,
            };
        }
        const tag = self.ir_view.getTag(pattern) orelse {
            self.unmodelled = true;
            return .any;
        };
        switch (tag) {
            .identifier => return .any,
            .lit_string => {
                const idx = self.ir_view.getStringIdx(pattern) orelse return self.refuse();
                const s = self.ir_view.getString(idx) orelse return self.refuse();
                return .{ .lit = .{ .str = s } };
            },
            .lit_int => {
                const v = self.ir_view.getIntValue(pattern) orelse return self.refuse();
                return .{ .lit = .{ .num = @floatFromInt(v) } };
            },
            .lit_float => {
                const idx = self.ir_view.getFloatIdx(pattern) orelse return self.refuse();
                const v = self.ir_view.getFloat(idx) orelse return self.refuse();
                return .{ .lit = .{ .num = v } };
            },
            .lit_bool => {
                const v = self.ir_view.getBoolValue(pattern) orelse return self.refuse();
                return .{ .lit = .{ .boolean = v } };
            },
            .lit_null => return .{ .lit = .null_ },
            .lit_undefined => return .{ .lit = .undef },
            .match_type_test => {
                const t = self.ir_view.getMatchTypeTest(pattern) orelse return self.refuse();
                return .{ .kind = t.kind };
            },
            .match_pattern => {
                const mp = self.ir_view.getMatchPattern(pattern) orelse return self.refuse();
                const fields = try self.alloc.alloc(FieldPat, mp.props_count);
                var n: usize = 0;
                for (0..mp.props_count) |i| {
                    const prop_idx = self.ir_view.getListIndex(mp.props_start, @intCast(i));
                    const prop = self.ir_view.getProperty(prop_idx) orelse return self.refuse();
                    const key_tag = self.ir_view.getTag(prop.key) orelse return self.refuse();
                    if (key_tag != .lit_string) return self.refuse();
                    const key_idx = self.ir_view.getStringIdx(prop.key) orelse return self.refuse();
                    const name = self.ir_view.getString(key_idx) orelse return self.refuse();
                    for (fields[0..n]) |seen| {
                        // The same field named twice is a conjunction the
                        // matrix does not express.
                        if (std.mem.eql(u8, seen.name, name)) return self.refuse();
                    }
                    fields[n] = .{ .name = name, .pat = try self.simplify(prop.value, .field) };
                    n += 1;
                }
                return .{ .record = fields };
            },
            .array_pattern => {
                const arr = self.ir_view.getArray(pattern) orelse return self.refuse();
                const elems = try self.alloc.alloc(SPat, arr.elements_count);
                for (0..arr.elements_count) |i| {
                    const elem = self.ir_view.getListIndex(arr.elements_start, @intCast(i));
                    elems[i] = try self.simplify(elem, .elem);
                }
                return .{ .array = elems };
            },
            // exhaustive: an unmodelled pattern sets `unmodelled`, which reports the match as not exhaustive.
            else => return self.refuse(),
        }
    }

    fn refuse(self: *Simplifier) SPat {
        self.unmodelled = true;
        return .any;
    }
};

// -------------------------------------------------------------------------
// Types of columns and the constructors a value can have
// -------------------------------------------------------------------------

/// The type of the values in one matrix column. `opt` adds `undefined`, for an
/// optional field.
const ColTy = struct {
    ty: TypeIndex,
    opt: bool = false,
};

/// One alternative of a type, after unions, nullable types, and named types
/// are expanded.
const Member = union(enum) {
    boolean,
    number,
    string,
    lit_str: []const u8,
    lit_num: f64,
    lit_bool: bool,
    null_,
    undef,
    /// A record type, or `null_type_idx` for a record of unknown shape.
    record: TypeIndex,
    /// An array of this element type.
    array: TypeIndex,
    /// A fixed tuple type.
    tuple: TypeIndex,
    dict,
    bytes,
    function,
};

const Elem = union(enum) {
    uniform: TypeIndex,
    tuple: TypeIndex,
};

/// One constructor a value in a column can have. A head that stands for "every
/// value not listed" (`str_other`, `num_other`, `array_other`) makes an open
/// type impossible to cover with literals.
const Head = union(enum) {
    str: []const u8,
    str_other,
    num: f64,
    num_other,
    boolean: bool,
    null_,
    undef,
    record: TypeIndex,
    array: struct { len: u32, elem: Elem },
    array_other: TypeIndex,
    dict,
    bytes,
    function,
};

fn elemEql(a: Elem, b: Elem) bool {
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
    return switch (a) {
        .uniform => |t| t == b.uniform,
        .tuple => |t| t == b.tuple,
    };
}

fn headEql(a: Head, b: Head) bool {
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
    return switch (a) {
        .str => |s| std.mem.eql(u8, s, b.str),
        .num => |n| n == b.num,
        .boolean => |x| x == b.boolean,
        .record => |t| t == b.record,
        .array => |x| x.len == b.array.len and elemEql(x.elem, b.array.elem),
        .array_other => |t| t == b.array_other,
        .str_other, .num_other, .null_, .undef, .dict, .bytes, .function => true,
    };
}

/// How many kinds of value a member list holds: the kinds a type test or a
/// literal names. One kind means a `default:` arm and a type test cover the
/// same values, so the witness calls for `.otherwise()`.
fn familyCount(members: []const Member) usize {
    var seen = @as([10]bool, @splat(false));
    for (members) |m| {
        const i: usize = switch (m) {
            .boolean, .lit_bool => 0,
            .number, .lit_num => 1,
            .string, .lit_str => 2,
            .null_ => 3,
            .undef => 4,
            .record => 5,
            .array, .tuple => 6,
            .dict => 7,
            .bytes => 8,
            .function => 9,
        };
        seen[i] = true;
    }
    var n: usize = 0;
    for (seen) |s| {
        if (s) n += 1;
    }
    return n;
}

// -------------------------------------------------------------------------
// Witnesses
// -------------------------------------------------------------------------

const FieldW = struct {
    name: []const u8,
    w: Witness,
};

const Witness = union(enum) {
    /// No constraint.
    any,
    /// A value of an open kind that no pattern lists.
    other,
    other_string,
    other_number,
    other_array,
    lit_str: []const u8,
    lit_num: f64,
    lit_bool: bool,
    null_,
    undef,
    kind_dict,
    kind_bytes,
    record: []const FieldW,
    array: []const Witness,
};

fn cloneWitness(a: std.mem.Allocator, w: Witness) std.mem.Allocator.Error!Witness {
    switch (w) {
        .record => |fields| {
            const out = try a.alloc(FieldW, fields.len);
            for (fields, 0..) |f, i| out[i] = .{ .name = f.name, .w = try cloneWitness(a, f.w) };
            return .{ .record = out };
        },
        .array => |elems| {
            const out = try a.alloc(Witness, elems.len);
            for (elems, 0..) |e, i| out[i] = try cloneWitness(a, e);
            return .{ .array = out };
        },
        // exhaustive: every other witness is a leaf that owns no allocation to copy.
        else => return w,
    }
}

fn writeNumber(a: std.mem.Allocator, list: *std.ArrayList(u8), n: f64) std.mem.Allocator.Error!void {
    if (@floor(n) == n and @abs(n) < 1e15) {
        const i: i64 = @intFromFloat(n);
        try list.print(a, "{d}", .{i});
    } else {
        try list.print(a, "{d}", .{n});
    }
}

fn writeString(a: std.mem.Allocator, list: *std.ArrayList(u8), s: []const u8) std.mem.Allocator.Error!void {
    try list.append(a, '"');
    for (s) |c| {
        switch (c) {
            '"' => try list.appendSlice(a, "\\\""),
            '\\' => try list.appendSlice(a, "\\\\"),
            '\n' => try list.appendSlice(a, "\\n"),
            else => try list.append(a, c),
        }
    }
    try list.append(a, '"');
}

const WitnessPosition = enum { subject, field, element };

fn writeWitness(a: std.mem.Allocator, list: *std.ArrayList(u8), w: Witness, position: WitnessPosition) std.mem.Allocator.Error!void {
    const wildcard = if (position == .element) "P.any" else "P.present";
    switch (w) {
        .any, .other, .other_string, .other_number, .other_array => try list.appendSlice(a, wildcard),
        .lit_str => |s| try writeString(a, list, s),
        .lit_num => |n| try writeNumber(a, list, n),
        .lit_bool => |b| try list.appendSlice(a, if (b) "true" else "false"),
        .null_ => try list.appendSlice(a, "null"),
        .undef => try list.appendSlice(a, "undefined"),
        .kind_dict => try list.appendSlice(a, if (position == .subject) "P.Dict" else wildcard),
        .kind_bytes => try list.appendSlice(a, if (position == .subject) "P.Bytes" else wildcard),
        .record => |fields| {
            var first = true;
            try list.append(a, '{');
            for (fields) |f| {
                if (f.w == .any) continue;
                try list.appendSlice(a, if (first) " " else ", ");
                first = false;
                try list.appendSlice(a, f.name);
                try list.appendSlice(a, ": ");
                try writeWitness(a, list, f.w, .field);
            }
            try list.appendSlice(a, if (first) "}" else " }");
        },
        .array => |elems| {
            try list.append(a, '[');
            for (elems, 0..) |e, i| {
                if (i > 0) try list.appendSlice(a, ", ");
                try writeWitness(a, list, e, .element);
            }
            try list.append(a, ']');
        },
    }
}

// -------------------------------------------------------------------------
// The usefulness walk
// -------------------------------------------------------------------------

const Error = error{ OutOfMemory, Exhausted };

const Engine = struct {
    ma: *const MatchAnalysis,
    gpa: std.mem.Allocator,
    spent: u64 = 0,
    budget: u64,

    fn charge(self: *Engine, n: usize) Error!void {
        self.spent +|= n;
        if (self.spent > self.budget) return error.Exhausted;
    }

    /// Expand a column type into its alternatives.
    fn collectColumn(self: *Engine, a: std.mem.Allocator, ct: ColTy, out: *std.ArrayList(Member), open: *bool) Error!void {
        try self.collectMembers(a, ct.ty, out, open, 0);
        if (ct.opt) try out.append(a, .undef);
    }

    fn appendUnknown(a: std.mem.Allocator, out: *std.ArrayList(Member), unknown_elem: TypeIndex) Error!void {
        try out.appendSlice(a, &.{
            .boolean,
            .number,
            .string,
            .null_,
            .undef,
            .{ .record = null_type_idx },
            .{ .array = unknown_elem },
            .dict,
            .bytes,
            .function,
        });
    }

    fn collectMembers(self: *Engine, a: std.mem.Allocator, ty: TypeIndex, out: *std.ArrayList(Member), open: *bool, depth: u8) Error!void {
        const pool = self.ma.pool;
        if (depth > max_resolve_depth) {
            open.* = true;
            return appendUnknown(a, out, pool.idx_unknown);
        }
        const tag = pool.getTag(ty) orelse {
            open.* = true;
            return appendUnknown(a, out, pool.idx_unknown);
        };
        switch (tag) {
            .t_union => {
                for (pool.getUnionMembers(ty)) |m| try self.collectMembers(a, m, out, open, depth + 1);
            },
            .t_nullable => {
                try self.collectMembers(a, pool.getNullableInner(ty), out, open, depth + 1);
                try out.append(a, .undef);
            },
            .t_ref => {
                const resolved = if (self.ma.env) |env| env.resolveRef(ty) else ty;
                if (resolved == ty) {
                    open.* = true;
                    return appendUnknown(a, out, pool.idx_unknown);
                }
                try self.collectMembers(a, resolved, out, open, depth + 1);
            },
            .t_boolean => try out.append(a, .boolean),
            .t_number => try out.append(a, .number),
            .t_string, .t_template_literal => try out.append(a, .string),
            .t_literal_string => {
                if (pool.getLiteralStringValue(ty)) |s| {
                    try out.append(a, .{ .lit_str = s });
                } else {
                    try out.append(a, .string);
                }
            },
            .t_literal_number => {
                const data = pool.getData(ty) orelse {
                    try out.append(a, .number);
                    return;
                };
                const v: i16 = @bitCast(data.a);
                try out.append(a, .{ .lit_num = @floatFromInt(v) });
            },
            .t_literal_bool => {
                const data = pool.getData(ty) orelse {
                    try out.append(a, .boolean);
                    return;
                };
                try out.append(a, .{ .lit_bool = data.a != 0 });
            },
            .t_null => try out.append(a, .null_),
            .t_undefined, .t_void => try out.append(a, .undef),
            .t_never => {},
            .t_record => try out.append(a, .{ .record = ty }),
            .t_array => {
                const elem = pool.getArrayElement(ty);
                try out.append(a, .{ .array = if (elem == null_type_idx) pool.idx_unknown else elem });
            },
            .t_tuple => try out.append(a, .{ .tuple = ty }),
            .t_dict => try out.append(a, .dict),
            .t_bytes => try out.append(a, .bytes),
            .t_function => try out.append(a, .function),
            // Types the model cannot enumerate: a value of one of these may be
            // anything, so only a binding or a `default:` covers it.
            .t_unknown_type, .t_generic_app, .t_generic_param, .t_intersection, .t_error => {
                open.* = true;
                try appendUnknown(a, out, pool.idx_unknown);
            },
        }
    }

    fn appendHead(a: std.mem.Allocator, out: *std.ArrayList(Head), h: Head) Error!void {
        for (out.items) |existing| {
            if (headEql(existing, h)) return;
        }
        try out.append(a, h);
    }

    /// The constructors a value in this column can have. Literals and array
    /// lengths that the column's patterns name become heads of the open kinds
    /// they belong to; everything else of that kind is one `*_other` head.
    fn headsOf(self: *Engine, a: std.mem.Allocator, members: []const Member, rows: []const Row, q0: SPat) Error![]const Head {
        var strs = std.ArrayList([]const u8).empty;
        var nums = std.ArrayList(f64).empty;
        var lens = std.ArrayList(u32).empty;
        for (rows) |row| try gatherLiterals(a, row[0], &strs, &nums, &lens);
        try gatherLiterals(a, q0, &strs, &nums, &lens);

        var out = std.ArrayList(Head).empty;
        for (members) |m| {
            switch (m) {
                .boolean => {
                    try appendHead(a, &out, .{ .boolean = true });
                    try appendHead(a, &out, .{ .boolean = false });
                },
                .number => {
                    for (nums.items) |n| try appendHead(a, &out, .{ .num = n });
                    try appendHead(a, &out, .num_other);
                },
                .string => {
                    for (strs.items) |s| try appendHead(a, &out, .{ .str = s });
                    try appendHead(a, &out, .str_other);
                },
                .lit_str => |s| try appendHead(a, &out, .{ .str = s }),
                .lit_num => |n| try appendHead(a, &out, .{ .num = n }),
                .lit_bool => |b| try appendHead(a, &out, .{ .boolean = b }),
                .null_ => try appendHead(a, &out, .null_),
                .undef => try appendHead(a, &out, .undef),
                .record => |t| try appendHead(a, &out, .{ .record = t }),
                .array => |elem| {
                    for (lens.items) |len| try appendHead(a, &out, .{ .array = .{ .len = len, .elem = .{ .uniform = elem } } });
                    try appendHead(a, &out, .{ .array_other = elem });
                },
                .tuple => |t| {
                    const len: u32 = @intCast(self.ma.pool.getTupleElements(t).len);
                    try appendHead(a, &out, .{ .array = .{ .len = len, .elem = .{ .tuple = t } } });
                },
                .dict => try appendHead(a, &out, .dict),
                .bytes => try appendHead(a, &out, .bytes),
                .function => try appendHead(a, &out, .function),
            }
        }
        return out.items;
    }

    fn gatherLiterals(
        a: std.mem.Allocator,
        p: SPat,
        strs: *std.ArrayList([]const u8),
        nums: *std.ArrayList(f64),
        lens: *std.ArrayList(u32),
    ) Error!void {
        switch (p) {
            .lit => |l| switch (l) {
                .str => |s| {
                    for (strs.items) |e| if (std.mem.eql(u8, e, s)) return;
                    try strs.append(a, s);
                },
                .num => |n| {
                    for (nums.items) |e| if (e == n) return;
                    try nums.append(a, n);
                },
                // exhaustive: other literal kinds give the head split no string or number to split on.
                else => {},
            },
            .array => |elems| {
                const len: u32 = @intCast(elems.len);
                for (lens.items) |e| if (e == len) return;
                try lens.append(a, len);
            },
            // exhaustive: other patterns give the head split no string, number, or length to split on.
            else => {},
        }
    }

    fn headMatches(h: Head, p: SPat) bool {
        return switch (p) {
            .any => true,
            .present => h != .undef,
            .lit => |l| switch (l) {
                .str => |s| h == .str and std.mem.eql(u8, h.str, s),
                .num => |n| h == .num and h.num == n,
                .boolean => |b| h == .boolean and h.boolean == b,
                .null_ => h == .null_,
                .undef => h == .undef,
            },
            .kind => |k| switch (k) {
                .boolean => h == .boolean,
                .number => h == .num or h == .num_other,
                .string => h == .str or h == .str_other,
                .array => h == .array or h == .array_other,
                .dict => h == .dict,
                .bytes => h == .bytes,
            },
            .record => h == .record,
            .array => |elems| h == .array and h.array.len == elems.len,
        };
    }

    fn isLiteralType(self: *const Engine, ty: TypeIndex) bool {
        const tag = self.ma.pool.getTag(ty) orelse return false;
        return tag == .t_literal_string or tag == .t_literal_number or tag == .t_literal_bool;
    }

    /// The fields a record head is split into: every field a pattern in the
    /// column names, and, when the column holds several record types, each
    /// literal-typed field of this one, so a missing case can name its
    /// discriminant.
    fn recordFields(
        self: *Engine,
        a: std.mem.Allocator,
        rows: []const Row,
        q0: SPat,
        record_type: TypeIndex,
        record_heads: usize,
    ) Error![]const []const u8 {
        var names = std.ArrayList([]const u8).empty;
        for (rows) |row| try addPatternFields(a, row[0], &names);
        try addPatternFields(a, q0, &names);
        if (record_heads >= 2 and record_type != null_type_idx) {
            for (self.ma.pool.getRecordFields(record_type)) |f| {
                if (f.optional or !self.isLiteralType(f.type_idx)) continue;
                try addName(a, &names, self.ma.pool.getName(f.name_start, f.name_len));
            }
        }
        return names.items;
    }

    fn addPatternFields(a: std.mem.Allocator, p: SPat, names: *std.ArrayList([]const u8)) Error!void {
        switch (p) {
            .record => |fields| for (fields) |f| try addName(a, names, f.name),
            // exhaustive: only a record pattern names fields.
            else => {},
        }
    }

    fn addName(a: std.mem.Allocator, names: *std.ArrayList([]const u8), name: []const u8) Error!void {
        for (names.items) |e| if (std.mem.eql(u8, e, name)) return;
        try names.append(a, name);
    }

    fn fieldColTy(self: *Engine, record_type: TypeIndex, name: []const u8) ColTy {
        const pool = self.ma.pool;
        if (record_type == null_type_idx) return .{ .ty = pool.idx_unknown };
        const field = pool.lookupRecordField(record_type, name) orelse return .{ .ty = pool.idx_unknown };
        return .{ .ty = field.type_idx, .opt = field.optional };
    }

    /// The column types a head splits into.
    fn subTypes(self: *Engine, a: std.mem.Allocator, h: Head, fields: []const []const u8) Error![]const ColTy {
        switch (h) {
            .record => |t| {
                const out = try a.alloc(ColTy, fields.len);
                for (fields, 0..) |name, i| out[i] = self.fieldColTy(t, name);
                return out;
            },
            .array => |arr| {
                const out = try a.alloc(ColTy, arr.len);
                switch (arr.elem) {
                    .uniform => |t| for (out) |*c| {
                        c.* = .{ .ty = t };
                    },
                    .tuple => |t| {
                        const elems = self.ma.pool.getTupleElements(t);
                        for (out, 0..) |*c, i| {
                            c.* = .{ .ty = if (i < elems.len) elems[i] else self.ma.pool.idx_unknown };
                        }
                    },
                }
                return out;
            },
            // exhaustive: every other head has no sub-columns.
            else => return &.{},
        }
    }

    /// The patterns a head splits one pattern into. The pattern matches the
    /// head (`headMatches`).
    fn specialize(a: std.mem.Allocator, p: SPat, fields: []const []const u8, arity: usize) Error![]const SPat {
        if (arity == 0) return &.{};
        switch (p) {
            .record => |pfields| {
                const out = try a.alloc(SPat, arity);
                for (fields, 0..) |name, i| {
                    out[i] = .any;
                    for (pfields) |pf| {
                        if (std.mem.eql(u8, pf.name, name)) {
                            out[i] = pf.pat;
                            break;
                        }
                    }
                }
                return out;
            },
            .array => |elems| {
                return elems;
            },
            else => {
                const out = try a.alloc(SPat, arity);
                @memset(out, .any);
                return out;
            },
        }
    }

    fn allAny(rows: []const Row) bool {
        for (rows) |row| {
            if (row[0] != .any) return false;
        }
        return true;
    }

    /// Whether the pattern vector `q` matches a value that none of `rows`
    /// match. Returns a witness per column when it does. The witness is
    /// allocated with `out`.
    fn useful(self: *Engine, out: std.mem.Allocator, rows: []const Row, q: Row, tys: []const ColTy, depth: u16) Error!?[]const Witness {
        if (depth > max_walk_depth) return error.Exhausted;
        try self.charge(rows.len + 1);
        if (q.len == 0) {
            return if (rows.len == 0) @as([]const Witness, &.{}) else null;
        }

        var local = std.heap.ArenaAllocator.init(self.gpa);
        defer local.deinit();
        const la = local.allocator();

        var members = std.ArrayList(Member).empty;
        var open = false;
        try self.collectColumn(la, tys[0], &members, &open);

        // When no row tests this column and the vector does not either, the
        // column cannot decide anything: drop it. The witness stays
        // unconstrained there.
        if (q[0] == .any and allAny(rows)) {
            if (members.items.len == 0) return null;
            const rest = try la.alloc(Row, rows.len);
            for (rows, 0..) |row, i| rest[i] = row[1..];
            const sub = (try self.useful(la, rest, q[1..], tys[1..], depth + 1)) orelse return null;
            const res = try out.alloc(Witness, sub.len + 1);
            res[0] = .any;
            for (sub, 1..) |w, i| res[i] = try cloneWitness(out, w);
            return res;
        }

        const heads = try self.headsOf(la, members.items, rows, q[0]);
        var record_heads: usize = 0;
        for (heads) |h| {
            if (h == .record) record_heads += 1;
        }

        for (heads) |h| {
            if (!headMatches(h, q[0])) continue;

            var iter = std.heap.ArenaAllocator.init(self.gpa);
            defer iter.deinit();
            const ia = iter.allocator();

            const fields: []const []const u8 = if (h == .record)
                try self.recordFields(ia, rows, q[0], h.record, record_heads)
            else
                &.{};
            const sub_tys = try self.subTypes(ia, h, fields);
            const arity = sub_tys.len;

            var kept = std.ArrayList(Row).empty;
            for (rows) |row| {
                if (!headMatches(h, row[0])) continue;
                const head_pats = try specialize(ia, row[0], fields, arity);
                const merged = try ia.alloc(SPat, arity + row.len - 1);
                @memcpy(merged[0..arity], head_pats);
                @memcpy(merged[arity..], row[1..]);
                try kept.append(ia, merged);
            }

            const q_head = try specialize(ia, q[0], fields, arity);
            const q2 = try ia.alloc(SPat, arity + q.len - 1);
            @memcpy(q2[0..arity], q_head);
            @memcpy(q2[arity..], q[1..]);

            const tys2 = try ia.alloc(ColTy, arity + tys.len - 1);
            @memcpy(tys2[0..arity], sub_tys);
            @memcpy(tys2[arity..], tys[1..]);

            const sub = (try self.useful(ia, kept.items, q2, tys2, depth + 1)) orelse continue;

            const head_w: Witness = switch (h) {
                .str => |s| .{ .lit_str = s },
                .str_other => .other_string,
                .num => |n| .{ .lit_num = n },
                .num_other => .other_number,
                .boolean => |b| .{ .lit_bool = b },
                .null_ => .null_,
                .undef => .undef,
                .record => blk: {
                    const fw = try out.alloc(FieldW, arity);
                    for (fields, 0..) |name, i| fw[i] = .{ .name = name, .w = try cloneWitness(out, sub[i]) };
                    break :blk .{ .record = fw };
                },
                .array => blk: {
                    const ew = try out.alloc(Witness, arity);
                    for (0..arity) |i| ew[i] = try cloneWitness(out, sub[i]);
                    break :blk .{ .array = ew };
                },
                .array_other => .other_array,
                .dict => .kind_dict,
                .bytes => .kind_bytes,
                .function => .other,
            };
            const res = try out.alloc(Witness, tys.len);
            res[0] = head_w;
            for (sub[arity..], 1..) |w, i| res[i] = try cloneWitness(out, w);
            return res;
        }
        return null;
    }
};

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

const Expect = struct {
    exhaustive: bool,
    /// The exact first missing case. Required when the match is not
    /// exhaustive and the analysis completed.
    witness: ?[]const u8 = null,
    /// The first redundant arm, by index, and whether it is the default.
    redundant: ?Redundant = null,
    incomplete: ?Incomplete = null,
    /// Overrides the work budget.
    budget: ?u64 = null,
};

/// Compile `function f(v: <param_type>)` with a match over `v`, analyze the
/// match against the declared parameter type, and compare with `want`. The
/// first `match` expression in `decls ++ function` is the one analyzed.
fn expectCoverage(decls: []const u8, param_type: []const u8, arms: []const u8, want: Expect) !void {
    const allocator = std.testing.allocator;
    const source = try allocator.print("import {{ match, P }} from \"zttp:core\";\n{s}\nfunction f(v: {s}): number {{\n  return match(v)\n{s};\n}}\n", .{ decls, param_type, arms });
    defer allocator.free(source);

    var atoms = @import("zts-engine").atom_table.AtomTable.init(allocator);
    defer atoms.deinit();
    var parser = try @import("zts-engine").parser.JsParser.initAdmission(allocator, allocator, source, .compile);
    defer parser.deinit();
    parser.setAtomTable(&atoms);
    _ = try parser.parse();
    const parsed_view = IrView.fromIRStore(&parser.nodes, &parser.constants);

    var pool = TypePool.init(allocator);
    defer pool.deinit(allocator);
    var env = TypeEnv.init(allocator, &pool);
    defer env.deinit();
    try env.populateSourceTypes(.{ .direct = .{
        .module_path = "match-analysis-test.ts",
        .store = &parser.type_store,
        .ir_view = parsed_view,
        .atoms = &atoms,
    } });

    try @import("intrinsic_lowering.zig").validateSource(allocator, &parser, &atoms, &env);
    const view = IrView.fromIRStore(&parser.nodes, &parser.constants);

    var match_node: NodeIndex = null_node;
    var i: NodeIndex = 0;
    while (i < view.nodeCount()) : (i += 1) {
        if (view.getTag(i) == .match_expr) {
            match_node = i;
            break;
        }
    }
    try std.testing.expect(match_node != null_node);
    const me = view.getMatchExpr(match_node).?;

    const sig = env.getFnSigByName("f") orelse return error.MissingSignature;
    var analysis = MatchAnalysis.init(allocator, view, &pool, &env);
    if (want.budget) |b| analysis.budget = b;
    var cov = try analysis.analyze(allocator, sig.param_types[0], me, true);
    defer cov.deinit(allocator);

    try std.testing.expectEqual(want.exhaustive, cov.exhaustive);
    try std.testing.expectEqual(want.incomplete, cov.incomplete);
    if (want.witness) |w| {
        try std.testing.expect(cov.witness != null);
        try std.testing.expectEqualStrings(w, cov.witness.?);
    } else if (!want.exhaustive and want.incomplete == null) {
        return error.TestMissingWitness;
    } else {
        try std.testing.expect(cov.witness == null);
    }
    try std.testing.expectEqual(want.redundant, cov.redundant);
}

const abc = "type C = { kind: \"a\"; n: number } | { kind: \"b\" } | { kind: \"c\"; t: string };";

test "split coverage across arms of a discriminated union is exhaustive" {
    try expectCoverage(abc, "C",
        \\    .with({ kind: "a" }, () => 1)
        \\    .with({ kind: "b" }, () => 2)
        \\    .with({ kind: "c" }, () => 3)
        \\    .exhaustive()
    , .{ .exhaustive = true });
}

test "a missing record case names its discriminant" {
    try expectCoverage(abc, "C",
        \\    .with({ kind: "a" }, (selected) => selected.n)
        \\    .with({ kind: "b" }, () => 2)
        \\    .exhaustive()
    , .{ .exhaustive = false, .witness = "{ kind: \"c\" }" });
}

test "an arm that binds every field of one member covers that member only" {
    try expectCoverage(abc, "C",
        \\    .with({ kind: "a" }, (selected) => selected.n)
        \\    .with({ kind: "c" }, () => 1)
        \\    .exhaustive()
    , .{ .exhaustive = false, .witness = "{ kind: \"b\" }" });
}

test "nested discriminants must be covered at every depth" {
    const decls = "type N = { k: \"x\"; inner: { t: \"p\" } | { t: \"q\" } } | { k: \"y\" };";
    try expectCoverage(decls, "N",
        \\    .with({ k: "x", inner: { t: "p" } }, () => 1)
        \\    .with({ k: "x", inner: { t: "q" } }, () => 2)
        \\    .with({ k: "y" }, () => 3)
        \\    .exhaustive()
    , .{ .exhaustive = true });
    try expectCoverage(decls, "N",
        \\    .with({ k: "x", inner: { t: "p" } }, () => 1)
        \\    .with({ k: "y" }, () => 3)
        \\    .exhaustive()
    , .{ .exhaustive = false, .witness = "{ k: \"x\", inner: { t: \"q\" } }" });
}

test "booleans have two constructors and fields split on them" {
    try expectCoverage("", "boolean",
        \\    .with(true, () => 1)
        \\    .with(false, () => 2)
        \\    .exhaustive()
    , .{ .exhaustive = true });
    try expectCoverage("", "boolean",
        \\    .with(true, () => 1)
        \\    .exhaustive()
    , .{ .exhaustive = false, .witness = "false" });

    const decls = "type Flags = { x: boolean; y: boolean };";
    try expectCoverage(decls, "Flags",
        \\    .with({ x: true, y: true }, () => 1)
        \\    .with({ x: true, y: false }, () => 2)
        \\    .with({ x: false }, () => 3)
        \\    .exhaustive()
    , .{ .exhaustive = true });
    try expectCoverage(decls, "Flags",
        \\    .with({ x: true, y: true }, () => 1)
        \\    .with({ x: true, y: false }, () => 2)
        \\    .with({ x: false, y: true }, () => 3)
        \\    .exhaustive()
    , .{ .exhaustive = false, .witness = "{ x: false, y: false }" });
}

test "a nullable type is its inner type plus undefined" {
    try expectCoverage("", "\"a\" | undefined",
        \\    .with("a", () => 1)
        \\    .exhaustive()
    , .{ .exhaustive = false, .witness = "undefined" });
    try expectCoverage("", "\"a\" | undefined",
        \\    .with("a", () => 1)
        \\    .with(undefined, () => 2)
        \\    .exhaustive()
    , .{ .exhaustive = true });
    try expectCoverage("", "string | null",
        \\    .with(P.string, () => 1)
        \\    .with(null, () => 2)
        \\    .exhaustive()
    , .{ .exhaustive = true });
}

test "number literal types are closed and number is open" {
    try expectCoverage("type One = 1 | 2;", "One",
        \\    .with(1, () => 1)
        \\    .with(2, () => 2)
        \\    .exhaustive()
    , .{ .exhaustive = true });
    try expectCoverage("type One = 1 | 2;", "One",
        \\    .with(1, () => 1)
        \\    .exhaustive()
    , .{ .exhaustive = false, .witness = "2" });
    try expectCoverage("", "number",
        \\    .with(1, () => 1)
        \\    .with(2, () => 2)
        \\    .exhaustive()
    , .{ .exhaustive = false, .witness = ".otherwise()" });
    try expectCoverage("", "number",
        \\    .with(1.5, () => 1)
        \\    .otherwise(() => 2)
    , .{ .exhaustive = true });
}

test "literals over an open type need a default" {
    try expectCoverage("", "string",
        \\    .with("a", () => 1)
        \\    .with("b", () => 2)
        \\    .exhaustive()
    , .{ .exhaustive = false, .witness = ".otherwise()" });
    try expectCoverage("", "string",
        \\    .with("a", () => 1)
        \\    .otherwise(() => 2)
    , .{ .exhaustive = true });
    try expectCoverage("", "unknown",
        \\    .with(P.string, () => 1)
        \\    .with(P.number, () => 2)
        \\    .exhaustive()
    , .{ .exhaustive = false, .witness = ".otherwise()" });
}

test "an array of unbounded length needs a default or the array test" {
    try expectCoverage("", "number[]",
        \\    .with([], () => 1)
        \\    .with([P.any], () => 2)
        \\    .exhaustive()
    , .{ .exhaustive = false, .witness = ".otherwise()" });
    try expectCoverage("", "number[]",
        \\    .with([], () => 1)
        \\    .with(P.array, () => 2)
        \\    .exhaustive()
    , .{ .exhaustive = true });
}

test "a tuple has one length and each element is a column" {
    const decls = "type Pair = [boolean, \"p\" | \"q\"];";
    try expectCoverage(decls, "Pair",
        \\    .with([true, "p"], () => 1)
        \\    .with([true, "q"], () => 2)
        \\    .with([false, P.any], () => 3)
        \\    .exhaustive()
    , .{ .exhaustive = true });
    try expectCoverage(decls, "Pair",
        \\    .with([true, "p"], () => 1)
        \\    .with([false, P.any], () => 3)
        \\    .exhaustive()
    , .{ .exhaustive = false, .witness = "[true, \"q\"]" });
    // An array pattern of another length never matches a tuple of this one.
    try expectCoverage(decls, "Pair",
        \\    .with([P.any, P.any], () => 1)
        \\    .with([P.any], () => 2)
        \\    .exhaustive()
    , .{ .exhaustive = true, .redundant = .{ .arm = 1, .is_default = false } });
}

test "an optional field admits undefined, and a field underscore does not" {
    const decls = "type Opt = { a?: string };";
    try expectCoverage(decls, "Opt",
        \\    .with({ a: "x" }, () => 1)
        \\    .with({ a: P.present }, () => 2)
        \\    .exhaustive()
    , .{ .exhaustive = false, .witness = "{ a: undefined }" });
    try expectCoverage(decls, "Opt",
        \\    .with({ a: "x" }, () => 1)
        \\    .with({}, () => 2)
        \\    .exhaustive()
    , .{ .exhaustive = true });
    try expectCoverage(decls, "Opt",
        \\    .with({ a: undefined }, () => 1)
        \\    .with({ a: P.present }, () => 2)
        \\    .exhaustive()
    , .{ .exhaustive = true });
}

test "a field underscore on a required field is the same as a binding" {
    try expectCoverage("type R = { a: string };", "R",
        \\    .with({ a: P.present }, () => 1)
        \\    .exhaustive()
    , .{ .exhaustive = true });
}

test "an array element underscore is a plain wildcard" {
    try expectCoverage("", "[number, number]",
        \\    .with([P.any, P.any], () => 1)
        \\    .exhaustive()
    , .{ .exhaustive = true });
    try expectCoverage("", "[number, number]",
        \\    .with([1, P.any], () => 1)
        \\    .exhaustive()
    , .{ .exhaustive = false, .witness = "[P.any, P.any]" });
    try expectCoverage("", "[number | undefined, number]",
        \\    .with([P.any, P.any], () => 1)
        \\    .exhaustive()
    , .{ .exhaustive = true });
}

test "a record pattern with no literal does not cover a string member" {
    const decls = "type M = string | { w: number };";
    try expectCoverage(decls, "M",
        \\    .with({}, () => 1)
        \\    .exhaustive()
    , .{ .exhaustive = false, .witness = "P.string" });
    try expectCoverage(decls, "M",
        \\    .with({}, () => 1)
        \\    .with(P.string, () => 2)
        \\    .exhaustive()
    , .{ .exhaustive = true });
    try expectCoverage(decls, "M",
        \\    .with({}, () => 1)
        \\    .otherwise(() => 2)
    , .{ .exhaustive = true });
}

test "type tests partition the value kinds" {
    try expectCoverage("", "boolean | number | string | Bytes",
        \\    .with(P.boolean, () => 1)
        \\    .with(P.number, () => 2)
        \\    .with(P.string, () => 3)
        \\    .with(P.Bytes, () => 4)
        \\    .exhaustive()
    , .{ .exhaustive = true });
    try expectCoverage("", "boolean | number | string | Bytes",
        \\    .with(P.boolean, () => 1)
        \\    .with(P.number, () => 2)
        \\    .with(P.string, () => 3)
        \\    .exhaustive()
    , .{ .exhaustive = false, .witness = "P.Bytes" });
    try expectCoverage("", "string | number",
        \\    .with("a", () => 1)
        \\    .with(P.number, () => 2)
        \\    .exhaustive()
    , .{ .exhaustive = false, .witness = "P.string" });
    const json =
        "type J = null | boolean | number | string | readonly J[] | Dict<string, J>;";
    try expectCoverage(json, "J",
        \\    .with(null, () => 1)
        \\    .with(P.boolean, () => 2)
        \\    .with(P.number, () => 3)
        \\    .with(P.string, () => 4)
        \\    .with(P.array, () => 5)
        \\    .with(P.Dict, () => 6)
        \\    .exhaustive()
    , .{ .exhaustive = true });
    try expectCoverage(json, "J",
        \\    .with(null, () => 1)
        \\    .with(P.boolean, () => 2)
        \\    .with(P.number, () => 3)
        \\    .with(P.string, () => 4)
        \\    .with(P.array, () => 5)
        \\    .exhaustive()
    , .{ .exhaustive = false, .witness = "P.Dict" });
}

test "a record is not covered by a type test" {
    try expectCoverage("type M = string | { w: number };", "M",
        \\    .with(P.string, () => 1)
        \\    .with(P.number, () => 2)
        \\    .exhaustive()
    , .{ .exhaustive = false, .witness = "{}", .redundant = .{ .arm = 1, .is_default = false } });
}

test "aliases resolve and a name with no definition is open" {
    try expectCoverage("type A = B;\ntype B = \"x\" | \"y\";", "A",
        \\    .with("x", () => 1)
        \\    .with("y", () => 2)
        \\    .exhaustive()
    , .{ .exhaustive = true });
    try expectCoverage("", "Nothing",
        \\    .with("x", () => 1)
        \\    .exhaustive()
    , .{ .exhaustive = false, .witness = ".otherwise()" });
}

test "a redundant arm is reported with its index" {
    try expectCoverage("", "\"a\" | \"b\"",
        \\    .with("a", () => 1)
        \\    .with("a", () => 2)
        \\    .with("b", () => 3)
        \\    .exhaustive()
    , .{ .exhaustive = true, .redundant = .{ .arm = 1, .is_default = false } });
    try expectCoverage("", "string",
        \\    .with(P.string, () => 1)
        \\    .with("a", () => 2)
        \\    .exhaustive()
    , .{ .exhaustive = true, .redundant = .{ .arm = 1, .is_default = false } });
    try expectCoverage(abc, "C",
        \\    .with({ kind: "a" }, () => 1)
        \\    .with({ kind: "a" }, () => 2)
        \\    .otherwise(() => 3)
    , .{ .exhaustive = true, .redundant = .{ .arm = 1, .is_default = false } });
}

test "an arm the type excludes is reported as unreachable" {
    try expectCoverage("", "\"a\" | \"b\"",
        \\    .with("z", () => 1)
        \\    .otherwise(() => 2)
    , .{ .exhaustive = true, .redundant = .{ .arm = 0, .is_default = false } });
    try expectCoverage("type S = { w: number };", "S",
        \\    .with("z", () => 1)
        \\    .otherwise(() => 2)
    , .{ .exhaustive = true, .redundant = .{ .arm = 0, .is_default = false } });
}

test "a default after full coverage of a closed type is redundant" {
    try expectCoverage("", "\"a\" | \"b\"",
        \\    .with("a", () => 1)
        \\    .with("b", () => 2)
        \\    .otherwise(() => 3)
    , .{ .exhaustive = true, .redundant = .{ .arm = 2, .is_default = true } });
    try expectCoverage("", "boolean",
        \\    .with(true, () => 1)
        \\    .with(false, () => 2)
        \\    .otherwise(() => 3)
    , .{ .exhaustive = true, .redundant = .{ .arm = 2, .is_default = true } });
}

test "a default over an open type is not redundant" {
    try expectCoverage("", "string",
        \\    .with("a", () => 1)
        \\    .otherwise(() => 2)
    , .{ .exhaustive = true });
    try expectCoverage("type M = string | { w: number };", "M",
        \\    .with({}, () => 1)
        \\    .otherwise(() => 2)
    , .{ .exhaustive = true });
}

test "an exhausted budget is not exhaustive and gives no redundancy verdict" {
    // With the arms below, an unbounded budget finds the match exhaustive and
    // the second arm redundant. A budget of one unit finds neither.
    const arms =
        \\    .with("a", () => 1)
        \\    .with("a", () => 2)
        \\    .with("b", () => 3)
        \\    .exhaustive()
    ;
    try expectCoverage("", "\"a\" | \"b\"", arms, .{
        .exhaustive = true,
        .redundant = .{ .arm = 1, .is_default = false },
    });
    try expectCoverage("", "\"a\" | \"b\"", arms, .{
        .exhaustive = false,
        .incomplete = .budget,
        .budget = 1,
    });
}

test "a field named twice in one pattern is not modelled" {
    try expectCoverage(abc, "C",
        \\    .with({ kind: "a", kind: "b" }, () => 1)
        \\    .exhaustive()
    , .{ .exhaustive = false, .incomplete = .unmodelled });
    try expectCoverage(abc, "C",
        \\    .with({ kind: "a", kind: "b" }, () => 1)
        \\    .otherwise(() => 2)
    , .{ .exhaustive = true });
}

test "the help text names the missing case or the reason" {
    const allocator = std.testing.allocator;
    const witness = try allocator.dupe(u8, "{ kind: \"c\" }");
    var cov = Coverage{ .witness = witness };
    defer cov.deinit(allocator);
    const help = try missingCaseHelp(allocator, cov);
    defer allocator.free(help);
    try std.testing.expectEqualStrings("missing pattern: { kind: \"c\" }. Add a .with(pattern, callback) arm, or end the match with .otherwise(callback).", help);

    const budget = try missingCaseHelp(allocator, .{ .incomplete = .budget });
    defer allocator.free(budget);
    try std.testing.expect(std.mem.find(u8, budget, "analysis budget ran out") != null);
}
