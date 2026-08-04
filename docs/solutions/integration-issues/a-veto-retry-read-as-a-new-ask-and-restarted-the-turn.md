---
title: A veto retry read as a new ask and restarted the turn
date: 2026-08-04
category: integration-issues
module: pi expert agent loop and deterministic stand-in request parser
problem_type: integration_issue
component: tooling
severity: medium
symptoms:
  - "A rejected draft made the deterministic stand-in restart its playbook at step 0, with the veto retry nudge itself as the new ask."
  - "The ask, the step index, and the file bytes recovered earlier in the same turn were all cleared mid-turn."
  - "The compiler-authored repair note reset the turn the same way, because a system_note is serialized to the wire as a user-role message."
  - "Nothing failed while the defect existed - no stand-in draft had ever failed the veto, so the branch was unreachable until defect seeds were added."
root_cause: logic_error
resolution_type: code_fix
related_components:
  - testing_framework
tags:
  - pi
  - expert-agent
  - standin
  - wire-protocol
  - turn-state
  - veto-retry
  - latent-defect
  - prefix-drift
---

# A mid-turn nudge read as a new ask, and the stand-in restarted its turn

## Problem

The `zttp expert` agent loop appends messages to the transcript while a turn is
still running, and two of them reach the provider as user-role items. The
deterministic stand-in reconstructs the state of the turn from the request body
on every call, and it treated any user message that did not open with
`[expert workflow]` as the start of a new ask. So a veto rejection cleared the
ask, the step index, and the recovered source, and the playbook restarted at step
0 with the loop's own retry nudge as its ask.

## Symptoms

None, ever. That is the first thing to say about it.

Had the branch been reachable, the shape would have been a turn that never
advances. The stand-in answers step 0 of a playbook, the draft is rejected, the
loop appends its nudge, the stand-in reads that nudge as a fresh ask and answers
step 0 again, and every retry after that repeats the same message until the
attempt cap ends the turn. The recovered file bytes are dropped at the same
moment, so any step that authored from `parsed.source` would take the refusal
path instead. The visible failure is a loop that spends its attempts saying the
same thing, and the cause is four fields being reset by a message that was never
an ask.

The absence of a symptom is the point. Every stand-in draft is authored by repo
code to pass the same veto that judges it, so no draft had ever been rejected,
and the reset branch had never run. The defect was correct-looking code on a path
with no traffic.

## What Didn't Work

Nothing was tried and failed here, because nothing was ever attempted against
this behavior. The honest question is why review did not find it, and the answer
is that reading the code shows a special case that looks complete:

```zig
if (isUserMessage(item)) {
    const text = try readInputText(item);
    // The workflow note rides along as a second user message on the
    // same turn, so it must not reset the turn it belongs to.
    if (!std.mem.startsWith(u8, text, "[expert workflow]")) {
        ask = text;
        step_index = 0;
        source = null;
    }
}
```

(`packages/pi/src/standin/request.zig` at `d4f4491a^`.) The comment names a real
hazard, the guard handles it, and the guard is correct for the marker it names.
Nothing in that file says how many such markers exist. The literal was a bare
string in the reader, and its author, `renderSystemNote` in
`packages/pi/src/expert_workflow.zig`, held its own bare copy in a format string.
Two other messages of the same class were written elsewhere in
`packages/pi/src/loop.zig`, in the `.retry_draft` arm and in the auto-repair
block, and neither file had any reason to know about the other. To find the gap a
reader had to hold three files at once and ask what else lands as a user message
mid-turn, which is a question the code did not pose.

What found it was building the feature that could reach it. The defect seeds
landed first: drafts written to fail the veto on purpose, so the rejection half
of the loop became reachable offline. Only then did a stand-in draft ever get
bounced, and the reset became live code. The bug was found by constructing the
traffic, not by reading the road.

## Solution

Commit `d4f4491a`. Three parts, and the third is the one worth copying.

**The authored prefixes became exports, used in their own format strings.**
`packages/pi/src/loop.zig` now declares the two messages it writes mid-turn, with
the reason they need names:

```zig
/// The mid-turn messages this loop authors, exported so a reader of the wire can
/// recognize them.
///
/// Both reach the provider as user-role items - `extra_user_text` is a user
/// message and a `system_note` is serialized as one - so anything reconstructing
/// turn state from the request body sees them as ordinary user text. Something
/// that treats a user message as the start of a new ask will silently restart
/// mid-turn on every retry, which is exactly what the deterministic stand-in did
/// until these were named.
pub const veto_retry_prefix = "Your previous edit failed compiler verification";
pub const compiler_repair_prefix = "Compiler-authored repair for your last edit";
```

