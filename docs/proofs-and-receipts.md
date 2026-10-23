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

The card comes from one analysis, shown in two places:

- `zttp dev` redraws it on every save, above the live-reload HUD, and
  `zttp test` prints it as the pre-test check.
- `zttp check` prints it once to the terminal for a one-shot run.

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
| `pure` | the handler calls no virtual modules and makes no call the compiler cannot resolve: it is a pure function of the request |
| `read_only` | every virtual-module call is read-classified and every call resolves to a known function: no state is mutated |
| `deterministic` | no value that can differ between runs, such as a clock read, a random draw, or stored data, reaches the response |
| `retry_safe` | the same condition as `read_only` |
| `idempotent` | deterministic and retry-safe: safe under at-least-once delivery |

**Security** - data-flow guarantees:

| Chip | Proven when |
|---|---|
| `injection_safe` | no unvalidated user input reaches a SQL or HTML sink |
| `no_secret_leakage` | no secret-labelled value reaches a response body or header, a log, or an egress call (URL, headers, or body) |
| `no_credential_leak` | no credential-labelled value reaches a response body or header, a log, or an egress call (URL, headers, or body) |
| `input_validated` | all user input passes a validation step before any egress call |

A write to the cache or SQL is not a sink for these chips. The read side
defends stored data instead. `cacheGet`, `sqlOne`, and `sqlMany` carry the
label that means "could not follow". A handler that returns stored data is
not proven.

A `[-]` pill is not an error. It means the compiler could not prove that
property for this handler, often because the handler legitimately does the
thing the property forbids. A handler that writes to a cache will not be
`read_only`, and that is correct.

A call through a value the compiler cannot resolve, such as
`const f = cacheSet; f(...)`, also leaves `pure`, `read_only`, and
`retry_safe` unproven. The compiler cannot see what
that call reaches, so it does not claim that the call is safe.

### Known Limits of the Security Chips

The security chips are not sound proofs in v0.22.3 and earlier. On
2026-10-18, the analyzer accepted a declared capsule for each handler shape
below, and the handler leaked when it ran under `zttp serve`, or the shape
uses the same mechanism as one that leaked. In v0.22.3 and earlier, do not
rely on a security chip for a handler that contains one of these shapes.
v0.24.0 closes every row.

| Shape | Chip that v0.22.3 proved falsely |
|---|---|
| A `let` that is reassigned in an `if` or `else` branch, where one branch holds raw input | `injection_safe` |
| A `let` that carries a value from one `for...of` iteration to the next | `injection_safe` |
| A `push`, `unshift`, or `splice` that is not a statement of its own, for example in an initializer or an `if` condition | `injection_safe` |
| A write through an alias of an array: another variable, an object field, or the array parameter of a callback | `injection_safe` |
| A write into a later element of the array that a `forEach`, `some`, `every`, `findIndex`, or `reduce` callback iterates | `injection_safe`, `no_secret_leakage` |
| A `reduce` callback that logs its accumulator, where the initial value is a secret | `no_secret_leakage` |
| A callback passed to `dictMapValues` or `dictFold` that logs a value from a dict that holds a secret | `no_secret_leakage` |
| A helper that is called in an `if` condition and logs a secret | `no_secret_leakage` |
| A request that is selected by a ternary, such as `cond ? req : req`, before its `authorization` header is read | `no_credential_leak` |
| A secret stored with `cacheSet` and read back with `cacheIncr` | `no_secret_leakage` |
| A callback that is selected by an expression, such as `forEach(cond ? f : g)` | `no_secret_leakage` |
| An `assert` whose message is a secret, in the handler or in a helper it calls: a failed assert returns the message, which becomes the response body | `no_secret_leakage` |
| `unescapeHtml(escapeHtml(req.url))` sent with `Response.html` | `injection_safe` |
| `Array.from(secret, f)`, where `f` logs each character | `no_secret_leakage` |
| A request taken back out of an array, for example `[req].pop()`, before its `authorization` header is read | `no_credential_leak` |
| `Response.json(req.headers)`, which sends every request header, `Authorization` included | `no_credential_leak` |
| A response status computed from a secret, such as `Response.json(data, { status: 200 + secret.length })` | `no_secret_leakage` |
| A request value rendered by `renderToString` as a tag name, as in `h(input, {})`, or as a child of `script` or `style`: the output is not escaped there | `injection_safe` |
| A failed `assert cond;` without a message: the runtime answered with the last value on the stack, such as a local that holds a secret | `no_secret_leakage` |
| `let b;` without an initializer in a block after another block that held a secret: `b` read the secret from the reused slot | `no_secret_leakage` |

