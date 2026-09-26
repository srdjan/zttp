---
title: A guard that every input satisfied refused the first new one
date: 2026-09-20
category: conventions
module: tooling (coverage union), scripts (coverage publication), repo-wide (writing any guard or floor)
problem_type: convention
component: testing_framework
severity: medium
applies_when:
  - "Writing a floor or refusal in a gate whose precondition already holds for every input in the tree"
  - "Guarding a publication step keyed on an identity that moves by construction whenever its input is edited"
  - "Probing a refusal branch with a fabricated input and reading the refusal as proof the branch is correct"
  - "Reading a green history as evidence that a guard is satisfiable on a subject it has not yet seen"
  - "Choosing between refusing a first observation and publishing it with its own count"
tags:
  - testing
  - build
  - gates
  - verification
  - fail-closed
  - latent-defect
  - corpus-replay
  - first-run
---

# A guard that every input satisfied refused the first new one

## Context

The coverage page carries a union: of every run ever published for one corpus
identity, which compiler rules did at least one draft trip. One row is a draw
and the union is the fairer answer, so `d5a0193b` (2026-08-26, "docs(coverage):
publish what this corpus has ever reached, not just the last draw", on
`origin/main`) added `scripts/coverage-union.sh` to compute it from
`git log docs/coverage.json`. That script no longer exists at any later tree.
Read it with `git show af447edd^:scripts/coverage-union.sh`; every line cited
from it below is the pre-fix state.

Its commit body names three floors, two of them in the script and the third in
the publisher, and says "All three were probed and refuse". The second is the
one this document is about, at `:101-106`:

```python
# Floor. An identity nothing in history carries would otherwise union to just
# the pending codes and read as a complete answer.
if not matching:
    raise SystemExit(
        "coverage union: no published coverage.json carries corpus %s" % version[:12]
    )
```

The intent is sound. A union over zero published rows plus the pending run is
the pending run wearing the union's name, and the page would print it as the
corpus's whole record.

The defect is what the condition means. `matching` is empty exactly when no
published page carries the identity being published, which is the state every
corpus identity is in the first time it is published. And the identity is not a
stable name. `corpusVersion()` returns `headlineInputIdentity().bytes`
(`packages/pi/src/expert_codegen_record.zig:1045-1047`), and that identity is
built from each case's name, prompt, seed files and mode (`:976-981`). Edit one
prompt and the identity moves. The repository's own workflow for a corpus
defect is to edit the case, re-record, and republish, and the third step ran
into this floor.

Why the author could not see it. The floor was written on 2026-08-26. At this
tree 46 commits touch `docs/coverage.json` and they carry six corpus
identities, each first published at: `83c9c0c040e8` in `c1f18192`
(2026-08-04), `04d2e920b07f` in `4822d2e2` (2026-08-04), `760bc9965c67` in
`a89950a2` (2026-08-10), `19dc67a54ec3` in `90f641ac` (2026-08-16),
`0012ad8ca6d5` in `20360613` (2026-08-17), and `e6801afae099` in `01f159be`
(2026-09-20). Five of the six predate the floor, and `0012ad8ca6d5` already had
four published rows on the day `d5a0193b` landed. Between that commit and the
fix, 27 further commits touched the page, and every one of them carries
`0012ad8ca6d5`. For 25 days every input the floor saw was an identity that
already had history.

The refusal branch was not unexecuted, and this is the part worth being exact
about. `d5a0193b`'s own body says "All three were probed and refuse". A probe
feeds the floor an identity nothing carries and confirms that it refuses, which
shows the branch executes and rejects what it names. It says nothing about
whether the state that reaches the branch is one the workflow legitimately
produces. That question had one answer available, and only by producing the
state: edit a prompt, which is the workflow's own first step for a corpus
defect. Nobody did until 2026-09-20.

