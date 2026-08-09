# Convergence

[STRATEGY.md](../STRATEGY.md) claims that the set of programs the agent can
write should converge on the set of programs the compiler can prove. This page
is the measurement of that claim, so the claim has an answer when someone asks
for one.

The headline figure is **first-draft veto-pass rate**: how often the model's
first attempt at a prompt clears the compiler veto with no retries. It is a
counted result over a frozen corpus, not an estimate.

## Results

| Recorded | Commit | Corpus | Cases | Model | Policy | First-draft pass | Median round-trips | Intent pass |
|---|---|---|---|---|---|---|---|---|
| 2026-08-01 | `e4a13aee` | `b28a83a531db` | 11 | claude-sonnet-4-6 | `37a115c262dc` | 90% (10/11) | 5 | 100% (6/6) |
| 2026-08-01 | `847840a4-dirty` | `b28a83a531db` | 11 | claude-sonnet-4-6 | `118885d3f647` | 90% (10/11) | 5 | 100% (6/6) |
| 2026-08-02 | `57269997` | `b28a83a531db` | 11 | claude-sonnet-4-6 | `118885d3f647` | 90% (10/11) | 5 | 100% (6/6) |
| 2026-08-02 | `79e9fc86` | `b28a83a531db` | 11 | claude-sonnet-4-6 | `118885d3f647` | 90% (10/11) | 5 | 100% (6/6) |
| 2026-08-02 | `845025e7` | `b28a83a531db` | 11 | claude-sonnet-4-6 | `118885d3f647` | 90% (10/11) | 5 | 100% (6/6) |
| 2026-08-02 | `2db4545c` | `b28a83a531db` | 11 | claude-sonnet-4-6 | `118885d3f647` | 90% (10/11) | 5 | 100% (6/6) |
| 2026-08-02 | `ec31f5a8` | `b28a83a531db` | 11 | claude-sonnet-4-6 | `118885d3f647` | 90% (10/11) | 5 | 100% (6/6) |
| 2026-08-02 | `631aabd6` | `b28a83a531db` | 11 | claude-sonnet-4-6 | `118885d3f647` | 90% (10/11) | 5 | 100% (6/6) |
| 2026-08-02 | `9b7518ea` | `b28a83a531db` | 11 | claude-sonnet-4-6 | `118885d3f647` | 90% (10/11) | 5 | 100% (6/6) |
| 2026-08-02 | `7ec8ba85` | `ed809ba50da1` | 11 | claude-sonnet-4-6 | `118885d3f647` | 90% (10/11) | 4 | 100% (6/6) |
| 2026-08-03 | `74d48add` | `3742860e78b2` | 16 | claude-sonnet-4-6 | `118885d3f647` | 87% (14/16) | 4 | 100% (10/10) |
| 2026-08-03 | `aba46bee` | `d6b571835aa5` | 16 | claude-sonnet-4-6 | `118885d3f647` | 93% (15/16) | 4 | 100% (10/10) |
| 2026-08-03 | `d984092c` | `d6b571835aa5` | 16 | claude-haiku-4-5-20251001 | `118885d3f647` | 25% (4/16) | 3 | 90% (9/10) |
| 2026-08-03 | `39449aff` | `83c9c0c040e8` | 20 | claude-sonnet-4-6 | `118885d3f647` | 95% (19/20) | 4 | 100% (14/14) |
| 2026-08-04 | `4822d2e2` | `04d2e920b07f` | 20 | claude-sonnet-4-6 | `118885d3f647` | 100% (20/20) | 4 | 100% (14/14) |
| 2026-08-09 | `6f02ad7c` | `04d2e920b07f` | 20 | claude-sonnet-4-6 | `118885d3f647` | 100% (20/20) | 4 | 100% (14/14) |

Regenerate with `bash scripts/update-convergence.sh`, which appends a row and
rewrites [convergence.json](convergence.json). History is git history on those
two files.

The first nine rows share a corpus and a policy hash and differ only by build.
Between the second and the third, the flow checker stopped proving through
three fail-opens - a call it could not enter, and two shapes of egress options
object it could not read field by field - and gained the ability to walk a
helper imported from a sibling file. The fourth adds one more: a closure passed
as an argument now carries the labels of the value it produces, so a secret
returned from a `map` callback no longer reaches the response unlabelled.

