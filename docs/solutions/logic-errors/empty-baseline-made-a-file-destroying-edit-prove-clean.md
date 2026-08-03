---
title: An empty baseline made a file-destroying edit prove clean
date: 2026-08-03
category: logic-errors
module: pi expert agent deterministic stand-in author
problem_type: logic_error
component: tooling
severity: critical
symptoms:
  - "An offline `zttp expert` run replaced a handler larger than 32 KiB with a twenty-line stub and recorded the turn as a verified, proven edit."
  - "Every gate stayed green: the veto passed with zero new violations, and a proof-carrying receipt was written next to the deletion."
  - "The same path fired for a missing file and for a file above the 256 KiB read limit, because a failed tool call returns plain text with no `content` field."
  - "Nothing reproduced under the existing fixtures, because a handler below the transcript cap round-trips as valid JSON."
root_cause: logic_error
resolution_type: code_fix
related_components:
  - testing_framework
  - documentation
tags:
  - pi
  - expert-agent
  - standin
  - fail-open
  - data-loss
  - veto
  - proof-boundary
  - empty-baseline
---

# An empty baseline made a file-destroying edit prove clean

## Problem

The `zttp expert` agent has a deterministic offline author, the "stand-in": a small HTTP server that speaks the OpenAI Responses wire protocol and answers with fixed playbooks, so the expert loop can be exercised end to end without a hosted model. It has no memory of its own. It reconstructs the state of the turn by re-reading the transcript the loop sends it on every round trip, including the target file's bytes, which it recovers by parsing the `workspace_read_file` tool result back out of that transcript (`packages/pi/src/standin/request.zig:98`).

Two facts about the loop make that recovery fallible.

The first is a cap. A tool result entering the transcript is truncated at 32 KiB (`packages/pi/src/loop.zig:314`, `capToolResultForTranscript` at `packages/pi/src/loop.zig:319`), so a handler above that size arrives cut mid-string with a re-read pointer appended. The read tool's output is a JSON object, so a cut inside it is no longer JSON at all.

The second is the shape of a failed tool call. `workspace_read_file` reads through a 256 KiB limit (`packages/pi/src/tools/common.zig:6`, used at `packages/pi/src/tools/workspace_read_file.zig:64`), and any error it raises is turned into plain text by the loop's recovery arm: `"{tool}: {errorName}"` (`packages/pi/src/loop.zig:826`). A missing file and a file above the read limit both arrive as `workspace_read_file: FileNotFound` and `workspace_read_file: FileTooBig`. Neither is JSON, and neither has a `content` field.

In all three cases `readSource` recovered nothing. The old code stored that nothing as an empty string:

```zig
var source: []const u8 = "";
```

The playbook then treated `""` as the file's real contents. `synthesizeRoute` (`packages/pi/src/standin/playbook.zig:818`) searches the source for `zttp:router`, `const routes = {`, and a `Spec` import, finds none of them in an empty string, and emits its from-scratch branch: two imports, a `Guardrails` type alias, a one-entry `routes` object, a dispatching `function handler`, and the new route function. About twenty lines. That stub, and `""` as the `before` field, went into a single `apply_edit` call.

That is where the veto stopped being able to help. `before` is the baseline the compiler diffs against, not a compare-and-swap guard. `edit_simulate` analyzes `before`, builds a multiset of its violation keys, and marks a diagnostic in the new content `is_new` only when the baseline cannot account for it (`packages/tools/src/edit_simulate.zig:100-129`); `new_count` is the count of those, and the veto's verdict is exactly `ok = new_count == 0` (`packages/pi/src/veto.zig:7`, `packages/pi/src/veto.zig:240`). An empty `before` analyzes to zero violations, and the stub is clean code, so `new_count` was zero and the draft passed.

Worse, supplying `""` also suppressed the recovery that would have found the real baseline. `prepareEdit` reads the file from disk only when `before` is null:

```zig
const before = edit.before orelse blk: {
    const current = file_io.readFile(allocator, target_path, 16 * 1024 * 1024) catch |err| switch (err) {
        error.FileNotFound, error.FileTooBig => break :blk null,
        else => return err,
    };
    break :blk current;
};
```

(`packages/pi/src/loop.zig:849`). An empty string is not null, so that fallback never ran. And the same degenerate baseline reached the human: the approval preview's `before` is that same field (`packages/pi/src/loop.zig:940`), so an interactive user was shown the deletion of a large handler as if it were the creation of a new twenty-line file. Under `zttp expert --yes` there is no prompt at all (`packages/pi/src/app.zig:579`).

Then the apply path writes. It does not compare, re-read, or check anything about what is already on disk:

```zig
try file_io.writeFile(allocator, prepared.resolved_path, content);
```

(`packages/pi/src/loop.zig:883`). The user's file was gone, and every gate in the chain had said the edit was clean.

## Symptoms

There was no failing test, no diagnostic, and no error message. The failure signature is a file that is smaller than it was, replaced by a plausible stub, with a green verdict recorded next to it.

The three triggers are: a target handler larger than 32 KiB, where the read succeeded but the transcript copy was truncated; a target file that does not exist; and a target file larger than 256 KiB, where the read tool itself failed. All three land at the same place. The playbooks that could write in this state were add-route, add-env, write-test, and fix.

## What Didn't Work

Everything that was supposed to catch it ran, and passed.

`scripts/verify.sh`, the full local gate that mirrors CI step for step, was green. `zig build test-standin`, the dedicated target for exactly this code, was green: 26 test declarations carrying the pinned filter name at the parent commit (`git grep 'test "' ab947d20^ -- packages/pi/src | grep -c 'stand-in'`). And the change had a line-by-line diff review before it landed.

The reason the tests missed it is worth stating plainly, because it is not subtle: every fixture used a small handler. `sequenceSource` in `packages/pi/src/standin_range_tests.zig` is a few dozen bytes. No test in the suite ever produced a tool result above 32 KiB, so the truncation branch of `capToolResultForTranscript` was never reached from the stand-in's direction, and `readSource` never returned its failure path in a test. The suite proved the happy path repeatedly and had no opinion at all about the other one.

Trusting the veto did not work either, and this is the more general trap. The veto is a real compiler running real analysis, and it is what the whole design leans on. But it answers one question: does this draft introduce violations the previous content did not have. It does not answer "is this draft the same program", and it cannot answer anything when the previous content is a fiction. Note that even with the true baseline the stub would still have passed, because deleting nine hundred correct lines introduces no violation. The veto was never the right place for this catch. The only correct move is to refuse to author.

It was found by an adversarial multi-agent review pass over the whole migration, which returned 15 confirmed defects, 13 of them in this file set. That pass read the code asking what happens when each input is absent rather than what happens when it is present.

## Solution

Commit `ab947d20`. The fix is a type change and five call sites.

Recovered source became optional, with the reason recorded where the type is declared:

```zig
pub const ParsedRequest = struct {
    ask: []const u8,
    step_index: usize,
    /// The target file's bytes, recovered from a read tool's output.
    ///
    /// Null means no read has succeeded yet, which is NOT the same as an empty
    /// file. The loop caps a tool result at 32 KiB, so the output for a large
    /// file is truncated and no longer parses as JSON, and a failed read
    /// returns plain text with no `content` field. Both arrive here as null. A
    /// playbook that authored from "" in those cases would rewrite the file
    /// from nothing, and the veto would not object because an empty `before`
    /// makes an empty baseline.
    source: ?[]const u8 = null,
};
```

