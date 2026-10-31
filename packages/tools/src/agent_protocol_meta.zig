//! Agent protocol `meta`, `features`, `restrictions`, `describe_rule`, and `modules` payloads.

const std = @import("std");
const zts = @import("zts");
const agent_identity = @import("agent_identity.zig");
const module_graph_record = @import("module_graph_record.zig");
const expert_meta = @import("expert_meta.zig");
const edit_simulate = @import("edit_simulate.zig");
const json_diagnostics = @import("json_diagnostics.zig");
const canonicalize = @import("canonicalize.zig");
const example_registry = @import("example_registry.zig");
const decision_registry = @import("decision_registry.zig");
const policy_catalog = zts.PolicyCatalog;
const idiomCatalog = zts.IdiomCatalog;
const restrictionCatalog = zts.RestrictionCatalog;
const repairPolicy = zts.RepairPolicy;
const moduleMetadata = zts.ModuleMetadata;
const testing = std.testing;
const envelope_mod = @import("agent_protocol_envelope.zig");
const operations = envelope_mod.operations;
const specFor = envelope_mod.specFor;
const ErrorCode = envelope_mod.ErrorCode;
const verify_mod = @import("agent_protocol_verify.zig");
const writeStringArray = verify_mod.writeStringArray;
const deferred_sections = envelope_mod.deferred_sections;
const support_mod = @import("agent_protocol_support.zig");
const respond = support_mod.respond;
const parse = support_mod.parse;
const Operation = envelope_mod.Operation;
const ChangingRootReader = support_mod.ChangingRootReader;
const respondWithRootSourceReader = support_mod.respondWithRootSourceReader;

// ---------------------------------------------------------------------------
// meta
// ---------------------------------------------------------------------------

const MetaView = enum { bootstrap, full };

pub fn parseMetaView(input: std.json.Value) error{InvalidMetaView}!MetaView {
    const view = switch (input) {
        .null => return .full,
        .object => |object| object.get("view") orelse return .full,
        else => return error.InvalidMetaView,
    };
    if (view != .string) return error.InvalidMetaView;
    return std.meta.stringToEnum(MetaView, view.string) orelse error.InvalidMetaView;
}

pub fn writeMetaPayload(json: *std.json.Stringify, view: MetaView) !bool {
    return switch (view) {
        .bootstrap => writeBootstrapMetaPayload(json),
        .full => writeFullMetaPayload(json),
    };
}

fn writeOperationCatalog(json: *std.json.Stringify, include_payload_fields: bool) !void {
    try json.beginArray();
    for (&operations) |*spec| {
        try json.beginObject();
        try json.objectField("id");
        try json.write(@tagName(spec.op));
        try json.objectField("status");
        try json.write(@tagName(spec.status));
        try json.objectField("input_fields");
        try json.beginArray();
        for (spec.input_fields) |f| try json.write(f);
        try json.endArray();
        if (include_payload_fields) {
            try json.objectField("payload_fields");
            try json.beginArray();
            for (spec.payload_fields) |f| try json.write(f);
            try json.endArray();
            try json.objectField("deferred_note");
            if (spec.deferred_note) |n| try json.write(n) else try json.write(null);
        }
        try json.endObject();
    }
    try json.endArray();
}

fn writeBootstrapMetaPayload(json: *std.json.Stringify) !bool {
    try json.beginObject();
    try json.objectField("view");
    try json.write("bootstrap");
    try json.objectField("compiler_version");
    try json.write(expert_meta.compiler_version);
    try json.objectField("profile_id");
    try json.write(agent_identity.profile_id);
    try json.objectField("policy_version");
    try json.write(expert_meta.policy_version);
    try json.objectField("policy_hash");
    try json.write(&zts.policyHash());
    try json.objectField("grammar_hash");
    try json.write(&zts.grammarHash());
    try json.objectField("idiom_table_hash");
    try json.write(&zts.idiomTableHash());
    try json.objectField("restriction_matrix_hash");
    try json.write(&zts.restrictionMatrixHash());
    try json.objectField("builtin_registry_hash");
    try json.write(&moduleMetadata.builtinRegistryHash());
    try json.objectField("example_registry_hash");
    try json.write(&example_registry.catalogHash());
    try json.objectField("operations");
    try writeOperationCatalog(json, false);
    try json.objectField("full_meta_request");
    try json.beginObject();
    try json.objectField("operation");
    try json.write("meta");
    try json.objectField("input");
    try json.beginObject();
    try json.objectField("view");
    try json.write("full");
    try json.endObject();
    try json.endObject();
    try json.objectField("full_meta_sections");
    try json.beginArray();
    for (specFor(.meta).payload_fields) |field| try json.write(field);
    try json.endArray();
    try json.endObject();
    return true;
}

/// Emit what an export answers with.
///
/// Discovery published a name, an effect, and (since parameter names landed)
/// what each argument means - and nothing at all about the return. A model had
/// no way to learn that `sqlMany` answers an array rather than a Result.
///
/// The declared signature wins when an export has one, because that is what the
/// checker enforces. Everything else renders the coarse kind through the same
/// `jsTypeName` that the rest of the surface uses.
///
/// This is deliberately NOT the `returns` field in `zts modules --json`, which
/// stays a `ReturnKind` name: `module_manifest.zig:267` parses that one back
/// through `stringToEnum` and a structural type there would refuse to load.
fn writeExportReturns(json: *std.json.Stringify, exp: anytype) !void {
    try json.objectField("returns");
    if (exp.signature) |declared| {
        try json.write(declared.returns);
    } else {
        try json.write(exp.returns.jsTypeName());
    }
}

/// Whether any module in the resolved graph imports this builtin specifier.
///
/// Reads the graph the caller already resolved rather than re-parsing: an
/// import the resolver rejected is in `rejected`, not here, so a specifier that
/// failed to resolve is never treated as imported.
fn graphImportsSpecifier(
    graph: *const module_graph_record.GraphRecord,
    specifier: []const u8,
) bool {
    for (graph.modules) |module| {
        for (module.imports) |import| {
            if (std.mem.eql(u8, import.specifier, specifier)) return true;
        }
    }
    return false;
}

/// Emit a module's use protocol, when it declares one.
///
/// Omitted rather than emitted empty: an absent field reads as "this module
/// has no protocol beyond its signatures", while `"summary":""` reads as a
/// module whose protocol is the empty string. The roster is filled module by
/// module, so the difference is live.
fn writeModuleSummary(json: *std.json.Stringify, binding: anytype) !void {
    if (binding.summary.len == 0) return;
    try json.objectField("summary");
    try json.write(binding.summary);
}

/// Emit an export's parameter names, in call order.
///
/// This is the field the model needs and did not have. Discovery published
/// `sqlMany` with a name and an effect and nothing else, so a model had no way
/// to learn that its first argument is a query name registered by `sql()`
/// rather than a SQL statement. Positions past `required_arg_count` carry a
/// trailing `?`, which is derived here rather than stored - the arity is
/// already declared and two sources for one fact drift.
fn writeExportParams(json: *std.json.Stringify, exp: anytype) !void {
    if (exp.param_names.len == 0) return;
    const required: usize = if (exp.required_arg_count) |n| n else exp.param_names.len;
    try json.objectField("params");
    try json.beginArray();
    for (exp.param_names, 0..) |param, index| {
        if (index < required) {
            try json.write(param);
        } else {
            var buf: [64]u8 = undefined;
            const optional = std.fmt.bufPrint(&buf, "{s}?", .{param}) catch param;
            try json.write(optional);
        }
    }
    try json.endArray();
}

