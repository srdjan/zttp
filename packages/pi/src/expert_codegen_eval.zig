//! expert_codegen_eval - measure the pi expert's code-generation QUALITY.
//!
//! The sibling expert_eval.zig pins the routing surface (does an ask reach the
//! right compiler-native tool). This module measures the next thing: given the
//! model's drafts, how good is the generated zts code? It drives a real turn
//! through the real compiler veto in an isolated workspace and reports the
//! headline number - raw first-draft veto-pass rate - plus first-attempt green,
//! round-trips-to-green, and a per-ZTS-code gap histogram that ranks which
//! teaching gap to close next.
//!
//! Where the drafts come from is the client's job: scripted replies in the unit
//! tests below (deterministic, free), or cassette replay of recorded model
//! output for the committed baseline (recorded once, replayed forever). Either
//! way the veto, the apply path, and the metrics are the production loop, so the
//! score is a measured count over a fixed sample, not an estimate.
//!
//! First-slice scope: length-1 (edit-only) cases, criteria raw_first_draft_veto and
//! reaches_green. Multi-roundtrip cases (explore->edit, retry-to-green) and a
//! discharges_property criterion are deferred until the baseline histogram says
//! they are worth the cassette cost.

const std = @import("std");
const loop = @import("loop.zig");
const turn = @import("turn.zig");
const transcript_mod = @import("transcript.zig");
const registry_mod = @import("registry/registry.zig");
const expert_workflow = @import("expert_workflow.zig");
const codegen_types = @import("expert_codegen_types.zig");
const tools_common = @import("tools/common.zig");
const IsolatedTmp = @import("test_support/tmp.zig").IsolatedTmp;
const zts = @import("zts");

pub const SeedFile = codegen_types.SeedFile;

/// A case's intent check: the behaviour the produced handler must actually
/// exhibit, as a `zttp test` jsonl spec.
///
/// The veto answers "is this program provable". It cannot answer "does this
/// program do what was asked", and a handler that returns `{ok:true}` for every
/// prompt clears the veto every time. Without this, the published pass rate
/// measures convergence on trivial rather than convergence on provable.
pub const IntentCheck = struct {
    /// Contents of the `.test.jsonl` spec, written into the case workspace.
    tests_jsonl: []const u8,
    /// Relative handler path the produced edit is expected to land on. Used to
    /// synthesize a `zttp.json` so `zttp test` resolves the same file the turn
    /// wrote.
    handler_path: []const u8 = "handler.ts",
    /// Verbatim `zttp.json` for cases that need more than a handler key - the
    /// SQL case seeds a `sqlite` path its veto resolves. Synthesizing over the
    /// top of a seeded config would silently drop that key and the case would
    /// fail for a reason that has nothing to do with the model.
    zttp_json: ?[]const u8 = null,
    /// Auxiliary handlers and manifests needed only by the runtime proof.
    /// These are written after the model turn, so they cannot influence the
    /// model or be captured as authored workspace input.
    runtime_files: []const SeedFile = &.{},
};

pub const Criterion = enum {
    /// The exact first model draft must pass the compiler veto unchanged.
    raw_first_draft_veto,
    /// The handler must reach a verified applied edit within max_attempts.
    reaches_green,
};

pub const CodegenCase = struct {
    name: []const u8,
    prompt: []const u8,
    /// Bytes written into the tmp workspace before the turn. Lets a case model
    /// "edit an existing handler" or seed a zttp.json so the SQL veto path
    /// resolves.
    seed_files: []const SeedFile = &.{},
    /// The task kind this prompt should route to. Ties the codegen corpus to the
    /// routing eval so the two cannot drift on the same prompts.
    expected_kind: expert_workflow.TaskKind,
    criterion: Criterion,
    max_attempts: u8 = 1,
    /// Behaviour the produced handler must exhibit. Null means the case is not
    /// intent-checked, which `CaseResult.intent` reports as `.not_checked` so a
    /// missing check can never be counted as a passing one.
    intent: ?IntentCheck = null,
};

/// Outcome of a case's intent check. `not_checked` is deliberately distinct
/// from `passed`: a case with no spec, or one whose turn produced no edit to
/// run a spec against, has not demonstrated anything and must not be counted
/// as if it had.
pub const IntentOutcome = codegen_types.IntentOutcome;

