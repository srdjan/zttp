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

    /// Result type ({ok, value, error}) - verifier requires .ok check
    result,

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
            .result => "Result",
        };
    }
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
pub const DataLabel = enum(u3) {
    secret, // env vars with sensitive names (PASSWORD, KEY, TOKEN, SECRET, PRIVATE)
    credential, // auth tokens, JWT payloads, bearer tokens
    user_input, // request body, headers, query params, path params
    config, // non-secret env configuration
    internal, // cache values, internal state
    external, // data from fetchSync responses
    validated, // data that passed through validation
};

/// Bitset of data provenance labels. Propagates through operations via merge (OR).
/// Compact enough (1 byte) to store per-node in the flow checker's label map.
pub const LabelSet = packed struct(u8) {
    secret: bool = false,
    credential: bool = false,
    user_input: bool = false,
    config: bool = false,
    internal: bool = false,
    external: bool = false,
    validated: bool = false,
    _pad: u1 = 0,

    pub const empty: LabelSet = .{};

    /// Bitwise OR: union of two label sets.
    pub fn merge(a: LabelSet, b: LabelSet) LabelSet {
        const ai: u8 = @bitCast(a);
        const bi: u8 = @bitCast(b);
        return @bitCast(ai | bi);
    }

    /// Merge for conditional branches (ternary/if-else): taint labels use OR
    /// (either branch can taint), but `validated` uses AND (a value is only
    /// considered validated when ALL branches that produce it are validated;
    /// otherwise one unvalidated path launders the flag for the entire ternary).
    pub fn mergeConditional(a: LabelSet, b: LabelSet) LabelSet {
        const ai: u8 = @bitCast(a);
        const bi: u8 = @bitCast(b);
        const validated_mask: u8 = 1 << @intFromEnum(DataLabel.validated);
        return @bitCast(((ai | bi) & ~validated_mask) | ((ai & bi) & validated_mask));
    }

    /// Check if a specific label is present.
    pub fn has(self: LabelSet, label: DataLabel) bool {
        const bit: u3 = @intFromEnum(label);
        const mask: u8 = @as(u8, 1) << bit;
        const raw: u8 = @bitCast(self);
        return (raw & mask) != 0;
    }

    /// Check if any label in the mask is present.
    pub fn hasAny(self: LabelSet, mask: LabelSet) bool {
        const si: u8 = @bitCast(self);
        const mi: u8 = @bitCast(mask);
        return (si & mi) != 0;
    }

    /// True if no labels are set.
    pub fn isEmpty(self: LabelSet) bool {
        const raw: u8 = @bitCast(self);
        return (raw & 0x7F) == 0; // ignore pad bit
    }

    /// Create a LabelSet from a single label.
    pub fn fromLabel(label: DataLabel) LabelSet {
        const bit: u3 = @intFromEnum(label);
        const mask: u8 = @as(u8, 1) << bit;
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

    /// Return type classification. Drives verifier, bool checker, and type checker.
    returns: ReturnKind = .unknown,

    /// Type signature for parameter types (mapped to TypeIndex during type init).
    param_types: []const ReturnKind = &.{},

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
            // `param_types` is what the type checker enforces at the call site,
            // so an under-declared list silently drops the diagnostic for that
            // argument position. Three entries had drifted this way (cacheStats,
            // io.parallel, io.race declared no parameters while reading args[0]).
            // Declare one kind per argument; mark trailing optional arguments
            // with `required_arg_count` rather than by omitting their type.
            if (f.param_types.len != f.arg_count) {
                @compileError(std.fmt.comptimePrint(
                    "{s}.{s} declares arg_count={d} but {d} param_types; declare one kind per argument",
                    .{ b.specifier, f.name, f.arg_count, f.param_types.len },
                ));
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