fn writeFullMetaPayload(json: *std.json.Stringify) !bool {
    try json.beginObject();

    try json.objectField("compiler_version");
    try json.write(expert_meta.compiler_version);
    try json.objectField("profile_id");
    try json.write(agent_identity.profile_id);
    try json.objectField("policy_version");
    try json.write(expert_meta.policy_version);
    try json.objectField("policy_hash");
    try json.write(&zts.policyHash());
    try json.objectField("grammar_hash");
    try json.write(&zts.grammarHash());

    // Keep the metadata field while the supported frontend catalog is empty.
    try json.objectField("source_frontends");
    try json.beginArray();
    try json.endArray();

    try json.objectField("operations");
    try writeOperationCatalog(json, true);

    try json.objectField("error_codes");
    try json.beginArray();
    inline for (@typeInfo(ErrorCode).@"enum".field_names) |field| try json.write(field);
    try json.endArray();

    try json.objectField("idiom_table_hash");
    try json.write(&zts.idiomTableHash());
    try json.objectField("restriction_matrix_hash");
    try json.write(&zts.restrictionMatrixHash());
    try json.objectField("builtin_registry_hash");
    try json.write(&moduleMetadata.builtinRegistryHash());
    try json.objectField("example_registry_hash");
    try json.write(&example_registry.catalogHash());
    try json.objectField("severities");
    try json.beginObject();
    try json.objectField("set");
    try json.beginArray();
    // Derived from the stable projection, so the closed wire set stays aligned
    // with every checker without exposing a checker-specific severity type.
    inline for (@typeInfo(zts.DiagnosticProjection.Severity).@"enum".field_names) |field| {
        const severity: zts.DiagnosticProjection.Severity = @fromBackingInt(@intCast(@backingInt(@field(zts.DiagnosticProjection.Severity, field))));
        try json.write(severity.label());
    }
    try json.endArray();
    try json.objectField("success_rule");
    try json.write("a response reports success true exactly when it produced no error diagnostic, so warnings and advisories never fail a check");
    try json.endObject();

    try json.objectField("idioms");
    try json.beginArray();
    for (idiomCatalog.idioms()) |*entry| {
        try json.beginObject();
        try json.objectField("id");
        try json.write(entry.id);
        try json.objectField("operation");
        try json.write(entry.operation);
        try json.objectField("idiomatic");
        try json.write(entry.idiomatic);
        try json.objectField("superseded");
        try json.write(entry.superseded);
        try json.objectField("precondition");
        try json.write(entry.precondition);
        // The rewrite that realizes the row, or null when the row is
        // advisory-only. Spec 4.2.1 permits a row with no mechanical rewrite.
        try json.objectField("rewrite_rule");
        if (entry.rewrite_rule) |rule| try json.write(rule) else try json.write(null);
        try json.endObject();
    }
    try json.endArray();

    // Only constants the code enforces. The repair-iteration and tool-call
    // budget spec 4.8 also asks for is a loop policy nothing implements, so it
    // is a deferred section rather than a number invented here.
    try json.objectField("limits");
    try json.beginObject();
    try json.objectField("normalize_iterations");
    try json.write(canonicalize.max_normalize_iterations);
    try json.objectField("request_bytes");
    try json.write(edit_simulate.max_stdin_json_bytes);
    try json.objectField("source_bytes");
    try json.write(module_graph_record.max_source_bytes);
    try json.objectField("module_graph_modules");
    try json.write(module_graph_record.max_modules);
    try json.endObject();

    try json.objectField("module_catalog");
    try json.beginArray();
    for (zts.builtinModules) |binding| {
        try json.beginObject();
        try json.objectField("specifier");
        try json.write(binding.specifier);
        try json.objectField("name");
        try json.write(binding.name);
        try writeModuleSummary(json, binding);
        try json.objectField("required_capabilities");
        try json.beginArray();
        for (binding.required_capabilities) |cap| try json.write(@tagName(cap));
        try json.endArray();
        try json.objectField("exports");
        try json.beginArray();
        for (binding.exports) |exp| {
            try json.beginObject();
            try json.objectField("name");
            try json.write(exp.name);
            try json.objectField("effect");
            try json.write(@tagName(exp.effect));
            try writeExportParams(json, exp);
            try writeExportReturns(json, exp);
            try json.endObject();
        }
        try json.endArray();
        try json.endObject();
    }
    try json.endArray();

    // Spec section 8's grammar, production for production, in document order.
    // `scripts/check-grammar-drift.sh` compares the registry behind this to the
    // document itself, so what a client reads here is the section.
    //
    // Every row carries its enforcement point. The section is a structural
    // over-approximation by its own preamble - several productions admit forms
    // the prose excludes - and a grammar published without that distinction
    // would teach an agent to write programs this compiler refuses.
    try json.objectField("grammar");
    try json.beginArray();
    for (zts.GrammarCatalog.productions()) |p| {
        try json.beginObject();
        try json.objectField("name");
        try json.write(p.name);
        try json.objectField("rhs");
        try json.write(p.rhs);
        try json.objectField("enforcement");
        try json.write(p.enforcement.id());
        // The rule that refuses what the production over-admits, where that
        // rule is a member of the policy-hashed registry.
        try json.objectField("rule_code");
        if (p.rule_code) |code| try json.write(code) else try json.write(null);
        // Set instead of `rule_code` when the refusal comes from a band the
        // registry does not cover, so the row still says who answers.
        try json.objectField("note");
        if (p.note) |note| try json.write(note) else try json.write(null);
        try json.endObject();
    }
    try json.endArray();

    // The decision kinds a client keys on (spec 4.8), versioned, each with the
    // response fields that carry it and the next action it admits. The `Id`
    // enum behind this is the wire vocabulary every refusal is written from, so
    // a kind on the wire and a kind published here cannot differ.
    try json.objectField("decisions");
    try json.beginObject();
    try json.objectField("version");
    try json.write(decision_registry.version);
    try json.objectField("kinds");
    try json.beginArray();
    for (&decision_registry.decisions) |row| {
        try json.beginObject();
        try json.objectField("id");
        try json.write(row.id.wire());
        try json.objectField("next_action");
        try json.write(@tagName(row.next_action));
        try json.objectField("description");
        try json.write(row.description);
        try json.objectField("parameters");
        try json.beginArray();
        for (row.parameters) |param| try json.write(param);
        try json.endArray();
        try json.endObject();
    }
    try json.endArray();
    try json.endObject();

    // One canonical minimal example per admitted surface form (spec 4.8), so
    // an agent learns the ZTS-specific spellings here rather than from hidden
    // instructions. Every example is checked by the test that publishes it and
    // must report nothing at any severity, so a form that stops being legal
    // fails the build instead of teaching a program the compiler refuses.
    try json.objectField("examples");
    try json.beginArray();
    for (&example_registry.examples) |entry| {
        try json.beginObject();
        try json.objectField("feature");
        try json.write(entry.feature);
        try json.objectField("source");
        try json.write(entry.source);
        try json.endObject();
    }
    try json.endArray();

    try json.objectField("module_examples");
    try json.beginArray();
    for (&example_registry.module_examples) |entry| {
        try json.beginObject();
        try json.objectField("name");
        try json.write(entry.name);
        try json.objectField("purpose");
        try json.write(entry.purpose);
        try json.objectField("modules");
        try json.beginArray();
        for (entry.modules) |specifier| try json.write(specifier);
        try json.endArray();
        try json.objectField("source");
        try json.write(entry.source);
        try json.endObject();
    }
    try json.endArray();

    // The ambient table (spec 6): the names a handler writes without importing
    // them. Both halves are registry-generated - the values are the
    // `known_globals` list the checker itself reads, and every type row is
    // resolved through the checker's own entry by a gate in `ambient_names`, so
    // a name published here is a name the compiler admits.
    try json.objectField("ambient_names");
    try json.beginObject();
    try json.objectField("types");
    try json.beginArray();
    for (zts.AmbientCatalog.typeNames()) |entry| {
        try json.beginObject();
        try json.objectField("name");
        try json.write(entry.name);
        // Where the name gets its meaning, which is also whether a later
        // declaration can shadow it.
        try json.objectField("origin");
        try json.write(entry.origin.id());
        // Type arguments the name requires. `Dict` is written `Dict<K, V>` and
        // nothing else, so the name alone is half a spelling.
        try json.objectField("arity");
        try json.write(entry.arity);
        try json.endObject();
    }
    try json.endArray();
    try json.objectField("values");
    try json.beginArray();
    for (zts.AmbientCatalog.valueNames()) |name| try json.write(name);
    try json.endArray();
    try json.endObject();

    // The canonical type serialization (spec 5.4). A type digest is an identity
    // a client may cache; the version is what tells it whether a cached
    // identity still applies after a compiler upgrade.
    try json.objectField("type_serialization");
    try json.beginObject();
    try json.objectField("version");
    try json.write(zts.TypeSerialization.version);
    try json.objectField("digest_algorithm");
    try json.write(zts.TypeSerialization.digest_algorithm);
    try json.objectField("digest_encoding");
    try json.write("lowercase hex");
    try json.objectField("max_depth");
    try json.write(zts.TypeSerialization.max_depth);
    try json.objectField("note");
    try json.write("the digest is sha256 over one canonical string per type; two structurally identical types serialize identically and a type graph deeper than max_depth has no identity");
    try json.endObject();

    // The equivalence-validator registry (D3 section 4). Published so a client
    // can read why a repair is or is not advertised, rather than inferring it
    // from a flag with no stated reason.
    try json.objectField("validators");
    try json.beginArray();
    for (repairPolicy.validators()) |row| {
        try json.beginObject();
        try json.objectField("intent");
        try json.write(@tagName(row.intent));
        try json.objectField("method");
        try json.write(row.method.id());
        try json.objectField("status");
        try json.write(@tagName(row.status));
        try json.objectField("precondition");
        if (row.precondition) |p| try json.write(p) else try json.write(null);
        try json.objectField("gradable");
        try json.write(row.gradable());
        try json.endObject();
    }
    try json.endArray();

    // The verifier discovery registry: every property `verify` will answer
    // about, and the family of reasoning that decides it. Derived from
    // `proof_trace.property_info`, which a comptime check ties to
    // `HandlerProperties`, so a new contract property appears here without an
    // edit and `verify` can never advertise a name it would then refuse.
    try json.objectField("verifiers");
    try json.beginArray();
    for (zts.proof_trace.verifiers) |v| {
        try json.beginObject();
        try json.objectField("property");
        try json.write(v.id);
        try json.objectField("kind");
        try json.write(v.kind.asString());
        // Spec 4.8: a verifier row publishes what a request must supply, what
        // has to hold before the answer means anything, the grades it can carry,
        // and the shape of the evidence beside it. "An agent never chooses among
        // undocumented verification commands."
        try json.objectField("inputs");
        try writeStringArray(json, v.inputs);
        try json.objectField("prerequisites");
        try writeStringArray(json, v.prerequisites);
        try json.objectField("grades");
        try writeStringArray(json, v.grades);
        try json.objectField("result_schema");
        try json.beginArray();
        for (v.result_schema) |f| {
            try json.beginObject();
            try json.objectField("name");
            try json.write(f.name);
            try json.objectField("type");
            try json.write(f.json_type);
            try json.objectField("presence");
            try json.write(f.presence);
            try json.endObject();
        }
        try json.endArray();
        try json.endObject();
    }
    try json.endArray();

    try json.objectField("deferred_sections");
    try json.beginArray();
    for (&deferred_sections) |*section| {
        try json.beginObject();
        try json.objectField("name");
        try json.write(section.name);
        try json.objectField("note");
        try json.write(section.note);
        try json.endObject();
    }
    try json.endArray();

    try json.endObject();
    return true;
}

// ---------------------------------------------------------------------------
// features, restrictions, describe_rule
// ---------------------------------------------------------------------------

/// Every surface form the profile has an opinion about. `restriction_id` links a
/// refused form to its matrix row; an admitted form has none.
///
/// D3 §6 sketched `{ id, category, status }`. There is no category data behind
/// `category` - the v1 table never had one - so the field is absent rather than
/// invented, and the link to the matrix takes its place.
pub fn writeFeaturesPayload(json: *std.json.Stringify) !bool {
    try json.beginObject();
    try json.objectField("features");
    try json.beginArray();

    for (json_diagnostics.allowed_feature_names) |name| {
        try json.beginObject();
        try json.objectField("id");
        try json.write(name);
        try json.objectField("status");
        try json.write("allowed");
        try json.objectField("restriction_id");
        try json.write(null);
        try json.endObject();
    }
    for (restrictionCatalog.restrictions()) |*entry| {
        try json.beginObject();
        try json.objectField("id");
        try json.write(entry.feature);
        try json.objectField("status");
        try json.write("blocked");
        try json.objectField("restriction_id");
        try json.write(entry.id);
        try json.endObject();
    }

    try json.endArray();
    try json.endObject();
    return true;
}

