//! Types that cross a module boundary on the compile path.
//!
//! Each module of a multi-module build is checked in its own session, with its
//! own `TypePool`, so a type index of one module means nothing in another.
//! `ExportedSignatures` holds the exported function signatures of the checked
//! dependencies, and the types of their exported values, in one pool of its own.
//! `Copier` moves a type from one pool into another. A type the copy cannot represent comes back as
//! `null_type_idx`, which every consumer reads as unknown. A copy never widens
//! a type: one member that fails to copy fails the whole type.

const std = @import("std");
const type_pool_mod = @import("type_pool.zig");
const type_env_mod = @import("type_env.zig");

const TypePool = type_pool_mod.TypePool;
const TypeIndex = type_pool_mod.TypeIndex;
const TypeEnv = type_env_mod.TypeEnv;
const FunctionSig = type_env_mod.FunctionSig;
const RecordField = type_pool_mod.RecordField;
const FuncParam = type_pool_mod.FuncParam;
const null_type_idx = type_pool_mod.null_type_idx;

const in_progress: TypeIndex = null_type_idx - 1;
const max_copy_depth: u8 = 64;

/// Moves types from one pool into another. One copier serves one source and
/// one destination, and its memo keeps a shared node shared. A node that is
/// still being copied when it is met again closes a cycle through a recursive
/// alias, and that type stays unknown.
pub const Copier = struct {
    allocator: std.mem.Allocator,
    src: *const TypePool,
    /// Resolves a named reference in the source. Null when the source holds
    /// no references to resolve.
    src_env: ?*const TypeEnv,
    dst: *TypePool,
    /// Lets a nominal type of the source reuse the destination's own type of
    /// the same name, so `Response` stays one type.
    dst_env: ?*const TypeEnv,
    memo: std.AutoHashMapUnmanaged(TypeIndex, TypeIndex) = .empty,

    pub fn deinit(self: *Copier) void {
        self.memo.deinit(self.allocator);
    }

    /// The copy of `idx` in the destination, or `null_type_idx` when the type
    /// cannot be represented.
    pub fn copy(self: *Copier, idx: TypeIndex) TypeIndex {
        return self.copyAt(idx, 0);
    }

    fn copyAt(self: *Copier, original: TypeIndex, depth: u8) TypeIndex {
        if (original == null_type_idx or depth >= max_copy_depth) return null_type_idx;
        const idx = if (self.src_env) |env| env.resolveRef(original) else original;
        if (self.memo.get(idx)) |found| return if (found == in_progress) null_type_idx else found;
        self.memo.put(self.allocator, idx, in_progress) catch return null_type_idx;
        const result = self.copyNode(idx, depth);
        self.memo.put(self.allocator, idx, result) catch return null_type_idx;
        return result;
    }

    fn copyNode(self: *Copier, idx: TypeIndex, depth: u8) TypeIndex {
        const src = self.src;
        const tag = src.getTag(idx) orelse return null_type_idx;
        const nominal = src.isNominal(idx);
        if (nominal) {
            if (self.sharedNominal(idx, tag)) |shared| return shared;
        }
        const base = self.copyBase(idx, tag, depth);
        if (base == null_type_idx or !nominal) return base;
        switch (tag) {
            .t_string, .t_number, .t_boolean, .t_record => {},
            // exhaustive: a nominal over any other tag has no copy and stays
            // unknown, which grants nothing.
            else => return null_type_idx,
        }
        return self.dst.addNominalAlias(self.allocator, base, src.nominalName(idx));
    }

    fn sharedNominal(self: *const Copier, idx: TypeIndex, tag: type_pool_mod.TypeTag) ?TypeIndex {
        const env = self.dst_env orelse return null;
        const name = self.src.nominalName(idx);
        if (name.len == 0) return null;
        const existing = env.getTypeAlias(name) orelse return null;
        if (!self.dst.isNominal(existing)) return null;
        if (!std.mem.eql(u8, self.dst.nominalName(existing), name)) return null;
        if (self.dst.getTag(existing) != tag) return null;
        return existing;
    }

    fn copyBase(self: *Copier, idx: TypeIndex, tag: type_pool_mod.TypeTag, depth: u8) TypeIndex {
        const src = self.src;
        const dst = self.dst;
        const allocator = self.allocator;
        switch (tag) {
            .t_boolean => return dst.idx_boolean,
            .t_number => return dst.idx_number,
            .t_string => return dst.idx_string,
            .t_bytes => return dst.idx_bytes,
            .t_null => return dst.idx_null,
            .t_undefined => return dst.idx_undefined,
            .t_void => return dst.idx_void,
            .t_never => return dst.idx_never,
            .t_unknown_type => return if (idx == src.idx_json_value) dst.idx_json_value else dst.idx_unknown,
            .t_literal_string => {
                const value = src.getLiteralStringValue(idx) orelse return null_type_idx;
                return dst.addLiteralString(allocator, value);
            },
            .t_literal_number => {
                const data = src.getData(idx) orelse return null_type_idx;
                return dst.addLiteralNumber(allocator, @bitCast(data.a));
            },
            .t_literal_bool => {
                const data = src.getData(idx) orelse return null_type_idx;
                return dst.addLiteralBool(allocator, data.a != 0);
            },
            .t_ref => {
                // A name the source did not resolve. The destination would
                // resolve it against its own declarations, and a type of
                // another module must not be read that way. `object` is the
                // one ambient name with a fixed meaning.
                if (!std.mem.eql(u8, src.getRefName(idx), "object")) return null_type_idx;
                return dst.addRef(allocator, "object");
            },
            .t_array => {
                const element = self.copyAt(src.getArrayElement(idx), depth + 1);
                if (element == null_type_idx) return null_type_idx;
                return if (src.isReadonlyArray(idx))
                    dst.addReadonlyArray(allocator, element)
                else
                    dst.addArray(allocator, element);
            },
            .t_dict => {
                const key = self.copyAt(src.getDictKey(idx), depth + 1);
                const value = self.copyAt(src.getDictValue(idx), depth + 1);
                if (key == null_type_idx or value == null_type_idx) return null_type_idx;
                return dst.addDict(allocator, key, value);
            },
            .t_nullable => {
                const inner = self.copyAt(src.getNullableInner(idx), depth + 1);
                if (inner == null_type_idx) return null_type_idx;
                return dst.addNullable(allocator, inner);
            },
            .t_tuple => return self.copyList(src.getTupleElements(idx), .tuple, depth),
            .t_union => return self.copyList(src.getUnionMembers(idx), .union_type, depth),
            .t_intersection => return self.copyList(src.getIntersectionMembers(idx), .intersection, depth),
            .t_record => return self.copyRecord(idx, depth),
            .t_function => return self.copyFunction(idx, depth),
            // exhaustive: a type variable, a generic application, a template
            // literal, and the refused-expression type have no copy. Each stays
            // unknown, which grants nothing.
            .t_generic_param, .t_generic_app, .t_template_literal, .t_error => return null_type_idx,
        }
    }

    const ListKind = enum { tuple, union_type, intersection };

    fn copyList(self: *Copier, members: []const TypeIndex, kind: ListKind, depth: u8) TypeIndex {
        const copied = self.allocator.alloc(TypeIndex, members.len) catch return null_type_idx;
        defer self.allocator.free(copied);
        for (members, 0..) |member, i| {
            copied[i] = self.copyAt(member, depth + 1);
            if (copied[i] == null_type_idx) return null_type_idx;
        }
        return switch (kind) {
            .tuple => self.dst.addTuple(self.allocator, copied),
            .union_type => self.dst.addUnion(self.allocator, copied),
            .intersection => self.dst.addIntersection(self.allocator, copied),
        };
    }

    fn copyRecord(self: *Copier, idx: TypeIndex, depth: u8) TypeIndex {
        const fields = self.src.getRecordFields(idx);
        const copied = self.allocator.alloc(RecordField, fields.len) catch return null_type_idx;
        defer self.allocator.free(copied);
        for (fields, 0..) |field, i| {
            const name = self.dst.addName(self.allocator, self.src.getName(field.name_start, field.name_len));
            const field_type = self.copyAt(field.type_idx, depth + 1);
            if (field_type == null_type_idx) return null_type_idx;
            copied[i] = .{
                .name_start = name.start,
                .name_len = name.len,
                .type_idx = field_type,
                .optional = field.optional,
                .readonly = field.readonly,
            };
        }
        const record = self.dst.addRecord(self.allocator, copied);
        if (record != null_type_idx and self.src.isResultRecord(idx)) {
            return self.dst.markResultRecord(self.allocator, record);
        }
        return record;
    }

    fn copyFunction(self: *Copier, idx: TypeIndex, depth: u8) TypeIndex {
        const info = self.src.getFunctionInfo(idx);
        const copied = self.allocator.alloc(FuncParam, info.params.len) catch return null_type_idx;
        defer self.allocator.free(copied);
        for (info.params, 0..) |param, i| {
            const name = self.dst.addName(self.allocator, self.src.getName(param.name_start, param.name_len));
            const param_type = self.copyAt(param.type_idx, depth + 1);
            if (param_type == null_type_idx) return null_type_idx;
            copied[i] = .{
                .name_start = name.start,
                .name_len = name.len,
                .type_idx = param_type,
                .optional = param.optional,
            };
        }
        const ret = self.copyAt(info.ret, depth + 1);
        if (ret == null_type_idx) return null_type_idx;
        return self.dst.addFunctionWithReturn(self.allocator, copied, ret);
    }

    /// The signature `sig` of the source, in the destination pool. Null when
    /// the signature is generic, declares a type predicate, or holds a return
    /// type or a declared parameter type that does not copy. A parameter
    /// without a declared type stays without one.
    pub fn copySignature(self: *Copier, sig: FunctionSig) ?FunctionSig {
        if (sig.type_param_count > 0 or sig.type_predicate != null) return null;
        var out: FunctionSig = .{};
        @memset(&out.param_types, null_type_idx);
        out.param_count = sig.param_count;
        out.required_param_count = sig.required_param_count;
        out.max_arg_count = sig.max_arg_count;
        for (0..sig.param_count) |i| {
            if (sig.param_types[i] == null_type_idx) continue;
            const param_type = self.copy(sig.param_types[i]);
            if (param_type == null_type_idx) return null;
            out.param_types[i] = param_type;
        }
        out.return_type = self.copy(sig.return_type);
        if (out.return_type == null_type_idx) return null;
        return out;
    }
};

