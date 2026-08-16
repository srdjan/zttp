//! Report-only qualification for one frozen expert evaluation cohort.
//!
//! A live run is evidence, not a default-selection side effect. This module
//! validates one complete 19-case run and then requires three comparable,
//! consecutive run records before it calls a candidate qualified. It never
//! edits the model registry.

const std = @import("std");
const codegen_types = @import("expert_codegen_types.zig");
const models = @import("providers/models.zig");

pub const schema_version: u32 = 1;
pub const required_runs: usize = 3;
pub const expected_cases: usize = 19;
pub const expected_runtime_intents: usize = 18;
pub const minimum_raw_first_draft_passes: usize = 14;
pub const maximum_median_roundtrips: u8 = 4;

pub const DraftQuality = codegen_types.DraftQuality;
pub const IntentOutcome = codegen_types.IntentOutcome;

pub const FailureKind = enum {
    empty_response,
    timeout,
    decode,
    provider,
    intent,
    validation,
    internal,
};

/// Closed, evidence-led explanation for a model-authored first draft that did
/// not pass unchanged. Transport and harness failures live in `FailureKind` and
/// are deliberately not misreported as model-authoring diagnoses.
pub const DraftFailureCause = enum {
    missing_fact,
    wrong_route,
    bad_tool_order,
    source_shape,
};

pub const DraftEvidence = struct {
    diagnostic_code: ?[]const u8 = null,
    transcript_entry: ?usize = null,
    tool_name: ?[]const u8 = null,
};

pub const DraftFailure = struct {
    primary: DraftFailureCause,
    contributors: []const DraftFailureCause = &.{},
    evidence: DraftEvidence,
};

pub const CaseResult = struct {
    name: []const u8,
    artifact_identity: ?[]const u8,
    draft_quality: DraftQuality,
    applied: bool,
    intent: IntentOutcome,
    roundtrips: u8,
    wall_clock_ms: u64,
    failures: []const FailureKind = &.{},
    error_names: []const []const u8 = &.{},
    draft_failure: ?DraftFailure = null,
};

pub const ProviderRuntime = struct {
    name: []const u8,
    revision: []const u8,
};

pub const RequestPolicy = struct {
    max_output_tokens: u32,
    reserve_tokens: u64,
    stream: bool,
    purpose: []const u8,
    cache_policy: []const u8,
};

pub const EvaluationIdentity = struct {
    provider: []const u8,
    model: []const u8,
    model_revision: ?[]const u8,
    provider_runtime: ?ProviderRuntime,
    request_policy: RequestPolicy,
    provider_tool_count: usize,
    provider_tool_bytes: usize,
    headline_input_hash: []const u8,
    intent_suite_hash: []const u8,
    security_probe_hash: []const u8,
    threshold_hash: []const u8,
    manifest_hash: []const u8,
    prompt_persona_hash: []const u8,
    provider_neutral_catalog_hash: []const u8,
    provider_serialized_catalog_hash: []const u8,
    schema_hash: []const u8,
    meta_hash: []const u8,
    grammar_hash: []const u8,
    semantics_hash: []const u8,
    diagnostic_hash: []const u8,
    policy_hash: []const u8,
};

pub const SourceIdentity = struct {
    commit: []const u8,
    dirty: bool,
    known: bool,
};

pub const RequestLimits = struct {
    turn_timeout_ms: u64,
    max_model_roundtrips_per_turn: u8,
    max_tool_calls_per_turn: usize,
};

/// Extra evidence required for a developer-managed local serving stack. The
/// zttp request sends no sampling overrides, so `sampling_policy` must state
/// that server defaults were used and `seed` is null unless that contract
/// changes in the provider adapter.
pub const LocalProvenance = struct {
    model_artifact_sha256: []const u8,
    quantization: []const u8,
    chat_template_sha256: []const u8,
    serving_args: []const u8,
    sampling_policy: []const u8,
    seed: ?u64,
    hardware: []const u8,
    os: []const u8,
    peak_memory_bytes: u64,
};

