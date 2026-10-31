//! Type Environment: resolves type names to TypePool indices.
//!
//! Resolves validated syntax owners. Provides:
//! - Type alias resolution (structural Foo = ...)
//! - Interface resolution (interface Bar { ... })
//! - Variable type annotations (const x: Type = ...)
//! - Function signatures (params + return types)
//! - Generic scope tracking
//!
//! TypeEnv publishes structured types in TypePool and retains selected source metadata.

const std = @import("std");
const engine = @import("zts-engine");
const type_pool_mod = @import("type_pool.zig");
const type_syntax_lowering = @import("type_syntax_lowering.zig");

const TypePool = type_pool_mod.TypePool;
const TypeIndex = type_pool_mod.TypeIndex;
const null_type_idx = type_pool_mod.null_type_idx;
const parseTypeText = type_syntax_lowering.parseTypeText;
const TypeSyntax = engine.parser.type_syntax;
const IrView = engine.parser.IrView;
const NodeIndex = engine.parser.NodeIndex;
const AtomTable = engine.atom_table.AtomTable;
const Atom = engine.object.Atom;

pub const SourceTypeMode = enum { omitted, direct };

pub const DirectSyntaxInput = struct {
    store: *const TypeSyntax.Store,
    ir_view: IrView,
    atoms: *AtomTable,
};

pub const SourceTypeInput = union(SourceTypeMode) {
    omitted,
    direct: DirectSyntaxInput,
};

/// A borrowed source selection for consumers of an already-populated environment.
pub const ConsumerTypeSource = union(SourceTypeMode) {
    omitted,
    direct: *const TypeEnv,

    pub fn validate(self: @This()) !?*const TypeEnv {
        return switch (self) {
            .omitted => null,
            .direct => |env| blk: {
                try env.ensureHealthy();
                try env.pool.ensureHealthy();
                if (env.sourceTypeMode() != .direct) return error.TypeSourceModeMismatch;
                break :blk env;
            },
        };
    }

    pub fn fromEnvironment(env: ?*const TypeEnv) !@This() {
        const selected = env orelse return .omitted;
        try selected.ensureHealthy();
        try selected.pool.ensureHealthy();
        return switch (selected.sourceTypeMode() orelse return error.TypeSourceModeMismatch) {
            .omitted => .omitted,
            .direct => .{ .direct = selected },
        };
    }
};

pub const FunctionTypeRef = struct {
    direct_owner: NodeIndex,
};

const DirectVariableType = struct {
    binding: engine.parser.BindingRef,
    type_idx: TypeIndex,
};

const DirectSourceAnnotationKey = struct {
    owner: NodeIndex,
    slot: u8,
};

const DirectFunctionAccumulator = struct {
    signature: FunctionSig = .{},
    publish_name: bool = false,
};

const DirectCompatibilityOrder = std.AutoHashMapUnmanaged(u32, NodeIndex);
const DirectFunctionAccumulators = std.AutoHashMapUnmanaged(NodeIndex, DirectFunctionAccumulator);

const DirectReplayPhase = enum {
    before,
    after,
};

/// A callback may read these maps only until the callback returns.
const DirectReplaySnapshot = struct {
    phase: DirectReplayPhase,
    compatibility_key: u32,
    owner: NodeIndex,
    compatibility_found_existing: bool,
    compatibility_capacity: usize,
    compatibility_count: usize,
    accumulator_capacity: usize,
    accumulator_count: usize,
    compatibility_order: *const DirectCompatibilityOrder,
    accumulators: *const DirectFunctionAccumulators,
};

const DirectReplayObserver = struct {
    context: *anyopaque,
    visit: *const fn (context: *anyopaque, snapshot: DirectReplaySnapshot) void,

    fn observe(self: DirectReplayObserver, snapshot: DirectReplaySnapshot) void {
        self.visit(self.context, snapshot);
    }
};

const DirectGenericSets = std.AutoHashMapUnmanaged(NodeIndex, ParsedGenericSet);

/// The field name used to mark a record as the proof payload of an instantiated
/// `Proof<T, P>` capsule. The verifier looks for records bearing this field
/// when extracting declared proof sets from a function return type.
/// Sized to be unmistakable for any user-authored field.
pub const proof_marker_field = "__zttp_proof__";

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

test "consumer type source validates modes and health before absence" {
    const allocator = std.testing.allocator;
    var unselected_pool = TypePool.init(allocator);
    defer unselected_pool.deinit(allocator);
    var unselected = TypeEnv.init(allocator, &unselected_pool);
    defer unselected.deinit();
    try std.testing.expectEqual(.omitted, std.meta.activeTag(try ConsumerTypeSource.fromEnvironment(null)));
    try std.testing.expectError(error.TypeSourceModeMismatch, ConsumerTypeSource.fromEnvironment(&unselected));
    try std.testing.expectError(error.TypeSourceModeMismatch, (ConsumerTypeSource{ .direct = &unselected }).validate());

    var omitted_pool = TypePool.init(allocator);
    defer omitted_pool.deinit(allocator);
    var omitted = TypeEnv.init(allocator, &omitted_pool);
    defer omitted.deinit();
    try omitted.populateSourceTypes(.omitted);
    try std.testing.expect(try (try ConsumerTypeSource.fromEnvironment(&omitted)).validate() == null);
    try std.testing.expectError(error.TypeSourceModeMismatch, (ConsumerTypeSource{ .direct = &omitted }).validate());

    var frontend: engine.source_frontend.DirectCheckSource = undefined;
    try frontend.initCompileInPlace(allocator, allocator, "const value: number = 1;", "selection.ts");
    defer frontend.deinit();
    const accepted = frontend.acceptedCapabilities() orelse return error.TestUnexpectedResult;
    var direct_pool = TypePool.init(allocator);
    defer direct_pool.deinit(allocator);
    var direct = TypeEnv.init(allocator, &direct_pool);
    defer direct.deinit();
    try direct.populateSourceTypes(.{ .direct = .{
        .store = accepted.type_store,
        .ir_view = accepted.ir_view,
        .atoms = accepted.atoms,
    } });
    try std.testing.expectEqual(&direct, (try (try ConsumerTypeSource.fromEnvironment(&direct)).validate()).?);

    unselected.markAllocationFailure();
    try std.testing.expectError(error.OutOfMemory, ConsumerTypeSource.fromEnvironment(&unselected));
    try std.testing.expectError(error.OutOfMemory, (ConsumerTypeSource{ .direct = &unselected }).validate());
    omitted_pool.failure = error.TypePoolCapacityExceeded;
    try std.testing.expectError(error.TypePoolCapacityExceeded, ConsumerTypeSource.fromEnvironment(&omitted));
    try std.testing.expectError(error.TypePoolCapacityExceeded, (ConsumerTypeSource{ .direct = &omitted }).validate());
}

/// The field name marking the body of an instantiated `Effects<...>` generic
/// alias. Distinct from `proof_marker_field` so a return type carrying both
/// (`Proof<Effects<Response, "env">, "deterministic">`) keeps capability
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
    owner_token: u64 = 0,

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
};

/// One declared type parameter of a function signature.
pub const GenericParam = struct {
    /// Interned, so it outlives the source syntax the signature was read from.
    name: []const u8 = "",
    /// The `t_generic_param` node the name resolves to inside the signature.
    idx: TypeIndex = null_type_idx,
    /// The `extends` bound, or `null_type_idx` when unconstrained.
    constraint: TypeIndex = null_type_idx,
};

pub const ParsedGenericInput = struct {
    name: []const u8,
    constraint: ?TypeIndex = null,
};

pub const ParsedGenericScope = struct {
    owner_env: *TypeEnv,
    prior_depth: usize,
    owner_token: u64,
    params: [MAX_TYPE_PARAMS]GenericParam = @splat(.{}),
    count: u8 = 0,
    active: bool = true,
};