/// The whole section-12 matrix, including the rows the frozen v1 surface never
/// published. `enforced_by` and `unenforced_note` are both published: a client
/// that reads only the exclusion list would otherwise believe six rows are
/// enforced when the compiler admits them.
pub fn writeRestrictionsPayload(json: *std.json.Stringify) !bool {
    try json.beginObject();
    try json.objectField("restrictions");
    try json.beginArray();

    for (restrictionCatalog.restrictions()) |*entry| {
        try json.beginObject();
        try json.objectField("id");
        try json.write(entry.id);
        try json.objectField("feature");
        try json.write(entry.feature);
        try json.objectField("boundary");
        try json.write(entry.boundary);
        try json.objectField("nature");
        try json.write(entry.nature.label());
        try json.objectField("note");
        try json.write(entry.note);
        try json.objectField("alternative");
        if (entry.alternative) |a| try json.write(a) else try json.write(null);
        try json.objectField("failure_class");
        if (entry.failure_class) |f| try json.write(f) else try json.write(null);
        try json.objectField("proof_unlocked");
        if (entry.proof_unlocked) |p| try json.write(p) else try json.write(null);
        try json.objectField("enforced_by");
        try json.beginArray();
        for (entry.enforced_by) |code| try json.write(code);
        try json.endArray();
        try json.objectField("unenforced_note");
        if (entry.unenforced_note) |n| try json.write(n) else try json.write(null);
        try json.endObject();
    }

    try json.endArray();
    try json.endObject();
    return true;
}

/// The rule registry, optionally filtered to one rule by name or code. An
/// unknown rule is an empty list and `success: true` - the closed operation set
/// answers "no such rule" as data, not as a protocol failure.
///
/// No `severity` field: see the `rule_severity` deferred section.
pub fn writeDescribeRulePayload(json: *std.json.Stringify, input: std.json.Value) !bool {
    const filter: ?[]const u8 = blk: {
        const obj = switch (input) {
            .object => |o| o,
            else => break :blk null,
        };
        const value = obj.get("rule") orelse break :blk null;
        break :blk if (value == .string) value.string else null;
    };

    try json.beginObject();
    try json.objectField("rules");
    try json.beginArray();
    for (policy_catalog.rules()) |*rule| {
        if (filter) |name| {
            if (!std.mem.eql(u8, rule.name, name) and !std.mem.eql(u8, rule.code, name)) continue;
        }
        try json.beginObject();
        try json.objectField("name");
        try json.write(rule.name);
        try json.objectField("code");
        try json.write(rule.code);
        try json.objectField("category");
        try json.write(rule.category.label());
        try json.objectField("description");
        try json.write(rule.description);
        try json.objectField("example");
        if (rule.example) |e| try json.write(e) else try json.write(null);
        try json.objectField("help");
        try json.write(rule.help);
        try json.objectField("repair_intent");
        if (rule.repair) |r| try json.write(@tagName(r)) else try json.write(null);
        try json.endObject();
    }
    try json.endArray();
    try json.endObject();
    return true;
}

// ---------------------------------------------------------------------------
// modules
// ---------------------------------------------------------------------------

/// The resolved module environment for one entry file (spec 4.8): the relative
/// graph with source digests, the built-in registry, authenticated extensions,
/// every rejected candidate, and one digest over the whole environment.
///
/// The payload's `module_graph_hash` and the envelope's are the same value,
/// computed once - a client that binds one has bound the other.
pub fn writeModulesPayload(
    json: *std.json.Stringify,
    graph: *const module_graph_record.GraphRecord,
) !bool {
    try json.beginObject();

    try json.objectField("graph");
    try json.beginArray();
    for (graph.modules) |module| {
        try json.beginObject();
        try json.objectField("path");
        try json.write(module.path);
        try json.objectField("source_digest");
        try json.write(&module.source_digest);
        try json.objectField("imports");
        try json.beginArray();
        for (module.imports) |import| {
            try json.beginObject();
            try json.objectField("specifier");
            try json.write(import.specifier);
            try json.objectField("kind");
            try json.write(@tagName(import.kind));
            try json.objectField("target");
            try json.write(import.target);
            try json.endObject();
        }
        try json.endArray();
        try json.endObject();
    }
    try json.endArray();

    // Every builtin, in one shape. `resolved` says which of them the entry file
    // imports; it is the only field this loop varies, and it is a fact about
    // the file, not a second row schema.
    //
    // Scoping was tried twice and gave both fields back. Emitting a bare
    // specifier list for an unimported module saved 10,406 of an 11,061-byte
    // response and cost correctness: a model reading it wrote a SELECT
    // statement into the argument that takes a registered query name, so every
    // module got its summary and its `name(params)` signature back. What was
    // left scoped after that was `required_capabilities` and per-export
    // `effect`, and that made a `builtins[]` row two shapes within one
    // `schema_version` - a reader written against v2, where both keys were
    // guaranteed on every row, read undefined rather than a version mismatch
    // it could detect, and `resolved` only helps a reader that already knows
    // to look for it. Measured on a one-import entry file, giving those two
    // back takes the payload from 11636 to 14393 bytes.
    //
    // These bytes are corpus input. This payload's text is a recorded
    // `zts_expert_query` tool result inside the `sibling-helper` and
    // `egress-options-holes` cassettes, so any change to what this writes
    // stales them and the replay gate refuses with `StaleCodegenCassette`.
    // Plan a re-record before editing it; see
    // docs/internals/cassette-recording.md.
    try json.objectField("builtins");
    try json.beginArray();
    for (zts.builtinModules) |binding| {
        const imported = graphImportsSpecifier(graph, binding.specifier);
        try json.beginObject();
        try json.objectField("specifier");
        try json.write(binding.specifier);
        try json.objectField("name");
        try json.write(binding.name);
        try writeModuleSummary(json, binding);
        // Whether the entry file imports this module. A reader never has to
        // infer that from a missing key, and never mistakes an unimported
        // entry for a module that declares no capabilities.
        try json.objectField("resolved");
        try json.write(imported);
        try json.objectField("required_capabilities");
        try json.beginArray();
        for (binding.required_capabilities) |cap| try json.write(@tagName(cap));
        try json.endArray();
        try json.objectField("exports");
        try json.beginArray();
        for (binding.exports) |exp| {
            try json.beginObject();
            try json.objectField("name");
            try json.write(exp.name);
            try json.objectField("effect");
            try json.write(@tagName(exp.effect));
            try writeExportParams(json, exp);
            // Universal, like params: a chooser needs to know what a module
            // answers before importing it, and the absence of exactly this
            // fact is what three failing cases had in common.
            try writeExportReturns(json, exp);
            try json.endObject();
        }
        try json.endArray();
        try json.endObject();
    }
    try json.endArray();

    // Empty until a manifest is authenticated; see the extension_manifests
    // deferred section. An extension specifier in source shows up under
    // `rejected`, never silently resolved.
    try json.objectField("extensions");
    try json.beginArray();
    try json.endArray();

    try json.objectField("rejected");
    try json.beginArray();
    for (graph.rejected) |rejection| {
        try json.beginObject();
        try json.objectField("specifier");
        try json.write(rejection.specifier);
        try json.objectField("importer");
        try json.write(rejection.importer);
        try json.objectField("reason");
        try json.write(rejection.reason);
        try json.endObject();
    }
    try json.endArray();

    try json.objectField("module_graph_hash");
    try json.write(&graph.hash);

    try json.endObject();
    return graph.rejected.len == 0;
}

test "meta response carries the full identity block" {
    const a = testing.allocator;
    const out = try respond(a,
        \\{"schema_version":2,"operation":"meta","project_root":".","input":{}}
    );
    defer a.free(out);
    try testing.expectEqual(@as(u8, '\n'), out[out.len - 1]);

    var parsed = try parse(a, out);
    defer parsed.deinit();
    const obj = parsed.value.object;
    try testing.expectEqual(@as(i64, 2), obj.get("schema_version").?.integer);
    try testing.expectEqualStrings("meta", obj.get("operation").?.string);
    try testing.expectEqualStrings("zts-model-1", obj.get("profile_id").?.string);
    try testing.expectEqual(@as(usize, 64), obj.get("policy_hash").?.string.len);
    try testing.expectEqual(@as(usize, 64), obj.get("module_graph_hash").?.string.len);
    try testing.expect(obj.get("success").?.bool);
    try testing.expect(obj.get("payload").? == .object);
    try testing.expect(obj.get("diagnostics").? == .array);
    try testing.expect(obj.get("error") == null);
}

test "meta bootstrap view is bounded and routes to full discovery" {
    const a = testing.allocator;
    const out = try respond(a,
        \\{"schema_version":2,"operation":"meta","project_root":".","input":{"view":"bootstrap"}}
    );
    defer a.free(out);

    // This response is injected into every new agent transcript. A full meta
    // response is intentionally much larger and remains available on demand.
    try testing.expect(out.len <= 8 * 1024);

    var parsed = try parse(a, out);
    defer parsed.deinit();
    const root = parsed.value.object;
    try testing.expect(root.get("success").?.bool);
    const payload = root.get("payload").?.object;
    try testing.expectEqualStrings("bootstrap", payload.get("view").?.string);
    try testing.expectEqualStrings(&zts.policyHash(), payload.get("policy_hash").?.string);
    try testing.expectEqualStrings(&zts.grammarHash(), payload.get("grammar_hash").?.string);
    try testing.expectEqualStrings(&zts.idiomTableHash(), payload.get("idiom_table_hash").?.string);
    try testing.expectEqualStrings(&zts.restrictionMatrixHash(), payload.get("restriction_matrix_hash").?.string);
    try testing.expectEqual(@as(usize, 64), payload.get("builtin_registry_hash").?.string.len);
    const ops = payload.get("operations").?.array;
    try testing.expectEqual(operations.len, ops.items.len);
    const full = payload.get("full_meta_request").?.object;
    try testing.expectEqualStrings("meta", full.get("operation").?.string);
    try testing.expectEqualStrings("full", full.get("input").?.object.get("view").?.string);
    const sections = payload.get("full_meta_sections").?.array;
    try testing.expectEqual(specFor(.meta).payload_fields.len, sections.items.len);
    for (specFor(.meta).payload_fields, sections.items) |field, section| {
        try testing.expectEqualStrings(field, section.string);
    }
    try testing.expect(payload.get("grammar") == null);
    try testing.expect(payload.get("examples") == null);
}