The `cacheIncr`, response-status, and `renderToString` rows are fixed after
v0.22.3. The change that fixed `cacheIncr` also marks the results of
`cacheDelete`, `cacheStats`, `rateReset`, and `sqlExec` as unknown.
The two runtime rows are fixed after v0.22.3 in code generation: the analysis
was right about the program, and the runtime did not run it as written.
`packages/runtime/src/server_test.zig` holds their regression tests. Each
other row has a permanent fixture in `packages/tools/src/flow_false_proofs.zig`,
and v0.24.0 refuses each fixture or leaves its property unproven.

The structural chips (`pure`, `read_only`, `deterministic`, `retry_safe`,
`idempotent`) were not part of this check. Treat that as unmeasured, not as
proven.

### Reading A Failing Chip

When a save demotes a property that was proven on the previous save, the card
adds a `Why:` row naming the regression:

```
Why: -deterministic at src/handler.ts:14: Date.now()
```

It reads as: the `deterministic` property was lost (`-`), the construct that
broke it is at `src/handler.ts`, and that construct is `Date.now()`. Remove
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
compiler decided. Read the auto-rendered block in the terminal HUD to see:

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

## Counterexamples in the Live HUD

When `zttp dev --watch --prove` recompiles your handler and a proven
property regresses between the previous build and the new one, the proof
card surfaces a Counterexample block. The block is the compiler's way of
saying not just "you broke it" but "here is the construct that broke it,
here is what to do, and here is what fails."

Counterexamples land in the terminal HUD, which writes them into the proof
card frame that stderr already streams.

### What the block looks like

For the `deterministic` property today:

```
| Counterexample: -deterministic at src/handler.ts:14: Date.now()        |
|   why: remove Date.now() / Math.random() / performance.now().          |
```

