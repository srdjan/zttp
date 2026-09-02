//! Typed identities for expert evaluation inputs, cohorts, and observed runs.
//!
//! Each identity has one authority and one domain. Inputs that change what the
//! model sees are deliberately separate from intent, probes, thresholds, and
//! observed results, so a pinned outcome can never move the headline input ID.

const std = @import("std");
const codegen_types = @import("expert_codegen_types.zig");
const models = @import("providers/models.zig");
const request_policy = @import("providers/request_policy.zig");
const tool_catalog = @import("providers/tool_catalog.zig");

fn TypedIdentity(comptime domain: []const u8) type {
    return struct {
        pub const domain_tag = domain;

        bytes: [64]u8,

        pub fn eql(a: @This(), b: @This()) bool {
            return std.mem.eql(u8, &a.bytes, &b.bytes);
        }

        pub fn slice(self: *const @This()) []const u8 {
            return &self.bytes;
        }
    };
}

pub const ContentDigest = TypedIdentity("zttp-expert-content-digest-v1");
pub const PromptPersonaIdentity = TypedIdentity("zttp-expert-prompt-persona-v1");
pub const ProviderNeutralCatalogIdentity = TypedIdentity("zttp-expert-provider-neutral-catalog-v1");
pub const ProviderSerializedCatalogIdentity = TypedIdentity("zttp-expert-provider-serialized-catalog-v1");
pub const SchemaIdentity = TypedIdentity("zttp-expert-schema-v1");
pub const MetaIdentity = TypedIdentity("zttp-expert-meta-v1");
pub const GrammarIdentity = TypedIdentity("zttp-expert-grammar-v1");
pub const SemanticsIdentity = TypedIdentity("zttp-expert-semantics-v1");
pub const DiagnosticIdentity = TypedIdentity("zttp-expert-diagnostics-v1");
pub const PolicyIdentity = TypedIdentity("zttp-expert-policy-v1");
pub const HeadlineInputIdentity = TypedIdentity("zttp-expert-headline-input-v1");
pub const IntentSuiteIdentity = TypedIdentity("zttp-expert-intent-suite-v1");
pub const SecurityProbeCorpusIdentity = TypedIdentity("zttp-expert-security-probes-v2");
pub const ThresholdIdentity = TypedIdentity("zttp-expert-thresholds-v1");
pub const ManifestIdentity = TypedIdentity("zttp-expert-manifest-v1");
pub const ResultRunIdentity = TypedIdentity("zttp-expert-result-run-v1");

comptime {
    // Every identity above has the same single `bytes: [64]u8` field, so what
    // makes them distinct types is `domain_tag` capturing the comptime domain.
    // A struct returned by a comptime function is distinct only for the values
    // its body captures.
    //
    // Deleting `domain_tag` is already a compile error, twice over: the sixteen
    // `FramedHasher.init(X.domain_tag)` call sites below read it, and the
    // parameter would go unused. That regression needs no guard.
    //
    // This guards the one that compiles: a `domain_tag` that still exists but
    // stops deriving from the parameter, such as a hardcoded string. The call
    // sites keep resolving, so nothing complains, while every identity collapses
    // into one type and every hasher silently shares one domain. A ContentDigest
    // would pass where a PolicyIdentity is required and `eql` would compare
    // across domains.
    //
    // This reads the identities back out of the file by shape, so a new one
    // needs no edit here.
    const decls = @typeInfo(@This()).@"struct".decls;
    var identities: [decls.len]type = undefined;
    var found: usize = 0;
    for (decls) |decl| {
        const Candidate = @field(@This(), decl.name);
        if (@TypeOf(Candidate) != type) continue;
        const info = @typeInfo(Candidate);
        if (info != .@"struct") continue;
        const fields = info.@"struct".fields;
        if (fields.len != 1) continue;
        if (!std.mem.eql(u8, fields[0].name, "bytes")) continue;
        if (fields[0].type != [64]u8) continue;
        identities[found] = Candidate;
        found += 1;
    }
    if (found < 2) @compileError("the identity types are no longer discoverable here");
    for (0..found) |left| for (left + 1..found) |right| {
        if (identities[left] == identities[right]) {
            @compileError("two identities share one type: the domain is no longer captured");
        }
    };
}

pub const HeadlineCase = struct {
    name: []const u8,
    prompt: []const u8,
    seed_files: []const codegen_types.SeedFile = &.{},
    mode: codegen_types.InputMode,
};

pub const IntentScenario = union(enum) {
    compiler_veto_only: struct {
        name: []const u8,
        reason: []const u8,
    },
    runtime: struct {
        name: []const u8,
        spec: []const u8,
        runner: []const u8,
        revision: ?[]const u8 = null,
        handler_path: []const u8,
        config: ?[]const u8 = null,
        runtime_files: []const codegen_types.SeedFile = &.{},
    },
};

pub const SecurityProbeDiagnosticSeverity = enum { err, warning, advisory };

pub const SecurityProbeExpectedDiagnostic = struct {
    code: []const u8,
    severity: SecurityProbeDiagnosticSeverity,
};