The day it fired. `3a19cca5` (2026-09-20, "fix(pi): two corpus cases asked for
what they never stated") amended a prompt in one case and a seed capsule in
another, both of which are hashed into the identity, and its body says "the
corpus version moves from 0012ad8ca6d5 to e6801afae099". `b66b3bca` (same day,
"test(pi): re-record the corpus against the two amended cases") re-recorded and
reported "Unfiltered `zig build test-expert-app`: 1058/1060, the one failure
being docs/coverage.json drift, which the next two commits regenerate in
order." `4b304fe5` republished convergence. The coverage republish, second of
the two announced, is where the floor refused.

That refusal was also a cycle, and its shape is worth stating exactly, because
a bypass already existed on the same path and did not reach the floor.
`assertCoveragePageCurrent` (`expert_codegen_record.zig:4454`) fails the replay
when the page's `corpusVersion`, `rulesTotal` or `rulesTripped` differ from the
run (`:4490-4492`). It runs when `on_headline and !evidencePublicationMode()`
(`:4901-4903`), and `evidencePublicationMode()` is `ZTTP_EVIDENCE_PUBLISH`
equal to `"1"` (`:4058-4061`). `test-expert-app` is a host test root
(`host_test_roots` in `build/host_tests.zig`) and every host root is a dependency
of the aggregate `test` step (`for (host.runs)` in `build.zig`), which `scripts/verify.sh:59-64` runs. So after the
re-record every plain `zig build test` was red on the stale page and would stay
red until the page was regenerated. The publisher runs its replay as
`ZTTP_EVIDENCE_PUBLISH=1 zig build test-expert-app`
(`scripts/update-coverage.sh:56`), which skips the stale check: that is the
escape that lets the page be rewritten while it is wrong, since the check
compares against the very file the publisher is about to write. Downstream of
that escape the pre-fix publisher called `bash scripts/coverage-union.sh` with
the new identity (`af447edd^:scripts/update-coverage.sh:124`), and the floor
refused. The escape covered the check its author knew about. The floor added
later to the same path had no escape, and the only exits were to change the
floor or to hand-write a file whose header says "Generated file. Do not edit."
(`scripts/update-coverage.sh:309`).