The fifth carries one of each. A callback a module invokes now carries what it
returns out of that module, closing the last of the fail-opens: a module export
answers with its declared return labels, and those cannot describe what a
caller's callback produced, so `parallel([() => env("SECRET_KEY")])` had still
been proving clean. Alongside it, `deterministic` moved from answering whether a
varying value was read to whether one reaches the response, so a handler that
logs a timestamp and returns a constant keeps the property and keeps
`idempotent` with it. That second change is a loosening: strictly more programs
prove than before.

The sixth is a tightening that a precision change forced into the open. The
per-export capability rows reached `zttp:cache` and `zttp:service`, and taking
the clock off `cacheStats` - which sums counters and reads no clock - flipped a
golden fixture's `deterministic` from false to true. The verdict had been right
for an accidental reason: the varying-value label was read off the capability
set, and the module-level `.clock` happened to cover a call returning live
counters. `zttp:sql` declares no clock at all, so the same rule had been proving
`deterministic` for a handler returning database rows. A read from mutable
module state is now its own varying source, which no capability set can express.

The seventh moves no fence at all, and it is here to say so. It is the first
row published after the compiler started advertising an exact repair - ZTS620
carries `repair_available: true` - and after five more repair intents became
reachable from a single request rather than only through a whole-file
normalize. Neither can change a first-draft rate: a repair is what happens
*after* a draft is vetoed, so it shows up in round-trips and in the
compiler-authored apply share, not in the headline. The row exists so the two
are separable later, when a corpus large enough to move round-trips exists.

The eighth is the same kind of row and worth the same honesty. It is the first
published after the hole-mode turn loop exists - a turn can now spend itself on
one hole, structurally, rather than being asked to - and after the protocol grew
`verify` and `simulate_edit`. Neither is visible here either, for a sharper
reason than the seventh: this corpus contains no hole-mode session at all. A
cassette replay is a ratchet over outcomes already recorded, so it can confirm
a compiler change did not flip one and it cannot produce a turn nobody recorded.
Measuring the loop change needs hole-mode sessions run against a live model,
which is the same blocker as the item-5 model row.

The ninth closes the agenda's construction work: the remaining declared-law
rows discharge, so six intents repair mechanically rather than one, and
`apply_repair` writes. It moves nothing here for the seventh row's reason -
repairs act after a veto - and it does raise the ceiling on what the
compiler-authored apply share could reach, which is the counter to watch once a
corpus large enough to move round-trips exists.

None of it adds a rule, so the policy hash cannot separate these rows and the
commit column is what does. The rate held at 90% throughout - six tightenings,
one loosening, and three changes the headline cannot see - and this corpus felt
none of them. The replay is a ratchet, failing if a compiler change flips a
recorded first-draft outcome, so that is a checked result rather than a quiet
one. What it also says is that eleven cases are too few to see a fence move:
none of them logs a timestamp, none returns a row it read from a store, none
writes the shapes the fail-opens hid behind, none has a first draft that trips
one of the five newly reachable rewrites, and none was recorded in hole mode.

That list has stopped being a caveat and become the finding. Nine rows over one
corpus, every one of them 90%, is the corpus reporting its own resolution rather
than the compiler holding still - eleven cases cannot separate nine builds. The
next thing worth doing to this number is growing what it measures over.

The tenth row is the first on a different corpus, and the corpus column says so:
`ed809ba50da1` rather than `b28a83a531db`. It must not be read as the tenth
point of the series above. The forge tools left the guidance, so every case is
now authored by the model rather than synthesized in Zig, and the persona gained
an instruction to dry-run each draft through `zts_expert_edit_simulate` before
`apply_edit`.

The headline did not move, and what sits behind it did. `validate-body` stopped
being the pinned failure: its `as` draft never reaches the veto now, because the
model sees ZTS042 in simulation first. `jwt-auth` took its place, and for a
different reason - returning the claims the prompt asks for trips ZTS401, so the
first draft is rejected for doing what was requested. One gap closed and another
opened, netting the same 90%, which is a reminder that a held rate is not
evidence of a held cause.