pub const SecurityProbeDiagnosticExpectation = struct {
    primary: []const u8,
    exact_diagnostics: []const SecurityProbeExpectedDiagnostic,
};

pub const PositiveSecurityProbeExpectation = union(enum) {
    property: struct {
        name: []const u8,
        value: bool,
    },
    capability_budget: []const []const u8,
};

pub const SecurityProbeClaim = union(enum) {
    positive: PositiveSecurityProbeExpectation,
    adversarial: SecurityProbeDiagnosticExpectation,
};

pub const SecurityProbe = struct {
    scenario: []const u8,
    family: []const u8,
    source: []const u8,
    claim: SecurityProbeClaim,
};

pub const ExpectedVerdict = enum { pass, fail };
pub const Metric = enum {
    raw_first_draft_pass,
    first_attempt_green,
    final_green,
    runtime_intent,
};

pub const ExpectedOutcome = struct {
    scenario: []const u8,
    metric: Metric,
    verdict: ExpectedVerdict,
};

pub const ThresholdComparison = enum { at_least, exactly, at_most };

pub const NamedThreshold = struct {
    name: []const u8,
    comparison: ThresholdComparison,
    value: u64,
};

pub const ManifestComponents = struct {
    headline_input: HeadlineInputIdentity,
    intent_suite: IntentSuiteIdentity,
    security_probes: SecurityProbeCorpusIdentity,
    thresholds: ThresholdIdentity,
};

pub const CatalogIdentities = struct {
    provider_neutral: ProviderNeutralCatalogIdentity,
    provider_serialized: ProviderSerializedCatalogIdentity,
};

pub const CompilerIdentities = struct {
    schema: SchemaIdentity,
    meta: MetaIdentity,
    grammar: GrammarIdentity,
    semantics: SemanticsIdentity,
    diagnostics: DiagnosticIdentity,
    policy: PolicyIdentity,
};

pub const RequestPolicy = struct {
    max_output_tokens: u32,
    reserve_tokens: u64,
    stream: bool,
    purpose: request_policy.Purpose,
    cache_policy: request_policy.CachePolicy,
};

pub const RuntimeRevision = struct {
    name: []const u8,
    revision: []const u8,
};

pub const SourceRevision = struct {
    commit: []const u8,
    dirty: bool,
};

pub const ObservedResult = struct {
    scenario: []const u8,
    artifact_identity: ?ContentDigest,
    draft_quality: codegen_types.DraftQuality,
    intent_outcome: codegen_types.IntentOutcome,
    applied: bool,
    roundtrips: u64,
};

pub const ResultRunInput = struct {
    provider: models.Provider,
    model: []const u8,
    model_revision: ?[]const u8,
    provider_runtime: ?RuntimeRevision,
    request_policy: RequestPolicy,
    prompt_persona: PromptPersonaIdentity,
    catalogs: CatalogIdentities,
    compiler: CompilerIdentities,
    cohorts: ManifestComponents,
    source_revision: SourceRevision,
    run_id: []const u8,
    observations: []const ObservedResult,
};

const FramedHasher = struct {
    state: std.crypto.hash.sha2.Sha256,

    fn init(domain: []const u8) FramedHasher {
        var out: FramedHasher = .{ .state = std.crypto.hash.sha2.Sha256.init(.{}) };
        out.field("domain", domain);
        return out;
    }

    fn frame(self: *FramedHasher, bytes: []const u8) void {
        var length: [8]u8 = undefined;
        std.mem.writeInt(u64, &length, @intCast(bytes.len), .big);
        self.state.update(&length);
        self.state.update(bytes);
    }

    fn field(self: *FramedHasher, label: []const u8, value: []const u8) void {
        self.frame(label);
        self.frame(value);
    }

    fn optionalField(self: *FramedHasher, label: []const u8, value: ?[]const u8) void {
        if (value) |present| {
            self.field(label, "present");
            self.field("optional-value", present);
        } else {
            self.field(label, "absent");
        }
    }

    fn boolField(self: *FramedHasher, label: []const u8, value: bool) void {
        self.field(label, if (value) "true" else "false");
    }

    fn u64Field(self: *FramedHasher, label: []const u8, value: u64) void {
        var bytes: [8]u8 = undefined;
        std.mem.writeInt(u64, &bytes, value, .big);
        self.field(label, &bytes);
    }

    fn digestField(self: *FramedHasher, label: []const u8, value: anytype) void {
        self.field(label, &value.bytes);
    }

    fn optionalDigestField(self: *FramedHasher, label: []const u8, value: ?ContentDigest) void {
        if (value) |present| {
            self.field(label, "present");
            self.digestField("optional-digest", present);
        } else {
            self.field(label, "absent");
        }
    }

    fn finish(self: *FramedHasher, comptime Identity: type) Identity {
        return .{ .bytes = std.fmt.bytesToHex(self.state.finalResult(), .lower) };
    }
};

pub fn contentDigest(domain: []const u8, bytes: []const u8) ContentDigest {
    var hasher = FramedHasher.init(ContentDigest.domain_tag);
    hasher.field("content-domain", domain);
    hasher.field("content", bytes);
    return hasher.finish(ContentDigest);
}

