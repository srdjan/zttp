//! The declarative vocabulary a module binding is written in: return kinds,
//! failure severities, data labels, contract categories, algebraic laws, and
//! the `FunctionBinding` / `ModuleBinding` records themselves, plus the
//! comptime validation that runs over them.
//!
//! No runtime behavior: everything here is comptime metadata the analyzers,
//! the verifier, and the spec renderer read.
//!
//! Split out of module_binding.zig, which re-exports every name here.

const std = @import("std");
const object = @import("../object.zig");
const value = @import("../value.zig");
const resolver = @import("../modules/internal/resolver.zig");
const capabilities = @import("capabilities.zig");

const ModuleCapability = capabilities.ModuleCapability;
const ModuleFn = capabilities.ModuleFn;
const wrapModuleFn = capabilities.wrapModuleFn;
const wrapModuleFnWithCapabilities = capabilities.wrapModuleFnWithCapabilities;

/// Re-export EffectClass from resolver for backward compatibility
pub const EffectClass = resolver.EffectClass;

// -------------------------------------------------------------------------
// Return type classification
// -------------------------------------------------------------------------

/// Unified return type for verification, type checking, and bool checking.
/// Each consumer maps this to its own internal representation.
pub const ReturnKind = enum {
    /// Plain value types - no caller-side check required
    boolean,
    number,
    string,
    object,
    undefined,
    unknown,

    /// Optional types - verifier requires narrowing before use
    optional_string,
    optional_object,
    /// `number | undefined`. The shape `byteAt` answers with, and the only
    /// optional the vocabulary was missing: declaring it `.unknown` would have
    /// been the checker knowing less than spec 6.3 states.
    optional_number,

    /// Result type ({ok, value, error}) - verifier requires .ok check
    result,

    /// `Dict<K, V>` (spec 6.2). Coarse in the same way `result` is: a binding
    /// cannot spell an export's type parameters, so a declared `dict` reaches
    /// the checker as `Dict<unknown, unknown>`.
    dict,

    /// `Bytes` (spec 6.3). Not coarse: `Bytes` takes no type parameters, so
    /// the kind names the type exactly.
    bytes,

    /// Lowercase JS-facing type name for signature advertisement (e.g. in
    /// `zts modules --json`). Maps the verifier-oriented tags onto the
    /// shapes a handler author actually sees at the call site.
    pub fn jsTypeName(self: ReturnKind) []const u8 {
        return switch (self) {
            .boolean => "boolean",
            .number => "number",
            .string => "string",
            .object => "object",
            .undefined => "undefined",
            .unknown => "unknown",
            .optional_string => "string?",
            .optional_object => "object?",
            .optional_number => "number?",
            .result => "Result",
            .dict => "Dict",
            .bytes => "Bytes",
        };
    }
};

/// A signature spelled in source text, one entry per parameter plus the return.
///
/// `ReturnKind` can name a fixed set of coarse shapes and nothing else, so an
/// export whose type is a literal union, a record, or a named ABI type had to
/// declare `.object` or `.unknown` and lose the question at the call site.
/// This is the override: `returnKindToTs` reads the text here before falling
/// back to the enum, and `parseTypeExpr` - the same parser that already builds
/// every module signature - turns it into the precise type.
///
/// It is a channel that already exists, not a new one. The frozen-signature
/// gate runs the whole pipeline over every export, so a declared signature is
/// covered by construction, and its "no fallback to `unknown`" assertion is
/// what stops a mistyped signature from degrading quietly.
pub const DeclaredSignature = struct {
    /// One entry per declared parameter, in order. Must be `arg_count` long.
    params: []const []const u8,
    /// The return type as source text.
    returns: []const u8,
};

// -------------------------------------------------------------------------
// Failure severity classification
// -------------------------------------------------------------------------