(`packages/pi/src/standin/request.zig:5-17`). The local that feeds it changed from `var source: []const u8 = "";` to `var source: ?[]const u8 = null;` (`packages/pi/src/standin/request.zig:36`), and `readSource` now returns `!?[]const u8`, answering null on a JSON parse failure, a non-object value, a missing `content` key, or a `content` that is not a string (`packages/pi/src/standin/request.zig:98-107`).

Every authoring step then unwraps, and refuses rather than writing. The add-route step went from

```zig
2 => blk: {
    const handler_name = try routeHandlerName(allocator, spec.method, spec.path);
    defer allocator.free(handler_name);
    const proposed = try synthesizeRoute(allocator, parsed.source, spec, handler_name);
    defer allocator.free(proposed);
    const args = try renderApplyArgs(allocator, spec.file, proposed, parsed.source);
    defer allocator.free(args);
    break :blk try renderToolCall(allocator, 2, "apply_edit", args);
},
```

to

```zig
3, 4 => blk: {
    const source = parsed.source orelse break :blk try renderUnreadableSource(allocator, "add-route");
    const handler_name = try routeHandlerName(allocator, spec.method, spec.path);
    defer allocator.free(handler_name);
    const proposed = try synthesizeRoute(allocator, source, spec, handler_name);
    defer allocator.free(proposed);
    const args = try renderApplyArgs(allocator, spec.file, proposed, source);
    defer allocator.free(args);
    const tool = if (parsed.step_index == 3) "zts_expert_edit_simulate" else "apply_edit";
    break :blk try renderToolCall(allocator, parsed.step_index, tool, args);
},
```

(`packages/pi/src/standin/playbook.zig:77-87`). The same `orelse` guard is on add-env (`:186`), write-test (`:240`), and fix (`:273`). The one place that keeps the old permissive behavior is the read-only review playbook, and it says why:

```zig
else => if (is_review)
    // Review answers in text and applies no edit, so an unreadable
    // file costs an answer rather than a file.
    renderReviewText(allocator, parsed.source orelse "")
```

(`packages/pi/src/standin/playbook.zig:135-137`).

The refusal itself carries the reason the user needs:

```zig
/// No read has produced usable bytes for the target file.
///
/// Refuse rather than author from "". `apply_edit` writes unconditionally -
/// `before` is a veto baseline, not a compare-and-swap - so a stub built from
/// nothing would replace whatever the user actually had, and an empty baseline
/// means the draft proves clean on the way out.
fn renderUnreadableSource(allocator: std.mem.Allocator, playbook_name: []const u8) ![]u8 {
    return renderSourceMiss(
        allocator,
        playbook_name,
        "the target file could not be read, because it is missing or larger than one tool result carries",
    );
}
```

(`packages/pi/src/standin/playbook.zig:390-402`). It renders as a `[standin-miss]` text answer, the same shape the stand-in already used for asks outside its declared range.

The regression test constructs the truncated transcript directly rather than mocking around it:

```zig
test "stand-in request parsing reports an unrecoverable read as null, not empty" {
    // What a >32 KiB file looks like after the loop truncates the tool result:
    // no longer valid JSON, so no content can be recovered. Authoring from ""
    // here would overwrite the user's file with a stub.
    ...
    try testing.expectEqual(@as(usize, 1), parsed.step_index);
    try testing.expect(parsed.source == null);
}
```

(`packages/pi/src/standin/request.zig:154-171`).

### The four gates that reported a passing count while asserting nothing

The same review found four test gates in this area that printed numbers nobody was checking. They are a different defect from the one above, but they share its shape closely enough to belong in the same record.

**A frozen corpus outside the hash that guarded it.** `range.negative_corpus` holds the four prompts that must fall outside the stand-in's declared range, and it is the only thing asserting the range does not silently grow. It was not part of `contentHash()`, so emptying it changed no published number, and both false-fire gates that loop over it would have iterated zero times and reported 0/0, which reads exactly like a clean run. Fix: hash the corpus alongside the declared entries (`packages/pi/src/standin/range.zig:175-179`), and assert a floor before trusting any count taken over it (`try testing.expect(range.negative_corpus.len >= 4);` at `packages/pi/src/standin_range_tests.zig:133` and `:144`). The published `content_hash` moved to `970a6c41daae...` (`packages/pi/src/standin/range.zig:12`) because what it covers changed, not because the range did.