pub fn contentDigestParts(domain: []const u8, parts: []const []const u8) ContentDigest {
    var hasher = FramedHasher.init(ContentDigest.domain_tag);
    hasher.field("content-domain", domain);
    hasher.u64Field("part-count", parts.len);
    for (parts, 0..) |part, index| {
        hasher.u64Field("part-index", index);
        hasher.field("part", part);
    }
    return hasher.finish(ContentDigest);
}

test "content digest parts bind boundaries order and domain" {
    const baseline = contentDigestParts("responses", &.{ "ab", "c" });
    try std.testing.expect(baseline.eql(contentDigestParts("responses", &.{ "ab", "c" })));
    try expectChanged(baseline, contentDigestParts("responses", &.{ "a", "bc" }));
    try expectChanged(baseline, contentDigestParts("responses", &.{ "c", "ab" }));
    try expectChanged(baseline, contentDigestParts("other", &.{ "ab", "c" }));
}

pub fn promptPersona(bytes: []const u8) PromptPersonaIdentity {
    var hasher = FramedHasher.init(PromptPersonaIdentity.domain_tag);
    hasher.field("prompt-persona-bytes", bytes);
    return hasher.finish(PromptPersonaIdentity);
}

pub fn schema(bytes: []const u8) SchemaIdentity {
    var hasher = FramedHasher.init(SchemaIdentity.domain_tag);
    hasher.field("schema-bytes", bytes);
    return hasher.finish(SchemaIdentity);
}

pub fn meta(bytes: []const u8) MetaIdentity {
    var hasher = FramedHasher.init(MetaIdentity.domain_tag);
    hasher.field("meta-bytes", bytes);
    return hasher.finish(MetaIdentity);
}

pub fn grammar(bytes: []const u8) GrammarIdentity {
    var hasher = FramedHasher.init(GrammarIdentity.domain_tag);
    hasher.field("grammar-bytes", bytes);
    return hasher.finish(GrammarIdentity);
}

pub fn semantics(bytes: []const u8) SemanticsIdentity {
    var hasher = FramedHasher.init(SemanticsIdentity.domain_tag);
    hasher.field("semantics-bytes", bytes);
    return hasher.finish(SemanticsIdentity);
}

pub fn diagnostics(bytes: []const u8) DiagnosticIdentity {
    var hasher = FramedHasher.init(DiagnosticIdentity.domain_tag);
    hasher.field("diagnostic-bytes", bytes);
    return hasher.finish(DiagnosticIdentity);
}

pub fn policy(bytes: []const u8) PolicyIdentity {
    var hasher = FramedHasher.init(PolicyIdentity.domain_tag);
    hasher.field("policy-bytes", bytes);
    return hasher.finish(PolicyIdentity);
}

pub fn providerNeutralCatalog(definitions: []const tool_catalog.Definition) ProviderNeutralCatalogIdentity {
    return .{ .bytes = tool_catalog.providerNeutralHashForDefinitions(definitions) };
}

pub fn providerSerializedCatalog(bytes: []const u8) ProviderSerializedCatalogIdentity {
    var hasher = FramedHasher.init(ProviderSerializedCatalogIdentity.domain_tag);
    hasher.field("serialized-catalog", bytes);
    return hasher.finish(ProviderSerializedCatalogIdentity);
}

pub fn headlineInput(cases: []const HeadlineCase) HeadlineInputIdentity {
    var hasher = FramedHasher.init(HeadlineInputIdentity.domain_tag);
    hasher.u64Field("case-count", cases.len);
    for (cases, 0..) |case, case_index| {
        hasher.u64Field("case-index", case_index);
        hasher.field("case-name", case.name);
        hasher.field("prompt", case.prompt);
        hasher.field("mode", @tagName(case.mode));
        hasher.u64Field("seed-count", case.seed_files.len);
        for (case.seed_files, 0..) |seed, seed_index| {
            hasher.u64Field("seed-index", seed_index);
            hasher.field("seed-path", seed.path);
            hasher.field("seed-bytes", seed.bytes);
        }
    }
    return hasher.finish(HeadlineInputIdentity);
}

pub fn intentSuite(scenarios: []const IntentScenario) IntentSuiteIdentity {
    var hasher = FramedHasher.init(IntentSuiteIdentity.domain_tag);
    hasher.u64Field("scenario-count", scenarios.len);
    for (scenarios, 0..) |scenario, scenario_index| {
        hasher.u64Field("scenario-index", scenario_index);
        switch (scenario) {
            .compiler_veto_only => |compiler_only| {
                hasher.field("scenario-name", compiler_only.name);
                hasher.optionalField("spec", null);
                hasher.field("runtime-support", "compiler-veto-only");
                hasher.field("unsupported-reason", compiler_only.reason);
                hasher.optionalField("handler-path", null);
                hasher.optionalField("config", null);
                hasher.u64Field("runtime-file-count", 0);
            },
            .runtime => |runtime| {
                hasher.field("scenario-name", runtime.name);
                hasher.optionalField("spec", runtime.spec);
                hasher.field("runtime-support", "executable");
                hasher.field("runtime-runner", runtime.runner);
                hasher.optionalField("runtime-revision", runtime.revision);
                hasher.optionalField("handler-path", runtime.handler_path);
                hasher.optionalField("config", runtime.config);
                hasher.u64Field("runtime-file-count", runtime.runtime_files.len);
                for (runtime.runtime_files, 0..) |runtime_file, file_index| {
                    hasher.u64Field("runtime-file-index", file_index);
                    hasher.field("runtime-file-path", runtime_file.path);
                    hasher.field("runtime-file-bytes", runtime_file.bytes);
                }
            },
        }
    }
    return hasher.finish(IntentSuiteIdentity);
}