pub const ParsedGenericSet = struct {
    owner_env: *TypeEnv,
    params: [MAX_TYPE_PARAMS]GenericParam = @splat(.{}),
    count: u8 = 0,
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
    /// The most arguments a call may supply, set only when the callee's own
    /// parameter list is known: the parameter nodes of a source function, or the
    /// declared function type of a parameter. A signature built from annotations
    /// alone can hold fewer entries than the function has parameters, and a
    /// module export's table is checked elsewhere, so both leave it null.
    max_arg_count: ?u8 = null,
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

// ---------------------------------------------------------------------------
// Generic type alias (structural Result<T> = ...)
// ---------------------------------------------------------------------------

pub const GenericAlias = struct {
    param_names: [8][]const u8 = undefined,
    param_count: u8 = 0,
    body: TypeIndex = null_type_idx,
};

// ---------------------------------------------------------------------------
// Type Environment
// ---------------------------------------------------------------------------

pub const TypeEnv = struct {
    pool: *TypePool,
    allocator: std.mem.Allocator,

    /// Type namespace: type alias name -> resolved TypeIndex
    type_aliases: std.StringHashMapUnmanaged(TypeIndex),
    /// Generic type aliases: name -> uninstantiated body + param names
    generic_aliases: std.StringHashMapUnmanaged(GenericAlias),
    /// Variable name -> declared type (for name-based lookup)
    var_types_by_name: std.StringHashMapUnmanaged(TypeIndex),
    /// Scoped binding identity: packed(scope_id, name_atom) -> declared type.
    var_types_by_binding: std.AutoHashMapUnmanaged(u32, TypeIndex),
    /// Direct annotations keyed by their final runtime declaration.
    direct_var_types: std.AutoHashMapUnmanaged(NodeIndex, DirectVariableType),
    /// Function name -> signature (for name-based lookup)
    fn_sigs_by_name: std.StringHashMapUnmanaged(FunctionSig),
    /// Source-declared function name -> signature. Kept separate from module
    /// exports so a colliding module name cannot masquerade as a user's
    /// function declaration while binding-local metadata is established.
    source_fn_sigs_by_name: std.StringHashMapUnmanaged(FunctionSig),
    /// Direct signatures keyed by their final function or arrow node.
    direct_fn_signatures: std.AutoHashMapUnmanaged(NodeIndex, FunctionSig),
    /// Owned raw spellings keyed by final owner and compact annotation slot.
    direct_source_fn_annotations: std.AutoHashMapUnmanaged(DirectSourceAnnotationKey, []const u8),
    /// Generic scope stack
    generic_scopes: std.ArrayListUnmanaged(GenericScope),
    /// Direct call and compatibility arguments keyed by final runtime owner.
    direct_call_type_args: std.AutoHashMapUnmanaged(NodeIndex, CallTypeArgs),
    /// Alias names whose definition contains a cycle that no data constructor
    /// guards (spec 5.7). Filled once, after the type-namespace pass; read by
    /// the type checker at every site that resolves such a name.
    non_contractive_aliases: std.StringHashMapUnmanaged(void),
    /// The same aliases by the index their name resolves to. An annotation is
    /// resolved before the checker sees it, and only a name with no definition
    /// at all survives as a `t_ref` - `structural U = number | U` arrives as the
    /// union itself, so a name-only lookup would miss every alias that has a
    /// body, which is every one that matters.
    non_contractive_indices: std.AutoHashMapUnmanaged(TypeIndex, void),

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
    source_selection: ?SourceTypeMode = null,
    direct_annotation_count: usize = 0,
    direct_accumulator_events: usize = 0,
    next_generic_owner_token: u64 = 1,

    pub fn init(allocator: std.mem.Allocator, pool: *TypePool) TypeEnv {
        var env: TypeEnv = .{
            .pool = pool,
            .allocator = allocator,
            .type_aliases = .empty,
            .generic_aliases = .empty,
            .var_types_by_name = .empty,
            .var_types_by_binding = .empty,
            .direct_var_types = .empty,
            .fn_sigs_by_name = .empty,
            .source_fn_sigs_by_name = .empty,
            .direct_fn_signatures = .empty,
            .direct_source_fn_annotations = .empty,
            .generic_scopes = .empty,
            .direct_call_type_args = .empty,
            .non_contractive_aliases = .empty,
            .non_contractive_indices = .empty,
            .name_storage = .empty,
        };
        env.registerBuiltins();
        return env;
    }

    /// Record that the environment is missing something it was asked to hold.
    /// Callers that read annotations out of it must refuse to answer rather
    /// than report the gap as an absent declaration.
    pub fn markAllocationFailure(self: *TypeEnv) void {
        self.allocation_failed = true;
    }

    /// Register the ambient proof and effect capsules. Idempotent;
    /// user-declared aliases of the same name overwrite the built-in.
    pub fn registerBuiltins(self: *TypeEnv) void {
        // Proof<T, S> and Effects<T, S> share the capsule shape
        // `T & { <marker>: S }`; they differ only in the marker field.
        self.registerCapsuleAlias("Proof", proof_marker_field);
        self.registerCapsuleAlias("Effects", effect_marker_field);
    }

    /// Register a two-param capsule alias `Name<T, S>` whose body is
    /// `T & { <marker>: S }` - the shape shared by `Proof<T, S>` (marker
    /// `__zttp_proof__`) and `Effects<T, S>` (marker `__zttp_effect__`).
    /// After instantiation the underlying return type `T` survives for type
    /// checking while the phantom marker record carries `S`. Distinct marker
    /// fields let a return type carry both capsules and have each extraction
    /// (`extractProofMembers` / `extractEffectMembers`) recover only its own.
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
        self.non_contractive_aliases.deinit(self.allocator);
        self.non_contractive_indices.deinit(self.allocator);
        self.type_aliases.deinit(self.allocator);
        self.generic_aliases.deinit(self.allocator);
        self.var_types_by_name.deinit(self.allocator);
        self.var_types_by_binding.deinit(self.allocator);
        self.direct_var_types.deinit(self.allocator);
        self.fn_sigs_by_name.deinit(self.allocator);
        self.source_fn_sigs_by_name.deinit(self.allocator);
        self.direct_fn_signatures.deinit(self.allocator);
        self.direct_source_fn_annotations.deinit(self.allocator);
        self.generic_scopes.deinit(self.allocator);
        self.direct_call_type_args.deinit(self.allocator);
        for (self.name_storage.items) |name| {
            self.allocator.free(name);
        }
        self.name_storage.deinit(self.allocator);
    }

    // -------------------------------------------------------------------
    // Population from direct syntax
    // -------------------------------------------------------------------

    const DirectHeaderCursor = struct {
        signature_index: usize = 0,
        parameter_index: usize = 0,
        return_consumed: bool = false,
    };

    const DirectHeaderEvent = union(enum) {
        parameter: struct {
            signature: *const TypeSyntax.FunctionSignature,
            annotation: *const TypeSyntax.ParameterAnnotation,
        },
        return_value: struct {
            signature: *const TypeSyntax.FunctionSignature,
            syntax: *const TypeSyntax.ReturnSyntax,
        },

        fn start(self: DirectHeaderEvent) u32 {
            return switch (self) {
                .parameter => |event| event.annotation.value.raw_span.start,
                .return_value => |event| event.syntax.raw_span.start,
            };
        }
    };

    /// Select one source of type metadata. Explicit selections are single-use.
    pub fn populateSourceTypes(self: *TypeEnv, input: SourceTypeInput) !void {
        return self.populateSourceTypesImpl(input, null);
    }

    fn populateSourceTypesImpl(
        self: *TypeEnv,
        input: SourceTypeInput,
        observer: ?DirectReplayObserver,
    ) !void {
        if (self.source_selection != null) return error.TypeSourceAlreadySelected;
        switch (input) {
            .omitted => {
                self.source_selection = .omitted;
            },
            .direct => |direct| {
                var application_bases = direct.store.planApplicationBasesWithIr(
                    self.allocator,
                    direct.ir_view,
                ) catch |err| {
                    return self.retainDirectValidationFailure(err);
                };
                defer application_bases.deinit();
                try validateDirectSourceOrder(direct.store);

                self.source_selection = .direct;
                self.direct_annotation_count = direct.store.annotations.items.len;
                self.populateSelectedDirectSourceTypes(direct, &application_bases, observer) catch |err| {
                    self.retainDirectPopulationFailure(err);
                    return err;
                };
            },
        }
    }

    fn populateSelectedDirectSourceTypes(
        self: *TypeEnv,
        direct: DirectSyntaxInput,
        application_bases: *const TypeSyntax.Store.ApplicationBasePlan,
        observer: ?DirectReplayObserver,
    ) !void {
        try self.populateDirectSourceTypes(direct, application_bases, observer);
        try self.pool.ensureHealthy();
        try self.ensureHealthy();
    }

    fn retainDirectPopulationFailure(self: *TypeEnv, err: anyerror) void {
        switch (err) {
            error.TypePoolCapacityExceeded => {}, // The pool retains this failure.
            else => self.markAllocationFailure(),
        }
    }

    fn retainDirectValidationFailure(self: *TypeEnv, err: anyerror) anyerror {
        if (err == error.OutOfMemory) self.markAllocationFailure();
        return err;
    }

    pub fn sourceTypeMode(self: *const TypeEnv) ?SourceTypeMode {
        return self.source_selection;
    }

    fn validateDirectSourceOrder(store: *const TypeSyntax.Store) !void {
        try validateDirectCallOrder(store);

        var previous_annotation_start: ?u32 = null;
        for (store.annotations.items) |annotation| {
            if (previous_annotation_start) |previous| {
                if (previous >= annotation.raw_span.start) return error.InvalidTypeSourceOrder;
            }
            previous_annotation_start = annotation.raw_span.start;
        }

        var previous_header_start: ?u32 = null;
        for (store.function_signatures.items) |signature| {
            const parameters = store.parameterAnnotationSlice(signature.parameters) orelse
                return error.InvalidTypeRange;
            for (parameters) |parameter| {
                if (previous_header_start) |previous| {
                    if (previous >= parameter.value.raw_span.start) return error.InvalidTypeSourceOrder;
                }
                previous_header_start = parameter.value.raw_span.start;
            }
            if (signature.return_syntax) |return_syntax| {
                if (previous_header_start) |previous| {
                    if (previous >= return_syntax.raw_span.start) return error.InvalidTypeSourceOrder;
                }
                previous_header_start = return_syntax.raw_span.start;
            }
        }
    }

    fn validateDirectCallOrder(store: *const TypeSyntax.Store) !void {
        var previous_start: ?u32 = null;
        for (store.explicit_call_arguments.items) |explicit| {
            if (previous_start) |previous| {
                if (previous >= explicit.list_span.start) return error.InvalidTypeSourceOrder;
            }
            previous_start = explicit.list_span.start;
        }
    }

    fn populateDirectSourceTypes(
        self: *TypeEnv,
        input: DirectSyntaxInput,
        application_bases: *const TypeSyntax.Store.ApplicationBasePlan,
        observer: ?DirectReplayObserver,
    ) !void {
        try self.pool.ensureHealthy();
        try self.ensureHealthy();

        const lowered = try self.allocator.alloc(TypeIndex, input.store.nodes.items.len);
        defer self.allocator.free(lowered);
        @memset(lowered, null_type_idx);

        for (input.store.declarations.items, 0..) |_, declaration_index| {
            try self.populateParsedDeclaration(
                input.store,
                application_bases,
                lowered,
                declaration_index,
            );
        }
        self.finishTypeAliasPopulation();
        try self.pool.ensureHealthy();
        try self.ensureHealthy();

        // Phase 2: create callable generic parameters in source order.
        var callable_sets: DirectGenericSets = .empty;
        defer callable_sets.deinit(self.allocator);
        try self.populateDirectGenericPhase(
            input,
            application_bases,
            lowered,
            &callable_sets,
        );

        // Phase 3: resolve call arguments in source order.
        try self.populateDirectCallPhase(input, application_bases, lowered);

        var compatibility_order: DirectCompatibilityOrder = .empty;
        defer compatibility_order.deinit(self.allocator);
        var function_accumulators: DirectFunctionAccumulators = .empty;
        defer function_accumulators.deinit(self.allocator);

        // Phase 4: merge variable and header values by their authored spans.
        var annotation_index: usize = 0;
        var header_cursor: DirectHeaderCursor = .{};
        while (true) {
            const header_event = directHeaderEvent(input.store, &header_cursor);
            const annotation = if (annotation_index < input.store.annotations.items.len)
                &input.store.annotations.items[annotation_index]
            else
                null;
            if (annotation == null and header_event == null) break;

            if (annotation != null and
                (header_event == null or annotation.?.raw_span.start < header_event.?.start()))
            {
                try self.populateDirectVariable(
                    input,
                    application_bases,
                    lowered,
                    annotation.?,
                );
                annotation_index += 1;
                continue;
            }

            const event = header_event.?;
            switch (event) {
                .parameter => |parameter_event| {
                    const accumulator = try self.replayDirectSignatureEvent(
                        input.ir_view,
                        parameter_event.signature,
                        &compatibility_order,
                        &function_accumulators,
                        observer,
                    );
                    const parameter = parameter_event.annotation;
                    const type_idx = try self.lowerDirectHeaderRoot(
                        input.store,
                        application_bases,
                        lowered,
                        &callable_sets,
                        parameter_event.signature.owner,
                        parameter.value.root,
                        parameter.value.node_range,
                        parameter.value.raw_span,
                    );
                    if (accumulator.signature.param_count < accumulator.signature.param_types.len) {
                        const compact_position = accumulator.signature.param_count;
                        accumulator.signature.param_types[compact_position] = type_idx;
                        accumulator.signature.param_count += 1;
                        try self.putDirectSourceAnnotation(
                            parameter_event.signature.owner,
                            compact_position,
                            parameter.value.raw_span.text(input.store.source),
                        );
                    }
                },
                .return_value => |return_event| {
                    try self.populateDirectReturn(
                        input,
                        application_bases,
                        lowered,
                        &callable_sets,
                        return_event.signature,
                        return_event.syntax,
                        &compatibility_order,
                        &function_accumulators,
                        observer,
                    );
                },
            }
            advanceDirectHeaderCursor(&header_cursor, event);
        }

        // Phase 5: retain signatures and merge name fallbacks in bucket order.
        var iterator = compatibility_order.iterator();
        while (iterator.next()) |entry| {
            const owner = entry.value_ptr.*;
            var accumulator = function_accumulators.get(owner) orelse
                return error.InvalidFunctionSignatureOwner;
            if (callable_sets.get(owner)) |set| {
                @memcpy(
                    accumulator.signature.type_params[0..set.count],
                    set.params[0..set.count],
                );
                accumulator.signature.type_param_count = set.count;
            }
            try self.direct_fn_signatures.put(self.allocator, owner, accumulator.signature);
            if (!accumulator.publish_name) continue;
            const function = input.ir_view.getFunction(owner) orelse
                return error.InvalidFunctionSignatureOwner;
            const name = runtimeAtomName(input.atoms, function.name_atom) orelse continue;
            const owned_name = self.internName(name);
            try self.ensureHealthy();
            try self.fn_sigs_by_name.put(self.allocator, owned_name, accumulator.signature);
            try self.source_fn_sigs_by_name.put(self.allocator, owned_name, accumulator.signature);
        }
    }

    fn populateDirectGenericPhase(
        self: *TypeEnv,
        input: DirectSyntaxInput,
        application_bases: *const TypeSyntax.Store.ApplicationBasePlan,
        lowered: []TypeIndex,
        callable_sets: *DirectGenericSets,
    ) !void {
        for (input.store.generic_owners.items) |owner| {
            const is_callable = switch (owner.identity) {
                .function, .arrow => true,
                .structural_declaration, .nominal_declaration => false,
            };
            if (!is_callable or
                std.meta.activeTag(owner.compatibility) != .declaration_parameters)
            {
                continue;
            }
            const owner_node = switch (owner.identity) {
                .function => |node| node,
                .arrow => |node| node,
                .structural_declaration, .nominal_declaration => return error.InvalidGenericOwner,
            };
            if (try self.populateDirectGenericProjection(
                input.store,
                application_bases,
                lowered,
                owner.projected_parameters,
            )) |set| {
                try callable_sets.put(self.allocator, owner_node, set);
            }
        }
    }

    fn populateDirectCallPhase(
        self: *TypeEnv,
        input: DirectSyntaxInput,
        application_bases: *const TypeSyntax.Store.ApplicationBasePlan,
        lowered: []TypeIndex,
    ) !void {
        for (input.store.explicit_call_arguments.items) |explicit| {
            try self.populateDirectCallArguments(
                input,
                application_bases,
                lowered,
                explicit.owner,
                explicit.semantic_fragments,
            );
        }
    }

    fn populateDirectCallArguments(
        self: *TypeEnv,
        input: DirectSyntaxInput,
        application_bases: *const TypeSyntax.Store.ApplicationBasePlan,
        lowered: []TypeIndex,
        owner: NodeIndex,
        fragment_range: TypeSyntax.Range,
    ) !void {
        try self.pool.ensureHealthy();
        try self.ensureHealthy();
        const tag = input.ir_view.getTag(owner) orelse return error.InvalidGenericOwner;
        if (tag != .call) return error.InvalidGenericOwner;
        const fragments = input.store.semanticFragmentSlice(fragment_range) orelse
            return error.InvalidTypeRange;
        if (fragments.len > MAX_TYPE_PARAMS) return error.InvalidTypeRange;
        if (fragments.len == 0) return;

        var arguments: CallTypeArgs = .{};
        for (fragments, 0..) |fragment, index| {
            arguments.args[index] = try self.lowerDirectRoot(
                input.store,
                application_bases,
                lowered,
                fragment.root,
                fragment.node_range,
                fragment.raw_span,
            );
        }
        arguments.count = @intCast(fragments.len);
        try self.pool.ensureHealthy();
        try self.ensureHealthy();
        try self.direct_call_type_args.put(self.allocator, owner, arguments);
        try self.pool.ensureHealthy();
        try self.ensureHealthy();
    }

    fn populateDirectGenericProjection(
        self: *TypeEnv,
        store: *const TypeSyntax.Store,
        application_bases: *const TypeSyntax.Store.ApplicationBasePlan,
        lowered: []TypeIndex,
        projected_range: TypeSyntax.Range,
    ) !?ParsedGenericSet {
        const projected = store.projectedGenericParameterSlice(projected_range) orelse
            return error.InvalidTypeRange;
        if (projected.len == 0) return null;
        if (projected.len > MAX_TYPE_PARAMS) return error.InvalidTypeRange;

        var inputs: [MAX_TYPE_PARAMS]ParsedGenericInput = undefined;
        for (projected, 0..) |parameter, index| {
            inputs[index] = .{ .name = parameter.name_span.text(store.source) };
        }

        var scope = try self.beginParsedGenerics(inputs[0..projected.len]);
        for (projected, 0..) |parameter, index| {
            if (index >= scope.count) break;
            const fragment_index = parameter.bound_fragment orelse continue;
            const constraint_result = self.lowerParsedGenericBound(
                store,
                application_bases,
                lowered,
                &scope,
                fragment_index,
            );
            inputs[index].constraint = if (constraint_result) |constraint|
                constraint
            else |err|
                return @as(anyerror!?ParsedGenericSet, self.closeParsedScopeAfterError(&scope, err));
        }

        const installation_result = self.installParsedConstraints(
            &scope,
            inputs[0..projected.len],
        );
        if (installation_result) |_| {} else |err| {
            return @as(anyerror!?ParsedGenericSet, self.closeParsedScopeAfterError(&scope, err));
        }

        const retained: ?ParsedGenericSet = if (scope.count == 0)
            null
        else blk: {
            const capture_result = self.captureParsedGenericSet(&scope);
            break :blk if (capture_result) |set|
                set
            else |err|
                return @as(
                    anyerror!?ParsedGenericSet,
                    self.closeParsedScopeAfterError(&scope, err),
                );
        };
        try self.endParsedGenerics(&scope);
        return retained;
    }

    fn lowerParsedGenericBound(
        self: *TypeEnv,
        store: *const TypeSyntax.Store,
        application_bases: *const TypeSyntax.Store.ApplicationBasePlan,
        lowered: []TypeIndex,
        owner: *const ParsedGenericScope,
        fragment_index: u32,
    ) !TypeIndex {
        if (@as(usize, fragment_index) >= store.semantic_fragments.items.len) {
            return error.InvalidTypeRange;
        }
        const fragment = store.semantic_fragments.items[fragment_index];
        const exact = fragment.raw_span.text(store.source);
        const trimmed = std.mem.trim(u8, exact, " \t\r\n");
        if (std.mem.eql(u8, trimmed, "DictKey")) {
            return self.finishParsedBoundRoot(owner, exact, null_type_idx);
        }
        if (self.getTypeAlias(trimmed)) |type_idx| return type_idx;
        if (try self.resolveParsedGenericParam(owner, trimmed)) |type_idx| return type_idx;
        try type_syntax_lowering.lowerOwnedRange(
            self.allocator,
            store,
            self.pool,
            lowered,
            application_bases,
            fragment.node_range,
        );
        return self.finishParsedBoundRoot(
            owner,
            exact,
            try type_syntax_lowering.loweredChild(lowered, fragment.root, lowered.len),
        );
    }

    fn lowerDirectHeaderRoot(
        self: *TypeEnv,
        store: *const TypeSyntax.Store,
        application_bases: *const TypeSyntax.Store.ApplicationBasePlan,
        lowered: []TypeIndex,
        callable_sets: *const DirectGenericSets,
        owner: NodeIndex,
        root: TypeSyntax.Child,
        node_range: TypeSyntax.Range,
        raw_span: TypeSyntax.Span,
    ) !TypeIndex {
        const set = callable_sets.get(owner) orelse return self.lowerDirectRoot(
            store,
            application_bases,
            lowered,
            root,
            node_range,
            raw_span,
        );
        var scope = try self.beginParsedGenericUse(&set);
        const lowering_result = self.lowerParsedGenericRoot(
            store,
            application_bases,
            lowered,
            &scope,
            root,
            node_range,
            raw_span,
        );
        const type_idx = if (lowering_result) |result|
            result
        else |err|
            return @as(anyerror!TypeIndex, self.closeParsedScopeAfterError(&scope, err));
        try self.endParsedGenerics(&scope);
        return type_idx;
    }

    fn populateDirectReturn(
        self: *TypeEnv,
        input: DirectSyntaxInput,
        application_bases: *const TypeSyntax.Store.ApplicationBasePlan,
        lowered: []TypeIndex,
        callable_sets: *const DirectGenericSets,
        signature: *const TypeSyntax.FunctionSignature,
        syntax: *const TypeSyntax.ReturnSyntax,
        compatibility_order: *DirectCompatibilityOrder,
        function_accumulators: *DirectFunctionAccumulators,
        observer: ?DirectReplayObserver,
    ) !void {
        const ordinary_value: ?TypeSyntax.TypeValue = switch (syntax.structure) {
            .value => |value| value,
            .predicate => null,
        };
        if (ordinary_value) |value| {
            const type_idx = try self.lowerDirectHeaderRoot(
                input.store,
                application_bases,
                lowered,
                callable_sets,
                signature.owner,
                value.root,
                value.node_range,
                value.raw_span,
            );
            const accumulator = try self.replayDirectSignatureEvent(
                input.ir_view,
                signature,
                compatibility_order,
                function_accumulators,
                observer,
            );
            accumulator.signature.return_type = type_idx;
            accumulator.publish_name = input.ir_view.getTag(signature.owner) == .function_expr;
            try self.putDirectSourceAnnotation(
                signature.owner,
                return_annotation_slot,
                syntax.raw_span.text(input.store.source),
            );
        } else {
            const predicate = syntax.structure.predicate;
            const accumulator = try self.replayDirectSignatureEvent(
                input.ir_view,
                signature,
                compatibility_order,
                function_accumulators,
                observer,
            );
            accumulator.signature.return_type = self.pool.idx_boolean;
            accumulator.publish_name = input.ir_view.getTag(signature.owner) == .function_expr;

            switch (predicate.target) {
                .unresolved => return,
                .resolved => {},
            }
            switch (predicate.narrowed.root) {
                .absent => return error.InvalidReturnSyntax,
                .present => {},
            }
            const compact_position = directPredicateParameterIndex(
                input.store,
                input.atoms,
                signature,
                predicate.target_span.text(input.store.source),
            ) orelse return;
            const narrowed = try self.lowerDirectHeaderRoot(
                input.store,
                application_bases,
                lowered,
                callable_sets,
                signature.owner,
                predicate.narrowed.root,
                predicate.narrowed.node_range,
                predicate.narrowed.raw_span,
            );
            if (narrowed == null_type_idx) return;
            accumulator.signature.type_predicate = .{
                .param_index = compact_position,
                .narrowed = narrowed,
            };
        }
    }

    fn directPredicateParameterIndex(
        store: *const TypeSyntax.Store,
        atoms: *AtomTable,
        signature: *const TypeSyntax.FunctionSignature,
        target: []const u8,
    ) ?u8 {
        const parameters = store.parameterAnnotationSlice(signature.parameters) orelse return null;
        for (parameters[0..@min(parameters.len, 16)], 0..) |parameter, index| {
            const name = runtimeAtomName(atoms, parameter.owner.binding.name_atom) orelse continue;
            if (std.mem.eql(u8, name, target)) return @intCast(index);
        }
        return null;
    }

    fn populateDirectVariable(
        self: *TypeEnv,
        input: DirectSyntaxInput,
        application_bases: *const TypeSyntax.Store.ApplicationBasePlan,
        lowered: []TypeIndex,
        annotation: *const TypeSyntax.Annotation,
    ) !void {
        const owner = annotation.runtime_owner orelse return error.InvalidAnnotationOwner;
        const type_idx = try self.lowerDirectRoot(
            input.store,
            application_bases,
            lowered,
            annotation.root,
            annotation.node_range,
            annotation.raw_span,
        );
        try self.direct_var_types.put(self.allocator, owner.declaration, .{
            .binding = annotation.binding,
            .type_idx = type_idx,
        });

        const name = runtimeAtomName(input.atoms, annotation.binding.name_atom) orelse return;
        const owned_name = self.internName(name);
        try self.ensureHealthy();
        try self.var_types_by_name.put(self.allocator, owned_name, type_idx);
    }

    fn lowerDirectRoot(
        self: *TypeEnv,
        store: *const TypeSyntax.Store,
        application_bases: *const TypeSyntax.Store.ApplicationBasePlan,
        lowered: []TypeIndex,
        root: TypeSyntax.Child,
        node_range: TypeSyntax.Range,
        raw_span: TypeSyntax.Span,
    ) !TypeIndex {
        const exact = std.mem.trim(u8, raw_span.text(store.source), " \t\r\n");
        if (self.getTypeAlias(exact)) |type_idx| return type_idx;
        try type_syntax_lowering.lowerOwnedRange(
            self.allocator,
            store,
            self.pool,
            lowered,
            application_bases,
            node_range,
        );
        const result = self.finishParsedTypeRoot(try type_syntax_lowering.loweredChild(
            lowered,
            root,
            lowered.len,
        ));
        try self.pool.ensureHealthy();
        try self.ensureHealthy();
        return result;
    }

    /// Publish one parsed declaration through the shared direct lowerer.
    pub fn populateParsedDeclaration(
        self: *TypeEnv,
        store: *const TypeSyntax.Store,
        application_bases: *const TypeSyntax.Store.ApplicationBasePlan,
        lowered: []TypeIndex,
        declaration_index: usize,
    ) !void {
        try self.pool.ensureHealthy();
        try self.ensureHealthy();
        if (declaration_index >= store.declarations.items.len) return error.InvalidTypeRange;
        const declaration = store.declarations.items[declaration_index];
        var structural_parameters: ?[]const TypeSyntax.ProjectedGenericParameter = null;
        if (declaration.generic_owner) |owner_index| {
            if (@as(usize, owner_index) >= store.generic_owners.items.len) return error.InvalidGenericOwner;
            const owner = store.generic_owners.items[owner_index];
            const projected = store.projectedGenericParameterSlice(owner.projected_parameters) orelse
                return error.InvalidTypeRange;
            if (projected.len > MAX_TYPE_PARAMS) return error.InvalidTypeRange;
            switch (declaration.kind) {
                .structural => {
                    switch (owner.identity) {
                        .structural_declaration => |owner_declaration_index| {
                            if (@as(usize, owner_declaration_index) != declaration_index) {
                                return error.InvalidGenericOwner;
                            }
                        },
                        else => return error.InvalidGenericOwner,
                    }
                    if (std.meta.activeTag(owner.compatibility) != .declaration_parameters) {
                        return error.InvalidGenericOwner;
                    }
                    structural_parameters = projected;
                },
                .nominal => {
                    switch (owner.identity) {
                        .nominal_declaration => |owner_declaration_index| {
                            if (@as(usize, owner_declaration_index) != declaration_index) {
                                return error.InvalidGenericOwner;
                            }
                        },
                        else => return error.InvalidGenericOwner,
                    }
                    if (std.meta.activeTag(owner.compatibility) != .ignored_declaration_parameters) {
                        return error.InvalidGenericOwner;
                    }
                },
            }
        }

        const present = switch (declaration.body) {
            .absent => {
                try self.pool.ensureHealthy();
                try self.ensureHealthy();
                return;
            },
            .present => |body| body,
        };
        self.populateParsedDeclarationBody(store, application_bases, lowered, declaration, structural_parameters, present) catch |err| {
            self.retainDirectPopulationFailure(err);
            return err;
        };
    }

    fn populateParsedDeclarationBody(
        self: *TypeEnv,
        store: *const TypeSyntax.Store,
        application_bases: *const TypeSyntax.Store.ApplicationBasePlan,
        lowered: []TypeIndex,
        declaration: TypeSyntax.Declaration,
        structural_parameters: ?[]const TypeSyntax.ProjectedGenericParameter,
        present: @FieldType(TypeSyntax.DeclarationBody, "present"),
    ) !void {
        if (structural_parameters) |projected| {
            var inputs: [MAX_TYPE_PARAMS]ParsedGenericInput = undefined;
            for (projected, 0..) |parameter, index| {
                inputs[index] = .{ .name = parameter.name_span.text(store.source) };
            }
            var scope = try self.beginParsedGenerics(inputs[0..projected.len]);
            const lowered_result = self.lowerParsedGenericRoot(
                store,
                application_bases,
                lowered,
                &scope,
                present.root,
                present.node_range,
                present.raw_span,
            );
            const type_idx = if (lowered_result) |result|
                result
            else |err|
                return @as(anyerror!void, self.closeParsedScopeAfterError(&scope, err));
            const publication_result = self.putParsedGenericAlias(
                declaration.name_span.text(store.source),
                &scope,
                type_idx,
            );
            if (publication_result) |_| {} else |err| {
                return @as(anyerror!void, self.closeParsedScopeAfterError(&scope, err));
            }
            try self.endParsedGenerics(&scope);
            return;
        }
        const type_idx = try self.lowerDirectRoot(
            store,
            application_bases,
            lowered,
            present.root,
            present.node_range,
            present.raw_span,
        );
        const name = declaration.name_span.text(store.source);
        switch (declaration.kind) {
            .structural => self.putTypeAlias(name, type_idx),
            .nominal => if (type_idx != null_type_idx) {
                const nominal = self.pool.addNominalAlias(self.allocator, type_idx, name);
                if (nominal != null_type_idx) self.putTypeAlias(name, nominal);
            },
        }
        try self.pool.ensureHealthy();
        try self.ensureHealthy();
    }

    fn lowerParsedGenericRoot(
        self: *TypeEnv,
        store: *const TypeSyntax.Store,
        application_bases: *const TypeSyntax.Store.ApplicationBasePlan,
        lowered: []TypeIndex,
        owner: *const ParsedGenericScope,
        root: TypeSyntax.Child,
        node_range: TypeSyntax.Range,
        raw_span: TypeSyntax.Span,
    ) !TypeIndex {
        const exact = std.mem.trim(u8, raw_span.text(store.source), " \t\r\n");
        if (self.getTypeAlias(exact)) |type_idx| return type_idx;
        if (try self.resolveParsedGenericParam(owner, exact)) |type_idx| return type_idx;
        try type_syntax_lowering.lowerOwnedRange(
            self.allocator,
            store,
            self.pool,
            lowered,
            application_bases,
            node_range,
        );
        return self.finishParsedGenericRoot(
            owner,
            exact,
            try type_syntax_lowering.loweredChild(lowered, root, lowered.len),
        );
    }

    fn replayDirectSignatureEvent(
        self: *TypeEnv,
        view: IrView,
        signature: *const TypeSyntax.FunctionSignature,
        compatibility_order: *DirectCompatibilityOrder,
        accumulators: *DirectFunctionAccumulators,
        observer: ?DirectReplayObserver,
    ) !*DirectFunctionAccumulator {
        const compatibility_key = view.signatureOffset(signature.owner) orelse
            return error.InvalidFunctionSignatureOwner;
        if (observer) |active| {
            observeDirectReplay(
                active,
                .before,
                compatibility_key,
                signature.owner,
                compatibility_order.contains(compatibility_key),
                compatibility_order,
                accumulators,
            );
        }
        const compatibility = try compatibility_order.getOrPut(self.allocator, compatibility_key);
        if (!compatibility.found_existing) {
            compatibility.value_ptr.* = signature.owner;
        } else if (compatibility.value_ptr.* != signature.owner) {
            return error.InvalidFunctionSignatureOwner;
        }
        self.direct_accumulator_events += 1;

        const accumulator = try accumulators.getOrPut(self.allocator, signature.owner);
        if (!accumulator.found_existing) accumulator.value_ptr.* = .{};
        if (observer) |active| {
            observeDirectReplay(
                active,
                .after,
                compatibility_key,
                signature.owner,
                compatibility.found_existing,
                compatibility_order,
                accumulators,
            );
        }
        return accumulator.value_ptr;
    }

    fn observeDirectReplay(
        observer: DirectReplayObserver,
        phase: DirectReplayPhase,
        compatibility_key: u32,
        owner: NodeIndex,
        compatibility_found_existing: bool,
        compatibility_order: *const DirectCompatibilityOrder,
        accumulators: *const DirectFunctionAccumulators,
    ) void {
        observer.observe(.{
            .phase = phase,
            .compatibility_key = compatibility_key,
            .owner = owner,
            .compatibility_found_existing = compatibility_found_existing,
            .compatibility_capacity = compatibility_order.capacity(),
            .compatibility_count = compatibility_order.count(),
            .accumulator_capacity = accumulators.capacity(),
            .accumulator_count = accumulators.count(),
            .compatibility_order = compatibility_order,
            .accumulators = accumulators,
        });
    }

    fn putDirectSourceAnnotation(
        self: *TypeEnv,
        owner: NodeIndex,
        slot: u8,
        spelling: []const u8,
    ) !void {
        const owned = self.internName(spelling);
        try self.ensureHealthy();
        try self.direct_source_fn_annotations.put(self.allocator, .{
            .owner = owner,
            .slot = slot,
        }, owned);
    }

    fn directHeaderEvent(
        store: *const TypeSyntax.Store,
        cursor: *DirectHeaderCursor,
    ) ?DirectHeaderEvent {
        while (cursor.signature_index < store.function_signatures.items.len) {
            const signature = &store.function_signatures.items[cursor.signature_index];
            const parameters = store.parameterAnnotationSlice(signature.parameters) orelse return null;
            if (cursor.parameter_index < parameters.len) {
                return .{ .parameter = .{
                    .signature = signature,
                    .annotation = &parameters[cursor.parameter_index],
                } };
            }
            if (!cursor.return_consumed) {
                if (signature.return_syntax) |*syntax| {
                    return .{ .return_value = .{ .signature = signature, .syntax = syntax } };
                }
            }
            cursor.signature_index += 1;
            cursor.parameter_index = 0;
            cursor.return_consumed = false;
        }
        return null;
    }

    fn advanceDirectHeaderCursor(cursor: *DirectHeaderCursor, event: DirectHeaderEvent) void {
        switch (event) {
            .parameter => cursor.parameter_index += 1,
            .return_value => cursor.return_consumed = true,
        }
    }

    fn runtimeAtomName(atoms: *AtomTable, value: u16) ?[]const u8 {
        const atom: Atom = @fromBackingInt(@intCast(value));
        if (atom.toPredefinedName()) |name| return name;
        return atoms.getName(atom);
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
        // Check generic scope stack (innermost first)
        if (self.generic_scopes.items.len > 0) {
            var i = self.generic_scopes.items.len;
            while (i > 0) {
                i -= 1;
                if (self.generic_scopes.items[i].resolve(trimmed)) |idx| return idx;
            }
        }
        // Fall back to type expression parser
        const parsed = type_syntax_lowering.parseTypeText(self.pool, self.allocator, trimmed);

        // If the parser produced a generic application (e.g. Result<string>),
        // try to instantiate it against a known generic alias.
        return self.tryInstantiateGenericApp(parsed);
    }

    /// Apply the existing post-parse projection to one complete syntax root.
    /// Callers must perform exact whole-root alias lookup before this operation.
    pub fn finishParsedTypeRoot(self: *TypeEnv, idx: TypeIndex) TypeIndex {
        return self.tryInstantiateGenericApp(idx);
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
    /// application nested inside `Proof<Response, ...>` or
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
                    // `structural K = "id" | "name"; Pick<User, K>` sees the literal
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

    /// True when `name` is an alias whose own definition cycles back to it
    /// without passing through a data constructor (spec 5.7).
    pub fn isNonContractiveAlias(self: *const TypeEnv, name: []const u8) bool {
        return self.non_contractive_aliases.contains(name);
    }

    /// The alias name a non-contractive type came from, so the diagnostic can
    /// name what the author wrote rather than the shape it resolved to.
    pub fn nameOfNonContractive(self: *const TypeEnv, idx: TypeIndex) ?[]const u8 {
        var it = self.type_aliases.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.* != idx) continue;
            if (self.non_contractive_aliases.contains(entry.key_ptr.*)) return entry.key_ptr.*;
        }
        return null;
    }

    /// True when `idx` is what a non-contractive alias name resolves to, or is
    /// still the unresolved name itself.
    pub fn isNonContractiveType(self: *const TypeEnv, idx: TypeIndex) bool {
        if (idx == null_type_idx) return false;
        if (self.non_contractive_indices.contains(idx)) return true;
        if (self.pool.getTag(idx) != .t_ref) return false;
        const name = self.pool.getRefName(idx);
        return name.len > 0 and self.isNonContractiveAlias(name);
    }

    /// Spec 5.7: a recursive alias is contractive when every cycle passes
    /// through a record, tuple, or array constructor - `Dict` joins that list
    /// in phase 4. Union and intersection edges do not guard recursion, so
    /// `structural Loop = Loop`, `structural U = number | U`, and a cycle through a
    /// function parameter are all errors rather than infinite types.
    ///
    /// Decided per alias by walking its body and stopping at the first
    /// guarded constructor. A name reached twice on one unguarded path is the
    /// cycle; the visited set is the same walk's own path, so two aliases that
    /// name a third are not mistaken for a cycle.
    fn findNonContractiveAliases(self: *TypeEnv) void {
        var it = self.type_aliases.iterator();
        while (it.next()) |entry| {
            const name = entry.key_ptr.*;
            var path: [MAX_ALIAS_PATH][]const u8 = undefined;
            path[0] = name;
            if (self.reachesUnguarded(entry.value_ptr.*, path[0..], 1)) {
                self.non_contractive_aliases.put(self.allocator, name, {}) catch self.markAllocationFailure();
                self.non_contractive_indices.put(self.allocator, entry.value_ptr.*, {}) catch self.markAllocationFailure();
            }
        }
    }

    /// Add the current alias census to the retained contractivity maps.
    /// Repeated namespace updates are additive, so this operation clears nothing.
    pub fn finishTypeAliasPopulation(self: *TypeEnv) void {
        self.findNonContractiveAliases();
    }

    const MAX_ALIAS_PATH = 32;

    /// True when `idx` reaches one of the names in `path[0..len]` without
    /// crossing a data constructor.
    fn reachesUnguarded(self: *const TypeEnv, idx: TypeIndex, path: [][]const u8, len: usize) bool {
        if (idx == null_type_idx) return false;
        // Out of path slots. Refusing to answer keeps the walk from claiming
        // contractivity it did not establish; the alias is left alone and the
        // assignability walk's own assumption set still terminates.
        if (len >= path.len) return false;

        switch (self.pool.getTag(idx) orelse return false) {
            // Guarded: a cycle that passes through one of these describes a
            // finite value of increasing depth, which is the whole point.
            .t_record, .t_array, .t_tuple, .t_dict => return false,
            .t_ref => {
                const name = self.pool.getRefName(idx);
                if (name.len == 0) return false;
                for (path[0..len]) |seen| {
                    if (std.mem.eql(u8, seen, name)) return true;
                }
                const next = self.type_aliases.get(name) orelse return false;
                path[len] = name;
                return self.reachesUnguarded(next, path, len + 1);
            },
            .t_union => {
                for (self.pool.getUnionMembers(idx)) |member| {
                    if (self.reachesUnguarded(member, path, len)) return true;
                }
                return false;
            },
            .t_intersection => {
                for (self.pool.getIntersectionMembers(idx)) |member| {
                    if (self.reachesUnguarded(member, path, len)) return true;
                }
                return false;
            },
            .t_nullable => return self.reachesUnguarded(self.pool.getNullableInner(idx), path, len),
            // A function type is not a data constructor. A cycle through a
            // parameter is the negative recursion spec 5.7 names, and one
            // through the return type is no more finite than a bare cycle.
            .t_function => {
                const info = self.pool.getFunctionInfo(idx);
                for (info.params) |param| {
                    if (self.reachesUnguarded(param.type_idx, path, len)) return true;
                }
                return self.reachesUnguarded(info.ret, path, len);
            },
            // exhaustive: every remaining tag is a scalar, a literal, or an
            // opaque capsule. None of them names another type, so none can
            // close a cycle.
            else => return false,
        }
    }

    /// Follow a t_ref through the alias then interface map to its underlying
    /// type, chasing chains (`structural A = B; structural B = {...}` stores A as t_ref(B))
    /// up to a small depth with a self-reference guard. Non-ref types and
    /// unresolved refs pass through unchanged.
    pub fn resolveRef(self: *const TypeEnv, idx: TypeIndex) TypeIndex {
        var cur = idx;
        var depth: u8 = 0;
        while (depth < 8) : (depth += 1) {
            const tag = self.pool.getTag(cur) orelse return cur;
            if (tag != .t_ref) return cur;
            const name = self.pool.getRefName(cur);
            if (name.len == 0) return cur;
            const next = self.type_aliases.get(name) orelse return cur;
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
            // Spec 5.3, the same direction `TypePool.assignableStep` holds:
            // `T | undefined` admits `undefined` and refuses `null`.
            if (source_tag == .t_null) return false;
            if (source_tag == .t_undefined) return true;
            const target_inner = self.pool.getNullableInner(target);
            if (source_tag == .t_nullable) {
                return self.isAssignableTo(self.pool.getNullableInner(source), target_inner);
            }
            // A union source is judged member by member against the whole
            // nullable, so its `undefined` member is admitted. The type of a
            // `match` that may fall through is such a union.
            if (source_tag == .t_union) {
                for (self.pool.getUnionMembers(source)) |member| {
                    if (!self.isAssignableTo(member, target)) return false;
                }
                return true;
            }
            return self.isAssignableTo(source, target_inner);
        }

        if (target_tag == .t_ref and std.mem.eql(u8, self.pool.getRefName(target), "object")) {
            return self.isObjectLike(source, 0);
        }

        return self.pool.isAssignableToWith(source, target, self.refResolver());
    }

    /// The environment's alias table, handed to the pool so a name nested
    /// inside a compound type resolves during the comparison rather than only
    /// at its top level.
    fn refResolver(self: *const TypeEnv) type_pool_mod.TypePool.RefResolver {
        return .{ .ctx = self, .resolve = resolveRefErased };
    }

    fn resolveRefErased(ctx: *const anyopaque, idx: TypeIndex) TypeIndex {
        const self: *const TypeEnv = @ptrCast(@alignCast(ctx));
        return self.resolveRef(idx);
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
                // `structural Foo = string`; aliases present in TypeEnv resolve above.
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
            // exhaustive: other type tags do not meet this object-like check.
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

    pub fn varAnnotationCount(self: *const TypeEnv) usize {
        return if (self.source_selection == .direct) self.direct_annotation_count else 0;
    }

    /// Read one direct annotation through its final declaration owner.
    pub fn getVarTypeForDeclaration(
        self: *const TypeEnv,
        view: IrView,
        declaration: NodeIndex,
    ) ?TypeIndex {
        if (self.source_selection != .direct) return null;
        if (view.getTag(declaration) != .var_decl) return null;
        const retained = self.direct_var_types.get(declaration) orelse return null;
        const runtime = view.getVarDecl(declaration) orelse return null;
        if (!std.meta.eql(runtime.binding, retained.binding)) return null;
        return retained.type_idx;
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
        if (self.source_selection == .omitted) return null;
        return self.source_fn_sigs_by_name.get(name);
    }

    /// Select a source signature through its validated runtime owner.
    pub fn functionTypeRef(
        self: *const TypeEnv,
        view: IrView,
        owner: NodeIndex,
    ) ?FunctionTypeRef {
        if (self.source_selection != .direct) return null;
        const tag = view.getTag(owner) orelse return null;
        if (tag != .function_expr and tag != .arrow_function) return null;
        return .{ .direct_owner = owner };
    }

    pub fn getFunctionSignature(
        self: *const TypeEnv,
        reference: FunctionTypeRef,
    ) ?FunctionSig {
        if (self.source_selection != .direct) return null;
        return self.direct_fn_signatures.get(reference.direct_owner);
    }

    pub fn getFunctionParameterSpelling(
        self: *const TypeEnv,
        reference: FunctionTypeRef,
        compact_position: u8,
    ) ?[]const u8 {
        if (self.source_selection != .direct) return null;
        return self.direct_source_fn_annotations.get(.{
            .owner = reference.direct_owner,
            .slot = compact_position,
        });
    }

    pub fn getFunctionReturnSpelling(
        self: *const TypeEnv,
        reference: FunctionTypeRef,
    ) ?[]const u8 {
        if (self.source_selection != .direct) return null;
        return self.direct_source_fn_annotations.get(.{
            .owner = reference.direct_owner,
            .slot = return_annotation_slot,
        });
    }

    /// Look up a type alias by name.
    pub fn getTypeAlias(self: *const TypeEnv, name: []const u8) ?TypeIndex {
        return self.type_aliases.get(name);
    }

    /// Register a type alias that no source text declares. The runtime's own
    /// globals arrive this way: a handler writes `: Response` and there is no
    /// `structural Response = ...` anywhere to read it from.
    pub fn putTypeAlias(self: *TypeEnv, name: []const u8, type_idx: TypeIndex) void {
        const owned_name = self.internName(name);
        self.type_aliases.put(self.allocator, owned_name, type_idx) catch self.markAllocationFailure();
    }

    /// Refuse consumers that would otherwise interpret allocation-dropped
    /// declarations as declarations the author never wrote.
    pub fn ensureHealthy(self: *const TypeEnv) error{OutOfMemory}!void {
        if (self.allocation_failed) return error.OutOfMemory;
    }

    /// Read actual call arguments. Compatibility owners are not calls.
    pub fn getCallTypeArgsForCall(
        self: *const TypeEnv,
        view: IrView,
        call: NodeIndex,
    ) ?CallTypeArgs {
        if (view.getTag(call) != .call) return null;
        if (self.source_selection != .direct) return null;
        return self.direct_call_type_args.get(call);
    }

    /// Walk a TypeIndex (typically a function return-type annotation),
    /// following intersections and resolving alias references, and append
    /// every declared proof-property name found inside a `Proof<...>` marker
    /// to `out`. Strings live as long as the type pool's name storage;
    /// the caller must not free them. Safe to call when no proof marker is
    /// present (the slice stays empty). Read the returned `non_literal` before
    /// treating an empty slice as "no marker".
    pub fn extractProofMembers(
        self: *const TypeEnv,
        idx: TypeIndex,
        out: *std.ArrayListUnmanaged([]const u8),
    ) std.mem.Allocator.Error!MarkerExtraction {
        if (self.allocation_failed) return error.OutOfMemory;
        var status: MarkerExtraction = .{};
        try self.collectMarkedMembers(idx, out, proof_marker_field, 0, &status);
        return status;
    }

    /// Like `extractProofMembers`, but recovers the capability name strings
    /// inside an `Effects<...>` marker. A return type may carry both an
    /// `Effects<...>` and a `Proof<...>` marker; each extraction
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
    /// `Proof<...>` and `Effects<...>`) from a declared type,
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
                    return std.mem.eql(u8, fname, proof_marker_field) or
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
                // An aliased capability set (`structural Caps = "clock" | "crypto";`
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

    pub fn beginParsedGenerics(
        self: *TypeEnv,
        projected: []const ParsedGenericInput,
    ) !ParsedGenericScope {
        try self.pool.ensureHealthy();
        try self.ensureHealthy();
        const prior_depth = self.generic_scopes.items.len;
        self.pushGenericScope();
        if (self.generic_scopes.items.len != prior_depth + 1) {
            try self.ensureHealthy();
            return error.OutOfMemory;
        }
        var owns_push = true;
        errdefer if (owns_push and self.generic_scopes.items.len == prior_depth + 1) {
            self.popGenericScope();
        };

        const token = self.next_generic_owner_token;
        self.next_generic_owner_token +%= 1;
        if (self.next_generic_owner_token == 0) self.next_generic_owner_token = 1;
        self.generic_scopes.items[prior_depth].owner_token = token;
        var owner: ParsedGenericScope = .{
            .owner_env = self,
            .prior_depth = prior_depth,
            .owner_token = token,
        };
        for (projected[0..@min(projected.len, MAX_TYPE_PARAMS)]) |input| {
            if (input.name.len == 0) continue;
            const owned_name = self.internName(input.name);
            try self.ensureHealthy();
            const index = self.addGenericParam(input.name);
            try self.pool.ensureHealthy();
            owner.params[owner.count] = .{
                .name = owned_name,
                .idx = index,
            };
            owner.count += 1;
        }
        try self.pool.ensureHealthy();
        try self.ensureHealthy();
        owns_push = false;
        return owner;
    }

    pub fn captureParsedGenericSet(
        self: *TypeEnv,
        owner: *const ParsedGenericScope,
    ) !ParsedGenericSet {
        try self.pool.ensureHealthy();
        try self.ensureHealthy();
        _ = try self.validateParsedGenericScope(owner);
        if (owner.count > MAX_TYPE_PARAMS) return error.InvalidParsedGenericOwner;
        return .{
            .owner_env = self,
            .params = owner.params,
            .count = owner.count,
        };
    }

    pub fn beginParsedGenericUse(
        self: *TypeEnv,
        set: *const ParsedGenericSet,
    ) !ParsedGenericScope {
        try self.pool.ensureHealthy();
        try self.ensureHealthy();
        if (set.owner_env != self or set.count > MAX_TYPE_PARAMS) {
            return error.InvalidParsedGenericOwner;
        }

        const prior_depth = self.generic_scopes.items.len;
        self.pushGenericScope();
        if (self.generic_scopes.items.len != prior_depth + 1) {
            try self.ensureHealthy();
            return error.OutOfMemory;
        }
        var owns_push = true;
        errdefer if (owns_push and self.generic_scopes.items.len == prior_depth + 1) {
            self.popGenericScope();
        };

        const token = self.next_generic_owner_token;
        self.next_generic_owner_token +%= 1;
        if (self.next_generic_owner_token == 0) self.next_generic_owner_token = 1;
        self.generic_scopes.items[prior_depth].owner_token = token;
        const owner: ParsedGenericScope = .{
            .owner_env = self,
            .prior_depth = prior_depth,
            .owner_token = token,
            .params = set.params,
            .count = set.count,
        };
        for (set.params[0..set.count]) |parameter| {
            self.generic_scopes.items[prior_depth].addConstrainedParam(
                parameter.name,
                parameter.idx,
                parameter.constraint,
            );
        }
        try self.pool.ensureHealthy();
        try self.ensureHealthy();
        owns_push = false;
        return owner;
    }

    pub fn installParsedConstraints(
        self: *TypeEnv,
        owner: *ParsedGenericScope,
        projected: []const ParsedGenericInput,
    ) !void {
        try self.pool.ensureHealthy();
        try self.ensureHealthy();
        _ = try self.validateParsedGenericScope(owner);
        for (projected, 0..) |input, index| {
            if (index >= owner.count) break;
            const constraint = input.constraint orelse continue;
            owner.params[index].constraint = constraint;
            self.generic_scopes.items[owner.prior_depth].setConstraint(input.name, constraint);
        }
        try self.pool.ensureHealthy();
        try self.ensureHealthy();
    }

    pub fn resolveParsedGenericParam(
        self: *const TypeEnv,
        owner: *const ParsedGenericScope,
        name: []const u8,
    ) !?TypeIndex {
        try self.pool.ensureHealthy();
        try self.ensureHealthy();
        const scope = try self.validateParsedGenericScope(owner);
        return scope.resolve(name);
    }

    pub fn finishParsedGenericRoot(
        self: *TypeEnv,
        owner: *const ParsedGenericScope,
        exact_text: []const u8,
        lowered: TypeIndex,
    ) !TypeIndex {
        try self.pool.ensureHealthy();
        try self.ensureHealthy();
        const scope = try self.validateParsedGenericScope(owner);
        const exact = std.mem.trim(u8, exact_text, " \t\n\r");
        if (self.type_aliases.get(exact)) |index| return index;
        if (scope.resolve(exact)) |index| return index;
        const result = self.finishParsedTypeRoot(lowered);
        try self.pool.ensureHealthy();
        try self.ensureHealthy();
        return result;
    }

    pub fn finishParsedBoundRoot(
        self: *TypeEnv,
        owner: *const ParsedGenericScope,
        exact_text: []const u8,
        lowered: TypeIndex,
    ) !TypeIndex {
        try self.pool.ensureHealthy();
        try self.ensureHealthy();
        const scope = try self.validateParsedGenericScope(owner);
        const exact = std.mem.trim(u8, exact_text, " \t\n\r");
        if (std.mem.eql(u8, exact, "DictKey")) {
            const result = self.pool.addUnion(self.allocator, &.{ self.pool.idx_string, self.pool.idx_number });
            try self.pool.ensureHealthy();
            return result;
        }
        if (self.type_aliases.get(exact)) |index| return index;
        if (scope.resolve(exact)) |index| return index;
        const result = self.finishParsedTypeRoot(lowered);
        try self.pool.ensureHealthy();
        try self.ensureHealthy();
        return result;
    }

    pub fn putParsedGenericAlias(
        self: *TypeEnv,
        name: []const u8,
        owner: *const ParsedGenericScope,
        body: TypeIndex,
    ) !void {
        try self.pool.ensureHealthy();
        try self.ensureHealthy();
        _ = try self.validateParsedGenericScope(owner);
        var alias: GenericAlias = .{ .body = body };
        for (owner.params[0..owner.count], 0..) |parameter, index| {
            alias.param_names[index] = parameter.name;
        }
        alias.param_count = owner.count;
        const owned_name = self.internName(name);
        try self.ensureHealthy();
        {
            errdefer self.markAllocationFailure();
            try self.generic_aliases.put(self.allocator, owned_name, alias);
        }
        try self.pool.ensureHealthy();
        try self.ensureHealthy();
    }

    pub fn endParsedGenerics(self: *TypeEnv, owner: *ParsedGenericScope) !void {
        _ = try self.validateParsedGenericScope(owner);
        self.popGenericScope();
        owner.active = false;
        try self.pool.ensureHealthy();
        try self.ensureHealthy();
    }

    pub fn closeParsedScopeAfterError(
        self: *TypeEnv,
        owner: *ParsedGenericScope,
        original: anyerror,
    ) anyerror {
        const prior_depth = owner.prior_depth;
        const cleanup_result = self.endParsedGenerics(owner);
        if (cleanup_result) |_| {
            if (owner.active or self.generic_scopes.items.len != prior_depth) {
                return error.InvalidParsedGenericOwner;
            }
            return original;
        } else |err| {
            if (owner.active or self.generic_scopes.items.len != prior_depth) {
                return error.InvalidParsedGenericOwner;
            }
            switch (err) {
                error.OutOfMemory, error.TypePoolCapacityExceeded => return original,
                else => return err,
            }
        }
    }

    fn validateParsedGenericScope(
        self: *const TypeEnv,
        owner: *const ParsedGenericScope,
    ) !*const GenericScope {
        if (owner.owner_env != self or !owner.active) return error.InvalidParsedGenericOwner;
        if (self.generic_scopes.items.len != owner.prior_depth + 1) {
            return error.InvalidParsedGenericOwner;
        }
        const scope = &self.generic_scopes.items[owner.prior_depth];
        if (scope.owner_token != owner.owner_token) return error.InvalidParsedGenericOwner;
        return scope;
    }

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

const ParsedGenericApiCase = enum {
    exact_dict_key_bound,
    scope_name_storage,
    original_constraint_index,
    forward_constraint,
    duplicate_constraint_selection,
    compact_capacity,
    empty_name_consumes_capacity,
    null_body_publication,
    cross_environment_owner,
    poisoned_pool_cleanup,
    poisoned_environment_cleanup,
    interned_publication_names,
    repeated_exit_rejected,
};

test "parsed generic API census observes every case" {
    var seen = std.EnumSet(ParsedGenericApiCase).empty;
    inline for (std.meta.tags(ParsedGenericApiCase)) |case| {
        try std.testing.expect(!seen.contains(case));
        switch (case) {
            .cross_environment_owner => {
                var left_pool = TypePool.init(std.testing.allocator);
                defer left_pool.deinit(std.testing.allocator);
                var right_pool = TypePool.init(std.testing.allocator);
                defer right_pool.deinit(std.testing.allocator);
                var left = TypeEnv.init(std.testing.allocator, &left_pool);
                defer left.deinit();
                var right = TypeEnv.init(std.testing.allocator, &right_pool);
                defer right.deinit();
                var left_owner = try left.beginParsedGenerics(&.{.{ .name = "T" }});
                var right_owner = try right.beginParsedGenerics(&.{.{ .name = "T" }});
                try std.testing.expectEqual(left_owner.prior_depth, right_owner.prior_depth);
                try std.testing.expectEqual(left_owner.owner_token, right_owner.owner_token);
                try std.testing.expectError(
                    error.InvalidParsedGenericOwner,
                    right.resolveParsedGenericParam(&left_owner, "T"),
                );
                try left.endParsedGenerics(&left_owner);
                try right.endParsedGenerics(&right_owner);
            },
            else => {
                var pool = TypePool.init(std.testing.allocator);
                defer pool.deinit(std.testing.allocator);
                var env = TypeEnv.init(std.testing.allocator, &pool);
                defer env.deinit();
                switch (case) {
                    .exact_dict_key_bound => {
                        env.putTypeAlias("DictKey", pool.idx_boolean);
                        var owner = try env.beginParsedGenerics(&.{.{ .name = "T" }});
                        const ordinary = try env.finishParsedGenericRoot(&owner, "DictKey", pool.idx_number);
                        try std.testing.expectEqual(pool.idx_boolean, ordinary);
                        const bound = try env.finishParsedBoundRoot(&owner, "DictKey", pool.idx_boolean);
                        try std.testing.expectEqual(type_pool_mod.TypeTag.t_union, pool.getTag(bound).?);
                        try std.testing.expectEqualSlices(
                            TypeIndex,
                            &.{ pool.idx_string, pool.idx_number },
                            pool.getUnionMembers(bound),
                        );
                        const partial_dict_key = pool.addRef(std.testing.allocator, "DictKey");
                        try pool.ensureHealthy();
                        const suffixed = try env.finishParsedBoundRoot(
                            &owner,
                            "DictKey = string",
                            partial_dict_key,
                        );
                        try std.testing.expectEqual(type_pool_mod.TypeTag.t_ref, pool.getTag(suffixed).?);
                        try std.testing.expectEqualStrings("DictKey", pool.getRefName(suffixed));
                        try env.endParsedGenerics(&owner);
                    },
                    .scope_name_storage => {
                        const name32 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
                        const name33 = name32 ++ "b";
                        var owner32 = try env.beginParsedGenerics(&.{.{ .name = name32 }});
                        try std.testing.expect((try env.resolveParsedGenericParam(&owner32, name32)) != null);
                        try env.endParsedGenerics(&owner32);
                        var owner33 = try env.beginParsedGenerics(&.{.{ .name = name33 }});
                        try std.testing.expectEqual(@as(usize, 33), owner33.params[0].name.len);
                        try std.testing.expect((try env.resolveParsedGenericParam(&owner33, name33)) == null);
                        try env.endParsedGenerics(&owner33);
                    },
                    .original_constraint_index => {
                        var owner = try env.beginParsedGenerics(&.{
                            .{ .name = "" },
                            .{ .name = "T" },
                        });
                        try env.installParsedConstraints(&owner, &.{
                            .{ .name = "" },
                            .{ .name = "T", .constraint = pool.idx_number },
                        });
                        try std.testing.expectEqual(@as(u8, 1), owner.count);
                        try std.testing.expectEqual(null_type_idx, owner.params[0].constraint);
                        try env.endParsedGenerics(&owner);
                    },
                    .forward_constraint => {
                        var owner = try env.beginParsedGenerics(&.{
                            .{ .name = "T" },
                            .{ .name = "U" },
                        });
                        try env.installParsedConstraints(&owner, &.{
                            .{ .name = "T", .constraint = owner.params[1].idx },
                            .{ .name = "U" },
                        });
                        try std.testing.expectEqual(owner.params[1].idx, owner.params[0].constraint);
                        try env.endParsedGenerics(&owner);
                    },
                    .duplicate_constraint_selection => {
                        var owner = try env.beginParsedGenerics(&.{
                            .{ .name = "T" },
                            .{ .name = "T" },
                        });
                        try env.installParsedConstraints(&owner, &.{
                            .{ .name = "T", .constraint = pool.idx_string },
                            .{ .name = "T", .constraint = pool.idx_number },
                        });
                        const scope = env.generic_scopes.items[owner.prior_depth];
                        try std.testing.expectEqual(pool.idx_number, owner.params[1].constraint);
                        try std.testing.expectEqual(pool.idx_number, scope.params[0].constraint);
                        try std.testing.expectEqual(null_type_idx, scope.params[1].constraint);
                        try env.endParsedGenerics(&owner);
                    },
                    .compact_capacity => {
                        var owner = try env.beginParsedGenerics(&.{
                            .{ .name = "A" }, .{ .name = "B" }, .{ .name = "C" },
                            .{ .name = "D" }, .{ .name = "E" }, .{ .name = "F" },
                            .{ .name = "G" }, .{ .name = "H" }, .{ .name = "I" },
                        });
                        try std.testing.expectEqual(@as(u8, @intCast(MAX_TYPE_PARAMS)), owner.count);
                        try std.testing.expectEqualStrings("H", owner.params[7].name);
                        try env.endParsedGenerics(&owner);
                    },
                    .empty_name_consumes_capacity => {
                        var owner = try env.beginParsedGenerics(&.{
                            .{ .name = "" },  .{ .name = "A" }, .{ .name = "B" },
                            .{ .name = "C" }, .{ .name = "D" }, .{ .name = "E" },
                            .{ .name = "F" }, .{ .name = "G" }, .{ .name = "H" },
                        });
                        try std.testing.expectEqual(@as(u8, 7), owner.count);
                        try std.testing.expectEqualStrings("G", owner.params[6].name);
                        try std.testing.expect((try env.resolveParsedGenericParam(&owner, "H")) == null);
                        try env.endParsedGenerics(&owner);
                    },
                    .null_body_publication => {
                        var owner = try env.beginParsedGenerics(&.{});
                        try env.putParsedGenericAlias("Empty", &owner, null_type_idx);
                        const alias = env.generic_aliases.get("Empty") orelse return error.TestUnexpectedResult;
                        try std.testing.expectEqual(@as(u8, 0), alias.param_count);
                        try std.testing.expectEqual(null_type_idx, alias.body);
                        try env.endParsedGenerics(&owner);
                    },
                    .poisoned_pool_cleanup => {
                        const prior = env.generic_scopes.items.len;
                        var owner = try env.beginParsedGenerics(&.{.{ .name = "T" }});
                        pool.failure = error.TypePoolCapacityExceeded;
                        try std.testing.expectError(error.TypePoolCapacityExceeded, env.endParsedGenerics(&owner));
                        try std.testing.expectEqual(prior, env.generic_scopes.items.len);
                        try std.testing.expect(!owner.active);
                    },
                    .poisoned_environment_cleanup => {
                        const prior = env.generic_scopes.items.len;
                        var owner = try env.beginParsedGenerics(&.{.{ .name = "T" }});
                        env.allocation_failed = true;
                        try std.testing.expectError(error.OutOfMemory, env.endParsedGenerics(&owner));
                        try std.testing.expectEqual(prior, env.generic_scopes.items.len);
                        try std.testing.expect(!owner.active);
                    },
                    .interned_publication_names => {
                        const param_source = try std.testing.allocator.dupe(u8, "OwnedParameter");
                        const alias_source = try std.testing.allocator.dupe(u8, "OwnedAlias");
                        var owner = try env.beginParsedGenerics(&.{.{ .name = param_source }});
                        try env.putParsedGenericAlias(alias_source, &owner, owner.params[0].idx);
                        try env.endParsedGenerics(&owner);
                        std.testing.allocator.free(param_source);
                        std.testing.allocator.free(alias_source);
                        const alias = env.generic_aliases.get("OwnedAlias") orelse return error.TestUnexpectedResult;
                        try std.testing.expectEqualStrings("OwnedParameter", alias.param_names[0]);
                    },
                    .repeated_exit_rejected => {
                        var owner = try env.beginParsedGenerics(&.{.{ .name = "T" }});
                        try env.endParsedGenerics(&owner);
                        try std.testing.expectError(
                            error.InvalidParsedGenericOwner,
                            env.endParsedGenerics(&owner),
                        );
                    },
                    .cross_environment_owner => unreachable,
                }
            },
        }
        seen.insert(case);
    }
    try std.testing.expectEqual(@typeInfo(ParsedGenericApiCase).@"enum".field_names.len, seen.count());
}

test "direct call arguments retain eight entries under allocation failure" {
    const allocator = std.testing.allocator;
    const source = "const value = pick<string, number, boolean, null, Bytes, undefined, never, unknown, string>();";
    var frontend: engine.source_frontend.DirectCheckSource = undefined;
    try frontend.initCompileInPlace(allocator, allocator, source, "arguments.ts");
    defer frontend.deinit();
    const accepted = frontend.acceptedCapabilities() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 1), accepted.type_store.explicit_call_arguments.items.len);
    const call = accepted.type_store.explicit_call_arguments.items[0].owner;
    try std.testing.expectEqual(engine.parser.NodeTag.call, accepted.ir_view.getTag(call).?);
    const Context = struct {
        fn run(failing: std.mem.Allocator, input: DirectSyntaxInput, owner: NodeIndex, successes: *usize) !void {
            var pool = TypePool.init(failing);
            defer pool.deinit(failing);
            var env = TypeEnv.init(failing, &pool);
            defer env.deinit();
            try pool.ensureHealthy();
            try env.ensureHealthy();
            try env.populateSourceTypes(.{ .direct = input });
            const arguments = env.getCallTypeArgsForCall(input.ir_view, owner) orelse return error.TestUnexpectedResult;
            try std.testing.expectEqual(@as(u8, 8), arguments.count);
            try std.testing.expectEqualSlices(TypeIndex, &.{
                pool.idx_string, pool.idx_number,    pool.idx_boolean, pool.idx_null,
                pool.idx_bytes,  pool.idx_undefined, pool.idx_never,   pool.idx_unknown,
            }, arguments.args[0..arguments.count]);
            successes.* += 1;
        }
    };
    var successes: usize = 0;
    try std.testing.checkAllAllocationFailures(allocator, Context.run, .{
        DirectSyntaxInput{ .store = accepted.type_store, .ir_view = accepted.ir_view, .atoms = accepted.atoms },
        call,
        &successes,
    });
    try std.testing.expect(successes > 0);
}