test "meta refuses an unknown view" {
    const a = testing.allocator;
    const out = try respond(a,
        \\{"schema_version":2,"operation":"meta","project_root":".","input":{"view":"verbose"}}
    );
    defer a.free(out);

    var parsed = try parse(a, out);
    defer parsed.deinit();
    const root = parsed.value.object;
    try testing.expect(!root.get("success").?.bool);
    const protocol_error = root.get("error").?.object;
    try testing.expectEqualStrings("malformed_request", protocol_error.get("code").?.string);
    try testing.expectEqualStrings("input.view", protocol_error.get("field").?.string);
}

test "meta payload publishes every operation and its status" {
    const a = testing.allocator;
    const out = try respond(a,
        \\{"schema_version":2,"operation":"meta","project_root":".","input":{}}
    );
    defer a.free(out);
    var parsed = try parse(a, out);
    defer parsed.deinit();

    const payload = parsed.value.object.get("payload").?.object;
    const ops = payload.get("operations").?.array;
    try testing.expectEqual(operations.len, ops.items.len);
    inline for (@typeInfo(Operation).@"enum".field_names) |field| {
        var seen: usize = 0;
        for (ops.items) |o| {
            if (std.mem.eql(u8, o.object.get("id").?.string, field)) seen += 1;
        }
        try testing.expectEqual(@as(usize, 1), seen);
    }
    // The sections no registry can generate are named, not stubbed. Counted
    // against the table rather than a floor: the floor was a stand-in for "the
    // list is populated" and had to be edited down every time a section closed,
    // which is a number drifting behind the thing it describes.
    const sections = payload.get("deferred_sections").?.array;
    try testing.expectEqual(deferred_sections.len, sections.items.len);
    for (sections.items) |s| {
        try testing.expect(payload.get(s.object.get("name").?.string) == null);
    }
}

test "an unsupported schema version gets the frozen three-key response" {
    const a = testing.allocator;
    const out = try respond(a,
        \\{"schema_version":1,"operation":"meta","project_root":".","input":{}}
    );
    defer a.free(out);
    var parsed = try parse(a, out);
    defer parsed.deinit();
    const obj = parsed.value.object;
    try testing.expectEqual(@as(usize, 3), obj.count());
    try testing.expect(obj.get("schema_version_unsupported").?.bool);
    try testing.expectEqual(@as(usize, 1), obj.get("supported_schema_versions").?.array.items.len);
    try testing.expect(obj.get("compiler_version") != null);
    try testing.expect(obj.get("operation") == null);
}

test "malformed input is a protocol error naming the offending field" {
    const a = testing.allocator;
    const cases = [_]struct { body: []const u8, field: ?[]const u8 }{
        .{ .body = "not json at all", .field = null },
        .{ .body = "[]", .field = null },
        .{ .body =
        \\{"operation":"meta","project_root":".","input":{}}
        , .field = "schema_version" },
        .{ .body =
        \\{"schema_version":"2","operation":"meta","project_root":".","input":{}}
        , .field = "schema_version" },
        .{ .body =
        \\{"schema_version":2,"project_root":".","input":{}}
        , .field = "operation" },
        .{ .body =
        \\{"schema_version":2,"operation":"meta","input":{}}
        , .field = "project_root" },
    };
    for (cases) |case| {
        const out = try respond(a, case.body);
        defer a.free(out);
        var parsed = try parse(a, out);
        defer parsed.deinit();
        const err = parsed.value.object.get("error") orelse {
            std.debug.print("no error object for input: {s}\n", .{case.body});
            return error.TestUnexpectedResult;
        };
        try testing.expectEqualStrings("malformed_request", err.object.get("code").?.string);
        if (case.field) |f| {
            try testing.expectEqualStrings(f, err.object.get("field").?.string);
        }
    }
}

test "an unresolvable project root is its own error code" {
    const a = testing.allocator;
    const out = try respond(a,
        \\{"schema_version":2,"operation":"meta","project_root":"/no/such/root/here","input":{}}
    );
    defer a.free(out);
    var parsed = try parse(a, out);
    defer parsed.deinit();
    const err = parsed.value.object.get("error").?.object;
    try testing.expectEqualStrings("project_root_unresolvable", err.get("code").?.string);
    try testing.expectEqualStrings("project_root", err.get("field").?.string);
}

test "a matching expected block passes the guard" {
    const a = testing.allocator;
    const policy = zts.policyHash();
    const graph = module_graph_record.contextFreeHash();
    const req = try a.print(
        \\{{"schema_version":2,"operation":"meta","project_root":".","input":{{}},
        \\ "expected":{{"profile_id":"zts-model-1","policy_hash":"{s}","module_graph_hash":"{s}"}}}}
    , .{ policy, graph });
    defer a.free(req);

    const out = try respond(a, req);
    defer a.free(out);
    var parsed = try parse(a, out);
    defer parsed.deinit();
    try testing.expect(parsed.value.object.get("success").?.bool);
    try testing.expect(parsed.value.object.get("error") == null);
}

test "a stale policy_hash fails with both values named" {
    const a = testing.allocator;
    const out = try respond(a,
        \\{"schema_version":2,"operation":"meta","project_root":".","input":{},
        \\ "expected":{"policy_hash":"0000000000000000000000000000000000000000000000000000000000000000"}}
    );
    defer a.free(out);
    var parsed = try parse(a, out);
    defer parsed.deinit();

    const obj = parsed.value.object;
    try testing.expect(!obj.get("success").?.bool);
    const err = obj.get("error").?.object;
    try testing.expectEqualStrings("identity_mismatch", err.get("code").?.string);
    try testing.expectEqualStrings("expected.policy_hash", err.get("field").?.string);
    // Both values, so a client re-binds without a second round trip.
    const message = err.get("message").?.string;
    try testing.expect(std.mem.indexOf(u8, message, "0000000000") != null);
    try testing.expect(std.mem.indexOf(u8, message, &zts.policyHash()) != null);
}

test "a stale profile_id fails the same way" {
    const a = testing.allocator;
    const out = try respond(a,
        \\{"schema_version":2,"operation":"meta","project_root":".","input":{},
        \\ "expected":{"profile_id":"zts-1"}}
    );
    defer a.free(out);
    var parsed = try parse(a, out);
    defer parsed.deinit();
    const err = parsed.value.object.get("error").?.object;
    try testing.expectEqualStrings("identity_mismatch", err.get("code").?.string);
    try testing.expectEqualStrings("expected.profile_id", err.get("field").?.string);
}

test "a stale module_graph_hash fails the same way" {
    const a = testing.allocator;
    const out = try respond(a,
        \\{"schema_version":2,"operation":"meta","project_root":".","input":{},
        \\ "expected":{"module_graph_hash":"deadbeef"}}
    );
    defer a.free(out);
    var parsed = try parse(a, out);
    defer parsed.deinit();
    const err = parsed.value.object.get("error").?.object;
    try testing.expectEqualStrings("identity_mismatch", err.get("code").?.string);
    try testing.expectEqualStrings("expected.module_graph_hash", err.get("field").?.string);
}

test "an omitted or empty expected block skips the guard" {
    const a = testing.allocator;
    for ([_][]const u8{
        \\{"schema_version":2,"operation":"meta","project_root":".","input":{}}
        ,
        \\{"schema_version":2,"operation":"meta","project_root":".","input":{},"expected":{}}
        ,
    }) |body| {
        const out = try respond(a, body);
        defer a.free(out);
        var parsed = try parse(a, out);
        defer parsed.deinit();
        try testing.expect(parsed.value.object.get("success").?.bool);
    }
}

test "an unknown key inside expected is malformed, not ignored" {
    // Silently skipping a misspelled guard field would report success for a
    // request the client believed was guarded.
    const a = testing.allocator;
    const out = try respond(a,
        \\{"schema_version":2,"operation":"meta","project_root":".","input":{},
        \\ "expected":{"policy_hashh":"x"}}
    );
    defer a.free(out);
    var parsed = try parse(a, out);
    defer parsed.deinit();
    const err = parsed.value.object.get("error").?.object;
    try testing.expectEqualStrings("malformed_request", err.get("code").?.string);
    try testing.expectEqualStrings("expected.policy_hashh", err.get("field").?.string);
}

test "a non-string expected value is malformed" {
    const a = testing.allocator;
    const out = try respond(a,
        \\{"schema_version":2,"operation":"meta","project_root":".","input":{},
        \\ "expected":{"policy_hash":2}}
    );
    defer a.free(out);
    var parsed = try parse(a, out);
    defer parsed.deinit();
    const err = parsed.value.object.get("error").?.object;
    try testing.expectEqualStrings("malformed_request", err.get("code").?.string);
    try testing.expectEqualStrings("expected.policy_hash", err.get("field").?.string);
}

test "restrictions publishes every matrix row, not only the frozen v1 set" {
    const a = testing.allocator;
    const out = try respond(a,
        \\{"schema_version":2,"operation":"restrictions","project_root":".","input":{}}
    );
    defer a.free(out);
    var parsed = try parse(a, out);
    defer parsed.deinit();

    const rows = parsed.value.object.get("payload").?.object.get("restrictions").?.array;
    try testing.expectEqual(restrictionCatalog.restrictions().len, rows.items.len);
    try testing.expect(rows.items.len > restrictionCatalog.v1Count());

    const first = rows.items[0].object;
    try testing.expect(std.mem.startsWith(u8, first.get("id").?.string, "restriction."));
    try testing.expect(first.get("nature") != null);
    try testing.expect(first.get("enforced_by").? == .array);
}

