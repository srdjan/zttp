//! Pure module metadata. No handles, engine values, or implementation callbacks.

const std = @import("std");

pub const EffectClass = enum {
    read,
    write,
    none,

    pub fn toString(self: EffectClass) []const u8 {
        return @tagName(self);
    }
};

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

/// The provenance labels an extension can declare on a return value. The
/// analyzer keeps additional private facts, so the adapter maps declared labels
/// by name and never interprets this set's reserved bits as analyzer facts.
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
    schema_compile,
    request_schema,
    route_pattern,
    cookie_name,
    cors_origin,
    rate_limit_key,
    fetch_host,
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

/// The semantic fields of an export, independent of how it is implemented.
/// Projection reads declaration values rather than applying these defaults, so
/// null capability inheritance stays distinct from an explicitly empty set.
pub const FunctionDescriptor = struct {
    name: []const u8,
    arg_count: u8,
    required_arg_count: ?u8 = null,
    effect: EffectClass = .read,
    required_capabilities: ?[]const ModuleCapability = null,
    returns: ReturnKind = .unknown,
    param_types: []const ReturnKind = &.{},
    param_names: []const []const u8 = &.{},
    json_encodable_args: []const u8 = &.{},
    signature: ?DeclaredSignature = null,
    traceable: bool = true,
    replay_pure: bool = false,
    contract_extractions: []const ContractExtraction = &.{},
    contract_flags: ContractFlags = .{},
    return_labels: LabelSet = .{},
    declassify_bound_arg: ?u8 = null,
    declassifies: LabelSet = .{},
    derives_from_args: bool = false,
    failure_severity: FailureSeverity = .none,
    laws: []const Law = &.{},
};

pub const ModuleDescriptor = struct {
    specifier: []const u8,
    name: []const u8,
    exports: []const FunctionDescriptor,
    summary: []const u8 = "",
    required_capabilities: []const ModuleCapability = &.{},
    stateful: bool = false,
    contract_section: ?[]const u8 = null,
    sandboxable: bool = false,
};

pub const ExportDescriptor = struct {
    module: *const ModuleDescriptor,
    function: *const FunctionDescriptor,
};

/// Project one existing declaration. Callback fields are explicitly excluded;
/// every other source field must be represented, and every descriptor field
/// must have a source. Adding metadata cannot silently leave this view behind.
pub fn describeFunction(comptime binding: anytype) FunctionDescriptor {
    @setEvalBranchQuota(20_000);
    const callbacks: []const []const u8 = if (@hasField(@TypeOf(binding), "func"))
        &.{ "func", "module_func" }
    else
        &.{"module_func"};
    comptime requireCoverage(@TypeOf(binding), FunctionDescriptor, callbacks);
    var result: FunctionDescriptor = undefined;
    inline for (std.meta.fields(FunctionDescriptor)) |field| {
        if (comptime std.mem.eql(u8, field.name, "return_labels") or
            std.mem.eql(u8, field.name, "declassifies"))
        {
            @field(result, field.name) = projectLabels(@field(binding, field.name));
        } else {
            @field(result, field.name) = @field(binding, field.name);
        }
    }
    return result;
}

fn describeFunctions(comptime bindings: anytype) [bindings.len]FunctionDescriptor {
    var result: [bindings.len]FunctionDescriptor = undefined;
    for (bindings, 0..) |binding, index| result[index] = describeFunction(binding);
    return result;
}

pub fn describeModule(comptime binding: anytype) ModuleDescriptor {
    @setEvalBranchQuota(200_000);
    comptime requireCoverage(@TypeOf(binding), ModuleDescriptor, &.{ "state_init", "state_deinit" });
    const exports = comptime describeFunctions(binding.exports);
    var result: ModuleDescriptor = undefined;
    inline for (std.meta.fields(ModuleDescriptor)) |field| {
        if (comptime std.mem.eql(u8, field.name, "exports")) {
            @field(result, field.name) = &exports;
        } else {
            @field(result, field.name) = @field(binding, field.name);
        }
    }
    return result;
}

pub fn describeModules(comptime bindings: anytype) [bindings.len]ModuleDescriptor {
    @setEvalBranchQuota(200_000);
    var result: [bindings.len]ModuleDescriptor = undefined;
    for (bindings, 0..) |binding, index| result[index] = describeModule(binding);
    return result;
}

fn projectLabels(comptime labels: anytype) LabelSet {
    comptime requireCoverage(@TypeOf(labels), LabelSet, &.{});
    var result: LabelSet = undefined;
    inline for (std.meta.fields(LabelSet)) |field| @field(result, field.name) = @field(labels, field.name);
    return result;
}

fn requireCoverage(comptime Source: type, comptime Target: type, comptime excluded: []const []const u8) void {
    if (coverageProblem(Source, Target, excluded)) |problem| @compileError(problem);
}

fn coverageProblem(comptime Source: type, comptime Target: type, comptime excluded: []const []const u8) ?[]const u8 {
    for (std.meta.fields(Source)) |field| {
        if (@hasField(Target, field.name)) continue;
        var classified = false;
        for (excluded) |name| {
            if (std.mem.eql(u8, name, field.name)) classified = true;
        }
        if (!classified) return "unclassified descriptor source field: " ++ field.name;
    }
    for (std.meta.fields(Target)) |field| {
        if (!@hasField(Source, field.name)) return "descriptor field has no source: " ++ field.name;
    }
    for (excluded) |name| {
        if (!@hasField(Source, name)) return "descriptor exclusion has no source: " ++ name;
        if (@hasField(Target, name)) return "descriptor field is also excluded: " ++ name;
    }
    return null;
}

test "descriptor coverage refuses unclassified fields and missing sources" {
    const Metadata = struct { name: []const u8 };
    const Declaration = struct { name: []const u8, callback: ?*const fn () void };
    const Added = struct { name: []const u8, callback: ?*const fn () void, new_semantics: bool };
    const Missing = struct { callback: ?*const fn () void };
    try std.testing.expect(comptime coverageProblem(Declaration, Metadata, &.{"callback"}) == null);
    try std.testing.expectEqualStrings("unclassified descriptor source field: new_semantics", comptime coverageProblem(Added, Metadata, &.{"callback"}).?);
    try std.testing.expectEqualStrings("descriptor field has no source: name", comptime coverageProblem(Missing, Metadata, &.{"callback"}).?);
    try std.testing.expectEqualStrings("descriptor exclusion has no source: absent", comptime coverageProblem(Declaration, Metadata, &.{ "callback", "absent" }).?);
    try std.testing.expectEqualStrings("descriptor field is also excluded: name", comptime coverageProblem(Declaration, Metadata, &.{ "callback", "name" }).?);
}

test "descriptor records carry metadata without runtime callbacks" {
    inline for (.{ FunctionDescriptor, ModuleDescriptor, ExportDescriptor }) |T| {
        try std.testing.expect(!@hasField(T, "func"));
        try std.testing.expect(!@hasField(T, "module_func"));
        try std.testing.expect(!@hasField(T, "state_init"));
        try std.testing.expect(!@hasField(T, "state_deinit"));
    }
}