/// How the fault coverage checker treats a 2xx response on this function's
/// failure path. Derived from the function's domain semantics:
///   - critical: security/validation boundary - 2xx on failure is suspicious
///   - expected: cache miss or missing config - 2xx is normal (graceful degradation)
///   - upstream: external service failure - 2xx may be intentional (fallback)
///   - none: function cannot fail (returns plain value)
pub const FailureSeverity = enum {
    /// Auth or validation failure - 2xx on failure path is a warning.
    critical,
    /// Cache miss, missing env, route not matched - 2xx is fine.
    expected,
    /// External service failure (fetchSync) - 2xx is informational.
    upstream,
    /// Function always succeeds (returns plain value, not Result/optional).
    none,
};

// -------------------------------------------------------------------------
// Data provenance labels
// -------------------------------------------------------------------------

/// Classification of data sensitivity for compile-time information flow analysis.
/// The flow checker tracks these labels through the handler's data flow graph,
/// proving that sensitive data never reaches unauthorized sinks.
pub const DataLabel = enum(u4) {
    secret, // env vars with sensitive names (PASSWORD, KEY, TOKEN, SECRET, PRIVATE)
    credential, // auth tokens, JWT payloads, bearer tokens
    user_input, // request body, headers, query params, path params
    config, // non-secret env configuration
    internal, // cache values, internal state
    external, // data from fetchSync responses
    validated, // data that passed through validation
    nondeterministic, // derived from a clock or RNG read: differs between runs
    unknown, // provenance the checker could not follow: proves nothing
};

/// Bitset of data provenance labels. Propagates through operations via merge (OR).
/// Compact enough (2 bytes) to store per-node in the flow checker's label map.
pub const LabelSet = packed struct(u16) {
    secret: bool = false,
    credential: bool = false,
    user_input: bool = false,
    config: bool = false,
    internal: bool = false,
    external: bool = false,
    validated: bool = false,
    /// Derived from a clock or RNG read, so it differs between runs of the
    /// same request. Seeded from the export's own capabilities rather than
    /// declared per binding, and consumed where the value reaches a response.
    nondeterministic: bool = false,
    /// The checker could not follow where this value came from - a call it
    /// could not summarize. Distinct from the empty set, which is the positive
    /// claim that a value carries nothing: a sink that this reaches cannot
    /// prove the properties it governs, so they are cleared rather than held.
    unknown: bool = false,
    _reserved: u7 = 0,

    pub const empty: LabelSet = .{};

    /// Bitwise OR: union of two label sets.
    pub fn merge(a: LabelSet, b: LabelSet) LabelSet {
        const ai: u16 = @bitCast(a);
        const bi: u16 = @bitCast(b);
        return @bitCast(ai | bi);
    }

    /// Merge for conditional branches (ternary/if-else): taint labels use OR
    /// (either branch can taint), but `validated` uses AND (a value is only
    /// considered validated when ALL branches that produce it are validated;
    /// otherwise one unvalidated path launders the flag for the entire ternary).
    pub fn mergeConditional(a: LabelSet, b: LabelSet) LabelSet {
        const ai: u16 = @bitCast(a);
        const bi: u16 = @bitCast(b);
        const validated_mask: u16 = @as(u16, 1) << @intFromEnum(DataLabel.validated);
        return @bitCast(((ai | bi) & ~validated_mask) | ((ai & bi) & validated_mask));
    }

    /// Check if a specific label is present.
    pub fn has(self: LabelSet, label: DataLabel) bool {
        const mask: u16 = @as(u16, 1) << @intFromEnum(label);
        const raw: u16 = @bitCast(self);
        return (raw & mask) != 0;
    }

    /// Check if any label in the mask is present.
    pub fn hasAny(self: LabelSet, mask: LabelSet) bool {
        const si: u16 = @bitCast(self);
        const mi: u16 = @bitCast(mask);
        return (si & mi) != 0;
    }

    /// True if no labels are set. `_reserved` is never written, so the whole
    /// word answers this: an earlier version masked off what it took to be a
    /// pad bit, and a set carrying only `nondeterministic` - which had moved
    /// into that bit - read as empty, which both the sink check and the import
    /// scan take as "nothing to do".
    pub fn isEmpty(self: LabelSet) bool {
        const raw: u16 = @bitCast(self);
        return raw == 0;
    }

    /// Create a LabelSet from a single label.
    pub fn fromLabel(label: DataLabel) LabelSet {
        const mask: u16 = @as(u16, 1) << @intFromEnum(label);
        return @bitCast(mask);
    }
};

