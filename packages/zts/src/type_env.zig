//! Type Environment: resolves type names to TypePool indices.
//!
//! Populated from TypeMap entries extracted by the stripper. Provides:
//! - Type alias resolution (type Foo = ...)
//! - Interface resolution (interface Bar { ... })
//! - Variable type annotations (const x: Type = ...)
//! - Function signatures (params + return types)
//! - Generic scope tracking
//!
//! The TypeEnv is the bridge between raw type text (from the stripper's TypeMap)
//! and the structured types in the TypePool.

const std = @import("std");
const type_pool_mod = @import("type_pool.zig");
const type_map_mod = @import("zts-base").type_map;

const TypePool = type_pool_mod.TypePool;
const TypeIndex = type_pool_mod.TypeIndex;
const null_type_idx = type_pool_mod.null_type_idx;
const parseTypeExpr = type_pool_mod.parseTypeExpr;
const TypeMap = type_map_mod.TypeMap;
const TypeMapKind = type_map_mod.TypeMapKind;
const TypeMapEntry = type_map_mod.TypeMapEntry;

/// The field name used to mark a record as the body of an instantiated
/// `Spec<...>` generic alias. The verifier looks for records bearing this
/// field when extracting declared spec sets from a handler return type.
/// Sized to be unmistakable for any user-authored field.
pub const spec_marker_field = "__zttp_spec__";

/// Built-in object-deriving utility types. Recognized by name in
/// tryInstantiateGenericApp; the transforms themselves live in TypePool.
const UtilityKind = enum { pick, omit, partial, required, readonly };

fn utilityKind(name: []const u8) ?UtilityKind {
    if (std.mem.eql(u8, name, "Pick")) return .pick;
    if (std.mem.eql(u8, name, "Omit")) return .omit;
    if (std.mem.eql(u8, name, "Partial")) return .partial;
    if (std.mem.eql(u8, name, "Required")) return .required;
    if (std.mem.eql(u8, name, "Readonly")) return .readonly;
    return null;
}

/// The field name marking the body of an instantiated `Effects<...>` generic
/// alias. Distinct from `spec_marker_field` so a return type carrying both
/// (`Effects<Response, "env"> & Spec<"deterministic">`) keeps capability
/// names and proof-property names in separate extraction passes.
pub const effect_marker_field = "__zttp_effect__";

/// What a marker extraction found besides the names themselves.
///
/// The names alone are ambiguous: an empty list means either "no marker" or
/// "a marker whose payload the extractor could not reduce to literal names".
/// Callers that treat the second as the first fail open - an unchecked
/// program then claims conformance. `non_literal` separates the two.
/// Walk-depth ceiling for marker search and payload reading. Exceeding it
/// fails closed rather than returning a partial read.
const max_marker_depth: u8 = 8;

pub const MarkerExtraction = struct {
    /// True when a marker was present but its payload contained a type that
    /// is not a closed union of string literals. The name list is then not
    /// the declared set and must not be discharged as one.
    non_literal: bool = false,
};

// ---------------------------------------------------------------------------
// Generic scope
// ---------------------------------------------------------------------------

pub const MAX_TYPE_PARAMS = 8;

pub const GenericScope = struct {
    /// Type parameter names mapped to their TypeIndex in the pool.
    params: [MAX_TYPE_PARAMS]struct {
        name: [32]u8,
        name_len: u8,
        idx: TypeIndex,
        /// The `extends` bound, or `null_type_idx` when the parameter is
        /// unconstrained. Held next to the parameter so a later pass can check
        /// an inferred or explicit argument against it.
        constraint: TypeIndex,
    } = undefined,
    count: u8 = 0,

    pub fn addParam(self: *GenericScope, name: []const u8, idx: TypeIndex) void {
        self.addConstrainedParam(name, idx, null_type_idx);
    }

    pub fn addConstrainedParam(
        self: *GenericScope,
        name: []const u8,
        idx: TypeIndex,
        constraint: TypeIndex,
    ) void {
        if (self.count >= MAX_TYPE_PARAMS) return;
        const len: u8 = @intCast(@min(name.len, 32));
        @memcpy(self.params[self.count].name[0..len], name[0..len]);
        self.params[self.count].name_len = len;
        self.params[self.count].idx = idx;
        self.params[self.count].constraint = constraint;
        self.count += 1;
    }

    /// Attach a constraint to an already-added parameter. Constraints are
    /// resolved after every parameter of the scope is in place, so that
    /// `<T, U extends T>` sees `T`.
    pub fn setConstraint(self: *GenericScope, name: []const u8, constraint: TypeIndex) void {
        for (0..self.count) |i| {
            if (self.params[i].name_len == name.len and
                std.mem.eql(u8, self.params[i].name[0..self.params[i].name_len], name))
            {
                self.params[i].constraint = constraint;
                return;
            }
        }
    }

    pub fn resolve(self: *const GenericScope, name: []const u8) ?TypeIndex {
        for (0..self.count) |i| {
            if (self.params[i].name_len == name.len and
                std.mem.eql(u8, self.params[i].name[0..self.params[i].name_len], name))
            {
                return self.params[i].idx;
            }
        }
        return null;
    }

    pub fn constraintOf(self: *const GenericScope, name: []const u8) TypeIndex {
        for (0..self.count) |i| {
            if (self.params[i].name_len == name.len and
                std.mem.eql(u8, self.params[i].name[0..self.params[i].name_len], name))
            {
                return self.params[i].constraint;
            }
        }
        return null_type_idx;
    }
};

/// One declared type parameter of a function signature.
pub const GenericParam = struct {
    /// Interned, so it outlives the TypeMap the signature was read from.
    name: []const u8 = "",
    /// The `t_generic_param` node the name resolves to inside the signature.
    idx: TypeIndex = null_type_idx,
    /// The `extends` bound, or `null_type_idx` when unconstrained.
    constraint: TypeIndex = null_type_idx,
};

/// Explicit type arguments written at a call site (`first<string>(xs)`),
/// already resolved to pool indices.
pub const CallTypeArgs = struct {
    args: [MAX_TYPE_PARAMS]TypeIndex = undefined,
    count: u8 = 0,
};

// ---------------------------------------------------------------------------
// Function signature (params + return type)
// ---------------------------------------------------------------------------

pub const FunctionSig = struct {
    param_types: [16]TypeIndex = undefined,
    param_count: u8 = 0,
    required_param_count: ?u8 = null,
    return_type: TypeIndex = null_type_idx,
    /// Type parameters declared by this signature, in declaration order. Empty
    /// for a monomorphic function. A call to a signature that has these is
    /// instantiated before its arguments are checked.
    type_params: [MAX_TYPE_PARAMS]GenericParam = @splat(.{}),
    type_param_count: u8 = 0,
    /// A declared type predicate (`function isText(v: unknown): v is string`):
    /// which parameter it narrows and what it narrows that parameter to.
    /// Absent on an ordinary function. The declaration alone installs nothing -
    /// the checker admits the guard only after reading the body that claims it.
    type_predicate: ?TypePredicate = null,

    pub fn typeParams(self: *const FunctionSig) []const GenericParam {
        return self.type_params[0..self.type_param_count];
    }
};

pub const TypePredicate = struct {
    /// Position of the named parameter in the signature.
    param_index: u8,
    /// The type the parameter has when the predicate returns true.
    narrowed: TypeIndex,
};

/// Parameter names of one signature, in declaration order.
const ParamNames = struct {
    names: [16][]const u8 = undefined,
    count: u8 = 0,

    fn append(self: *ParamNames, name: []const u8) void {
        if (self.count >= self.names.len) return;
        self.names[self.count] = name;
        self.count += 1;
    }

    fn indexOf(self: *const ParamNames, name: []const u8) ?u8 {
        for (0..self.count) |i| {
            if (std.mem.eql(u8, self.names[i], name)) return @intCast(i);
        }
        return null;
    }
};

/// Split `v is string` into the parameter it names and the type text.
/// Returns null when the text is not a predicate.
pub fn parseTypePredicate(text: []const u8) ?struct { param_name: []const u8, type_text: []const u8 } {
    const marker = " is ";
    const at = std.mem.indexOf(u8, text, marker) orelse return null;
    const param_name = std.mem.trim(u8, text[0..at], " \t\n\r");
    const type_text = std.mem.trim(u8, text[at + marker.len ..], " \t\n\r");
    if (param_name.len == 0 or type_text.len == 0) return null;
    // The parameter position is a plain identifier; anything else means the
    // ` is ` came from inside a type rather than from a predicate.
    for (param_name) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '$') return null;
    }
    return .{ .param_name = param_name, .type_text = type_text };
}

// ---------------------------------------------------------------------------
// Generic type alias (type Result<T> = ...)
// ---------------------------------------------------------------------------

pub const GenericAlias = struct {
    param_names: [8][]const u8 = undefined,
    param_count: u8 = 0,
    body: TypeIndex = null_type_idx,
};

// ---------------------------------------------------------------------------
// Type-parameter lists
// ---------------------------------------------------------------------------

/// One entry of a declared type-parameter list.
pub const TypeParamSpec = struct {
    name: []const u8,
    /// Text of the `extends` bound, empty when unconstrained.
    constraint_text: []const u8 = "",
};

/// Split a declared type-parameter list into its entries.
///
/// The text arrives two ways: a function's list comes in without its angle
/// brackets (`T extends string, U`), a type alias's comes in with them
/// (`<T, U>`), so both are accepted. Splitting on every comma is wrong,
/// because a constraint carries commas of its own inside `<>`, `{}`, `[]`, and
/// `()` - a naive split cuts `U extends Record<string, number>` into two
/// entries, and the second is a type name nothing resolves.
///
/// Returns the number of entries written to `out`.
pub fn splitTypeParams(text: []const u8, out: []TypeParamSpec) usize {
    var pieces: [MAX_TYPE_PARAMS][]const u8 = undefined;
    const piece_count = splitTopLevelCommas(text, &pieces);
    for (pieces[0..piece_count], 0..) |piece, i| {
        if (i >= out.len) return out.len;
        out[i] = parseTypeParamSpec(piece);
    }
    return @min(piece_count, out.len);
}

/// Split a type-argument or type-parameter list on the commas that separate
/// its entries, ignoring the commas nested inside `<>`, `{}`, `[]`, and `()`.
/// A naive split cuts `Record<string, number>` in half and leaves two type
/// names nothing resolves.
///
/// A `>` closes only while a `<` is open. The `>` of an arrow type is not a
/// closer, and counting it as one drove the depth negative and discarded the
/// whole list - so `T extends (s: string) => number` produced no entries at
/// all, and the signature silently lost every type parameter it declared.
///
/// The surrounding angle brackets of an alias's list (`<T, U>`) are stripped
/// first; a function's list arrives without them.
pub fn splitTopLevelCommas(text: []const u8, out: [][]const u8) usize {
    var body = std.mem.trim(u8, text, " \t\n\r");
    if (body.len >= 2 and body[0] == '<' and body[body.len - 1] == '>') {
        body = std.mem.trim(u8, body[1 .. body.len - 1], " \t\n\r");
    }
    if (body.len == 0) return 0;

    var count: usize = 0;
    var angle: u32 = 0;
    var bracket: u32 = 0;
    var piece_start: usize = 0;
    var i: usize = 0;
    while (i <= body.len) : (i += 1) {
        const at_end = i == body.len;
        const c = if (at_end) ',' else body[i];
        switch (c) {
            '<' => angle += 1,
            '>' => if (angle > 0) {
                angle -= 1;
            },
            '{', '[', '(' => bracket += 1,
            '}', ']', ')' => if (bracket > 0) {
                bracket -= 1;
            },
            // exhaustive: only the bracket pairs move the nesting depth. Every
            // other byte, the separating comma included, is handled below.
            else => {},
        }
        if (c != ',' or angle != 0 or bracket != 0) continue;
        const piece = std.mem.trim(u8, body[piece_start..i], " \t\n\r");
        piece_start = i + 1;
        if (piece.len == 0) continue;
        if (count >= out.len) break;
        out[count] = piece;
        count += 1;
    }
    return count;
}

fn parseTypeParamSpec(piece: []const u8) TypeParamSpec {
    // The name runs to the first separator. A default (`T = string`) is not in
    // the admitted subset (spec 5.6 excludes it), so the name stops at `=` as
    // well and whatever follows is left unread rather than resolved as a bound.
    var name_end: usize = piece.len;
    for (piece, 0..) |c, i| {
        if (c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == '=') {
            name_end = i;
            break;
        }
    }
    const name = piece[0..name_end];
    const rest = std.mem.trim(u8, piece[name_end..], " \t\n\r");
    const kw = "extends";
    if (rest.len > kw.len and std.mem.startsWith(u8, rest, kw)) {
        const after = rest[kw.len];
        if (after == ' ' or after == '\t' or after == '\n' or after == '\r') {
            return .{ .name = name, .constraint_text = std.mem.trim(u8, rest[kw.len..], " \t\n\r") };
        }
    }
    return .{ .name = name };
}

// ---------------------------------------------------------------------------
// Type Environment
// ---------------------------------------------------------------------------