pub const CaseResult = struct {
    name: []const u8,
    /// classify(prompt) matched expected_kind.
    routed: bool,
    draft_quality: codegen_types.DraftQuality,
    applied: bool,
    passed_criterion: bool,
    roundtrips: u8,
    tool_calls: u32,
    proven_guarantees: u32,
    /// Whether the produced handler does the task the prompt asked for.
    intent: IntentOutcome = .not_checked,
    /// Leading ZTS code of the first diagnostic when the case missed its
    /// criterion; empty otherwise. A fixed buffer keeps CaseResult allocation
    /// free (ZTS codes are short, e.g. "ZTS303").
    failing_code_buf: [8]u8 = undefined,
    failing_code_len: u8 = 0,

    pub fn failingCode(self: *const CaseResult) ?[]const u8 {
        return if (self.failing_code_len == 0) null else self.failing_code_buf[0..self.failing_code_len];
    }
};

/// Run one case against a model client and the real compiler veto in an
/// isolated tmp workspace. The client supplies the model's drafts; everything
/// else - the veto, the apply path, the metrics - is the production loop.
pub fn runCase(
    allocator: std.mem.Allocator,
    case: CodegenCase,
    client: loop.ModelClient,
    registry: *const registry_mod.Registry,
) !CaseResult {
    var tmp = try IsolatedTmp.init(allocator, "codegen-eval");
    defer tmp.cleanup(allocator);
    for (case.seed_files) |sf| try tmp.writeFile(allocator, sf.path, sf.bytes);

    var tr: transcript_mod.Transcript = .{};
    defer tr.deinit(allocator);

    const result = try loop.runTurnWith(allocator, client, registry, &tr, case.prompt, .{
        .workspace_root = tmp.abs_path,
        .max_attempts = case.max_attempts,
        .approval_fn = loop.ApprovalFn.fromFn(loop.autoApprove),
        .replay_mode = false,
        // Inherit the production turn_timeout_ms default so the harness and the
        // live loop share one options struct (cassette replays are instant and
        // never approach the wall-clock bound anyway).
    });

    const passed = switch (case.criterion) {
        .raw_first_draft_veto => result.rawFirstDraftVetoPass(),
        .reaches_green => result.applied_change_set,
    };

    var cr: CaseResult = .{
        .name = case.name,
        .routed = expert_workflow.classify(case.prompt).kind == case.expected_kind,
        .draft_quality = result.draft_quality,
        .applied = result.applied_change_set,
        .passed_criterion = passed,
        .roundtrips = result.roundtrips,
        .tool_calls = result.tool_call_count,
        .proven_guarantees = result.proven_guarantees,
    };
    if (!passed) {
        if (firstZtsCode(&tr)) |code| {
            const n = @min(code.len, cr.failing_code_buf.len);
            @memcpy(cr.failing_code_buf[0..n], code[0..n]);
            cr.failing_code_len = @intCast(n);
        }
    }
    return cr;
}

/// An intent check together with the output the run produced. The output is
/// the only truthful account of why a check failed: a later re-run gets a fresh
/// durable directory and an empty oplog, so it can pass while the run being
/// explained did not, and it can also fail for reasons the first run created.
/// A caller that needs to explain a failure keeps this instead of asking again.
pub const IntentRun = struct {
    outcome: IntentOutcome,
    /// Empty when the check never reached the point of running the spec.
    stdout: []u8 = &.{},
    stderr: []u8 = &.{},
    /// How the child ended: "exited", "signal", "stopped" or "unknown".
    term: []const u8 = "",
    exit_code: ?u8 = null,
    /// Whether the three buffers above are owned allocations. A captured run
    /// with genuinely empty output still owns them, so emptiness cannot stand
    /// in for this and `deinit` must not infer ownership from length.
    owns_output: bool = false,

    pub fn deinit(self: *IntentRun, allocator: std.mem.Allocator) void {
        if (self.owns_output) {
            allocator.free(self.stdout);
            allocator.free(self.stderr);
            allocator.free(self.term);
        }
        self.* = .{ .outcome = .failed };
    }

    /// Write the run's own output where a reader will see it, prefixed so it is
    /// not mistaken for the surrounding test's output.
    pub fn report(self: *const IntentRun, label: []const u8) void {
        std.debug.print(
            "[codegen-intent] {s}: `zttp test` ended {s}",
            .{ label, if (self.term.len > 0) self.term else "without running" },
        );
        if (self.exit_code) |code| std.debug.print(" with code {d}", .{code});
        std.debug.print(
            "\nstdout:\n{s}\nstderr:\n{s}\n",
            .{ self.stdout, self.stderr },
        );
    }
};