Median round-trips moved for the first time, 5 to 4. That column had been flat
across nine builds, and the dry-run instruction is the visible reason: a draft
that would have cost a veto retry now costs a simulate call instead. The intent
column reads 100% again but over a corrected check - see the section below on
`websocket-echo` - so it is not comparable to the 100% above it either.

## The eleventh row: the corpus grew to sixteen

The rate moved for the first time in eleven rows, 90% to 87%, and the policy
hash did not. The compiler is the same build the tenth row was taken on. What
changed is the corpus: five cases added, and all sixteen re-recorded rather than
the eleven being held and five appended.

The reading that matters is which cases moved it. **All five new cases passed
first draft.** The two failures are both from the original eleven: `jwt-auth`,
which is the tenth row's pin and still reaches green, and
`workflow-nested-dispatch-avoidance`, which was a pass in the tenth row and is
now a failure that does not reach green at all.

Nothing in the compiler did that. The same build replays the *old*
`workflow-nested-dispatch-avoidance` cassette at a pass. The old session was four
steps; the new one is eighteen, its first draft is a far larger program - it
compiles a schema, decodes the body, logs - and it trips ZTS204 on a declared
return type. That is the model drawing a different first draft on two recordings
of one prompt. It is pinned rather than re-rolled: recording until the old
outcome came back would be selecting the sample that flatters the rate.

So the honest summary of this row is that the corpus still has not seen a fence
move. It has seen recording variance, and the 3-point drop is that variance
rather than any of the five new fences biting. The new cases exist so that a
*future* build which moves one of those fences becomes visible here; on this
build the fences they stand on had already moved, several rows back.

Intent is the column that genuinely improved: the denominator went from 6 to 10
and the rate held at 100%. Four of the five new cases carry a spec, and one old
spec was corrected - see `jwt-auth` below.

Five cases were added on 2026-08-03, taking the corpus from eleven to sixteen.
Each stands on one fence the paragraph above says the original eleven could not
feel. `log-timestamp` logs a clock read and returns a constant, which is the
`deterministic` loosening in the fifth row; nothing in the eleven read a clock at
all. `cache-counter` returns a value read from a store, which is the sixth row's
tightening. `sibling-helper` puts the handler's helper in another file, so the
cross-file label walk from the third row has something to stand on.
`egress-options` sets a method and headers in the fetch init object, one of the
shapes the flow checker could not read field by field. `parallel-secret` stands
on the callback-into-module labels of the fifth row.

Every design was checked against the analyzer before it was written down, so a
case cannot fail for a harness reason and be read as a model failure:
`log-timestamp` proves `deterministic` and `cache-counter` does not,
`sibling-helper` trips ZTS400 through the import and is clean without it, and
each io stub was confirmed load-bearing by giving it the wrong value and
watching the assertion fail.

That check is also how one of the five was authored wrong. `parallel-secret` was
pinned as a failure on the reasoning that no draft could pass it: the array
`parallel()` returns unions every callback's labels and indexing does not narrow
back, so returning the app name is refused for what a sibling callback read. The
imprecision is real and still documented in
[a label union that never narrows](solutions/logic-errors/a-label-union-that-never-narrows-refuses-a-clean-program.md).
The conclusion drawn from it was not. Asked for the task, the model reduced the
secret to a boolean *inside* the callback, so nothing carrying the label ever
crossed the boundary and there was no union to narrow. It passed first draft,
after three `zts_expert_edit_simulate` dry runs. The pin is a pass, and what the
case measures is the containment rather than the imprecision.

Worth stating plainly, because it cuts against the reason the corpus was grown:
a case authored from analysis rather than from a recording can encode the
author's wrong conclusion, and here the recording is what caught it.

`jwt-auth`'s intent spec was corrected in the same pass, and it had been wrong
for ten rows. It asserts that a request with no bearer token is unauthorized,
but stubbed no `JWT_SECRET`, so a handler that validates its configuration
before reading the request answers 500 "server misconfigured" and the check
records a bearer-token failure that never happened. It passed only because every
recorded handler until now read the header first. This re-record produced one
that checks the secret first, the check failed on a handler that does return 401
for a missing token, and the spec gained the env stub. Same class as the
`websocket-echo` correction below, opposite direction: that one passed for a
reason its name did not describe, this one failed for one.