// -------------------------------------------------------------------------
// Contract extraction rules
// -------------------------------------------------------------------------

/// Category for extracted literals in the contract JSON.
pub const ContractCategory = enum {
    env,
    cache_namespace,
    sql_registration,
    scope_name,
    durable_key,
    durable_step,
    durable_signal,
    durable_producer_key,
    schema_compile,
    request_schema,
    route_pattern,
    cookie_name,
    cors_origin,
    rate_limit_key,
    service_call,
    fetch_host,
    /// A `zttp:workflow` `call`/`saga`/`fanout` target: a named co-located
    /// sub-handler dispatched in-process. See `WorkflowCallInfo`.
    workflow_call,
    /// Partner-declared category. The actual tag string lives on
    /// `ContractExtraction.extension_category` and is emitted under
    /// `contract.json` at `extensions.<specifier>.categories`.
    extension_specific,
};

/// Transform applied to extracted literal before storing.
pub const ContractTransform = enum {
    /// Extract hostname from URL string.
    extract_host,
    /// No transform, use raw literal.
    identity,
};

/// Declarative rule for extracting a literal from a function argument.
pub const ContractExtraction = struct {
    /// Which argument position holds the literal (0-indexed).
    arg_position: u8 = 0,
    /// What category this literal belongs to in the contract.
    category: ContractCategory,
    /// Optional transform applied to the raw string.
    transform: ?ContractTransform = null,
    /// When true, the call sets a boolean flag rather than extracting a literal.
    flag_only: bool = false,
    /// Partner-declared category tag. Only meaningful when
    /// `category == .extension_specific`. Borrowed reference for
    /// comptime built-in declarations; owned for manifest-derived rules
    /// (the owning store frees it).
    extension_category: ?[]const u8 = null,
};

/// Boolean flags set on the contract when a function is imported or called.
pub const ContractFlags = struct {
    sets_scope_used: bool = false,
    sets_durable_used: bool = false,
    sets_durable_timers: bool = false,
    sets_bearer_auth: bool = false,
    sets_jwt_auth: bool = false,
};

// -------------------------------------------------------------------------
// Algebraic laws
// -------------------------------------------------------------------------

/// Tag identifying which algebraic law applies to a function.
/// Laws are the mechanism behind proven-equivalent deploys: the canonicalizer
/// walks `BehaviorPath.io_sequence` and applies rewrites justified by these
/// equations. Every variant here must be *unconditionally sound*, i.e. the
/// rewrite is valid regardless of surrounding context. Conditional laws
/// (commutation, reordering) are explicitly deferred until side-condition
/// machinery exists.
pub const LawKind = enum {
    pure,
    idempotent_call,
    inverse_of,
    absorbing,
};

/// An algebraic equation attached to a `FunctionBinding`.
///
/// - `.pure`: `f(args)` is a function of its arguments only. Two adjacent
///   calls with structurally-equal arguments collapse to one.
/// - `.idempotent_call`: `f(args); f(args)` has the same observable effect
///   as `f(args)`. The only law allowed on write-effect functions.
/// - `.inverse_of`: `g(f(x)) == x` where `g` is the named function.
///   The name is resolved against the full registry in `validateBindings`;
///   a dangling reference is a compile error.
/// - `.absorbing`: when an argument matches `AbsorbingPattern.argument_shape`,
///   the call is known to produce the fixed `residue` and can be folded.
pub const Law = union(LawKind) {
    pure: void,
    idempotent_call: void,
    inverse_of: []const u8,
    absorbing: AbsorbingPattern,
};