pub fn securityProbeCorpus(probes: []const SecurityProbe) SecurityProbeCorpusIdentity {
    var hasher = FramedHasher.init(SecurityProbeCorpusIdentity.domain_tag);
    hasher.u64Field("probe-count", probes.len);
    for (probes, 0..) |probe, probe_index| {
        hasher.u64Field("probe-index", probe_index);
        hasher.field("scenario", probe.scenario);
        hasher.field("family", probe.family);
        hasher.field("source", probe.source);
        switch (probe.claim) {
            .adversarial => |diagnostic| {
                hasher.field("claim", "adversarial");
                hasher.field("primary-diagnostic-code", diagnostic.primary);
                hasher.u64Field("diagnostic-count", diagnostic.exact_diagnostics.len);
                for (diagnostic.exact_diagnostics, 0..) |expected, diagnostic_index| {
                    hasher.u64Field("diagnostic-index", diagnostic_index);
                    hasher.field("diagnostic-code", expected.code);
                    hasher.field("diagnostic-severity", @tagName(expected.severity));
                }
            },
            .positive => |positive| {
                hasher.field("claim", "positive");
                switch (positive) {
                    .property => |property| {
                        hasher.field("expectation", "property");
                        hasher.field("property-name", property.name);
                        hasher.boolField("property-value", property.value);
                    },
                    .capability_budget => |capabilities| {
                        hasher.field("expectation", "capability-budget");
                        hasher.u64Field("capability-count", capabilities.len);
                        for (capabilities, 0..) |capability, capability_index| {
                            hasher.u64Field("capability-index", capability_index);
                            hasher.field("capability", capability);
                        }
                    },
                }
            },
        }
    }
    return hasher.finish(SecurityProbeCorpusIdentity);
}

pub fn thresholds(
    expected_outcomes: []const ExpectedOutcome,
    named_thresholds: []const NamedThreshold,
) ThresholdIdentity {
    var hasher = FramedHasher.init(ThresholdIdentity.domain_tag);
    hasher.u64Field("expected-outcome-count", expected_outcomes.len);
    for (expected_outcomes, 0..) |expected, expected_index| {
        hasher.u64Field("expected-outcome-index", expected_index);
        hasher.field("scenario", expected.scenario);
        hasher.field("metric", @tagName(expected.metric));
        hasher.field("verdict", @tagName(expected.verdict));
    }
    hasher.u64Field("named-threshold-count", named_thresholds.len);
    for (named_thresholds, 0..) |threshold, threshold_index| {
        hasher.u64Field("named-threshold-index", threshold_index);
        hasher.field("threshold-name", threshold.name);
        hasher.field("comparison", @tagName(threshold.comparison));
        hasher.u64Field("threshold-value", threshold.value);
    }
    return hasher.finish(ThresholdIdentity);
}

pub fn manifest(components: ManifestComponents) ManifestIdentity {
    var hasher = FramedHasher.init(ManifestIdentity.domain_tag);
    hasher.digestField("headline-input", components.headline_input);
    hasher.digestField("intent-suite", components.intent_suite);
    hasher.digestField("security-probes", components.security_probes);
    hasher.digestField("thresholds", components.thresholds);
    return hasher.finish(ManifestIdentity);
}