test "restrictions publishes the rows nothing enforces as unenforced" {
    // Six rows the profile excludes on paper and admits in practice. A client
    // reading only the exclusion list would otherwise believe they are enforced.
    const a = testing.allocator;
    const out = try respond(a,
        \\{"schema_version":2,"operation":"restrictions","project_root":".","input":{}}
    );
    defer a.free(out);
    var parsed = try parse(a, out);
    defer parsed.deinit();

    const rows = parsed.value.object.get("payload").?.object.get("restrictions").?.array;
    var unenforced: usize = 0;
    for (rows.items) |row| {
        const codes = row.object.get("enforced_by").?.array;
        const note = row.object.get("unenforced_note").?;
        if (codes.items.len == 0) {
            try testing.expect(note == .string);
            unenforced += 1;
        } else {
            try testing.expect(note == .null);
        }
    }
    // Two rows remain: `restriction.unchecked-recursion` (not a rejection by
    // design) and `restriction.unbound-native-module` (enforced outside the rule
    // registry). `restriction.interface` left this set when phase 7 refused the
    // form with ZTS049; it had been waiting on a migration policy that is now
    // decided. An exact count, so closing or opening a gap has to come here and
    // say which.
    try testing.expectEqual(@as(usize, 2), unenforced);
}

test "features publishes both halves and links refused forms to the matrix" {
    const a = testing.allocator;
    const out = try respond(a,
        \\{"schema_version":2,"operation":"features","project_root":".","input":{}}
    );
    defer a.free(out);
    var parsed = try parse(a, out);
    defer parsed.deinit();

    const items = parsed.value.object.get("payload").?.object.get("features").?.array;
    try testing.expectEqual(
        json_diagnostics.allowed_feature_names.len + restrictionCatalog.restrictions().len,
        items.items.len,
    );
    var allowed: usize = 0;
    for (items.items) |f| {
        const status = f.object.get("status").?.string;
        if (std.mem.eql(u8, status, "allowed")) {
            allowed += 1;
            try testing.expect(f.object.get("restriction_id").? == .null);
        } else {
            try testing.expectEqualStrings("blocked", status);
            const id = f.object.get("restriction_id").?.string;
            try testing.expect(restrictionCatalog.findById(id) != null);
        }
    }
    try testing.expectEqual(json_diagnostics.allowed_feature_names.len, allowed);
}

test "describe_rule with no filter returns every registry rule" {
    const a = testing.allocator;
    const out = try respond(a,
        \\{"schema_version":2,"operation":"describe_rule","project_root":".","input":{}}
    );
    defer a.free(out);
    var parsed = try parse(a, out);
    defer parsed.deinit();

    const rules = parsed.value.object.get("payload").?.object.get("rules").?.array;
    try testing.expectEqual(policy_catalog.rules().len, rules.items.len);
    // No severity field: it is a property of the emission site, not the rule.
    try testing.expect(rules.items[0].object.get("severity") == null);
}

test "describe_rule filters by code and by name" {
    const a = testing.allocator;
    for ([_][]const u8{
        \\{"schema_version":2,"operation":"describe_rule","project_root":".","input":{"rule":"ZTS303"}}
        ,
        \\{"schema_version":2,"operation":"describe_rule","project_root":".","input":{"rule":"unchecked_result_value"}}
        ,
    }) |body| {
        const out = try respond(a, body);
        defer a.free(out);
        var parsed = try parse(a, out);
        defer parsed.deinit();
        const rules = parsed.value.object.get("payload").?.object.get("rules").?.array;
        try testing.expectEqual(@as(usize, 1), rules.items.len);
        try testing.expectEqualStrings("ZTS303", rules.items[0].object.get("code").?.string);
        try testing.expectEqualStrings("unchecked_result_value", rules.items[0].object.get("name").?.string);
    }
}

test "describe_rule with an unknown rule succeeds with an empty list" {
    // The closed operation set answers "no such rule" as data, not as a
    // protocol failure.
    const a = testing.allocator;
    const out = try respond(a,
        \\{"schema_version":2,"operation":"describe_rule","project_root":".","input":{"rule":"ZTS999"}}
    );
    defer a.free(out);
    var parsed = try parse(a, out);
    defer parsed.deinit();
    try testing.expect(parsed.value.object.get("success").?.bool);
    try testing.expectEqual(
        @as(usize, 0),
        parsed.value.object.get("payload").?.object.get("rules").?.array.items.len,
    );
    try testing.expect(parsed.value.object.get("error") == null);
}

test "meta names rule_severity as a section no registry can answer" {
    const a = testing.allocator;
    const out = try respond(a,
        \\{"schema_version":2,"operation":"meta","project_root":".","input":{}}
    );
    defer a.free(out);
    var parsed = try parse(a, out);
    defer parsed.deinit();
    const sections = parsed.value.object.get("payload").?.object.get("deferred_sections").?.array;
    var found = false;
    for (sections.items) |sec| {
        if (std.mem.eql(u8, sec.object.get("name").?.string, "rule_severity")) found = true;
    }
    try testing.expect(found);
}

test "modules returns the resolved graph and binds one hash in two places" {
    const a = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "util.ts", .data = "export const two = 2;\n" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "handler.ts", .data =
        \\import { env } from "zttp:env";
        \\import { two } from "./util.ts";
        \\export function handler(req) { return Response.json({ two: two, e: env("X") }); }
        \\
    });
    const root = try std.Io.Dir.realPathFileAlloc(tmp.dir, testing.io, ".", a);
    defer a.free(root);

    const req = try a.print(
        \\{{"schema_version":2,"operation":"modules","project_root":"{s}","input":{{"file":"handler.ts"}}}}
    , .{root});
    defer a.free(req);
    const out = try respond(a, req);
    defer a.free(out);

    var parsed = try parse(a, out);
    defer parsed.deinit();
    const obj = parsed.value.object;
    try testing.expect(obj.get("success").?.bool);

    const payload = obj.get("payload").?.object;
    // One digest, bound in the envelope and in the payload.
    try testing.expectEqualStrings(
        obj.get("module_graph_hash").?.string,
        payload.get("module_graph_hash").?.string,
    );
    try testing.expectEqual(@as(usize, 2), payload.get("graph").?.array.items.len);
    try testing.expectEqual(zts.builtinModules.len, payload.get("builtins").?.array.items.len);
    try testing.expectEqual(@as(usize, 0), payload.get("rejected").?.array.items.len);

    const imports = payload.get("graph").?.array.items[0].object.get("imports").?.array;
    try testing.expectEqualStrings("zttp:env", imports.items[0].object.get("specifier").?.string);
    try testing.expectEqualStrings("builtin", imports.items[0].object.get("kind").?.string);
    try testing.expectEqualStrings("util.ts", imports.items[1].object.get("target").?.string);
}

// The regression this closes was measured, not imagined. `zts_expert_reference`
// and its prose carried `sqlOne(name: string, params?: object)`, a recorded
// corpus case read it and drafted correct named-query code, and the tool was
// deleted in `803ebc95`. The next recording of the same case wrote
// `sqlMany("SELECT id, name FROM users", {})` - a SELECT statement in the slot
// that takes a registered name - because discovery published only a name and
// an effect per export. The named fact is back, through compiler authority.
//
// Asserted on the value, not on a difference from a wrong payload: a test that
// only checked "params is present" would pass on `["string","object"]`, which
// is the shape that could not teach anything.
test "module discovery names each parameter and the module use protocol" {
    const a = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "handler.ts", .data =
        \\import { sqlMany } from "zttp:sql";
        \\export function handler(req) { return Response.json(sqlMany("listUsers")); }
        \\
    });
    const root = try std.Io.Dir.realPathFileAlloc(tmp.dir, testing.io, ".", a);
    defer a.free(root);

    const req = try a.print(
        \\{{"schema_version":2,"operation":"modules","project_root":"{s}","input":{{"file":"handler.ts"}}}}
    , .{root});
    defer a.free(req);
    const out = try respond(a, req);
    defer a.free(out);

    var parsed = try parse(a, out);
    defer parsed.deinit();
    const payload = parsed.value.object.get("payload").?.object;

    var found_sql_module = false;
    var found_sql_many = false;
    for (payload.get("builtins").?.array.items) |module| {
        const module_obj = module.object;
        if (!std.mem.eql(u8, module_obj.get("specifier").?.string, "zttp:sql")) continue;
        found_sql_module = true;

        // The protocol between the exports, which no single signature holds.
        const summary = module_obj.get("summary").?.string;
        try testing.expect(std.mem.indexOf(u8, summary, "sql(name, statement)") != null);
        try testing.expect(std.mem.indexOf(u8, summary, "never SQL text") != null);

        for (module_obj.get("exports").?.array.items) |exp| {
            const exp_obj = exp.object;
            if (!std.mem.eql(u8, exp_obj.get("name").?.string, "sqlMany")) continue;
            found_sql_many = true;
            const params = exp_obj.get("params").?.array;
            try testing.expectEqual(@as(usize, 2), params.items.len);
            try testing.expectEqualStrings("name", params.items[0].string);
            // Derived from required_arg_count, so the optional marker cannot
            // drift from the arity the checker enforces.
            try testing.expectEqualStrings("params?", params.items[1].string);
        }
    }
    // The floor: a payload that stopped carrying zttp:sql, or an export list
    // that stopped carrying sqlMany, would satisfy every assertion above by
    // never running one.
    try testing.expect(found_sql_module);
    try testing.expect(found_sql_many);
}

