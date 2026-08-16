//! Closed compiler-owned catalog of every public diagnostic identity.
//!
//! A diagnostic code is protocol, not presentation text. Every producer maps
//! its typed cause into this catalog, and every row names an explicit family
//! and risk tier. Security gates consume the taxonomy directly instead of
//! guessing from code prefixes or from the smaller policy rule registry.

const std = @import("std");
const engine = @import("zts-engine");
const contracts = @import("zts-contracts");
const bool_checker = @import("bool_checker.zig");
const flow_checker = @import("flow_checker.zig");
const handler_verifier = @import("handler_verifier.zig");
const property_diagnostics = @import("property_diagnostics.zig");
const strict_checker = @import("strict_checker.zig");
const type_checker = @import("type_checker.zig");

pub const ParserKind = engine.parser.ErrorKind;
pub const StripKind = engine.stripper.StripDiagnosticKind;
pub const PrepareSourceKind = engine.source_frontend.PrepareDiagnosticKind;
pub const SpecKind = contracts.handler_contract.SpecDiagnostic.Kind;
pub const PolicyCategory = engine.handler_policy.PolicyCategory;
pub const PolicyViolationKind = engine.handler_policy.ViolationKind;

pub const Producer = enum {
    compiler_driver,
    parser,
    tsx_frontend,
    type_stripper,
    boolean_checker,
    type_checker,
    virtual_import,
    handler_verifier,
    flow_checker,
    strict_checker,
    spec_discharge,
    capability_policy,
    property_analysis,
    semantics_conformance,
};

pub const Family = enum {
    infrastructure,
    syntax,
    source_profile,
    boolean_logic,
    type_safety,
    module_contract,
    control_flow,
    runtime_safety,
    state_isolation,
    sensitive_data_flow,
    untrusted_input_flow,
    proof_contract,
    capability_control,
    workflow_durability,
    canonical_form,
    fault_handling,
    system_contract,
    semantics_conformance,
};

pub const RiskTier = enum {
    advisory,
    correctness,
    security_critical,
};

pub const Entry = struct {
    producer: Producer,
    kind: []const u8,
    code: []const u8,
    family: Family,
    risk: RiskTier,
};

const Metadata = struct {
    code: []const u8,
    family: Family,
    risk: RiskTier,
};

pub const DriverKind = enum {
    compiler_io_failure,
    unsupported_source_extension,
    missing_sql_schema,
};

pub const VirtualImportKind = enum {
    unknown_module,
    missing_export,
};

pub const PolicyKind = enum {
    env_literal_not_allowed,
    env_dynamic_not_allowed,
    egress_literal_not_allowed,
    egress_dynamic_not_allowed,
    cache_literal_not_allowed,
    cache_dynamic_not_allowed,
    sql_literal_not_allowed,
    sql_dynamic_not_allowed,
};

/// Semantic conformance diagnostics retain the existing `.code()` call shape
/// while moving their identity into the common catalog.
pub const SemanticsKind = enum {
    uncovered_node,
    uncovered_opcode,
    unbalanced_lowering,
    lowering_divergence,
    refinement_divergence,
    smt_counterexample,
    smt_unencodable,
    excluded_law_holds,
    audit_solver_error,

    pub fn code(self: SemanticsKind) []const u8 {
        return semanticsCode(self);
    }
};

pub fn driverCode(kind: DriverKind) []const u8 {
    return switch (kind) {
        .compiler_io_failure => "ZTS000",
        .unsupported_source_extension => "ZTS052",
        .missing_sql_schema => "ZTS700",
    };
}