/// Describes a recognizable argument shape and the residue the function
/// produces when that shape appears. Used for dead-branch pruning during
/// path canonicalization (e.g. `jwtVerify("")` is always `.err`).
pub const AbsorbingPattern = struct {
    /// Which argument position the pattern matches on (0-indexed).
    arg_position: u8 = 0,
    /// The shape the argument must have for the residue to apply.
    argument_shape: ArgumentShape,
    /// The fixed residue produced when the shape matches.
    residue: Residue,

    pub const ArgumentShape = enum {
        empty_string_literal,
        undefined_literal,
    };

    pub const Residue = enum {
        result_err,
        returns_undefined,
        returns_false,
    };
};

/// How an export's return type is read off one of its arguments, for the
/// exports whose answer is not a fixed type.
///
/// `ReturnKind` can only name a fixed type, so an export that hands back
/// whatever its caller's callback produced had to declare `unknown`. That was
/// harmless while an unresolved name answered assignable, and stops being
/// harmless under D1 amendment A1: `unknown` is assignable to nothing, so every
/// `durable.run(key, () => Response.json(...))` in a handler declaring
/// `Response` became a return-type mismatch. The type is not unknown - it is
/// the callback's, and this field says which argument to read it from.
pub const ReturnFromParam = struct {
    /// Position of the argument the return type is read from.
    param_index: u8,

    kind: enum {
        /// The argument is a function and the export returns what calling it
        /// returns: `run(key: string, fn: () => T) -> T`.
        call_result,
        /// The export returns the argument unchanged:
        /// `using(resource: T, close: (T) => void) -> T`.
        identity,
    },
};

// -------------------------------------------------------------------------
// Function binding
// -------------------------------------------------------------------------