// `modules` resolves one entry file and describes every builtin in one shape,
// marking which of them the file imports. The assertions below are mostly
// about an unimported entry, because that is the row an earlier scoping cut
// down: a bare specifier list is what discovery published before parameter
// names, and the measured consequence was a model writing SQL text into the
// argument that takes a registered query name.
test "modules describes imports in full and keeps every other module choosable" {
    const a = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "handler.ts", .data =
        \\import { env } from "zttp:env";
        \\export function handler(req) { return Response.text(env("HOME")); }
        \\
    });
    const root = try std.Io.Dir.realPathFileAlloc(tmp.dir, testing.io, ".", a);
    defer a.free(root);

    const req = try a.print(
        \\{{"schema_version":2,"operation":"modules","project_root":"{s}","input":{{"file":"handler.ts"}}}}
    , .{root});
    defer a.free(req);
    const out = try respond(a, req);
    defer a.free(out);

    var parsed = try parse(a, out);
    defer parsed.deinit();
    const payload = parsed.value.object.get("payload").?.object;

    var saw_imported = false;
    var saw_unimported = false;
    for (payload.get("builtins").?.array.items) |module| {
        const m = module.object;
        const spec = m.get("specifier").?.string;
        const resolved = m.get("resolved").?.bool;

        if (std.mem.eql(u8, spec, "zttp:env")) {
            saw_imported = true;
            try testing.expect(resolved);
            // The imported module keeps everything: capabilities and per-export
            // effect are what a handler that actually calls it needs.
            try testing.expect(m.get("required_capabilities") != null);
            const exp = m.get("exports").?.array.items[0].object;
            try testing.expect(exp.get("effect") != null);
            try testing.expectEqualStrings("name", exp.get("params").?.array.items[0].string);
            continue;
        }

        if (std.mem.eql(u8, spec, "zttp:sql")) {
            saw_unimported = true;
            try testing.expect(!resolved);
            // Present, exactly as on a resolved row. Omitting these made the
            // shape of a row conditional while `schema_version` stayed 2, so a
            // v2 reader - where the keys were guaranteed on every row - read
            // undefined rather than a mismatch it could detect. `resolved` is
            // the hint; it is not a second shape.
            try testing.expect(m.get("required_capabilities") != null);

            // KEPT, and this is the whole safety argument for scoping. A model
            // choosing a module still learns that zttp:sql registers a
            // statement by name and that sqlMany takes that name, not SQL.
            // (Return types are asserted separately, below.)
            const summary = m.get("summary").?.string;
            try testing.expect(std.mem.indexOf(u8, summary, "never SQL text") != null);
            for (m.get("exports").?.array.items) |exp_value| {
                const exp = exp_value.object;
                try testing.expect(exp.get("effect") != null);
                if (!std.mem.eql(u8, exp.get("name").?.string, "sqlMany")) continue;
                const params = exp.get("params").?.array;
                try testing.expectEqualStrings("name", params.items[0].string);
                try testing.expectEqualStrings("params?", params.items[1].string);
            }
        }
    }
    // The floor. A payload that stopped emitting either shape would satisfy
    // every assertion above by never running one.
    try testing.expect(saw_imported);
    try testing.expect(saw_unimported);
}

// Discovery must publish the return type for each export. Assert the value,
// because a field-presence test would pass on the unhelpful `object` value.
test "module discovery says what each export answers with" {
    const a = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "handler.ts", .data =
        \\import { parseBearer } from "zttp:auth";
        \\export function handler(req) { return Response.text(parseBearer("x")); }
        \\
    });
    const root = try std.Io.Dir.realPathFileAlloc(tmp.dir, testing.io, ".", a);
    defer a.free(root);

    const req = try a.print(
        \\{{"schema_version":2,"operation":"modules","project_root":"{s}","input":{{"file":"handler.ts"}}}}
    , .{root});
    defer a.free(req);
    const out = try respond(a, req);
    defer a.free(out);

    var parsed = try parse(a, out);
    defer parsed.deinit();
    const payload = parsed.value.object.get("payload").?.object;

    var saw_optional = false;
    for (payload.get("builtins").?.array.items) |module| {
        const m = module.object;
        const spec = m.get("specifier").?.string;
        for (m.get("exports").?.array.items) |exp_value| {
            const exp = exp_value.object;
            const name = exp.get("name").?.string;
            const returns = exp.get("returns").?.string;

            // The coarse kind, rendered the way the rest of the surface renders
            // it. This exact fact is what jwt-auth needed: `string?` says the
            // result must be narrowed, not destructured as a Result.
            if (std.mem.eql(u8, spec, "zttp:auth") and std.mem.eql(u8, name, "parseBearer")) {
                saw_optional = true;
                try testing.expectEqualStrings("string?", returns);
            }
        }
    }
    // The floor prevents success when the payload stops carrying the export.
    try testing.expect(saw_optional);
}

test "a file-bound operation binds the graph digest, not the context-free one" {
    const a = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "handler.ts",
        .data = "export function handler(req) { return Response.json({ ok: true }); }\n",
    });
    const root = try std.Io.Dir.realPathFileAlloc(tmp.dir, testing.io, ".", a);
    defer a.free(root);

    const req = try a.print(
        \\{{"schema_version":2,"operation":"modules","project_root":"{s}","input":{{"file":"handler.ts"}}}}
    , .{root});
    defer a.free(req);
    const out = try respond(a, req);
    defer a.free(out);
    var parsed = try parse(a, out);
    defer parsed.deinit();

    const bound = parsed.value.object.get("module_graph_hash").?.string;
    try testing.expect(!std.mem.eql(u8, bound, &module_graph_record.contextFreeHash()));
}

test "modules reports a rejected import and stops claiming success" {
    const a = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "handler.ts",
        .data = "import { gone } from \"./gone.ts\";\nexport const x = gone;\n",
    });
    const root = try std.Io.Dir.realPathFileAlloc(tmp.dir, testing.io, ".", a);
    defer a.free(root);

    const req = try a.print(
        \\{{"schema_version":2,"operation":"modules","project_root":"{s}","input":{{"file":"handler.ts"}}}}
    , .{root});
    defer a.free(req);
    const out = try respond(a, req);
    defer a.free(out);
    var parsed = try parse(a, out);
    defer parsed.deinit();

    const obj = parsed.value.object;
    // The environment resolved, so this is not a protocol error - but it did
    // not resolve completely, so it is not a success either.
    try testing.expect(!obj.get("success").?.bool);
    try testing.expect(obj.get("error") == null);
    const rejected = obj.get("payload").?.object.get("rejected").?.array;
    try testing.expectEqual(@as(usize, 1), rejected.items.len);
    try testing.expectEqualStrings("file_unreadable", rejected.items[0].object.get("reason").?.string);
}

test "modules without input.file is malformed, not an empty graph" {
    const a = testing.allocator;
    const out = try respond(a,
        \\{"schema_version":2,"operation":"modules","project_root":".","input":{}}
    );
    defer a.free(out);
    var parsed = try parse(a, out);
    defer parsed.deinit();
    const err = parsed.value.object.get("error").?.object;
    try testing.expectEqualStrings("malformed_request", err.get("code").?.string);
    try testing.expectEqualStrings("input.file", err.get("field").?.string);
}

test "modules on a path outside the project root is refused" {
    const a = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "app");
    const base = try std.Io.Dir.realPathFileAlloc(tmp.dir, testing.io, "app", a);
    defer a.free(base);

    const req = try a.print(
        \\{{"schema_version":2,"operation":"modules","project_root":"{s}","input":{{"file":"../escape.ts"}}}}
    , .{base});
    defer a.free(req);
    const out = try respond(a, req);
    defer a.free(out);
    var parsed = try parse(a, out);
    defer parsed.deinit();
    const err = parsed.value.object.get("error").?.object;
    try testing.expectEqualStrings("path_outside_project_root", err.get("code").?.string);
    try testing.expectEqualStrings("input.file", err.get("field").?.string);
}

test "modules on a missing entry file reports file_unreadable" {
    const a = testing.allocator;
    const out = try respond(a,
        \\{"schema_version":2,"operation":"modules","project_root":".","input":{"file":"no/such/handler.ts"}}
    );
    defer a.free(out);
    var parsed = try parse(a, out);
    defer parsed.deinit();
    const err = parsed.value.object.get("error").?.object;
    try testing.expectEqualStrings("file_unreadable", err.get("code").?.string);
}

test "a missing JavaScript root is unreadable before extension validation" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.Io.Dir.realPathFileAlloc(tmp.dir, testing.io, ".", allocator);
    defer allocator.free(root);
    const request = try allocator.print(
        \\{{"schema_version":2,"operation":"modules","project_root":"{s}","input":{{"file":"missing.js"}}}}
    , .{root});
    defer allocator.free(request);

    const raw = try respond(allocator, request);
    defer allocator.free(raw);
    var response = try parse(allocator, raw);
    defer response.deinit();
    const protocol_error = response.value.object.get("error").?.object;
    try testing.expectEqualStrings("file_unreadable", protocol_error.get("code").?.string);
}

test "an oversized JavaScript root is unreadable before extension validation" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const oversized = try allocator.alloc(u8, module_graph_record.max_source_bytes + 1);
    defer allocator.free(oversized);
    @memset(oversized, ' ');
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "h.js", .data = oversized });
    const root = try std.Io.Dir.realPathFileAlloc(tmp.dir, testing.io, ".", allocator);
    defer allocator.free(root);
    const request = try allocator.print(
        \\{{"schema_version":2,"operation":"modules","project_root":"{s}","input":{{"file":"h.js"}}}}
    , .{root});
    defer allocator.free(request);

    const raw = try respond(allocator, request);
    defer allocator.free(raw);
    var response = try parse(allocator, raw);
    defer response.deinit();
    const protocol_error = response.value.object.get("error").?.object;
    try testing.expectEqualStrings("file_unreadable", protocol_error.get("code").?.string);
}

test "modules refuses a JavaScript entry extension" {
    const a = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "handler.js",
        .data = "export function handler(req) { return Response.text('ok'); }\n",
    });
    const root = try std.Io.Dir.realPathFileAlloc(tmp.dir, testing.io, ".", a);
    defer a.free(root);
    const req = try a.print(
        \\{{"schema_version":2,"operation":"modules","project_root":"{s}","input":{{"file":"handler.js"}}}}
    , .{root});
    defer a.free(req);

    const out = try respond(a, req);
    defer a.free(out);
    var parsed = try parse(a, out);
    defer parsed.deinit();
    const err = parsed.value.object.get("error").?.object;
    try testing.expectEqualStrings("unsupported_source_extension", err.get("code").?.string);
    try testing.expectEqualStrings("input.file", err.get("field").?.string);
}

test "a stale module_graph_hash is caught against the real graph" {
    const a = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "handler.ts",
        .data = "export function handler(req) { return Response.json({ ok: true }); }\n",
    });
    const root = try std.Io.Dir.realPathFileAlloc(tmp.dir, testing.io, ".", a);
    defer a.free(root);

    // The context-free digest is a real hash, and the wrong one for a file
    // request: the guard must compare against what the operation read.
    const req = try a.print(
        \\{{"schema_version":2,"operation":"modules","project_root":"{s}","input":{{"file":"handler.ts"}},
        \\ "expected":{{"module_graph_hash":"{s}"}}}}
    , .{ root, module_graph_record.contextFreeHash() });
    defer a.free(req);
    const out = try respond(a, req);
    defer a.free(out);
    var parsed = try parse(a, out);
    defer parsed.deinit();
    const err = parsed.value.object.get("error").?.object;
    try testing.expectEqualStrings("identity_mismatch", err.get("code").?.string);
    try testing.expectEqualStrings("expected.module_graph_hash", err.get("field").?.string);
}