pub fn resultRun(input: ResultRunInput) ResultRunIdentity {
    var hasher = FramedHasher.init(ResultRunIdentity.domain_tag);
    hasher.field("provider", @tagName(input.provider));
    hasher.field("model", input.model);
    hasher.optionalField("model-revision", input.model_revision);
    if (input.provider_runtime) |runtime| {
        hasher.field("provider-runtime", "present");
        hasher.field("provider-runtime-name", runtime.name);
        hasher.field("provider-runtime-revision", runtime.revision);
    } else {
        hasher.field("provider-runtime", "absent");
    }
    hasher.u64Field("max-output-tokens", input.request_policy.max_output_tokens);
    hasher.u64Field("reserve-tokens", input.request_policy.reserve_tokens);
    hasher.boolField("stream", input.request_policy.stream);
    hasher.field("request-purpose", @tagName(input.request_policy.purpose));
    hasher.field("cache-policy", @tagName(input.request_policy.cache_policy));
    hasher.digestField("prompt-persona", input.prompt_persona);
    hasher.digestField("provider-neutral-catalog", input.catalogs.provider_neutral);
    hasher.digestField("provider-serialized-catalog", input.catalogs.provider_serialized);
    hasher.digestField("schema", input.compiler.schema);
    hasher.digestField("meta", input.compiler.meta);
    hasher.digestField("grammar", input.compiler.grammar);
    hasher.digestField("semantics", input.compiler.semantics);
    hasher.digestField("diagnostics", input.compiler.diagnostics);
    hasher.digestField("policy", input.compiler.policy);
    hasher.digestField("headline-input", input.cohorts.headline_input);
    hasher.digestField("intent-suite", input.cohorts.intent_suite);
    hasher.digestField("security-probes", input.cohorts.security_probes);
    hasher.digestField("thresholds", input.cohorts.thresholds);
    hasher.digestField("manifest", manifest(input.cohorts));
    hasher.field("source-commit", input.source_revision.commit);
    hasher.boolField("source-dirty", input.source_revision.dirty);
    hasher.field("run-id", input.run_id);
    hasher.u64Field("observation-count", input.observations.len);
    for (input.observations, 0..) |observation, observation_index| {
        hasher.u64Field("observation-index", observation_index);
        hasher.field("scenario", observation.scenario);
        hasher.optionalDigestField("artifact-identity", observation.artifact_identity);
        hasher.field("draft-quality", @tagName(observation.draft_quality));
        hasher.boolField("raw-first-draft-pass", observation.draft_quality.rawFirstDraftVetoPass());
        hasher.boolField("first-attempt-green", observation.draft_quality.firstAttemptGreen());
        hasher.field("intent-outcome", @tagName(observation.intent_outcome));
        hasher.boolField("applied", observation.applied);
        hasher.u64Field("roundtrips", observation.roundtrips);
    }
    return hasher.finish(ResultRunIdentity);
}

fn testDigest(byte: u8) ContentDigest {
    return .{ .bytes = [_]u8{byte} ** 64 };
}

fn expectChanged(before: anytype, after: @TypeOf(before)) !void {
    try std.testing.expect(!before.eql(after));
}