test "captured generic set supports repeated scope use without semantic allocation" {
    const allocator = std.testing.allocator;
    var pool = TypePool.init(allocator);
    defer pool.deinit(allocator);
    var env = TypeEnv.init(allocator, &pool);
    defer env.deinit();

    var owner = try env.beginParsedGenerics(&.{.{ .name = "T" }});
    try env.installParsedConstraints(&owner, &.{.{
        .name = "T",
        .constraint = pool.idx_string,
    }});
    const generic_index = owner.params[0].idx;
    const capture_node_count = pool.nodes.items.len;
    const capture_name_count = env.name_storage.items.len;
    const capture_depth = env.generic_scopes.items.len;
    const set = try env.captureParsedGenericSet(&owner);
    try std.testing.expectEqual(capture_node_count, pool.nodes.items.len);
    try std.testing.expectEqual(capture_name_count, env.name_storage.items.len);
    try std.testing.expectEqual(capture_depth, env.generic_scopes.items.len);
    try env.endParsedGenerics(&owner);

    env.putTypeAlias("T", pool.idx_number);
    env.putTypeAlias("DictKey", pool.idx_boolean);
    try env.ensureHealthy();
    const stable_node_count = pool.nodes.items.len;
    const stable_name_count = env.name_storage.items.len;

    var parameter_use = try env.beginParsedGenericUse(&set);
    try std.testing.expectEqual(stable_node_count, pool.nodes.items.len);
    try std.testing.expectEqual(stable_name_count, env.name_storage.items.len);
    try std.testing.expectEqual(generic_index, parameter_use.params[0].idx);
    try std.testing.expectEqual(pool.idx_string, parameter_use.params[0].constraint);
    try std.testing.expectEqual(
        generic_index,
        (try env.resolveParsedGenericParam(&parameter_use, "T")).?,
    );
    try std.testing.expectEqual(
        pool.idx_number,
        try env.finishParsedGenericRoot(&parameter_use, "T", generic_index),
    );
    try env.endParsedGenerics(&parameter_use);
    try std.testing.expectEqual(stable_node_count, pool.nodes.items.len);
    try std.testing.expectEqual(stable_name_count, env.name_storage.items.len);

    var return_use = try env.beginParsedGenericUse(&set);
    try std.testing.expectEqual(stable_node_count, pool.nodes.items.len);
    try std.testing.expectEqual(stable_name_count, env.name_storage.items.len);
    try std.testing.expectEqual(generic_index, return_use.params[0].idx);
    try std.testing.expectEqual(pool.idx_string, return_use.params[0].constraint);
    const bound = try env.finishParsedBoundRoot(&return_use, "DictKey", generic_index);
    try std.testing.expectEqual(type_pool_mod.TypeTag.t_union, pool.getTag(bound).?);
    try std.testing.expectEqualSlices(
        TypeIndex,
        &.{ pool.idx_string, pool.idx_number },
        pool.getUnionMembers(bound),
    );
    try env.endParsedGenerics(&return_use);
    try std.testing.expectEqual(stable_name_count, env.name_storage.items.len);
}