## The twelfth row: a security tightening that raised the headline

87% to 93%, and it must not be read as the agent getting better. Nothing about
the model changed between these two rows. A fail-open closed, and the case that
had been pinned on it converged.

`jwt-auth` was the pin. Its prompt asks for the verified claims, returning them
trips ZTS401, and the recorded handler had been *hand-corrected* for several
rows because the model kept finding ways around the fence. The 2026-08-03
recording showed what it had found this time: it routed the claims through
`validateJson` and stated in its own commentary that this cleared the credential
label. It was right. A parsing export answered from its declared `validated` and
dropped everything its argument carried, so any label laundered through it -
`env("JWT_SECRET")` through `validateJson` and into the response proved
`no_secret_leakage` with zero diagnostics. `coerceJson` and `decodeJson` did the
same, in two different modules. Written up in
[validateJson strips the label it was asked to check](solutions/security-issues/validate-json-strips-the-label-it-was-asked-to-check.md).

With that closed, the case was re-recorded and reached a safe handler with no
hand correction for the first time: the model tried the validator, was refused,
and returned a confirmation envelope instead of the claims. Sixteen round-trips,
zero veto retries - it converged in simulation. Its pin flips to a pass, and that
one flip is the entire six points.

So the shape of this row is worth stating: **a tightening raised the rate**,
because the fence it moved was the one the pinned case was pinned on. Every other
case is unchanged. The policy hash is unchanged too - the fix adds no rule - so
the commit column is again what separates the two rows.

The other failure, `workflow-nested-dispatch-avoidance`, is untouched and still
the recording variance described above.

Worth noting where the finding came from. A frozen corpus is meant to detect
regressions, and this one instead surfaced a live fail-open, because recording it
put a capable model against the fence with an incentive to get around it and a
transcript of what it tried. That is not what the corpus was built for and is
arguably the strongest argument yet for growing it.

## The thirteenth row: the small-model row, and what it separates

Roadmap item 5, finally measurable. Same sixteen cases, same compiler, same
policy hash - only the model differs, and the corpus column says so by staying
`d6b571835aa5` across both.

| Model | First-draft | Median | Intent | Reached green |
|---|---|---|---|---|
| Sonnet 4.6 | 93% (15/16) | 4 | 100% (10/10) | 16/16 |
| Haiku 4.5 | 25% (4/16) | 3 | 90% (9/10) | 16/16 |

The headline gap is nearly four to one, and **reached-green is 16/16 for both**.
The tiers differ in first-draft aim, not in whether they converge. That is the
retry loop doing exactly what it is for, and it is the first time this page has
been able to say so with a number rather than an argument. It also sharpens what
the headline is: a rate that counted retries would have reported these two models
as identical.

Median round-trips reads *lower* for Haiku, 3 against 4, which is not the small
model being more efficient. Sonnet spends round-trips in `zts_expert_edit_simulate`
before submitting - sixteen of them on `jwt-auth` alone - and those dry runs are
why its first drafts land. Haiku submits sooner and takes a veto retry instead.
Two different costs, and this column only sees one of them.

Publishing this row needed two fixes first, both of which were quietly wrong in
the same way. The model column was printed from a compile-time constant while
`ZTTP_CODEGEN_MODEL` was advertised for exactly this purpose, so the run would
have published a Haiku measurement under Sonnet's name. And both ratchets - the
per-case pin and the intent assertion - would have fired on every tier
difference, reporting a smaller model as a compiler regression. A pin records
what one model did on one prompt, so it can only ratchet that model.

Main holds the Sonnet cassettes, not these. A corpus recorded off-headline
measures but does not gate, so leaving Haiku in place would quietly retire the
regression check that protects the headline. This row is reproducible from its
own commit, which is what the commit column is for.

## The fourteenth row: hole mode against whole-file

Roadmap item 3's measurement, which had been open since the turn mode shipped
because a cassette replay cannot produce a turn nobody recorded. Four cases now
pair with the whole-file case of the same task, so the task is held fixed and
only the turn's starting state varies.

| Arm | Median round-trips | n |
|---|---|---|
| whole-file | 5 | 16 |
| holes | **3** | 4 |