The fix is `af447edd` (2026-09-20, "tooling: port the coverage union to Zig and
let a new identity publish"). It is Zig rather than an edit to the python3
heredoc because `AGENTS.md` treats existing Python as legacy to remove as each
area is touched, never a precedent to extend. `01f159be` then republished over
`e6801afae099`, and `69e134d8` ("build: cover the two new coverage-union
steps") closed a second and smaller instance the same morning. Those three,
with `3a19cca5`, `b66b3bca` and `4b304fe5`, are on local `main` and have not
reached `origin/main`. `d5a0193b` is on `origin/main`.

## Guidance

**A guard on "nothing prior" refuses the first legitimate occurrence of its
subject, and its author cannot see that from the inputs in hand, because every
one of them has a prior.** The refusal branch may well have been probed. A
probe with a fabricated input proves the branch executes and rejects what it
names; it does not prove that reaching it is a defect. The question a
first-occurrence guard has to answer is not "does it fire" but "is the state
that fires it one the workflow produces by construction", and a guard whose
author never produced that state has answered only the first.

Apply it in three steps.

**Sort every refusal into one of two kinds, in writing, beside the branch.** A
refusal is either a defect the workflow must never produce, or a first that the
workflow produces by construction. The deleted floor's comment at `:101-102`
says what the refusal protects against and not which kind it is. The port says
which: `compute`'s doc comment at `tooling/coverage_union.zig:242-244` reads
"Refusing instead - as the shell version did - makes the first publication of a
new identity impossible, and the corpus identity moves by construction whenever
a prompt is edited." That sentence is the sort. A branch that refuses a first
must admit it and mark it; a branch that refuses a defect must name the step
that would have to be wrong.

The port sorts its own new refusal the same way, and it is worth walking
through because it is also a guard on a first. `error.FirstRunWithoutCodes`
(in the `Failure` set at `tooling/coverage_union.zig:87`, message at `:102`)
refuses a new identity whose pending run names no codes, which is what the
original floor was actually protecting against: counting an empty set as an
observation. Is a first run with zero codes a legitimate first? It is not, and
the reason is upstream rather than inside the union. The replay refuses a
zero-tripped run before the publisher sees it, at
`expert_codegen_record.zig:4840-4848`: "Zero tripped rules over a corpus this
size is a scan that stopped working, not a finding about the corpus." That
floor makes the empty case a defect, so the union's refusal of it is sound.
Without that upstream floor the same refusal would rest on an assumption.

**Admit a first by counting it, and let the output describe itself.** The fix
does not weaken the intent. When history carries runs of the identity,
`compute` unions the pending codes in without counting them as a published
row, exactly as the shell version did (`:276-288`; the test at `:524`). When
history carries none, the pending run is itself the one observation:
`observations` is 1 and `distinct_sets` is 1 (the test at `:495`). The page
prints those counts, so a union of one says it is a union of one. The renderer
was changed to say so in words: `scripts/update-coverage.sh:223-232` prints
"the single published run" and "one shape" at a count of 1, in place of "1
published runs ... 1 distinct shapes", and the current page reads "Across the
single published run of corpus `e6801afae099`, the tripped set took one shape"
(`docs/coverage.md:66-67`). The original floor was afraid a first would read as
a complete answer. A first that announces its own count does not.

**Produce the first legitimate input and run the workflow through its last
step.** This is the cheap test, and it is the one `d5a0193b` did not run. Do
not feed the guard a fabricated value, which is what a probe does and why a
probe cannot answer this. Take the workflow's own step that creates a new
subject: edit a prompt, add a rule to the registry, add a build step, add a
provider. Apply it in a scratch copy. Then run the prescribed workflow from
that step to its last step and read the last step's exit status. If a guard
fires, you have found a first-occurrence guard with no first-occurrence branch,
and you have found it before a re-record has left the tree red. The port's test
at `tooling/coverage_union.zig:495`, "the first publication of an identity is
one observation, not a refusal", is exactly this probe made permanent: it
commits history under one identity and asks for a union under another, which is
the state a prompt edit leaves behind.

Two smaller rules follow from the same morning.

**A refusal names its exit.** The deleted floor's message at `:105` named the
identity and nothing else. Compare the step-coverage gate's failure text in
`build/step_coverage.zig`, which ends "Run the step from scripts/verify.sh, a CI
workflow, or `zig build test`; or add a row to scripts/manual-steps.allow with
the reason a human asks for it." A reader of the first message has to work out
whether they are looking at a defect or a first. A reader of the second is told
the two legitimate answers and picks one.

**A bypass for one guard does not reach a guard added later to the same
path.** `ZTTP_EVIDENCE_PUBLISH` exists so the publisher's replay can run while
the page it compares against is wrong. The union floor joined the same
publication path a month later with no bypass, and it needed none, since its
correct behaviour on a first is to admit rather than to skip. When adding a
guard to a path that already carries an escape, decide which of those two it
is and write the decision down. The cycle here was invisible for 25 days partly
because the escape made the path look as if "the page is stale or new" had
already been handled.

## Why This Matters

The failure mode is specific and it recurs. A guard is written against a
snapshot of the world, and the snapshot is the set of inputs that exist on the
day. Every one of them satisfies the precondition, so the author's model of
"when this refuses" is drawn from imagination alone, and the imagined case is
the fabricated one used to probe it. The first genuinely new input arrives
later, in the middle of the change that made it new, and that is the worst
moment. Here it arrived after a paid re-record, with `zig build test` already
red on drift and the workflow's announced next commit blocked.

This is a different failure from the two already documented for gates.
[a-gate-that-counts-nothing-still-reports-a-pass](a-gate-that-counts-nothing-still-reports-a-pass.md)
is about a gate that passes while checking nothing.
[a-gate-can-be-non-vacuous-and-still-porous](a-gate-can-be-non-vacuous-and-still-porous.md)
is about a gate that checks something real and misses the cases nobody named.
Both fail open. This one fails closed on a legitimate input, and only once the
input's subject is genuinely new. It is not vacuous: the floor had a full input
for 25 days. It is not porous: the floor caught exactly what it was written to
catch. Its refusal was probed and observed. None of the checks in those two
documents would have found it, because each asks whether a gate rejects what it
should, and this floor's defect is that it rejects what it should not.

The correction is not a licence to relax. Fixing this floor opened the opposite
failure at the same branch within hours, which is the second half of the
lesson. The port skips a `docs/coverage.json` blob that does not parse, which
is correct on its own. But a skipped blob has no readable `corpusVersion`, so
it may have been a run of the identity being published, and the first-run path
read "no readable run carries this identity" as "no run was ever published". An
identity whose only published row was unreadable would have been reported as
one observation of the pending codes alone: the exact claim the original floor
existed to prevent, now made silently instead of refused. `2ad78dad` counts
unreadable blobs and refuses the first-publication claim when any exist. It is
latent rather than live, measured: all 46 blobs in this history parse today.

Two things about how that one was found are worth keeping. No probe found it,
and two independent security reviews had read the whole file and passed it.
They were not wrong: they assessed the skip as safe parsing, which it is. The
defect was in what an empty result then licenses a caller to claim, which is a
correctness question and was outside what either review was asked. It surfaced
from reading what a review had recorded neutrally and not evaluated. When a
guard is relaxed, the new permissive branch deserves the same sorting the
refusal got, and a reviewer's neutral observation about a path near it is a
place to look.

The contrast that landed the same morning shows the shape that does not have
this defect. `69e134d8` was caught by `test-step-coverage` (`build/step_coverage.zig`),
which walks `b.top_level_steps.values()` at build time, so its
universe of inputs is the live graph and a step added an hour ago is in it the
moment it exists. The gate is bidirectional: a step nothing runs fails,
a row for a step something now runs fails, and a row naming a step that no
longer exists fails. It is a dependency of `zig build test`, which `scripts/verify.sh:59-64` runs,
and `69e134d8`'s body records "Found by scripts/verify.sh, not by the previous
commit's narrower runs." It refused two new steps, named both exits, and the
fix was one line in the aggregate `test` step of `build.zig` and one allowlist row with its reason
(`scripts/manual-steps.allow:77-83`). The gate did not know in advance whether
the new steps were defects or firsts. It refused loudly, said what each answer
would look like, and let a human sort them. That is what a first-occurrence
branch looks like when the gate cannot decide on its own.

## When to Apply

Whenever a guard's condition is an absence: no history, no baseline, no prior
run, no row, no matching entry, not seen before. Those words are the signature.
A guard on absence is a guard on the first occurrence, and the first occurrence
is legitimate unless something upstream has already made it a defect.

Whenever the guard's subject is an identity derived from content, so that
ordinary edits create a new subject: corpus identities, content hashes, policy
hashes, manifest digests. The author sees a handful of stable-looking values,
and the values are not stable.

Whenever a guard is added to a path that already carries an escape for a
sibling guard. Ask whether the escape must reach the new guard, or whether the
new guard must not need one.

Whenever a guard is relaxed. The branch that now admits what was refused is new
code on the same condition, and it needs the same sorting: what does admitting
claim, and can the inputs support that claim in every state that reaches it.

Not needed when the guard's condition is a defect by construction and the
construction is written beside it: an upstream floor that already refuses the
state, or a step that cannot produce it. `FirstRunWithoutCodes` is that case,
and its reason is `expert_codegen_record.zig:4840-4848`.

## Examples

### 1. The floor, and the branch the fix gave it

Before, at `af447edd^:scripts/coverage-union.sh:99-106`: the refusal with no
first-occurrence branch, quoted in Context. After, at
`tooling/coverage_union.zig:276-289`:

```zig
if (published.items.len == 0) {
    if (pending_set.len == 0) return error.FirstRunWithoutCodes;
    // ... a blob that could not be read may have been a run of this identity
    if (unreadable != 0) return error.FirstRunWithUnreadableHistory;
    const only = try arena.alloc(CodeSet, 1);
    only[0] = .{ .codes = pending_set };
    sets = only;
}
if (sets.len == 0) return error.NoTrippedList;
```

The outer branch admits a first and counts it as one observation. The two inner
refusals keep the original intent: the first because an empty set is a defect
upstream, the second because an unreadable history cannot support the claim
that this is a first at all.

### 2. The probe that would have found it

The test at `tooling/coverage_union.zig:495`:

```zig
// History exists but carries a different identity - exactly the state a
// prompt edit leaves behind, and the one the shell version refused.
try fixture.publish(io, version_b, &.{ "ZTS400", "ZTS500" });

var result = try compute(testing.allocator, io, fixture.root, version_a, &.{ "ZTS500", "ZTS400", "ZTS501" });
try testing.expectEqual(@as(usize, 1), result.observations);
try testing.expectEqual(@as(usize, 1), result.distinct_sets);
```

It builds a throwaway git repository and commits a real `docs/coverage.json`,
so the thing under test is the same `git log` and `git show` path the tool
runs. That is the first legitimate input from Guidance, and it is the test the
original script did not have. The refusals are covered by a census over the
error set (`:581`, iterating `@typeInfo(Failure).error_set` at `:589`), which
requires a message for every member and probes each one the library entry
point can reach; the comment at `:632` names the two it cannot.

### 3. The publisher reads a marker, with a floor

`scripts/update-coverage.sh:131-142`. `zig build` owns the step's stdout, so
the union is read from one `[coverage-union] ` line
(`tooling/coverage_union.zig:37`) and the reader requires exactly one such
line, matching the `[seed-coverage]` reader at `:107-109`. This is the rule
from
[a-gate-that-counts-nothing-still-reports-a-pass](a-gate-that-counts-nothing-still-reports-a-pass.md)
applied to the new reader, so that the fix did not introduce the failure that
document describes.

### 4. The sentence a union of one prints

`scripts/update-coverage.sh:223-232` and `:374-376`. The page says "the single
published run" and "one shape" when the counts are 1, and the current
`docs/coverage.json` carries `"observations": 1`, `"distinctSets": 1` and
`"unionCount": 3` for `e6801afae099`. A reader can see it is a first. That is
what makes admitting a first safe.

### 5. The instance that was caught

`69e134d8`, one line in the aggregate `test` step of `build.zig`:

```zig
test_step.dependOn(&run_coverage_union_tests.step);
```

and the allowlist row at `scripts/manual-steps.allow:77-83`, which says why
`coverage-union` itself is a publication operation and not a check: the
publisher "refuses a dirty tree and so cannot run inside a build that is itself
producing artifacts." The gate refused both new steps, its message named both
exits, and each step got the exit that fit it.

## Related

- `CONCEPTS.md`, the Gate and Probe entries - the whole class in one place; the Gate entry carries the fail-closed member this document is about
- [a-gate-that-counts-nothing-still-reports-a-pass](a-gate-that-counts-nothing-still-reports-a-pass.md) - vacuity, and the marker-line floor that Example 3 applies
- [a-gate-can-be-non-vacuous-and-still-porous](a-gate-can-be-non-vacuous-and-still-porous.md) - porosity, and the mutation harness; its "apply the edit and run the real gate" method is the one this document turns toward legitimate firsts rather than illegitimate edits
- [difference-is-not-the-claim-and-a-probe-must-compile](difference-is-not-the-claim-and-a-probe-must-compile.md) - a probe's verdict is read from an exit status; the cheap test in Guidance is read the same way
- [a-stale-cassette-is-loud-and-an-unsatisfiable-seed-is-silent](../logic-errors/a-stale-cassette-is-loud-and-an-unsatisfiable-seed-is-silent.md) - the same morning's other finding, `78b3005f`, on a seed no fill could satisfy; that one was silent where this one was loud
- `tooling/coverage_union.zig` - the port, with the sort written at `:242-244` and the first-occurrence branch at `:276-289`
- `git show af447edd^:scripts/coverage-union.sh` - the pre-fix script; it exists at no later tree
- Commits are cited by SHA because this repository works on local `main` and opens no pull requests. Of those named here only `d5a0193b` has reached `origin/main`; the rest are local and may be rewritten if they are ever rebased.