test "captured generic set rejects invalid owners and environments before mutation" {
    const allocator = std.testing.allocator;
    var left_pool = TypePool.init(allocator);
    defer left_pool.deinit(allocator);
    var right_pool = TypePool.init(allocator);
    defer right_pool.deinit(allocator);
    var left = TypeEnv.init(allocator, &left_pool);
    defer left.deinit();
    var right = TypeEnv.init(allocator, &right_pool);
    defer right.deinit();

    var owner = try left.beginParsedGenerics(&.{.{ .name = "T" }});
    const set = try left.captureParsedGenericSet(&owner);
    const left_depth = left.generic_scopes.items.len;
    const left_nodes = left_pool.nodes.items.len;
    const left_names = left.name_storage.items.len;
    const right_depth = right.generic_scopes.items.len;
    const right_nodes = right_pool.nodes.items.len;
    const right_names = right.name_storage.items.len;

    try std.testing.expectError(
        error.InvalidParsedGenericOwner,
        right.captureParsedGenericSet(&owner),
    );
    try std.testing.expectError(
        error.InvalidParsedGenericOwner,
        right.beginParsedGenericUse(&set),
    );
    var invalid_count = set;
    invalid_count.count = MAX_TYPE_PARAMS + 1;
    try std.testing.expectError(
        error.InvalidParsedGenericOwner,
        left.beginParsedGenericUse(&invalid_count),
    );
    const valid_count = owner.count;
    owner.count = MAX_TYPE_PARAMS + 1;
    try std.testing.expectError(
        error.InvalidParsedGenericOwner,
        left.captureParsedGenericSet(&owner),
    );
    owner.count = valid_count;

    try std.testing.expectEqual(left_depth, left.generic_scopes.items.len);
    try std.testing.expectEqual(left_nodes, left_pool.nodes.items.len);
    try std.testing.expectEqual(left_names, left.name_storage.items.len);
    try std.testing.expectEqual(right_depth, right.generic_scopes.items.len);
    try std.testing.expectEqual(right_nodes, right_pool.nodes.items.len);
    try std.testing.expectEqual(right_names, right.name_storage.items.len);
    try left.ensureHealthy();
    try right.ensureHealthy();
    try left_pool.ensureHealthy();
    try right_pool.ensureHealthy();

    try left.endParsedGenerics(&owner);
    try std.testing.expectError(
        error.InvalidParsedGenericOwner,
        left.captureParsedGenericSet(&owner),
    );
}