The prediction holds. Every hole case also passed first draft with zero veto
retries, which is the mechanism rather than the model's aim: a `fill_hole` edit
replaces the bytes of one `hole()` call, so it cannot produce the whole-file
rejection the veto exists to catch. That is item 3's claim in one line - the
emittable set per step narrows to one typed expression in a known context, and
set convergence stops being statistical.

The number is honest about what it includes. The hole arm is handed the frame -
imports, branch structure, and the narrow `Spec<...>` - so part of the saving is
work it was not asked to do. That is the mechanism, not a flaw, but it means
this compares hole mode end to end against writing from scratch, not the model's
aim against itself.

Getting there took two corrections worth recording, because both were mistakes
in the measurement rather than in the thing measured.

The seeds first went in without the `Spec<...>` their finished form needs, so
they checked with a ZTS500 already outstanding. The veto is differential: it asks
whether an edit introduces a *new* violation. A baseline that already carries the
violation hands that check a state it cannot see past, so filling a hole added
nothing and three cases recorded a first-draft pass on programs that did not
check clean. `fill_hole` can never touch a signature, so the agent could not have
cleared it either. Only the intent checks caught it. That is the weak-baseline
family one step along from
[an empty baseline made a file-destroying edit prove clean](solutions/logic-errors/empty-baseline-made-a-file-destroying-edit-prove-clean.md):
a differential check is only as strong as the state it differs against.

And the arm seeds one hole per case, which is its own finding rather than a
simplification. `zts_expert_fill_hole` proposes an edit and re-reads the file
from disk on every call, so two fills in one turn do not compose - the second
runs against the original bytes. The model diagnosed it mid-session, fell back to
a whole-file `apply_edit`, and ended with the program still holed. Written up in
[two hole fills in one turn do not compose](solutions/logic-errors/two-hole-fills-in-one-turn-do-not-compose.md).
Measuring multi-hole cases would fold that loop defect into the round-trip number
and report a bug as a cost.

That loop defect was closed on 2026-08-04 without changing this historical row.
The stand-in now runs a two-hole seed across two full offline turns: each turn
publishes a fresh compiler frame, fills one exact site, and applies it before the
next turn begins. The second frame therefore includes the first accepted fill,
and the gate ends with both expressions composed and no holes left.

## The fifteenth row: a compiler defect the corpus had already recorded

100% (20/20) over the same twenty cases the row above measured at 95%, at the
same policy hash. One case moved: `workflow-nested-dispatch-avoidance`, whose
first draft used to be rejected and now is not.

The compiler was wrong, not the draft. A function expression or arrow with no
signature of its own inherited the enclosing function's declared return type, so
a `return` inside a `run` callback was measured against the handler's contract
rather than against nothing. That is what the pinned draft tripped, and the
cassette says so in the model's own words on the next turn: "ZTS204 on line 88,
the `Response.json(...)` call inside `run()`". The turn it then spent hoisting
the result into a local binding was work the compiler invented.

Two things about how this was found are worth keeping, because neither is the
usual way a defect surfaces.

The corpus had recorded it a day earlier and nobody had read it that way. The
2026-08-03 re-record flipped this case to a failure, and the note written at the
time attributed it to the model drawing a different draft - which was true, and
stopped one step short. Pinning the worse outcome rather than re-rolling is what
kept the evidence in the repository; the re-roll that would have restored 95%
would also have deleted the only record of the bug.

And it surfaced from an experiment that was then reverted. Closing D1's
unresolved-name fail-open turned four working examples red, which is a
re-sequencing signal rather than a green light - but one of the failures was
this defect rather than a missing prerequisite. The fail-open had been hiding it
for every handler, because a handler's declared `Response` is an unresolved name
that accepts whatever it is compared against.

Coverage moved with the rate: [coverage.md](coverage.md) goes from five of the
compiler's seventy-two advertised rules tripped to seven.

## Reading the table

**Corpus** is the first twelve characters of a hash over the whole corpus:
every prompt, seed file, pinned outcome, and intent spec. Editing any case
changes it by construction, so two rows carrying different corpus versions are
measuring different things and must not be compared. A hand-maintained version
number would have rotted the first time somebody reworded a prompt.