test "modules binds its root record to one captured source" {
    const allocator = testing.allocator;
    const source_a = "export const value = 1;\n";
    const source_b = "export const value = 2;\n";

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "h.ts", .data = source_a });
    const root = try std.Io.Dir.realPathFileAlloc(tmp.dir, testing.io, ".", allocator);
    defer allocator.free(root);
    const request = try allocator.print(
        \\{{"schema_version":2,"operation":"modules","project_root":"{s}","input":{{"file":"h.ts"}}}}
    , .{root});
    defer allocator.free(request);

    var changing_reader = ChangingRootReader{
        .directory = tmp.dir,
        .path = "h.ts",
        .replacement = source_b,
    };
    const raw = try respondWithRootSourceReader(
        allocator,
        request,
        changing_reader.rootSourceReader(),
    );
    defer allocator.free(raw);
    try testing.expectEqual(@as(u32, 1), changing_reader.read_count);

    var response = try parse(allocator, raw);
    defer response.deinit();
    const graph = response.value.object.get("payload").?.object.get("graph").?.array;
    try testing.expectEqual(@as(usize, 1), graph.items.len);
    try testing.expectEqualStrings("h.ts", graph.items[0].object.get("path").?.string);
    const expected_digest = agent_identity.sourceDigest(source_a);
    try testing.expectEqualStrings(
        &expected_digest,
        graph.items[0].object.get("source_digest").?.string,
    );

    const on_disk = try tmp.dir.readFileAlloc(testing.io, "h.ts", allocator, .limited(4096));
    defer allocator.free(on_disk);
    try testing.expectEqualStrings(source_b, on_disk);
}

test "meta publishes the verifier registry it will answer about" {
    const a = testing.allocator;
    const out = try respond(a,
        \\{"schema_version":2,"operation":"meta","project_root":"."}
    );
    defer a.free(out);
    var parsed = try parse(a, out);
    defer parsed.deinit();

    const verifiers = parsed.value.object.get("payload").?.object.get("verifiers").?.array;
    try testing.expectEqual(zts.proof_trace.verifiers.len, verifiers.items.len);

    // The registry advertises wire names. Publishing the internal spelling
    // would name a property `verify` then answers `unknown_property` about.
    var saw_results_safe = false;
    for (verifiers.items) |item| {
        const id = item.object.get("property").?.string;
        try testing.expect(zts.proof_trace.verifierKind(id) != null);
        if (std.mem.eql(u8, id, "results_safe")) saw_results_safe = true;
    }
    try testing.expect(saw_results_safe);

    // The section retires in the same change that makes it answerable.
    for (parsed.value.object.get("payload").?.object.get("deferred_sections").?.array.items) |section| {
        try testing.expect(!std.mem.eql(u8, section.object.get("name").?.string, "verifiers"));
    }
}

test "every verifier row publishes spec 4.8's required inputs, prerequisites, grades, and result schema" {
    // Spec 4.8: "`meta.payload.verifiers` MUST enumerate each property
    // identifier, required inputs, prerequisites, possible assurance grades,
    // and result schema. An agent never chooses among undocumented
    // verification commands." Published for EVERY row, not just the first, and
    // asserted non-empty: four empty arrays would satisfy "the field exists"
    // while documenting nothing.
    const a = testing.allocator;
    const out = try respond(a,
        \\{"schema_version":2,"operation":"meta","project_root":"."}
    );
    defer a.free(out);
    var parsed = try parse(a, out);
    defer parsed.deinit();

    const verifiers = parsed.value.object.get("payload").?.object.get("verifiers").?.array;
    try testing.expect(verifiers.items.len > 0);
    try testing.expectEqual(zts.proof_trace.verifiers.len, verifiers.items.len);

    for (verifiers.items, zts.proof_trace.verifiers) |item, registry| {
        const row = item.object;
        const registry_fields = [_][]const []const u8{ registry.inputs, registry.prerequisites, registry.grades };
        for ([_][]const u8{ "inputs", "prerequisites", "grades" }, registry_fields) |field, expected| {
            const arr = row.get(field).?.array;
            try testing.expect(arr.items.len > 0);
            try testing.expectEqual(expected.len, arr.items.len);
            for (expected, arr.items) |want, entry| try testing.expectEqualStrings(want, entry.string);
        }
        const schema = row.get("result_schema").?.array;
        try testing.expect(schema.items.len > 0);
        try testing.expectEqual(registry.result_schema.len, schema.items.len);
        for (registry.result_schema, schema.items) |want, field| {
            try testing.expectEqualStrings(want.name, field.object.get("name").?.string);
            try testing.expectEqualStrings(want.json_type, field.object.get("type").?.string);
            try testing.expectEqualStrings(want.presence, field.object.get("presence").?.string);
        }
    }
}

fn metaPayload(a: std.mem.Allocator, out: *[]u8) !std.json.Parsed(std.json.Value) {
    out.* = try respond(a,
        \\{"schema_version":2,"operation":"meta","project_root":".","input":{}}
    );
    return parse(a, out.*);
}

test "meta publishes the registry hashes it binds work to" {
    const a = testing.allocator;
    var raw: []u8 = undefined;
    var parsed = try metaPayload(a, &raw);
    defer a.free(raw);
    defer parsed.deinit();

    const payload = parsed.value.object.get("payload").?.object;
    try testing.expectEqualStrings(&zts.policyHash(), payload.get("policy_hash").?.string);
    try testing.expectEqualStrings(&zts.grammarHash(), payload.get("grammar_hash").?.string);
    try testing.expectEqualStrings(&zts.idiomTableHash(), payload.get("idiom_table_hash").?.string);
    try testing.expectEqualStrings(&zts.restrictionMatrixHash(), payload.get("restriction_matrix_hash").?.string);
    try testing.expectEqual(@as(usize, 64), payload.get("builtin_registry_hash").?.string.len);
}

test "meta publishes the closed severity set and the rule that decides success" {
    const a = testing.allocator;
    var raw: []u8 = undefined;
    var parsed = try metaPayload(a, &raw);
    defer a.free(raw);
    defer parsed.deinit();

    const severities = parsed.value.object.get("payload").?.object.get("severities").?.object;
    const set = severities.get("set").?.array;
    // Derived from the stable projection, so the wire set is what every checker
    // can emit - three since phase 0 added advisory.
    try testing.expectEqual(
        @typeInfo(zts.DiagnosticProjection.Severity).@"enum".field_names.len,
        set.items.len,
    );
    var found_advisory = false;
    for (set.items) |item| {
        if (std.mem.eql(u8, item.string, "advisory")) found_advisory = true;
    }
    try testing.expect(found_advisory);
    try testing.expect(std.mem.indexOf(u8, severities.get("success_rule").?.string, "no error diagnostic") != null);
}

test "meta publishes an advisory-only idiom table" {
    const a = testing.allocator;
    var raw: []u8 = undefined;
    var parsed = try metaPayload(a, &raw);
    defer a.free(raw);
    defer parsed.deinit();

    const idioms = parsed.value.object.get("payload").?.object.get("idioms").?.array;
    try testing.expectEqual(idiomCatalog.idioms().len, idioms.items.len);

    var wired: usize = 0;
    for (idioms.items) |item| {
        const row = item.object;
        try testing.expect(std.mem.startsWith(u8, row.get("id").?.string, "idiom."));
        try testing.expect(row.get("precondition").? == .string);
        if (row.get("rewrite_rule").? == .string) {
            wired += 1;
            // A named rewrite must resolve back to this row, or the mapping a
            // client follows from a normalize trace is broken.
            const entry = idiomCatalog.findByRewriteRule(row.get("rewrite_rule").?.string).?;
            try testing.expectEqualStrings(row.get("id").?.string, entry.id);
        }
    }
    // The current table is wholly advisory. Mechanical repairs belong to
    // diagnostics, not stylistic alternatives.
    try testing.expectEqual(@as(usize, 0), wired);
}

test "meta limits are the constants the code enforces" {
    const a = testing.allocator;
    var raw: []u8 = undefined;
    var parsed = try metaPayload(a, &raw);
    defer a.free(raw);
    defer parsed.deinit();

    const limits = parsed.value.object.get("payload").?.object.get("limits").?.object;
    try testing.expectEqual(
        @as(i64, canonicalize.max_normalize_iterations),
        limits.get("normalize_iterations").?.integer,
    );
    try testing.expectEqual(
        @as(i64, @intCast(edit_simulate.max_stdin_json_bytes)),
        limits.get("request_bytes").?.integer,
    );
    try testing.expectEqual(
        @as(i64, @intCast(module_graph_record.max_source_bytes)),
        limits.get("source_bytes").?.integer,
    );
    try testing.expectEqual(
        @as(i64, @intCast(module_graph_record.max_modules)),
        limits.get("module_graph_modules").?.integer,
    );
}

test "meta publishes the built-in module catalog from the bindings" {
    const a = testing.allocator;
    var raw: []u8 = undefined;
    var parsed = try metaPayload(a, &raw);
    defer a.free(raw);
    defer parsed.deinit();

    const catalog = parsed.value.object.get("payload").?.object.get("module_catalog").?.array;
    try testing.expectEqual(zts.builtinModules.len, catalog.items.len);
    for (catalog.items, zts.builtinModules) |item, binding| {
        const module = item.object;
        try testing.expect(std.mem.startsWith(u8, module.get("specifier").?.string, "zttp:"));
        try testing.expect(module.get("exports").?.array.items.len >= 1);
        try testing.expectEqual(binding.exports.len, module.get("exports").?.array.items.len);
        try testing.expect(module.get("required_capabilities").? == .array);
    }
}