/// `runIntentCheck` with the run's output retained. Prefer this wherever a
/// failure has to be explained; `runIntentCheck` discards the output and is for
/// callers that only score the outcome.
pub fn runIntentCheckCaptured(
    allocator: std.mem.Allocator,
    intent: IntentCheck,
    workspace_abs: []const u8,
    zttp_bin: []const u8,
) IntentRun {
    const spec_rel = "intent.test.jsonl";
    writeRuntimeFiles(allocator, workspace_abs, intent) catch return .{ .outcome = .failed };
    writeWorkspaceFile(allocator, workspace_abs, spec_rel, intent.tests_jsonl) catch
        return .{ .outcome = .failed };

    const config = if (intent.zttp_json) |verbatim|
        allocator.dupe(u8, verbatim) catch return .{ .outcome = .failed }
    else
        std.fmt.allocPrint(
            allocator,
            "{{\n  \"entry\": \"{s}\"\n}}\n",
            .{intent.handler_path},
        ) catch return .{ .outcome = .failed };
    defer allocator.free(config);
    writeWorkspaceFile(allocator, workspace_abs, "zttp.json", config) catch
        return .{ .outcome = .failed };

    const outcome = tools_common.runCommand(
        allocator,
        workspace_abs,
        &.{ zttp_bin, "test", spec_rel },
    ) catch return .{ .outcome = .failed };

    // The three buffers move into the returned run and are freed by its
    // `deinit`, so `outcome.deinit` is deliberately not called here.
    return .{
        // Killed, stopped, or signalled: the run did not get to demonstrate
        // anything, which is not evidence the handler does the task. `ok` is
        // already false for each of those.
        .outcome = if (outcome.ok) .passed else .failed,
        .stdout = outcome.stdout,
        .stderr = outcome.stderr,
        .term = outcome.term,
        .exit_code = outcome.exit_code,
        .owns_output = true,
    };
}

/// Run a case's intent check against the handler the turn produced.
///
/// Shells out to the built `zttp test` rather than driving the engine here.
/// The eval's whole claim is that the veto, the apply path, and the metrics are
/// the production loop; an intent check that reimplemented request dispatch
/// could drift from the runtime and would be measuring its own copy instead.
/// `zttp test` runs the same handler the same way `zttp dev` would.
///
/// Returns `.failed` for every reason a check can fail to demonstrate intent -
/// a missing binary, a workspace that will not build, an expectation that did
/// not hold. None of those are evidence the handler does the task, and turning
/// any of them into `.passed` is the fail-open this check exists to close.
pub fn runIntentCheck(
    allocator: std.mem.Allocator,
    intent: IntentCheck,
    workspace_abs: []const u8,
    zttp_bin: []const u8,
) IntentOutcome {
    var run = runIntentCheckCaptured(allocator, intent, workspace_abs, zttp_bin);
    defer run.deinit(allocator);
    return run.outcome;
}

fn writeRuntimeFiles(
    allocator: std.mem.Allocator,
    workspace_abs: []const u8,
    intent: IntentCheck,
) !void {
    var resolved_paths: std.ArrayList([]u8) = .empty;
    defer {
        for (resolved_paths.items) |path| allocator.free(path);
        resolved_paths.deinit(allocator);
    }

    for (intent.runtime_files) |runtime_file| {
        if (runtime_file.path.len == 0 or
            std.mem.eql(u8, runtime_file.path, intent.handler_path) or
            std.mem.eql(u8, runtime_file.path, "intent.test.jsonl") or
            std.mem.eql(u8, runtime_file.path, "zttp.json"))
        {
            return error.InvalidRuntimeSupportFile;
        }
        const resolved = tools_common.resolveInsideWorkspace(
            allocator,
            workspace_abs,
            runtime_file.path,
        ) catch return error.InvalidRuntimeSupportFile;
        errdefer allocator.free(resolved);
        for (resolved_paths.items) |prior| {
            if (std.mem.eql(u8, prior, resolved)) return error.DuplicateRuntimeSupportFile;
        }
        try resolved_paths.append(allocator, resolved);
    }

    for (intent.runtime_files, resolved_paths.items) |runtime_file, resolved| {
        try zts.file_io.writeFile(allocator, resolved, runtime_file.bytes);
    }
}

fn writeWorkspaceFile(
    allocator: std.mem.Allocator,
    workspace_abs: []const u8,
    rel: []const u8,
    bytes: []const u8,
) !void {
    const path = try tools_common.resolveInsideWorkspace(allocator, workspace_abs, rel);
    defer allocator.free(path);
    try zts.file_io.writeFile(allocator, path, bytes);
}