/// Complete metadata for a single exported function.
pub const FunctionBinding = struct {
    /// Function name as visible from JS import.
    name: []const u8,

    /// Native implementation (for built-in modules using raw Context access).
    /// Exactly one of func or module_func must be set.
    func: ?object.NativeFn = null,

    /// Sandboxed implementation (for third-party modules using ModuleHandle).
    /// The registration system wraps this into a NativeFn automatically.
    module_func: ?ModuleFn = null,

    /// Argument count (for JS runtime).
    arg_count: u8,

    /// Required argument count for static checking. When null, every typed
    /// parameter is required.
    required_arg_count: ?u8 = null,

    /// Effect classification for handler property derivation.
    effect: EffectClass = .read,

    /// Runtime capabilities this export consumes, as opposed to the union its
    /// module declares. `null` means "inherit the module's set", which is what
    /// every binding did before this field existed - so an untightened module
    /// keeps its current behaviour exactly. An empty slice is a different
    /// claim: this export reaches nothing, which is the answer for
    /// `parseBearer` and `timingSafeEqual` and is unsayable if empty meant
    /// inherit.
    ///
    /// The module-level union is an over-approximation per export:
    /// `zttp:websocket` declares six capabilities, and `serializeAttachment`
    /// reaches none of them. Under a mandatory-ceiling rule that turns into
    /// annotations that are wrong on their face, and over-approximating on the
    /// provable side rejects true programs. Declaring the real set per export
    /// is what makes a ceiling truthful.
    ///
    /// `validateBindings` requires this to be a subset of the module's set, so
    /// tightening an export can never widen its authority by accident.
    required_capabilities: ?[]const ModuleCapability = null,

    /// Return type classification. Drives verifier, bool checker, and type checker.
    returns: ReturnKind = .unknown,

    /// Set when the return type is a function of an argument rather than a
    /// fixed type. The type checker builds a one-parameter generic signature
    /// from it and infers the parameter at each call site; every other consumer
    /// keeps reading `returns`, which stays `.unknown` - the honest answer for
    /// a caller that has no argument to read.
    returns_from_param: ?ReturnFromParam = null,

    /// Type signature for parameter types (mapped to TypeIndex during type init).
    param_types: []const ReturnKind = &.{},

    /// Argument positions whose type must be JSON-encodable, checked by the
    /// same rule `Response.json` runs. An export that serializes an argument
    /// to the wire owes its caller the diagnostic at the call site rather than
    /// a throw inside the encoder, and this is how it says which argument.
    json_encodable_args: []const u8 = &.{},

    /// The precise signature, when the coarse kinds above cannot spell it.
    /// Every consumer that reads `param_types`/`returns` as text goes through
    /// `returnKindToTs`, which consults this first, so declaring it here is
    /// enough - there is no second place to keep in step.
    signature: ?DeclaredSignature = null,

    /// Whether trace/replay/durable should wrap this function.
    /// false for setup-only functions (schemaCompile, schemaDrop, sql register).
    traceable: bool = true,

    /// Whether this function is safe to execute live during replay/`serve --test`
    /// when no recorded I/O entry matches: its result must depend only on its
    /// arguments and in-process setup (e.g. a compiled schema), with no read of
    /// host/external or non-deterministic state. This is a stronger property
    /// than `Law.pure` (which is algebraic - `env()` is `.pure` yet reads the
    /// host environment), so it is an explicit, audited opt-in rather than
    /// inferred. Default false: a replay-stubbed function returns the recorded
    /// result or `undefined`.
    replay_pure: bool = false,

    /// Contract extraction rules for this function's arguments.
    contract_extractions: []const ContractExtraction = &.{},

    /// Flags set on the contract when this function is called.
    contract_flags: ContractFlags = .{},

    /// Data provenance labels for this function's return value.
    /// Used by the flow checker to track sensitive data through the handler.
    return_labels: LabelSet = .{},

    /// Set when the return value can contain data that arrived as an argument,
    /// and the export validates nothing. The flow checker then unions every
    /// argument's labels into the call's result instead of answering the
    /// declared set alone.
    ///
    /// `return_labels` on its own is a fail-open for this shape. An export
    /// that declares nothing answers the empty set, so `dictSet(d, k, secret)`
    /// followed by `dictGet(d, k)` reached the response with
    /// `no_secret_leakage` PROVEN - measured, not supposed. This is the same
    /// conflation `validateJson` shipped, minus the discharge: `.validated`
    /// says "and `user_input` is discharged, because validating is what
    /// discharges it", and this flag says only "the data passes through".
    ///
    /// Not for an export whose result is a fact *about* an argument rather
    /// than data *from* it: `dictHas` returns a presence boolean and cannot
    /// carry the value.
    derives_from_args: bool = false,

    /// Failure severity classification for fault coverage analysis.
    /// Determines how the fault coverage checker treats a 2xx response
    /// on this function's failure path.
    failure_severity: FailureSeverity = .none,

    /// Algebraic laws this function satisfies. Consumed by the behavior-path
    /// canonicalizer (see `behavior_canonical.zig`) to justify rewrites for
    /// proven-equivalent deploys. Every law must be unconditionally sound;
    /// `validateBindings` rejects laws that contradict the declared effect.
    laws: []const Law = &.{},

    /// Get the NativeFn for this binding, wrapping ModuleFn if needed.
    pub fn getNativeFn(comptime self: FunctionBinding) object.NativeFn {
        if (self.func) |f| return f;
        if (self.module_func) |mf| return wrapModuleFn(mf);
        @compileError("FunctionBinding must set either func or module_func");
    }

    /// Convert to a legacy ModuleExport for backward compatibility.
    pub fn toModuleExport(comptime self: FunctionBinding) resolver.ModuleExport {
        return .{
            .name = self.name,
            .func = self.getNativeFn(),
            .arg_count = self.arg_count,
            .effect = self.effect,
        };
    }
};

// -------------------------------------------------------------------------
// Module binding
// -------------------------------------------------------------------------