pub fn parserCode(kind: ParserKind) []const u8 {
    return switch (kind) {
        .unsupported_feature => "ZTS001",
        .unexpected_token => "ZTS002",
        .expected_token => "ZTS003",
        .expected_expression => "ZTS004",
        .expected_statement => "ZTS005",
        .expected_identifier => "ZTS006",
        .unexpected_eof => "ZTS007",
        .unterminated_string => "ZTS008",
        .unterminated_template => "ZTS009",
        .unterminated_regex => "ZTS010",
        .unterminated_comment => "ZTS011",
        .invalid_number => "ZTS012",
        .invalid_escape_sequence => "ZTS013",
        .invalid_unicode_escape => "ZTS014",
        .expected_property_name => "ZTS015",
        .invalid_assignment_target => "ZTS016",
        .invalid_destructuring => "ZTS017",
        .duplicate_parameter => "ZTS018",
        .duplicate_binding => "ZTS019",
        .undeclared_variable => "ZTS020",
        .const_without_initializer => "ZTS021",
        .invalid_break => "ZTS022",
        .invalid_continue => "ZTS023",
        .invalid_return => "ZTS024",
        .invalid_yield => "ZTS025",
        .invalid_await => "ZTS026",
        .invalid_super => "ZTS027",
        .too_many_parameters => "ZTS028",
        .too_many_locals => "ZTS029",
        .too_many_upvalues => "ZTS030",
        .too_many_constants => "ZTS031",
        .jump_too_large => "ZTS032",
        .invalid_import => "ZTS037",
        .invalid_export => "ZTS038",
        .duplicate_export => "ZTS039",
        .unexpected_character => "ZTS040",
        .nesting_too_deep => "ZTS044",
        .string_line_continuation => "ZTS045",
        .non_ascii_identifier => "ZTS046",
        .missing_semicolon => "ZTS047",
    };
}

pub fn prepareSourceCode(kind: PrepareSourceKind) []const u8 {
    return switch (kind) {
        .mismatched_tag => "ZTS033",
        .invalid_attribute => "ZTS034",
        .unclosed_element => "ZTS035",
        .expression_expected => "ZTS036",
    };
}

pub fn stripCode(kind: StripKind) []const u8 {
    return switch (kind) {
        .any_type => "ZTS041",
        .as_assertion => "ZTS042",
        .satisfies_assertion => "ZTS043",
        .nominal_base_not_scalar => "ZTS048",
        .interface_declaration => "ZTS049",
        .type_alias_declaration => "ZTS050",
        .distinct_type_declaration => "ZTS051",
        .legacy_types_import => "ZTS053",
        .default_parameter => "ZTS054",
        .optional_parameter => "ZTS055",
        .default_export => "ZTS056",
        .mutable_export => "ZTS057",
        .array_type_alias => "ZTS058",
        .readonly_array_type_alias => "ZTS059",
        .void_type => "ZTS060",
        .unterminated_string => "ZTS008",
    };
}

pub fn booleanCode(kind: bool_checker.DiagnosticKind) []const u8 {
    return switch (kind) {
        .condition_not_boolean => "ZTS100",
        .logical_operand_not_boolean => "ZTS101",
        .not_operand_not_boolean => "ZTS102",
        .nullish_on_non_nullable => "ZTS103",
        .arithmetic_on_non_numeric => "ZTS104",
        .add_on_non_addable => "ZTS106",
        .tautological_comparison => "ZTS107",
    };
}

pub fn typeCode(kind: type_checker.DiagnosticKind) []const u8 {
    return switch (kind) {
        .type_mismatch => "ZTS200",
        .missing_field => "ZTS201",
        .arg_count_mismatch => "ZTS202",
        .arg_type_mismatch => "ZTS203",
        .return_type_mismatch => "ZTS204",
        .non_exhaustive_match => "ZTS205",
        .ambiguous_type_argument => "ZTS208",
        .type_constraint_violation => "ZTS209",
        .type_argument_count_mismatch => "ZTS210",
        .invalid_type_predicate => "ZTS211",
        .non_contractive_alias => "ZTS212",
        .unencodable_json_payload => "ZTS213",
        .string_add => "ZTS105",
        .nominal_constructor_call => "ZTS214",
        .readonly_mutation => "ZTS215",
    };
}

pub fn virtualImportCode(kind: VirtualImportKind) []const u8 {
    return switch (kind) {
        .unknown_module => "ZTS206",
        .missing_export => "ZTS207",
    };
}

pub fn verifierCode(kind: handler_verifier.DiagnosticKind) []const u8 {
    return switch (kind) {
        .missing_return_else => "ZTS300",
        .missing_return_default => "ZTS301",
        .missing_return_path => "ZTS302",
        .unchecked_result_value => "ZTS303",
        .unreachable_after_return => "ZTS304",
        .unused_variable => "ZTS305",
        .unused_import => "ZTS306",
        .non_exhaustive_match => "ZTS307",
        .unchecked_optional_use => "ZTS308",
        .unchecked_optional_access => "ZTS309",
        .module_scope_mutation => "ZTS310",
        .spec_not_discharged => "ZTS500",
        .spec_incompatible_with_import => "ZTS501",
        .spec_unknown_name => "ZTS502",
    };
}