/// Absolute path to the `zttp` binary the intent check drives, or null when it
/// is not built. Null makes callers skip the check rather than record a pass.
pub fn locateZttpBinary(allocator: std.mem.Allocator, repo_root: []const u8) ?[]u8 {
    const path = std.fs.path.resolve(allocator, &.{ repo_root, "zig-out", "bin", "zttp" }) catch return null;
    if (!zts.file_io.fileExists(allocator, path)) {
        allocator.free(path);
        return null;
    }
    return path;
}

pub const CodegenSummary = struct {
    total: usize,
    routed: usize,
    raw_first_draft_passes: usize,
    first_attempt_greens: usize,
    greens: usize,
    criterion_passes: usize,
    /// Cases whose produced handler did the task the prompt asked for.
    intent_passes: usize = 0,
    /// Cases that were intent-checked at all. The denominator for
    /// `intentPassPercent`: reporting intent passes against `total` would let
    /// an uncovered corpus read as a low score rather than an unmeasured one.
    intent_checked: usize = 0,
    /// Median round-trips to green across all cases. The mean would be dragged
    /// by one case that never converges; the median says what a typical prompt
    /// costs.
    median_roundtrips: u8 = 0,

    /// Raw first-draft veto-pass rate in percent (0-100), 0 when empty. Integer to
    /// keep the eval free of float-formatting noise; the count fields carry the
    /// exact numerator/denominator for callers that want a precise ratio.
    pub fn rawFirstDraftPassPercent(self: CodegenSummary) usize {
        if (self.total == 0) return 0;
        return self.raw_first_draft_passes * 100 / self.total;
    }

    /// Attempt-one green rate after compiler normalization or repair.
    pub fn firstAttemptGreenPercent(self: CodegenSummary) usize {
        if (self.total == 0) return 0;
        return self.first_attempt_greens * 100 / self.total;
    }

    /// Intent-pass rate over the cases that were actually checked, in percent.
    /// Read it beside `intent_checked`/`total`: a high rate over a third of the
    /// corpus is a different claim from a high rate over all of it.
    pub fn intentPassPercent(self: CodegenSummary) usize {
        if (self.intent_checked == 0) return 0;
        return self.intent_passes * 100 / self.intent_checked;
    }
};

pub fn summarize(results: []const CaseResult) CodegenSummary {
    var s: CodegenSummary = .{
        .total = results.len,
        .routed = 0,
        .raw_first_draft_passes = 0,
        .first_attempt_greens = 0,
        .greens = 0,
        .criterion_passes = 0,
    };
    for (results) |r| {
        if (r.routed) s.routed += 1;
        if (r.draft_quality.rawFirstDraftVetoPass()) s.raw_first_draft_passes += 1;
        if (r.draft_quality.firstAttemptGreen()) s.first_attempt_greens += 1;
        if (r.applied) s.greens += 1;
        if (r.passed_criterion) s.criterion_passes += 1;
        switch (r.intent) {
            .passed => {
                s.intent_passes += 1;
                s.intent_checked += 1;
            },
            .failed => s.intent_checked += 1,
            .not_checked, .compiler_veto_only => {},
        }
    }
    s.median_roundtrips = medianRoundtrips(results);
    return s;
}

/// Median of the per-case round-trip counts. Sorts a fixed-size copy so the
/// caller's slice is untouched and no allocation is needed; a corpus larger
/// than the buffer falls back to reporting 0 rather than a wrong median.
fn medianRoundtrips(results: []const CaseResult) u8 {
    var buf: [64]u8 = undefined;
    if (results.len == 0 or results.len > buf.len) return 0;
    for (results, 0..) |r, i| buf[i] = r.roundtrips;
    const sample = buf[0..results.len];
    std.mem.sort(u8, sample, {}, std.sort.asc(u8));
    const mid = sample.len / 2;
    if (sample.len % 2 == 1) return sample[mid];
    // Even count: the lower of the two middles, so the reported figure is
    // always a round-trip count some case actually took.
    return sample[mid - 1];
}

test "median roundtrips reports a value a case actually took" {
    const mk = struct {
        fn r(n: u8) CaseResult {
            return .{
                .name = "x",
                .routed = true,
                .draft_quality = .raw_veto_pass,
                .applied = true,
                .passed_criterion = true,
                .roundtrips = n,
                .tool_calls = 0,
                .proven_guarantees = 0,
            };
        }
    }.r;
    try std.testing.expectEqual(@as(u8, 2), medianRoundtrips(&.{ mk(1), mk(2), mk(9) }));
    try std.testing.expectEqual(@as(u8, 2), medianRoundtrips(&.{ mk(1), mk(2), mk(3), mk(9) }));
    try std.testing.expectEqual(@as(u8, 0), medianRoundtrips(&.{}));
}