pub const Summary = struct {
    expected_cases: usize,
    completed_cases: usize,
    artifact_cases: usize,
    raw_first_draft_passes: usize,
    first_attempt_greens: usize,
    final_greens: usize,
    intent_passes: usize,
    intent_checked: usize,
    median_roundtrips: u8,
    empty_responses: usize,
    timeout_failures: usize,
    decode_failures: usize,
    provider_failures: usize,
    intent_failures: usize,
    validation_failures: usize,
    internal_failures: usize,
    wall_clock_ms: u64,
};

pub const Run = struct {
    schema_version: u32,
    run_id: []const u8,
    result_run_hash: []const u8,
    complete: bool,
    filtered: bool,
    report_only: bool,
    default_change_authorized: bool,
    identity: EvaluationIdentity,
    source: SourceIdentity,
    limits: RequestLimits,
    local_provenance: ?LocalProvenance,
    cases: []const CaseResult,
    summary: Summary,
};

pub const RunFailureReason = enum {
    wrong_schema,
    incomplete,
    filtered,
    not_report_only,
    default_change_authorized,
    unknown_source,
    dirty_source,
    missing_identity,
    invalid_digest,
    invalid_request_policy,
    invalid_request_limits,
    local_provenance_missing,
    local_provenance_invalid,
    unexpected_local_provenance,
    case_floor,
    duplicate_case,
    invalid_case,
    summary_mismatch,
    raw_first_draft_below_floor,
    final_green_below_floor,
    runtime_intent_below_floor,
    median_roundtrips_above_ceiling,
    empty_response,
    timeout,
    decode,
    provider_failure,
    validation_failure,
    internal_failure,
};

pub const SeriesFailureReason = enum {
    wrong_run_count,
    run_failed,
    duplicate_run_id,
    identity_drift,
    source_drift,
    local_provenance_drift,
};

pub const SeriesFailure = struct {
    reason: SeriesFailureReason,
    run_index: ?usize = null,
    run_reason: ?RunFailureReason = null,
};

pub const SeriesAssessment = union(enum) {
    qualified,
    failed: SeriesFailure,
};

fn nonEmpty(value: []const u8) bool {
    return std.mem.trim(u8, value, " \t\r\n").len != 0;
}

fn isLowerHex(value: []const u8, expected_len: usize) bool {
    if (value.len != expected_len) return false;
    for (value) |byte| {
        if (!(std.ascii.isDigit(byte) or (byte >= 'a' and byte <= 'f'))) return false;
    }
    return true;
}

fn optionalStringEql(lhs: ?[]const u8, rhs: ?[]const u8) bool {
    if ((lhs == null) != (rhs == null)) return false;
    if (lhs) |value| return std.mem.eql(u8, value, rhs.?);
    return true;
}

fn runtimeEql(lhs: ?ProviderRuntime, rhs: ?ProviderRuntime) bool {
    if ((lhs == null) != (rhs == null)) return false;
    if (lhs) |value| {
        return std.mem.eql(u8, value.name, rhs.?.name) and
            std.mem.eql(u8, value.revision, rhs.?.revision);
    }
    return true;
}

fn policyEql(lhs: RequestPolicy, rhs: RequestPolicy) bool {
    return lhs.max_output_tokens == rhs.max_output_tokens and
        lhs.reserve_tokens == rhs.reserve_tokens and
        lhs.stream == rhs.stream and
        std.mem.eql(u8, lhs.purpose, rhs.purpose) and
        std.mem.eql(u8, lhs.cache_policy, rhs.cache_policy);
}

