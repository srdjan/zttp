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

const descriptors = @import("descriptors.zig");

pub const EffectClass = descriptors.EffectClass;
pub const ReturnKind = descriptors.ReturnKind;
pub const DeclaredSignature = descriptors.DeclaredSignature;
pub const FailureSeverity = descriptors.FailureSeverity;
pub const ModuleCapability = descriptors.ModuleCapability;
pub const ModuleCapabilityError = descriptors.ModuleCapabilityError;
pub const DataLabel = descriptors.DataLabel;
pub const LabelSet = descriptors.LabelSet;
pub const ContractCategory = descriptors.ContractCategory;
pub const ContractTransform = descriptors.ContractTransform;
pub const ContractExtraction = descriptors.ContractExtraction;
pub const ContractFlags = descriptors.ContractFlags;
pub const LawKind = descriptors.LawKind;
pub const AbsorbingPattern = descriptors.AbsorbingPattern;
pub const Law = descriptors.Law;

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
    /// The length must equal `param_types`, so a parameter added without a
    /// name is a compile error rather than a silently shortened list. Both
    /// lists are empty only for a zero-parameter export.
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
    /// that names the labels it discharges in `declassifies`.
    ///
    /// The declassification holds only while that argument is a compile-time
    /// literal. `mask(text, visible)` reveals the trailing `visible` bytes, so
    /// a runtime `visible` lets whatever computes it decide how much of the
    /// secret survives: `mask(env("SECRET_KEY"), bytesLength(requestBody(req)))`
    /// is request-controlled declassification. With a non-literal bound the
    /// analyzer keeps the input's labels, and the ordinary sink diagnostic
    /// reports the secret reaching the response.
    declassify_bound_arg: ?u8 = null,
    /// The labels this export discharges from its input, and only these. The
    /// result carries every other label of its input, plus `return_labels`.
    ///
    /// `mask(text, visible)` names `secret` and `credential`: making a secret
    /// printable is what it is for, and it leaves `user_input` on the result,
    /// because masked request text is still request text. Declaring
    /// `return_labels` alone would replace the input's labels and discharge all
    /// of them. The set needs `declassify_bound_arg`, and the discharge holds
    /// only while that argument is a compile-time literal.
    declassifies: LabelSet = .{},
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
};

pub fn validateBindings(comptime bindings: []const ModuleBinding) void {
    validateBindingMetadata(bindings);
    for (bindings) |binding| {
        for (binding.exports) |f| {
            if (f.param_names.len != f.param_types.len) {
                @compileError("every parameter must be named: param_names is not parallel to param_types on " ++ binding.specifier ++ "." ++ f.name);
            }
        }
    }
}

/// Checks metadata shared by SDK and engine records. Implementation pointers,
/// analyzer-only labels, signatures and laws keep their boundary-specific checks.
pub fn validateBindingMetadata(comptime bindings: anytype) void {
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

pub fn findDuplicateRequiredCapability(comptime capabilities: []const ModuleCapability) ?ModuleCapability {
    for (capabilities, 0..) |capability, i| {
        for (capabilities[i + 1 ..]) |other| {
            if (capability == other) return capability;
        }
    }
    return null;
}