/// Complete declaration for a virtual module.
/// One per module - the single source of truth for all consumers.
pub const ModuleBinding = struct {
    /// Module specifier as used in JS imports: "zttp:crypto", "zttp:redis".
    specifier: []const u8,

    /// Short name for trace/replay JSON keys and enum references.
    name: []const u8,

    /// All exported functions with full metadata.
    exports: []const FunctionBinding,

    /// Runtime capabilities consumed by the module's Zig implementation.
    required_capabilities: []const ModuleCapability = &.{},

    /// Whether this module needs per-runtime state.
    stateful: bool = false,

    /// State initialization callback (called during runtime init).
    state_init: ?*const fn (*anyopaque, std.mem.Allocator) anyerror!void = null,

    /// State cleanup callback (called during context deinit).
    state_deinit: ?*const fn (*anyopaque, std.mem.Allocator) void = null,

    /// Contract section name for contract.json output.
    /// When non-null, the module gets its own top-level section.
    contract_section: ?[]const u8 = null,

    /// Whether the contract should feed into RuntimePolicy sandboxing.
    sandboxable: bool = false,

    /// Whether this module is compile-time only (skip trace/replay/durable).
    comptime_only: bool = false,

    /// Whether this module manages its own I/O wrapping (skip trace/replay/durable).
    /// Used by modules like durable that implement their own write-ahead logging.
    self_managed_io: bool = false,

    /// Generate a legacy exports array from this binding.
    pub fn toModuleExports(comptime self: ModuleBinding) [self.exports.len]resolver.ModuleExport {
        var result: [self.exports.len]resolver.ModuleExport = undefined;
        for (self.exports, 0..) |exp, i| {
            result[i] = exp.toModuleExport();
        }
        return result;
    }
};

// -------------------------------------------------------------------------
// Registry validation
// -------------------------------------------------------------------------