pub fn flowCode(kind: flow_checker.DiagnosticKind) []const u8 {
    return switch (kind) {
        .secret_in_response => "ZTS400",
        .credential_in_response => "ZTS401",
        .secret_in_log => "ZTS402",
        .credential_in_log => "ZTS403",
        .secret_in_egress_url => "ZTS404",
        .credential_in_egress_url => "ZTS405",
        .secret_in_egress_body => "ZTS406",
        .unvalidated_input_in_egress => "ZTS407",
    };
}

pub fn strictCode(kind: strict_checker.DiagnosticKind) []const u8 {
    return switch (kind) {
        .implicit_unknown => "ZTS600",
        .unpublished_ambient_global => "ZTS629",
        .missing_public_annotation => "ZTS601",
        .dynamic_capability_access => "ZTS602",
        .non_exhaustive_profile_match => "ZTS603",
        .avoidable_let => "ZTS604",
        .computed_property_access => "ZTS605",
        .raw_exported_boundary_type => "ZTS061",
        .canonical_arrow_helper => "ZTS608",
        .canonical_export_function_const => "ZTS609",
        .canonical_public_helper_effects => "ZTS610",
        .canonical_public_helper_proof => "ZTS611",
        .canonical_ternary_impure => "ZTS612",
        .canonical_compound_assignment => "ZTS613",
        .canonical_non_leading_spread => "ZTS614",
        .canonical_call_spread => "ZTS616",
        .canonical_redundant_bool_compare => "ZTS620",
        .canonical_ternary_chain => "ZTS621",
        .mutable_live_iteration => "ZTS622",
        .canonical_internal_helper_effects => "ZTS623",
        .nullish_operator_on_null => "ZTS624",
        .canonical_redundant_pattern_rename => "ZTS625",
        .canonical_unbound_field_read => "ZTS626",
        .canonical_dict_entry_round_trip => "ZTS627",
        .canonical_dict_entries_reduce => "ZTS628",
    };
}

pub fn specCode(kind: SpecKind) []const u8 {
    return switch (kind) {
        .not_discharged => "ZTS500",
        .incompatible_with_import => "ZTS501",
        .unknown_name => "ZTS502",
        .missing_capsule => "ZTS606",
        .effect_undeclared => "ZTS503",
        .effect_unknown_capability => "ZTS504",
        .effect_over_declared => "ZTS505",
        .budget_exceeded => "ZTS506",
        .helper_budget_exceeded => "ZTS607",
        .missing_proof_capsule_export => "ZTS508",
        .workflow_call_in_step => "ZTS509",
        .saga_step_missing_compensate => "ZTS510",
        .effect_ceiling_not_literal => "ZTS511",
        .effect_row_lower_bound => "ZTS512",
    };
}

pub fn policyCode(kind: PolicyKind) []const u8 {
    return switch (kind) {
        .env_literal_not_allowed => "POL001",
        .env_dynamic_not_allowed => "POL002",
        .egress_literal_not_allowed => "POL003",
        .egress_dynamic_not_allowed => "POL004",
        .cache_literal_not_allowed => "POL005",
        .cache_dynamic_not_allowed => "POL006",
        .sql_literal_not_allowed => "POL007",
        .sql_dynamic_not_allowed => "POL008",
    };
}

pub fn policyKind(category: PolicyCategory, kind: PolicyViolationKind) PolicyKind {
    return switch (category) {
        .env => switch (kind) {
            .literal_not_allowed => .env_literal_not_allowed,
            .dynamic_not_allowed => .env_dynamic_not_allowed,
        },
        .egress => switch (kind) {
            .literal_not_allowed => .egress_literal_not_allowed,
            .dynamic_not_allowed => .egress_dynamic_not_allowed,
        },
        .cache => switch (kind) {
            .literal_not_allowed => .cache_literal_not_allowed,
            .dynamic_not_allowed => .cache_dynamic_not_allowed,
        },
        .sql => switch (kind) {
            .literal_not_allowed => .sql_literal_not_allowed,
            .dynamic_not_allowed => .sql_dynamic_not_allowed,
        },
    };
}