fn identityEql(lhs: EvaluationIdentity, rhs: EvaluationIdentity) bool {
    return std.mem.eql(u8, lhs.provider, rhs.provider) and
        std.mem.eql(u8, lhs.model, rhs.model) and
        optionalStringEql(lhs.model_revision, rhs.model_revision) and
        runtimeEql(lhs.provider_runtime, rhs.provider_runtime) and
        policyEql(lhs.request_policy, rhs.request_policy) and
        lhs.provider_tool_count == rhs.provider_tool_count and
        lhs.provider_tool_bytes == rhs.provider_tool_bytes and
        std.mem.eql(u8, lhs.headline_input_hash, rhs.headline_input_hash) and
        std.mem.eql(u8, lhs.intent_suite_hash, rhs.intent_suite_hash) and
        std.mem.eql(u8, lhs.security_probe_hash, rhs.security_probe_hash) and
        std.mem.eql(u8, lhs.threshold_hash, rhs.threshold_hash) and
        std.mem.eql(u8, lhs.manifest_hash, rhs.manifest_hash) and
        std.mem.eql(u8, lhs.prompt_persona_hash, rhs.prompt_persona_hash) and
        std.mem.eql(u8, lhs.provider_neutral_catalog_hash, rhs.provider_neutral_catalog_hash) and
        std.mem.eql(u8, lhs.provider_serialized_catalog_hash, rhs.provider_serialized_catalog_hash) and
        std.mem.eql(u8, lhs.schema_hash, rhs.schema_hash) and
        std.mem.eql(u8, lhs.meta_hash, rhs.meta_hash) and
        std.mem.eql(u8, lhs.grammar_hash, rhs.grammar_hash) and
        std.mem.eql(u8, lhs.semantics_hash, rhs.semantics_hash) and
        std.mem.eql(u8, lhs.diagnostic_hash, rhs.diagnostic_hash) and
        std.mem.eql(u8, lhs.policy_hash, rhs.policy_hash);
}

fn sourceEql(lhs: SourceIdentity, rhs: SourceIdentity) bool {
    return lhs.dirty == rhs.dirty and lhs.known == rhs.known and
        std.mem.eql(u8, lhs.commit, rhs.commit);
}

fn localProvenanceEql(lhs: ?LocalProvenance, rhs: ?LocalProvenance) bool {
    if ((lhs == null) != (rhs == null)) return false;
    if (lhs) |value| {
        const other = rhs.?;
        return std.mem.eql(u8, value.model_artifact_sha256, other.model_artifact_sha256) and
            std.mem.eql(u8, value.quantization, other.quantization) and
            std.mem.eql(u8, value.chat_template_sha256, other.chat_template_sha256) and
            std.mem.eql(u8, value.serving_args, other.serving_args) and
            std.mem.eql(u8, value.sampling_policy, other.sampling_policy) and
            value.seed == other.seed and
            std.mem.eql(u8, value.hardware, other.hardware) and
            std.mem.eql(u8, value.os, other.os);
    }
    return true;
}

fn validIdentity(identity: EvaluationIdentity) ?RunFailureReason {
    if (!nonEmpty(identity.provider) or !nonEmpty(identity.model) or
        (identity.model_revision != null and !nonEmpty(identity.model_revision.?)) or
        identity.provider_tool_count == 0 or identity.provider_tool_bytes == 0)
    {
        return .missing_identity;
    }
    if (identity.provider_runtime) |runtime| {
        if (!nonEmpty(runtime.name) or !nonEmpty(runtime.revision)) return .missing_identity;
    }
    if (identity.request_policy.max_output_tokens == 0 or
        identity.request_policy.reserve_tokens == 0 or
        !nonEmpty(identity.request_policy.purpose) or
        !nonEmpty(identity.request_policy.cache_policy))
    {
        return .invalid_request_policy;
    }
    inline for (&.{
        identity.headline_input_hash,
        identity.intent_suite_hash,
        identity.security_probe_hash,
        identity.threshold_hash,
        identity.manifest_hash,
        identity.prompt_persona_hash,
        identity.provider_neutral_catalog_hash,
        identity.provider_serialized_catalog_hash,
        identity.schema_hash,
        identity.meta_hash,
        identity.grammar_hash,
        identity.semantics_hash,
        identity.diagnostic_hash,
        identity.policy_hash,
    }) |digest| {
        if (!isLowerHex(digest, 64)) return .invalid_digest;
    }
    return null;
}

