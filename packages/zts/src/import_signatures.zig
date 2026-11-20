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
const GenericAlias = type_env_mod.GenericAlias;
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
    recursive_source_name: ?[]const u8 = null,
    recursive_destination_name: ?[]const u8 = null,
    generic_param_names: []const []const u8 = &.{},

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
        if (self.src.getTag(original) == .t_ref) {
            const name = self.src.getRefName(original);
            for (self.generic_param_names) |param_name| {
                if (std.mem.eql(u8, name, param_name)) {
                    return self.dst.addGenericParam(self.allocator, name);
                }
            }
            if (self.recursive_source_name) |source_name| {
                if (std.mem.eql(u8, name, source_name)) {
                    return self.dst.addRef(self.allocator, self.recursive_destination_name orelse source_name);
                }
            }
        }
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
        const origin = src.nominalOrigin(idx) orelse return null_type_idx;
        const construction = src.nominalConstruction(idx) orelse return null_type_idx;
        return self.dst.addNominalAliasWithOrigin(
            self.allocator,
            base,
            src.nominalName(idx),
            origin,
            construction,
        );
    }

    fn sharedNominal(self: *const Copier, idx: TypeIndex, tag: type_pool_mod.TypeTag) ?TypeIndex {
        const env = self.dst_env orelse return null;
        const name = self.src.nominalName(idx);
        if (name.len == 0) return null;
        const existing = env.getTypeAlias(name) orelse return null;
        if (!self.dst.isNominal(existing)) return null;
        const source_origin = self.src.nominalOrigin(idx) orelse return null;
        const existing_origin = self.dst.nominalOrigin(existing) orelse return null;
        if (source_origin.module_path.len != 0 or existing_origin.module_path.len != 0) {
            if (source_origin.declaration_start != existing_origin.declaration_start or
                !std.mem.eql(u8, source_origin.module_path, existing_origin.module_path)) return null;
        } else if (!std.mem.eql(u8, self.dst.nominalName(existing), name)) return null;
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
            .t_generic_param => return dst.addGenericParam(allocator, src.getRefName(idx)),
            .t_generic_app => {
                const info = src.getGenericAppInfo(idx);
                const base = self.copyAt(info.base, depth + 1);
                if (base == null_type_idx) return null_type_idx;
                const copied = allocator.alloc(TypeIndex, info.args.len) catch return null_type_idx;
                defer allocator.free(copied);
                for (info.args, 0..) |arg, i| {
                    copied[i] = self.copyAt(arg, depth + 1);
                    if (copied[i] == null_type_idx) return null_type_idx;
                }
                return dst.addGenericApp(allocator, base, copied);
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
            // exhaustive: a template literal and the refused-expression type
            // have no copy. Each stays unknown, which grants nothing.
            .t_template_literal, .t_error => return null_type_idx,
        }
    }

    /// Copy one exported alias. A recursive self-reference keeps its identity
    /// and adopts the import's local name.
    pub fn copyAlias(self: *Copier, idx: TypeIndex, source_name: []const u8, destination_name: []const u8) TypeIndex {
        self.recursive_source_name = source_name;
        self.recursive_destination_name = destination_name;
        return self.copy(idx);
    }

    /// Copy a generic alias and its parameter constraints.
    pub fn copyGenericAlias(
        self: *Copier,
        alias: GenericAlias,
        source_name: []const u8,
        destination_name: []const u8,
    ) ?GenericAlias {
        self.recursive_source_name = source_name;
        self.recursive_destination_name = destination_name;
        self.generic_param_names = alias.param_names[0..alias.param_count];
        var copied: GenericAlias = .{};
        copied.param_count = alias.param_count;
        for (0..alias.param_count) |i| {
            const stored = self.dst.addName(self.allocator, alias.param_names[i]);
            copied.param_names[i] = self.dst.getName(stored.start, stored.len);
            if (alias.param_constraints[i] != null_type_idx) {
                copied.param_constraints[i] = self.copy(alias.param_constraints[i]);
                if (copied.param_constraints[i] == null_type_idx) return null;
            }
        }
        copied.body = self.copy(alias.body);
        if (copied.body == null_type_idx) return null;
        return copied;
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
        var record = self.dst.addRecord(self.allocator, copied);
        if (record != null_type_idx and self.src.isResultRecord(idx)) {
            record = self.dst.markResultRecord(self.allocator, record);
        }
        if (record != null_type_idx and self.src.hasUnknownFields(idx)) {
            record = self.dst.markUnknownFieldRecord(self.allocator, record);
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
    pub const TypeAlias = union(enum) {
        direct: TypeIndex,
        generic: GenericAlias,
    };

    pub const Row = struct {
        /// The normalized path that identifies the exporting module.
        module_path: []u8,
        name: []u8,
        sig: ?FunctionSig,
        /// The type of a value export, in `pool`, or `null_type_idx`.
        value_type: TypeIndex = null_type_idx,
        type_alias: ?TypeAlias = null,
        brand_origin: ?type_pool_mod.NominalOrigin = null,
    };

    allocator: std.mem.Allocator,
    pool: TypePool,
    rows: std.ArrayListUnmanaged(Row) = .empty,

    pub fn init(allocator: std.mem.Allocator) ExportedSignatures {
        return .{ .allocator = allocator, .pool = TypePool.init(allocator) };
    }

    pub fn deinit(self: *ExportedSignatures) void {
        for (self.rows.items) |row| {
            self.allocator.free(row.module_path);
            self.allocator.free(row.name);
        }
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
        module_path: []const u8,
        name: []const u8,
        sig: ?FunctionSig,
        value_type: TypeIndex,
    ) !void {
        for (self.rows.items) |*row| {
            if (row.type_alias != null or row.brand_origin != null) continue;
            if (!std.mem.eql(u8, row.module_path, module_path) or !std.mem.eql(u8, row.name, name)) continue;
            row.sig = sig;
            row.value_type = value_type;
            return;
        }
        const owned_module_path = try self.allocator.dupe(u8, module_path);
        errdefer self.allocator.free(owned_module_path);
        const owned = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(owned);
        try self.rows.append(self.allocator, .{
            .module_path = owned_module_path,
            .name = owned,
            .sig = sig,
            .value_type = value_type,
        });
    }

    pub fn addTypeAlias(
        self: *ExportedSignatures,
        module_path: []const u8,
        name: []const u8,
        type_alias: TypeAlias,
    ) !void {
        const owned_module_path = try self.allocator.dupe(u8, module_path);
        errdefer self.allocator.free(owned_module_path);
        const owned_name = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(owned_name);
        try self.rows.append(self.allocator, .{
            .module_path = owned_module_path,
            .name = owned_name,
            .sig = null,
            .type_alias = type_alias,
        });
    }

    pub fn addBrand(
        self: *ExportedSignatures,
        module_path: []const u8,
        name: []const u8,
        declaration_start: u32,
    ) !void {
        const owned_module_path = try self.allocator.dupe(u8, module_path);
        errdefer self.allocator.free(owned_module_path);
        const owned_name = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(owned_name);
        try self.rows.append(self.allocator, .{
            .module_path = owned_module_path,
            .name = owned_name,
            .sig = null,
            .brand_origin = .{
                .module_path = owned_module_path,
                .declaration_start = declaration_start,
            },
        });
    }

    pub fn find(self: *const ExportedSignatures, module_path: []const u8, name: []const u8) ?*const Row {
        return self.findValue(module_path, name) orelse self.findType(module_path, name);
    }

    pub fn findValue(self: *const ExportedSignatures, module_path: []const u8, name: []const u8) ?*const Row {
        for (self.rows.items) |*row| {
            if (row.sig == null and row.value_type == null_type_idx) continue;
            if (std.mem.eql(u8, row.module_path, module_path) and std.mem.eql(u8, row.name, name)) return row;
        }
        return null;
    }

    pub fn findType(self: *const ExportedSignatures, module_path: []const u8, name: []const u8) ?*const Row {
        for (self.rows.items) |*row| {
            if (row.type_alias == null and row.brand_origin == null) continue;
            if (std.mem.eql(u8, row.module_path, module_path) and std.mem.eql(u8, row.name, name)) return row;
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
        /// The local type-namespace name. Empty for runtime imports.
        local: []const u8 = "",
        sig: ?FunctionSig,
        /// The type of a value export, or `null_type_idx`.
        value_type: TypeIndex = null_type_idx,
        type_alias: ?ExportedSignatures.TypeAlias = null,
        brand_origin: ?type_pool_mod.NominalOrigin = null,
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

    /// Install erased type-only imports before local declarations are lowered.
    pub fn installTypeImports(self: *const FileImportSignatures, env: *TypeEnv) !void {
        for (self.rows) |row| {
            if (row.local.len == 0) continue;
            if (row.brand_origin) |origin| {
                try env.putImportedBrand(row.local, origin);
                continue;
            }
            const exported = row.type_alias orelse return error.UntypedTypeImport;
            var copier: Copier = .{
                .allocator = env.allocator,
                .src = self.source,
                .src_env = null,
                .dst = env.pool,
                .dst_env = env,
            };
            defer copier.deinit();
            switch (exported) {
                .direct => |source_type| {
                    const copied = copier.copyAlias(source_type, row.imported, row.local);
                    if (copied == null_type_idx) return error.UntypedTypeImport;
                    try env.putImportedTypeAlias(row.local, copied);
                },
                .generic => |source_alias| {
                    const copied = copier.copyGenericAlias(source_alias, row.imported, row.local) orelse
                        return error.UntypedTypeImport;
                    try env.putImportedGenericAlias(row.local, copied);
                },
            }
        }
        try env.pool.ensureHealthy();
        try env.ensureHealthy();
    }
};