test "intent rate is measured over checked cases, not the whole corpus" {
    const mk = struct {
        fn r(outcome: IntentOutcome) CaseResult {
            return .{
                .name = "x",
                .routed = true,
                .draft_quality = .raw_veto_pass,
                .applied = true,
                .passed_criterion = true,
                .roundtrips = 1,
                .tool_calls = 0,
                .proven_guarantees = 0,
                .intent = outcome,
            };
        }
    }.r;
    const s = summarize(&.{ mk(.passed), mk(.failed), mk(.not_checked), mk(.compiler_veto_only) });
    try std.testing.expectEqual(@as(usize, 4), s.total);
    try std.testing.expectEqual(@as(usize, 2), s.intent_checked);
    try std.testing.expectEqual(@as(usize, 1), s.intent_passes);
    // 1 of 2 checked, not 1 of 4 total.
    try std.testing.expectEqual(@as(usize, 50), s.intentPassPercent());
}

/// How many failing cases reported a given leading ZTS code. This is the gap
/// histogram primitive: ask it per code that appears and the answer ranks which
/// teaching gap accounts for the most retries.
pub fn countFailingCode(results: []const CaseResult, code: []const u8) usize {
    var n: usize = 0;
    for (results) |r| {
        if (r.failingCode()) |c| {
            if (std.mem.eql(u8, c, code)) n += 1;
        }
    }
    return n;
}

/// A set of diagnostic codes, in first-seen order. Registry codes are the
/// registry's own comptime literals and are stored as-is; off-registry codes
/// point into transcript text and are duped on insert.
pub const CodeSet = std.StringArrayHashMapUnmanaged(void);

/// Every registry rule a turn's transcript reports, and every diagnostic code
/// it reports that the registry does not carry.
///
/// `firstZtsCode` answers the gap histogram's question - which rule did this
/// case trip first. This answers the coverage question: which rules does the
/// corpus exercise at all. A fence no case stands on cannot move a published
/// number, and nine consecutive rows reading 90% over one corpus is what that
/// looks like from outside. Nothing joined the corpus to the registry before
/// this, so the argument was made in prose, per row.
///
/// Codes are matched as whole tokens against `all_rules` rather than by a
/// prefix pattern: the registry carries `ZTS`, `POL`, and `PROP` codes, and a
/// pattern guessing at their shapes would quietly drop a family. The second scan
/// is the honest complement. `ZTS042` (stripper) and `ZTS204` (type checker) are
/// real diagnostics this corpus trips that no registry entry carries, so the
/// policy hash cannot see them and neither could a count taken over `all_rules`
/// alone.
pub fn collectCodes(
    allocator: std.mem.Allocator,
    tr: *const transcript_mod.Transcript,
    registry_hits: *CodeSet,
    off_registry: *CodeSet,
) !void {
    for (tr.entries.items) |entry| {
        const text: []const u8 = switch (entry) {
            .diagnostic_box => |b| b.llm_text,
            .tool_result => |t| if (isDiagnosticResult(t)) t.llm_text else continue,
            else => continue,
        };

        for (zts.PolicyCatalog.rules()) |rule| {
            if (containsCodeToken(text, rule.code)) {
                // The key is the registry's own literal, so it outlives any
                // transcript and needs no dupe.
                _ = try registry_hits.getOrPut(allocator, rule.code);
            }
        }

        var i: usize = 0;
        while (std.mem.indexOfPos(u8, text, i, "ZTS")) |pos| {
            var end = pos + 3;
            while (end < text.len and std.ascii.isDigit(text[end])) end += 1;
            i = pos + 3;
            if (end == pos + 3) continue;
            const code = text[pos..end];
            // ZTS000 is the synthesized "no violations" marker, not a rule.
            if (std.mem.eql(u8, code, "ZTS000")) continue;
            if (zts.PolicyCatalog.findByCode(code) != null) continue;
            const gop = try off_registry.getOrPut(allocator, code);
            if (!gop.found_existing) gop.key_ptr.* = try allocator.dupe(u8, code);
        }
    }
}

/// Substring match with both boundaries checked. Without it `ZTS30` matches
/// inside `ZTS300` and `POL1` inside `POL10`, so a rule would be reported as
/// tripped by a diagnostic for a different one.
fn containsCodeToken(text: []const u8, code: []const u8) bool {
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, text, i, code)) |pos| {
        i = pos + code.len;
        const opens = pos == 0 or !std.ascii.isAlphanumeric(text[pos - 1]);
        const closes = i >= text.len or !std.ascii.isAlphanumeric(text[i]);
        if (opens and closes) return true;
    }
    return false;
}