fn validLocalProvenance(provenance: LocalProvenance) bool {
    return isLowerHex(provenance.model_artifact_sha256, 64) and
        isLowerHex(provenance.chat_template_sha256, 64) and
        nonEmpty(provenance.quantization) and provenance.quantization.len <= 64 and
        nonEmpty(provenance.serving_args) and provenance.serving_args.len <= 4096 and
        std.mem.eql(u8, provenance.sampling_policy, "server-defaults") and
        provenance.seed == null and
        nonEmpty(provenance.hardware) and provenance.hardware.len <= 512 and
        nonEmpty(provenance.os) and provenance.os.len <= 512 and
        provenance.peak_memory_bytes > 0;
}

fn medianRoundtrips(cases: []const CaseResult) u8 {
    var values: [expected_cases]u8 = undefined;
    if (cases.len != values.len) return 0;
    for (cases, 0..) |case, index| values[index] = case.roundtrips;
    std.mem.sort(u8, &values, {}, std.sort.asc(u8));
    return values[values.len / 2];
}

pub fn summarize(cases: []const CaseResult) Summary {
    var out: Summary = .{
        .expected_cases = expected_cases,
        .completed_cases = cases.len,
        .artifact_cases = 0,
        .raw_first_draft_passes = 0,
        .first_attempt_greens = 0,
        .final_greens = 0,
        .intent_passes = 0,
        .intent_checked = 0,
        .median_roundtrips = medianRoundtrips(cases),
        .empty_responses = 0,
        .timeout_failures = 0,
        .decode_failures = 0,
        .provider_failures = 0,
        .intent_failures = 0,
        .validation_failures = 0,
        .internal_failures = 0,
        .wall_clock_ms = 0,
    };
    for (cases) |case| {
        if (case.artifact_identity != null) out.artifact_cases += 1;
        if (case.draft_quality.rawFirstDraftVetoPass()) out.raw_first_draft_passes += 1;
        if (case.draft_quality != .not_green) out.first_attempt_greens += 1;
        if (case.applied) out.final_greens += 1;
        switch (case.intent) {
            .passed => {
                out.intent_passes += 1;
                out.intent_checked += 1;
            },
            .failed => out.intent_checked += 1,
            .not_checked, .compiler_veto_only => {},
        }
        out.wall_clock_ms +|= case.wall_clock_ms;
        for (case.failures) |failure| switch (failure) {
            .empty_response => out.empty_responses += 1,
            .timeout => out.timeout_failures += 1,
            .decode => out.decode_failures += 1,
            .provider => out.provider_failures += 1,
            .intent => out.intent_failures += 1,
            .validation => out.validation_failures += 1,
            .internal => out.internal_failures += 1,
        };
    }
    return out;
}

fn summaryEql(lhs: Summary, rhs: Summary) bool {
    return std.meta.eql(lhs, rhs);
}

fn validCase(case: CaseResult) bool {
    if (!nonEmpty(case.name) or case.failures.len != case.error_names.len) return false;
    if (case.artifact_identity) |digest| if (!isLowerHex(digest, 64)) return false;
    for (case.error_names) |name| if (!nonEmpty(name)) return false;
    if (case.draft_quality.rawFirstDraftVetoPass() and case.draft_failure != null) return false;
    if (!case.draft_quality.rawFirstDraftVetoPass() and case.failures.len == 0 and case.draft_failure == null) return false;
    if (case.draft_failure) |failure| {
        if (failure.evidence.diagnostic_code) |code| if (!nonEmpty(code)) return false;
        if (failure.evidence.tool_name) |name| if (!nonEmpty(name)) return false;
        for (failure.contributors) |contributor| {
            if (contributor == failure.primary) return false;
        }
    }
    return true;
}