**A hand-written row list never compared to the table it covers.** The sequence gate is the only check on tool ordering and the at-most-one-edit rule, and it drives a literal array of six `SequenceCase` rows. A seventh range entry would simply have had no row and escaped the check while the gate still reported success. Fix: one line, `try testing.expectEqual(range.entries.len, cases.len);` (`packages/pi/src/standin_range_tests.zig:190`).

**A test binary whose filter excluded any test not named for it.** The stand-in test roots are compiled with `.filters = &.{"stand-in"}` (`build.zig:316`), so a test whose name omits that token never runs and never reports. Nothing enforced the naming rule the filter depends on. Fix: a gate that `@embedFile`s both roots, fails on any `test "` declaration at column zero without `stand-in` in its name, and guards itself with a floor on how many declarations it saw (`packages/pi/src/standin_range_tests.zig:282-310`).

**An executable compiled by no gate.** `zttp-standin` is deliberately not installed, so nothing forced it to compile and a break would surface only when somebody ran the step by hand. Fix: `test_step.dependOn(&standin_exe.step);` (`build.zig:792`), which compiles it without installing it.

## Why This Works

The type change is the whole fix, and it works for the reason the sibling learning already states: `""` is a real answer to "what are this file's bytes", and the defect was reusing it for a question that was never asked. `?[]const u8` splits the two, and Zig then makes the split non-optional at every use site. There is no way to reach `synthesizeRoute` with the unwrap skipped, because the compiler will not let the optional through.

The refusal, not the veto, is what protects the file. This is worth being explicit about, because the tempting fix is to strengthen the check. Strengthening it would not have worked: `edit_simulate` counts violations introduced relative to a baseline, and deleting correct code introduces none. Even a true baseline would have let the stub through. The only thing that stops a write built on missing information is declining to build it.

Refusing also costs nothing that matters. The stand-in answers `[standin-miss]` with the reason, the user reads that the file is missing or too large to carry in one tool result, and no bytes move. The failure is loud, local, and reversible, where the old behavior was silent, remote from its cause, and destroyed the only copy.

The four gate fixes work by the same move applied to counters instead of strings. `0/0` and `26/26` are both green output; only one of them means anything. Each fix adds the assertion that separates them: a floor on the corpus, an equality against the table being covered, a floor on the declarations scanned, an edge in the build graph. None of them checks new behavior. They check that the existing checks are looking at something.

## Prevention

**Treat an unobtainable baseline as an error, never as an empty one.** This is the generalizable rule, and it is not specific to files or to this agent. Any check of the form "count the NEW problems relative to a baseline" - a diff-aware linter, a coverage ratchet, a violation delta, a performance regression gate - returns a clean verdict when handed an empty baseline, because there is nothing for the new state to be worse than. The failure mode is structural: the check is working correctly and answering the question it was asked, and the question has been quietly replaced. So the code that produces a baseline must be able to say "I could not get one", and that must be a distinct, hard-failing state. If the baseline is optional in the type system, do not default it; make every consumer decide.

**Prefer `?T` over an empty value for "not found".** This repo has now hit this class twice in two days, in unrelated subsystems, and it is already written down: [empty-label-set-claimed-a-value-was-clean](../security-issues/empty-label-set-claimed-a-value-was-clean.md) records a flow checker where the empty `LabelSet` meant both "this value carries nothing" and "the walk never looked", which made the compiler report `no_secret_leakage ... PROVEN` for handlers that leak a secret. Its own Prevention section closes with this rule, after the conflation reappeared inside its own fix: `closuresWithin` returned an empty set for both "no closure here" and "a closure whose only label was just stripped", and became `?LabelSet`. Read that section before writing any function that answers with a container. The same doc names the polarity rule underneath both cases, taken from [normalize-unions-without-dropping-members](normalize-unions-without-dropping-members.md): when an analysis cannot see, it must widen, never narrow, because narrowing turns a rejection into an acceptance.