Each is concatenated into the format string at the single place that writes it:
`veto_retry_prefix ++ " (attempt {d}/{d}). "` in the `.retry_draft` arm, and
`compiler_repair_prefix ++ ". Apply these changes verbatim, ..."` where the
auto-repair block is appended as a `.system_note`. `workflow_note_prefix` in
`packages/pi/src/expert_workflow.zig` took the same treatment inside
`renderSystemNote`. A fourth constant, `veto_reject_preamble`, names the opening
words of the failed-apply tool result, which is a `function_call_output` body
rather than a user message. Because the literal and the exported name are the
same token in the same expression, the text cannot change without the export
changing with it.

The claim in that doc comment is worth checking against the provider, because it
is the whole reason the two messages are indistinguishable on the wire. In
`packages/pi/src/providers/openai/client.zig`, `buildRequestBody` serializes
`extra_user_text` through `writeUserMessage`, and `writeTranscriptEntry` routes
the `.system_note` arm through the same function:

```zig
.system_note => |body| {
    // System notes are surfaced as additional user-role context
    // blocks; the top-level `instructions` field carries the
    // persona prompt exclusively.
    ...
    try writeUserMessage(w, body);
},
```

Both arrive as `{"role":"user","content":[{"type":"input_text", ...}]}`. There is
no field a reader can key on. The opening text is the only signal.

**The stand-in keeps its own copies, and gained two fields in the same pass.**
`packages/pi/src/standin/request.zig` declares `continuation_prefixes` with the
three rows and `isContinuation` over them, and says why it duplicates rather than
imports:

```zig
/// Duplicated from the authors rather than imported: pulling `loop.zig` in here
/// would drag the whole agent into the stand-in executable. A gate asserts the
/// two copies agree, in both directions, the way the negative corpus is held
/// against `expert_eval.cases`.
pub const continuation_prefixes = [_][]const u8{
    "[expert workflow]",
    "Your previous edit failed compiler verification",
    "Compiler-authored repair for your last edit",
};
```

`ParsedRequest` also gained `last_output` and `rejected_drafts`, both computed in
the existing single pass over `input`, so `parse` stays a pure function of the
request body with no state of its own. `rejected_drafts` counts the
function-call outputs opening with `veto_reject_preamble`, which is what
separates "past the apply step because the edit landed" from "past it because the
compiler bounced it". The step index alone cannot express that, since both
advance it by one.

Two regression tests build the wire shape directly. "stand-in request parsing
keeps the turn through a veto rejection and its retry notice" feeds an ask, a
workflow note, a successful read, a failed apply, and the retry nudge, then
requires the original ask, `step_index == 2`, the recovered source, and
`rejected_drafts == 1`. "stand-in request parsing keeps the turn through a
compiler-authored repair note" does the same for the repair note.

**A gate holds the two copies together in both directions.** The test is
"stand-in gate: continuation prefixes match the messages the loop authors" in
`packages/pi/src/standin_range_tests.zig`. It builds the authored list from the
exports, asserts a floor, then walks each set against the other:

```zig
const authored = [_][]const u8{
    expert_workflow.workflow_note_prefix,
    loop.veto_retry_prefix,
    loop.compiler_repair_prefix,
};

// Floor first: an emptied table would make both loops below iterate nothing
// and report agreement between two empty sets, which is the state that
// reintroduces the turn reset.
try testing.expect(standin_request.continuation_prefixes.len >= 3);
try testing.expectEqual(authored.len, standin_request.continuation_prefixes.len);
```

