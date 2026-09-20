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

/// A signature spelled in source text, one entry per parameter plus the
/// return. Set it when the coarse `ReturnKind` cannot name the export's type -
/// a literal union, a record, or a named ABI type.
pub const DeclaredSignature = struct {
    params: []const []const u8,
    returns: []const u8,
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
};

pub const ModuleCapabilityError = error{
    MissingModuleCapability,
    ClockUnavailable,
    StderrWriteFailed,
    RandomUnavailable,
};

pub const DataLabel = enum(u4) {
    secret,
    credential,
    user_input,
    config,
    internal,
    external,
    validated,
    nondeterministic,
    unknown,
};

/// The provenance labels an extension can declare on a return value. Mirrors
/// the analyzer's own set field for field; the adapter maps them across by name
/// rather than by bit pattern, so the two widths need not agree.
///
/// `unknown` is the one label that is not a data-sensitivity class. It is the
/// claim that provenance could not be followed, and the analyzer assigns it
/// wherever its own walk gives up. A binding declares it for the shape the
/// analyzer cannot see at all: an export that reads persistent cross-call
/// state - a cache, a queue, a SQL table, a durable signal - and hands back a
/// value some separate write put there. The read call holds no reference to
/// that value, so no dataflow rule can reach it and only the binding knows. A
/// store read that declared a benign label instead reported
/// `no_secret_leakage` PROVEN for a secret round-tripped through the store.
pub const LabelSet = packed struct(u16) {
    secret: bool = false,
    credential: bool = false,
    user_input: bool = false,
    config: bool = false,
    internal: bool = false,
    external: bool = false,
    validated: bool = false,
    nondeterministic: bool = false,
    /// Provenance the checker could not follow: proves nothing. Distinct from
    /// the empty set, which is the positive claim that a value carries
    /// nothing.
    unknown: bool = false,
    _reserved: u7 = 0,

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
    /// What each parameter position means, in order, parallel to
    /// `param_types`. A kind says a parameter is a string; only a name says
    /// which string. `sqlMany(string, object)` is what discovery published
    /// before this field, and a model reading it wrote a SELECT statement into
    /// the slot that takes a registered query name - which compiles, and fails
    /// at runtime. `sqlMany(name, params)` is the whole fix for that case.
    ///
    /// Empty means undeclared, which `validateBindings` permits only while the
    /// roster is being filled. When present the length must equal
    /// `param_types`, so a parameter added without a name is a compile error
    /// rather than a silently shortened list.
    param_names: []const []const u8 = &.{},
    /// Argument positions whose type must be JSON-encodable, checked by the
    /// same rule `Response.json` runs. An export that serializes an argument
    /// to the wire owes its caller the diagnostic at the call site rather than
    /// a throw inside the encoder, and this is how it says which argument.
    json_encodable_args: []const u8 = &.{},

    /// The precise signature, when the coarse kinds above cannot spell it.
    signature: ?DeclaredSignature = null,
    traceable: bool = true,
    /// Safe to execute live during replay/`serve --test` when no recorded I/O
    /// entry matches: result depends only on arguments and in-process setup,
    /// with no host/external or non-deterministic read. Explicit, audited
    /// opt-in (stronger than `Law.pure`); default false keeps it replay-stubbed.
    replay_pure: bool = false,
    contract_extractions: []const ContractExtraction = &.{},
    contract_flags: ContractFlags = .{},
    return_labels: LabelSet = .{},

    /// The argument that bounds how much this export declassifies. Set only on
    /// an export whose purpose is to make a labelled value publishable, and
    /// whose declared labels therefore replace its input's instead of joining
    /// them.
    ///
    /// The declassification holds only while that argument is a compile-time
    /// literal. `mask(text, visible)` reveals the trailing `visible` bytes, so
    /// a runtime `visible` lets whatever computes it decide how much of the
    /// secret survives: `mask(env("SECRET_KEY"), bytesLength(requestBody(req)))`
    /// is request-controlled declassification. With a non-literal bound the
    /// analyzer keeps the input's labels, and the ordinary sink diagnostic
    /// reports the secret reaching the response.
    declassify_bound_arg: ?u8 = null,
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
    /// One line saying how the module is used, for the protocol a per-export
    /// signature cannot carry. `zttp:sql` is the case that earned it: every
    /// export reads correctly on its own, and the fact that a statement must
    /// be registered with `sql(name, statement)` before any of the others can
    /// execute it lives between them, not in any one of them.
    ///
    /// Optional on purpose, unlike `param_names`. A parameter always exists,
    /// so an unnamed one is missing information and the compiler demands it.
    /// A protocol beyond the signatures often does not exist, and saying so by
    /// declaring nothing is the honest answer - most modules are fully
    /// described by named signatures alone.
    ///
    /// Declaring one is not free. Every summary is bytes in every `modules`
    /// and `meta` response, repeatedly, in exactly the cases that loop: filling
    /// all 26 doubled the discovery payload from 7,213 to 14,616 bytes.
    /// Measured, not estimated. So declare one only where a caller would get
    /// the module wrong without it, and keep it to the sentence they need
    /// before the first call. It is not documentation.
    summary: []const u8 = "",
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
            // Equality, not "empty or parallel". While the roster was being
            // filled, an unnamed export was permitted - and that permission is
            // the shape AGENTS.md warns about, because partial coverage looks
            // exactly like full coverage from here. Now every parameter must be
            // named: a zero-parameter export satisfies this with two empty
            // lists, and a parameter added later without a name is a compile
            // error at the binding rather than a gap in what discovery says.
            //
            // Checked before the capability `orelse continue` below, so an
            // export that inherits its module's set is still checked here.
            if (f.param_names.len != f.param_types.len) {
                @compileError("every parameter must be named: param_names is not parallel to param_types on " ++ binding.specifier ++ "." ++ f.name);
            }
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