**Probe the position, do not read the arm.** The sibling learning's probe method transfers directly and would have found this in minutes. There, the probe was a handler that launders a secret through one syntactic position, run through the real compiler, where `PROVEN` is the bug rather than the pass. Here, the equivalent probe is a target file whose size crosses each boundary in the chain, run through the real loop, where a clean apply is the bug:

```bash
# 40 KiB: read succeeds, transcript copy is truncated at 32 KiB.
python3 -c "print('// pad\n' * 6000 + 'export function handler(req: Request): Response { return Response.json({ok:true}); }')" > /tmp/big.ts
# 300 KiB: the read tool itself fails at the 256 KiB limit.
python3 -c "print('// pad\n' * 45000 + 'export function handler(req: Request): Response { return Response.json({ok:true}); }')" > /tmp/huge.ts
# and the third case: a path that does not exist at all.
wc -c /tmp/big.ts /tmp/huge.ts
```

Then ask the agent to add a route to each and check the file afterwards. Reasoning about which branch handles which case is what let this ship; running the boundary is what found it. Any fixture size chosen for convenience is a fixture size that tests one side of a cap.

**Say what a gate covers, so its silence is not read as coverage.** `scripts/verify.sh` and `zig build test-standin` were both green through this, and neither was broken. They covered the small-file path exhaustively and the large-file path not at all. This mirrors what the sibling learning says about `scripts/check-proof-swallow.sh`, which is structurally blind to a function that returns a wrong answer rather than discarding an error. A green gate is evidence about the inputs it was given and nothing else.

**A number that is printed is not a number that is asserted.** This is the operative rule behind all four gate fixes and it is the same failure as the primary bug, one level up. `0/0 false fires`, `26/26 passed`, `all rows checked` are all output; none of them is a claim until something compares them to a value derived independently of the thing being measured. When a gate loops over a collection, assert the collection is non-empty. When a gate drives a hand-written list against a table, assert the two lengths are equal. When a test binary filters by name, enforce the naming rule the filter depends on. When a build product has no consumer, give it one in the test graph. Each is one line, and each converts a number into a claim.

## Related Issues

- [empty-label-set-claimed-a-value-was-clean](../security-issues/empty-label-set-claimed-a-value-was-clean.md) - the same conflation in the ZigTS flow checker, where the empty `LabelSet` meant both "carries nothing" and "never looked". Read its Prevention section with this one: the `?T` rule and the probe method are stated there and apply here unchanged.
- [normalize-unions-without-dropping-members](normalize-unions-without-dropping-members.md) - the polarity rule underneath both: a bounded analysis may degrade quality but must never drop an obligation.
- [a-proxy-signal-carried-a-proof-it-never-claimed](a-proxy-signal-carried-a-proof-it-never-claimed.md) - a signal used for a claim it did not make, the same substitution defect in a different form.
- `packages/pi/src/veto.zig:7` and `packages/tools/src/edit_simulate.zig:100-129` - the contract this bug exploited: `ok = new_count == 0`, counted against `before`. Any change to the meaning of `before` has to be read against `packages/pi/src/loop.zig:849`, where a null (and only a null) triggers the disk-read fallback.
- [a-gate-that-counts-nothing-still-reports-a-pass](../conventions/a-gate-that-counts-nothing-still-reports-a-pass.md) - the four gate weaknesses summarized here, stated as a repo-wide convention with the earlier recurrences and the two scripts that already implement the rule.
- Commit `ab947d20` - the fix, with the twelve other findings from the same review pass.