pub fn firstZtsCode(tr: *const transcript_mod.Transcript) ?[]const u8 {
    for (tr.entries.items) |entry| {
        const text: []const u8 = switch (entry) {
            .diagnostic_box => |b| b.llm_text,
            // The agent's own analysis-tool results carry the violations its
            // draft tripped, even when the turn recovered (so no terminal
            // diagnostic box). A clean result lists no violations, so it has no
            // ZTSxxx code and is skipped.
            .tool_result => |t| if (isDiagnosticResult(t)) t.llm_text else continue,
            else => continue,
        };
        if (findZts(text)) |code| return code;
    }
    return null;
}

fn isDiagnosticResult(result: transcript_mod.OwnedToolResult) bool {
    if (std.mem.eql(u8, result.tool_name, "zts_expert_review_patch") or
        std.mem.eql(u8, result.tool_name, "zts_check")) return true;
    return !result.ok and
        std.mem.eql(u8, result.tool_name, "propose_change_set") and
        std.mem.startsWith(u8, result.llm_text, loop.veto_reject_preamble);
}

fn findZts(text: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, text, i, "ZTS")) |pos| {
        var end = pos + 3;
        while (end < text.len and std.ascii.isDigit(text[end])) end += 1;
        // ZTS000 is the synthesized "no violations" / envelope marker, not a
        // real diagnostic; skip it so a clean tool result is not mistaken for a
        // failing code in the gap histogram.
        if (end > pos + 3 and !std.mem.eql(u8, text[pos..end], "ZTS000")) return text[pos..end];
        i = pos + 3;
    }
    return null;
}

const testing = std.testing;

test "runtime support files validate the full set before writing" {
    var tmp = try IsolatedTmp.init(testing.allocator, "intent-runtime-files");
    defer tmp.cleanup(testing.allocator);

    try writeRuntimeFiles(testing.allocator, tmp.abs_path, .{
        .tests_jsonl = "fixture",
        .runtime_files = &.{.{ .path = "support.ts", .bytes = "const marker = true;" }},
    });
    const support_path = try tmp.childPath(testing.allocator, "support.ts");
    defer testing.allocator.free(support_path);
    const support = try zts.file_io.readFile(testing.allocator, support_path, 1024);
    defer testing.allocator.free(support);
    try testing.expectEqualStrings("const marker = true;", support);

    const untouched_path = try tmp.childPath(testing.allocator, "untouched.ts");
    defer testing.allocator.free(untouched_path);
    try testing.expectError(error.InvalidRuntimeSupportFile, writeRuntimeFiles(
        testing.allocator,
        tmp.abs_path,
        .{
            .tests_jsonl = "fixture",
            .runtime_files = &.{
                .{ .path = "untouched.ts", .bytes = "must not land" },
                .{ .path = "../outside.ts", .bytes = "escape" },
            },
        },
    ));
    try testing.expect(!zts.file_io.fileExists(testing.allocator, untouched_path));
}

test "runtime support files reject reserved and duplicate targets" {
    var tmp = try IsolatedTmp.init(testing.allocator, "intent-runtime-boundaries");
    defer tmp.cleanup(testing.allocator);

    inline for (&.{ "", "handler.ts", "intent.test.jsonl", "zttp.json" }) |reserved| {
        try testing.expectError(error.InvalidRuntimeSupportFile, writeRuntimeFiles(
            testing.allocator,
            tmp.abs_path,
            .{
                .tests_jsonl = "fixture",
                .runtime_files = &.{.{ .path = reserved, .bytes = "forbidden" }},
            },
        ));
    }
    try testing.expectError(error.DuplicateRuntimeSupportFile, writeRuntimeFiles(
        testing.allocator,
        tmp.abs_path,
        .{
            .tests_jsonl = "fixture",
            .runtime_files = &.{
                .{ .path = "same.ts", .bytes = "one" },
                .{ .path = "sub/../same.ts", .bytes = "two" },
            },
        },
    ));
}

// A model client that returns one fixed reply, ignoring the transcript. Stands
// in for cassette replay in the deterministic self-test: it exercises runCase,
// the real veto, and the metrics with zero network and zero model cost.
const ScriptedClient = struct {
    reply: turn.AssistantReply,

    fn requestFn(
        ctx: *anyopaque,
        arena: std.mem.Allocator,
        tr: *const transcript_mod.Transcript,
        extra_user_text: ?[]const u8,
    ) anyerror!loop.ModelCallResult {
        const self: *ScriptedClient = @ptrCast(@alignCast(ctx));
        _ = arena;
        _ = tr;
        _ = extra_user_text;
        return .{ .reply = self.reply };
    }

    pub fn asClient(self: *ScriptedClient) loop.ModelClient {
        return .{ .context = self, .request_fn = requestFn };
    }
};

