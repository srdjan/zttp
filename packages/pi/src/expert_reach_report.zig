//! Evidence contract for the bounded provable-set reach measurement.
//!
//! The runner writes every selected task and every result row, including tasks
//! that it has not attempted. This module validates that retained evidence
//! against caller-owned task descriptors and derives all counts from the rows.

const std = @import("std");
const codegen_types = @import("expert_codegen_types.zig");

pub const schema_version: u32 = 1;
pub const full_task_count: usize = 8;

pub const InputMode = codegen_types.InputMode;

pub const Origin = enum {
    fresh_model,
    deterministic_harness,
    replay,
};

pub const Scope = enum {
    full,
    pilot,
};

/// One closed terminal state per selected task. `not_attempted` is retained in
/// checkpoint reports and is never accepted in a complete report.
pub const Outcome = enum {
    not_attempted,
    reached,
    no_edit,
    proof_failed,
    intent_failed,
    budget_exhausted,
    empty_response,
    timeout,
    provider_error,
    decode_error,
    harness_error,
    internal_error,
};

/// Frozen identities supplied by the corpus owner. A report repeats this list
/// so that its denominator remains reviewable without loading the corpus.
pub const ExpectedCase = struct {
    id: []const u8,
    family: []const u8,
    mode: InputMode,
    input_hash: []const u8,
    reference_hash: []const u8,
    intent_hash: []const u8,
    admission_hash: []const u8,
};

pub const SourceIdentity = struct {
    revision: []const u8,
    known: bool,
    clean: bool,
};

pub const RequestPolicy = struct {
    max_output_tokens: u32,
    reserve_tokens: u64,
    stream: bool,
    purpose: []const u8,
    cache_policy: []const u8,
};

pub const ModelIdentity = struct {
    provider: []const u8,
    model: []const u8,
    request_policy: RequestPolicy,
    context_hash: []const u8,
    persona_hash: []const u8,
    tool_catalog_hash: []const u8,
};

pub const CompilerIdentity = struct {
    version: []const u8,
    policy_hash: []const u8,
    grammar_hash: []const u8,
    semantics_hash: []const u8,
    diagnostic_hash: []const u8,
};

pub const RunIdentity = struct {
    suite_hash: []const u8,
    compiler: CompilerIdentity,
    model: ?ModelIdentity,
};

pub const Limits = struct {
    task_timeout_ms: u64,
    max_model_roundtrips: u32,
    max_tool_calls: u32,
    max_verification_attempts: u32,
};

pub const CaseResult = struct {
    task_id: []const u8,
    outcome: Outcome,
    compiler_ok: bool = false,
    properties_ok: bool = false,
    intent_passed: bool = false,
    within_budget: bool = false,
    candidate_source_hash: ?[]const u8 = null,
    artifact_hash: ?[]const u8 = null,
    compiler_evidence_hash: ?[]const u8 = null,
    intent_evidence_hash: ?[]const u8 = null,
    error_name: ?[]const u8 = null,
    wall_clock_ms: u64 = 0,
    roundtrips: u32 = 0,
    tool_calls: u32 = 0,
    verification_attempts: u32 = 0,
};

pub const Run = struct {
    schema_version: u32,
    run_id: []const u8,
    origin: Origin,
    scope: Scope,
    complete: bool,
    source: SourceIdentity,
    identity: RunIdentity,
    limits: Limits,
    selected: []const ExpectedCase,
    cases: []const CaseResult,
};

pub const ReachFraction = struct {
    reached: usize,
    selected: usize,
};

pub const ModeSummary = struct {
    reached: usize = 0,
    selected: usize = 0,
};

pub const OutcomeCounts = struct {
    not_attempted: usize = 0,
    reached: usize = 0,
    no_edit: usize = 0,
    proof_failed: usize = 0,
    intent_failed: usize = 0,
    budget_exhausted: usize = 0,
    empty_response: usize = 0,
    timeout: usize = 0,
    provider_error: usize = 0,
    decode_error: usize = 0,
    harness_error: usize = 0,
    internal_error: usize = 0,
};

pub const Summary = struct {
    selected: usize,
    attempted: usize,
    reached: usize,
    whole_file: ModeSummary,
    typed_hole: ModeSummary,
    outcomes: OutcomeCounts,
    /// Present only for a complete full run whose explicit origin is fresh.
    headline: ?ReachFraction,
};