pub const TypeEnv = struct {
    const NamedVarAnnotation = struct {
        name: []const u8,
        ordinal: u32,
        type_idx: TypeIndex,
    };

    pool: *TypePool,
    allocator: std.mem.Allocator,

    /// Type namespace: type alias name -> resolved TypeIndex
    type_aliases: std.StringHashMapUnmanaged(TypeIndex),
    /// Generic type aliases: name -> uninstantiated body + param names
    generic_aliases: std.StringHashMapUnmanaged(GenericAlias),
    /// Interface namespace: interface name -> resolved TypeIndex
    interfaces: std.StringHashMapUnmanaged(TypeIndex),
    /// Variable types: packed(context_line, context_col) -> TypeIndex
    var_types: std.AutoHashMapUnmanaged(u32, TypeIndex),
    /// Function signatures: packed(context_line, context_col) -> FunctionSig
    fn_signatures: std.AutoHashMapUnmanaged(u32, FunctionSig),
    /// Variable name -> declared type (for name-based lookup)
    var_types_by_name: std.StringHashMapUnmanaged(TypeIndex),
    /// All variable annotations keyed by semantic (name, occurrence), in source order.
    var_annotations: std.ArrayListUnmanaged(NamedVarAnnotation),
    /// Scoped binding identity: packed(scope_id, name_atom) -> declared type.
    var_types_by_binding: std.AutoHashMapUnmanaged(u32, TypeIndex),
    /// Function name -> signature (for name-based lookup)
    fn_sigs_by_name: std.StringHashMapUnmanaged(FunctionSig),
    /// Source-declared function name -> signature. Kept separate from module
    /// exports so a colliding module name cannot masquerade as a user's
    /// function declaration while binding-local metadata is established.
    source_fn_sigs_by_name: std.StringHashMapUnmanaged(FunctionSig),
    /// Generic scope stack
    generic_scopes: std.ArrayListUnmanaged(GenericScope),
    /// Explicit call-site type arguments, keyed by the byte offset of the
    /// call's `(` in the stripped source.
    call_type_args: std.AutoHashMapUnmanaged(u32, CallTypeArgs),

    /// Stable storage for interned names used as hash-map keys.
    /// Keys must not move after insertion, so each name owns its own allocation.
    name_storage: std.ArrayListUnmanaged([]const u8),

    /// Set when an allocation failed while populating the environment. Every
    /// such failure drops a type alias, an interface, or a function signature
    /// on the floor, and a missing signature is invisible: the annotation
    /// readers below simply find nothing and the caller reads that as "the
    /// author declared nothing". `TypeChecker` and `TypePool` already carry
    /// the same flag for the same reason.
    allocation_failed: bool = false,

    pub fn init(allocator: std.mem.Allocator, pool: *TypePool) TypeEnv {
        var env: TypeEnv = .{
            .pool = pool,
            .allocator = allocator,
            .type_aliases = .empty,
            .generic_aliases = .empty,
            .interfaces = .empty,
            .var_types = .empty,
            .fn_signatures = .empty,
            .var_types_by_name = .empty,
            .var_annotations = .empty,
            .var_types_by_binding = .empty,
            .fn_sigs_by_name = .empty,
            .source_fn_sigs_by_name = .empty,
            .generic_scopes = .empty,
            .call_type_args = .empty,
            .name_storage = .empty,
        };
        env.registerBuiltins();
        return env;
    }

    /// Record that the environment is missing something it was asked to hold.
    /// Callers that read annotations out of it must refuse to answer rather
    /// than report the gap as an absent declaration.
    fn markAllocationFailure(self: *TypeEnv) void {
        self.allocation_failed = true;
    }

    /// Register built-in type aliases (`Spec<S>` and friends) so user code
    /// can write `import type { Spec } from "zttp:types"` and have the
    /// type checker resolve it without a real source file. Idempotent;
    /// user-declared aliases of the same name will overwrite the built-in
    /// (last-write-wins matches the existing populateFromTypeMap pattern).
    pub fn registerBuiltins(self: *TypeEnv) void {
        self.registerSpecBuiltin();
        // Proof<T, S> and Effects<T, S> share the capsule shape
        // `T & { <marker>: S }`; they differ only in the marker field.
        self.registerCapsuleAlias("Proof", spec_marker_field);
        self.registerCapsuleAlias("Effects", effect_marker_field);
    }

    /// Spec<S>: phantom marker carrying the declared spec name set as S.
    /// Registered as a generic alias whose body is a record whose only
    /// field is named `__zttp_spec__` with type S. After instantiation
    /// with a literal-string union, the field type carries the spec
    /// names. The verifier walks return-type intersections to extract
    /// them via extractSpecMembers.
    fn registerSpecBuiltin(self: *TypeEnv) void {
        self.pushGenericScope();
        const s_param = self.addGenericParam("S");
        const field_name = self.pool.addName(self.allocator, spec_marker_field);
        const body = self.pool.addRecord(self.allocator, &.{
            .{
                .name_start = field_name.start,
                .name_len = field_name.len,
                .type_idx = s_param,
                .optional = false,
            },
        });
        self.popGenericScope();

        if (body == null_type_idx) return;

        const owned_name = self.internName("Spec");
        if (owned_name.len == 0) return;
        const owned_param = self.internName("S");

        var alias = GenericAlias{};
        alias.param_names[0] = owned_param;
        alias.param_count = 1;
        alias.body = body;
        self.generic_aliases.put(self.allocator, owned_name, alias) catch self.markAllocationFailure();
    }

    /// Register a two-param capsule alias `Name<T, S>` whose body is
    /// `T & { <marker>: S }` - the shape shared by `Proof<T, S>` (marker
    /// `__zttp_spec__`) and `Effects<T, S>` (marker `__zttp_effect__`).
    /// After instantiation the underlying return type `T` survives for type
    /// checking while the phantom marker record carries `S`. Distinct marker
    /// fields let a return type carry both capsules and have each extraction
    /// (`extractSpecMembers` / `extractEffectMembers`) recover only its own.
    fn registerCapsuleAlias(self: *TypeEnv, alias_name: []const u8, marker_field: []const u8) void {
        self.pushGenericScope();
        const t_param = self.addGenericParam("T");
        const s_param = self.addGenericParam("S");
        const field_name = self.pool.addName(self.allocator, marker_field);
        const marker = self.pool.addRecord(self.allocator, &.{
            .{
                .name_start = field_name.start,
                .name_len = field_name.len,
                .type_idx = s_param,
                .optional = false,
            },
        });
        const body = self.pool.addIntersection(self.allocator, &.{ t_param, marker });
        self.popGenericScope();

        if (body == null_type_idx) return;

        const owned_name = self.internName(alias_name);
        if (owned_name.len == 0) return;
        const owned_t = self.internName("T");
        const owned_s = self.internName("S");

        var alias = GenericAlias{};
        alias.param_names[0] = owned_t;
        alias.param_names[1] = owned_s;
        alias.param_count = 2;
        alias.body = body;
        self.generic_aliases.put(self.allocator, owned_name, alias) catch self.markAllocationFailure();
    }

    pub fn deinit(self: *TypeEnv) void {
        self.type_aliases.deinit(self.allocator);
        self.generic_aliases.deinit(self.allocator);
        self.interfaces.deinit(self.allocator);
        self.var_types.deinit(self.allocator);
        self.fn_signatures.deinit(self.allocator);
        self.var_types_by_name.deinit(self.allocator);
        self.var_annotations.deinit(self.allocator);
        self.var_types_by_binding.deinit(self.allocator);
        self.fn_sigs_by_name.deinit(self.allocator);
        self.source_fn_sigs_by_name.deinit(self.allocator);
        self.generic_scopes.deinit(self.allocator);
        self.call_type_args.deinit(self.allocator);
        for (self.name_storage.items) |name| {
            self.allocator.free(name);
        }
        self.name_storage.deinit(self.allocator);
    }

    // -------------------------------------------------------------------
    // Population from TypeMap
    // -------------------------------------------------------------------

    /// Populate the environment from a TypeMap (extracted by the stripper).
    /// Processes entries in order: type aliases first, then interfaces,
    /// then variable/param/return annotations.
    pub fn populateFromTypeMap(self: *TypeEnv, tm: *const TypeMap) void {
        // First pass: type aliases and interfaces (defines the type namespace)
        // Collect generic_params entries keyed by (name_start, name_end) for alias lookup.
        var generic_params_map: std.AutoHashMapUnmanaged(u64, TypeMapEntry) = .empty;
        defer generic_params_map.deinit(self.allocator);
        for (tm.entries.items) |entry| {
            if (entry.kind == .generic_params and entry.name_start != 0) {
                const key = (@as(u64, entry.name_start) << 32) | entry.name_end;
                generic_params_map.put(self.allocator, key, entry) catch self.markAllocationFailure();
            }
        }

        for (tm.entries.items) |entry| {
            switch (entry.kind) {
                .type_alias => self.processTypeAlias(tm, entry, &generic_params_map),
                .interface_decl => self.processInterface(tm, entry),
                .distinct_type => self.processDistinctType(tm, entry),
                // exhaustive: this is the type-namespace pass. The annotation
                // kinds it skips are consumed by the second pass below, so
                // nothing is dropped - only deferred.
                else => {},
            }
        }

        // Type parameters declared by a signature, keyed by the line the
        // signature starts on - the same key its parameter and return
        // annotations carry. Built before the annotations are resolved,
        // because `xs: T[]` only resolves `T` to a type parameter while that
        // parameter is in scope; without this the name falls through to an
        // unresolved reference and nothing can be inferred from it later.
        var fn_generics_by_line: std.AutoHashMapUnmanaged(u32, DeclaredGenerics) = .empty;
        defer fn_generics_by_line.deinit(self.allocator);
        for (tm.entries.items) |entry| {
            if (entry.kind != .generic_params) continue;
            const declared = self.declareGenerics(tm.getTypeText(entry));
            if (declared.count == 0) continue;
            fn_generics_by_line.put(self.allocator, entry.context_line, declared) catch self.markAllocationFailure();
        }

        // Explicit type arguments at call sites. Keyed by the byte offset of
        // the call's `(`, which is one past the recorded `>`; the stripper
        // blanks rather than deletes, so offsets in the stripped source the
        // parser reads are the offsets recorded here.
        for (tm.entries.items) |entry| {
            if (entry.kind != .call_type_arguments) continue;
            var args: CallTypeArgs = .{};
            // Depth-aware for the same reason the declaration side is: a single
            // type argument carries its own commas, and splitting on all of them
            // made `make<Record<string, number>>(1)` read as two arguments and
            // refused a correct call for the wrong arity.
            var arg_texts: [MAX_TYPE_PARAMS][]const u8 = undefined;
            const arg_count = splitTopLevelCommas(tm.getTypeText(entry), &arg_texts);
            for (arg_texts[0..arg_count]) |arg_text| {
                args.args[args.count] = self.resolveType(arg_text);
                args.count += 1;
            }
            if (args.count == 0) continue;
            self.call_type_args.put(self.allocator, entry.source_end + 1, args) catch self.markAllocationFailure();
        }

        // Second pass: variable and function annotations
        // Group param and return annotations by context line to build function sigs
        var fn_params_by_line: std.AutoHashMapUnmanaged(u32, FunctionSig) = .empty;
        defer fn_params_by_line.deinit(self.allocator);
        var fn_names_by_line: std.AutoHashMapUnmanaged(u32, []const u8) = .empty;
        defer fn_names_by_line.deinit(self.allocator);
        // Parameter names in declaration order, so a type predicate can say
        // which parameter `v is string` names. Only the predicate reads these,
        // so they stay local rather than growing `FunctionSig`.
        var fn_param_names_by_line: std.AutoHashMapUnmanaged(u32, ParamNames) = .empty;
        defer fn_param_names_by_line.deinit(self.allocator);

        for (tm.entries.items) |entry| {
            switch (entry.kind) {
                .var_annotation => self.processVarAnnotation(tm, entry),
                .param_annotation => {
                    const gop = fn_params_by_line.getOrPut(self.allocator, entry.context_line) catch {
                        self.markAllocationFailure();
                        continue;
                    };
                    if (!gop.found_existing) {
                        gop.value_ptr.* = .{};
                    }
                    const type_text = tm.getTypeText(entry);
                    const generics = fn_generics_by_line.get(entry.context_line);
                    const type_idx = self.resolveTypeInGenerics(type_text, generics);
                    if (gop.value_ptr.param_count < 16) {
                        gop.value_ptr.param_types[gop.value_ptr.param_count] = type_idx;
                        gop.value_ptr.param_count += 1;
                    }
                    if (tm.getNameText(entry)) |param_name| {
                        const names = fn_param_names_by_line.getOrPut(self.allocator, entry.context_line) catch {
                            self.markAllocationFailure();
                            continue;
                        };
                        if (!names.found_existing) names.value_ptr.* = .{};
                        names.value_ptr.append(self.internName(param_name));
                    }
                },
                .return_annotation => {
                    const type_text = tm.getTypeText(entry);
                    const generics = fn_generics_by_line.get(entry.context_line);
                    const type_idx = self.resolveTypeInGenerics(type_text, generics);
                    const gop = fn_params_by_line.getOrPut(self.allocator, entry.context_line) catch {
                        self.markAllocationFailure();
                        continue;
                    };
                    if (!gop.found_existing) {
                        gop.value_ptr.* = .{};
                    }
                    gop.value_ptr.return_type = type_idx;
                    if (tm.getNameText(entry)) |name| {
                        const owned_name = self.internName(name);
                        fn_names_by_line.put(self.allocator, entry.context_line, owned_name) catch self.markAllocationFailure();
                    }
                },
                .type_guard_annotation => {
                    // `v is string` is a return annotation that also declares a
                    // narrowing. The function returns a boolean; the predicate
                    // is recorded next to the signature and admitted later,
                    // once the checker has read the body that claims it.
                    const gop = fn_params_by_line.getOrPut(self.allocator, entry.context_line) catch {
                        self.markAllocationFailure();
                        continue;
                    };
                    if (!gop.found_existing) {
                        gop.value_ptr.* = .{};
                    }
                    gop.value_ptr.return_type = self.pool.idx_boolean;
                    if (tm.getNameText(entry)) |name| {
                        const owned_name = self.internName(name);
                        fn_names_by_line.put(self.allocator, entry.context_line, owned_name) catch self.markAllocationFailure();
                    }
                    const parsed = parseTypePredicate(tm.getTypeText(entry)) orelse continue;
                    const names = fn_param_names_by_line.get(entry.context_line) orelse continue;
                    const index = names.indexOf(parsed.param_name) orelse continue;
                    const generics = fn_generics_by_line.get(entry.context_line);
                    const narrowed = self.resolveTypeInGenerics(parsed.type_text, generics);
                    if (narrowed == null_type_idx) continue;
                    gop.value_ptr.type_predicate = .{ .param_index = index, .narrowed = narrowed };
                },
                // exhaustive: mirror of the first pass. The kinds skipped here
                // are the type-namespace ones already processed above.
                else => {},
            }
        }

        // Merge function signatures
        var iter = fn_params_by_line.iterator();
        while (iter.next()) |kv| {
            if (fn_generics_by_line.get(kv.key_ptr.*)) |declared| {
                kv.value_ptr.type_params = declared.params;
                kv.value_ptr.type_param_count = declared.count;
            }
            self.fn_signatures.put(self.allocator, kv.key_ptr.*, kv.value_ptr.*) catch self.markAllocationFailure();
            if (fn_names_by_line.get(kv.key_ptr.*)) |name| {
                self.fn_sigs_by_name.put(self.allocator, name, kv.value_ptr.*) catch self.markAllocationFailure();
                self.source_fn_sigs_by_name.put(self.allocator, name, kv.value_ptr.*) catch self.markAllocationFailure();
            }
        }
    }

    const DeclaredGenerics = struct {
        params: [MAX_TYPE_PARAMS]GenericParam = @splat(.{}),
        count: u8 = 0,
    };

    /// Resolve a declared type-parameter list into pool nodes plus bounds.
    /// Constraints resolve with every parameter of the list already in scope,
    /// so `<T, U extends T>` sees `T`.
    fn declareGenerics(self: *TypeEnv, params_text: []const u8) DeclaredGenerics {
        var specs: [MAX_TYPE_PARAMS]TypeParamSpec = undefined;
        const spec_count = splitTypeParams(params_text, &specs);
        if (spec_count == 0) return .{};

        var declared: DeclaredGenerics = .{};
        const depth_before = self.generic_scopes.items.len;
        self.pushGenericScope();
        if (self.generic_scopes.items.len == depth_before) return .{};
        defer self.popGenericScope();
        for (specs[0..spec_count]) |spec| {
            if (spec.name.len == 0) continue;
            declared.params[declared.count] = .{
                .name = self.internName(spec.name),
                .idx = self.addGenericParam(spec.name),
            };
            declared.count += 1;
        }
        for (specs[0..spec_count], 0..) |spec, i| {
            if (i >= declared.count) break;
            if (spec.constraint_text.len == 0) continue;
            const constraint = self.resolveType(spec.constraint_text);
            declared.params[i].constraint = constraint;
            self.generic_scopes.items[self.generic_scopes.items.len - 1].setConstraint(spec.name, constraint);
        }
        return declared;
    }

    /// Resolve an annotation with a signature's type parameters in scope, so a
    /// bare `T` reaches the parameter node rather than a same-named alias.
    fn resolveTypeInGenerics(self: *TypeEnv, type_text: []const u8, generics: ?DeclaredGenerics) TypeIndex {
        const declared = generics orelse return self.resolveType(type_text);
        if (declared.count == 0) return self.resolveType(type_text);
        const depth_before = self.generic_scopes.items.len;
        self.pushGenericScope();
        if (self.generic_scopes.items.len == depth_before) return self.resolveType(type_text);
        defer self.popGenericScope();
        const top = &self.generic_scopes.items[self.generic_scopes.items.len - 1];
        for (declared.params[0..declared.count]) |param| {
            top.addConstrainedParam(param.name, param.idx, param.constraint);
        }
        return self.resolveType(type_text);
    }

    fn processTypeAlias(
        self: *TypeEnv,
        tm: *const TypeMap,
        entry: TypeMapEntry,
        generic_params_map: *const std.AutoHashMapUnmanaged(u64, TypeMapEntry),
    ) void {
        const name = tm.getNameText(entry) orelse return;
        const type_text = tm.getTypeText(entry);
        if (type_text.len == 0) return;

        // Check for matching generic_params entry (same name range).
        const gp_key = (@as(u64, entry.name_start) << 32) | entry.name_end;
        if (generic_params_map.get(gp_key)) |gp_entry| {
            const params_text = tm.getTypeText(gp_entry);
            if (params_text.len > 0) {
                // Parse comma-separated param names and resolve body in generic scope.
                var alias = GenericAlias{};
                self.pushGenericScope();

                // The stripper records an alias's list with its angle brackets
                // still on (`<V>`), so splitting on commas alone made the one
                // parameter name `<V>`, which no `t_ref` in the body ever
                // matched: every generic alias resolved to its uninstantiated
                // body and every argument checked against it was accepted.
                var specs: [MAX_TYPE_PARAMS]TypeParamSpec = undefined;
                const spec_count = splitTypeParams(params_text, &specs);
                for (specs[0..spec_count]) |spec| {
                    if (spec.name.len == 0) continue;
                    if (alias.param_count >= 8) break;
                    _ = self.addGenericParam(spec.name);
                    alias.param_names[alias.param_count] = self.internName(spec.name);
                    alias.param_count += 1;
                }

                alias.body = self.resolveType(type_text);
                self.popGenericScope();

                const owned_name = self.internName(name);
                self.generic_aliases.put(self.allocator, owned_name, alias) catch self.markAllocationFailure();
                return;
            }
        }

        // Non-generic alias: simple name -> type mapping.
        const type_idx = self.resolveType(type_text);
        const owned_name = self.internName(name);
        self.type_aliases.put(self.allocator, owned_name, type_idx) catch self.markAllocationFailure();
    }

    fn processDistinctType(self: *TypeEnv, tm: *const TypeMap, entry: TypeMapEntry) void {
        const name = tm.getNameText(entry) orelse return;
        const type_text = tm.getTypeText(entry);
        if (type_text.len == 0) return;

        // Resolve the base type, then create a nominal alias.
        const base_idx = self.resolveType(type_text);
        if (base_idx == null_type_idx) return;
        const nominal_idx = self.pool.addNominalAlias(self.allocator, base_idx, name);
        if (nominal_idx == null_type_idx) return;

        const owned_name = self.internName(name);
        self.type_aliases.put(self.allocator, owned_name, nominal_idx) catch self.markAllocationFailure();
    }

    fn processInterface(self: *TypeEnv, tm: *const TypeMap, entry: TypeMapEntry) void {
        const name = tm.getNameText(entry) orelse return;
        const type_text = tm.getTypeText(entry);
        if (type_text.len == 0) return;

        const type_idx = self.resolveType(type_text);

        // Check if all members are function-typed -> mark as nominal (capability interface)
        if (type_idx != null_type_idx and self.pool.getTag(type_idx) == .t_record) {
            const fields = self.pool.getRecordFields(type_idx);
            var all_functions = fields.len > 0;
            for (fields) |field| {
                const ftag = self.pool.getTag(field.type_idx);
                if (ftag != .t_function and ftag != null) {
                    all_functions = false;
                    break;
                }
            }
            if (all_functions and type_idx < self.pool.nodes.items.len) {
                self.pool.markNominal(self.allocator, type_idx, name);
            }
        }

        const owned_name = self.internName(name);
        self.interfaces.put(self.allocator, owned_name, type_idx) catch self.markAllocationFailure();
    }

    fn processVarAnnotation(self: *TypeEnv, tm: *const TypeMap, entry: TypeMapEntry) void {
        const type_text = tm.getTypeText(entry);
        if (type_text.len == 0) return;

        const type_idx = self.resolveType(type_text);
        const key = packLocationKey(entry.context_line, entry.context_col);
        self.var_types.put(self.allocator, key, type_idx) catch self.markAllocationFailure();

        // Also store by name for name-based lookup
        if (tm.getNameText(entry)) |name| {
            const owned_name = self.internName(name);
            self.var_types_by_name.put(self.allocator, owned_name, type_idx) catch self.markAllocationFailure();
            if (entry.name_ordinal) |ordinal| {
                self.var_annotations.append(self.allocator, .{
                    .name = owned_name,
                    .ordinal = ordinal,
                    .type_idx = type_idx,
                }) catch self.markAllocationFailure();
            }
        }
    }

    // -------------------------------------------------------------------
    // Type resolution
    // -------------------------------------------------------------------

    /// Resolve a type expression string to a TypeIndex.
    /// Checks type aliases and interfaces before falling back to the parser.
    /// For generic applications (e.g. Result<string>), instantiates the generic
    /// alias body by substituting type parameters with the provided arguments.
    pub fn resolveType(self: *TypeEnv, type_text: []const u8) TypeIndex {
        // Trim whitespace
        const trimmed = std.mem.trim(u8, type_text, " \t\n\r");
        if (trimmed.len == 0) return null_type_idx;

        // Check type aliases
        if (self.type_aliases.get(trimmed)) |idx| return idx;
        // Check interfaces
        if (self.interfaces.get(trimmed)) |idx| return idx;
        // Check generic scope stack (innermost first)
        if (self.generic_scopes.items.len > 0) {
            var i = self.generic_scopes.items.len;
            while (i > 0) {
                i -= 1;
                if (self.generic_scopes.items[i].resolve(trimmed)) |idx| return idx;
            }
        }
        // Fall back to type expression parser
        const parsed = parseTypeExpr(self.pool, self.allocator, trimmed);

        // If the parser produced a generic application (e.g. Result<string>),
        // try to instantiate it against a known generic alias.
        return self.tryInstantiateGenericApp(parsed);
    }

    /// Outcome of instantiating the members of a composite type. `unchanged`
    /// lets the caller keep the original index instead of interning an
    /// identical type; `changed` hands over an owned slice the caller frees.
    const CompositeMembers = union(enum) {
        failed,
        unchanged,
        changed: []TypeIndex,
    };

    /// Instantiate every member of an intersection or union.
    ///
    /// `live` is borrowed from the pool's shared members list, which a nested
    /// instantiation may reallocate, so it is copied before the loop runs.
    /// Reading through `live` inside the loop is a use-after-free that yields
    /// garbage TypeIndex values.
    ///
    /// Intersection and union differ only in which getter produced `live` and
    /// which adder consumes the result, so both go through here: the copy
    /// discipline and the member-count handling are stated once.
    fn instantiateCompositeMembers(self: *TypeEnv, live: []const TypeIndex) CompositeMembers {
        const new_members = self.allocator.dupe(TypeIndex, live) catch {
            if (self.pool.failure == null) self.pool.failure = error.OutOfMemory;
            return .failed;
        };
        var changed = false;
        for (new_members) |*member| {
            const m = member.*;
            member.* = self.tryInstantiateGenericApp(m);
            if (member.* != m) changed = true;
        }
        if (!changed) {
            self.allocator.free(new_members);
            return .unchanged;
        }
        return .{ .changed = new_members };
    }

    /// If idx is a t_generic_app whose base resolves to a generic alias,
    /// instantiate the alias body with the provided type arguments.
    /// Recurses through intersection and union members so a generic
    /// application nested inside `Response & Spec<...>` or
    /// `Result<T> | Foo` is instantiated as well.
    fn tryInstantiateGenericApp(self: *TypeEnv, idx: TypeIndex) TypeIndex {
        if (idx == null_type_idx) return idx;
        const tag = self.pool.getTag(idx) orelse return idx;

        switch (tag) {
            .t_generic_app => {
                const info = self.pool.getGenericAppInfo(idx);
                if (info.base == null_type_idx) return idx;
                const base_name = self.pool.getRefName(info.base);
                if (base_name.len == 0) return idx;

                // Built-in utility types Pick/Omit/Partial/Required. Resolved
                // here (not at parse time like Readonly<T>) because resolving
                // a named source type to its record needs the alias/interface
                // maps, which only exist on TypeEnv.
                if (utilityKind(base_name)) |kind| {
                    const want_args: usize = switch (kind) {
                        .partial, .required, .readonly => 1,
                        .pick, .omit => 2,
                    };
                    if (info.args.len < want_args) return idx;
                    // Copy args before any transform: generic-app args live in
                    // the pool's shared members list, which a transform's
                    // addRecord/addUnion may reallocate.
                    var raw_args: [8]TypeIndex = undefined;
                    const uargc = @min(info.args.len, raw_args.len);
                    @memcpy(raw_args[0..uargc], info.args[0..uargc]);

                    // `Readonly<T>` is the one utility whose source need not be
                    // a record: an array source is `readonly T[]`, which is how
                    // the `readonly Items` spelling reaches an alias at all -
                    // the type-expression parser has no alias map and defers the
                    // modifier here. Resolving the name to nothing would leave
                    // an unresolved application, which assignability fail-opens
                    // on, so an unrecognized source resolves to itself rather
                    // than staying wrapped.
                    if (kind == .readonly) {
                        const resolved = self.resolveRef(self.tryInstantiateGenericApp(raw_args[0]));
                        if (resolved == null_type_idx) return idx;
                        if (self.pool.getTag(resolved) == .t_array) {
                            if (self.pool.isReadonlyArray(resolved)) return resolved;
                            return self.pool.addReadonlyArray(self.allocator, self.pool.getArrayElement(resolved));
                        }
                        if (self.pool.getTag(resolved) == .t_record) {
                            return self.pool.makeReadonly(self.allocator, resolved);
                        }
                        return resolved;
                    }

                    const src = self.resolveRefToRecord(self.tryInstantiateGenericApp(raw_args[0]));
                    if (src == null_type_idx) return idx;
                    // Resolve the keys argument through the alias map too, so
                    // `type K = "id" | "name"; Pick<User, K>` sees the literal
                    // union instead of an unresolved t_ref (which collectStringKeys
                    // reads as zero keys, silently returning the full source - an
                    // unsound over-accept).
                    const keys = if (kind == .pick or kind == .omit)
                        self.resolveRef(self.tryInstantiateGenericApp(raw_args[1]))
                    else
                        null_type_idx;
                    return switch (kind) {
                        .partial => self.pool.makePartial(self.allocator, src),
                        .required => self.pool.makeRequired(self.allocator, src),
                        .readonly => self.pool.makeReadonly(self.allocator, src),
                        .pick => self.pool.pickFields(self.allocator, src, keys),
                        .omit => self.pool.omitFields(self.allocator, src, keys),
                    };
                }

                const alias = self.generic_aliases.get(base_name) orelse return idx;
                if (info.args.len != alias.param_count) return idx;
                // Copy args before instantiating: info.args is a slice into the
                // pool's shared members list, and a nested instantiation's
                // addRecord/addUnion may reallocate it, dangling the slice
                // mid-loop. Instantiate nested generic-app arguments first, so a
                // composed type like `Proof<Effects<string, "env">, "pure">`
                // carries both the proof marker and the effect marker.
                var inst_args: [8]TypeIndex = undefined;
                const argc = @min(info.args.len, inst_args.len);
                @memcpy(inst_args[0..argc], info.args[0..argc]);
                for (0..argc) |i| {
                    inst_args[i] = self.tryInstantiateGenericApp(inst_args[i]);
                }
                return self.pool.instantiate(
                    self.allocator,
                    alias.body,
                    alias.param_names[0..alias.param_count],
                    inst_args[0..argc],
                    0,
                );
            },
            .t_intersection => switch (self.instantiateCompositeMembers(self.pool.getIntersectionMembers(idx))) {
                .failed => return null_type_idx,
                .unchanged => return idx,
                .changed => |members| {
                    defer self.allocator.free(members);
                    return self.pool.addIntersection(self.allocator, members);
                },
            },
            .t_union => switch (self.instantiateCompositeMembers(self.pool.getUnionMembers(idx))) {
                .failed => return null_type_idx,
                .unchanged => return idx,
                .changed => |members| {
                    defer self.allocator.free(members);
                    return self.pool.addUnion(self.allocator, members);
                },
            },
            .t_nullable => {
                // `Effects<Response, "env"> | undefined` parses as a nullable
                // wrapping an uninstantiated generic application. Without this
                // arm the wrapper is returned as-is, the marker search below
                // finds a `t_generic_app` it has no case for, and the ceiling
                // reads as absent - so the annotation the author wrote never
                // bound anything.
                const inner = self.pool.getNullableInner(idx);
                const instantiated = self.tryInstantiateGenericApp(inner);
                if (instantiated == inner) return idx;
                return self.pool.addNullable(self.allocator, instantiated);
            },
            // exhaustive: returning the index unchanged is the identity, not a
            // dropped case. Every tag that can wrap or be a generic application
            // is handled above; the rest have nothing to instantiate, and the
            // caller gets back the same type it passed in.
            else => return idx,
        }
    }

    /// Follow a t_ref through the alias then interface map to its underlying
    /// type, chasing chains (`type A = B; type B = {...}` stores A as t_ref(B))
    /// up to a small depth with a self-reference guard. Non-ref types and
    /// unresolved refs pass through unchanged.
    fn resolveRef(self: *const TypeEnv, idx: TypeIndex) TypeIndex {
        var cur = idx;
        var depth: u8 = 0;
        while (depth < 8) : (depth += 1) {
            const tag = self.pool.getTag(cur) orelse return cur;
            if (tag != .t_ref) return cur;
            const name = self.pool.getRefName(cur);
            if (name.len == 0) return cur;
            const next = self.type_aliases.get(name) orelse self.interfaces.get(name) orelse return cur;
            if (next == cur) return cur;
            cur = next;
        }
        return cur;
    }

    /// Type-aware assignability for checks that need the environment's alias
    /// table. The pool alone cannot distinguish an object-like named type from
    /// a named alias of a primitive.
    pub fn isAssignableTo(self: *const TypeEnv, source: TypeIndex, target: TypeIndex) bool {
        const target_tag = self.pool.getTag(target) orelse return false;
        if (target_tag == .t_nullable) {
            const source_tag = self.pool.getTag(source) orelse return false;
            if (source_tag == .t_null or source_tag == .t_undefined) return true;
            const target_inner = self.pool.getNullableInner(target);
            if (source_tag == .t_nullable) {
                return self.isAssignableTo(self.pool.getNullableInner(source), target_inner);
            }
            return self.isAssignableTo(source, target_inner);
        }

        if (target_tag == .t_ref and std.mem.eql(u8, self.pool.getRefName(target), "object")) {
            return self.isObjectLike(source, 0);
        }

        return self.pool.isAssignableTo(source, target);
    }

    fn isObjectLike(self: *const TypeEnv, source: TypeIndex, depth: u8) bool {
        const source_tag = self.pool.getTag(source) orelse return false;
        return switch (source_tag) {
            .t_never => true,
            .t_record, .t_array, .t_tuple, .t_function => true,
            .t_ref => blk: {
                const resolved = self.resolveRef(source);
                if (resolved != source and depth < 8) {
                    break :blk self.isObjectLike(resolved, depth + 1);
                }
                // Request/WebSocket-style nominal refs have no definition in
                // TypeEnv, so unresolved named refs are pragmatically object-like.
                // This over-accepts an unresolved primitive alias such as
                // `type Foo = string`; aliases present in TypeEnv resolve above.
                break :blk true;
            },
            .t_union => blk: {
                const members = self.pool.getUnionMembers(source);
                if (members.len == 0) break :blk false;
                for (members) |member| {
                    if (!self.isObjectLike(member, depth)) break :blk false;
                }
                break :blk true;
            },
            else => false,
        };
    }

    /// Resolve a type to a record: a record passes through, a named ref resolves
    /// via resolveRef (following alias chains), otherwise null_type_idx. Used by
    /// the utility-type path to find the source object's fields.
    fn resolveRefToRecord(self: *const TypeEnv, idx: TypeIndex) TypeIndex {
        if (idx == null_type_idx) return null_type_idx;
        const resolved = self.resolveRef(idx);
        const tag = self.pool.getTag(resolved) orelse return null_type_idx;
        return if (tag == .t_record) resolved else null_type_idx;
    }

    /// Look up a variable's declared type by name.
    pub fn getVarTypeByName(self: *const TypeEnv, name: []const u8) ?TypeIndex {
        return self.var_types_by_name.get(name);
    }

    /// Resolve one declaration annotation by semantic name occurrence.
    pub fn getVarTypeByNameOrdinal(self: *const TypeEnv, name: []const u8, ordinal: u32) ?TypeIndex {
        for (self.var_annotations.items) |annotation| {
            if (annotation.ordinal == ordinal and std.mem.eql(u8, annotation.name, name)) {
                return annotation.type_idx;
            }
        }
        return null;
    }

    pub fn varAnnotationCount(self: *const TypeEnv) usize {
        return self.var_annotations.items.len;
    }

    pub fn bindVarType(self: *TypeEnv, scope_id: u16, name_atom: u16, type_idx: TypeIndex) !void {
        try self.var_types_by_binding.put(self.allocator, packBindingNameKey(scope_id, name_atom), type_idx);
    }

    pub fn getVarTypeByBinding(self: *const TypeEnv, scope_id: u16, name_atom: u16) ?TypeIndex {
        return self.var_types_by_binding.get(packBindingNameKey(scope_id, name_atom));
    }

    /// Look up a function signature by name.
    pub fn getFnSigByName(self: *const TypeEnv, name: []const u8) ?FunctionSig {
        return self.fn_sigs_by_name.get(name);
    }

    /// Look up only a signature declared by the checked source. Module export
    /// signatures deliberately do not participate in this lookup.
    pub fn getSourceFnSigByName(self: *const TypeEnv, name: []const u8) ?FunctionSig {
        return self.source_fn_sigs_by_name.get(name);
    }

    /// Look up a type alias by name.
    pub fn getTypeAlias(self: *const TypeEnv, name: []const u8) ?TypeIndex {
        return self.type_aliases.get(name);
    }

    /// Look up an interface by name.
    pub fn getInterface(self: *const TypeEnv, name: []const u8) ?TypeIndex {
        return self.interfaces.get(name);
    }

    /// Look up a function signature by source location.
    pub fn getFnSigByLoc(self: *const TypeEnv, line: u32) ?FunctionSig {
        return self.fn_signatures.get(line);
    }

    /// Explicit type arguments written at the call whose `(` sits at `offset`.
    pub fn getCallTypeArgs(self: *const TypeEnv, offset: u32) ?CallTypeArgs {
        return self.call_type_args.get(offset);
    }

    /// Walk a TypeIndex (typically a function return-type annotation),
    /// following intersections and resolving alias references, and append
    /// every declared spec name string found inside a `Spec<...>` marker
    /// to `out`. Strings live as long as the type pool's name storage;
    /// the caller must not free them. Safe to call when no spec marker is
    /// present (the slice stays empty). Read the returned `non_literal` before
    /// treating an empty slice as "no marker".
    pub fn extractSpecMembers(
        self: *const TypeEnv,
        idx: TypeIndex,
        out: *std.ArrayListUnmanaged([]const u8),
    ) std.mem.Allocator.Error!MarkerExtraction {
        if (self.allocation_failed) return error.OutOfMemory;
        var status: MarkerExtraction = .{};
        try self.collectMarkedMembers(idx, out, spec_marker_field, 0, &status);
        return status;
    }

    /// Like `extractSpecMembers`, but recovers the capability name strings
    /// inside an `Effects<...>` marker. A return type may carry both an
    /// `Effects<...>` and a `Spec<...>` / `Proof<...>` marker; each extraction
    /// keys on its own field name and ignores the other.
    pub fn extractEffectMembers(
        self: *const TypeEnv,
        idx: TypeIndex,
        out: *std.ArrayListUnmanaged([]const u8),
    ) std.mem.Allocator.Error!MarkerExtraction {
        // A degraded environment may be missing the very signature this is
        // asked to read. Answering "no annotation" from a gap in the
        // environment is the same fail-open ZTS511 closes one layer up, so
        // surface the allocation failure that actually happened instead.
        if (self.allocation_failed) return error.OutOfMemory;
        var status: MarkerExtraction = .{};
        try self.collectMarkedMembers(idx, out, effect_marker_field, 0, &status);
        return status;
    }

    /// Strip phantom proof-marker members (the capsule records behind
    /// `Spec<...>`, `Proof<...>`, and `Effects<...>`) from a declared type,
    /// returning the value type a returned expression must actually satisfy.
    /// Markers are compile-time obligations discharged by the verifier and
    /// the contract extractor, never by the runtime value, so `return s`
    /// with `s: string` satisfies a declared `Effects<string, "env">`.
    /// Non-intersection types pass through unchanged.
    pub fn stripProofMarkers(self: *const TypeEnv, idx: TypeIndex) TypeIndex {
        if (idx == null_type_idx) return idx;
        const tag = self.pool.getTag(idx) orelse return idx;
        if (tag != .t_intersection) return idx;

        var kept: [8]TypeIndex = undefined;
        var kept_count: usize = 0;
        for (self.pool.getIntersectionMembers(idx)) |member| {
            if (self.isProofMarkerRecord(member)) continue;
            // Recurse into nested intersections so composed markers like
            // Proof<Effects<string, "env">, "pure"> are fully stripped.
            const stripped_member = self.stripProofMarkers(member);
            if (stripped_member == null_type_idx) continue;
            // Wider intersections than the buffer: keep the declared type
            // unchanged rather than silently dropping members.
            if (kept_count >= kept.len) return idx;
            kept[kept_count] = stripped_member;
            kept_count += 1;
        }
        if (kept_count == 0) return idx;
        if (kept_count == 1) return kept[0];
        return self.pool.addIntersection(self.allocator, kept[0..kept_count]);
    }

    /// True when `idx` is (or aliases to) a single-field record whose only
    /// field is one of the phantom proof-marker fields.
    fn isProofMarkerRecord(self: *const TypeEnv, idx0: TypeIndex) bool {
        var idx = idx0;
        var depth: u8 = 0;
        while (depth < 8) : (depth += 1) {
            const tag = self.pool.getTag(idx) orelse return false;
            switch (tag) {
                .t_ref => {
                    const name = self.pool.getRefName(idx);
                    idx = self.type_aliases.get(name) orelse return false;
                },
                .t_record => {
                    const fields = self.pool.getRecordFields(idx);
                    if (fields.len != 1) return false;
                    const fname = self.pool.getName(fields[0].name_start, fields[0].name_len);
                    return std.mem.eql(u8, fname, spec_marker_field) or
                        std.mem.eql(u8, fname, effect_marker_field);
                },
                // exhaustive: false narrows erasure - the member is kept rather
                // than stripped, so the returned expression must satisfy a type
                // that still carries the phantom field. That can only reject a
                // valid return, never let an undischarged proof through.
                else => return false,
            }
        }
        return false;
    }

    /// Search a return type for `marker` and read the payload behind it.
    ///
    /// Failing to find a marker is not a fail-open: the capsule is opt-in, so
    /// an unannotated return type legitimately yields nothing. Only the
    /// payload reader below can fail open, so only it sets `status`. The one
    /// exception is depth exhaustion, which can hide a marker that is present;
    /// that case fails closed.
    fn collectMarkedMembers(
        self: *const TypeEnv,
        idx: TypeIndex,
        out: *std.ArrayListUnmanaged([]const u8),
        marker: []const u8,
        depth: u8,
        status: *MarkerExtraction,
    ) std.mem.Allocator.Error!void {
        if (idx == null_type_idx) return;
        if (depth > max_marker_depth) {
            status.non_literal = true;
            return;
        }
        const tag = self.pool.getTag(idx) orelse return;

        switch (tag) {
            .t_intersection => {
                for (self.pool.getIntersectionMembers(idx)) |member| {
                    try self.collectMarkedMembers(member, out, marker, depth + 1, status);
                }
            },
            .t_ref => {
                const name = self.pool.getRefName(idx);
                if (self.type_aliases.get(name)) |resolved| {
                    try self.collectMarkedMembers(resolved, out, marker, depth + 1, status);
                }
            },
            .t_nullable => {
                // A nullable-wrapped marker (`Effects<...> | undefined`) still
                // carries the obligation; descend into the inner type so the
                // capability/spec set is recovered.
                try self.collectMarkedMembers(self.pool.getNullableInner(idx), out, marker, depth + 1, status);
            },
            .t_union => {
                // `Effects<Response, "env"> | string` puts the marker on one
                // branch only, so there is no single ceiling for the type. The
                // ceiling is present and unreadable, which is not the same as
                // absent: report it rather than returning the empty set that
                // every consumer reads as "the author declared nothing".
                for (self.pool.getUnionMembers(idx)) |member| {
                    var probe: std.ArrayListUnmanaged([]const u8) = .empty;
                    defer probe.deinit(self.allocator);
                    var probe_status: MarkerExtraction = .{};
                    try self.collectMarkedMembers(member, &probe, marker, depth + 1, &probe_status);
                    if (probe.items.len > 0 or probe_status.non_literal) {
                        status.non_literal = true;
                        return;
                    }
                }
            },
            .t_record => {
                for (self.pool.getRecordFields(idx)) |field| {
                    const fname = self.pool.getName(field.name_start, field.name_len);
                    if (std.mem.eql(u8, fname, marker)) {
                        try self.collectLiteralUnionStrings(field.type_idx, out, 0, status);
                    }
                }
            },
            // exhaustive: the remaining tags are value types that cannot
            // contain a marker record - a marker only ever reaches a return
            // type through an intersection, an alias ref, a nullable wrapper,
            // or a union, each handled above. Finding no marker is not a
            // fail-open: the capsule is opt-in, so an unannotated return type
            // legitimately yields nothing.
            else => {},
        }
    }

    /// Read a marker payload as a closed union of string literals.
    ///
    /// Every path that cannot produce a name sets `status.non_literal`, so an
    /// empty result is never mistaken for a declared-empty set. Allocation
    /// failure propagates rather than truncating the set in silence.
    fn collectLiteralUnionStrings(
        self: *const TypeEnv,
        idx: TypeIndex,
        out: *std.ArrayListUnmanaged([]const u8),
        depth: u8,
        status: *MarkerExtraction,
    ) std.mem.Allocator.Error!void {
        if (depth > max_marker_depth) {
            status.non_literal = true;
            return;
        }
        const tag = self.pool.getTag(idx) orelse {
            status.non_literal = true;
            return;
        };
        switch (tag) {
            .t_union => {
                for (self.pool.getUnionMembers(idx)) |member| {
                    try self.collectLiteralUnionStrings(member, out, depth + 1, status);
                }
            },
            .t_ref => {
                // An aliased capability set (`type Caps = "clock" | "crypto";`
                // used as `Effects<Response, Caps>`) reaches here as a t_ref.
                // Resolve through the alias/interface chain and recurse so the
                // literal names are recovered; without this the budget extracts
                // zero effects and the capability proof silently fails open.
                const resolved = self.resolveRef(idx);
                if (resolved != idx) {
                    try self.collectLiteralUnionStrings(resolved, out, depth + 1, status);
                } else {
                    // The reference does not resolve to anything the pool
                    // holds, so the payload is not a closed literal union.
                    status.non_literal = true;
                }
            },
            .t_literal_string => {
                if (self.pool.getLiteralStringValue(idx)) |val| {
                    try out.append(self.allocator, val);
                } else {
                    status.non_literal = true;
                }
            },
            // A computed, generic, primitive, or otherwise non-literal payload
            // (`Effects<Response, SomeComputedThing>`). Extracting nothing here
            // and reporting it as "no annotation" is the fail-open D2 5 names.
            else => status.non_literal = true,
        }
    }

    // -------------------------------------------------------------------
    // Generic scope management
    // -------------------------------------------------------------------

    pub fn pushGenericScope(self: *TypeEnv) void {
        self.generic_scopes.append(self.allocator, .{}) catch self.markAllocationFailure();
    }

    pub fn popGenericScope(self: *TypeEnv) void {
        if (self.generic_scopes.items.len > 0) {
            _ = self.generic_scopes.pop();
        }
    }

    pub fn addGenericParam(self: *TypeEnv, name: []const u8) TypeIndex {
        const idx = self.pool.addGenericParam(self.allocator, name);
        if (self.generic_scopes.items.len > 0) {
            self.generic_scopes.items[self.generic_scopes.items.len - 1].addParam(name, idx);
        }
        return idx;
    }

    // -------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------

    pub fn internName(self: *TypeEnv, name: []const u8) []const u8 {
        // The empty-string fallback is a key nothing will match, so every
        // lookup keyed on this name silently misses. Record the failure so a
        // reader refuses to answer instead of reporting the gap as an absent
        // declaration.
        const owned = self.allocator.dupe(u8, name) catch {
            self.markAllocationFailure();
            return "";
        };
        self.name_storage.append(self.allocator, owned) catch {
            self.allocator.free(owned);
            self.markAllocationFailure();
            return "";
        };
        return owned;
    }
};