**Policy** is the compiler's rule hash, the same one `policy-hash.txt` pins.
The fence moves: a new rule can lower the pass rate without the model getting
worse, and a precision fix can raise it without the model getting better. A row
without this column would attribute both to the model.

**Commit** is the build the row was produced from, and it is the column that
covers what the policy hash cannot. The hash is over the rule registry, so a
change to analysis semantics that adds no rule leaves it identical - the
determinism fix that stopped `uuid()` proving `deterministic` moved neither the
policy hash nor the hand-bumped compiler version. Two rows that differ only by
such a fix would otherwise look like the same build measured twice. A row marked
`-dirty` was published from uncommitted work and cannot be reproduced from the
commit alone.

The first two rows are retrofitted: the column was added after they were
published, and each names the commit the run's tree became - `e4a13aee` and
`847840a4`, the two commits git shows touching this file. Both runs were made
from a dirty tree that was committed immediately after, which is why the second
carries the marker. Rows from here on are stamped by the script rather than
reconstructed.

**Model** is which model produced the drafts, read out of the recorded
cassettes' own headers rather than declared. It used to be printed from
`request.default_model`, a compile-time constant, while `ZTTP_CODEGEN_MODEL` was
advertised for recording "a second row against another tier" - the two together
would publish a small-model measurement under the headline model's name, which
is the one thing this column exists to prevent. Reading it from the artefact
makes it measured. Two guards sit under it: the replay fails if the cassettes
disagree with each other, so a half-re-recorded corpus cannot average two
models into one row, and it fails if no cassette yields a model at all, so a
header-format change cannot quietly restore the constant.

The headline rows use the product default, so the number describes what a user
actually gets rather than a tier picked to flatter the result. A row from
another tier carries that tier in this column, and its per-case pins are
measured rather than ratcheted - `expect_first_draft_pass` records what one
model did, so it can only ratchet that model, and a smaller tier failing a case
the headline passes is a tier difference rather than a compiler regression.

**First-draft pass** is the headline. Retries are excluded on purpose: a rate
that counted them would measure the retry loop's persistence, not the agent's
aim, and every retry loop eventually passes a linter.

**Median round-trips** is what a typical prompt costs to reach green. The
median rather than the mean, so one case that never converges does not set the
number for the other ten.

**Intent pass** is the rate over cases that carry an intent spec, and the
denominator is those cases, not the whole corpus. The veto answers whether a
program is provable; it cannot answer whether the program does what was asked,
and a handler that returns `{ok: true}` for every prompt clears the veto every
time. Without this column the headline could not distinguish converging on
provable from converging on trivial.

## What is not measured yet

Five of the twenty cases - the durable and workflow ones - carry no intent
spec. Executing them needs the durable store and queue the runtime stands up,
and `zttp test` has no offline story for either: `saga()` fails with
`NativeFunctionError` before any assertion runs, and an io stub does not
intercept it. Those cases are veto-checked but not intent-checked, which is why
the intent column reads over 14 rather than over 20. Giving the test runner a
durable backend would close it.

`parallel-secret` is the sixth without one, for a different reason: its response
is a bare app name read from an env var, and asserting it would test the env
stub rather than the boundary containment the case is about.

One case is pinned as an accepted failure. It used to be `validate-body`, whose first draft wrote
`result.value as Item` against a subset with no `as` (ZTS042). That draft is
gone: the persona now tells the model to dry-run with `zts_expert_edit_simulate`
before `apply_edit`, so it sees ZTS042 in simulation and never submits the
assertion.

The pin moved to `jwt-auth`, and the gap it ranks is sharper. The prompt asks
the handler to return the verified claims, and returning them trips ZTS401 -
a flow-family credential-leakage warning, not a spec-discharge failure - which
the veto counts as a new violation introduced by the patch. The first draft
returns the claims the prompt asked for and is rejected for it; the model then
spends a round trip finding the sanctioned pattern and reaches green. So this
is a first-draft failure rather than a broken case, and what it ranks is the
tension between "return the claims" and `no_credential_leakage`.

It is a real corpus entry: it feeds the gap histogram that ranks which teaching
gap to close next, and the pinned outcome is part of the corpus version, so
quietly flipping it would change what the rate means.

## The intent column before and after the websocket-echo fix