pub fn assessRun(run: Run) ?RunFailureReason {
    if (run.schema_version != schema_version) return .wrong_schema;
    if (!run.complete) return .incomplete;
    if (run.filtered) return .filtered;
    if (!run.report_only) return .not_report_only;
    if (run.default_change_authorized) return .default_change_authorized;
    if (!run.source.known or !isLowerHex(run.source.commit, 40)) return .unknown_source;
    if (run.source.dirty) return .dirty_source;
    if (!nonEmpty(run.run_id)) return .missing_identity;
    if (!isLowerHex(run.result_run_hash, 64)) return .invalid_digest;
    if (validIdentity(run.identity)) |reason| return reason;
    if (run.limits.turn_timeout_ms == 0 or
        run.limits.max_model_roundtrips_per_turn == 0 or
        run.limits.max_tool_calls_per_turn == 0)
    {
        return .invalid_request_limits;
    }
    const is_local = std.mem.eql(u8, run.identity.provider, "local");
    if (is_local) {
        const provenance = run.local_provenance orelse return .local_provenance_missing;
        if (run.identity.model_revision == null or run.identity.provider_runtime == null) {
            return .local_provenance_missing;
        }
        if (!isLowerHex(run.identity.model_revision.?, 40)) return .local_provenance_invalid;
        if (!validLocalProvenance(provenance)) return .local_provenance_invalid;
    } else if (run.local_provenance != null) {
        return .unexpected_local_provenance;
    }
    if (run.cases.len != expected_cases) return .case_floor;
    for (run.cases, 0..) |case, index| {
        if (!validCase(case)) return .invalid_case;
        for (run.cases[0..index]) |prior| {
            if (std.mem.eql(u8, case.name, prior.name)) return .duplicate_case;
        }
    }
    const measured = summarize(run.cases);
    if (!summaryEql(measured, run.summary)) return .summary_mismatch;
    if (measured.expected_cases != expected_cases or measured.completed_cases != expected_cases) {
        return .case_floor;
    }
    if (measured.raw_first_draft_passes < minimum_raw_first_draft_passes) {
        return .raw_first_draft_below_floor;
    }
    if (measured.final_greens != expected_cases or measured.artifact_cases != expected_cases) {
        return .final_green_below_floor;
    }
    if (measured.intent_passes != expected_runtime_intents or
        measured.intent_checked != expected_runtime_intents)
    {
        return .runtime_intent_below_floor;
    }
    if (measured.median_roundtrips == 0 or measured.median_roundtrips > maximum_median_roundtrips) {
        return .median_roundtrips_above_ceiling;
    }
    if (measured.empty_responses != 0) return .empty_response;
    if (measured.timeout_failures != 0) return .timeout;
    if (measured.decode_failures != 0) return .decode;
    if (measured.provider_failures != 0) return .provider_failure;
    if (measured.validation_failures != 0 or measured.intent_failures != 0) return .validation_failure;
    if (measured.internal_failures != 0) return .internal_failure;
    return null;
}

pub fn assessSeries(runs: []const Run) SeriesAssessment {
    if (runs.len != required_runs) return .{ .failed = .{ .reason = .wrong_run_count } };
    for (runs, 0..) |run, index| {
        if (assessRun(run)) |reason| {
            return .{ .failed = .{ .reason = .run_failed, .run_index = index, .run_reason = reason } };
        }
        for (runs[0..index]) |prior| {
            if (std.mem.eql(u8, run.run_id, prior.run_id)) {
                return .{ .failed = .{ .reason = .duplicate_run_id, .run_index = index } };
            }
        }
        if (index == 0) continue;
        if (!identityEql(runs[0].identity, run.identity)) {
            return .{ .failed = .{ .reason = .identity_drift, .run_index = index } };
        }
        if (!sourceEql(runs[0].source, run.source)) {
            return .{ .failed = .{ .reason = .source_drift, .run_index = index } };
        }
        if (!localProvenanceEql(runs[0].local_provenance, run.local_provenance)) {
            return .{ .failed = .{ .reason = .local_provenance_drift, .run_index = index } };
        }
    }
    return .qualified;
}

fn readRun(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !Run {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(4 * 1024 * 1024));
    return try std.json.parseFromSliceLeaky(Run, allocator, bytes, .{
        .ignore_unknown_fields = false,
        .allocate = .alloc_always,
    });
}