const clean_health =
    "function handler(req: Request): Proof<Response, \"deterministic\"> { return Response.json({ ok: true }); }";

test "runCase scores a clean first draft as a veto pass" {
    var client: ScriptedClient = .{ .reply = .{ .response = .{ .change_set = .{
        .file = "handler.ts",
        .content = clean_health,
    } } } };
    const case: CodegenCase = .{
        .name = "health-scaffold",
        .prompt = "scaffold a minimal GET /health handler",
        .expected_kind = .route_add,
        .criterion = .raw_first_draft_veto,
    };
    var registry: registry_mod.Registry = .{};
    defer registry.deinit(testing.allocator);
    const r = try runCase(testing.allocator, case, client.asClient(), &registry);
    try testing.expect(r.draft_quality.rawFirstDraftVetoPass());
    try testing.expect(r.draft_quality.firstAttemptGreen());
    try testing.expect(r.applied);
    try testing.expect(r.passed_criterion);
    try testing.expect(r.failingCode() == null);
}

test "runCase scores a clean workflow first draft as a veto pass" {
    const workflow_handler =
        \\import { run } from "zttp:durable";
        \\import { call } from "zttp:workflow";
        \\
        \\function handler(req: Request): Proof<Response, "deterministic" | "state_isolated" | "result_safe" | "optional_safe" | "no_secret_leakage" | "no_credential_leakage" | "input_validated" | "pii_contained" | "injection_safe" | "canonical"> {
        \\  const key = req.headers.get("idempotency-key") ?? "workflow-demo";
        \\  return run(key, () => {
        \\    const res = call("greet", { method: "GET", path: "/workflow" });
        \\    return Response.json({ ok: true, childStatus: res.status });
        \\  });
        \\}
    ;
    var client: ScriptedClient = .{ .reply = .{ .response = .{ .change_set = .{
        .file = "handler.ts",
        .content = workflow_handler,
    } } } };
    const case: CodegenCase = .{
        .name = "queued-workflow",
        .prompt = "Create a durable workflow handler that calls a greet child handler via workflow.call",
        .expected_kind = .workflow_authoring,
        .criterion = .raw_first_draft_veto,
    };
    var registry: registry_mod.Registry = .{};
    defer registry.deinit(testing.allocator);
    const r = try runCase(testing.allocator, case, client.asClient(), &registry);
    try testing.expect(r.routed);
    try testing.expect(r.draft_quality.rawFirstDraftVetoPass());
    try testing.expect(r.draft_quality.firstAttemptGreen());
    try testing.expect(r.applied);
    try testing.expect(r.failingCode() == null);
}

test "runCase records the failing ZTS code for a bad first draft" {
    // A forbidden `var` is a hard parse error (ZTS001) that the repair lane
    // cannot author a fix for, so it stays failed and the histogram records its
    // code - exactly the hard-failure case the gap histogram is meant to rank.
    var client: ScriptedClient = .{ .reply = .{ .response = .{ .change_set = .{
        .file = "handler.ts",
        .content = "function handler(req: Request): Proof<Response, \"deterministic\"> { var x = 1; return Response.json({ x: x }); }",
    } } } };
    const case: CodegenCase = .{
        .name = "forbidden-var",
        .prompt = "fix the violation",
        .expected_kind = .violation_fix,
        .criterion = .raw_first_draft_veto,
    };
    var registry: registry_mod.Registry = .{};
    defer registry.deinit(testing.allocator);
    const r = try runCase(testing.allocator, case, client.asClient(), &registry);
    try testing.expect(!r.draft_quality.rawFirstDraftVetoPass());
    try testing.expect(!r.draft_quality.firstAttemptGreen());
    try testing.expect(!r.passed_criterion);
    const code = r.failingCode() orelse return error.ExpectedFailingCode;
    try testing.expect(std.mem.startsWith(u8, code, "ZTS"));
}

