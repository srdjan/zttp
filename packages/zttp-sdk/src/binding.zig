const std = @import("std");
const handle = @import("handle.zig");
const value = @import("value.zig");

pub const ModuleHandle = handle.ModuleHandle;
pub const JSValue = value.JSValue;

pub const ModuleFn = *const fn (
    handle: *ModuleHandle,
    this: JSValue,
    args: []const JSValue,
) anyerror!JSValue;

pub const EffectClass = enum {
    read,
    write,
    none,
};

pub const ReturnKind = enum {
    boolean,
    number,
    string,
    object,
    undefined,
    unknown,
    optional_string,
    optional_object,
    /// `number | undefined`.
    optional_number,
    result,
    /// `Dict<K, V>` (spec 6.2). Coarse in the same way `result` is: the
    /// binding surface cannot spell a module export's type parameters, so a
    /// declared `dict` is `Dict<unknown, unknown>` to the checker.
    dict,
    /// `Bytes` (spec 6.3). Not coarse: `Bytes` takes no type parameters, so
    /// the kind names the type exactly.
    bytes,
};

pub const FailureSeverity = enum {
    critical,
    expected,
    upstream,
    none,
};

pub const ModuleCapability = enum {
    env,
    clock,
    random,
    crypto,
    stderr,
    runtime_callback,
    sqlite,
    filesystem,
    network,
    policy_check,
    websocket,
};

pub const ModuleCapabilityError = error{
    MissingModuleCapability,
    ClockUnavailable,
    StderrWriteFailed,
    RandomUnavailable,
};

pub const DataLabel = enum(u3) {
    secret,
    credential,
    user_input,
    config,
    internal,
    external,
    validated,
    nondeterministic,
};

/// The provenance labels an extension can declare on a return value. The
/// analyzer's own set carries one more - `unknown`, for a value it could not
/// trace - which it assigns and no binding declares, so the adapter maps these
/// fields across by name rather than by bit pattern.
pub const LabelSet = packed struct(u8) {
    secret: bool = false,
    credential: bool = false,
    user_input: bool = false,
    config: bool = false,
    internal: bool = false,
    external: bool = false,
    validated: bool = false,
    nondeterministic: bool = false,

    pub const empty: LabelSet = .{};
};

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
    // A zttp:workflow call/saga/fanout target: a named co-located
    // sub-handler dispatched in-process.
    workflow_call,
    // Partner-declared category. The actual tag string lives on
    // ContractExtraction.extension_category and is keyed under
    // contract.json's extensions.<specifier>.categories.
    extension_specific,
};

pub const ContractTransform = enum {
    extract_host,
    identity,
};

pub const ContractExtraction = struct {
    arg_position: u8 = 0,
    category: ContractCategory,
    transform: ?ContractTransform = null,
    flag_only: bool = false,
    extension_category: ?[]const u8 = null,
};

pub const ContractFlags = struct {
    sets_scope_used: bool = false,
    sets_durable_used: bool = false,
    sets_durable_timers: bool = false,
    sets_bearer_auth: bool = false,
    sets_jwt_auth: bool = false,
};

pub const LawKind = enum {
    pure,
    idempotent_call,
    inverse_of,
    absorbing,
};