pub fn propertyCode(kind: property_diagnostics.ViolationKind) []const u8 {
    return switch (kind) {
        .fault_uncovered => "PROP01",
        .injection_unsafe => "PROP02",
        .secret_leakage => "PROP03",
        .credential_leakage => "PROP04",
        .result_unsafe => "PROP05",
        .optional_unchecked => "PROP06",
    };
}

pub fn semanticsCode(kind: SemanticsKind) []const u8 {
    return switch (kind) {
        .uncovered_node => "ZTS750",
        .uncovered_opcode => "ZTS751",
        .unbalanced_lowering => "ZTS752",
        .lowering_divergence => "ZTS753",
        .refinement_divergence => "ZTS754",
        .smt_counterexample => "ZTS755",
        .smt_unencodable => "ZTS756",
        .excluded_law_holds => "ZTS757",
        .audit_solver_error => "ZTS758",
    };
}

fn driverMetadata(kind: DriverKind) Metadata {
    return .{
        .code = driverCode(kind),
        .family = switch (kind) {
            .compiler_io_failure => .infrastructure,
            .unsupported_source_extension => .source_profile,
            .missing_sql_schema => .system_contract,
        },
        .risk = .correctness,
    };
}

fn parserMetadata(kind: ParserKind) Metadata {
    return .{
        .code = parserCode(kind),
        .family = switch (kind) {
            .unsupported_feature,
            .string_line_continuation,
            .non_ascii_identifier,
            .missing_semicolon,
            => .source_profile,
            else => .syntax,
        },
        .risk = .correctness,
    };
}

fn prepareSourceMetadata(kind: PrepareSourceKind) Metadata {
    return .{ .code = prepareSourceCode(kind), .family = .syntax, .risk = .correctness };
}

fn stripMetadata(kind: StripKind) Metadata {
    return .{
        .code = stripCode(kind),
        .family = if (kind == .unterminated_string) .syntax else .source_profile,
        .risk = .correctness,
    };
}

fn booleanMetadata(kind: bool_checker.DiagnosticKind) Metadata {
    return .{ .code = booleanCode(kind), .family = .boolean_logic, .risk = .correctness };
}

fn typeMetadata(kind: type_checker.DiagnosticKind) Metadata {
    return .{
        .code = typeCode(kind),
        .family = switch (kind) {
            .unencodable_json_payload => .runtime_safety,
            .readonly_mutation => .state_isolation,
            else => .type_safety,
        },
        .risk = .correctness,
    };
}

fn virtualImportMetadata(kind: VirtualImportKind) Metadata {
    return .{ .code = virtualImportCode(kind), .family = .module_contract, .risk = .correctness };
}

fn verifierMetadata(kind: handler_verifier.DiagnosticKind) Metadata {
    return .{
        .code = verifierCode(kind),
        .family = switch (kind) {
            .missing_return_else,
            .missing_return_default,
            .missing_return_path,
            .unreachable_after_return,
            .non_exhaustive_match,
            => .control_flow,
            .unchecked_result_value,
            .unchecked_optional_use,
            .unchecked_optional_access,
            => .runtime_safety,
            .module_scope_mutation => .state_isolation,
            .spec_not_discharged,
            .spec_incompatible_with_import,
            .spec_unknown_name,
            => .proof_contract,
            .unused_variable, .unused_import => .canonical_form,
        },
        .risk = if (kind == .module_scope_mutation) .security_critical else .correctness,
    };
}

fn flowMetadata(kind: flow_checker.DiagnosticKind) Metadata {
    return .{
        .code = flowCode(kind),
        .family = switch (kind) {
            .unvalidated_input_in_egress => .untrusted_input_flow,
            else => .sensitive_data_flow,
        },
        .risk = .security_critical,
    };
}

fn strictMetadata(kind: strict_checker.DiagnosticKind) Metadata {
    const security = switch (kind) {
        .unpublished_ambient_global,
        .dynamic_capability_access,
        .canonical_public_helper_effects,
        => true,
        else => false,
    };
    return .{
        .code = strictCode(kind),
        .family = switch (kind) {
            .unpublished_ambient_global,
            .dynamic_capability_access,
            .canonical_public_helper_effects,
            => .capability_control,
            .implicit_unknown,
            .missing_public_annotation,
            .computed_property_access,
            .raw_exported_boundary_type,
            => .type_safety,
            .non_exhaustive_profile_match => .control_flow,
            .mutable_live_iteration => .state_isolation,
            .nullish_operator_on_null => .runtime_safety,
            else => .canonical_form,
        },
        .risk = if (security) .security_critical else .correctness,
    };
}