/// The exports of the modules checked so far. Types live in `pool`, which this
/// table owns. A row holds the signature of a function export, the type of a
/// value export, or both. A row with neither is an export that has no type
/// which crosses a module.
pub const ExportedSignatures = struct {
    pub const Row = struct {
        /// The module's index in the graph's module list.
        module: u16,
        name: []u8,
        sig: ?FunctionSig,
        /// The type of a value export, in `pool`, or `null_type_idx`.
        value_type: TypeIndex = null_type_idx,
    };

    allocator: std.mem.Allocator,
    pool: TypePool,
    rows: std.ArrayListUnmanaged(Row) = .empty,

    pub fn init(allocator: std.mem.Allocator) ExportedSignatures {
        return .{ .allocator = allocator, .pool = TypePool.init(allocator) };
    }

    pub fn deinit(self: *ExportedSignatures) void {
        for (self.rows.items) |row| self.allocator.free(row.name);
        self.rows.deinit(self.allocator);
        self.pool.deinit(self.allocator);
    }

    /// A copier that fills this table from the pool and environment of one
    /// checked module. The caller keeps it for every export of that module.
    pub fn copierFrom(self: *ExportedSignatures, src_pool: *const TypePool, src_env: *const TypeEnv) Copier {
        return .{
            .allocator = self.allocator,
            .src = src_pool,
            .src_env = src_env,
            .dst = &self.pool,
            .dst_env = null,
        };
    }

    pub fn add(
        self: *ExportedSignatures,
        module: u16,
        name: []const u8,
        sig: ?FunctionSig,
        value_type: TypeIndex,
    ) !void {
        const owned = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(owned);
        try self.rows.append(self.allocator, .{ .module = module, .name = owned, .sig = sig, .value_type = value_type });
    }

    pub fn find(self: *const ExportedSignatures, module: u16, name: []const u8) ?*const Row {
        for (self.rows.items) |*row| {
            if (row.module == module and std.mem.eql(u8, row.name, name)) return row;
        }
        return null;
    }
};

/// What one module knows of its file imports. The caller builds it before the
/// module is checked. Every file import has a row, and a row with a null
/// signature and no value type is an import that has no type. Strings are
/// borrowed and must outlive the checker.
pub const FileImportSignatures = struct {
    pub const Row = struct {
        /// The specifier as written in the importing module.
        specifier: []const u8,
        /// The name of the export.
        imported: []const u8,
        sig: ?FunctionSig,
        /// The type of a value export, or `null_type_idx`.
        value_type: TypeIndex = null_type_idx,
    };

    /// The pool that holds the types of every row.
    source: *const TypePool,
    rows: []const Row,

    pub fn find(self: *const FileImportSignatures, specifier: []const u8, imported: []const u8) ?*const Row {
        for (self.rows) |*row| {
            if (std.mem.eql(u8, row.specifier, specifier) and std.mem.eql(u8, row.imported, imported)) return row;
        }
        return null;
    }
};