test "summarize aggregates pass rate and failing-code histogram" {
    var bad: CaseResult = .{
        .name = "b",
        .routed = true,
        .draft_quality = .not_green,
        .applied = false,
        .passed_criterion = false,
        .roundtrips = 1,
        .tool_calls = 0,
        .proven_guarantees = 0,
    };
    std.mem.copyForwards(u8, bad.failing_code_buf[0..6], "ZTS303");
    bad.failing_code_len = 6;

    const results = [_]CaseResult{
        .{
            .name = "a",
            .routed = true,
            .draft_quality = .raw_veto_pass,
            .applied = true,
            .passed_criterion = true,
            .roundtrips = 1,
            .tool_calls = 0,
            .proven_guarantees = 1,
        },
        .{
            .name = "salvaged",
            .routed = true,
            .draft_quality = .normalized,
            .applied = true,
            .passed_criterion = false,
            .roundtrips = 1,
            .tool_calls = 0,
            .proven_guarantees = 1,
        },
        bad,
    };
    const s = summarize(&results);
    try testing.expectEqual(@as(usize, 3), s.total);
    try testing.expectEqual(@as(usize, 1), s.raw_first_draft_passes);
    try testing.expectEqual(@as(usize, 2), s.first_attempt_greens);
    try testing.expectEqual(@as(usize, 2), s.greens);
    try testing.expectEqual(@as(usize, 33), s.rawFirstDraftPassPercent());
    try testing.expectEqual(@as(usize, 66), s.firstAttemptGreenPercent());
    try testing.expectEqual(@as(usize, 1), countFailingCode(&results, "ZTS303"));
    try testing.expectEqual(@as(usize, 0), countFailingCode(&results, "ZTS999"));
}

test "code collection matches whole tokens, not prefixes" {
    // The case this exists for: a diagnostic for ZTS303 must not be counted as
    // coverage of a shorter code that is its prefix, or the corpus reports
    // exercising rules nothing exercised.
    try testing.expect(containsCodeToken("error ZTS303: bad", "ZTS303"));
    try testing.expect(!containsCodeToken("error ZTS303: bad", "ZTS30"));
    try testing.expect(!containsCodeToken("error XZTS303", "ZTS303"));
    try testing.expect(containsCodeToken("ZTS303", "ZTS303"));
    try testing.expect(containsCodeToken("see POL001 and POL0012", "POL001"));
    try testing.expect(!containsCodeToken("POL0012 only", "POL001"));
}

test "code collection separates registry rules from codes the registry cannot see" {
    var tr: transcript_mod.Transcript = .{};
    defer tr.deinit(testing.allocator);

    // ZTS042 is the stripper's; no `all_rules` entry carries it, which is the
    // blind spot the second list exists to name. ZTS000 is the "no violations"
    // marker and belongs to neither.
    //
    // The registry-side sample is ZTS302, a rule with a producer and a seed.
    // It was ZTS300, which is not in the registry any more - the sample has to
    // be a live rule or this test proves the opposite of its name.
    try tr.append(testing.allocator, .{ .diagnostic_box = .{
        .llm_text = "ZTS302 unhandled path; ZTS042 unsupported cast; ZTS000 clean",
    } });

    var hits: CodeSet = .empty;
    defer hits.deinit(testing.allocator);
    var off: CodeSet = .empty;
    defer {
        for (off.keys()) |key| testing.allocator.free(key);
        off.deinit(testing.allocator);
    }

    try collectCodes(testing.allocator, &tr, &hits, &off);

    try testing.expect(hits.contains("ZTS302"));
    try testing.expect(!hits.contains("ZTS042"));
    try testing.expect(off.contains("ZTS042"));
    try testing.expect(!off.contains("ZTS000"));
    try testing.expect(!off.contains("ZTS302"));

    // A second turn reporting the same code must not double-count it: the
    // published figure is how many distinct rules the corpus reaches.
    try collectCodes(testing.allocator, &tr, &hits, &off);
    try testing.expectEqual(@as(usize, 1), off.count());
}

test "code collection reads persisted apply edit compiler rejections" {
    var tr: transcript_mod.Transcript = .{};
    defer tr.deinit(testing.allocator);
    try tr.append(testing.allocator, .{ .tool_result = .{
        .tool_use_id = "apply-1",
        .tool_name = "propose_change_set",
        .ok = false,
        .llm_text = "The compiler rejected this edit. ZTS400 secret data flows into response body",
    } });

    var hits: CodeSet = .empty;
    defer hits.deinit(testing.allocator);
    var off: CodeSet = .empty;
    defer {
        for (off.keys()) |key| testing.allocator.free(key);
        off.deinit(testing.allocator);
    }

    try collectCodes(testing.allocator, &tr, &hits, &off);
    try testing.expect(hits.contains("ZTS400"));
    try testing.expectEqualStrings("ZTS400", firstZtsCode(&tr).?);
}