pub const AbsorbingPattern = struct {
    arg_position: u8 = 0,
    argument_shape: ArgumentShape,
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

pub const Law = union(LawKind) {
    pure: void,
    idempotent_call: void,
    inverse_of: []const u8,
    absorbing: AbsorbingPattern,
};

pub const FunctionBinding = struct {
    name: []const u8,
    module_func: ModuleFn,
    arg_count: u8,
    required_arg_count: ?u8 = null,
    effect: EffectClass = .read,
    /// Capabilities this export consumes, as opposed to the union its module
    /// declares. `null` inherits the module set, which is what every binding
    /// did before this field existed. An empty slice is the different, sayable
    /// claim that this export reaches nothing.
    ///
    /// `validateBindings` requires it to be a subset of the module's set: an
    /// export may narrow its module's authority, never widen it.
    required_capabilities: ?[]const ModuleCapability = null,
    returns: ReturnKind = .unknown,
    param_types: []const ReturnKind = &.{},
    traceable: bool = true,
    /// Safe to execute live during replay/`serve --test` when no recorded I/O
    /// entry matches: result depends only on arguments and in-process setup,
    /// with no host/external or non-deterministic read. Explicit, audited
    /// opt-in (stronger than `Law.pure`); default false keeps it replay-stubbed.
    replay_pure: bool = false,
    contract_extractions: []const ContractExtraction = &.{},
    contract_flags: ContractFlags = .{},
    return_labels: LabelSet = .{},
    /// The return value can contain data that arrived as an argument, and this
    /// export validates nothing. The flow checker then unions every argument's
    /// labels into the call's result instead of answering `return_labels`
    /// alone.
    ///
    /// `return_labels` on its own is a fail-open for this shape, and the
    /// default is the shape: an export declaring nothing answers the empty
    /// set, which is a positive claim that its result carries no provenance.
    /// Measured across this package before the field existed - `sha256`,
    /// `base64Encode`, `urlEncode`, `slugify`, and sixteen others all returned
    /// a secret to the response body with `no_secret_leakage` PROVEN.
    ///
    /// Not for an export whose result is a fact *about* its arguments rather
    /// than data *from* them (`timingSafeEqual` returns a boolean and cannot
    /// carry the value), one whose result comes from elsewhere (storage, a
    /// fresh draw, the host), or a deliberate declassifier that declares what
    /// it clears - `mask` exists to make a secret printable, and unioning its
    /// input back in would defeat the export.
    derives_from_args: bool = false,
    failure_severity: FailureSeverity = .none,
    laws: []const Law = &.{},
};

pub const ModuleBinding = struct {
    specifier: []const u8,
    name: []const u8,
    exports: []const FunctionBinding,
    required_capabilities: []const ModuleCapability = &.{},
    stateful: bool = false,
    state_init: ?*const fn (*anyopaque, std.mem.Allocator) anyerror!void = null,
    state_deinit: ?*const fn (*anyopaque, std.mem.Allocator) void = null,
    contract_section: ?[]const u8 = null,
    sandboxable: bool = false,
    comptime_only: bool = false,
    self_managed_io: bool = false,
};

pub fn validateBindings(comptime bindings: []const ModuleBinding) void {
    // Raised from the 5000 default because the O(n*m) duplicate-name
    // and specifier checks exceed it once the full builtin roster
    // (20+ modules) is validated in one call.
    @setEvalBranchQuota(20000);

    for (bindings) |binding| {
        const builtin_prefix = std.mem.startsWith(u8, binding.specifier, "zttp:");
        const extension_prefix = std.mem.startsWith(u8, binding.specifier, "zttp-ext:");
        if (!builtin_prefix and !extension_prefix) {
            @compileError("module specifier must start with 'zttp:' or 'zttp-ext:': " ++ binding.specifier);
        }

        if (binding.state_init != null and binding.state_deinit == null) {
            @compileError("module has state_init but missing state_deinit: " ++ binding.specifier);
        }
        if (binding.state_init == null and binding.state_deinit != null) {
            @compileError("module has state_deinit but missing state_init: " ++ binding.specifier);
        }
        if (findDuplicateRequiredCapability(binding.required_capabilities)) |capability| {
            @compileError("duplicate required capability '" ++ @tagName(capability) ++ "' in " ++ binding.specifier);
        }
        for (binding.exports) |f| {
            const export_caps = f.required_capabilities orelse continue;
            if (findDuplicateRequiredCapability(export_caps)) |capability| {
                @compileError("duplicate required capability '" ++ @tagName(capability) ++ "' on " ++ binding.specifier ++ "." ++ f.name);
            }
            // An export may narrow its module's authority, never widen it. The
            // module set is what the runtime actually grants, so an export
            // claiming more than it is a binding that lies about the sandbox.
            for (export_caps) |cap| {
                var found = false;
                for (binding.required_capabilities) |mod_cap| {
                    if (mod_cap == cap) found = true;
                }
                if (!found) {
                    @compileError("capability '" ++ @tagName(cap) ++ "' on " ++ binding.specifier ++ "." ++ f.name ++ " is not declared by the module; an export may narrow its module's set, never widen it");
                }
            }
        }
    }

    for (bindings, 0..) |a, i| {
        for (bindings[i + 1 ..]) |b| {
            if (std.mem.eql(u8, a.specifier, b.specifier)) {
                @compileError("duplicate module specifier: " ++ a.specifier);
            }
        }
    }

    for (bindings) |a| {
        for (a.exports, 0..) |af, afi| {
            for (a.exports[afi + 1 ..]) |af2| {
                if (std.mem.eql(u8, af.name, af2.name)) {
                    @compileError("duplicate function name within " ++ a.specifier ++ ": " ++ af.name);
                }
            }
        }
    }
}

fn findDuplicateRequiredCapability(comptime capabilities: []const ModuleCapability) ?ModuleCapability {
    for (capabilities, 0..) |capability, i| {
        for (capabilities[i + 1 ..]) |other| {
            if (capability == other) return capability;
        }
    }
    return null;
}