test "captured generic set preserves duplicate and long-name lookup behavior" {
    const allocator = std.testing.allocator;
    var pool = TypePool.init(allocator);
    defer pool.deinit(allocator);
    var env = TypeEnv.init(allocator, &pool);
    defer env.deinit();

    const name32 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    const name33 = name32 ++ "b";
    var owner = try env.beginParsedGenerics(&.{
        .{ .name = "T" },
        .{ .name = "T" },
        .{ .name = name33 },
    });
    try env.installParsedConstraints(&owner, &.{
        .{ .name = "T", .constraint = pool.idx_string },
        .{ .name = "T", .constraint = pool.idx_number },
        .{ .name = name33, .constraint = pool.idx_boolean },
    });
    const set = try env.captureParsedGenericSet(&owner);
    try env.endParsedGenerics(&owner);

    try std.testing.expectEqual(@as(u8, 3), set.count);
    try std.testing.expectEqualStrings("T", set.params[0].name);
    try std.testing.expectEqualStrings("T", set.params[1].name);
    try std.testing.expectEqualStrings(name33, set.params[2].name);
    try std.testing.expect(set.params[0].idx != set.params[1].idx);
    try std.testing.expect(set.params[1].idx != set.params[2].idx);
    try std.testing.expectEqual(pool.idx_string, set.params[0].constraint);
    try std.testing.expectEqual(pool.idx_number, set.params[1].constraint);
    try std.testing.expectEqual(pool.idx_boolean, set.params[2].constraint);

    const stable_node_count = pool.nodes.items.len;
    const stable_name_count = env.name_storage.items.len;
    const stable_depth = env.generic_scopes.items.len;
    var use = try env.beginParsedGenericUse(&set);
    try std.testing.expectEqual(stable_node_count, pool.nodes.items.len);
    try std.testing.expectEqual(stable_name_count, env.name_storage.items.len);
    try std.testing.expectEqual(set.params[0].idx, (try env.resolveParsedGenericParam(&use, "T")).?);
    try std.testing.expect((try env.resolveParsedGenericParam(&use, name33)) == null);
    const active_scope = env.generic_scopes.items[use.prior_depth];
    try std.testing.expectEqual(pool.idx_string, active_scope.params[0].constraint);
    try std.testing.expectEqual(pool.idx_number, active_scope.params[1].constraint);
    try std.testing.expectEqual(pool.idx_boolean, active_scope.params[2].constraint);
    try std.testing.expectEqualStrings(name33, use.params[2].name);
    try std.testing.expectEqual(pool.idx_boolean, use.params[2].constraint);
    try env.endParsedGenerics(&use);
    try std.testing.expectEqual(stable_depth, env.generic_scopes.items.len);
    try std.testing.expectEqual(stable_node_count, pool.nodes.items.len);
    try std.testing.expectEqual(stable_name_count, env.name_storage.items.len);
}

test "captured generic use preserves allocation failure and poisoned exit cleanup" {
    const allocator = std.testing.allocator;
    {
        var failing = std.testing.FailingAllocator.init(allocator, .{});
        const injected = failing.allocator();
        var pool = TypePool.init(injected);
        defer pool.deinit(injected);
        var env = TypeEnv.init(injected, &pool);
        defer env.deinit();

        var owner = try env.beginParsedGenerics(&.{.{ .name = "T" }});
        const set = try env.captureParsedGenericSet(&owner);
        try env.endParsedGenerics(&owner);

        const scope_capacity = env.generic_scopes.capacity;
        try std.testing.expect(scope_capacity > env.generic_scopes.items.len);
        var active_uses: std.ArrayListUnmanaged(ParsedGenericScope) = .empty;
        defer active_uses.deinit(allocator);
        try active_uses.ensureTotalCapacityPrecise(
            allocator,
            scope_capacity - env.generic_scopes.items.len,
        );
        while (env.generic_scopes.items.len < scope_capacity) {
            active_uses.appendAssumeCapacity(try env.beginParsedGenericUse(&set));
        }

        failing.fail_index = failing.alloc_index;
        failing.resize_fail_index = failing.resize_index;
        const stable_depth = env.generic_scopes.items.len;
        const stable_node_count = pool.nodes.items.len;
        const stable_name_count = env.name_storage.items.len;

        try std.testing.expectError(error.OutOfMemory, env.beginParsedGenericUse(&set));
        try std.testing.expect(failing.has_induced_failure);
        try std.testing.expectEqual(stable_depth, env.generic_scopes.items.len);
        try std.testing.expectEqual(stable_node_count, pool.nodes.items.len);
        try std.testing.expectEqual(stable_name_count, env.name_storage.items.len);
        try std.testing.expectError(error.OutOfMemory, env.ensureHealthy());
        try pool.ensureHealthy();
        while (active_uses.pop()) |active_value| {
            var active = active_value;
            try std.testing.expectError(error.OutOfMemory, env.endParsedGenerics(&active));
            try std.testing.expect(!active.active);
        }
        try std.testing.expectEqual(@as(usize, 0), env.generic_scopes.items.len);
    }
    {
        var pool = TypePool.init(allocator);
        defer pool.deinit(allocator);
        var env = TypeEnv.init(allocator, &pool);
        defer env.deinit();

        var owner = try env.beginParsedGenerics(&.{.{ .name = "T" }});
        const set = try env.captureParsedGenericSet(&owner);
        try env.endParsedGenerics(&owner);
        const stable_depth = env.generic_scopes.items.len;
        const stable_node_count = pool.nodes.items.len;
        const stable_name_count = env.name_storage.items.len;

        var pool_poisoned = try env.beginParsedGenericUse(&set);
        pool.failure = error.TypePoolCapacityExceeded;
        try std.testing.expectError(
            error.TypePoolCapacityExceeded,
            env.endParsedGenerics(&pool_poisoned),
        );
        try std.testing.expect(!pool_poisoned.active);
        try std.testing.expectEqual(stable_depth, env.generic_scopes.items.len);
        pool.failure = null;

        var env_poisoned = try env.beginParsedGenericUse(&set);
        env.markAllocationFailure();
        try std.testing.expectError(error.OutOfMemory, env.endParsedGenerics(&env_poisoned));
        try std.testing.expect(!env_poisoned.active);
        try std.testing.expectEqual(stable_depth, env.generic_scopes.items.len);
        try std.testing.expectEqual(stable_node_count, pool.nodes.items.len);
        try std.testing.expectEqual(stable_name_count, env.name_storage.items.len);
    }
}

test "parsed generic scope entry preserves an outer scope across allocation failures" {
    const Context = struct {
        fn run(injected: std.mem.Allocator) !void {
            var pool = TypePool.init(injected);
            defer pool.deinit(injected);
            var env = TypeEnv.init(injected, &pool);
            defer env.deinit();
            try pool.ensureHealthy();
            try env.ensureHealthy();

            env.generic_scopes.deinit(injected);
            env.generic_scopes = .empty;
            try env.generic_scopes.ensureTotalCapacityPrecise(injected, 1);
            env.generic_scopes.appendAssumeCapacity(.{});
            const prior_depth = env.generic_scopes.items.len;
            var owner = env.beginParsedGenerics(&.{
                .{ .name = "First" },
                .{ .name = "Second" },
            }) catch |err| {
                try std.testing.expectEqual(prior_depth, env.generic_scopes.items.len);
                return err;
            };
            try std.testing.expectEqual(prior_depth + 1, env.generic_scopes.items.len);
            try std.testing.expectEqual(@as(u8, 2), owner.count);
            try env.endParsedGenerics(&owner);
            try std.testing.expectEqual(prior_depth, env.generic_scopes.items.len);
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Context.run, .{});
}

const return_annotation_slot = std.math.maxInt(u8);

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

fn populateTestSource(env: *TypeEnv, source: []const u8) !void {
    var frontend: engine.source_frontend.DirectCheckSource = undefined;
    try frontend.initCompileInPlace(env.allocator, env.allocator, source, "types.ts");
    defer frontend.deinit();
    const accepted = frontend.acceptedCapabilities() orelse return error.TestUnexpectedResult;
    try env.populateSourceTypes(.{ .direct = .{
        .store = accepted.type_store,
        .ir_view = accepted.ir_view,
        .atoms = accepted.atoms,
    } });
}

test "TypeEnv basic type alias resolution" {
    const allocator = std.testing.allocator;
    var pool = TypePool.init(allocator);
    defer pool.deinit(allocator);

    var env = TypeEnv.init(allocator, &pool);
    defer env.deinit();

    // Simulate: structural Config = { port: number }
    const source = "structural Config = { port: number };";
    try populateTestSource(&env, source);

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
    try populateTestSource(&env, source);

    const port_type = env.getVarTypeByName("port");
    try std.testing.expect(port_type != null);
    try std.testing.expectEqual(pool.idx_number, port_type.?);
}

test "TypeEnv keeps null out of an optional type" {
    const allocator = std.testing.allocator;
    var pool = TypePool.init(allocator);
    defer pool.deinit(allocator);

    var env = TypeEnv.init(allocator, &pool);
    defer env.deinit();

    const optional_str = pool.addNullable(allocator, pool.idx_string);
    try std.testing.expect(env.isAssignableTo(pool.idx_undefined, optional_str));
    try std.testing.expect(!env.isAssignableTo(pool.idx_null, optional_str));

    const string_or_null = pool.addUnion(allocator, &.{ pool.idx_string, pool.idx_null });
    try std.testing.expect(env.isAssignableTo(pool.idx_null, string_or_null));
}

test "TypeEnv resolves type aliases in annotations" {
    const allocator = std.testing.allocator;
    var pool = TypePool.init(allocator);
    defer pool.deinit(allocator);

    var env = TypeEnv.init(allocator, &pool);
    defer env.deinit();

    // First: define a type alias
    const source = "structural Status = number;const code: Status = 200;";
    try populateTestSource(&env, source);

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
    try populateTestSource(&env, source);

    const sig = env.getSourceFnSigByName("add");
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

    // Simulate: structural Result<T> = { ok: boolean; value: T; error: string }
    //           const auth: Result<object> = jwtVerify(token, secret);
    const source = "structural Result<T> = { ok: boolean; value: T; error: string };const auth: Result<object> = jwtVerify();";
    try populateTestSource(&env, source);

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

    // Simulate: structural Pair<A, B> = { first: A; second: B }
    //           const p: Pair<string, number> = ...
    const source = "structural Pair<A, B> = { first: A; second: B };const p: Pair<string, number> = x;";
    try populateTestSource(&env, source);

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

    const intersection = parseTypeText(&pool, allocator, "string & number");
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

    // Simulate: structural AB = A & B;
    // Names A and B stay as t_ref inside the intersection (resolveType only
    // substitutes alias names when the entire annotation text matches; nested
    // identifiers in compound expressions remain refs - same behaviour as union).
    const source = "structural AB = A & B;";
    try populateTestSource(&env, source);

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
    try populateTestSource(&env, source);

    const sig = env.getSourceFnSigByName("f");
    try std.testing.expect(sig != null);
    try std.testing.expectEqual(type_pool_mod.TypeTag.t_intersection, pool.getTag(sig.?.return_type).?);
}

test "resolveType Pick<User, keys> keeps only the named fields" {
    const allocator = std.testing.allocator;
    var pool = TypePool.init(allocator);
    defer pool.deinit(allocator);
    var env = TypeEnv.init(allocator, &pool);
    defer env.deinit();

    const user = parseTypeText(&pool, allocator, "{ id: number; name: string; age: number }");
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

    const user = parseTypeText(&pool, allocator, "{ id: number; name: string; age: number }");
    env.type_aliases.put(allocator, env.internName("User"), user) catch unreachable;
    // Keys is a named alias of a string-literal union. The keys argument must
    // be alias-resolved, or collectStringKeys sees a t_ref, finds zero keys,
    // and Pick silently returns the full User - an unsound over-accept. It
    // must resolve to exactly {id, name}.
    const keys = parseTypeText(&pool, allocator, "\"id\" | \"name\"");
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

    // `structural A = B` (forward) stores A as a t_ref(B); B is the record.
    // resolveRefToRecord must chase the chain: returning the t_ref unchanged
    // would make Required<A> a no-op that accepts any record. It must clear `host?`.
    const b = parseTypeText(&pool, allocator, "{ host?: string }");
    env.type_aliases.put(allocator, env.internName("B"), b) catch unreachable;
    const a = parseTypeText(&pool, allocator, "B");
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

    const user = parseTypeText(&pool, allocator, "{ id: number; name: string; age: number }");
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

    const user = parseTypeText(&pool, allocator, "{ id: number; name: string }");
    env.type_aliases.put(allocator, env.internName("User"), user) catch unreachable;

    const partial = env.resolveType("Partial<User>");
    const fields = pool.getRecordFields(partial);
    try std.testing.expectEqual(@as(usize, 2), fields.len);
    try std.testing.expect(fields[0].optional);
    try std.testing.expect(fields[1].optional);

    // An object missing a field is assignable to Partial<User> but not to the
    // original required type - the transform flows into the assignability check.
    const subset = parseTypeText(&pool, allocator, "{ id: number }");
    try std.testing.expect(pool.isAssignableTo(subset, partial));
    try std.testing.expect(!pool.isAssignableTo(subset, user));
}

test "resolveType Required<Conf> clears optional and rejects a missing field" {
    const allocator = std.testing.allocator;
    var pool = TypePool.init(allocator);
    defer pool.deinit(allocator);
    var env = TypeEnv.init(allocator, &pool);
    defer env.deinit();

    const conf = parseTypeText(&pool, allocator, "{ host?: string; port?: number }");
    env.type_aliases.put(allocator, env.internName("Conf"), conf) catch unreachable;

    const req = env.resolveType("Required<Conf>");
    const fields = pool.getRecordFields(req);
    try std.testing.expectEqual(@as(usize, 2), fields.len);
    try std.testing.expect(!fields[0].optional);
    try std.testing.expect(!fields[1].optional);

    const subset = parseTypeText(&pool, allocator, "{ host: string }");
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
    const record = parseTypeText(&pool, allocator, "{ id: number }");
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

test "extractProofMembers walks a generic Proof alias to its literal union" {
    const allocator = std.testing.allocator;
    var pool = TypePool.init(allocator);
    defer pool.deinit(allocator);

    var env = TypeEnv.init(allocator, &pool);
    defer env.deinit();

    // Simulate a source-defined alias around the ambient capsule.
    const source =
        "structural Guardrails<T> = Proof<T, \"idempotent\" | \"deterministic\">;" ++
        "function handler(): Guardrails<Response> { return null; }";
    try populateTestSource(&env, source);

    const sig = env.getSourceFnSigByName("handler") orelse return error.MissingSig;

    var names: std.ArrayListUnmanaged([]const u8) = .empty;
    defer names.deinit(allocator);
    _ = try env.extractProofMembers(sig.return_type, &names);

    try std.testing.expectEqual(@as(usize, 2), names.items.len);
    try std.testing.expectEqualStrings("idempotent", names.items[0]);
    try std.testing.expectEqualStrings("deterministic", names.items[1]);
}

test "extractProofMembers handles an inline Proof return capsule" {
    const allocator = std.testing.allocator;
    var pool = TypePool.init(allocator);
    defer pool.deinit(allocator);

    var env = TypeEnv.init(allocator, &pool);
    defer env.deinit();

    const source = "function handler(): Proof<Response, \"idempotent\"> { return null; }";
    try populateTestSource(&env, source);

    const sig = env.getSourceFnSigByName("handler") orelse return error.MissingSig;

    var names: std.ArrayListUnmanaged([]const u8) = .empty;
    defer names.deinit(allocator);
    _ = try env.extractProofMembers(sig.return_type, &names);

    try std.testing.expectEqual(@as(usize, 1), names.items.len);
    try std.testing.expectEqualStrings("idempotent", names.items[0]);
}

test "extractProofMembers returns empty when no Proof marker" {
    const allocator = std.testing.allocator;
    var pool = TypePool.init(allocator);
    defer pool.deinit(allocator);

    var env = TypeEnv.init(allocator, &pool);
    defer env.deinit();

    const source = "function handler(): Response { return null; }";
    try populateTestSource(&env, source);

    const sig = env.getSourceFnSigByName("handler") orelse return error.MissingSig;

    var names: std.ArrayListUnmanaged([]const u8) = .empty;
    defer names.deinit(allocator);
    _ = try env.extractProofMembers(sig.return_type, &names);

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

    // Body is an intersection: the underlying T plus the proof marker record.
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
    _ = try env.extractProofMembers(idx, &names);

    try std.testing.expectEqual(@as(usize, 2), names.items.len);
    try std.testing.expectEqualStrings("total", names.items[0]);
    try std.testing.expectEqualStrings("pure", names.items[1]);
}

test "extractProofMembers handles inline return type Proof<T, \"name\">" {
    const allocator = std.testing.allocator;
    var pool = TypePool.init(allocator);
    defer pool.deinit(allocator);

    var env = TypeEnv.init(allocator, &pool);
    defer env.deinit();

    // function load(): Proof<string, "read_only"> { ... }
    const source = "function load(): Proof<string, \"read_only\"> { return \"\"; }";
    try populateTestSource(&env, source);

    const sig = env.getSourceFnSigByName("load") orelse return error.MissingSig;

    var names: std.ArrayListUnmanaged([]const u8) = .empty;
    defer names.deinit(allocator);
    _ = try env.extractProofMembers(sig.return_type, &names);

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

    // The effect marker is distinct from the proof marker: an Effects<...>
    // type carries no Proof members.
    var specs: std.ArrayListUnmanaged([]const u8) = .empty;
    defer specs.deinit(allocator);
    _ = try env.extractProofMembers(idx, &specs);
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
    _ = try env.extractProofMembers(idx, &specs);
    try std.testing.expectEqual(@as(usize, 1), specs.items.len);
    try std.testing.expectEqualStrings("pure", specs.items[0]);
}

test "TypeEnv leading-pipe union literal" {
    const allocator = std.testing.allocator;
    var pool = TypePool.init(allocator);
    defer pool.deinit(allocator);

    var env = TypeEnv.init(allocator, &pool);
    defer env.deinit();

    // structural Names = | "a" | "b" | "c"
    const source = "structural Names = | \"a\" | \"b\" | \"c\";";
    try populateTestSource(&env, source);

    const names_idx = env.getTypeAlias("Names");
    try std.testing.expect(names_idx != null);
    try std.testing.expectEqual(type_pool_mod.TypeTag.t_union, pool.getTag(names_idx.?).?);
    try std.testing.expectEqual(@as(usize, 3), pool.getUnionMembers(names_idx.?).len);
}

test "a generic alias instantiates through direct syntax" {
    // Parse the source and populate the environment through the same direct
    // path used by consumers, including the generic declaration and use.
    const allocator = std.testing.allocator;
    const source = "structural Box<V> = { v: V };\nconst b: Box<string> = { v: \"x\" };\n";

    var pool = TypePool.init(allocator);
    defer pool.deinit(allocator);
    var env = TypeEnv.init(allocator, &pool);
    defer env.deinit();
    try populateTestSource(&env, source);

    const box = env.resolveType("Box<string>");
    try std.testing.expectEqual(type_pool_mod.TypeTag.t_record, pool.getTag(box).?);
    const fields = pool.getRecordFields(box);
    try std.testing.expectEqual(@as(usize, 1), fields.len);
    try std.testing.expectEqual(pool.idx_string, fields[0].type_idx);
}

test "direct generic signatures preserve nested bounds and identifier names" {
    const allocator = std.testing.allocator;
    const source =
        "function comma<T, U extends Record<string, number>>(a: T, b: U): T { return a; }\n" ++
        "function named<Textends>(a: Textends): Textends { return a; }\n" ++
        "function arrow<T extends (s: string) => number, U>(a: T, b: U): T { return a; }\n";
    var pool = TypePool.init(allocator);
    defer pool.deinit(allocator);
    var env = TypeEnv.init(allocator, &pool);
    defer env.deinit();
    try populateTestSource(&env, source);
    try std.testing.expectEqual(@as(usize, 3), env.direct_fn_signatures.count());

    const cases = [_]struct { function_name: []const u8, parameter_names: []const []const u8 }{
        .{ .function_name = "comma", .parameter_names = &.{ "T", "U" } },
        .{ .function_name = "named", .parameter_names = &.{"Textends"} },
        .{ .function_name = "arrow", .parameter_names = &.{ "T", "U" } },
    };
    for (cases) |case| {
        const signature = env.getSourceFnSigByName(case.function_name) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqual(case.parameter_names.len, signature.type_param_count);
        try std.testing.expectEqual(case.parameter_names.len, signature.param_count);
        for (case.parameter_names, 0..) |name, index| {
            try std.testing.expectEqualStrings(name, signature.type_params[index].name);
            try std.testing.expectEqual(type_pool_mod.TypeTag.t_generic_param, pool.getTag(signature.type_params[index].idx).?);
            try std.testing.expectEqual(signature.type_params[index].idx, signature.param_types[index]);
        }
        try std.testing.expectEqual(signature.type_params[0].idx, signature.return_type);
    }

    const comma = env.getSourceFnSigByName("comma").?;
    try std.testing.expectEqual(null_type_idx, comma.type_params[0].constraint);
    try std.testing.expectEqual(type_pool_mod.TypeTag.t_generic_app, pool.getTag(comma.type_params[1].constraint).?);
    const record = pool.getGenericAppInfo(comma.type_params[1].constraint);
    try std.testing.expectEqual(type_pool_mod.TypeTag.t_ref, pool.getTag(record.base).?);
    try std.testing.expectEqualStrings("Record", pool.getRefName(record.base));
    try std.testing.expectEqualSlices(TypeIndex, &.{ pool.idx_string, pool.idx_number }, record.args);

    const named = env.getSourceFnSigByName("named").?;
    try std.testing.expectEqual(null_type_idx, named.type_params[0].constraint);

    const arrow = env.getSourceFnSigByName("arrow").?;
    try std.testing.expectEqual(null_type_idx, arrow.type_params[1].constraint);
    try std.testing.expectEqual(type_pool_mod.TypeTag.t_function, pool.getTag(arrow.type_params[0].constraint).?);
    const bound = pool.getFunctionInfo(arrow.type_params[0].constraint);
    try std.testing.expectEqual(@as(usize, 1), bound.params.len);
    try std.testing.expectEqualStrings("s", pool.getName(bound.params[0].name_start, bound.params[0].name_len));
    try std.testing.expectEqual(pool.idx_string, bound.params[0].type_idx);
    try std.testing.expect(!bound.params[0].optional);
    try std.testing.expectEqual(pool.idx_number, bound.ret);
}

test "a type-parameter list wrapped across lines still reaches its signature" {
    // The list and annotations span several lines. They must attach to the
    // same function owner so the signature keeps its type parameters.
    const allocator = std.testing.allocator;
    const source = "function pick<\n  T,\n  U extends { id: string }\n>(a: T, b: U): T {\n  return a;\n}\n";

    var pool = TypePool.init(allocator);
    defer pool.deinit(allocator);
    var env = TypeEnv.init(allocator, &pool);
    defer env.deinit();
    try populateTestSource(&env, source);

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
    const source = "function make<T>(n: number): T {\n  return hole();\n}\nconst v = make<Record<string, number>>(1);\n";

    var pool = TypePool.init(allocator);
    defer pool.deinit(allocator);
    var env = TypeEnv.init(allocator, &pool);
    defer env.deinit();
    try populateTestSource(&env, source);

    var it = env.direct_call_type_args.iterator();
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
    const source = "structural Items = string[];\nconst f: readonly Items = [\"a\"];\n";

    var pool = TypePool.init(allocator);
    defer pool.deinit(allocator);
    var env = TypeEnv.init(allocator, &pool);
    defer env.deinit();
    try populateTestSource(&env, source);

    const resolved = env.resolveType("readonly Items");
    try std.testing.expectEqual(type_pool_mod.TypeTag.t_array, pool.getTag(resolved).?);
    try std.testing.expect(pool.isReadonlyArray(resolved));
    // The control: without the modifier the same alias stays mutable.
    try std.testing.expect(!pool.isReadonlyArray(env.resolveType("Items")));
}

test "functions on one line and nested functions of one name keep separate signatures" {
    const allocator = std.testing.allocator;
    const source = "function a(x: number): number { function h(p: number): number { return p; } return h(x); }\n" ++
        "function b(): number { function h(p: number, q: number): number { return p + q; } return h(1, 2); }\n";
    var frontend: engine.source_frontend.DirectCheckSource = undefined;
    try frontend.initCompileInPlace(allocator, allocator, source, "owners.ts");
    defer frontend.deinit();
    const accepted = frontend.acceptedCapabilities() orelse return error.TestUnexpectedResult;
    const parser = &frontend.parser;

    var pool = TypePool.init(allocator);
    defer pool.deinit(allocator);
    var env = TypeEnv.init(allocator, &pool);
    defer env.deinit();
    try env.populateSourceTypes(.{ .direct = .{
        .store = accepted.type_store,
        .ir_view = accepted.ir_view,
        .atoms = accepted.atoms,
    } });

    // Every function node finds its own signature: `a` and its `h` share a
    // line, and the two `h` share a name.
    var counts: [8]u8 = undefined;
    var seen: usize = 0;
    for (parser.nodes.tags.items, 0..) |tag, idx| {
        if (tag != .function_expr) continue;
        const reference = env.functionTypeRef(accepted.ir_view, @intCast(idx)) orelse return error.TestUnexpectedResult;
        const sig = env.getFunctionSignature(reference) orelse return error.TestUnexpectedResult;
        counts[seen] = sig.param_count;
        seen += 1;
    }
    try std.testing.expectEqual(@as(usize, 4), seen);
    // Parse order is inner-first: a's h, a, b's h, b.
    try std.testing.expectEqualSlices(u8, &.{ 1, 1, 2, 0 }, counts[0..seen]);
}

const GrowthCountingAllocator = struct {
    backing: std.mem.Allocator,
    alloc_calls: usize = 0,
    resize_calls: usize = 0,
    remap_calls: usize = 0,
    free_calls: usize = 0,
    live_bytes: usize = 0,

    fn init(backing: std.mem.Allocator) GrowthCountingAllocator {
        return .{ .backing = backing };
    }

    fn allocator(self: *GrowthCountingAllocator) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = countAlloc,
                // In-place growth depends on SafeAllocator's preceding allocations.
                .resize = std.mem.Allocator.noResize,
                .remap = std.mem.Allocator.noRemap,
                .free = countFree,
            },
        };
    }

    /// Successful allocations, resizes, remaps, frees, and remaining bytes.
    fn shape(self: GrowthCountingAllocator) [5]usize {
        return .{ self.alloc_calls, self.resize_calls, self.remap_calls, self.free_calls, self.live_bytes };
    }

    fn countAlloc(context: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *GrowthCountingAllocator = @ptrCast(@alignCast(context));
        const result = self.backing.rawAlloc(len, alignment, ra) orelse return null;
        self.alloc_calls += 1;
        self.live_bytes += len;
        return result;
    }

    fn countFree(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ra: usize) void {
        const self: *GrowthCountingAllocator = @ptrCast(@alignCast(context));
        self.free_calls += 1;
        self.live_bytes -= memory.len;
        self.backing.rawFree(memory, alignment, ra);
    }
};