/// Validate a set of module bindings at compile time.
/// Produces clear compile errors for:
///   - duplicate specifiers
///   - duplicate function names within a module
///   - state lifecycle inconsistency (stateful without init/deinit)
///   - specifier format (must start with "zttp:" or "zttp-ext:")
///   - function bindings missing both func and module_func
pub fn validateBindings(comptime bindings: []const ModuleBinding) void {
    @setEvalBranchQuota(10000);
    // Check specifier format and state consistency per module
    for (bindings) |b| {
        const builtin_prefix = std.mem.startsWith(u8, b.specifier, "zttp:");
        const extension_prefix = std.mem.startsWith(u8, b.specifier, "zttp-ext:");
        if (!builtin_prefix and !extension_prefix) {
            @compileError("module specifier must start with 'zttp:' or 'zttp-ext:': " ++ b.specifier);
        }
        // state_init and state_deinit must be set together or not at all
        if (b.state_init != null and b.state_deinit == null) {
            @compileError("module has state_init but missing state_deinit: " ++ b.specifier);
        }
        if (b.state_init == null and b.state_deinit != null) {
            @compileError("module has state_deinit but missing state_init: " ++ b.specifier);
        }
        if (findDuplicateRequiredCapability(b.required_capabilities)) |capability| {
            @compileError("duplicate required capability '" ++ @tagName(capability) ++ "' in " ++ b.specifier);
        }
        for (b.exports) |f| {
            if (f.func == null and f.module_func == null) {
                @compileError("function binding missing both func and module_func: " ++ f.name);
            }
            if (f.required_capabilities) |export_caps| {
                if (findDuplicateRequiredCapability(export_caps)) |capability| {
                    @compileError("duplicate required capability '" ++ @tagName(capability) ++ "' on " ++ b.specifier ++ "." ++ f.name);
                }
                // An export may narrow its module's authority, never widen it.
                // Without this a tightening pass could hand a function a
                // capability its module never declared, and the module set is
                // what the runtime actually grants.
                for (export_caps) |cap| {
                    var found = false;
                    for (b.required_capabilities) |mod_cap| {
                        if (mod_cap == cap) found = true;
                    }
                    if (!found) {
                        @compileError("capability '" ++ @tagName(cap) ++ "' on " ++ b.specifier ++ "." ++ f.name ++ " is not declared by the module; an export may narrow its module's set, never widen it");
                    }
                }
            }
            // `param_types` is what the type checker enforces at the call site,
            // so an under-declared list silently drops the diagnostic for that
            // argument position. Three entries had drifted this way (cacheStats,
            // io.parallel, io.race declared no parameters while reading args[0]).
            // Declare one kind per argument; mark trailing optional arguments
            // with `required_arg_count` rather than by omitting their type.
            // A declared signature replaces the coarse text for every
            // position, so it must cover every position. A short list would
            // silently leave the trailing parameters on the enum - two
            // answers to one question, with the imprecise one winning where
            // it was least expected.
            for (f.json_encodable_args) |position| {
                if (position >= f.arg_count) {
                    @compileError(std.fmt.comptimePrint(
                        "{s}.{s} marks argument {d} JSON-encodable but declares arg_count={d}",
                        .{ b.specifier, f.name, position, f.arg_count },
                    ));
                }
            }
            if (f.signature) |sig| {
                if (sig.params.len != f.arg_count) {
                    @compileError(std.fmt.comptimePrint(
                        "{s}.{s} declares arg_count={d} but a signature with {d} parameters; declare one per argument",
                        .{ b.specifier, f.name, f.arg_count, sig.params.len },
                    ));
                }
                if (sig.returns.len == 0) {
                    @compileError(b.specifier ++ "." ++ f.name ++ " declares a signature with an empty return type");
                }
                for (sig.params) |param_text| {
                    if (param_text.len == 0) {
                        @compileError(b.specifier ++ "." ++ f.name ++ " declares a signature with an empty parameter type");
                    }
                }
            }
            if (f.param_types.len != f.arg_count) {
                @compileError(std.fmt.comptimePrint(
                    "{s}.{s} declares arg_count={d} but {d} param_types; declare one kind per argument",
                    .{ b.specifier, f.name, f.arg_count, f.param_types.len },
                ));
            }
            // A return read off an argument must name an argument that exists,
            // and must leave `returns` at `.unknown`. A fixed kind beside it
            // would be a second answer to the same question, and the consumers
            // that cannot instantiate a signature read that one.
            if (f.returns_from_param) |from| {
                if (from.param_index >= f.param_types.len) {
                    @compileError(std.fmt.comptimePrint(
                        "{s}.{s} reads its return type from argument {d} but declares {d} param_types",
                        .{ b.specifier, f.name, from.param_index, f.param_types.len },
                    ));
                }
                if (f.returns != .unknown) {
                    @compileError(b.specifier ++ "." ++ f.name ++ " reads its return type from an argument, so `returns` must stay `.unknown`");
                }
                if (f.param_types[from.param_index] != .unknown) {
                    @compileError(b.specifier ++ "." ++ f.name ++ " reads its return type from an argument whose declared kind is not `.unknown`; a callback or pass-through argument has no fixed kind to name");
                }
            }
            if (f.laws.len > 0) {
                if (b.comptime_only) {
                    @compileError("laws are not allowed on comptime_only module '" ++ b.specifier ++ "' function '" ++ f.name ++ "'");
                }
                if (b.self_managed_io) {
                    @compileError("laws are not allowed on self_managed_io module '" ++ b.specifier ++ "' function '" ++ f.name ++ "'");
                }
                if (findDuplicateLawKind(f.laws)) |kind| {
                    @compileError("duplicate law '" ++ @tagName(kind) ++ "' on " ++ b.specifier ++ "." ++ f.name);
                }
                for (f.laws) |law| {
                    if (f.effect == .write and law != .idempotent_call) {
                        @compileError("only '.idempotent_call' may be declared on write-effect function " ++ b.specifier ++ "." ++ f.name ++ " (got '." ++ @tagName(std.meta.activeTag(law)) ++ "')");
                    }
                }
            }
            // replay_pure is a stronger claim than Law.pure ("depends only on
            // args, no ambient state"; env() is .pure yet reads the host env).
            // The flag is SDK-exposed, so enforce the invariant the resolver
            // relies on at the binding boundary - otherwise the zttp:env leak
            // class (a secret-labeled function running for real under serve
            // --test) recurs one mis-declared flag away.
            if (f.replay_pure) {
                if (f.effect == .write) {
                    @compileError("replay_pure is invalid on the write-effect function " ++ b.specifier ++ "." ++ f.name);
                }
                if (f.return_labels.secret or f.return_labels.credential) {
                    @compileError("replay_pure is invalid on " ++ b.specifier ++ "." ++ f.name ++ ": a secret/credential return would leak host state into replayed/test responses");
                }
            }
        }
    }
    // Check unique specifiers
    for (bindings, 0..) |a, i| {
        for (bindings[i + 1 ..]) |b| {
            if (std.mem.eql(u8, a.specifier, b.specifier)) {
                @compileError("duplicate module specifier: " ++ a.specifier);
            }
        }
    }
    // Check unique function names within each module. Different modules may
    // export the same name because all proof metadata lookups must be keyed by
    // (specifier, export_name).
    for (bindings) |a| {
        for (a.exports, 0..) |af, afi| {
            for (a.exports[afi + 1 ..]) |af2| {
                if (std.mem.eql(u8, af.name, af2.name)) {
                    @compileError("duplicate function name within " ++ a.specifier ++ ": " ++ af.name);
                }
            }
        }
    }
    // Resolve .inverse_of references. The target name must refer to an
    // existing function somewhere in the registry, and the target must
    // declare the symmetric inverse so `g(f(x)) = x` and `f(g(x)) = x`
    // are both justified by paired declarations.
    for (bindings) |b| {
        for (b.exports) |f| {
            for (f.laws) |law| {
                switch (law) {
                    .inverse_of => |target_name| {
                        const target = findFunctionInRegistry(bindings, target_name) orelse {
                            @compileError("inverse_of target '" ++ target_name ++ "' not found for " ++ b.specifier ++ "." ++ f.name);
                        };
                        if (!hasInverseLawPointingTo(target.laws, f.name)) {
                            @compileError("inverse_of must be declared symmetrically: " ++
                                b.specifier ++ "." ++ f.name ++ " declares inverse_of=" ++
                                target_name ++ " but " ++ target_name ++ " does not declare inverse_of=" ++ f.name);
                        }
                    },
                    else => {},
                }
            }
        }
    }
}