Every row above through `9b7518ea` reports 100% (6/6) intent, and one of those
six passes was false. The `websocket-echo` check sent a GET with no headers and
asserted status 101.

The runtime owns the upgrade, not the handler: it upgrades only when the request
carries an RFC 6455 upgrade and the contract exports `onMessage`, and it writes
the 101 itself (`packages/runtime/src/server.zig:634-635`, `:1173`). A
header-less GET never upgrades, so it reaches the handler, and the only way a
handler returns 101 for it is by hardcoding that status - claiming a protocol
switch on every plain request. The check rewarded a bug rather than catching
one.

Nothing model-facing taught 101 either. It appears in `docs/reliability.md` and
an archived plan, both describing server internals, and the websocket example is
not among the four vendored under `skills/zts-expert/examples/`. The recorded
pass was luck, and a later re-record produced a handler that returned 200 and
failed the same check.

The prompt now states the non-upgrade behavior and the check asserts exactly
that, so the expectation is discoverable rather than assumed. Intent figures
from the first row carrying the new corpus version onward are therefore not
comparable to the rows above: those measured six cases of which one could not be
satisfied honestly.

## How a run works

The corpus lives in `packages/pi/src/expert_codegen_record.zig`. It has two
modes.

Recording is live and costs tokens. `ZTTP_CODEGEN_RECORD=1` with an API key
drives real expert turns through the real tool registry and tees each
round-trip to a per-case cassette, which is then committed.

Replay is deterministic and free. It reads the committed cassettes and re-runs
the recorded tool calls through the real veto, the real apply path, and the
real metrics. This is what CI runs and what the table above reports. The
replay is also a ratchet: it fails if a compiler change flips a recorded
first-draft outcome, so the rate cannot drift without somebody noticing.

The intent check shells out to the built `zttp test` rather than driving the
engine directly, so it exercises the same runtime a user does instead of a
second copy of it.

Every replay also prints a `[proof-coverage]` line, published as
[coverage.md](coverage.md), naming which of the compiler's advertised rules the
corpus trips. The two are deliberately separate pages under separate markers,
for the reason the next section gives.

## Why an offline run cannot land a row here

A row on this page is a measurement of a live model. There is a second, much
cheaper offline substitute in this repo - the deterministic stand-in, a scripted
responder that speaks the same wire shape - and every number it could produce
about drafting would be the playbook grading its own work. Its drafts and defect
seeds are authored by repo code to produce declared veto outcomes, so its
first-draft result is scripted; its round-trip count is the length of the
playbook; and its intent pass is definitional because the playbook writes the
intended program literally.

Four mechanisms keep such a number off this page, and none of them is a
convention somebody has to remember:

- The corpus recorder refuses any session that is not a live Anthropic key, so
  a stand-in session cannot become model-measurement input. A separate loopback
  smoke test exercises transport capture and replay without publishing a row.
- The replay hard-fails unless every case yields a model name from its own
  cassette header, so a row can never be published without cassettes behind it.
- `scripts/check-convergence-emitter.sh` holds `[codegen-convergence]` and
  `[proof-coverage]` to one producer and one publisher each, and forbids either
  publisher from reading the other's marker. A second emitter is what would let
  an offline summary be lifted into this table.
- The offline case type carries no `expect_first_draft_pass` field. That field
  records what one model did on one prompt, and giving a synthetic case somewhere
  to write it is how a hand-reasoned claim about model behavior gets pinned with
  no recording left to catch it - which is exactly what happened to
  `parallel-secret`.

## The pre-release protocol

Model-behavior numbers come only from recordings, so recording is a release
activity rather than a development one. Development runs against the stand-in;
see [coverage.md](coverage.md) for which paths that reaches.

A pre-release run is: re-record whatever cassettes the replay reports as stale,
then one `bash scripts/update-convergence.sh`, then
`bash scripts/update-coverage.sh` if the corpus or the registry moved. The stash
machinery in the recorder means a failed live turn restores the previous cassette
instead of leaving the case empty, so a partial run is recoverable.

No re-rolling. A surprising outcome is pinned and explained, not re-recorded
until it flatters - the `workflow-nested-dispatch-avoidance` row above is the
precedent, and it is the reason that case is pinned as an accepted failure rather
than quietly re-drawn.