fn growthParserView(parser: *const engine.parser.JsParser) IrView {
    return IrView.fromIRStore(&parser.nodes, &parser.constants);
}

fn growthExpectRuntime(parser: *const engine.parser.JsParser, root: NodeIndex) !void {
    try std.testing.expect(!parser.hasErrors());
    const view = growthParserView(parser);
    try std.testing.expectEqual(engine.parser.NodeTag.program, view.getTag(root).?);
    try parser.type_store.validateRuntimeOwners(std.testing.allocator, view);
}

fn growthExpectExactPool(left: *const TypePool, right: *const TypePool) !void {
    try std.testing.expectEqual(left.nodes.items.len, right.nodes.items.len);
    for (left.nodes.items, right.nodes.items) |a, b| try std.testing.expect(std.meta.eql(a, b));
    try std.testing.expectEqual(left.fields.items.len, right.fields.items.len);
    for (left.fields.items, right.fields.items) |a, b| try std.testing.expect(std.meta.eql(a, b));
    try std.testing.expectEqual(left.params.items.len, right.params.items.len);
    for (left.params.items, right.params.items) |a, b| try std.testing.expect(std.meta.eql(a, b));
    try std.testing.expectEqualSlices(TypeIndex, left.members.items, right.members.items);
    try std.testing.expectEqualSlices(u8, left.names.items, right.names.items);
    try std.testing.expectEqual(left.template_parts.items.len, right.template_parts.items.len);
    for (left.template_parts.items, right.template_parts.items) |a, b| try std.testing.expect(std.meta.eql(a, b));
}

fn growthExpectExactSignature(left: FunctionSig, right: FunctionSig) !void {
    try std.testing.expectEqual(left.param_count, right.param_count);
    try std.testing.expectEqualSlices(
        TypeIndex,
        left.param_types[0..left.param_count],
        right.param_types[0..right.param_count],
    );
    try std.testing.expectEqual(left.required_param_count, right.required_param_count);
    try std.testing.expectEqual(left.max_arg_count, right.max_arg_count);
    try std.testing.expectEqual(left.return_type, right.return_type);
    try std.testing.expectEqual(left.type_param_count, right.type_param_count);
    for (left.type_params[0..left.type_param_count], right.type_params[0..right.type_param_count]) |a, b| {
        try std.testing.expectEqualStrings(a.name, b.name);
        try std.testing.expectEqual(a.idx, b.idx);
        try std.testing.expectEqual(a.constraint, b.constraint);
    }
    try std.testing.expect(std.meta.eql(left.type_predicate, right.type_predicate));
}

const GrowthTraceEvent = struct {
    key: u32 = 0,
    owner: NodeIndex = 0,
    found_existing: bool = false,
    before_capacity: usize = 0,
    before_count: usize = 0,
    after_capacity: usize = 0,
    after_count: usize = 0,
    accumulator_count: usize = 0,
    keys_start: usize = 0,
    keys_count: usize = 0,
};

const GrowthTrace = struct {
    events: []GrowthTraceEvent,
    keys: []u32,
    event_count: usize = 0,
    key_count: usize = 0,
    pending: bool = false,
    invalid: bool = false,
    view: IrView,

    fn observer(self: *GrowthTrace) DirectReplayObserver {
        return .{ .context = self, .visit = visit };
    }

    fn visit(context: *anyopaque, snapshot: DirectReplaySnapshot) void {
        const self: *GrowthTrace = @ptrCast(@alignCast(context));
        if (snapshot.phase == .before) {
            if (self.pending or self.event_count >= self.events.len) {
                self.invalid = true;
                return;
            }
            self.pending = true;
            self.events[self.event_count] = .{
                .key = snapshot.compatibility_key,
                .owner = snapshot.owner,
                .found_existing = snapshot.compatibility_found_existing,
                .before_capacity = snapshot.compatibility_capacity,
                .before_count = snapshot.compatibility_count,
            };
            return;
        }
        if (!self.pending or self.event_count >= self.events.len) {
            self.invalid = true;
            return;
        }
        var event = &self.events[self.event_count];
        if (event.key != snapshot.compatibility_key or event.owner != snapshot.owner or
            event.found_existing != snapshot.compatibility_found_existing)
        {
            self.invalid = true;
        }
        event.after_capacity = snapshot.compatibility_capacity;
        event.after_count = snapshot.compatibility_count;
        event.accumulator_count = snapshot.accumulator_count;
        event.keys_start = self.key_count;
        var compatibility = snapshot.compatibility_order.iterator();
        while (compatibility.next()) |entry| {
            if (self.key_count >= self.keys.len) {
                self.invalid = true;
                break;
            }
            self.keys[self.key_count] = entry.key_ptr.*;
            self.key_count += 1;
            const owner = entry.value_ptr.*;
            if (self.view.signatureOffset(owner) != entry.key_ptr.* or
                !snapshot.accumulators.contains(owner)) self.invalid = true;
        }
        event.keys_count = self.key_count - event.keys_start;
        var accumulators = snapshot.accumulators.iterator();
        while (accumulators.next()) |entry| {
            var claimed = false;
            var owners = snapshot.compatibility_order.valueIterator();
            while (owners.next()) |owner| {
                if (owner.* == entry.key_ptr.*) {
                    claimed = true;
                    break;
                }
            }
            if (!claimed) self.invalid = true;
        }
        if (snapshot.compatibility_count != snapshot.accumulator_count) self.invalid = true;
        self.pending = false;
        self.event_count += 1;
    }
};

fn growthBuildExpectedTrace(
    allocator: std.mem.Allocator,
    event_keys: []const u32,
    events: []GrowthTraceEvent,
    keys: []u32,
) !usize {
    var accumulator: std.AutoHashMapUnmanaged(u32, FunctionSig) = .empty;
    defer accumulator.deinit(allocator);
    var event_count: usize = 0;
    var key_count: usize = 0;
    for (event_keys) |key| {
        if (event_count >= events.len) return error.TestUnexpectedResult;
        const before_capacity = accumulator.capacity();
        const before_count = accumulator.count();
        const gop = try accumulator.getOrPut(allocator, key);
        if (!gop.found_existing) gop.value_ptr.* = .{};
        events[event_count] = .{
            .key = key,
            .found_existing = gop.found_existing,
            .before_capacity = before_capacity,
            .before_count = before_count,
            .after_capacity = accumulator.capacity(),
            .after_count = accumulator.count(),
            .keys_start = key_count,
        };
        var iterator = accumulator.keyIterator();
        while (iterator.next()) |value| {
            if (key_count >= keys.len) return error.TestUnexpectedResult;
            keys[key_count] = value.*;
            key_count += 1;
        }
        events[event_count].keys_count = key_count - events[event_count].keys_start;
        event_count += 1;
    }
    return event_count;
}

fn growthExpectTraceEqual(
    expected_events: []const GrowthTraceEvent,
    expected_keys: []const u32,
    direct: *const GrowthTrace,
) ![2]usize {
    try std.testing.expect(!direct.invalid);
    try std.testing.expect(!direct.pending);
    try std.testing.expectEqual(expected_events.len, direct.event_count);
    var boundaries: [2]usize = undefined;
    var boundary_count: usize = 0;
    var previous_capacity: usize = 0;
    for (expected_events, direct.events[0..direct.event_count], 0..) |expected, actual, index| {
        try std.testing.expectEqual(expected.key, actual.key);
        try std.testing.expectEqual(expected.found_existing, actual.found_existing);
        try std.testing.expectEqual(expected.before_capacity, actual.before_capacity);
        try std.testing.expectEqual(expected.before_count, actual.before_count);
        try std.testing.expectEqual(expected.after_capacity, actual.after_capacity);
        try std.testing.expectEqual(expected.after_count, actual.after_count);
        try std.testing.expectEqual(expected.after_count, actual.accumulator_count);
        try std.testing.expectEqual(expected.keys_count, actual.keys_count);
        try std.testing.expectEqualSlices(
            u32,
            expected_keys[expected.keys_start..][0..expected.keys_count],
            direct.keys[actual.keys_start..][0..actual.keys_count],
        );
        if (previous_capacity != 0 and expected.after_capacity > previous_capacity) {
            try std.testing.expect(expected.found_existing);
            if (boundary_count >= boundaries.len) return error.TestUnexpectedResult;
            boundaries[boundary_count] = index;
            boundary_count += 1;
        }
        previous_capacity = expected.after_capacity;
    }
    try std.testing.expectEqual(boundaries.len, boundary_count);
    return boundaries;
}

fn growthExpectFinalSignatures(
    expected: *const TypeEnv,
    direct: *const TypeEnv,
    direct_view: IrView,
    store: *const TypeSyntax.Store,
) !void {
    try std.testing.expectEqual(expected.direct_fn_signatures.count(), direct.direct_fn_signatures.count());
    for (store.function_signatures.items) |record| {
        const expected_ref = expected.functionTypeRef(direct_view, record.owner) orelse
            return error.TestUnexpectedResult;
        const direct_ref = direct.functionTypeRef(direct_view, record.owner) orelse
            return error.TestUnexpectedResult;
        try growthExpectExactSignature(
            expected.getFunctionSignature(expected_ref) orelse return error.TestUnexpectedResult,
            direct.getFunctionSignature(direct_ref) orelse return error.TestUnexpectedResult,
        );
    }
    try std.testing.expectEqual(expected.fn_sigs_by_name.count(), direct.fn_sigs_by_name.count());
    var fallback_signatures = expected.fn_sigs_by_name.iterator();
    while (fallback_signatures.next()) |entry| {
        try growthExpectExactSignature(
            entry.value_ptr.*,
            direct.fn_sigs_by_name.get(entry.key_ptr.*) orelse return error.TestUnexpectedResult,
        );
    }
    try std.testing.expectEqual(
        expected.source_fn_sigs_by_name.count(),
        direct.source_fn_sigs_by_name.count(),
    );
    var source_signatures = expected.source_fn_sigs_by_name.iterator();
    while (source_signatures.next()) |entry| {
        try growthExpectExactSignature(
            entry.value_ptr.*,
            direct.source_fn_sigs_by_name.get(entry.key_ptr.*) orelse return error.TestUnexpectedResult,
        );
    }
}