test "cohort identities are deterministic domain separated and field isolated" {
    const seeds = [_]codegen_types.SeedFile{.{ .path = "lib/a.ts", .bytes = "export const a = 1;\n" }};
    const headline_cases = [_]HeadlineCase{
        .{ .name = "alpha", .prompt = "write alpha", .seed_files = &seeds, .mode = .whole_file },
        .{ .name = "beta", .prompt = "write beta", .mode = .holes },
    };
    const headline = headlineInput(&headline_cases);
    try std.testing.expect(headline.eql(headlineInput(&headline_cases)));

    var changed_headline = headline_cases;
    changed_headline[0].name = "changed-alpha";
    try expectChanged(headline, headlineInput(&changed_headline));
    changed_headline = headline_cases;
    changed_headline[0].prompt = "write changed alpha";
    try expectChanged(headline, headlineInput(&changed_headline));
    changed_headline = headline_cases;
    changed_headline[0].mode = .holes;
    try expectChanged(headline, headlineInput(&changed_headline));
    changed_headline = headline_cases;
    const changed_seeds = [_]codegen_types.SeedFile{.{ .path = "lib/a.ts", .bytes = "export const a = 2;\n" }};
    changed_headline[0].seed_files = &changed_seeds;
    try expectChanged(headline, headlineInput(&changed_headline));
    changed_headline = headline_cases;
    const moved_seeds = [_]codegen_types.SeedFile{.{ .path = "lib/moved.ts", .bytes = "export const a = 1;\n" }};
    changed_headline[0].seed_files = &moved_seeds;
    try expectChanged(headline, headlineInput(&changed_headline));

    const ambiguous_left = [_]HeadlineCase{
        .{ .name = "ab", .prompt = "c", .mode = .whole_file },
    };
    const ambiguous_right = [_]HeadlineCase{
        .{ .name = "a", .prompt = "bc", .mode = .whole_file },
    };
    try expectChanged(headlineInput(&ambiguous_left), headlineInput(&ambiguous_right));

    const intents = [_]IntentScenario{
        .{ .runtime = .{
            .name = "alpha",
            .spec = "{\"type\":\"test\"}\n",
            .runner = "zttp-test-jsonl",
            .revision = "1",
            .handler_path = "handler.ts",
            .config = "{\"handler\":\"handler.ts\"}",
            .runtime_files = &.{.{ .path = "system.json", .bytes = "{}" }},
        } },
        .{ .compiler_veto_only = .{
            .name = "beta",
            .reason = "compiler-boundary-probe",
        } },
    };
    const intent = intentSuite(&intents);
    try std.testing.expect(intent.eql(intentSuite(&intents)));
    var changed_intents = intents;
    changed_intents[0] = .{ .runtime = .{
        .name = "changed-alpha",
        .spec = "{\"type\":\"test\"}\n",
        .runner = "zttp-test-jsonl",
        .revision = "1",
        .handler_path = "handler.ts",
        .config = "{\"handler\":\"handler.ts\"}",
        .runtime_files = &.{.{ .path = "system.json", .bytes = "{}" }},
    } };
    try expectChanged(intent, intentSuite(&changed_intents));
    changed_intents = intents;
    changed_intents[0] = .{ .runtime = .{
        .name = "alpha",
        .spec = "changed spec",
        .runner = "zttp-test-jsonl",
        .revision = "1",
        .handler_path = "handler.ts",
        .config = "{\"handler\":\"handler.ts\"}",
        .runtime_files = &.{.{ .path = "system.json", .bytes = "{}" }},
    } };
    try expectChanged(intent, intentSuite(&changed_intents));
    changed_intents = intents;
    changed_intents[0] = .{ .runtime = .{
        .name = "alpha",
        .spec = "{\"type\":\"test\"}\n",
        .runner = "zttp-test-jsonl",
        .revision = "1",
        .handler_path = "other.ts",
        .config = "{\"handler\":\"handler.ts\"}",
        .runtime_files = &.{.{ .path = "system.json", .bytes = "{}" }},
    } };
    try expectChanged(intent, intentSuite(&changed_intents));
    changed_intents = intents;
    changed_intents[0] = .{ .runtime = .{
        .name = "alpha",
        .spec = "{\"type\":\"test\"}\n",
        .runner = "zttp-test-jsonl",
        .revision = "1",
        .handler_path = "handler.ts",
        .config = null,
        .runtime_files = &.{.{ .path = "system.json", .bytes = "{}" }},
    } };
    try expectChanged(intent, intentSuite(&changed_intents));
    changed_intents = intents;
    changed_intents[0] = .{ .runtime = .{
        .name = "alpha",
        .spec = "{\"type\":\"test\"}\n",
        .runner = "different-runner",
        .revision = "1",
        .handler_path = "handler.ts",
        .config = "{\"handler\":\"handler.ts\"}",
        .runtime_files = &.{.{ .path = "system.json", .bytes = "{}" }},
    } };
    try expectChanged(intent, intentSuite(&changed_intents));
    changed_intents = intents;
    changed_intents[0] = .{ .runtime = .{
        .name = "alpha",
        .spec = "{\"type\":\"test\"}\n",
        .runner = "zttp-test-jsonl",
        .revision = "2",
        .handler_path = "handler.ts",
        .config = "{\"handler\":\"handler.ts\"}",
        .runtime_files = &.{.{ .path = "system.json", .bytes = "{}" }},
    } };
    try expectChanged(intent, intentSuite(&changed_intents));
    changed_intents = intents;
    changed_intents[0] = .{ .runtime = .{
        .name = "alpha",
        .spec = "{\"type\":\"test\"}\n",
        .runner = "zttp-test-jsonl",
        .revision = "1",
        .handler_path = "handler.ts",
        .config = "{\"handler\":\"handler.ts\"}",
        .runtime_files = &.{.{ .path = "other-system.json", .bytes = "{}" }},
    } };
    try expectChanged(intent, intentSuite(&changed_intents));
    changed_intents = intents;
    changed_intents[0] = .{ .runtime = .{
        .name = "alpha",
        .spec = "{\"type\":\"test\"}\n",
        .runner = "zttp-test-jsonl",
        .revision = "1",
        .handler_path = "handler.ts",
        .config = "{\"handler\":\"handler.ts\"}",
        .runtime_files = &.{.{ .path = "system.json", .bytes = "changed" }},
    } };
    try expectChanged(intent, intentSuite(&changed_intents));
    changed_intents = intents;
    changed_intents[0] = .{ .compiler_veto_only = .{
        .name = "alpha",
        .reason = "compiler-boundary-probe",
    } };
    try expectChanged(intent, intentSuite(&changed_intents));
    changed_intents = intents;
    changed_intents[1] = .{ .compiler_veto_only = .{
        .name = "beta",
        .reason = "different-reason",
    } };
    try expectChanged(intent, intentSuite(&changed_intents));

    const probes = [_]SecurityProbe{
        .{
            .scenario = "alpha",
            .family = "sensitive_data_flow",
            .source = "return secret",
            .claim = .{ .adversarial = .{
                .primary = "ZTS400",
                .exact_diagnostics = &.{
                    .{ .code = "ZTS400", .severity = .err },
                    .{ .code = "ZTS500", .severity = .err },
                },
            } },
        },
    };
    const probe = securityProbeCorpus(&probes);
    var changed_probes = probes;
    changed_probes[0].scenario = "beta";
    try expectChanged(probe, securityProbeCorpus(&changed_probes));
    changed_probes = probes;
    changed_probes[0].family = "untrusted_input_flow";
    try expectChanged(probe, securityProbeCorpus(&changed_probes));
    changed_probes = probes;
    changed_probes[0].claim = .{ .positive = .{ .property = .{
        .name = "no_secret_leakage",
        .value = false,
    } } };
    try expectChanged(probe, securityProbeCorpus(&changed_probes));
    changed_probes = probes;
    changed_probes[0].source = "return public";
    try expectChanged(probe, securityProbeCorpus(&changed_probes));
    changed_probes = probes;
    changed_probes[0].claim = .{ .positive = .{ .property = .{
        .name = "no_secret_leakage",
        .value = true,
    } } };
    try expectChanged(probe, securityProbeCorpus(&changed_probes));

    const expected = [_]ExpectedOutcome{
        .{ .scenario = "alpha", .metric = .first_attempt_green, .verdict = .pass },
    };
    const floors = [_]NamedThreshold{
        .{ .name = "corpus-cases", .comparison = .at_least, .value = 2 },
    };
    const threshold = thresholds(&expected, &floors);
    var changed_expected = expected;
    changed_expected[0].scenario = "beta";
    try expectChanged(threshold, thresholds(&changed_expected, &floors));
    changed_expected = expected;
    changed_expected[0].metric = .runtime_intent;
    try expectChanged(threshold, thresholds(&changed_expected, &floors));
    changed_expected = expected;
    changed_expected[0].verdict = .fail;
    try expectChanged(threshold, thresholds(&changed_expected, &floors));
    var changed_floors = floors;
    changed_floors[0].name = "headline-cases";
    try expectChanged(threshold, thresholds(&expected, &changed_floors));
    changed_floors = floors;
    changed_floors[0].comparison = .exactly;
    try expectChanged(threshold, thresholds(&expected, &changed_floors));
    changed_floors = floors;
    changed_floors[0].value += 1;
    try expectChanged(threshold, thresholds(&expected, &changed_floors));

    const manifest_id = manifest(.{
        .headline_input = headline,
        .intent_suite = intent,
        .security_probes = probe,
        .thresholds = threshold,
    });
    try std.testing.expect(manifest_id.eql(manifest(.{
        .headline_input = headline,
        .intent_suite = intent,
        .security_probes = probe,
        .thresholds = threshold,
    })));
    try expectChanged(manifest_id, manifest(.{
        .headline_input = headlineInput(&changed_headline),
        .intent_suite = intent,
        .security_probes = probe,
        .thresholds = threshold,
    }));
    try expectChanged(manifest_id, manifest(.{
        .headline_input = headline,
        .intent_suite = intentSuite(&changed_intents),
        .security_probes = probe,
        .thresholds = threshold,
    }));
    try expectChanged(manifest_id, manifest(.{
        .headline_input = headline,
        .intent_suite = intent,
        .security_probes = securityProbeCorpus(&changed_probes),
        .thresholds = threshold,
    }));
    try expectChanged(manifest_id, manifest(.{
        .headline_input = headline,
        .intent_suite = intent,
        .security_probes = probe,
        .thresholds = thresholds(&changed_expected, &floors),
    }));

    const same_bytes = "same bytes";
    const prompt_persona = promptPersona(same_bytes);
    const meta_id = meta(same_bytes);
    const schema_id = schema(same_bytes);
    const grammar_id = grammar(same_bytes);
    const semantics_id = semantics(same_bytes);
    const diagnostic_id = diagnostics(same_bytes);
    const policy_id = policy(same_bytes);
    inline for (.{ meta_id, schema_id, grammar_id, semantics_id, diagnostic_id, policy_id }) |other| {
        try std.testing.expect(!std.mem.eql(u8, &prompt_persona.bytes, &other.bytes));
    }
}