The first loop requires each authored prefix to appear exactly once in the
stand-in's table and reports `the loop authors "{s}" and the stand-in skips it
{d} times`. The second loop requires the reverse and reports `the stand-in skips
"{s}", which nothing authors`. Both return `error.ContinuationPrefixDrifted`. A
final `expectEqualStrings(loop.veto_reject_preamble,
standin_request.veto_reject_preamble)` covers the tool-output constant.

One direction would not be enough, and the two failures it misses are different.
A subset check, every stand-in row is authored, passes when the loop adds a
fourth message the stand-in has never heard of, which is the original bug
returning. A superset check, every authored message is skipped, passes when the
loop stops writing a message the stand-in still skips, which makes the stand-in
ignore a real ask that happens to open with dead text. Only both directions plus
the length equality pin the two tables to each other.

The probe was to shrink `continuation_prefixes` back to one row. Both new parse
tests fail, reproducing the reset exactly, and the gate names the missing rows.

## Why This Works

The defect is not a missing case in a switch. It is a message that is
semantically a control signal and syntactically ordinary user content. The
provider protocol has one user role and no field for "this is the loop talking to
itself", so the distinction lives entirely in the opening words. Any component
that has to make that distinction must therefore re-derive it, and with the
literals hidden inside format strings the only place to derive it from was prose:
a code comment in the reader, naming one marker it happened to know about.

Exporting the literal from the code that writes it turns the distinction into a
named thing that two files can agree on. `veto_retry_prefix` is not documentation
about the wire, it is the wire. The format string and the reader's table now
refer to the same fact instead of to two hand-copied instances of it, and adding
a fourth mid-turn message means adding an export, which is a visible act in the
file that already holds the other three.

Naming alone does not hold, because the stand-in still keeps copies. The
duplication is deliberate and has a cost stated where it is paid: importing
`loop.zig` into `packages/pi/src/standin/request.zig` would pull the whole agent
into the stand-in executable. What keeps duplicated facts from rotting is a gate
over both directions, and the both-directions part is not pedantry. Each
direction catches a different rot, and each single-direction check is green in
the presence of the other's failure. The floor on the table is there for the
reason the sibling documents give: two empty sets agree perfectly.

## Prevention

**When one component reconstructs another's state from a shared wire format,
export the markers from whoever writes them.** This is the generalizable rule. A
protocol that carries control information inside a field typed as content forces
every reader to re-derive the boundary, and a re-derivation written as a string
literal in the reader is a copy with no link back to its source. Export the
literal from its author, use it in the author's own format string so the two
cannot separate, and make every reader refer to that name. If the reader cannot
import the author, that is an acceptable trade with a stated reason, but the copy
is then a fact held in two places and needs a gate.

**Gate a duplicated table in both directions, with a floor.** A subset check
passes when the source grows a row the copy lacks. A superset check passes when
the source drops a row the copy still carries. The two failures are not
symmetric, and both are silent. Assert the lengths are equal, walk each set
against the other requiring exactly one match, and assert a floor on the table
before either loop, because a gate that iterates nothing reports agreement. This
is the same rule as
[a-gate-that-counts-nothing-still-reports-a-pass](../conventions/a-gate-that-counts-nothing-still-reports-a-pass.md),
applied to a pair rather than to one collection.

**A latent defect on an unexercised path is found by building the thing that
exercises it.** No review pass over
`packages/pi/src/standin/request.zig` would have found this, because the code
reads correctly for the one marker it names, and the absence of the other two is
information that lives in different files. What found it was the defect seeds:
once a stand-in draft could fail the veto on purpose, the reset branch had
traffic for the first time. That is an argument for the offline arms as a method
rather than a lucky side effect of them. When a code path exists only for a
condition nothing in the test suite can produce, the suite is not weak about that
path, it is silent about it, and the way to break the silence is to construct the
condition. This repo now has three records where the finding instrument was
construction rather than reading: the boundary-sized files in
[empty-baseline-made-a-file-destroying-edit-prove-clean](../logic-errors/empty-baseline-made-a-file-destroying-edit-prove-clean.md),
the seeded rejections here, and the deliberate probe in
[difference-is-not-the-claim-and-a-probe-must-compile](../conventions/difference-is-not-the-claim-and-a-probe-must-compile.md).

**Ask what else arrives in this shape.** The operative question when writing a
guard against one marker is not "is this guard correct" but "how many markers are
there, and who decides". If the answer is not a list somewhere, the guard is
complete only by coincidence. Write the list, put it next to the code that writes
the messages, and let the reader hold a copy under a gate.

## Related Issues

- [difference-is-not-the-claim-and-a-probe-must-compile](../conventions/difference-is-not-the-claim-and-a-probe-must-compile.md) - the gate rules this fix's gate follows, from the same subsystem on the same day
- [a-gate-that-counts-nothing-still-reports-a-pass](../conventions/a-gate-that-counts-nothing-still-reports-a-pass.md) - the floor-on-input rule, which is why the prefix gate asserts a length before comparing
- [empty-baseline-made-a-file-destroying-edit-prove-clean](../logic-errors/empty-baseline-made-a-file-destroying-edit-prove-clean.md) - the other stand-in parsing defect, where a value that could not be recovered was reported as an empty one; `ParsedRequest.source` carries its comment
- [two-hole-fills-in-one-turn-do-not-compose](../logic-errors/two-hole-fills-in-one-turn-do-not-compose.md) - another stand-in loop invariant that was carried by an assertion rather than by structure
- Commit `d4f4491a` - the exports, the prefix table, `last_output` and `rejected_drafts`, the two parse tests, and the both-directions gate
- Commit `6e27440e` - the defect seeds that made the rejection branch reachable, which is what surfaced this