pub fn main(init: std.process.Init.Minimal) !void {
    const allocator = std.heap.smp_allocator;
    var io_backend = std.Io.Threaded.init(allocator, .{ .environ = .empty });
    defer io_backend.deinit();

    var args = std.process.Args.Iterator.init(init.args);
    defer args.deinit();
    _ = args.next();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var runs: std.ArrayList(Run) = .empty;
    defer runs.deinit(a);
    while (args.next()) |path| try runs.append(a, try readRun(io_backend.io(), a, path));

    const assessment = assessSeries(runs.items);
    const failure: ?SeriesFailure = switch (assessment) {
        .qualified => null,
        .failed => |value| value,
    };
    const first: ?*const Run = if (runs.items.len == 0) null else &runs.items[0];
    const report = .{
        .schema_version = schema_version,
        .qualified = failure == null,
        .default_change_authorized = false,
        .run_count = runs.items.len,
        .provider = if (first) |run| run.identity.provider else null,
        .model = if (first) |run| run.identity.model else null,
        .manifest_hash = if (first) |run| run.identity.manifest_hash else null,
        .failure = failure,
        .runs = runs.items,
    };

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io_backend.io(), &stdout_buffer);
    defer stdout_writer.interface.flush() catch {};
    try std.json.Stringify.value(report, .{}, &stdout_writer.interface);
    try stdout_writer.interface.writeByte('\n');
    try stdout_writer.interface.flush();
    if (failure != null) std.process.exit(1);
}

const test_digest = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
const commit = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
const names = [_][]const u8{
    "case-01", "case-02", "case-03", "case-04", "case-05", "case-06", "case-07",
    "case-08", "case-09", "case-10", "case-11", "case-12", "case-13", "case-14",
    "case-15", "case-16", "case-17", "case-18", "case-19",
};

fn passingRun(cases: *[expected_cases]CaseResult, run_id: []const u8) Run {
    for (cases, 0..) |*case, index| {
        case.* = .{
            .name = names[index],
            .artifact_identity = test_digest,
            .draft_quality = if (index < minimum_raw_first_draft_passes) .raw_veto_pass else .not_green,
            .applied = true,
            .intent = if (index < expected_runtime_intents) .passed else .compiler_veto_only,
            .roundtrips = 4,
            .wall_clock_ms = 100,
            .draft_failure = if (index < minimum_raw_first_draft_passes) null else .{
                .primary = .source_shape,
                .evidence = .{ .diagnostic_code = "ZTS001", .transcript_entry = 3 },
            },
        };
    }
    const identity: EvaluationIdentity = .{
        .provider = "local",
        .model = "candidate",
        .model_revision = commit,
        .provider_runtime = .{ .name = "mlx-lm", .revision = "1.0.0" },
        .request_policy = .{
            .max_output_tokens = 8192,
            .reserve_tokens = 16384,
            .stream = false,
            .purpose = "normal",
            .cache_policy = "enabled",
        },
        .provider_tool_count = 21,
        .provider_tool_bytes = 11775,
        .headline_input_hash = test_digest,
        .intent_suite_hash = test_digest,
        .security_probe_hash = test_digest,
        .threshold_hash = test_digest,
        .manifest_hash = test_digest,
        .prompt_persona_hash = test_digest,
        .provider_neutral_catalog_hash = test_digest,
        .provider_serialized_catalog_hash = test_digest,
        .schema_hash = test_digest,
        .meta_hash = test_digest,
        .grammar_hash = test_digest,
        .semantics_hash = test_digest,
        .diagnostic_hash = test_digest,
        .policy_hash = test_digest,
    };
    return .{
        .schema_version = schema_version,
        .run_id = run_id,
        .result_run_hash = test_digest,
        .complete = true,
        .filtered = false,
        .report_only = true,
        .default_change_authorized = false,
        .identity = identity,
        .source = .{ .commit = commit, .dirty = false, .known = true },
        .limits = .{
            .turn_timeout_ms = 180_000,
            .max_model_roundtrips_per_turn = 18,
            .max_tool_calls_per_turn = 16,
        },
        .local_provenance = .{
            .model_artifact_sha256 = test_digest,
            .quantization = "4-bit",
            .chat_template_sha256 = test_digest,
            .serving_args = "mlx_lm.server --model candidate",
            .sampling_policy = "server-defaults",
            .seed = null,
            .hardware = "test-hardware",
            .os = "test-os",
            .peak_memory_bytes = 1024,
        },
        .cases = cases,
        .summary = summarize(cases),
    };
}