test "result run identity binds every report provenance class" {
    const definitions = [_]tool_catalog.Definition{
        .{ .name = "read", .description = "read a file", .input_schema = "{}" },
    };
    const neutral_catalog = providerNeutralCatalog(&definitions);
    try std.testing.expect(neutral_catalog.eql(providerNeutralCatalog(&definitions)));
    var changed_definitions = definitions;
    changed_definitions[0].name = "write";
    try expectChanged(neutral_catalog, providerNeutralCatalog(&changed_definitions));
    changed_definitions = definitions;
    changed_definitions[0].description = "changed description";
    try expectChanged(neutral_catalog, providerNeutralCatalog(&changed_definitions));
    changed_definitions = definitions;
    changed_definitions[0].input_schema = "{\"type\":\"object\"}";
    try expectChanged(neutral_catalog, providerNeutralCatalog(&changed_definitions));
    changed_definitions = definitions;
    changed_definitions[0].host_authoritative_keys = &.{"before"};
    try std.testing.expect(neutral_catalog.eql(providerNeutralCatalog(&changed_definitions)));

    const serialized_catalog = providerSerializedCatalog("[{\"name\":\"read\"}]");
    try std.testing.expect(serialized_catalog.eql(providerSerializedCatalog("[{\"name\":\"read\"}]")));
    try expectChanged(serialized_catalog, providerSerializedCatalog("[]"));

    const observations = [_]ObservedResult{.{
        .scenario = "alpha",
        .artifact_identity = testDigest('1'),
        .draft_quality = .raw_veto_pass,
        .intent_outcome = .passed,
        .applied = true,
        .roundtrips = 1,
    }};
    const base: ResultRunInput = .{
        .provider = .deepseek,
        .model = "deepseek-v4-flash",
        .model_revision = "revision-1",
        .provider_runtime = .{ .name = "deepseek-api", .revision = "2026-08-16" },
        .request_policy = .{
            .max_output_tokens = 32_768,
            .reserve_tokens = 2_048,
            .stream = false,
            .purpose = .normal,
            .cache_policy = .enabled,
        },
        .prompt_persona = promptPersona("prompt and persona bytes"),
        .catalogs = .{
            .provider_neutral = neutral_catalog,
            .provider_serialized = serialized_catalog,
        },
        .compiler = .{
            .schema = schema("schema bytes"),
            .meta = meta("meta bytes"),
            .grammar = grammar("grammar bytes"),
            .semantics = semantics("semantics bytes"),
            .diagnostics = diagnostics("diagnostic bytes"),
            .policy = policy("policy bytes"),
        },
        .cohorts = .{
            .headline_input = .{ .bytes = [_]u8{'1'} ** 64 },
            .intent_suite = .{ .bytes = [_]u8{'2'} ** 64 },
            .security_probes = .{ .bytes = [_]u8{'3'} ** 64 },
            .thresholds = .{ .bytes = [_]u8{'4'} ** 64 },
        },
        .source_revision = .{ .commit = "0123456789abcdef", .dirty = false },
        .run_id = "run-1",
        .observations = &observations,
    };
    const id = resultRun(base);
    try std.testing.expect(id.eql(resultRun(base)));

    var changed = base;
    changed.provider = .openai;
    try expectChanged(id, resultRun(changed));
    changed = base;
    changed.model = "different-model";
    try expectChanged(id, resultRun(changed));
    changed = base;
    changed.model_revision = null;
    try expectChanged(id, resultRun(changed));
    changed = base;
    changed.provider_runtime = null;
    try expectChanged(id, resultRun(changed));
    changed = base;
    changed.provider_runtime = .{ .name = "changed-runtime", .revision = "2026-08-16" };
    try expectChanged(id, resultRun(changed));
    changed = base;
    changed.provider_runtime = .{ .name = "deepseek-api", .revision = "2026-08-17" };
    try expectChanged(id, resultRun(changed));
    changed = base;
    changed.request_policy.max_output_tokens += 1;
    try expectChanged(id, resultRun(changed));
    changed = base;
    changed.request_policy.reserve_tokens += 1;
    try expectChanged(id, resultRun(changed));
    changed = base;
    changed.request_policy.stream = true;
    try expectChanged(id, resultRun(changed));
    changed = base;
    changed.request_policy.purpose = .summarization;
    try expectChanged(id, resultRun(changed));
    changed = base;
    changed.request_policy.cache_policy = .disabled;
    try expectChanged(id, resultRun(changed));
    changed = base;
    changed.prompt_persona = promptPersona("changed prompt and persona");
    try expectChanged(id, resultRun(changed));
    changed = base;
    changed_definitions = definitions;
    changed_definitions[0].name = "write";
    changed.catalogs.provider_neutral = providerNeutralCatalog(&changed_definitions);
    try expectChanged(id, resultRun(changed));
    changed = base;
    changed.catalogs.provider_serialized = providerSerializedCatalog("[]");
    try expectChanged(id, resultRun(changed));

    inline for (.{ "grammar", "semantics", "diagnostics", "policy" }, 0..) |_, index| {
        changed = base;
        switch (index) {
            0 => changed.compiler.grammar = grammar("changed grammar"),
            1 => changed.compiler.semantics = semantics("changed semantics"),
            2 => changed.compiler.diagnostics = diagnostics("changed diagnostics"),
            3 => changed.compiler.policy = policy("changed policy"),
            else => unreachable,
        }
        try expectChanged(id, resultRun(changed));
    }
    changed = base;
    changed.compiler.schema = schema("changed schema");
    try expectChanged(id, resultRun(changed));
    changed = base;
    changed.compiler.meta = meta("changed meta");
    try expectChanged(id, resultRun(changed));

    inline for (0..4) |index| {
        changed = base;
        switch (index) {
            0 => changed.cohorts.headline_input.bytes[0] = '9',
            1 => changed.cohorts.intent_suite.bytes[0] = '9',
            2 => changed.cohorts.security_probes.bytes[0] = '9',
            3 => changed.cohorts.thresholds.bytes[0] = '9',
            else => unreachable,
        }
        try expectChanged(id, resultRun(changed));
    }
    changed = base;
    changed.source_revision.commit = "fedcba9876543210";
    try expectChanged(id, resultRun(changed));
    changed = base;
    changed.source_revision.dirty = true;
    try expectChanged(id, resultRun(changed));
    changed = base;
    changed.run_id = "run-2";
    try expectChanged(id, resultRun(changed));

    inline for (0..7) |index| {
        var changed_observations = observations;
        switch (index) {
            0 => changed_observations[0].scenario = "beta",
            1 => changed_observations[0].artifact_identity = null,
            2 => changed_observations[0].draft_quality = .normalized,
            3 => changed_observations[0].draft_quality = .not_green,
            4 => changed_observations[0].intent_outcome = .failed,
            5 => changed_observations[0].applied = false,
            6 => changed_observations[0].roundtrips += 1,
            else => unreachable,
        }
        changed = base;
        changed.observations = &changed_observations;
        try expectChanged(id, resultRun(changed));
    }
}