fn specMetadata(kind: SpecKind) Metadata {
    const capability = switch (kind) {
        .effect_undeclared,
        .effect_unknown_capability,
        .budget_exceeded,
        .helper_budget_exceeded,
        .effect_ceiling_not_literal,
        .effect_row_lower_bound,
        => true,
        else => false,
    };
    return .{
        .code = specCode(kind),
        .family = switch (kind) {
            .effect_undeclared,
            .effect_unknown_capability,
            .effect_over_declared,
            .budget_exceeded,
            .helper_budget_exceeded,
            .effect_ceiling_not_literal,
            .effect_row_lower_bound,
            => .capability_control,
            .workflow_call_in_step, .saga_step_missing_compensate => .workflow_durability,
            else => .proof_contract,
        },
        .risk = if (capability) .security_critical else switch (kind) {
            .effect_over_declared, .missing_proof_capsule_export => .advisory,
            else => .correctness,
        },
    };
}

fn policyMetadata(kind: PolicyKind) Metadata {
    return .{ .code = policyCode(kind), .family = .capability_control, .risk = .security_critical };
}

fn propertyMetadata(kind: property_diagnostics.ViolationKind) Metadata {
    return .{
        .code = propertyCode(kind),
        .family = switch (kind) {
            .fault_uncovered => .fault_handling,
            .injection_unsafe => .untrusted_input_flow,
            .secret_leakage, .credential_leakage => .sensitive_data_flow,
            .result_unsafe, .optional_unchecked => .runtime_safety,
        },
        .risk = switch (kind) {
            .injection_unsafe,
            .secret_leakage,
            .credential_leakage,
            => .security_critical,
            else => .correctness,
        },
    };
}

fn semanticsMetadata(kind: SemanticsKind) Metadata {
    return .{ .code = semanticsCode(kind), .family = .semantics_conformance, .risk = .correctness };
}

fn enumEntries(
    comptime Kind: type,
    comptime producer: Producer,
    comptime metadataFn: anytype,
) [@typeInfo(Kind).@"enum".fields.len]Entry {
    const fields = @typeInfo(Kind).@"enum".fields;
    var result: [fields.len]Entry = undefined;
    for (fields, 0..) |field, index| {
        const kind: Kind = @enumFromInt(field.value);
        const metadata = metadataFn(kind);
        result[index] = .{
            .producer = producer,
            .kind = field.name,
            .code = metadata.code,
            .family = metadata.family,
            .risk = metadata.risk,
        };
    }
    return result;
}

const driver_entries = enumEntries(DriverKind, .compiler_driver, driverMetadata);
const parser_entries = enumEntries(ParserKind, .parser, parserMetadata);
const prepare_source_entries = enumEntries(PrepareSourceKind, .tsx_frontend, prepareSourceMetadata);
const strip_entries = enumEntries(StripKind, .type_stripper, stripMetadata);
const boolean_entries = enumEntries(bool_checker.DiagnosticKind, .boolean_checker, booleanMetadata);
const type_entries = enumEntries(type_checker.DiagnosticKind, .type_checker, typeMetadata);
const virtual_import_entries = enumEntries(VirtualImportKind, .virtual_import, virtualImportMetadata);
const verifier_entries = enumEntries(handler_verifier.DiagnosticKind, .handler_verifier, verifierMetadata);
const flow_entries = enumEntries(flow_checker.DiagnosticKind, .flow_checker, flowMetadata);
const strict_entries = enumEntries(strict_checker.DiagnosticKind, .strict_checker, strictMetadata);
const spec_entries = enumEntries(SpecKind, .spec_discharge, specMetadata);
const policy_entries = enumEntries(PolicyKind, .capability_policy, policyMetadata);
const property_entries = enumEntries(property_diagnostics.ViolationKind, .property_analysis, propertyMetadata);
const semantics_entries = enumEntries(SemanticsKind, .semantics_conformance, semanticsMetadata);

const total_count = driver_entries.len + parser_entries.len + prepare_source_entries.len +
    strip_entries.len + boolean_entries.len + type_entries.len + virtual_import_entries.len +
    verifier_entries.len + flow_entries.len + strict_entries.len + spec_entries.len +
    policy_entries.len + property_entries.len + semantics_entries.len;