test "meta publishes every decision kind a refusal can carry, with its next action" {
    const a = testing.allocator;
    var raw: []u8 = undefined;
    var parsed = try metaPayload(a, &raw);
    defer a.free(raw);
    defer parsed.deinit();

    const section = parsed.value.object.get("payload").?.object.get("decisions").?.object;
    try testing.expectEqual(@as(i64, decision_registry.version), section.get("version").?.integer);

    const kinds = section.get("kinds").?.array;
    try testing.expectEqual(decision_registry.decisions.len, kinds.items.len);
    for (kinds.items, &decision_registry.decisions) |item, row| {
        const published = item.object;
        try testing.expectEqualStrings(row.id.wire(), published.get("id").?.string);
        try testing.expectEqualStrings(@tagName(row.next_action), published.get("next_action").?.string);
        const parameters = published.get("parameters").?.array;
        try testing.expect(parameters.items.len > 0);
        try testing.expectEqual(row.parameters.len, parameters.items.len);
        for (row.parameters, parameters.items) |want, got| try testing.expectEqualStrings(want, got.string);
    }

    for (parsed.value.object.get("payload").?.object.get("deferred_sections").?.array.items) |section_row| {
        try testing.expect(!std.mem.eql(u8, section_row.object.get("name").?.string, "decisions"));
    }
}

test "the examples section stops being deferred" {
    const a = testing.allocator;
    var raw: []u8 = undefined;
    var parsed = try metaPayload(a, &raw);
    defer a.free(raw);
    defer parsed.deinit();

    const payload = parsed.value.object.get("payload").?.object;
    const rows = payload.get("examples").?.array;
    try testing.expectEqual(example_registry.examples.len, rows.items.len);
    for (rows.items, &example_registry.examples) |item, entry| {
        try testing.expectEqualStrings(entry.feature, item.object.get("feature").?.string);
        try testing.expectEqualStrings(entry.source, item.object.get("source").?.string);
    }
    for (payload.get("deferred_sections").?.array.items) |section| {
        try testing.expect(!std.mem.eql(u8, section.object.get("name").?.string, "examples"));
    }
}

test "meta publishes compiler-owned module examples exactly" {
    const a = testing.allocator;
    var raw: []u8 = undefined;
    var parsed = try metaPayload(a, &raw);
    defer a.free(raw);
    defer parsed.deinit();

    const rows = parsed.value.object.get("payload").?.object.get("module_examples").?.array;
    try testing.expectEqual(example_registry.module_examples.len, rows.items.len);
    for (rows.items, &example_registry.module_examples) |item, entry| {
        const object = item.object;
        try testing.expectEqualStrings(entry.name, object.get("name").?.string);
        try testing.expectEqualStrings(entry.purpose, object.get("purpose").?.string);
        try testing.expectEqualStrings(entry.source, object.get("source").?.string);
        const modules = object.get("modules").?.array;
        try testing.expectEqual(entry.modules.len, modules.items.len);
        for (modules.items, entry.modules) |module, expected| {
            try testing.expectEqualStrings(expected, module.string);
        }
    }
}

test "meta publishes section 8's grammar production for production, in order" {
    const a = testing.allocator;
    var raw: []u8 = undefined;
    var parsed = try metaPayload(a, &raw);
    defer a.free(raw);
    defer parsed.deinit();

    const payload = parsed.value.object.get("payload").?.object;
    try testing.expectEqualStrings(&zts.grammarHash(), payload.get("grammar_hash").?.string);
    const rows = payload.get("grammar").?.array;
    const table = zts.GrammarCatalog.productions();
    try testing.expectEqual(table.len, rows.items.len);

    // Order is part of the published artifact: the document reads top down, and
    // the drift gate compares the two in that order.
    for (rows.items, table) |item, p| {
        const row = item.object;
        try testing.expectEqualStrings(p.name, row.get("name").?.string);
        try testing.expectEqualStrings(p.rhs, row.get("rhs").?.string);
        try testing.expectEqualStrings(p.enforcement.id(), row.get("enforcement").?.string);
    }
    try testing.expectEqualStrings("Module", rows.items[0].object.get("name").?.string);
}

test "a production that over-admits says which rule refuses the excess" {
    const a = testing.allocator;
    var raw: []u8 = undefined;
    var parsed = try metaPayload(a, &raw);
    defer a.free(raw);
    defer parsed.deinit();

    const rows = parsed.value.object.get("payload").?.object.get("grammar").?.array;

    var check_rows: usize = 0;
    for (rows.items) |item| {
        const row = item.object;
        const has_code = row.get("rule_code").? != .null;
        const has_note = row.get("note").? != .null;
        if (std.mem.eql(u8, row.get("enforcement").?.string, "parse_time")) {
            try testing.expect(!has_code and !has_note);
            continue;
        }
        check_rows += 1;
        // Exactly one of the two, on the wire as well as in the table: a row
        // that says "something else refuses this" and names nothing is not
        // actionable by the client reading it.
        try testing.expect(has_code != has_note);
        if (has_code) {
            const code = row.get("rule_code").?.string;
            try testing.expect(zts.PolicyCatalog.findByCode(code) != null);
        }
    }
    // Assert the count the source registry states, not a floor beneath it. A
    // payload of nothing but parse_time rows would satisfy the loop while
    // publishing the over-approximation as if it were exact, and a hand-pinned
    // number both has to be edited in lockstep with every grammar cut and
    // still passes when the projection silently drops rows.
    var expected_check_rows: usize = 0;
    for (zts.GrammarCatalog.productions()) |p| {
        if (p.enforcement != .parse_time) expected_check_rows += 1;
    }
    // The gate's own input: a catalog whose every row said parse_time would
    // make the equality below true by checking nothing.
    try testing.expect(expected_check_rows > 0);
    try testing.expectEqual(expected_check_rows, check_rows);
}

test "the grammar section stops being deferred" {
    const a = testing.allocator;
    var raw: []u8 = undefined;
    var parsed = try metaPayload(a, &raw);
    defer a.free(raw);
    defer parsed.deinit();

    for (parsed.value.object.get("payload").?.object.get("deferred_sections").?.array.items) |section| {
        try testing.expect(!std.mem.eql(u8, section.object.get("name").?.string, "grammar"));
    }
}

test "meta publishes the ambient value names as the known-globals list itself" {
    const a = testing.allocator;
    var raw: []u8 = undefined;
    var parsed = try metaPayload(a, &raw);
    defer a.free(raw);
    defer parsed.deinit();

    const ambient = parsed.value.object.get("payload").?.object.get("ambient_names").?.object;
    const values = ambient.get("values").?.array;

    // Both directions against the source list: a global the checker knows and
    // this does not publish teaches an agent to import a name it need not, and
    // a name published here that the checker does not know teaches it to call
    // one that does not exist.
    const known = zts.AmbientCatalog.valueNames();
    try testing.expectEqual(known.len, values.items.len);
    for (known, 0..) |name, i| {
        try testing.expectEqualStrings(name, values.items[i].string);
    }
}

test "every published ambient type name carries its origin and its arity" {
    const a = testing.allocator;
    var raw: []u8 = undefined;
    var parsed = try metaPayload(a, &raw);
    defer a.free(raw);
    defer parsed.deinit();

    const ambient = parsed.value.object.get("payload").?.object.get("ambient_names").?.object;
    const rows = ambient.get("types").?.array;
    const table = zts.AmbientCatalog.typeNames();
    try testing.expectEqual(table.len, rows.items.len);

    var saw_generic = false;
    for (rows.items, table) |item, entry| {
        const row = item.object;
        try testing.expectEqualStrings(entry.name, row.get("name").?.string);
        try testing.expectEqualStrings(entry.origin.id(), row.get("origin").?.string);
        try testing.expectEqual(@as(i64, entry.arity), row.get("arity").?.integer);
        if (entry.arity > 0) saw_generic = true;
    }
    // The floor for the arity field: a table of arity-zero rows would satisfy
    // the loop above while proving nothing about the field.
    try testing.expect(saw_generic);

    // `Dict` is the value kind spec 6.2 names, and it is written with two type
    // arguments or not at all.
    var dict_arity: ?u8 = null;
    for (table) |entry| {
        if (std.mem.eql(u8, entry.name, "Dict")) dict_arity = entry.arity;
    }
    try testing.expectEqual(@as(?u8, 2), dict_arity);
}

test "meta publishes the type serialization version a cached digest is valid under" {
    const a = testing.allocator;
    var raw: []u8 = undefined;
    var parsed = try metaPayload(a, &raw);
    defer a.free(raw);
    defer parsed.deinit();

    const section = parsed.value.object.get("payload").?.object.get("type_serialization").?.object;
    try testing.expectEqual(@as(i64, zts.TypeSerialization.version), section.get("version").?.integer);
    try testing.expectEqualStrings("sha256", section.get("digest_algorithm").?.string);
    try testing.expectEqual(@as(i64, zts.TypeSerialization.max_depth), section.get("max_depth").?.integer);
}

test "the two sections this change makes answerable stop being deferred" {
    const a = testing.allocator;
    var raw: []u8 = undefined;
    var parsed = try metaPayload(a, &raw);
    defer a.free(raw);
    defer parsed.deinit();

    for (parsed.value.object.get("payload").?.object.get("deferred_sections").?.array.items) |section| {
        const name = section.object.get("name").?.string;
        try testing.expect(!std.mem.eql(u8, name, "ambient_names"));
        try testing.expect(!std.mem.eql(u8, name, "type_serialization"));
    }
}

test "the repair budget is deferred rather than guessed" {
    // Spec 4.8 asks limits to publish a repair-iteration and tool-call budget.
    // No code implements that loop policy, so it is named as deferred instead
    // of appearing as an invented number.
    const a = testing.allocator;
    var raw: []u8 = undefined;
    var parsed = try metaPayload(a, &raw);
    defer a.free(raw);
    defer parsed.deinit();

    const payload = parsed.value.object.get("payload").?.object;
    try testing.expect(payload.get("limits").?.object.get("repair_iterations") == null);
    var named = false;
    for (payload.get("deferred_sections").?.array.items) |section| {
        if (std.mem.eql(u8, section.object.get("name").?.string, "repair_budget")) named = true;
    }
    try testing.expect(named);
}

test "identical requests produce byte-identical responses" {
    const a = testing.allocator;
    const req =
        \\{"schema_version":2,"operation":"meta","project_root":".","input":{}}
    ;
    const first = try respond(a, req);
    defer a.free(first);
    const second = try respond(a, req);
    defer a.free(second);
    try testing.expectEqualStrings(first, second);
}