Two sources fold into one frame: the per-property cause that the
verifier records on `HandlerContract.property_provenance`, and the
actionable hint from the spec discharge catalog. Cause and hint are always
present when a Counterexample renders.

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
witnessing path. The Counterexample frame does not show the witness. The
[witness corpus](#witness-corpus) below is the system of record for these.

### Where it lives in the code

- `packages/runtime/src/counterexample_pipeline.zig` builds the preview
  from the contract and the diff. Single-file orchestrator. Owns
  nothing; borrows from contract, label table, and suggestion catalog.
- `packages/proof-review/src/review.zig` defines
  `CounterexamplePreview` and the optional `counterexample` field on
  `ProofCard`.
- `packages/runtime/src/proof_card_tui.zig` renders the block under the
  Why row using the same full-width primitive. One or two rows tall,
  depending on whether a hint is present.
- `packages/runtime/src/live_reload.zig` calls `buildFromDelta` after the
  upgrade verifier produces a verdict, before the swap decision.

### Related reading

[Witness Corpus](#witness-corpus) below covers the corpus, the CLI for
pinning and pruning, and the persisted-on-disk layout.
[`verification.md`](verification.md) describes the property classifier
that produces the demotions in the first place.
[Sound Mode](typescript.md#sound-mode) covers the type-directed analyses that
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
so tools can present it without reversing the hash.

`<key>` is `counterexample.CounterexampleWitness.stableKey()`: a sha256
over `(property, origin_node_id, sink_node_id)`. AST node ids survive
line shifts caused by edits above the witnessing site, so the same
logical leak is not re-persisted as a new entry every time the file is
reformatted.

Witness files use `counterexample.writeJsonl` exactly. They use the
same request and virtual-module stub shape consumed by the runtime
witness-replay path.

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
falsifying inputs - their classification is structural. The analyzer
persists no entries for them. The former `synthesize` command that seeded
them is gone (`pre-rebase:packages/runtime/src/witnesses_cli.zig`).

### Surfaces

There is no CLI for the corpus. The former `witnesses` command (`list`, `pin`,
`unpin`, `prune`, `synthesize`) is gone (`pre-rebase:packages/runtime/src/witnesses_cli.zig`).
To pin an entry, create its `<key>.pinned` marker file by hand. Delete the
marker to unpin it.

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

### Versioning

The corpus is per-project state. Commit `.zttp/witnesses/` to your
repository so every contributor's build sees the same defending
evidence and CI fails on the same regressions. Pinned entries should
in particular be treated as part of the source of truth.

### See also

- [verification.md - Author-Declared Proof Discharge](verification.md#8-author-declared-proof-discharge)
- `packages/zts/src/witness_corpus.zig` - persistence library
- `packages/zts/src/counterexample.zig` - solver and JSONL wire format

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
| `breaking` | A route/capability was removed, a response on an existing path changed, or a critical proven property was lost. | Needs review. The gate fails the check. |

The repo verdict is the worst single handler: one `breaking` handler makes the
whole pull request `breaking`.

A law applies only to two calls whose arguments are all known. The compiler
records a dynamic argument, and a string literal that holds `|`, as the token
`?`. A call with a `?` argument is never collapsed with another call, because
two dynamic arguments may hold different values. Two writes to different
dynamic keys stay two writes.

The same rule applies when the gate compares two paths. A path whose module call
receives a `?` argument is not equal to its twin, because the contract cannot
tell two dynamic values apart. Changing `cacheSet("items", a, ...)` to
`cacheSet("items", b, ...)` is `breaking`. One case stays `equivalent`. The
gate parses the handler source on both sides, and the two syntax trees must be the
same after the gate ignores comments, whitespace, and positions. The handler
must also import only built-in `zttp:` modules. An identical program is then a
no-op, so each `?` is the same expression.

A handler that imports a local file does not qualify. The tree of the handler
is the same whatever the imported file holds, and the imported file may compute
the dynamic argument. Such a handler with a `?` argument is `breaking` against
itself. This is the cost of the rule.

### A lost proof

The gate also compares the proven properties of each handler. A property that
was proven at the base and is not proven at the head is a lost proof. A gained
proof never changes the verdict.

Only a critical lost proof makes the handler `breaking`. The critical set is
`retry_safe`, `injection_safe`, `state_isolated`, `no_secret_leakage`,
`no_credential_leakage`, `fault_covered`, `result_safe`, and `optional_safe`.
The live-reload upgrade verifier classifies the same eight as critical. Both
paths read `contract_diff.propertyLossSeverity`.
Every other lost proof, for example `pure`, `read_only`, or `stateless`, is
listed in the report and leaves the verdict as it was. A first log call or
cache read removes several of these properties, and failing the gate on them
would turn ordinary additive edits into failures.

The report lists each lost proof under **Lost proofs** with its severity, and
the summary table shows `N proofs lost` in the "Δ behavior" column. When a
critical proof is lost, the handler is `breaking` whatever its behavior diff
says.

The gate acts on a lost proof only when the handler still analyzes. A handler
without a `Proof<...>` capsule must prove the whole default profile, and a
handler that declares the lost property fails its own analysis at the head. In
both cases the gate stops with exit 2 and names the file.

### Local use

```bash
# Compare the working tree against the default base (origin/main, then main).
zttp proofs gate

# Pick the range explicitly, and emit the machine verdict for scripting.
zttp proofs gate --base origin/main --head HEAD --format json
```

Exit code: `0` safe (equivalent / additive), `1` breaking, `2` usage or git
error, or a changed `.ts` file the analyzer could not read. A file that
fails to analyze is never classified: calling it additive or skipping it would
hide a route the branch removed, so the gate names the file and stops. The
Markdown form is a ready-to-paste PR comment; the JSON form
(`zttp.proof-gate.v1`) carries the per-handler verdict, behavior delta,
surface delta, counterexamples, and `lostProperties`: an array of
`{"property", "severity"}` objects, empty when no proof was lost. The key is
an addition, so the schema name does not change.

Flags:

- `--base <ref>` before side. Default `origin/main`, falling back to `main`.
- `--head <ref>` after side. Default: the working tree.
- `--format md|json` default `md`.
- `--out <path>` write the report to a file instead of stdout.
- `--no-sign` accepted and ignored. The gate used to append signed
  `kind=equivalence` ledger rows; it writes none now. CI scripts that pass the
  flag keep working.

Files that are not handlers (a changed `.ts` with no routes and no
behavior paths, i.e. a config or library module) and files under `tests/`,
`fixtures/`, or matching `*.test.*`/`*.spec.*` are skipped, and listed as such
in the report. An added file is skipped for the same reason: it counts as
`additive` only after the analyzer proves it is a handler.

### GitHub Actions

The example workflow posts a sticky proof comment on every pull request and
fails the check on `breaking`. Copy
[`docs/examples/proof-gate.yml`](examples/proof-gate.yml) to
`.github/workflows/proof-gate.yml` in your project, and copy
`scripts/proof-gate.sh` too. The zttp repository does not run this workflow.

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