pub fn findDuplicateRequiredCapability(comptime caps: []const ModuleCapability) ?ModuleCapability {
    for (caps, 0..) |capability, i| {
        for (caps[i + 1 ..]) |other| {
            if (capability == other) return capability;
        }
    }
    return null;
}

/// Return the first duplicated law *kind* within a single function's laws
/// list. Duplicates are always a spec error: laws are unconditionally sound
/// and idempotent, so declaring `[pure, pure]` or `[inverse_of "a", inverse_of "b"]`
/// signals confusion, not intent.
pub fn findDuplicateLawKind(comptime laws: []const Law) ?LawKind {
    for (laws, 0..) |law, i| {
        const kind = std.meta.activeTag(law);
        for (laws[i + 1 ..]) |other| {
            if (std.meta.activeTag(other) == kind) return kind;
        }
    }
    return null;
}

/// Find a function binding by name across an entire registry. Used to
/// resolve `.inverse_of` targets at comptime.
pub fn findFunctionInRegistry(
    comptime bindings: []const ModuleBinding,
    comptime name: []const u8,
) ?FunctionBinding {
    for (bindings) |b| {
        for (b.exports) |f| {
            if (std.mem.eql(u8, f.name, name)) return f;
        }
    }
    return null;
}

/// Check whether a laws list contains an `.inverse_of` pointing at `name`.
pub fn hasInverseLawPointingTo(
    comptime laws: []const Law,
    comptime name: []const u8,
) bool {
    for (laws) |law| {
        switch (law) {
            .inverse_of => |target| {
                if (std.mem.eql(u8, target, name)) return true;
            },
            else => {},
        }
    }
    return false;
}