fn packLocationKey(line: u32, col: u32) u32 {
    // Pack line (20 bits) + col (12 bits) into u32
    return (line << 12) | (col & 0xFFF);
}

fn packBindingNameKey(scope_id: u16, name_atom: u16) u32 {
    return (@as(u32, scope_id) << 16) | name_atom;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

fn installTestBoxGenericAlias(env: *TypeEnv) !void {
    const allocator = env.allocator;
    const pool = env.pool;

    env.pushGenericScope();
    _ = env.addGenericParam("T");
    const value_name = pool.addName(allocator, "value");
    const body = pool.addRecord(allocator, &.{.{
        .name_start = value_name.start,
        .name_len = value_name.len,
        .type_idx = env.resolveType("T"),
        .optional = false,
    }});
    env.popGenericScope();

    try env.generic_aliases.put(allocator, env.internName("Box"), .{
        .param_names = .{ env.internName("T"), undefined, undefined, undefined, undefined, undefined, undefined, undefined },
        .param_count = 1,
        .body = body,
    });
}

test "TypeEnv basic type alias resolution" {
    const allocator = std.testing.allocator;
    var pool = TypePool.init(allocator);
    defer pool.deinit(allocator);

    var env = TypeEnv.init(allocator, &pool);
    defer env.deinit();

    // Simulate: type Config = { port: number }
    const source = "type Config = { port: number };";
    var tm = TypeMap.init(source);
    defer tm.deinit(allocator);

    try tm.addEntry(allocator, .{
        .kind = .type_alias,
        .source_start = 14, // "{ port: number }"
        .source_end = 30,
        .context_line = 1,
        .context_col = 1,
        .name_start = 5, // "Config"
        .name_end = 11,
    });

    env.populateFromTypeMap(&tm);

    const config_idx = env.getTypeAlias("Config");
    try std.testing.expect(config_idx != null);
    try std.testing.expectEqual(type_pool_mod.TypeTag.t_record, pool.getTag(config_idx.?).?);
}

test "TypeEnv variable annotation" {
    const allocator = std.testing.allocator;
    var pool = TypePool.init(allocator);
    defer pool.deinit(allocator);

    var env = TypeEnv.init(allocator, &pool);
    defer env.deinit();

    const source = "const port: number = 8080;";
    var tm = TypeMap.init(source);
    defer tm.deinit(allocator);

    try tm.addEntry(allocator, .{
        .kind = .var_annotation,
        .source_start = 12, // "number"
        .source_end = 18,
        .context_line = 1,
        .context_col = 1,
        .name_start = 6, // "port"
        .name_end = 10,
    });

    env.populateFromTypeMap(&tm);

    const port_type = env.getVarTypeByName("port");
    try std.testing.expect(port_type != null);
    try std.testing.expectEqual(pool.idx_number, port_type.?);
}

test "TypeEnv resolves type aliases in annotations" {
    const allocator = std.testing.allocator;
    var pool = TypePool.init(allocator);
    defer pool.deinit(allocator);

    var env = TypeEnv.init(allocator, &pool);
    defer env.deinit();

    // First: define a type alias
    const source = "type Status = number;const code: Status = 200;";
    var tm = TypeMap.init(source);
    defer tm.deinit(allocator);

    try tm.addEntry(allocator, .{
        .kind = .type_alias,
        .source_start = 14, // "number"
        .source_end = 20,
        .context_line = 1,
        .context_col = 1,
        .name_start = 5, // "Status"
        .name_end = 11,
    });

    try tm.addEntry(allocator, .{
        .kind = .var_annotation,
        .source_start = 33, // "Status"
        .source_end = 39,
        .context_line = 1,
        .context_col = 22,
        .name_start = 27, // "code"
        .name_end = 31,
    });

    env.populateFromTypeMap(&tm);

    // "Status" should resolve to number
    const status_idx = env.getTypeAlias("Status");
    try std.testing.expect(status_idx != null);
    try std.testing.expectEqual(pool.idx_number, status_idx.?);

    // "code" should also be number (via Status alias)
    const code_type = env.getVarTypeByName("code");
    try std.testing.expect(code_type != null);
    try std.testing.expectEqual(pool.idx_number, code_type.?);
}

test "TypeEnv function signature from params and return" {
    const allocator = std.testing.allocator;
    var pool = TypePool.init(allocator);
    defer pool.deinit(allocator);

    var env = TypeEnv.init(allocator, &pool);
    defer env.deinit();

    const source = "function add(a: number, b: number): number { }";
    var tm = TypeMap.init(source);
    defer tm.deinit(allocator);

    // param a: number
    try tm.addEntry(allocator, .{
        .kind = .param_annotation,
        .source_start = 16, // "number"
        .source_end = 22,
        .context_line = 1,
        .context_col = 1,
        .name_start = 13, // "a"
        .name_end = 14,
    });
    // param b: number
    try tm.addEntry(allocator, .{
        .kind = .param_annotation,
        .source_start = 27, // "number"
        .source_end = 33,
        .context_line = 1,
        .context_col = 1,
        .name_start = 24, // "b"
        .name_end = 25,
    });
    // return: number
    try tm.addEntry(allocator, .{
        .kind = .return_annotation,
        .source_start = 36, // "number"
        .source_end = 42,
        .context_line = 1,
        .context_col = 1,
        .name_start = 0,
        .name_end = 0,
    });

    env.populateFromTypeMap(&tm);

    const sig = env.getFnSigByLoc(1);
    try std.testing.expect(sig != null);
    try std.testing.expectEqual(@as(u8, 2), sig.?.param_count);
    try std.testing.expectEqual(pool.idx_number, sig.?.param_types[0]);
    try std.testing.expectEqual(pool.idx_number, sig.?.param_types[1]);
    try std.testing.expectEqual(pool.idx_number, sig.?.return_type);
}

test "TypeEnv generic scope" {
    const allocator = std.testing.allocator;
    var pool = TypePool.init(allocator);
    defer pool.deinit(allocator);

    var env = TypeEnv.init(allocator, &pool);
    defer env.deinit();

    env.pushGenericScope();
    const t_idx = env.addGenericParam("T");
    try std.testing.expect(t_idx != null_type_idx);

    // "T" should resolve to the generic param
    const resolved = env.resolveType("T");
    try std.testing.expectEqual(t_idx, resolved);

    env.popGenericScope();

    // After popping, "T" should NOT resolve to the generic param
    const resolved2 = env.resolveType("T");
    // It will be a ref type now, not the generic param
    try std.testing.expect(resolved2 != t_idx);
}

test "TypeEnv generic type alias Result<string>" {
    const allocator = std.testing.allocator;
    var pool = TypePool.init(allocator);
    defer pool.deinit(allocator);

    var env = TypeEnv.init(allocator, &pool);
    defer env.deinit();

    // Simulate: type Result<T> = { ok: boolean; value: T; error: string }
    //           const auth: Result<object> = jwtVerify(token, secret);
    const source = "type Result<T> = { ok: boolean; value: T; error: string };const auth: Result<object> = jwtVerify();";
    var tm = TypeMap.init(source);
    defer tm.deinit(allocator);

    // type_alias entry: body is "{ ok: boolean; value: T; error: string }"
    try tm.addEntry(allocator, .{
        .kind = .type_alias,
        .source_start = 17, // "{ ok: boolean; value: T; error: string }"
        .source_end = 57,
        .context_line = 1,
        .context_col = 1,
        .name_start = 5, // "Result"
        .name_end = 11,
    });

    // generic_params entry: "T" (same name range as the alias)
    try tm.addEntry(allocator, .{
        .kind = .generic_params,
        .source_start = 12, // "T"
        .source_end = 13,
        .context_line = 1,
        .context_col = 1,
        .name_start = 5, // "Result"
        .name_end = 11,
    });

    // var annotation: auth: Result<object>
    try tm.addEntry(allocator, .{
        .kind = .var_annotation,
        .source_start = 70, // "Result<object>"
        .source_end = 84,
        .context_line = 1,
        .context_col = 58,
        .name_start = 64, // "auth"
        .name_end = 68,
    });

    env.populateFromTypeMap(&tm);

    // "Result" should be in generic_aliases, not type_aliases
    try std.testing.expect(env.getTypeAlias("Result") == null);
    try std.testing.expect(env.generic_aliases.get("Result") != null);

    // auth should resolve to an instantiated record with value: object (ref)
    const auth_type = env.getVarTypeByName("auth");
    try std.testing.expect(auth_type != null);
    try std.testing.expectEqual(type_pool_mod.TypeTag.t_record, pool.getTag(auth_type.?).?);

    const fields = pool.getRecordFields(auth_type.?);
    try std.testing.expectEqual(@as(usize, 3), fields.len);

    // ok: boolean
    try std.testing.expectEqual(pool.idx_boolean, fields[0].type_idx);
    // value: should be a ref("object"), not a generic param
    try std.testing.expect(pool.getTag(fields[1].type_idx) != .t_generic_param);
    // error: string
    try std.testing.expectEqual(pool.idx_string, fields[2].type_idx);
}

test "TypeEnv generic alias with multiple params" {
    const allocator = std.testing.allocator;
    var pool = TypePool.init(allocator);
    defer pool.deinit(allocator);

    var env = TypeEnv.init(allocator, &pool);
    defer env.deinit();

    // Simulate: type Pair<A, B> = { first: A; second: B }
    //           const p: Pair<string, number> = ...
    const source = "type Pair<A, B> = { first: A; second: B };const p: Pair<string, number> = x;";
    var tm = TypeMap.init(source);
    defer tm.deinit(allocator);

    try tm.addEntry(allocator, .{
        .kind = .type_alias,
        .source_start = 18, // "{ first: A; second: B }"
        .source_end = 41,
        .context_line = 1,
        .context_col = 1,
        .name_start = 5, // "Pair"
        .name_end = 9,
    });

    try tm.addEntry(allocator, .{
        .kind = .generic_params,
        .source_start = 10, // "A, B"
        .source_end = 14,
        .context_line = 1,
        .context_col = 1,
        .name_start = 5,
        .name_end = 9,
    });

    try tm.addEntry(allocator, .{
        .kind = .var_annotation,
        .source_start = 51, // "Pair<string, number>"
        .source_end = 71,
        .context_line = 1,
        .context_col = 42,
        .name_start = 48, // "p"
        .name_end = 49,
    });

    env.populateFromTypeMap(&tm);

    const p_type = env.getVarTypeByName("p");
    try std.testing.expect(p_type != null);
    try std.testing.expectEqual(type_pool_mod.TypeTag.t_record, pool.getTag(p_type.?).?);

    const fields = pool.getRecordFields(p_type.?);
    try std.testing.expectEqual(@as(usize, 2), fields.len);
    // first: string
    try std.testing.expectEqual(pool.idx_string, fields[0].type_idx);
    // second: number
    try std.testing.expectEqual(pool.idx_number, fields[1].type_idx);
}

test "TypeEnv resolveType instantiates generic alias inline" {
    const allocator = std.testing.allocator;
    var pool = TypePool.init(allocator);
    defer pool.deinit(allocator);

    var env = TypeEnv.init(allocator, &pool);
    defer env.deinit();

    try installTestBoxGenericAlias(&env);

    // resolveType("Box<number>") should instantiate to { value: number }
    const resolved = env.resolveType("Box<number>");
    try std.testing.expectEqual(type_pool_mod.TypeTag.t_record, pool.getTag(resolved).?);
    const fields = pool.getRecordFields(resolved);
    try std.testing.expectEqual(@as(usize, 1), fields.len);
    try std.testing.expectEqual(pool.idx_number, fields[0].type_idx);
}

test "TypeEnv instantiates every member of a normalized union wider than scratch buffers" {
    const allocator = std.testing.allocator;
    var pool = TypePool.init(allocator);
    defer pool.deinit(allocator);

    var env = TypeEnv.init(allocator, &pool);
    defer env.deinit();

    try installTestBoxGenericAlias(&env);

    // The first Box forces the union to be rebuilt. The second Box and m33 are
    // beyond the former 32-member buffer, so this also covers late generic
    // instantiation and preservation of every trailing member.
    const resolved = env.resolveType(
        \\(Box<string> |
        \\ "m01" | "m02" | "m03" | "m04" | "m05" | "m06" | "m07" | "m08" |
        \\ "m09" | "m10" | "m11" | "m12" | "m13" | "m14" | "m15" | "m16" |
        \\ "m17" | "m18" | "m19" | "m20" | "m21" | "m22" | "m23" | "m24" |
        \\ "m25" | "m26" | "m27" | "m28" | "m29" | "m30" | "m31" | "m32") |
        \\ "m33" | Box<number>
    );

    try pool.ensureHealthy();
    try std.testing.expectEqual(type_pool_mod.TypeTag.t_union, pool.getTag(resolved).?);
    const members = pool.getUnionMembers(resolved);
    try std.testing.expectEqual(@as(usize, 35), members.len);

    var literal_count: usize = 0;
    var saw_last_literal = false;
    var saw_string_box = false;
    var saw_number_box = false;
    for (members) |member| {
        switch (pool.getTag(member).?) {
            .t_literal_string => {
                literal_count += 1;
                if (std.mem.eql(u8, pool.getLiteralStringValue(member).?, "m33")) {
                    saw_last_literal = true;
                }
            },
            .t_record => {
                const fields = pool.getRecordFields(member);
                try std.testing.expectEqual(@as(usize, 1), fields.len);
                if (fields[0].type_idx == pool.idx_string) saw_string_box = true;
                if (fields[0].type_idx == pool.idx_number) saw_number_box = true;
            },
            else => return error.UnexpectedUnionMember,
        }
    }
    try std.testing.expectEqual(@as(usize, 33), literal_count);
    try std.testing.expect(saw_last_literal);
    try std.testing.expect(saw_string_box);
    try std.testing.expect(saw_number_box);
}

test "TypeEnv preserves and instantiates all 17 intersection members" {
    const allocator = std.testing.allocator;
    var pool = TypePool.init(allocator);
    defer pool.deinit(allocator);

    var env = TypeEnv.init(allocator, &pool);
    defer env.deinit();

    try installTestBoxGenericAlias(&env);

    // Both generic applications must instantiate, and every literal obligation
    // between them must remain in the intersection.
    const resolved = env.resolveType(
        \\Box<string> &
        \\ "m01" & "m02" & "m03" & "m04" & "m05" &
        \\ "m06" & "m07" & "m08" & "m09" & "m10" &
        \\ "m11" & "m12" & "m13" & "m14" & "m15" &
        \\ Box<number>
    );

    try pool.ensureHealthy();
    try std.testing.expectEqual(type_pool_mod.TypeTag.t_intersection, pool.getTag(resolved).?);
    const members = pool.getIntersectionMembers(resolved);
    try std.testing.expectEqual(@as(usize, 17), members.len);

    var literal_count: usize = 0;
    var saw_last_literal = false;
    var saw_string_box = false;
    var saw_number_box = false;
    for (members) |member| {
        switch (pool.getTag(member).?) {
            .t_literal_string => {
                literal_count += 1;
                if (std.mem.eql(u8, pool.getLiteralStringValue(member).?, "m15")) {
                    saw_last_literal = true;
                }
            },
            .t_record => {
                const fields = pool.getRecordFields(member);
                try std.testing.expectEqual(@as(usize, 1), fields.len);
                if (fields[0].type_idx == pool.idx_string) saw_string_box = true;
                if (fields[0].type_idx == pool.idx_number) saw_number_box = true;
            },
            else => return error.UnexpectedIntersectionMember,
        }
    }
    try std.testing.expectEqual(@as(usize, 15), literal_count);
    try std.testing.expect(saw_last_literal);
    try std.testing.expect(saw_string_box);
    try std.testing.expect(saw_number_box);
}

test "TypeEnv reports intersection snapshot allocation failure" {
    const allocator = std.testing.allocator;
    var pool = TypePool.init(allocator);
    defer pool.deinit(allocator);

    var env = TypeEnv.init(allocator, &pool);
    defer env.deinit();

    const intersection = type_pool_mod.parseTypeExpr(&pool, allocator, "string & number");
    try std.testing.expectEqual(type_pool_mod.TypeTag.t_intersection, pool.getTag(intersection).?);

    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    env.allocator = failing.allocator();
    const resolved = env.tryInstantiateGenericApp(intersection);
    env.allocator = allocator;

    try std.testing.expectEqual(null_type_idx, resolved);
    try std.testing.expectError(error.OutOfMemory, pool.ensureHealthy());
}

test "TypeEnv intersection alias type AB = A & B" {
    const allocator = std.testing.allocator;
    var pool = TypePool.init(allocator);
    defer pool.deinit(allocator);

    var env = TypeEnv.init(allocator, &pool);
    defer env.deinit();

    // Simulate: type AB = A & B;
    // Names A and B stay as t_ref inside the intersection (resolveType only
    // substitutes alias names when the entire annotation text matches; nested
    // identifiers in compound expressions remain refs - same behaviour as union).
    const source = "type AB = A & B;";
    var tm = TypeMap.init(source);
    defer tm.deinit(allocator);

    try tm.addEntry(allocator, .{
        .kind = .type_alias,
        .source_start = 10, // "A & B"
        .source_end = 15,
        .context_line = 1,
        .context_col = 1,
        .name_start = 5, // "AB"
        .name_end = 7,
    });

    env.populateFromTypeMap(&tm);

    const ab_idx = env.getTypeAlias("AB");
    try std.testing.expect(ab_idx != null);
    try std.testing.expectEqual(type_pool_mod.TypeTag.t_intersection, pool.getTag(ab_idx.?).?);
    const members = pool.getIntersectionMembers(ab_idx.?);
    try std.testing.expectEqual(@as(usize, 2), members.len);
    try std.testing.expectEqual(type_pool_mod.TypeTag.t_ref, pool.getTag(members[0]).?);
    try std.testing.expectEqualStrings("A", pool.getRefName(members[0]));
    try std.testing.expectEqual(type_pool_mod.TypeTag.t_ref, pool.getTag(members[1]).?);
    try std.testing.expectEqualStrings("B", pool.getRefName(members[1]));
}

test "TypeEnv return-type intersection X & Y" {
    const allocator = std.testing.allocator;
    var pool = TypePool.init(allocator);
    defer pool.deinit(allocator);

    var env = TypeEnv.init(allocator, &pool);
    defer env.deinit();

    const owned_x = env.internName("X");
    env.type_aliases.put(allocator, owned_x, pool.idx_string) catch {};
    const owned_y = env.internName("Y");
    env.type_aliases.put(allocator, owned_y, pool.idx_number) catch {};

    // function f(): X & Y { ... }
    const source = "function f(): X & Y { return null; }";
    var tm = TypeMap.init(source);
    defer tm.deinit(allocator);

    try tm.addEntry(allocator, .{
        .kind = .return_annotation,
        .source_start = 14, // "X & Y"
        .source_end = 19,
        .context_line = 7,
        .context_col = 1,
        .name_start = 0,
        .name_end = 0,
    });

    env.populateFromTypeMap(&tm);

    const sig = env.getFnSigByLoc(7);
    try std.testing.expect(sig != null);
    try std.testing.expectEqual(type_pool_mod.TypeTag.t_intersection, pool.getTag(sig.?.return_type).?);
}

test "resolveType Pick<User, keys> keeps only the named fields" {
    const allocator = std.testing.allocator;
    var pool = TypePool.init(allocator);
    defer pool.deinit(allocator);
    var env = TypeEnv.init(allocator, &pool);
    defer env.deinit();

    const user = parseTypeExpr(&pool, allocator, "{ id: number; name: string; age: number }");
    env.type_aliases.put(allocator, env.internName("User"), user) catch unreachable;

    const picked = env.resolveType("Pick<User, \"id\" | \"name\">");
    try std.testing.expectEqual(type_pool_mod.TypeTag.t_record, pool.getTag(picked).?);
    try std.testing.expectEqual(@as(usize, 2), pool.getRecordFields(picked).len);
    try std.testing.expect(pool.lookupRecordField(picked, "id") != null);
    try std.testing.expect(pool.lookupRecordField(picked, "name") != null);
    try std.testing.expect(pool.lookupRecordField(picked, "age") == null);
}

test "resolveType Pick<User, Keys> resolves an aliased key union (not the full source)" {
    const allocator = std.testing.allocator;
    var pool = TypePool.init(allocator);
    defer pool.deinit(allocator);
    var env = TypeEnv.init(allocator, &pool);
    defer env.deinit();

    const user = parseTypeExpr(&pool, allocator, "{ id: number; name: string; age: number }");
    env.type_aliases.put(allocator, env.internName("User"), user) catch unreachable;
    // Keys is a named alias of a string-literal union. Previously the keys
    // argument was not alias-resolved, so collectStringKeys saw a t_ref, found
    // zero keys, and Pick silently returned the full User - an unsound
    // over-accept. It must now resolve to exactly {id, name}.
    const keys = parseTypeExpr(&pool, allocator, "\"id\" | \"name\"");
    env.type_aliases.put(allocator, env.internName("Keys"), keys) catch unreachable;

    const picked = env.resolveType("Pick<User, Keys>");
    try std.testing.expectEqual(type_pool_mod.TypeTag.t_record, pool.getTag(picked).?);
    try std.testing.expectEqual(@as(usize, 2), pool.getRecordFields(picked).len);
    try std.testing.expect(pool.lookupRecordField(picked, "id") != null);
    try std.testing.expect(pool.lookupRecordField(picked, "name") != null);
    try std.testing.expect(pool.lookupRecordField(picked, "age") == null);
}

test "resolveType Required<A> follows a forward alias chain to the record" {
    const allocator = std.testing.allocator;
    var pool = TypePool.init(allocator);
    defer pool.deinit(allocator);
    var env = TypeEnv.init(allocator, &pool);
    defer env.deinit();

    // `type A = B` (forward) stores A as a t_ref(B); B is the record. Previously
    // resolveRefToRecord returned the t_ref unchanged, so Required<A> no-op'd and
    // accepted any record. It must now chase the chain and clear `host?`.
    const b = parseTypeExpr(&pool, allocator, "{ host?: string }");
    env.type_aliases.put(allocator, env.internName("B"), b) catch unreachable;
    const a = parseTypeExpr(&pool, allocator, "B");
    env.type_aliases.put(allocator, env.internName("A"), a) catch unreachable;

    const required = env.resolveType("Required<A>");
    try std.testing.expectEqual(type_pool_mod.TypeTag.t_record, pool.getTag(required).?);
    const fields = pool.getRecordFields(required);
    try std.testing.expectEqual(@as(usize, 1), fields.len);
    try std.testing.expect(!fields[0].optional);
}

test "resolveType Omit<User, key> drops the named field" {
    const allocator = std.testing.allocator;
    var pool = TypePool.init(allocator);
    defer pool.deinit(allocator);
    var env = TypeEnv.init(allocator, &pool);
    defer env.deinit();

    const user = parseTypeExpr(&pool, allocator, "{ id: number; name: string; age: number }");
    env.type_aliases.put(allocator, env.internName("User"), user) catch unreachable;

    const omitted = env.resolveType("Omit<User, \"age\">");
    try std.testing.expectEqual(type_pool_mod.TypeTag.t_record, pool.getTag(omitted).?);
    try std.testing.expectEqual(@as(usize, 2), pool.getRecordFields(omitted).len);
    try std.testing.expect(pool.lookupRecordField(omitted, "id") != null);
    try std.testing.expect(pool.lookupRecordField(omitted, "age") == null);
}

test "resolveType Partial<User> makes fields optional and assignable from a subset" {
    const allocator = std.testing.allocator;
    var pool = TypePool.init(allocator);
    defer pool.deinit(allocator);
    var env = TypeEnv.init(allocator, &pool);
    defer env.deinit();

    const user = parseTypeExpr(&pool, allocator, "{ id: number; name: string }");
    env.type_aliases.put(allocator, env.internName("User"), user) catch unreachable;

    const partial = env.resolveType("Partial<User>");
    const fields = pool.getRecordFields(partial);
    try std.testing.expectEqual(@as(usize, 2), fields.len);
    try std.testing.expect(fields[0].optional);
    try std.testing.expect(fields[1].optional);

    // An object missing a field is assignable to Partial<User> but not to the
    // original required type - the transform flows into the assignability check.
    const subset = parseTypeExpr(&pool, allocator, "{ id: number }");
    try std.testing.expect(pool.isAssignableTo(subset, partial));
    try std.testing.expect(!pool.isAssignableTo(subset, user));
}

test "resolveType Required<Conf> clears optional and rejects a missing field" {
    const allocator = std.testing.allocator;
    var pool = TypePool.init(allocator);
    defer pool.deinit(allocator);
    var env = TypeEnv.init(allocator, &pool);
    defer env.deinit();

    const conf = parseTypeExpr(&pool, allocator, "{ host?: string; port?: number }");
    env.type_aliases.put(allocator, env.internName("Conf"), conf) catch unreachable;

    const req = env.resolveType("Required<Conf>");
    const fields = pool.getRecordFields(req);
    try std.testing.expectEqual(@as(usize, 2), fields.len);
    try std.testing.expect(!fields[0].optional);
    try std.testing.expect(!fields[1].optional);

    const subset = parseTypeExpr(&pool, allocator, "{ host: string }");
    try std.testing.expect(!pool.isAssignableTo(subset, req));
}

test "TypeEnv object assignability accepts non-primitives and resolves known aliases" {
    const allocator = std.testing.allocator;
    var pool = TypePool.init(allocator);
    defer pool.deinit(allocator);
    var env = TypeEnv.init(allocator, &pool);
    defer env.deinit();

    const object_ref = pool.addRef(allocator, "object");
    const optional_object = pool.addNullable(allocator, object_ref);
    const record = parseTypeExpr(&pool, allocator, "{ id: number }");
    const array = pool.addArray(allocator, pool.idx_number);
    const function = pool.addFunctionWithReturn(allocator, &.{}, pool.idx_undefined);
    const request_ref = pool.addRef(allocator, "Request");
    const nullable_request = pool.addNullable(allocator, request_ref);

    try std.testing.expect(env.isAssignableTo(record, object_ref));
    try std.testing.expect(env.isAssignableTo(array, object_ref));
    try std.testing.expect(env.isAssignableTo(function, object_ref));
    try std.testing.expect(env.isAssignableTo(request_ref, object_ref));

    try std.testing.expect(!env.isAssignableTo(pool.idx_string, object_ref));
    try std.testing.expect(!env.isAssignableTo(pool.idx_number, object_ref));
    try std.testing.expect(!env.isAssignableTo(pool.idx_boolean, object_ref));
    try std.testing.expect(!env.isAssignableTo(pool.idx_undefined, object_ref));
    try std.testing.expect(!env.isAssignableTo(pool.idx_null, object_ref));
    try std.testing.expect(!env.isAssignableTo(pool.addLiteralString(allocator, "x"), object_ref));
    try std.testing.expect(!env.isAssignableTo(nullable_request, object_ref));

    try std.testing.expect(env.isAssignableTo(request_ref, optional_object));
    try std.testing.expect(env.isAssignableTo(nullable_request, optional_object));
    try std.testing.expect(env.isAssignableTo(pool.idx_undefined, optional_object));

    env.type_aliases.put(allocator, env.internName("StringAlias"), pool.idx_string) catch unreachable;
    const string_alias = pool.addRef(allocator, "StringAlias");
    try std.testing.expect(!env.isAssignableTo(string_alias, object_ref));
}

test "TypeEnv registers Spec<S> built-in alias on init" {
    const allocator = std.testing.allocator;
    var pool = TypePool.init(allocator);
    defer pool.deinit(allocator);

    var env = TypeEnv.init(allocator, &pool);
    defer env.deinit();

    // Spec must live in generic_aliases (parametric), not type_aliases.
    try std.testing.expect(env.getTypeAlias("Spec") == null);
    try std.testing.expect(env.generic_aliases.get("Spec") != null);

    // Body must be a record with the magic field name carrying S.
    const alias = env.generic_aliases.get("Spec").?;
    try std.testing.expectEqual(@as(u8, 1), alias.param_count);
    try std.testing.expectEqualStrings("S", alias.param_names[0]);

    const body_tag = pool.getTag(alias.body) orelse return error.MissingBody;
    try std.testing.expectEqual(type_pool_mod.TypeTag.t_record, body_tag);

    const fields = pool.getRecordFields(alias.body);
    try std.testing.expectEqual(@as(usize, 1), fields.len);
    try std.testing.expectEqualStrings(spec_marker_field, pool.getName(fields[0].name_start, fields[0].name_len));
}

test "TypeEnv resolveType Spec<\"a\" | \"b\"> instantiates marker" {
    const allocator = std.testing.allocator;
    var pool = TypePool.init(allocator);
    defer pool.deinit(allocator);

    var env = TypeEnv.init(allocator, &pool);
    defer env.deinit();

    const idx = env.resolveType("Spec<\"a\" | \"b\">");
    try std.testing.expectEqual(type_pool_mod.TypeTag.t_record, pool.getTag(idx).?);

    const fields = pool.getRecordFields(idx);
    try std.testing.expectEqual(@as(usize, 1), fields.len);
    try std.testing.expectEqualStrings(spec_marker_field, pool.getName(fields[0].name_start, fields[0].name_len));

    // Field type is the literal-string union "a" | "b".
    const union_tag = pool.getTag(fields[0].type_idx) orelse return error.MissingBody;
    try std.testing.expectEqual(type_pool_mod.TypeTag.t_union, union_tag);
    try std.testing.expectEqual(@as(usize, 2), pool.getUnionMembers(fields[0].type_idx).len);
}

test "extractSpecMembers walks intersection through alias to literal union" {
    const allocator = std.testing.allocator;
    var pool = TypePool.init(allocator);
    defer pool.deinit(allocator);

    var env = TypeEnv.init(allocator, &pool);
    defer env.deinit();

    // Simulate:
    //     type Guardrails = Spec<"idempotent" | "deterministic">;
    //     function handler(): Response & Guardrails { ... }
    const source =
        "type Guardrails = Spec<\"idempotent\" | \"deterministic\">;" ++
        "function handler(): Response & Guardrails { return null; }";
    var tm = TypeMap.init(source);
    defer tm.deinit(allocator);

    // Guardrails alias body: Spec<"idempotent" | "deterministic">
    try tm.addEntry(allocator, .{
        .kind = .type_alias,
        .source_start = 18,
        .source_end = 54,
        .context_line = 1,
        .context_col = 1,
        .name_start = 5,
        .name_end = 15,
    });
    // Return annotation: Response & Guardrails
    try tm.addEntry(allocator, .{
        .kind = .return_annotation,
        .source_start = 75,
        .source_end = 96,
        .context_line = 7,
        .context_col = 1,
        .name_start = 0,
        .name_end = 0,
    });

    env.populateFromTypeMap(&tm);

    const sig = env.getFnSigByLoc(7) orelse return error.MissingSig;

    var names: std.ArrayListUnmanaged([]const u8) = .empty;
    defer names.deinit(allocator);
    _ = try env.extractSpecMembers(sig.return_type, &names);

    try std.testing.expectEqual(@as(usize, 2), names.items.len);
    try std.testing.expectEqualStrings("idempotent", names.items[0]);
    try std.testing.expectEqualStrings("deterministic", names.items[1]);
}

test "extractSpecMembers handles inline Response & Spec<\"name\">" {
    const allocator = std.testing.allocator;
    var pool = TypePool.init(allocator);
    defer pool.deinit(allocator);

    var env = TypeEnv.init(allocator, &pool);
    defer env.deinit();

    // function handler(): Response & Spec<"idempotent"> { ... }
    const source = "function handler(): Response & Spec<\"idempotent\"> { return null; }";
    var tm = TypeMap.init(source);
    defer tm.deinit(allocator);

    try tm.addEntry(allocator, .{
        .kind = .return_annotation,
        .source_start = 20,
        .source_end = 49,
        .context_line = 3,
        .context_col = 1,
        .name_start = 0,
        .name_end = 0,
    });

    env.populateFromTypeMap(&tm);

    const sig = env.getFnSigByLoc(3) orelse return error.MissingSig;

    var names: std.ArrayListUnmanaged([]const u8) = .empty;
    defer names.deinit(allocator);
    _ = try env.extractSpecMembers(sig.return_type, &names);

    try std.testing.expectEqual(@as(usize, 1), names.items.len);
    try std.testing.expectEqualStrings("idempotent", names.items[0]);
}

test "extractSpecMembers returns empty when no Spec marker" {
    const allocator = std.testing.allocator;
    var pool = TypePool.init(allocator);
    defer pool.deinit(allocator);

    var env = TypeEnv.init(allocator, &pool);
    defer env.deinit();

    const source = "function handler(): Response { return null; }";
    var tm = TypeMap.init(source);
    defer tm.deinit(allocator);

    try tm.addEntry(allocator, .{
        .kind = .return_annotation,
        .source_start = 20,
        .source_end = 28,
        .context_line = 5,
        .context_col = 1,
        .name_start = 0,
        .name_end = 0,
    });

    env.populateFromTypeMap(&tm);

    const sig = env.getFnSigByLoc(5) orelse return error.MissingSig;

    var names: std.ArrayListUnmanaged([]const u8) = .empty;
    defer names.deinit(allocator);
    _ = try env.extractSpecMembers(sig.return_type, &names);

    try std.testing.expectEqual(@as(usize, 0), names.items.len);
}

test "TypeEnv registers Proof<T, S> built-in alias on init" {
    const allocator = std.testing.allocator;
    var pool = TypePool.init(allocator);
    defer pool.deinit(allocator);

    var env = TypeEnv.init(allocator, &pool);
    defer env.deinit();

    try std.testing.expect(env.getTypeAlias("Proof") == null);
    const alias = env.generic_aliases.get("Proof") orelse return error.MissingAlias;
    try std.testing.expectEqual(@as(u8, 2), alias.param_count);
    try std.testing.expectEqualStrings("T", alias.param_names[0]);
    try std.testing.expectEqualStrings("S", alias.param_names[1]);

    // Body is an intersection: the underlying T plus the spec marker record.
    try std.testing.expectEqual(type_pool_mod.TypeTag.t_intersection, pool.getTag(alias.body).?);
}

test "resolveType Proof<T, S> carries capsule property members" {
    const allocator = std.testing.allocator;
    var pool = TypePool.init(allocator);
    defer pool.deinit(allocator);

    var env = TypeEnv.init(allocator, &pool);
    defer env.deinit();

    // A capsule with two declared properties on an underlying string return.
    const idx = env.resolveType("Proof<string, \"total\" | \"pure\">");

    var names: std.ArrayListUnmanaged([]const u8) = .empty;
    defer names.deinit(allocator);
    _ = try env.extractSpecMembers(idx, &names);

    try std.testing.expectEqual(@as(usize, 2), names.items.len);
    try std.testing.expectEqualStrings("total", names.items[0]);
    try std.testing.expectEqualStrings("pure", names.items[1]);
}

test "extractSpecMembers handles inline return type Proof<T, \"name\">" {
    const allocator = std.testing.allocator;
    var pool = TypePool.init(allocator);
    defer pool.deinit(allocator);

    var env = TypeEnv.init(allocator, &pool);
    defer env.deinit();

    // function load(): Proof<string, "read_only"> { ... }
    const source = "function load(): Proof<string, \"read_only\"> { return \"\"; }";
    var tm = TypeMap.init(source);
    defer tm.deinit(allocator);

    try tm.addEntry(allocator, .{
        .kind = .return_annotation,
        .source_start = 17,
        .source_end = 43,
        .context_line = 4,
        .context_col = 1,
        .name_start = 0,
        .name_end = 0,
    });

    env.populateFromTypeMap(&tm);

    const sig = env.getFnSigByLoc(4) orelse return error.MissingSig;

    var names: std.ArrayListUnmanaged([]const u8) = .empty;
    defer names.deinit(allocator);
    _ = try env.extractSpecMembers(sig.return_type, &names);

    try std.testing.expectEqual(@as(usize, 1), names.items.len);
    try std.testing.expectEqualStrings("read_only", names.items[0]);
}

test "TypeEnv registers Effects<T, S> built-in alias on init" {
    const allocator = std.testing.allocator;
    var pool = TypePool.init(allocator);
    defer pool.deinit(allocator);

    var env = TypeEnv.init(allocator, &pool);
    defer env.deinit();

    const alias = env.generic_aliases.get("Effects") orelse return error.MissingAlias;
    try std.testing.expectEqual(@as(u8, 2), alias.param_count);
    try std.testing.expectEqualStrings("T", alias.param_names[0]);
    try std.testing.expectEqualStrings("S", alias.param_names[1]);
    try std.testing.expectEqual(type_pool_mod.TypeTag.t_intersection, pool.getTag(alias.body).?);
}

test "resolveType Effects<T, S> carries capability members under its own marker" {
    const allocator = std.testing.allocator;
    var pool = TypePool.init(allocator);
    defer pool.deinit(allocator);

    var env = TypeEnv.init(allocator, &pool);
    defer env.deinit();

    const idx = env.resolveType("Effects<string, \"env\" | \"crypto\">");

    var caps: std.ArrayListUnmanaged([]const u8) = .empty;
    defer caps.deinit(allocator);
    _ = try env.extractEffectMembers(idx, &caps);
    try std.testing.expectEqual(@as(usize, 2), caps.items.len);
    try std.testing.expectEqualStrings("env", caps.items[0]);
    try std.testing.expectEqualStrings("crypto", caps.items[1]);

    // The effect marker is distinct from the spec marker: an Effects<...>
    // type carries no Spec/Proof members.
    var specs: std.ArrayListUnmanaged([]const u8) = .empty;
    defer specs.deinit(allocator);
    _ = try env.extractSpecMembers(idx, &specs);
    try std.testing.expectEqual(@as(usize, 0), specs.items.len);
}

test "a non-literal Effects payload reports non_literal instead of zero names" {
    const allocator = std.testing.allocator;
    var pool = TypePool.init(allocator);
    defer pool.deinit(allocator);

    var env = TypeEnv.init(allocator, &pool);
    defer env.deinit();

    // A ceiling naming a type rather than string literals. Extracting nothing
    // and reporting it as "no annotation" is the fail-open D2 5 names: the
    // function keeps its capabilities and no ceiling bounds them.
    const idx = env.resolveType("Effects<string, string>");

    var caps: std.ArrayListUnmanaged([]const u8) = .empty;
    defer caps.deinit(allocator);
    const extraction = try env.extractEffectMembers(idx, &caps);
    try std.testing.expectEqual(@as(usize, 0), caps.items.len);
    try std.testing.expect(extraction.non_literal);
}

test "a literal Effects payload reports non_literal false" {
    const allocator = std.testing.allocator;
    var pool = TypePool.init(allocator);
    defer pool.deinit(allocator);

    var env = TypeEnv.init(allocator, &pool);
    defer env.deinit();

    const idx = env.resolveType("Effects<string, \"env\" | \"crypto\">");

    var caps: std.ArrayListUnmanaged([]const u8) = .empty;
    defer caps.deinit(allocator);
    const extraction = try env.extractEffectMembers(idx, &caps);
    try std.testing.expectEqual(@as(usize, 2), caps.items.len);
    try std.testing.expect(!extraction.non_literal);
}

test "a marker on one union branch reports non_literal, not an empty set" {
    const allocator = std.testing.allocator;
    var pool = TypePool.init(allocator);
    defer pool.deinit(allocator);

    var env = TypeEnv.init(allocator, &pool);
    defer env.deinit();

    // The ceiling is present but applies to one branch only, so there is no
    // single ceiling for the type. Returning the empty set here would read as
    // "the author declared nothing" - the same fail-open as a non-literal
    // payload, reached through the marker search instead of the payload read.
    const idx = env.resolveType("Effects<string, \"env\"> | string");

    var caps: std.ArrayListUnmanaged([]const u8) = .empty;
    defer caps.deinit(allocator);
    const extraction = try env.extractEffectMembers(idx, &caps);
    try std.testing.expectEqual(@as(usize, 0), caps.items.len);
    try std.testing.expect(extraction.non_literal);
}

test "a union carrying no marker at all stays silent" {
    const allocator = std.testing.allocator;
    var pool = TypePool.init(allocator);
    defer pool.deinit(allocator);

    var env = TypeEnv.init(allocator, &pool);
    defer env.deinit();

    const idx = env.resolveType("string | number");

    var caps: std.ArrayListUnmanaged([]const u8) = .empty;
    defer caps.deinit(allocator);
    const extraction = try env.extractEffectMembers(idx, &caps);
    try std.testing.expectEqual(@as(usize, 0), caps.items.len);
    try std.testing.expect(!extraction.non_literal);
}

test "a nullable-wrapped marker still resolves to its ceiling" {
    const allocator = std.testing.allocator;
    var pool = TypePool.init(allocator);
    defer pool.deinit(allocator);

    var env = TypeEnv.init(allocator, &pool);
    defer env.deinit();

    // `| undefined` is the one union shape that does carry the obligation
    // whole, and it must keep resolving after the t_union arm above.
    const idx = env.resolveType("Effects<string, \"env\"> | undefined");

    var caps: std.ArrayListUnmanaged([]const u8) = .empty;
    defer caps.deinit(allocator);
    const extraction = try env.extractEffectMembers(idx, &caps);
    try std.testing.expectEqual(@as(usize, 1), caps.items.len);
    try std.testing.expectEqualStrings("env", caps.items[0]);
    try std.testing.expect(!extraction.non_literal);
}

test "an unannotated return type reports non_literal false" {
    const allocator = std.testing.allocator;
    var pool = TypePool.init(allocator);
    defer pool.deinit(allocator);

    var env = TypeEnv.init(allocator, &pool);
    defer env.deinit();

    // No marker at all: the capsule is opt-in, so this must stay quiet.
    const idx = env.resolveType("string");

    var caps: std.ArrayListUnmanaged([]const u8) = .empty;
    defer caps.deinit(allocator);
    const extraction = try env.extractEffectMembers(idx, &caps);
    try std.testing.expectEqual(@as(usize, 0), caps.items.len);
    try std.testing.expect(!extraction.non_literal);
}

test "Proof<Effects<...>, ...> composes: each marker extracted independently" {
    const allocator = std.testing.allocator;
    var pool = TypePool.init(allocator);
    defer pool.deinit(allocator);

    var env = TypeEnv.init(allocator, &pool);
    defer env.deinit();

    const idx = env.resolveType("Proof<Effects<string, \"env\">, \"pure\">");

    var caps: std.ArrayListUnmanaged([]const u8) = .empty;
    defer caps.deinit(allocator);
    _ = try env.extractEffectMembers(idx, &caps);
    try std.testing.expectEqual(@as(usize, 1), caps.items.len);
    try std.testing.expectEqualStrings("env", caps.items[0]);

    var specs: std.ArrayListUnmanaged([]const u8) = .empty;
    defer specs.deinit(allocator);
    _ = try env.extractSpecMembers(idx, &specs);
    try std.testing.expectEqual(@as(usize, 1), specs.items.len);
    try std.testing.expectEqualStrings("pure", specs.items[0]);
}

test "TypeEnv leading-pipe union literal" {
    const allocator = std.testing.allocator;
    var pool = TypePool.init(allocator);
    defer pool.deinit(allocator);

    var env = TypeEnv.init(allocator, &pool);
    defer env.deinit();

    // type Names = | "a" | "b" | "c"
    const source = "type Names = | \"a\" | \"b\" | \"c\";";
    var tm = TypeMap.init(source);
    defer tm.deinit(allocator);

    try tm.addEntry(allocator, .{
        .kind = .type_alias,
        .source_start = 13, // "| \"a\" | \"b\" | \"c\""
        .source_end = 30,
        .context_line = 1,
        .context_col = 1,
        .name_start = 5, // "Names"
        .name_end = 10,
    });

    env.populateFromTypeMap(&tm);

    const names_idx = env.getTypeAlias("Names");
    try std.testing.expect(names_idx != null);
    try std.testing.expectEqual(type_pool_mod.TypeTag.t_union, pool.getTag(names_idx.?).?);
    try std.testing.expectEqual(@as(usize, 3), pool.getUnionMembers(names_idx.?).len);
}

test "splitTypeParams reads an alias list, which arrives with its angle brackets" {
    // The stripper records a function's list without the brackets and an
    // alias's with them. Splitting on commas alone made the alias's one
    // parameter name `<V>`, which no `t_ref` in the body matched, so every
    // generic alias resolved to its uninstantiated body.
    var out: [MAX_TYPE_PARAMS]TypeParamSpec = undefined;

    try std.testing.expectEqual(@as(usize, 1), splitTypeParams("<V>", &out));
    try std.testing.expectEqualStrings("V", out[0].name);
    try std.testing.expectEqualStrings("", out[0].constraint_text);

    try std.testing.expectEqual(@as(usize, 2), splitTypeParams("T, U", &out));
    try std.testing.expectEqualStrings("T", out[0].name);
    try std.testing.expectEqualStrings("U", out[1].name);
}

test "splitTypeParams keeps a constraint that carries its own commas" {
    var out: [MAX_TYPE_PARAMS]TypeParamSpec = undefined;
    const count = splitTypeParams("T, U extends Record<string, number>", &out);
    try std.testing.expectEqual(@as(usize, 2), count);
    try std.testing.expectEqualStrings("T", out[0].name);
    try std.testing.expectEqualStrings("U", out[1].name);
    try std.testing.expectEqualStrings("Record<string, number>", out[1].constraint_text);
}

test "splitTypeParams reads an extends bound and stops a name at a default" {
    var out: [MAX_TYPE_PARAMS]TypeParamSpec = undefined;

    try std.testing.expectEqual(@as(usize, 1), splitTypeParams("T extends { id: string }", &out));
    try std.testing.expectEqualStrings("T", out[0].name);
    try std.testing.expectEqualStrings("{ id: string }", out[0].constraint_text);

    // `extendsFoo` is a type name, not a bound.
    try std.testing.expectEqual(@as(usize, 1), splitTypeParams("Textends", &out));
    try std.testing.expectEqualStrings("Textends", out[0].name);
    try std.testing.expectEqualStrings("", out[0].constraint_text);

    // Defaults are outside the admitted subset; the name still reads cleanly.
    try std.testing.expectEqual(@as(usize, 1), splitTypeParams("T = string", &out));
    try std.testing.expectEqualStrings("T", out[0].name);
}

test "a generic alias instantiates through the stripper's own recording" {
    // End-to-end over the real TypeMap rather than a hand-built one: the
    // hand-built tests passed while the pipeline was broken, because they
    // wrote the parameter list the way the alias path wanted to read it.
    const allocator = std.testing.allocator;
    var strip_result = try @import("stripper.zig").strip(
        allocator,
        "type Box<V> = { v: V };\nconst b: Box<string> = { v: \"x\" };\n",
        .{},
    );
    defer strip_result.deinit();

    var pool = TypePool.init(allocator);
    defer pool.deinit(allocator);
    var env = TypeEnv.init(allocator, &pool);
    defer env.deinit();
    env.populateFromTypeMap(&strip_result.type_map);

    const box = env.resolveType("Box<string>");
    try std.testing.expectEqual(type_pool_mod.TypeTag.t_record, pool.getTag(box).?);
    const fields = pool.getRecordFields(box);
    try std.testing.expectEqual(@as(usize, 1), fields.len);
    try std.testing.expectEqual(pool.idx_string, fields[0].type_idx);
}

test "splitTypeParams keeps a list whose bound is a function type" {
    // The `>` of `=>` was counted as a closing angle bracket, which drove the
    // depth negative and emitted no entries at all - so the signature lost
    // every type parameter and its bound went unchecked.
    var out: [MAX_TYPE_PARAMS]TypeParamSpec = undefined;

    const one = splitTypeParams("T extends (s: string) => number", &out);
    try std.testing.expectEqual(@as(usize, 1), one);
    try std.testing.expectEqualStrings("T", out[0].name);
    try std.testing.expectEqualStrings("(s: string) => number", out[0].constraint_text);

    const two = splitTypeParams("T extends (s: string) => number, U", &out);
    try std.testing.expectEqual(@as(usize, 2), two);
    try std.testing.expectEqualStrings("U", out[1].name);
}

test "a type-parameter list wrapped across lines still reaches its signature" {
    // The stripper records the list after `skipBalancedAngles` has moved its
    // line counter to the closing `>`, while the parameter and return
    // annotations are keyed to the line the signature starts on. Keyed apart,
    // the signature read as monomorphic and its bound was never checked.
    const allocator = std.testing.allocator;
    var strip_result = try @import("stripper.zig").strip(
        allocator,
        "function pick<\n  T,\n  U extends { id: string }\n>(a: T, b: U): T {\n  return a;\n}\n",
        .{},
    );
    defer strip_result.deinit();

    var pool = TypePool.init(allocator);
    defer pool.deinit(allocator);
    var env = TypeEnv.init(allocator, &pool);
    defer env.deinit();
    env.populateFromTypeMap(&strip_result.type_map);

    const sig = env.getFnSigByName("pick") orelse return error.MissingSig;
    try std.testing.expectEqual(@as(u8, 2), sig.type_param_count);
    try std.testing.expectEqualStrings("T", sig.type_params[0].name);
    try std.testing.expectEqualStrings("U", sig.type_params[1].name);
    try std.testing.expect(sig.type_params[1].constraint != null_type_idx);
}

test "an explicit type argument carrying a comma is one argument" {
    // `make<Record<string, number>>(1)` split on every comma read as two
    // arguments and the call was refused for the wrong arity.
    const allocator = std.testing.allocator;
    var strip_result = try @import("stripper.zig").strip(
        allocator,
        "function make<T>(n: number): T {\n  return hole();\n}\nconst v = make<Record<string, number>>(1);\n",
        .{},
    );
    defer strip_result.deinit();

    var pool = TypePool.init(allocator);
    defer pool.deinit(allocator);
    var env = TypeEnv.init(allocator, &pool);
    defer env.deinit();
    env.populateFromTypeMap(&strip_result.type_map);

    var it = env.call_type_args.iterator();
    var seen: usize = 0;
    while (it.next()) |entry| {
        try std.testing.expectEqual(@as(u8, 1), entry.value_ptr.count);
        seen += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), seen);
}

test "readonly on an array alias survives to the resolved type" {
    // The type-expression parser has no alias map, so the name is still a
    // `t_ref` when the modifier is read and the modifier was dropped: a
    // declared read-only value was accepted by a mutating parameter.
    const allocator = std.testing.allocator;
    var strip_result = try @import("stripper.zig").strip(
        allocator,
        "type Items = string[];\nconst f: readonly Items = [\"a\"];\n",
        .{},
    );
    defer strip_result.deinit();

    var pool = TypePool.init(allocator);
    defer pool.deinit(allocator);
    var env = TypeEnv.init(allocator, &pool);
    defer env.deinit();
    env.populateFromTypeMap(&strip_result.type_map);

    const resolved = env.resolveType("readonly Items");
    try std.testing.expectEqual(type_pool_mod.TypeTag.t_array, pool.getTag(resolved).?);
    try std.testing.expect(pool.isReadonlyArray(resolved));
    // The control: without the modifier the same alias stays mutable.
    try std.testing.expect(!pool.isReadonlyArray(env.resolveType("Items")));
}