pub const all_entries: [total_count]Entry = blk: {
    var result: [total_count]Entry = undefined;
    var index: usize = 0;
    for (.{
        driver_entries,
        parser_entries,
        prepare_source_entries,
        strip_entries,
        boolean_entries,
        type_entries,
        virtual_import_entries,
        verifier_entries,
        flow_entries,
        strict_entries,
        spec_entries,
        policy_entries,
        property_entries,
        semantics_entries,
    }) |producer_entries| {
        for (producer_entries) |entry| {
            result[index] = entry;
            index += 1;
        }
    }
    break :blk result;
};

pub fn entries() []const Entry {
    return &all_entries;
}

pub fn findByCode(code: []const u8) ?*const Entry {
    for (&all_entries) |*entry| {
        if (std.mem.eql(u8, entry.code, code)) return entry;
    }
    return null;
}

fn hashField(hasher: *std.crypto.hash.sha2.Sha256, bytes: []const u8) void {
    var length: [8]u8 = undefined;
    std.mem.writeInt(u64, &length, @intCast(bytes.len), .big);
    hasher.update(&length);
    hasher.update(bytes);
}

pub fn catalogHash() [64]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hashField(&hasher, "zts-diagnostic-catalog-v1");
    for (&all_entries) |*entry| {
        hashField(&hasher, @tagName(entry.producer));
        hashField(&hasher, entry.kind);
        hashField(&hasher, entry.code);
        hashField(&hasher, @tagName(entry.family));
        hashField(&hasher, @tagName(entry.risk));
    }
    return std.fmt.bytesToHex(hasher.finalResult(), .lower);
}

test "diagnostic catalog is nonempty exhaustive and deterministic" {
    try std.testing.expect(all_entries.len >= 100);
    const first = catalogHash();
    const second = catalogHash();
    try std.testing.expectEqualStrings(&first, &second);
    try std.testing.expectEqual(@as(usize, 64), first.len);
}

test "only explicitly shared semantic faults have multiple producers" {
    const shared_codes = [_][]const u8{ "ZTS008", "ZTS500", "ZTS501", "ZTS502" };
    var duplicate_count: usize = 0;
    for (all_entries, 0..) |entry, index| {
        for (all_entries[index + 1 ..]) |other| {
            if (!std.mem.eql(u8, entry.code, other.code)) continue;
            duplicate_count += 1;
            var explicitly_shared = false;
            for (shared_codes) |code| {
                if (std.mem.eql(u8, code, entry.code)) explicitly_shared = true;
            }
            try std.testing.expect(explicitly_shared);
            try std.testing.expectEqual(entry.family, other.family);
            try std.testing.expectEqual(entry.risk, other.risk);
        }
    }
    try std.testing.expectEqual(shared_codes.len, duplicate_count);
}

test "lower contract tier spec codes match the compiler catalog" {
    inline for (@typeInfo(SpecKind).@"enum".fields) |field| {
        const kind: SpecKind = @enumFromInt(field.value);
        try std.testing.expectEqualStrings(kind.code(), specCode(kind));
    }
}

test "policy category pairs cover every catalog policy kind exactly once" {
    var seen = [_]bool{false} ** @typeInfo(PolicyKind).@"enum".fields.len;
    inline for (@typeInfo(PolicyCategory).@"enum".fields) |category_field| {
        const category: PolicyCategory = @enumFromInt(category_field.value);
        inline for (@typeInfo(PolicyViolationKind).@"enum".fields) |violation_field| {
            const violation: PolicyViolationKind = @enumFromInt(violation_field.value);
            const kind = policyKind(category, violation);
            const index: usize = @intFromEnum(kind);
            try std.testing.expect(!seen[index]);
            seen[index] = true;
        }
    }
    for (seen) |present| try std.testing.expect(present);
}

test "every security-critical family has catalog entries" {
    const critical_families = [_]Family{
        .state_isolation,
        .sensitive_data_flow,
        .untrusted_input_flow,
        .capability_control,
    };
    for (critical_families) |family| {
        var found = false;
        for (all_entries) |entry| {
            if (entry.family == family and entry.risk == .security_critical) found = true;
        }
        try std.testing.expect(found);
    }
}