const growth_source_plain =
    "function useNumber(value: number): number {\n" ++
    "  inner(value);\n" ++
    "  function inner(item: number): number { return item; }\n" ++
    "  return value;\n" ++
    "}\n" ++
    "function padding0(value: number): number { return value; }\n" ++
    "function padding1(value: number): number { return value; }\n" ++
    "function padding2(value: number): number { return value; }\n" ++
    "function padding3(value: number): number { return value; }\n" ++
    "function padding4(value: number): number { return value; }\n" ++
    "function padding5(value: number): number { return value; }\n" ++
    "function padding6(value: number): number { return value; }\n" ++
    "function padding7(value: number): number { return value; }\n" ++
    "function useText(value: string): string {\n" ++
    "  inner(value, \"\");\n" ++
    "  function inner(item: string, suffix: string): string { return item; }\n" ++
    "  return value;\n" ++
    "}\n" ++
    "export function handler(req: Request): Response {\n" ++
    "  return Response.json({ number: useNumber(1), text: useText(\"x\") });\n" ++
    "}\n";

const growth_source_reordered =
    "function useText(value: string): string {\n" ++
    "  inner(value, \"\");\n" ++
    "  function inner(item: string, suffix: string): string { return item; }\n" ++
    "  return value;\n" ++
    "}\n" ++
    "function padding0(value: number): number { return value; }\n" ++
    "function padding1(value: number): number { return value; }\n" ++
    "function padding2(value: number): number { return value; }\n" ++
    "function padding3(value: number): number { return value; }\n" ++
    "function padding4(value: number): number { return value; }\n" ++
    "function padding5(value: number): number { return value; }\n" ++
    "function padding6(value: number): number { return value; }\n" ++
    "function padding7(value: number): number { return value; }\n" ++
    "function useNumber(value: number): number {\n" ++
    "  inner(value);\n" ++
    "  function inner(item: number): number { return item; }\n" ++
    "  return value;\n" ++
    "}\n" ++
    "export function handler(req: Request): Response {\n" ++
    "  return Response.json({ number: useNumber(1), text: useText(\"x\") });\n" ++
    "}\n";

const growth_source_same_line = "function useNumber(value: number): number {   inner(value);   function inner(item: number): number { return item; }   return value; } function padding0(value: number): number { return value; } function padding1(value: number): number { return value; } function padding2(value: number): number { return value; } function padding3(value: number): number { return value; } function padding4(value: number): number { return value; } function padding5(value: number): number { return value; } function padding6(value: number): number { return value; } function padding7(value: number): number { return value; } function useText(value: string): string {   inner(value, \"\");   function inner(item: string, suffix: string): string { return item; }   return value; } export function handler(req: Request): Response {   return Response.json({ number: useNumber(1), text: useText(\"x\") }); } ";

const GrowthCase = enum { plain, reordered, same_line };

fn growthSource(case: GrowthCase) []const u8 {
    return switch (case) {
        .plain => growth_source_plain,
        .reordered => growth_source_reordered,
        .same_line => growth_source_same_line,
    };
}

// Recorded annotation events, including repeated events for the same signature.
const growth_keys_plain = [_]u32{
    18,  18,  76,  76,  151, 151, 210, 210, 269, 269, 328, 328, 387, 387,
    446, 446, 505, 505, 564, 564, 622, 622, 684, 684, 684, 781, 781,
};
const growth_keys_reordered = [_]u32{
    16,  16,  78,  78,  78,  169, 169, 228, 228, 287, 287, 346, 346, 405,
    405, 464, 464, 523, 523, 582, 582, 642, 642, 700, 700, 781, 781,
};
const growth_keys_same_line = [_]u32{
    18,  18,  76,  76,  151, 151, 210, 210, 269, 269, 328, 328, 387, 387,
    446, 446, 505, 505, 564, 564, 622, 622, 684, 684, 684, 781, 781,
};

fn growthEventKeys(case: GrowthCase) []const u32 {
    return switch (case) {
        .plain => &growth_keys_plain,
        .reordered => &growth_keys_reordered,
        .same_line => &growth_keys_same_line,
    };
}

fn growthSignature(params: []const TypeIndex, return_type: TypeIndex) FunctionSig {
    var signature: FunctionSig = .{ .param_count = @intCast(params.len), .return_type = return_type };
    @memcpy(signature.param_types[0..params.len], params);
    return signature;
}

fn growthExpectTraceSignatures(
    env: *const TypeEnv,
    parser: *const engine.parser.JsParser,
    atoms: *AtomTable,
    case: GrowthCase,
) !void {
    const view = growthParserView(parser);
    const names = [_][]const u8{
        if (case == .reordered) "useText" else "useNumber", "inner",
        "padding0",                                         "padding1",
        "padding2",                                         "padding3",
        "padding4",                                         "padding5",
        "padding6",                                         "padding7",
        if (case == .reordered) "useNumber" else "useText", "inner",
        "handler",
    };
    try std.testing.expectEqual(@as(usize, 13), parser.type_store.function_signatures.items.len);
    try std.testing.expectEqual(@as(usize, 13), env.direct_fn_signatures.count());
    try std.testing.expectEqual(@as(usize, 12), env.fn_sigs_by_name.count());
    try std.testing.expectEqual(@as(usize, 12), env.source_fn_sigs_by_name.count());
    const event_keys = growthEventKeys(case);
    var event_index: usize = 0;
    for (parser.type_store.function_signatures.items, names, 0..) |record, name, index| {
        try std.testing.expectEqual(event_keys[event_index], view.signatureOffset(record.owner).?);
        try std.testing.expectEqual(engine.parser.NodeTag.function_expr, view.getTag(record.owner).?);
        const function = view.getFunction(record.owner) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqualStrings(name, TypeEnv.runtimeAtomName(atoms, function.name_atom).?);
        const reference = env.functionTypeRef(view, record.owner) orelse return error.TestUnexpectedResult;
        const actual = env.getFunctionSignature(reference) orelse return error.TestUnexpectedResult;
        const text_signature = if (case == .reordered) index < 2 else index == 10 or index == 11;
        const param_count: usize = if (text_signature and std.mem.eql(u8, name, "inner")) 2 else 1;
        var parameter_type = if (text_signature) env.pool.idx_string else env.pool.idx_number;
        var return_type = parameter_type;
        if (index == 12) {
            try std.testing.expectEqual(@as(u8, 1), actual.param_count);
            parameter_type = actual.param_types[0];
            return_type = actual.return_type;
            try std.testing.expectEqual(type_pool_mod.TypeTag.t_ref, env.pool.getTag(parameter_type).?);
            try std.testing.expectEqual(type_pool_mod.TypeTag.t_ref, env.pool.getTag(return_type).?);
            try std.testing.expectEqualStrings("Request", env.pool.getRefName(parameter_type));
            try std.testing.expectEqualStrings("Response", env.pool.getRefName(return_type));
        }
        const params = [_]TypeIndex{ parameter_type, parameter_type };
        const expected = growthSignature(params[0..param_count], return_type);
        try growthExpectExactSignature(expected, actual);
        if (!std.mem.eql(u8, name, "inner")) {
            try growthExpectExactSignature(expected, env.getFnSigByName(name).?);
            try growthExpectExactSignature(expected, env.source_fn_sigs_by_name.get(name).?);
        }
        event_index += param_count + 1;
    }
    try std.testing.expectEqual(event_keys.len, event_index);
    const inner = env.getFnSigByName("inner") orelse return error.TestUnexpectedResult;
    try growthExpectExactSignature(growthSignature(&.{env.pool.idx_number}, env.pool.idx_number), inner);
    try growthExpectExactSignature(inner, env.source_fn_sigs_by_name.get("inner").?);
}

fn growthExpectTraceCase(case: GrowthCase) ![2]usize {
    const allocator = std.testing.allocator;
    var direct_count = GrowthCountingAllocator.init(allocator);
    var direct_atoms = AtomTable.init(direct_count.allocator());
    defer direct_atoms.deinit();
    var direct_parser = try engine.parser.JsParser.initAdmission(
        direct_count.allocator(),
        allocator,
        growthSource(case),
        .compile,
    );
    defer direct_parser.deinit();
    direct_parser.setAtomTable(&direct_atoms);
    const direct_root = try direct_parser.parse();
    try growthExpectRuntime(&direct_parser, direct_root);
    const allocation_shape: [5]usize = switch (case) {
        // Parser scratch now retains one allocation through the parser's
        // lifetime. Signature replay's capacity/order assertions below remain
        // independent of this deliberately changed parser allocation shape.
        .plain, .same_line => .{ 55, 0, 0, 10, 15649 },
        .reordered => .{ 55, 0, 0, 10, 15633 },
    };
    try std.testing.expectEqual(allocation_shape, direct_count.shape());
    const direct_view = growthParserView(&direct_parser);

    var direct_pool = TypePool.init(allocator);
    defer direct_pool.deinit(allocator);
    var direct_env = TypeEnv.init(allocator, &direct_pool);
    defer direct_env.deinit();
    try direct_env.populateSourceTypes(.{ .direct = .{
        .store = &direct_parser.type_store,
        .ir_view = direct_view,
        .atoms = &direct_atoms,
    } });
    try growthExpectTraceSignatures(&direct_env, &direct_parser, &direct_atoms, case);

    const max_events = 64;
    const max_keys = max_events * 32;
    const direct_events = try allocator.alloc(GrowthTraceEvent, max_events);
    defer allocator.free(direct_events);
    const direct_keys = try allocator.alloc(u32, max_keys);
    defer allocator.free(direct_keys);
    const expected_events = try allocator.alloc(GrowthTraceEvent, max_events);
    defer allocator.free(expected_events);
    const expected_keys = try allocator.alloc(u32, max_keys);
    defer allocator.free(expected_keys);
    var trace: GrowthTrace = .{
        .events = direct_events,
        .keys = direct_keys,
        .view = direct_view,
    };
    var trace_pool = TypePool.init(allocator);
    defer trace_pool.deinit(allocator);
    var trace_env = TypeEnv.init(allocator, &trace_pool);
    defer trace_env.deinit();
    try trace_env.populateSourceTypesImpl(.{ .direct = .{
        .store = &direct_parser.type_store,
        .ir_view = direct_view,
        .atoms = &direct_atoms,
    } }, trace.observer());
    try growthExpectExactPool(&direct_pool, &trace_pool);
    try growthExpectFinalSignatures(&direct_env, &trace_env, direct_view, &direct_parser.type_store);
    try std.testing.expectEqual(@as(usize, 14), direct_parser.type_store.parameter_annotations.items.len);
    var return_count: usize = 0;
    for (direct_parser.type_store.function_signatures.items) |signature| {
        if (signature.return_syntax != null) return_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 13), return_count);
    const event_keys = growthEventKeys(case);
    try std.testing.expectEqual(@as(usize, 27), event_keys.len);
    const expected_event_count = try growthBuildExpectedTrace(allocator, event_keys, expected_events, expected_keys);
    try std.testing.expectEqual(@as(usize, 27), expected_event_count);
    return growthExpectTraceEqual(expected_events[0..expected_event_count], expected_keys, &trace);
}

test "direct signature replay preserves capacity and bucket order at two growth boundaries" {
    const plain = try growthExpectTraceCase(.plain);
    const reordered = try growthExpectTraceCase(.reordered);
    const same_line = try growthExpectTraceCase(.same_line);
    try std.testing.expectEqual([2]usize{ 11, 23 }, plain);
    try std.testing.expectEqual([2]usize{ 12, 24 }, reordered);
    try std.testing.expectEqual([2]usize{ 11, 23 }, same_line);
}

test "direct signature replay retains exact nested generic arrow and same-line owners" {
    const allocator = std.testing.allocator;
    const source = "function outer<T extends number>(value: T): T { " ++
        "function same(value: number): number { return value; } return value; } " ++
        "function same(value: string): string { return value; } " ++
        "const arrow = <U extends string>(value: U): U => value;";
    var direct_count = GrowthCountingAllocator.init(allocator);
    var direct_atoms = AtomTable.init(direct_count.allocator());
    defer direct_atoms.deinit();
    var direct_parser = try engine.parser.JsParser.initAdmission(direct_count.allocator(), allocator, source, .compile);
    defer direct_parser.deinit();
    direct_parser.setAtomTable(&direct_atoms);
    const direct_root = try direct_parser.parse();
    try growthExpectRuntime(&direct_parser, direct_root);
    try std.testing.expectEqual([5]usize{ 21, 0, 0, 2, 4963 }, direct_count.shape());
    const direct_view = growthParserView(&direct_parser);
    var direct_pool = TypePool.init(allocator);
    defer direct_pool.deinit(allocator);
    var direct_env = TypeEnv.init(allocator, &direct_pool);
    defer direct_env.deinit();
    try direct_env.populateSourceTypes(.{ .direct = .{
        .store = &direct_parser.type_store,
        .ir_view = direct_view,
        .atoms = &direct_atoms,
    } });
    try std.testing.expectEqual(@as(usize, 4), direct_env.direct_fn_signatures.count());
    try std.testing.expectEqual(@as(usize, 2), direct_env.fn_sigs_by_name.count());
    try std.testing.expectEqual(@as(usize, 2), direct_env.source_fn_sigs_by_name.count());
    try std.testing.expectEqual(@as(usize, 4), direct_parser.type_store.function_signatures.items.len);
    var owners: [4]NodeIndex = undefined;
    var repeated_same: [2]NodeIndex = undefined;
    var same_count: usize = 0;
    var arrow_count: usize = 0;
    for (direct_parser.type_store.function_signatures.items, 0..) |record, index| {
        owners[index] = record.owner;
        const expected_offsets = [_]u32{ 32, 61, 132, 206 };
        try std.testing.expectEqual(expected_offsets[index], direct_view.signatureOffset(record.owner).?);
        const reference = direct_env.functionTypeRef(direct_view, record.owner) orelse return error.TestUnexpectedResult;
        const signature = direct_env.getFunctionSignature(reference) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqual(@as(u8, 1), signature.param_count);
        if (index == 1 or index == 2) {
            const expected_type = if (index == 1) direct_pool.idx_number else direct_pool.idx_string;
            try growthExpectExactSignature(growthSignature(&.{expected_type}, expected_type), signature);
        }
        const function = direct_view.getFunction(record.owner) orelse return error.TestUnexpectedResult;
        const name = TypeEnv.runtimeAtomName(&direct_atoms, function.name_atom);
        if (name != null and std.mem.eql(u8, name.?, "same")) {
            if (same_count >= repeated_same.len) return error.TestUnexpectedResult;
            repeated_same[same_count] = record.owner;
            same_count += 1;
        }
        if (direct_view.getTag(record.owner) == .arrow_function) arrow_count += 1;
        try std.testing.expectEqual(@as(u32, 1), direct_view.getLoc(record.owner).?.line);
    }
    try std.testing.expectEqual(@as(usize, 2), same_count);
    try std.testing.expect(repeated_same[0] != repeated_same[1]);
    try std.testing.expectEqual(@as(usize, 1), arrow_count);
    for (owners, 0..) |owner, index| {
        for (owners[index + 1 ..]) |other| {
            try std.testing.expect(owner != other);
        }
    }
    const outer = direct_view.getFunction(owners[0]) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("outer", TypeEnv.runtimeAtomName(&direct_atoms, outer.name_atom).?);
    try std.testing.expectEqual(engine.parser.NodeTag.block, direct_view.getTag(outer.body).?);
    const outer_body = direct_view.getBlock(outer.body) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u16, 2), outer_body.stmts_count);
    const inner_declaration = direct_view.getListIndex(outer_body.stmts_start, 0);
    try std.testing.expectEqual(engine.parser.NodeTag.function_decl, direct_view.getTag(inner_declaration).?);
    const inner_binding = direct_view.getVarDecl(inner_declaration) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(repeated_same[0], inner_binding.init);
    try std.testing.expectEqual(@as(usize, 2), direct_parser.type_store.generic_owners.items.len);
    for (direct_parser.type_store.generic_owners.items) |generic_owner| {
        const owner = switch (generic_owner.identity) {
            .function => |node| node,
            .arrow => |node| node,
            else => return error.TestUnexpectedResult,
        };
        const reference = direct_env.functionTypeRef(direct_view, owner) orelse
            return error.TestUnexpectedResult;
        const signature = direct_env.getFunctionSignature(reference) orelse
            return error.TestUnexpectedResult;
        try std.testing.expectEqual(@as(u8, 1), signature.type_param_count);
        try std.testing.expectEqual(@as(?u8, null), signature.required_param_count);
        try std.testing.expectEqual(@as(?u8, null), signature.max_arg_count);
        try std.testing.expect(signature.type_predicate == null);
        const is_outer = owner == owners[0];
        const expected_name = if (is_outer) "T" else "U";
        try std.testing.expectEqualStrings(expected_name, signature.type_params[0].name);
        try std.testing.expectEqualStrings(expected_name, direct_pool.getRefName(signature.type_params[0].idx));
        try std.testing.expectEqual(type_pool_mod.TypeTag.t_generic_param, direct_pool.getTag(signature.type_params[0].idx).?);
        try std.testing.expectEqual(
            if (is_outer) direct_pool.idx_number else direct_pool.idx_string,
            signature.type_params[0].constraint,
        );
        try std.testing.expect(signature.type_params[0].idx == signature.param_types[0]);
        try std.testing.expect(signature.type_params[0].idx == signature.return_type);
    }
    const same = direct_env.getFnSigByName("same") orelse return error.TestUnexpectedResult;
    try growthExpectExactSignature(growthSignature(&.{direct_pool.idx_string}, direct_pool.idx_string), same);
    try growthExpectExactSignature(same, direct_env.source_fn_sigs_by_name.get("same").?);
    const outer_reference = direct_env.functionTypeRef(direct_view, owners[0]).?;
    try growthExpectExactSignature(direct_env.getFunctionSignature(outer_reference).?, direct_env.getFnSigByName("outer").?);
    try growthExpectExactSignature(direct_env.getFnSigByName("outer").?, direct_env.source_fn_sigs_by_name.get("outer").?);
}

const GrowthSignatureCase = enum { parameter, return_value, guard, arrow, generic_only };

fn growthExpectSignatureKind(
    case: GrowthSignatureCase,
    source: []const u8,
    expected_events: usize,
    expected_signatures: usize,
    expected_names: usize,
) !void {
    const allocator = std.testing.allocator;
    var direct_count = GrowthCountingAllocator.init(allocator);
    var direct_atoms = AtomTable.init(direct_count.allocator());
    defer direct_atoms.deinit();
    var direct_parser = try engine.parser.JsParser.initAdmission(direct_count.allocator(), allocator, source, .compile);
    defer direct_parser.deinit();
    direct_parser.setAtomTable(&direct_atoms);
    const direct_root = try direct_parser.parse();
    try growthExpectRuntime(&direct_parser, direct_root);
    const allocation_shape: [5]usize = switch (case) {
        .parameter, .arrow => .{ 13, 0, 0, 0, 3224 },
        .return_value => .{ 13, 0, 0, 1, 3253 },
        .guard => .{ 14, 0, 0, 1, 3465 },
        .generic_only => .{ 14, 0, 0, 1, 3468 },
    };
    try std.testing.expectEqual(allocation_shape, direct_count.shape());
    const direct_view = growthParserView(&direct_parser);
    var direct_pool = TypePool.init(allocator);
    defer direct_pool.deinit(allocator);
    var direct_env = TypeEnv.init(allocator, &direct_pool);
    defer direct_env.deinit();
    try direct_env.populateSourceTypes(.{ .direct = .{
        .store = &direct_parser.type_store,
        .ir_view = direct_view,
        .atoms = &direct_atoms,
    } });
    try std.testing.expectEqual(expected_events, direct_env.direct_accumulator_events);
    try std.testing.expectEqual(expected_signatures, direct_env.direct_fn_signatures.count());
    try std.testing.expectEqual(expected_names, direct_env.fn_sigs_by_name.count());
    try std.testing.expectEqual(expected_names, direct_env.source_fn_sigs_by_name.count());
    try std.testing.expectEqual(expected_signatures, direct_parser.type_store.function_signatures.items.len);
    if (case == .generic_only) {
        try std.testing.expectEqual(@as(usize, 1), direct_parser.type_store.generic_owners.items.len);
        return;
    }
    var expected = switch (case) {
        .parameter => growthSignature(&.{direct_pool.idx_string}, null_type_idx),
        .return_value => growthSignature(&.{}, direct_pool.idx_string),
        .guard => growthSignature(&.{direct_pool.idx_unknown}, direct_pool.idx_boolean),
        .arrow => growthSignature(&.{direct_pool.idx_string}, direct_pool.idx_string),
        .generic_only => unreachable,
    };
    if (case == .guard) expected.type_predicate = .{ .param_index = 0, .narrowed = direct_pool.idx_string };
    const owner = direct_parser.type_store.function_signatures.items[0].owner;
    const reference = direct_env.functionTypeRef(direct_view, owner) orelse return error.TestUnexpectedResult;
    try growthExpectExactSignature(expected, direct_env.getFunctionSignature(reference).?);
    if (expected_names != 0) {
        const name = if (case == .guard) "guard" else "value";
        try growthExpectExactSignature(expected, direct_env.getFnSigByName(name).?);
        try growthExpectExactSignature(expected, direct_env.source_fn_sigs_by_name.get(name).?);
    }
}