pub const ValidationError = error{
    WrongSchema,
    MissingRunId,
    InvalidSource,
    MissingModelIdentity,
    InvalidModelIdentity,
    InvalidRequestPolicy,
    InvalidCompilerIdentity,
    InvalidLimits,
    EmptySelection,
    WrongFullTaskCount,
    ExpectedSelectionMismatch,
    DuplicateExpectedCase,
    DuplicateSelectedCase,
    InvalidExpectedCase,
    CaseCountMismatch,
    DuplicateCaseResult,
    UnknownCaseResult,
    MissingCaseResult,
    InvalidCaseResult,
    NotAttemptedInCompleteRun,
    FalseFailure,
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

fn isLowerHexDigest(value: []const u8) bool {
    return isLowerHex(value, 64);
}

fn validOptionalDigest(value: ?[]const u8) bool {
    return value == null or isLowerHexDigest(value.?);
}

fn expectedCaseEql(lhs: ExpectedCase, rhs: ExpectedCase) bool {
    return std.mem.eql(u8, lhs.id, rhs.id) and
        std.mem.eql(u8, lhs.family, rhs.family) and
        lhs.mode == rhs.mode and
        std.mem.eql(u8, lhs.input_hash, rhs.input_hash) and
        std.mem.eql(u8, lhs.reference_hash, rhs.reference_hash) and
        std.mem.eql(u8, lhs.intent_hash, rhs.intent_hash) and
        std.mem.eql(u8, lhs.admission_hash, rhs.admission_hash);
}

fn validExpectedCase(case: ExpectedCase) bool {
    return nonEmpty(case.id) and nonEmpty(case.family) and
        isLowerHexDigest(case.input_hash) and
        isLowerHexDigest(case.reference_hash) and
        isLowerHexDigest(case.intent_hash) and
        isLowerHexDigest(case.admission_hash);
}

fn findExpected(cases: []const ExpectedCase, id: []const u8) ?ExpectedCase {
    for (cases) |case| {
        if (std.mem.eql(u8, case.id, id)) return case;
    }
    return null;
}

fn findResult(cases: []const CaseResult, id: []const u8) ?CaseResult {
    for (cases) |case| {
        if (std.mem.eql(u8, case.task_id, id)) return case;
    }
    return null;
}

fn validRequestPolicy(policy: RequestPolicy) bool {
    return policy.max_output_tokens > 0 and policy.reserve_tokens > 0 and
        nonEmpty(policy.purpose) and nonEmpty(policy.cache_policy);
}

fn validModelIdentity(identity: ModelIdentity) ValidationError!void {
    if (!nonEmpty(identity.provider) or !nonEmpty(identity.model)) {
        return error.InvalidModelIdentity;
    }
    if (!validRequestPolicy(identity.request_policy)) return error.InvalidRequestPolicy;
    if (!isLowerHexDigest(identity.context_hash) or
        !isLowerHexDigest(identity.persona_hash) or
        !isLowerHexDigest(identity.tool_catalog_hash))
    {
        return error.InvalidModelIdentity;
    }
}

fn validCompilerIdentity(identity: CompilerIdentity) bool {
    return nonEmpty(identity.version) and
        isLowerHexDigest(identity.policy_hash) and
        isLowerHexDigest(identity.grammar_hash) and
        isLowerHexDigest(identity.semantics_hash) and
        isLowerHexDigest(identity.diagnostic_hash);
}

fn validLimits(limits: Limits) bool {
    return limits.task_timeout_ms > 0 and limits.max_model_roundtrips > 0 and
        limits.max_tool_calls > 0 and limits.max_verification_attempts > 0;
}

fn evidenceWithinLimits(case: CaseResult, limits: Limits) bool {
    return case.wall_clock_ms <= limits.task_timeout_ms and
        case.roundtrips <= limits.max_model_roundtrips and
        case.tool_calls <= limits.max_tool_calls and
        case.verification_attempts <= limits.max_verification_attempts;
}

fn hasSuccessEvidence(case: CaseResult, expected: ExpectedCase, limits: Limits) bool {
    return case.compiler_ok and case.properties_ok and case.intent_passed and
        case.within_budget and evidenceWithinLimits(case, limits) and
        case.candidate_source_hash != null and isLowerHexDigest(case.candidate_source_hash.?) and
        case.artifact_hash != null and isLowerHexDigest(case.artifact_hash.?) and
        case.compiler_evidence_hash != null and isLowerHexDigest(case.compiler_evidence_hash.?) and
        case.intent_evidence_hash != null and isLowerHexDigest(case.intent_evidence_hash.?) and
        isLowerHexDigest(expected.reference_hash) and
        isLowerHexDigest(expected.admission_hash) and
        case.error_name == null;
}

fn validateCase(case: CaseResult, expected: ExpectedCase, limits: Limits) ValidationError!void {
    if (!nonEmpty(case.task_id) or
        !validOptionalDigest(case.candidate_source_hash) or
        !validOptionalDigest(case.artifact_hash) or
        !validOptionalDigest(case.compiler_evidence_hash) or
        !validOptionalDigest(case.intent_evidence_hash) or
        (case.error_name != null and !nonEmpty(case.error_name.?)))
    {
        return error.InvalidCaseResult;
    }
    if (case.properties_ok and !case.compiler_ok) return error.InvalidCaseResult;
    if (case.intent_passed and (!case.compiler_ok or !case.properties_ok)) {
        return error.InvalidCaseResult;
    }
    if (case.within_budget and !evidenceWithinLimits(case, limits)) {
        return error.InvalidCaseResult;
    }

    const success = hasSuccessEvidence(case, expected, limits);
    switch (case.outcome) {
        .not_attempted => {
            if (case.compiler_ok or case.properties_ok or case.intent_passed or case.within_budget or
                case.candidate_source_hash != null or case.artifact_hash != null or
                case.compiler_evidence_hash != null or case.intent_evidence_hash != null or
                case.error_name != null or case.wall_clock_ms != 0 or case.roundtrips != 0 or
                case.tool_calls != 0 or case.verification_attempts != 0)
            {
                return error.InvalidCaseResult;
            }
        },
        .reached => if (!success) return error.InvalidCaseResult,
        .no_edit => if (case.intent_passed) return error.InvalidCaseResult,
        .proof_failed => if ((case.compiler_ok and case.properties_ok) or case.intent_passed) {
            return error.InvalidCaseResult;
        },
        .intent_failed => if (!case.compiler_ok or !case.properties_ok or case.intent_passed or
            case.candidate_source_hash == null or case.artifact_hash == null or
            case.compiler_evidence_hash == null or case.intent_evidence_hash == null)
        {
            return error.InvalidCaseResult;
        },
        .budget_exhausted => if (case.within_budget) return error.InvalidCaseResult,
        .empty_response, .timeout, .provider_error, .decode_error, .harness_error, .internal_error => {},
    }
    if (case.outcome != .reached and success) return error.FalseFailure;
}

/// Validate a report against descriptors owned by the caller. This does not
/// trust a task list or summary copied into the report.
pub fn validate(run: Run, expected: []const ExpectedCase) ValidationError!void {
    if (run.schema_version != schema_version) return error.WrongSchema;
    if (!nonEmpty(run.run_id)) return error.MissingRunId;
    if (!isLowerHexDigest(run.identity.suite_hash) or
        !validCompilerIdentity(run.identity.compiler))
    {
        return error.InvalidCompilerIdentity;
    }
    if (!validLimits(run.limits)) return error.InvalidLimits;
    if (expected.len == 0) return error.EmptySelection;
    if (run.scope == .full and expected.len != full_task_count) {
        return error.WrongFullTaskCount;
    }

    if (run.origin == .fresh_model) {
        if (!run.source.known or !run.source.clean or !isLowerHex(run.source.revision, 40)) {
            return error.InvalidSource;
        }
        const model = run.identity.model orelse return error.MissingModelIdentity;
        try validModelIdentity(model);
    } else if (run.identity.model) |model| {
        try validModelIdentity(model);
    }

    for (expected, 0..) |case, index| {
        if (!validExpectedCase(case)) return error.InvalidExpectedCase;
        for (expected[0..index]) |prior| {
            if (std.mem.eql(u8, case.id, prior.id)) return error.DuplicateExpectedCase;
        }
    }

    if (run.selected.len != expected.len) return error.ExpectedSelectionMismatch;
    for (run.selected, 0..) |selected, index| {
        if (!validExpectedCase(selected)) return error.InvalidExpectedCase;
        for (run.selected[0..index]) |prior| {
            if (std.mem.eql(u8, selected.id, prior.id)) return error.DuplicateSelectedCase;
        }
        const caller_case = findExpected(expected, selected.id) orelse
            return error.ExpectedSelectionMismatch;
        if (!expectedCaseEql(selected, caller_case)) return error.ExpectedSelectionMismatch;
    }

    if (run.cases.len != expected.len) return error.CaseCountMismatch;
    for (run.cases, 0..) |case, index| {
        for (run.cases[0..index]) |prior| {
            if (std.mem.eql(u8, case.task_id, prior.task_id)) {
                return error.DuplicateCaseResult;
            }
        }
        const expected_case = findExpected(expected, case.task_id) orelse
            return error.UnknownCaseResult;
        try validateCase(case, expected_case, run.limits);
        if (run.complete and case.outcome == .not_attempted) {
            return error.NotAttemptedInCompleteRun;
        }
    }
    for (expected) |case| {
        if (findResult(run.cases, case.id) == null) return error.MissingCaseResult;
    }
}

fn incrementOutcome(counts: *OutcomeCounts, outcome: Outcome) void {
    switch (outcome) {
        .not_attempted => counts.not_attempted += 1,
        .reached => counts.reached += 1,
        .no_edit => counts.no_edit += 1,
        .proof_failed => counts.proof_failed += 1,
        .intent_failed => counts.intent_failed += 1,
        .budget_exhausted => counts.budget_exhausted += 1,
        .empty_response => counts.empty_response += 1,
        .timeout => counts.timeout += 1,
        .provider_error => counts.provider_error += 1,
        .decode_error => counts.decode_error += 1,
        .harness_error => counts.harness_error += 1,
        .internal_error => counts.internal_error += 1,
    }
}

fn headlineUnchecked(run: Run, reached: usize) ?ReachFraction {
    if (run.origin != .fresh_model or run.scope != .full or !run.complete) return null;
    return .{ .reached = reached, .selected = run.cases.len };
}

/// Derive every count from validated result rows. Failures and not-attempted
/// checkpoint rows remain in `selected`, which is the denominator.
pub fn summarize(run: Run, expected: []const ExpectedCase) ValidationError!Summary {
    try validate(run, expected);
    var out: Summary = .{
        .selected = run.cases.len,
        .attempted = 0,
        .reached = 0,
        .whole_file = .{},
        .typed_hole = .{},
        .outcomes = .{},
        .headline = null,
    };
    for (run.cases) |case| {
        const descriptor = findExpected(expected, case.task_id).?;
        const mode: *ModeSummary = switch (descriptor.mode) {
            .whole_file => &out.whole_file,
            .holes => &out.typed_hole,
        };
        mode.selected += 1;
        incrementOutcome(&out.outcomes, case.outcome);
        if (case.outcome != .not_attempted) out.attempted += 1;
        if (case.outcome == .reached) {
            out.reached += 1;
            mode.reached += 1;
        }
    }
    out.headline = headlineUnchecked(run, out.reached);
    return out;
}

/// Return a publishable reach fraction only for complete full fresh evidence.
pub fn headline(run: Run, expected: []const ExpectedCase) ValidationError!?ReachFraction {
    const summary = try summarize(run, expected);
    return summary.headline;
}

const digest_a = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
const digest_b = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
const digest_c = "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc";
const digest_d = "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd";
const source_revision = "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee";
const ids = [_][]const u8{
    "media-whole",   "media-hole",   "query-whole",    "query-hole",
    "preview-whole", "preview-hole", "deadline-whole", "deadline-hole",
};

fn expectedCases() [full_task_count]ExpectedCase {
    var cases: [full_task_count]ExpectedCase = undefined;
    for (&cases, 0..) |*case, index| {
        case.* = .{
            .id = ids[index],
            .family = if (index < 2) "media" else if (index < 4) "query" else if (index < 6) "preview" else "deadline",
            .mode = if (index % 2 == 0) .whole_file else .holes,
            .input_hash = digest_a,
            .reference_hash = digest_b,
            .intent_hash = digest_c,
            .admission_hash = digest_d,
        };
    }
    return cases;
}

fn reachedCase(id: []const u8) CaseResult {
    return .{
        .task_id = id,
        .outcome = .reached,
        .compiler_ok = true,
        .properties_ok = true,
        .intent_passed = true,
        .within_budget = true,
        .candidate_source_hash = digest_a,
        .artifact_hash = digest_b,
        .compiler_evidence_hash = digest_c,
        .intent_evidence_hash = digest_d,
        .wall_clock_ms = 10,
        .roundtrips = 1,
        .tool_calls = 1,
        .verification_attempts = 1,
    };
}

fn testRun(expected: []const ExpectedCase, cases: []const CaseResult) Run {
    return .{
        .schema_version = schema_version,
        .run_id = "run-1",
        .origin = .fresh_model,
        .scope = .full,
        .complete = true,
        .source = .{ .revision = source_revision, .known = true, .clean = true },
        .identity = .{
            .suite_hash = digest_a,
            .compiler = .{
                .version = "0.1.0",
                .policy_hash = digest_a,
                .grammar_hash = digest_b,
                .semantics_hash = digest_c,
                .diagnostic_hash = digest_d,
            },
            .model = .{
                .provider = "deepseek",
                .model = "deepseek-chat",
                .request_policy = .{
                    .max_output_tokens = 8192,
                    .reserve_tokens = 16384,
                    .stream = true,
                    .purpose = "normal",
                    .cache_policy = "enabled",
                },
                .context_hash = digest_a,
                .persona_hash = digest_b,
                .tool_catalog_hash = digest_c,
            },
        },
        .limits = .{
            .task_timeout_ms = 600_000,
            .max_model_roundtrips = 18,
            .max_tool_calls = 16,
            .max_verification_attempts = 5,
        },
        .selected = expected,
        .cases = cases,
    };
}

test "mixed outcomes retain the full denominator and exact mode counts" {
    const expected = expectedCases();
    var cases: [full_task_count]CaseResult = undefined;
    for (&cases, 0..) |*case, index| case.* = reachedCase(ids[index]);
    cases[2] = .{ .task_id = ids[2], .outcome = .no_edit, .within_budget = true };
    cases[3] = .{ .task_id = ids[3], .outcome = .proof_failed, .within_budget = true };
    cases[4] = .{
        .task_id = ids[4],
        .outcome = .intent_failed,
        .compiler_ok = true,
        .properties_ok = true,
        .within_budget = true,
        .candidate_source_hash = digest_a,
        .artifact_hash = digest_b,
        .compiler_evidence_hash = digest_c,
        .intent_evidence_hash = digest_d,
    };
    cases[5] = .{ .task_id = ids[5], .outcome = .provider_error, .within_budget = true };
    cases[6] = .{ .task_id = ids[6], .outcome = .budget_exhausted };
    cases[7] = .{ .task_id = ids[7], .outcome = .empty_response, .within_budget = true };

    const summary = try summarize(testRun(&expected, &cases), &expected);
    try std.testing.expectEqual(@as(usize, full_task_count), summary.selected);
    try std.testing.expectEqual(@as(usize, full_task_count), summary.attempted);
    try std.testing.expectEqual(@as(usize, 2), summary.reached);
    try std.testing.expectEqual(@as(usize, 1), summary.whole_file.reached);
    try std.testing.expectEqual(@as(usize, 1), summary.typed_hole.reached);
    try std.testing.expectEqual(@as(usize, 8), summary.headline.?.selected);
    try std.testing.expectEqual(@as(usize, 2), summary.headline.?.reached);
}

test "every failure outcome remains in the denominator" {
    for (std.meta.tags(Outcome)) |failure| {
        const expected = expectedCases();
        const case: CaseResult = switch (failure) {
            .not_attempted, .reached => continue,
            .no_edit,
            .proof_failed,
            .empty_response,
            .timeout,
            .provider_error,
            .decode_error,
            .harness_error,
            .internal_error,
            => .{
                .task_id = expected[0].id,
                .outcome = failure,
                .within_budget = true,
            },
            .intent_failed => .{
                .task_id = expected[0].id,
                .outcome = .intent_failed,
                .compiler_ok = true,
                .properties_ok = true,
                .within_budget = true,
                .candidate_source_hash = digest_a,
                .artifact_hash = digest_b,
                .compiler_evidence_hash = digest_c,
                .intent_evidence_hash = digest_d,
            },
            .budget_exhausted => .{
                .task_id = expected[0].id,
                .outcome = .budget_exhausted,
            },
        };
        const singleton = [_]CaseResult{case};
        var run = testRun(expected[0..1], &singleton);
        run.scope = .pilot;
        const summary = try summarize(run, expected[0..1]);
        try std.testing.expectEqual(@as(usize, 1), summary.selected);
        try std.testing.expectEqual(@as(usize, 0), summary.reached);
        try std.testing.expect(summary.headline == null);
    }
}

test "complete reports reject missing duplicate unknown and mismatched identities" {
    var expected = expectedCases();
    var cases: [full_task_count]CaseResult = undefined;
    for (&cases, 0..) |*case, index| case.* = reachedCase(ids[index]);

    var run = testRun(&expected, &cases);
    run.cases = run.cases[0 .. full_task_count - 1];
    try std.testing.expectError(error.CaseCountMismatch, validate(run, &expected));

    run = testRun(&expected, &cases);
    cases[1].task_id = ids[0];
    try std.testing.expectError(error.DuplicateCaseResult, validate(run, &expected));

    cases[1].task_id = "unknown";
    try std.testing.expectError(error.UnknownCaseResult, validate(run, &expected));

    cases[1] = reachedCase(ids[1]);
    expected[0].input_hash = digest_d;
    run = testRun(&expected, &cases);
    const caller_expected = expectedCases();
    try std.testing.expectError(error.ExpectedSelectionMismatch, validate(run, &caller_expected));
}

test "only complete full fresh reports expose a headline" {
    const expected = expectedCases();
    var cases: [full_task_count]CaseResult = undefined;
    for (&cases, 0..) |*case, index| case.* = reachedCase(ids[index]);

    var run = testRun(&expected, &cases);
    run.origin = .deterministic_harness;
    try std.testing.expect((try headline(run, &expected)) == null);

    run.origin = .replay;
    try std.testing.expect((try headline(run, &expected)) == null);

    run.origin = .fresh_model;
    run.scope = .pilot;
    try std.testing.expect((try headline(run, &expected)) == null);

    run.scope = .full;
    run.complete = false;
    try std.testing.expect((try headline(run, &expected)) == null);
}

test "fresh reports require a known clean canonical source revision" {
    const expected = expectedCases();
    var cases: [full_task_count]CaseResult = undefined;
    for (&cases, 0..) |*case, index| case.* = reachedCase(ids[index]);

    var run = testRun(&expected, &cases);
    run.source.revision = "unknown";
    try std.testing.expectError(error.InvalidSource, validate(run, &expected));

    run = testRun(&expected, &cases);
    run.source.revision = source_revision[0..39];
    try std.testing.expectError(error.InvalidSource, validate(run, &expected));

    run = testRun(&expected, &cases);
    run.source.revision = "EEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEE";
    try std.testing.expectError(error.InvalidSource, validate(run, &expected));

    run = testRun(&expected, &cases);
    run.source.known = false;
    try std.testing.expectError(error.InvalidSource, validate(run, &expected));

    run = testRun(&expected, &cases);
    run.source.clean = false;
    try std.testing.expectError(error.InvalidSource, validate(run, &expected));
}

test "success requires all evidence and observed work within limits" {
    const expected = expectedCases();
    var cases: [full_task_count]CaseResult = undefined;
    for (&cases, 0..) |*case, index| case.* = reachedCase(ids[index]);
    const run = testRun(&expected, &cases);

    cases[0].intent_evidence_hash = null;
    try std.testing.expectError(error.InvalidCaseResult, validate(run, &expected));

    cases[0] = reachedCase(ids[0]);
    cases[0].roundtrips = run.limits.max_model_roundtrips + 1;
    try std.testing.expectError(error.InvalidCaseResult, validate(run, &expected));

    cases[0] = reachedCase(ids[0]);
    cases[0].outcome = .provider_error;
    try std.testing.expectError(error.FalseFailure, validate(run, &expected));
}

test "checkpoint rows are explicit and forbidden after completion" {
    const expected = expectedCases();
    var cases: [full_task_count]CaseResult = undefined;
    for (&cases, 0..) |*case, index| case.* = reachedCase(ids[index]);
    cases[7] = .{ .task_id = ids[7], .outcome = .not_attempted };

    var run = testRun(&expected, &cases);
    run.complete = false;
    const summary = try summarize(run, &expected);
    try std.testing.expectEqual(@as(usize, 8), summary.selected);
    try std.testing.expectEqual(@as(usize, 7), summary.attempted);
    try std.testing.expectEqual(@as(usize, 1), summary.outcomes.not_attempted);

    run.complete = true;
    try std.testing.expectError(error.NotAttemptedInCompleteRun, validate(run, &expected));
}