test "qualification requires three complete comparable passing runs" {
    var case_sets: [required_runs][expected_cases]CaseResult = undefined;
    var runs = [_]Run{
        passingRun(&case_sets[0], "run-1"),
        passingRun(&case_sets[1], "run-2"),
        passingRun(&case_sets[2], "run-3"),
    };
    try std.testing.expect(assessRun(runs[0]) == null);
    try std.testing.expectEqual(.qualified, std.meta.activeTag(assessSeries(&runs)));

    // Peak memory is a per-run observation, not serving-stack identity. A
    // candidate remains comparable when that measurement varies.
    var second_provenance = runs[1].local_provenance.?;
    second_provenance.peak_memory_bytes = 2048;
    runs[1].local_provenance = second_provenance;
    try std.testing.expectEqual(.qualified, std.meta.activeTag(assessSeries(&runs)));

    runs[1].identity.policy_hash = "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc";
    const drift = assessSeries(&runs);
    try std.testing.expectEqual(SeriesFailureReason.identity_drift, drift.failed.reason);
}

test "qualification run gate rejects flattering denominators and quality misses" {
    var cases: [expected_cases]CaseResult = undefined;
    var run = passingRun(&cases, "run-1");

    run.cases = run.cases[0..18];
    run.summary = summarize(run.cases);
    try std.testing.expectEqual(RunFailureReason.case_floor, assessRun(run).?);

    run = passingRun(&cases, "run-1");
    cases[13].draft_quality = .not_green;
    cases[13].draft_failure = .{ .primary = .missing_fact, .evidence = .{ .diagnostic_code = "ZTS002" } };
    run.summary = summarize(&cases);
    try std.testing.expectEqual(RunFailureReason.raw_first_draft_below_floor, assessRun(run).?);

    run = passingRun(&cases, "run-1");
    cases[0].failures = &.{.empty_response};
    cases[0].error_names = &.{"EmptyResponse"};
    cases[0].applied = false;
    cases[0].artifact_identity = null;
    run.summary = summarize(&cases);
    try std.testing.expectEqual(RunFailureReason.final_green_below_floor, assessRun(run).?);
}

test "local qualification requires reproducible provenance and never authorizes a default" {
    var cases: [expected_cases]CaseResult = undefined;
    var run = passingRun(&cases, "run-1");
    run.local_provenance = null;
    try std.testing.expectEqual(RunFailureReason.local_provenance_missing, assessRun(run).?);

    run = passingRun(&cases, "run-1");
    run.default_change_authorized = true;
    try std.testing.expectEqual(RunFailureReason.default_change_authorized, assessRun(run).?);
}

test "qualification does not alter product or local-provider defaults" {
    try std.testing.expectEqual(models.Provider.deepseek, models.default_provider);
    try std.testing.expectEqualStrings(
        "deepseek-v4-flash",
        models.defaultForProvider(.deepseek).id,
    );
    try std.testing.expectEqualStrings(
        "LiquidAI/LFM2.5-2.6B-MLX-8bit",
        models.defaultForProvider(.local).id,
    );
}

test "qualification run JSON round trips through the strict CLI schema" {
    var cases: [expected_cases]CaseResult = undefined;
    const run = passingRun(&cases, "run-json");
    var encoded: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer encoded.deinit();
    try std.json.Stringify.value(run, .{}, &encoded.writer);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const decoded = try std.json.parseFromSliceLeaky(
        Run,
        arena.allocator(),
        encoded.written(),
        .{ .ignore_unknown_fields = false, .allocate = .alloc_always },
    );
    try std.testing.expect(assessRun(decoded) == null);
}