test "direct signature replay covers parameter return guard generic-only and atom-zero cases" {
    try growthExpectSignatureKind(.parameter, "const value = (item: string) => item;", 1, 1, 0);
    try growthExpectSignatureKind(.return_value, "function value(): string { return \"x\"; }", 1, 1, 1);
    try growthExpectSignatureKind(
        .guard,
        "function guard(value: unknown): value is string { return true; }",
        2,
        1,
        1,
    );
    try growthExpectSignatureKind(.arrow, "const value = (item: string): string => item;", 2, 1, 0);
    try growthExpectSignatureKind(.generic_only, "function identity<T>(value) { return value; }", 0, 0, 0);

    const allocator = std.testing.allocator;
    const source = "function named(value: string): string { return value; } " ++
        "const arrow = (value: number): number => value;";
    var atoms = AtomTable.init(allocator);
    defer atoms.deinit();
    var parser = try engine.parser.JsParser.initAdmission(allocator, allocator, source, .compile);
    defer parser.deinit();
    parser.setAtomTable(&atoms);
    _ = try parser.parse();
    const view = growthParserView(&parser);
    var function_owner: ?NodeIndex = null;
    var arrow_owner: ?NodeIndex = null;
    for (parser.type_store.function_signatures.items) |record| switch (view.getTag(record.owner).?) {
        .function_expr => function_owner = record.owner,
        .arrow_function => arrow_owner = record.owner,
        else => return error.TestUnexpectedResult,
    };
    const named_owner = function_owner orelse return error.TestUnexpectedResult;
    const anonymous_owner = arrow_owner orelse return error.TestUnexpectedResult;
    const function_extra = parser.nodes.data.items[@intCast(named_owner)].a;
    parser.nodes.extra.items[@as(usize, function_extra) + 1] = @backingInt(Atom.null);
    try parser.type_store.validateRuntimeOwners(allocator, view);
    try std.testing.expectEqual(@as(u16, 0), view.getFunction(named_owner).?.name_atom);
    try std.testing.expectEqual(@as(u16, 0), view.getFunction(anonymous_owner).?.name_atom);
    var pool = TypePool.init(allocator);
    defer pool.deinit(allocator);
    var env = TypeEnv.init(allocator, &pool);
    defer env.deinit();
    try env.populateSourceTypes(.{ .direct = .{
        .store = &parser.type_store,
        .ir_view = view,
        .atoms = &atoms,
    } });
    try std.testing.expect(env.getFnSigByName("null") != null);
    try std.testing.expectEqual(@as(usize, 1), env.fn_sigs_by_name.count());
    try std.testing.expectEqual(@as(usize, 1), env.source_fn_sigs_by_name.count());
    try std.testing.expect(env.getFnSigByName("named") == null);
    try std.testing.expect(env.source_fn_sigs_by_name.get("named") == null);
    const named_ref = env.functionTypeRef(view, named_owner) orelse return error.TestUnexpectedResult;
    const anonymous_ref = env.functionTypeRef(view, anonymous_owner) orelse return error.TestUnexpectedResult;
    const named_signature = env.getFunctionSignature(named_ref) orelse return error.TestUnexpectedResult;
    const anonymous_signature = env.getFunctionSignature(anonymous_ref) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u8, 1), named_signature.param_count);
    try std.testing.expectEqual(@as(u8, 1), anonymous_signature.param_count);
    try std.testing.expectEqual(pool.idx_string, named_signature.param_types[0]);
    try std.testing.expectEqual(pool.idx_number, anonymous_signature.param_types[0]);
    try std.testing.expectEqual(pool.idx_string, named_signature.return_type);
    try std.testing.expectEqual(pool.idx_number, anonymous_signature.return_type);
    try growthExpectExactSignature(named_signature, env.getFnSigByName("null").?);
    try growthExpectExactSignature(
        named_signature,
        env.source_fn_sigs_by_name.get("null") orelse return error.TestUnexpectedResult,
    );
}

const GrowthFailureObservations = struct {
    validation_failures: usize = 0,
    selected_failures: usize = 0,
    source_annotation_failures: usize = 0,
    publication_failures: usize = 0,
    name_merge_failures: usize = 0,
    successes: usize = 0,
};

const GrowthCompletionObserver = struct {
    completed_events: usize = 0,

    fn observer(self: *GrowthCompletionObserver) DirectReplayObserver {
        return .{ .context = self, .visit = visit };
    }

    fn visit(context: *anyopaque, snapshot: DirectReplaySnapshot) void {
        const self: *GrowthCompletionObserver = @ptrCast(@alignCast(context));
        if (snapshot.phase == .after) self.completed_events += 1;
    }
};

fn growthPublicAllocationSweep(
    allocator: std.mem.Allocator,
    observations: *GrowthFailureObservations,
) !void {
    const source = "function value(item: string): string { return item; }";
    var atoms = AtomTable.init(std.testing.allocator);
    defer atoms.deinit();
    var parser = try engine.parser.JsParser.initAdmission(std.testing.allocator, std.testing.allocator, source, .compile);
    defer parser.deinit();
    parser.setAtomTable(&atoms);
    _ = try parser.parse();
    const view = growthParserView(&parser);
    var pool = TypePool.init(allocator);
    defer pool.deinit(allocator);
    var env = TypeEnv.init(allocator, &pool);
    defer env.deinit();
    var completion: GrowthCompletionObserver = .{};
    if (env.populateSourceTypesImpl(.{ .direct = .{
        .store = &parser.type_store,
        .ir_view = view,
        .atoms = &atoms,
    } }, completion.observer())) |_| {} else |err| {
        switch (err) {
            error.OutOfMemory => {},
            else => return err,
        }
        if (env.sourceTypeMode() == null) {
            observations.validation_failures += 1;
            try std.testing.expectError(error.OutOfMemory, env.ensureHealthy());
            return err;
        }
        try std.testing.expectEqual(SourceTypeMode.direct, env.sourceTypeMode().?);
        observations.selected_failures += 1;
        var unhealthy = false;
        if (env.ensureHealthy()) |_| {} else |health_err| {
            switch (health_err) {
                error.OutOfMemory => unhealthy = true,
            }
        }
        if (pool.ensureHealthy()) |_| {} else |health_err| {
            switch (health_err) {
                error.OutOfMemory, error.TypePoolCapacityExceeded => unhealthy = true,
            }
        }
        try std.testing.expect(unhealthy);
        if (completion.completed_events > 0 and env.direct_source_fn_annotations.count() == 0) {
            observations.source_annotation_failures += 1;
        }
        if (env.direct_accumulator_events == 2 and
            env.direct_source_fn_annotations.count() == 2 and
            env.direct_fn_signatures.count() == 0)
        {
            observations.publication_failures += 1;
        }
        if (env.direct_fn_signatures.count() == 1 and env.fn_sigs_by_name.count() == 0) {
            observations.name_merge_failures += 1;
        }
        return err;
    }
    observations.successes += 1;
    try env.ensureHealthy();
    try pool.ensureHealthy();
    try std.testing.expectEqual(@as(usize, 2), env.direct_accumulator_events);
    try std.testing.expectEqual(@as(usize, 1), env.direct_fn_signatures.count());
    try std.testing.expectEqual(@as(usize, 1), env.fn_sigs_by_name.count());
}

const GrowthPostBoundaryArm = struct {
    failing: *std.testing.FailingAllocator,
    before_capacity: usize = 0,
    armed: bool = false,

    fn observer(self: *GrowthPostBoundaryArm) DirectReplayObserver {
        return .{ .context = self, .visit = visit };
    }

    fn visit(context: *anyopaque, snapshot: DirectReplaySnapshot) void {
        const self: *GrowthPostBoundaryArm = @ptrCast(@alignCast(context));
        if (snapshot.phase == .before) {
            self.before_capacity = snapshot.compatibility_capacity;
            return;
        }
        if (!self.armed and snapshot.compatibility_found_existing and
            snapshot.compatibility_capacity > self.before_capacity)
        {
            self.armed = true;
            self.failing.fail_index = self.failing.alloc_index;
            self.failing.resize_fail_index = self.failing.resize_index;
        }
    }
};

test "direct signature replay allocation failures poison incomplete publication" {
    var observations: GrowthFailureObservations = .{};
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        growthPublicAllocationSweep,
        .{&observations},
    );
    try std.testing.expect(observations.validation_failures > 0);
    try std.testing.expect(observations.selected_failures > 0);
    try std.testing.expect(observations.source_annotation_failures > 0);
    try std.testing.expect(observations.publication_failures > 0);
    try std.testing.expect(observations.name_merge_failures > 0);
    try std.testing.expect(observations.successes > 0);

    const source = "function value(item: string): string { return item; }";
    var atoms = AtomTable.init(std.testing.allocator);
    defer atoms.deinit();
    var parser = try engine.parser.JsParser.initAdmission(std.testing.allocator, std.testing.allocator, source, .compile);
    defer parser.deinit();
    parser.setAtomTable(&atoms);
    _ = try parser.parse();
    const view = growthParserView(&parser);
    const signature = &parser.type_store.function_signatures.items[0];
    var compatibility_failures: usize = 0;
    var accumulator_failures: usize = 0;
    for (0..8) |offset| {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
        const injected = failing.allocator();
        var pool = TypePool.init(injected);
        defer pool.deinit(injected);
        var env = TypeEnv.init(injected, &pool);
        defer env.deinit();
        var compatibility: DirectCompatibilityOrder = .empty;
        defer compatibility.deinit(injected);
        var accumulators: DirectFunctionAccumulators = .empty;
        defer accumulators.deinit(injected);
        failing.fail_index = failing.alloc_index + offset;
        _ = env.replayDirectSignatureEvent(
            view,
            signature,
            &compatibility,
            &accumulators,
            null,
        ) catch |err| {
            switch (err) {
                error.OutOfMemory => {},
                else => return err,
            }
            try std.testing.expect(failing.has_induced_failure);
            if (compatibility.count() == 0 and accumulators.count() == 0) {
                compatibility_failures += 1;
            } else if (compatibility.count() == 1 and accumulators.count() == 0) {
                accumulator_failures += 1;
            }
            continue;
        };
    }
    try std.testing.expect(compatibility_failures > 0);
    try std.testing.expect(accumulator_failures > 0);

    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const injected = failing.allocator();
    var growth_atoms = AtomTable.init(std.testing.allocator);
    defer growth_atoms.deinit();
    var growth_parser = try engine.parser.JsParser.initAdmission(
        std.testing.allocator,
        std.testing.allocator,
        growth_source_plain,
        .compile,
    );
    defer growth_parser.deinit();
    growth_parser.setAtomTable(&growth_atoms);
    _ = try growth_parser.parse();
    var growth_pool = TypePool.init(injected);
    defer growth_pool.deinit(injected);
    var growth_env = TypeEnv.init(injected, &growth_pool);
    defer growth_env.deinit();
    var arm: GrowthPostBoundaryArm = .{ .failing = &failing };
    try std.testing.expectError(error.OutOfMemory, growth_env.populateSourceTypesImpl(.{ .direct = .{
        .store = &growth_parser.type_store,
        .ir_view = growthParserView(&growth_parser),
        .atoms = &growth_atoms,
    } }, arm.observer()));
    try std.testing.expect(arm.armed);
    try std.testing.expect(failing.has_induced_failure);
    try std.testing.expectEqual(SourceTypeMode.direct, growth_env.sourceTypeMode().?);
    try std.testing.expectError(error.OutOfMemory, growth_env.ensureHealthy());
}

fn growthSignatureEqual(left: FunctionSig, right: FunctionSig) bool {
    if (left.param_count != right.param_count or
        !std.mem.eql(
            TypeIndex,
            left.param_types[0..left.param_count],
            right.param_types[0..right.param_count],
        ) or
        left.required_param_count != right.required_param_count or
        left.max_arg_count != right.max_arg_count or
        left.return_type != right.return_type or
        left.type_param_count != right.type_param_count or
        !std.meta.eql(left.type_predicate, right.type_predicate)) return false;
    for (left.type_params[0..left.type_param_count], right.type_params[0..right.type_param_count]) |a, b| {
        if (!std.mem.eql(u8, a.name, b.name) or a.idx != b.idx or a.constraint != b.constraint) return false;
    }
    return true;
}

const GrowthCompatibilityEntry = struct {
    key: u32,
    owner: NodeIndex,
};

const GrowthAccumulatorEntry = struct {
    owner: NodeIndex,
    accumulator: DirectFunctionAccumulator,
};

const GrowthFallbackObserver = struct {
    failing: *std.testing.FailingAllocator,
    target_event: usize,
    before_compatibility_entries: []GrowthCompatibilityEntry,
    before_accumulator_entries: []GrowthAccumulatorEntry,
    event_index: usize = 0,
    before_compatibility_entries_count: usize = 0,
    before_accumulator_entries_count: usize = 0,
    before_compatibility_capacity: usize = 0,
    before_compatibility_count: usize = 0,
    before_accumulator_capacity: usize = 0,
    before_accumulator_count: usize = 0,
    armed: bool = false,
    observed_after: bool = false,
    invalid: bool = false,

    fn observer(self: *GrowthFallbackObserver) DirectReplayObserver {
        return .{ .context = self, .visit = visit };
    }

    fn visit(context: *anyopaque, snapshot: DirectReplaySnapshot) void {
        const self: *GrowthFallbackObserver = @ptrCast(@alignCast(context));
        if (snapshot.phase == .before) {
            if (self.event_index != self.target_event) return;
            if (!snapshot.compatibility_found_existing) {
                self.invalid = true;
                return;
            }
            self.before_compatibility_capacity = snapshot.compatibility_capacity;
            self.before_compatibility_count = snapshot.compatibility_count;
            self.before_accumulator_capacity = snapshot.accumulator_capacity;
            self.before_accumulator_count = snapshot.accumulator_count;
            if (!snapshot.accumulators.contains(snapshot.owner)) {
                self.invalid = true;
                return;
            }
            var compatibility_entries = snapshot.compatibility_order.iterator();
            while (compatibility_entries.next()) |entry| {
                if (self.before_compatibility_entries_count >= self.before_compatibility_entries.len) {
                    self.invalid = true;
                    return;
                }
                self.before_compatibility_entries[self.before_compatibility_entries_count] = .{
                    .key = entry.key_ptr.*,
                    .owner = entry.value_ptr.*,
                };
                self.before_compatibility_entries_count += 1;
            }
            var accumulator_entries = snapshot.accumulators.iterator();
            while (accumulator_entries.next()) |entry| {
                if (self.before_accumulator_entries_count >= self.before_accumulator_entries.len) {
                    self.invalid = true;
                    return;
                }
                self.before_accumulator_entries[self.before_accumulator_entries_count] = .{
                    .owner = entry.key_ptr.*,
                    .accumulator = entry.value_ptr.*,
                };
                self.before_accumulator_entries_count += 1;
            }
            self.failing.fail_index = self.failing.alloc_index;
            self.failing.resize_fail_index = self.failing.resize_index;
            self.armed = true;
            return;
        }
        if (self.event_index == self.target_event) {
            if (!self.armed or !self.failing.has_induced_failure or
                snapshot.compatibility_capacity != self.before_compatibility_capacity or
                snapshot.compatibility_count != self.before_compatibility_count or
                snapshot.accumulator_capacity != self.before_accumulator_capacity or
                snapshot.accumulator_count != self.before_accumulator_count)
            {
                self.invalid = true;
            }
            var index: usize = 0;
            var compatibility_entries = snapshot.compatibility_order.iterator();
            while (compatibility_entries.next()) |entry| : (index += 1) {
                if (index >= self.before_compatibility_entries_count or
                    self.before_compatibility_entries[index].key != entry.key_ptr.* or
                    self.before_compatibility_entries[index].owner != entry.value_ptr.*)
                {
                    self.invalid = true;
                    break;
                }
            }
            if (index != self.before_compatibility_entries_count) self.invalid = true;
            index = 0;
            var accumulator_entries = snapshot.accumulators.iterator();
            while (accumulator_entries.next()) |entry| : (index += 1) {
                if (index >= self.before_accumulator_entries_count) {
                    self.invalid = true;
                    break;
                }
                const before = self.before_accumulator_entries[index];
                if (before.owner != entry.key_ptr.* or
                    before.accumulator.publish_name != entry.value_ptr.publish_name or
                    !growthSignatureEqual(before.accumulator.signature, entry.value_ptr.signature))
                {
                    self.invalid = true;
                    break;
                }
            }
            if (index != self.before_accumulator_entries_count) self.invalid = true;
            self.failing.fail_index = std.math.maxInt(usize);
            self.failing.resize_fail_index = std.math.maxInt(usize);
            self.observed_after = true;
        }
        self.event_index += 1;
    }
};

test "direct signature replay preserves existing entries after failed growth" {
    const boundaries = try growthExpectTraceCase(.plain);
    for (boundaries) |target_event| {
        const allocator = std.testing.allocator;
        var atoms = AtomTable.init(allocator);
        defer atoms.deinit();
        var parser = try engine.parser.JsParser.initAdmission(allocator, allocator, growth_source_plain, .compile);
        defer parser.deinit();
        parser.setAtomTable(&atoms);
        const root = try parser.parse();
        try growthExpectRuntime(&parser, root);
        const view = growthParserView(&parser);
        var expected_pool = TypePool.init(allocator);
        defer expected_pool.deinit(allocator);
        var expected_env = TypeEnv.init(allocator, &expected_pool);
        defer expected_env.deinit();
        try expected_env.populateSourceTypes(.{ .direct = .{
            .store = &parser.type_store,
            .ir_view = view,
            .atoms = &atoms,
        } });
        try growthExpectTraceSignatures(&expected_env, &parser, &atoms, .plain);

        var failing = std.testing.FailingAllocator.init(allocator, .{});
        const injected = failing.allocator();
        var direct_pool = TypePool.init(injected);
        defer direct_pool.deinit(injected);
        var direct_env = TypeEnv.init(injected, &direct_pool);
        defer direct_env.deinit();
        const before_compatibility_entries = try allocator.alloc(GrowthCompatibilityEntry, 32);
        defer allocator.free(before_compatibility_entries);
        const before_accumulator_entries = try allocator.alloc(GrowthAccumulatorEntry, 32);
        defer allocator.free(before_accumulator_entries);
        var observer: GrowthFallbackObserver = .{
            .failing = &failing,
            .target_event = target_event,
            .before_compatibility_entries = before_compatibility_entries,
            .before_accumulator_entries = before_accumulator_entries,
        };
        try direct_env.populateSourceTypesImpl(.{ .direct = .{
            .store = &parser.type_store,
            .ir_view = view,
            .atoms = &atoms,
        } }, observer.observer());
        try std.testing.expect(observer.armed);
        try std.testing.expect(observer.observed_after);
        try std.testing.expect(!observer.invalid);
        try std.testing.expect(failing.has_induced_failure);
        try direct_env.ensureHealthy();
        try direct_pool.ensureHealthy();
        try growthExpectExactPool(&expected_pool, &direct_pool);
        try growthExpectFinalSignatures(
            &expected_env,
            &direct_env,
            view,
            &parser.type_store,
        );
    }
}
