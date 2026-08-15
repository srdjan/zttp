# Proofs and Receipts

This is the single reference for the proof surfaces: the card you read on
every save, the counterexample block that explains a regression, the witness
corpus that persists falsifying inputs, and the merge gate that carries the
verdict into a pull request.

- [Reading the Proof Card](#reading-the-proof-card)
- [Counterexamples in the Live HUD](#counterexamples-in-the-live-hud)
- [Witness Corpus](#witness-corpus)
- [Proof Gate](#proof-gate)

## Reading the Proof Card

Every time you save a handler, zttp re-runs its analyzers and prints a proof
card: a verdict, the proven surface, and - when something fails - the exact
construct that broke a proof. It is the screen you read on every save. This
guide explains how to read it.

The card comes from one analysis, shown in three places:

- `zttp dev` redraws it on every save, above the live-reload HUD, and
  `zttp test` prints it as the pre-test check.
- `zttp check` prints it once to the terminal for a one-shot run.
- `zttp studio` mirrors it in the browser workbench.

The in-browser playground on the zttp website runs the same analyzer
compiled to WebAssembly, so the card there matches the card you get locally.

### The Stages

The top of the card is a sequence of pass/fail gates. Each must pass before
the next runs:

- `Parse` - the handler is valid ZigTS syntax.
- `Types` - TypeScript annotations check (TypeScript handlers only).
- `Sound mode` - type-directed analysis across operators: no non-numeric
  arithmetic, no mixed-type `+`, no tautological comparisons.
- `Strict ZigTS` - the strict profile, on by default.

A `FAIL` here names the error count. The diagnostics print above the card
with a ZTS code, a source location, and a suggested fix. Fix the first one
and re-save; later stages often clear on their own.

### The Proven Surface

Below the stages, the card lists the properties the compiler proved. Each is
a pill: `[+]` proven, `[-]` not proven. They are grouped.

**Verification** - structural guarantees about control flow:

| Chip | Proven when |
|---|---|
| `exhaustive_returns` | every path returns a Response |
| `results_safe` | every `Result.ok` is guarded before the value is used |
| `optionals_safe` | every optional is narrowed before use |
| `state_isolated` | no module-scope variable is mutated in the handler body |
| `no_unreachable` | the handler has no dead code |

**Properties** - behavioral guarantees:

| Chip | Proven when |
|---|---|
| `pure` | the handler calls no virtual modules: it is a pure function of the request |
| `read_only` | every virtual-module call is read-classified: no state is mutated |
| `deterministic` | no `Date.now()`, `Math.random()`, or `performance.now()` on any path: every run is identical |
| `retry_safe` | read-only, or every write sits inside a durable step |
| `idempotent` | deterministic and retry-safe: safe under at-least-once delivery |

**Security** - data-flow guarantees:

| Chip | Proven when |
|---|---|
| `injection_safe` | no unvalidated user input reaches a SQL or HTML sink |
| `no_secret_leakage` | no secret-labelled value reaches a response, header, or egress call |
| `no_credential_leak` | no credential-labelled value reaches a response body or log |
| `input_validated` | all user input passes a validation step before any egress call |

A `[-]` pill is not an error. It means the compiler could not prove that
property for this handler, often because the handler legitimately does the
thing the property forbids. A handler that writes to a cache will not be
`read_only`, and that is correct.

### Reading A Failing Chip

When a save demotes a property that was proven on the previous save, the card
adds a `Why:` row naming the regression:

```
Why: -deterministic at src/handler.ts:14: Date.now()
```

It reads as: the `deterministic` property was lost (`-`), the construct that
broke it is at `src/handler.ts:14`, and that construct is `Date.now()`. Remove
or relocate it and the property returns on the next save.

### Counterexamples

For properties backed by path or flow analysis, a `[-]` comes with a
counterexample: the concrete input that breaks the proof. It takes one of two
shapes.

An **offending node** is a single source location: the line and column, a
snippet of the breaking construct, and a one-line fix. This is what you get
for `deterministic` and similar path properties.

A **flow chain** is an ordered walk of a tainted value from the call that
produced it to the sink that leaked it, plus the request method and URL that
drives that path. This is what you get for the security properties
(`no_secret_leakage`, `injection_safe`, and the rest).

The live HUD renders a full Counterexample block when a property regresses;
see [Counterexamples in the Live HUD](#counterexamples-in-the-live-hud) for that
block in detail.

### The Proof Trace

Each property carries a proof trace: not just whether it holds, but how the
compiler decided. Expand a chip in the playground or Studio, or read the
auto-rendered block in the terminal HUD, to see:

- A `summary` in one plain sentence: what was checked and what was found.
- The `kind` of proof. `structural` is a single-pass scan of the IR.
  `path-enumeration` is exhaustive symbolic enumeration of execution paths.
  `flow-trace` is a source-to-sink data-flow taint trace.
- The `counterexample`, when the property does not hold.
- The `resisted` evidence, when a data-flow property *does* hold. This is the
  green-proof mirror of the counterexample: a representative attack the prover
  considered (`attackInput`), the source -> guard -> sink `chain` that defeats
  it, and a one-line `conclusion`. For example, a held `injection_safe` shows
  the SQL/HTML payload it tried, the validator that cleared it (e.g.
  `escapeHtml()`), and the sink it safely reached. A contained secret shows
  that it was read but never reached a response, log, or egress sink. The
  evidence is derived from what the prover observed, never invented: a named
  guard appears only when the validator binding is recovered from the source.

The trace is the same data on every surface. `zttp check --json` emits it as
a `proof.proofTrace` object keyed by property name, so agents and CI read the
exact reasoning the HUD shows.

Durable workflow checks add a second receipt shape when you ask for the
contract:

```bash
zttp check examples/workflow/dsl-orchestrator.ts --json
zttp check examples/workflow/dsl-orchestrator.ts --contract
```

The JSON proof card exposes `proofTrace.durable_workflow_*`. The contract file
exposes `durable.workflow.proofLevel` and
`durable.workflow.properties.retrySafe` / `idempotent` / `faultCovered`.
Deploy and verify receipts expose the same result as `durableWorkflowProofLevel`,
`durableWorkflowRetrySafe`, `durableWorkflowIdempotent`, and
`durableWorkflowFaultCovered`.
Those workflow-specific fields can remain partial even when a handler's
narrower `Spec` passes; they gate durable replay claims, not generic handler
properties.
The proof tells you what the compiler proved; the durable directory tells you
what the runtime persisted.

### The Three Lenses

In the `zttp dev` HUD, press `Tab` to rotate the card's left pane through
three lenses:

- `Properties` - the default `[+]`/`[-]` pills.
- `Trade` - each proof paired with the substrate restriction that earned it:
  which rejected JavaScript feature bought which guarantee.
- `Handover` - a copy-pasteable proof certificate for an AI agent or a
  reviewer.

Studio mirrors the same three views with a tab bar. The rotation is described
in the [User Guide](user-guide.md); the restriction-to-proof map it draws on
is [Restrictions to Proofs](restrictions-to-proofs.md).

## Counterexamples in the Live HUD

When `zttp dev --watch --prove` recompiles your handler and a proven
property regresses between the previous build and the new one, the proof
card surfaces a Counterexample block. The block is the compiler's way of
saying not just "you broke it" but "here is the construct that broke it,
here is what to do, and here is what fails."

Counterexamples land in two places at once. The terminal HUD writes them
into the proof card frame stderr already streams. The studio at
`http://localhost:3000/_zttp/studio` carries the same payload as a
`counterexample` object in the SSE state, so a browser tab open beside
your editor reflects the same regression without a refresh.

### What the block looks like

For the `deterministic` property today:

```
| Counterexample: -deterministic at src/handler.ts:14: Date.now()        |
|   why: remove Date.now() / Math.random() / performance.now() or move   |
|        the call inside a `durable.step`.                               |
|   [r] replay live   [s] pin as regression test   [a] ask expert to fix |
```

Three sources fold into one frame: the per-property cause that the
verifier records on `HandlerContract.property_provenance`, the
actionable hint from the spec discharge catalog, and the keystroke hints
that name the three follow-on actions. Cause and hint are always present
when a Counterexample renders. The keystrokes are advertised even before
their handlers ship: the agent integration and the live replay
short-cuts are wired in the same release as the frame itself.

### When the block does not render

The Counterexample block stays empty in three cases that read like a no
news / good news boundary: a save that broke nothing leaves `delta`
without demoted properties; a save that demoted a property without a captured
cause renders a Why row but no block; a fresh `seedInitialProof` pass has no
baseline to diff against, so demotions require another frame. The block is
opt-in by silence; nothing is forced
on a clean session.

### Cause-only versus flow-driven properties

Two classes of property feed Counterexamples differently:

The cause-only set (`deterministic`, `read_only`, `retry_safe`,
`idempotent`, `state_isolated`, `fault_covered`) is structural. The
verifier classifies the property from the IR and, when it demotes the
property, records a `PropertyCause` with the file line, column, and
snippet that produced the demotion. The Counterexample frame pairs that
cause with the hint catalog in `spec_discharge.suggestionFor` and
renders. No witness, no replay, no request: the snippet is the
counterexample.

The flow-driven set (`no_secret_leakage`, `no_credential_leakage`,
`input_validated`, `pii_contained`, `injection_safe`) has executable
witnesses. The witness solver in `zts.counterexample.solve` turns a
flow violation's constraint chain into a concrete `Request` plus the
virtual-module stub sequence needed to drive the handler down the
witnessing path. When the live-reload pipeline produces a witness for a
demoted flow property, the frame extends with the request line and two
replay rows showing the previous build's response and the current
build's response. The witness corpus described in
The [witness corpus](#witness-corpus) below is the system of record for these.

v1 ships the cause-only path end to end. The flow-driven extension
reuses the `CounterexamplePreview.failing_request`,
`previous_response`, and `current_response` slots that are already on
the data type; the live-reload integration with `replay_runner` lands as
a focused follow-on. The shape does not change.

### Acting on the block

The three keystrokes hold for both classes:

`[r]` replays the failing request live against the running server. For
cause-only Counterexamples this is a no-op today because the cause is a
construct rather than a runnable request. For flow-driven Counterexamples
this hits the dev server with the synthesised request and the replay
stub responses, so a developer can see the regression reproduce in the
same audit ring the rest of the HUD streams.

`[s]` pins the underlying witness into the corpus as a regression test.
The pinned witness re-fires on every subsequent analysis pass, so a fix
that re-introduces the same construct demotes the property again with
the original counterexample call-out. Pinning is the moment a one-time
catch becomes durable evidence.

`[a]` hands the Counterexample to the `zttp expert` agent through the
`pi_counterexample_current` tool. The agent's `proof_enrichment` and
`property_goals` channels consume it, so its first response is a fix
proposal grounded in the exact construct the verifier flagged, not a
clarifying question.

### Where it lives in the code

- `packages/runtime/src/counterexample_pipeline.zig` builds the preview
  from the contract and the diff. Single-file orchestrator. Owns
  nothing; borrows from contract, label table, and suggestion catalog.
- `packages/proof-review/src/review.zig` defines
  `CounterexamplePreview` and the optional `counterexample` field on
  `ProofCard`. The data type carries the flow-driven extension slots.
- `packages/runtime/src/proof_card_tui.zig` renders the block under the
  Why row using the same full-width primitive. Three to five rows tall
  depending on whether a witness is present.
- `packages/runtime/src/live_reload.zig` calls `buildFromDelta` after the
  upgrade verifier produces a verdict, before the swap decision. The
  studio receives the preview through the existing `updateFacts` channel.
- `packages/runtime/src/studio.zig` serialises the preview into the
  SSE `counterexample` field of the state JSON so the browser surface
  stays in lockstep with the terminal frame.

### Related reading

[Witness Corpus](#witness-corpus) below covers the corpus, the CLI for
pinning and pruning, and the persisted-on-disk layout that the `[s]`
keystroke ultimately writes into.
[`verification.md`](verification.md) describes the property classifier
that produces the demotions in the first place.
[`sound-mode.md`](sound-mode.md) covers the type-directed analyses that
sit upstream of the flow-driven property set.

## Witness Corpus

Every counterexample the compiler discovers when proving a handler is a
concrete falsifying input: a `Request` plus the virtual-module stub
responses needed to drive the handler down the witnessing path. The
witness corpus persists those inputs to disk so they accumulate across
builds, deploys, live reloads, and developer machines.

The corpus is the project's accumulated evidence. It is not throwaway
state.

### Layout

All paths are relative to the project root (the cwd of the analyzer
invocation):

```
.zttp/witnesses/<short_hash>/handler.path        # text, original handler path
.zttp/witnesses/<short_hash>/index.jsonl         # append-only event log
.zttp/witnesses/<short_hash>/<key>.witness.jsonl # one file per witness
.zttp/witnesses/<short_hash>/<key>.pinned        # marker file (presence = pinned)
```

`<short_hash>` is the first sixteen hex characters of
`sha256(handler_path)`. The original path is recorded in `handler.path`
so the listing surfaces (`zttp witnesses list`, `pi_witnesses`) can
present it without reversing the hash.

`<key>` is `counterexample.CounterexampleWitness.stableKey()`: a sha256
over `(property, origin_node_id, sink_node_id)`. AST node ids survive
line shifts caused by edits above the witnessing site, so the same
logical leak is not re-persisted as a new entry every time the file is
reformatted.

Witness files use `counterexample.writeJsonl` exactly. They use the
same request and virtual-module stub shape consumed by the runtime
witness-replay path. `zttp mock` is for `.test.jsonl` fixtures and
does not accept `--replay`.

### How the corpus grows

Witnesses are materialised by the agent-facing tools that already
synthesise concrete inputs from a flow_checker diagnostic's constraint
chain:

- `pi_repair_plan` materialises a witness for every flow violation that
  matches a requested goal, then persists each one before returning.
- `pi_goal_check` materialises a witness for every flow violation that
  matches an active goal and persists it during the same pass.

A handler that has never been touched by either tool has no corpus.
Once an agent runs them, the corpus begins populating immediately and
stays in sync with the proof state.

Build-time auto-population is wired into `precompile.runCheckOnly`, so
every `zts check` and `zig build -Dhandler=...` populates the corpus
from any flow-property witness the analyzer produces. The `proof.witnesses`
block in the JSON envelope reflects the corpus state after that
population pass.

Cause-only specs (`deterministic`, `read_only`, `retry_safe`,
`idempotent`, `state_isolated`, `fault_covered`) do not have flow-style
falsifying inputs - their classification is structural. Seed those
entries explicitly with `zttp witnesses synthesize <handler> <spec>`.

### Surfaces

#### CLI: `zttp witnesses`

```text
zttp witnesses list [<handler>]
zttp witnesses pin <handler> <key|prefix>
zttp witnesses unpin <handler> <key|prefix>
zttp witnesses prune <handler> [--older-than <seconds>]
zttp witnesses synthesize <handler> <spec>
```

`list` with no handler argument summarises every corpus directory found
under `.zttp/witnesses/`. With a handler, it prints one line per
witness with key prefix, property, pinned status, and the
natural-language summary the analyzer produced.

`pin` and `unpin` accept any unique key prefix. Pinned witnesses are
protected from `prune`.

`prune` removes unpinned witnesses whose first-seen timestamp is older
than the cutoff. The default is 90 days.

`synthesize` seeds a structural witness for one of the cause-only specs.
Repeat invocations on the same `(handler, spec)` pair are idempotent;
the underlying key is `sha256("structural" | spec | handler_path)`. The
stored summary is the per-property `Try:` suggestion from
`spec_discharge.suggestionFor`. Flow-rich specs are rejected because the
analyzer-driven path already covers them.

#### JSON envelope

`zts check --json` includes a `proof.witnesses` block:

```json
{
  "proof": {
    "...": "...",
    "witnesses": {
      "total": 3,
      "by_property": {
        "injection_safe": 1,
        "no_secret_leakage": 2
      }
    }
  }
}
```

The block is read directly from `.zttp/witnesses/<short_hash>/` for
the handler under check. A missing or empty corpus reports
`{"total":0,"by_property":{}}`.

#### Studio: `/_zttp/studio/witness/<key>.json`

While the studio is running (`zttp studio <handler.ts>` or
`zttp serve --studio --watch --prove`), each row in the Witnesses
tile is clickable. Clicking fetches the on-disk witness file and
renders the falsifying request, IO stubs, summary, source location,
and pinned status inline. The endpoint is read-only:

```text
GET /_zttp/studio/witness/<key>.json
=> {"key":"<hex>", "pinned":<bool>, "events":[<witness>, <request>, <io>...]}
```

`<key>` must be 1..64 hex chars (the same shape `witness_corpus.persist`
produces). The events array is the on-disk JSONL re-emitted as a JSON
array; each entry is an unmodified record from
`counterexample.writeJsonl`. Studio caches nothing. It re-reads the
file on every click, so a corpus refresh on disk is visible
immediately. A fingerprint guard on the detail panel keeps an
already-expanded witness expanded across the 750ms poll cycle when the
underlying `(key, property, pinned)` set is unchanged.

#### Agent tool: `pi_witnesses`

Single op: given a handler path, return the corpus listing.

```json
{
  "ok": true,
  "handler_path": "examples/system/users.ts",
  "total": 3,
  "by_property": { "injection_safe": 1, "no_secret_leakage": 2 },
  "entries": [
    {
      "key": "abcdef0123456789...",
      "property": "no_secret_leakage",
      "summary": "SECRET_KEY flows into Response body",
      "pinned": false,
      "first_seen_unix_s": 1745539200
    }
  ]
}
```

Use `pi_witnesses` before drafting a repair against a `Spec` failure.
`Spec`s with zero witnesses are unprobed: the proof currently relies on
the classifier alone, and a regression there would silently slip past
the corpus. `Spec`s with pinned witnesses are load-bearing; a repair
that removes them weakens coverage.

The slash command `/witnesses <path>` invokes the same tool from the
expert REPL.

### Versioning

The corpus is per-project state. Commit `.zttp/witnesses/` to your
repository so every contributor's build sees the same defending
evidence and CI fails on the same regressions. Pinned entries should
in particular be treated as part of the source of truth.

### See also

- [verification.md - Author-Declared Spec Discharge](verification.md#8-author-declared-spec-discharge)
- `packages/zts/src/witness_corpus.zig` - persistence library
- `packages/zts/src/counterexample.zig` - solver and JSONL wire format
- `packages/runtime/src/witnesses_cli.zig` - `zttp witnesses` subcommand
- `packages/pi/src/tools/pi_witnesses.zig` - agent tool

## Proof Gate

`zttp proofs gate` carries the proof to where review happens: the pull
request. The [compile-time proof flow](user-guide.md#compile-time-proofs)
shows the proof story for one scripted edit; the gate runs the same analysis
across every handler a real branch changed and turns the result into a
merge-decision signal.

### The verdict is the answer to "is this safe to merge?"

For each changed handler the gate compiles the base and head versions and runs
the same `contract_diff` the expert loop and `zttp prove-behavior` use, then
aggregates one repo-level verdict:

| Verdict | Meaning | Merge signal |
|---|---|---|
| `equivalent` | Surfaces and every response path are identical. | Mechanically safe. A proven no-op. |
| `equivalent_modulo_laws` | Identical after the algebraic laws declared on virtual modules. | Safe. The report lists which laws the proof used. |
| `additive` | New routes/capabilities, nothing removed or changed. | Backward-compatible. |
| `breaking` | A route/capability was removed, or a response on an existing path changed. | Needs review. The gate fails the check. |

The repo verdict is the worst single handler: one `breaking` handler makes the
whole pull request `breaking`.

### Local use

```bash
# Compare the working tree against the default base (origin/main, then main).
zttp proofs gate

# Pick the range explicitly, and emit the machine verdict for scripting.
zttp proofs gate --base origin/main --head HEAD --format json
```

Exit code: `0` safe (equivalent / additive), `1` breaking, `2` usage or git
error. The Markdown form is a ready-to-paste PR comment; the JSON form
(`zttp.proof-gate.v1`) carries the per-handler verdict, behavior delta,
surface delta, and counterexamples.

Flags:

- `--base <ref>` before side. Default `origin/main`, falling back to `main`.
- `--head <ref>` after side. Default: the working tree.
- `--format md|json` default `md`.
- `--out <path>` write the report to a file instead of stdout.
- `--no-sign` skip the signed `kind=equivalence` ledger rows. Run locally with
  signing on (the default) to append a signed receipt to `.zttp/proofs.jsonl`;
  CI passes `--no-sign` because runners hold no persistent attest identity.

Files that are not handlers (a changed `.ts`/`.tsx` with no routes and no
behavior paths, i.e. a config or library module) and files under `tests/`,
`fixtures/`, or matching `*.test.*`/`*.spec.*` are skipped, and listed as such
in the report.

### GitHub Actions

The shipped workflow posts a sticky proof comment on every pull request and
fails the check on `breaking`. Copy `.github/workflows/proof-gate.yml` and
`scripts/proof-gate.sh` into your project.

```yaml
on: pull_request
permissions:
  contents: read
  pull-requests: write
# checkout with fetch-depth: 0 so `git show <base>:<path>` can read the
# before side, build zttp, run scripts/proof-gate.sh, post the comment,
# then exit 1 when the verdict is `breaking`.
```

To merge a deliberate breaking change, add the `proof-override` label to the
pull request; the gate still posts the comment but does not fail the check.

### Relationship to other proof surfaces

- `zttp dev --prove` and the terminal HUD show the verdict to the author on
  save. The gate shows it to a reviewer at merge time.
- `zttp proofs show` / `diff` re-render a single ledger entry. The gate
  aggregates across a git range.
- `zttp prove-behavior <before.ts> <after.ts>` is the one-shot, two-file form
  of the same per-handler verdict the gate computes for each changed file.
