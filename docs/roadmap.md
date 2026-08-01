# Roadmap

The one forward-looking document in the maintained docs. It records the current
support boundary, what the implementation does not cover, and the work that is
planned but not built. Shipped changes live in `../CHANGELOG.md`; current user
behavior lives in [User Guide](user-guide.md).

## Supported Now

- macOS and Linux on x86_64 and aarch64.
- Zig `0.16.0` as declared by `build.zig.zon`.
- Threaded HTTP/1.1 server with per-request runtime isolation and decoded
  `Content-Length` or `Transfer-Encoding: chunked` request bodies.
- Restricted JS/TS/TSX handler execution through `zts`.
- WebSocket gateway support with parsed peer close-code metadata.
- The five core `zttp` commands: `init`, `dev`, `test`, `expert`, `deploy`.
- Local self-contained deploy artifacts with default-on attestation.
- Compile-time checks for response paths, Result and optional handling,
  state isolation, active specs, flow properties, contracts, and module policy.
- Built-in `zttp:*` virtual modules listed in
  [Virtual Modules](virtual-modules/README.md).
- Optional Studio and edge runtime builds via `-Dstudio` and `-Dedge`.

## Current Limitations

- Hosted cloud deploy is not part of the current CLI surface. `deploy` builds a
  local binary, `deploy --cloud` parses and rejects with a "not available in
  this beta" message, and the account verbs (`login`, `logout`, `review`,
  `grants`, `revoke-grant`) are not dispatched at all.
- The runtime uses the threaded HTTP server path. The evented `std.Io`
  networking path is not a supported request backend.
- Handlers receive raw `multipart/form-data` bodies from the HTTP server. Use
  `decodeFormMultipart` from `zttp:decode` or handler-owned parsing when a
  handler accepts multipart input.
- There is no scrape-able `/metrics` endpoint. `/_health` and `/_readiness`
  return bare status codes.
- Windows is not supported.

## Runtime And Product Work

- Close the remaining runtime lifecycle verification gaps before hosted deploy
  claims: broader accept-path coverage for deadlines, graceful shutdown, probes,
  and panic isolation; hosted request-timeout policy; and shutdown
  thread-safety semantics.
- Finish the engine-to-runtime boundary refactor by routing runtime calls
  through a strict facade and exposing stable runtime-facing engine types. The
  file split landed (`handler_instance.zig` owns `HandlerInstance`;
  `zruntime_tests.zig` is the test root), but six import cycles remain between
  the instance and the sibling files its methods moved into.
- Keep near-term module work limited to table-stakes gaps: fetch resilience,
  capability surfacing, and build-feature diagnostics. Cloud-adapter modules
  stay in a separate evaluated track.
- Keep `zttp help --all` and `packages/zts/src/builtin_modules.zig` as the
  sources of truth for CLI and module docs. `packages/modules/module-specs/` is
  not one of them: it is generated from the typed Zig module bindings by
  `zttp module-spec-render`, and `--check` gates it in `scripts/verify.sh`. Edit
  the binding, then regenerate.
- Add server-level rate limiting only if the standalone server becomes a
  first-class unproxied deployment target. Application limits are handled with
  `zttp:ratelimit`.
- Promote hosted deploy only after the control-plane path has CI smoke coverage
  and user-facing commands appear in default docs.

## Agent-Compiler Agenda

[STRATEGY.md](../STRATEGY.md) states the thesis: the set of programs the agent can
write should converge on the set of programs the compiler can prove. This section is
the work that closes the gap, ranked by how much it strengthens that claim per unit of
cost rather than by difficulty. Every count below names the file that owns it, so a
reader recounts instead of trusting a number that rots here.

The ranking follows three legs. The provable set must be true, or convergence to it has
no value. The gap must be measured, or the claim is only prose. The mechanisms that
close the gap should move from rejection toward construction.

### 1. Close the fail-open soundness holes (done)

The three holes [D2](plans/2026-07-30-015-d2-effects-purity-design.md) named are closed.
A non-literal `Effects<T, R>` ceiling reports ZTS511 instead of extracting zero names and
reading as no annotation. A `zttp-ext:` module contributes the capabilities its manifest
declares, and a module neither registry resolves fails closed with the full set. A call
through a value the compiler cannot resolve sets `EffectRow.lower_bound`, and the ceiling
check, the handler budget, and every capsule property refuse a row so marked (ZTS512).

`zig build test-proof-swallow` is the standing check. It scans the eleven analysis files
between the parsed IR and the reported verdict and fails on any discarded error not
listed in `scripts/proof-swallow.allow` with a reason it cannot weaken a verdict, and
also on a listed row nothing matches. The count of unreviewed swallows is asserted, not
claimed in a comment. Its first run found ten more paths of the same shape, all closed
in the same series: `type_env` dropping signatures on allocation failure with no record,
`reachesRecursion` returning false against the promise in its own doc comment,
`describeWorkflowCall` dropping a node out of the durable graph, and
`appendQueryParamsFromSchema` recording a required query parameter as optional.

Why it came first: every fail-open moves unproven programs into the reported provable
set, inflating the convergence number without any convergence. The history argues the
same way: a taint fail-open once survived fourteen review passes, so this class of defect
is proven to evade review here, which is why the standing check scans rather than trusts.

### 2. Publish an honest convergence number (done)

[docs/convergence.md](convergence.md) carries the table: corpus version, model, policy
hash, first-draft pass, median round-trips, and intent-pass rate, regenerated by
`scripts/update-convergence.sh` and versioned in git rather than left in a gitignored
`.zttp/` file. The first row reads 90% first-draft pass over 11 cases at a median of 5
round-trips, with 6 of the 11 intent-checked and all 6 passing.

The corpus version is a hash over every prompt, seed file, pinned outcome, and intent
spec, so editing a case changes it by construction and two rows measuring different
corpora cannot be compared by accident. The policy hash rides alongside because the
fence moves: a new rule lowers the rate without the model changing.

The intent check runs each case's `zttp test` spec against whatever the turn actually
wrote, so a case passes only when it clears the fence and does the task. It shells out
to the built binary rather than driving the engine directly, which keeps the measurement
on the same runtime a user gets. The five durable and workflow cases carry no spec yet -
`zttp test` has no offline durable backend - and they report as unchecked rather than as
passes, so the intent column reads over 6 rather than a flattering 11.

### 2a. A clock or random read does not clear `deterministic` (small, blocked)

`uuid()` reports `deterministic ....... PROVEN`, and a handler can then declare that
property in a `Spec<...>` and have it discharged. It is a false proof: the function
returns a different value on every call.

`isNonDeterministic` (`effect_inference.zig`) clears the flag for `Date.now` and
`Math.random` member calls only. A module call that reaches the `.clock` or `.random`
capability leaves it set, so every `zttp:id` mint and every clock-reading export escapes
the rule that the equivalent global call obeys.

The fix is a few lines: after resolving a call's capabilities, clear `deterministic` when
the newly added set contains `.clock` or `.random`, gated on `durable_callback_depth == 0`
for the same reason the member-call rule is - inside a `step()` the read is recorded and
replayed. Per-export capability rows (item 7) are what make it precise: `parseBearer`
stays deterministic while `jwtVerify`, which reads the clock for `exp`, does not.

Blocked on a corpus re-record, not on design. Landing it flips the `jwt-auth` case: its
recorded handler declares no `Spec<...>`, so the default profile now demands a
`deterministic` it no longer holds, the turn retries, and the committed cassette runs out
of steps mid-turn. Re-record that one case with
`ZTTP_CODEGEN_RECORD=1 ZTTP_CODEGEN_ONLY=jwt-auth`, then land the fix and refresh
[convergence.md](convergence.md) - the rate is expected to move, which is what the policy
hash column on that table exists to explain.

### 3. Typed holes (medium, decomposable)

Two of three slices have landed. `hole()` exists as a builtin typed `never`, so a
handler with a hole on one branch checks clean with both paths enumerated and its
properties proven; reaching one answers 501 rather than the 500 a real fault produces,
in all three response paths. `zts check --json` publishes a `holes` array carrying each
site's function, line, column, the value type the expression must produce (with the
phantom capsule marker erased), and the capability budget the handler declared but has
not yet spent.

Two pieces of the JSON are still missing: the in-scope bindings with their types, which
needs scope reconstruction the IR does not retain after parse, and the undischarged
obligations, which exist in `spec_diagnostics` but are not yet projected per hole. The
remaining slice is the agent's fill-one-hole turn mode.

Why: this is the only item that changes the convergence mechanism rather than measuring
or enforcing it. Today the loop is subtractive - the agent emits from its full
distribution and the veto rejects. With holes the compiler constructs the frame, and the
emittable set per step narrows to one typed expression in a known context. Set
convergence stops being statistical and becomes structural. Ship the capability budget
marked in the JSON as an over-approximation until item 7 lands.

Observable: round-trips to first green fall for hole-mode sessions against whole-file
sessions on the same model. The session ledger can already express that comparison, and
[convergence.md](convergence.md) is where the comparison gets published. Not claimable
until the turn mode ships - the builtin and the JSON describe the gap, but nothing yet
changes how the agent spends a turn.

### 4. Widen the mechanical repair lane (small to medium)

Lower more `RepairIntent` variants to real source edits, starting with the span-local
rewrites. Implement validator M2, parse identity, from
[D3](plans/2026-07-30-016-d3-canonical-form-wire-design.md); it does not need the
canonical formatter. Grade each lowering intent with it and flip `repair_available` on
the wire for graded intents only. Add `input_validated` and `pii_contained` to
`supported_goals` in `packages/pi/src/property_goals.zig`, widening the autoloop from
three driveable properties to five; the counterexample solver already models both.

Why: every intent that lowers and validates pulls a rejected program into the provable
set with zero model tokens. That is convergence driven from the compiler side, and the
`compiler_authored_apply` counter already measures it. 18 variants are declared in
`packages/zts/src/repair_intent.zig`; 8 now reach a source edit through `applyIntent` in
`packages/pi/src/tools/repair_apply.zig`, and the autoloop drives 5 properties rather
than 3.

`drop_redundant_bool_compare` lowered first because its rewrite already existed, tested
and deliberately conservative, in the normalizer - it was simply never wired into
`RepairKind`. `Intent` carries no column, so the apply path locates the comparison by
scanning the line and refuses when two candidates are present rather than guessing which
one the diagnostic meant.

`input_validated` and `pii_contained` joined `supported_goals`: the solver models both,
with an attack input and witness cases each, so refusing to drive them was capability
left on the floor. A test now asserts the goal list and the solver's `PropertyTag` set
cannot drift apart in either direction.

The validator question is settled and the registry exists:
`packages/zts/src/repair_validator.zig`, published as `meta.validators`.

M4, declared law with a carried precondition, is the family for the canonicalization
rewrites. The other four are ruled out by evidence rather than preference. M2 is parse
identity and discharges none of them - every repair changes the IR tree, which is the
point; even `let` to `const` fails it, since the declaration node distinguishes the two
kinds. M1 needs the canonical formatter and M3 needs the semantic kernel, and neither
exists; `semantics.zig` is explicitly a partial slice with statements structural-only.
M5 is advisory-only by construction and can never justify the flag. M4's machinery is the
one that already runs: `semantics_smt.encodeEquivalence` under z3, live in
`scripts/verify.sh`. Its published shape - a law plus preconditions carried on the row -
is what these rewrites need, with the checker as the precondition source: the rewrite is
sound exactly where the diagnostic that requested it fired.

The second half of the decision is a classification, not a gap. A behaviour-changing
repair claims no equivalence and never will: `add_trailing_return` exists to change what
the program does on a path that previously fell off the end. Those rows are `.none` and
ship advisory-only, which D3 blesses directly.

`repair_available` now answers from the registry instead of a constant. Every row is
`planned`, so every answer is still false - but false because the registry says so, and
one row reaching `implemented` is what changes it. A `status` distinct from `method` is
what keeps that honest: naming the right validator is not the same as having one.

Observable: compiler-authored apply share rises on the item-2 corpus, and
`repair_available: true` appears on the wire for a named, tested subset. The first half
is now measurable against [convergence.md](convergence.md); the second waits on the
validator decision above.

### 5. The small-local-model run (small, once item 2 exists)

Run the item-2 corpus in live mode against a small local model through the existing
OpenAI-compatible provider path, and report first-draft pass, round-trips, and
intent-pass against the frontier-model baseline. If the results are close, emit a
decoding grammar from the restriction registry and test grammar-constrained sampling.

Why: the narrow grammar is the stated reason a small model might be enough, and that is
currently an argument rather than a result. If a small model reaches the same green
state with more retries, the fence carries the intelligence rather than the model, which
is the thesis demonstrated rather than asserted. If it fails, that is also information:
it makes item 3 required rather than optional, because per-hole fill is the known way to
shrink a task to small-model size.

Observable: one published row per model in the item-2 table, dated.

### 6. Idempotence gate and the repair-span fix (small)

Two of the three parts were already done and this item's premise was stale.
Double-normalize byte-idempotence has run as `scripts/check-normalize-idempotent.sh`
inside `scripts/verify.sh` for some time (54 files, 1 skipped as not fully canonical),
and `original_line` reaches the JSON boundary at `agent_protocol.zig:1201`, so a client
can already re-validate a repair span. D3's "idempotence does not exist today" no longer
holds.

Confluence was the part that genuinely did not exist, and the first run of the harness
found a non-joining pair. `let ready = true; if (ready === true)` had two canonical
forms: rewriting the comparison first reached `if (ready)`, rewriting the binding first
reached `const ready = true; if (ready === true)` and stopped. Both passed
`normalize --check`, so the second was a second canonical form rather than a stuck one.
The normalize loop applies every enabled row per pass and lands on the first, which is
why it went unnoticed; a client applying repairs one intent at a time lands on the
second. Canonical form is set collapse, so a surface program with two normal forms is
the property failing rather than a cosmetic wart.

It is closed. The cause was one line: the rule's soundness guard compared the inferred
type against `idx_boolean` by identity, and a `const` binding keeps its literal type
(`t_literal_bool`) where a `let` widens to `boolean` - `widenLiteral` exists precisely
to stop let bindings locking to a value. `checkRedundantBoolCompare` now widens before
comparing, which does not loosen the guard: `t_literal_bool` widens only to
`idx_boolean`, and a value of literal type `true` is a boolean, so `x === true` is still
exactly `x`. The policy hash did not move - the registry text is unchanged and only the
firing condition widened.

The harness restricts the loop to one row kind at a time, which is what makes a critical
pair observable: within a single pass `applyRefactors` walks lines and rejects same-line
pairs, so permuting the refactor slice cannot change the output and would prove nothing.
`known_non_joining` is empty, which is the state D3 requires, and the harness fails both
on an unlisted non-joining pair and on a listed pair that starts joining.

Why: canonical form is set collapse. Many surface programs mapping to one normal program
shrinks the emittable set directly. The full canonical formatter is the largest single
cost in the language program and should not be entered blind; this is the cheap
measurement of how far the current normalizer sits from canonical. The span fix is a
precondition for any external client to trust a repair, which item 4 needs on the wire.

Observable: a counted list of non-confluent rule pairs, tracked toward zero, and a JSON
repair a test client re-validates byte for byte. The count is 0, and the harness fails on
any pair not on the list.

### 7. Per-export capability rows (medium)

Move capability declaration from a per-module union to per-export rows, so `escapeHtml`
carries its own row rather than the whole of `zttp:text`. Keep the module row as the
ceiling for unlisted exports during migration. D2 states the consequence plainly: the
current union "makes every ceiling wrong on its face".

Why: over-approximation on the provable side rejects true programs, which pushes the
agent into workarounds and widens the emitted set away from the natural solution.
Precision here grows the provable set toward the set of correct programs, which is the
other half of convergence. It also makes item 3's capability budget truthful. It depended
on item 1, which is done, so the surface underneath is no longer fail-open.

The mechanism has landed. `FunctionBinding.required_capabilities` is optional: null
inherits the module set, so an untightened binding behaves exactly as before, and an
empty slice is the separate claim that an export reaches nothing. `validateBindings`
enforces subset-of-module on both binding boundaries, so a tightening can narrow
authority and never widen it, and `module-spec-render` publishes the per-export set.

Five of the 24 modules are tightened, each verified against its implementation rather
than its comment: `zttp:auth` (parseBearer and timingSafeEqual reach neither crypto nor
clock), `zttp:id` (only ulid reads the clock), `zttp:websocket` (traced through dispatch
to the runtime callbacks and the connection pool: only send and close write to the
socket, only serializeAttachment can touch disk), `zttp:ratelimit` (rateReset removes a
map entry and reads no clock), and `zttp:sql` (`sql()` registers a statement in a map and
opens no database). The rest still inherit; each is its own reviewable commit.

What is left is either single-capability, where there is nothing to narrow, or routes
through module state and needs the same per-method trace: cache, log, env, crypto, and
the runtime_callback-only workflow modules.

Note the original observable named `escapeHtml`, which cannot demonstrate anything:
`zttp:text` declares no capabilities at all, so the test would pass before the change as
readily as after. The modules where the union actually over-approximates are
`zttp:websocket` (six capabilities over six exports), `zttp:auth`, `zttp:id`, and
`zttp:sql`. `zttp:websocket` was the largest and the audit is done: `.clock`,
`.policy_check`, and `.websocket` are reached by no export path, since the only
`requireCapability` in the module is `.runtime_callback` in dispatch. They stay in the
module set, which is what the sandbox grants and what the frame loop and hibernation
paths run under - per-export declarations are analysis-side only, because
`wrapToNativeFn` builds the runtime's active-context capabilities from the module set.

Observable: a test proving a `zttp:auth` bearer-token parse under a ceiling that excludes
the module's crypto and clock capabilities.

### 8. Unified repair vocabulary, then the deferred wire verbs (medium to large)

Collapse the parallel repair vocabularies into the one the spec assumes, then ship
`verify`, then `simulate_edit`, then `apply_repair`.

Why this rank, plainly: the agent package is the only client today and it reaches
simulate and repair in process, so no convergence behavior changes on the day the verbs
ship. Shipping `apply_repair` before the vocabulary is unified would freeze inconsistent
vocabularies into a public protocol, which is worse than the current honest refusal.
These become strategic the moment a second client exists - an editor, or the item-5
model run driven from outside the agent package. Ship `verify` first then, because a
minimal external client needs verify and simulate and nothing else.

Observable: a client outside the agent package completes a propose, simulate, verify
cycle over the wire with no in-process access.

### Sequencing

Items 1 and 6 start in parallel; both are small and neither depends on anything. Item 2
lands next and publishes its first table. Item 4 rides alongside. Item 3 begins once
item 2 provides a baseline to compare against. Item 5 runs the day item 2's live mode
works. Item 7 follows item 1. Item 8 waits for a second client or for the vocabulary,
whichever arrives first.

### Considered and refused

Recorded so they are not proposed again:

- **An SMT-grade counterexample solver.** The solver's triviality is a deliberate design
  choice and no current property needs path-sensitive constraints. Revisit only when a
  property demands it.
- **Replay as a training reward signal.** No training loop exists, and a reward computed
  over a fixed witness set leaks the same way a recorded cassette does. Replay is an
  acceptance check (item 2), not a reward.
- **Auto-applying validator M5.** Contract diff is blind to changes in pure computation,
  and D3 already forbids auto-apply on that basis.
- **Widening the autoloop past solver-backed boolean properties.** The six verdicts
  assume a decidable check; stretching them to fuzzy goals would break rollback
  semantics.

## The zts-advanced-1 Language Program

Implement the `zts-advanced-1` language profile incrementally on the existing
engine, keeping `scripts/verify.sh` green at every phase boundary. The source
spec is [zts-formal-spec-northstar-advanced.md](zts-formal-spec-northstar-advanced.md)
revision 4. The certificate and verifier stack (spec 13.3-13.4) and the
two-client conformance lab (14.2) are outside this program.

Three ground rules survive from phase to phase: the engine stays
interpreter-only with no kernel growth except where the spec names it; each
admitted form adds its semantics-registry rules in the same phase, so
`spec-check` stays green by construction; and no `meta` payload is ever
hand-written, because a hand-written payload is another drift gate.

Phases 0 and 1 are done. The executed plans and the program's decision log are
in [docs/archive/plans/](archive/README.md).

| Phase | Scope | Exit |
|---|---|---|
| 2. Type-system rock | Sound generic inference and instantiation per D1, constraints and explicit type arguments before inference; the closed narrowing list including negation, bare discriminant reads, and the `isDict`/`isBytes` value-kind guards; canonical type serialization per D3. | Generic functions instantiate soundly and never fall back to `unknown` over a frozen signature corpus covering every virtual-module export; narrowing conformance tests; stable type digests. |
| 3. Source `null`, recursive aliases, match upgrades | `null` as explicit data with the `??`/`?.`-rejected-on-null diagnostic and its repair; contractive recursive aliases over a finite type graph with memoized unfolding; match binding fields, rename and shorthand bindings, type-test patterns, and effectful arms with exactly-one-arm evaluation. | `JsonValue` minus the Dict arm compiles; exhaustiveness over null, literals, and type tests. |
| 4. Dict, JSON, Result completion | `Dict` and `zttp:collections` with persistent semantics, SameValueZero keys, and insertion order; `zttp:json` with a closed error taxonomy and policy-driven limits; `zttp:result` completion (`unwrapOr`, `orElse`, `collectAll`) with effect-row-polymorphic combinators per D2. | Dict determinism and SameValueZero tests; JSON round-trip and limit tests; `collectAll` first-error test. |
| 5. Bytes, ABI re-typing, defaults, Effects ceiling | `Bytes` and `zttp:bytes`; the HTTP, WebSocket, queue, and durable ABIs re-typed to the spec's 7.2 shapes including total `responseText`; trailing scalar default parameters; the decidable `Effects`-ceiling rule with repairs computed from the inferred row. | fetch, websocket, and queue examples re-typed; ceiling-rule repair tests. |
| 6. Full idiom table, validators, gate-complete protocol | The remaining idiom rows; equivalence validators per D3's method taxonomy, with any row lacking a registered validator shipping advisory-only; fixed-point normalization with a published pass bound; batch `apply_repair` and multi-property `verify`; the full registry-generated meta payload set. | Double-normalize byte-identity over the whole corpus; atomic `apply_repair` rejection tests; meta drift gates wired into `scripts/verify.sh`. |

Three design documents own the decisions the phases consume. Two of them also
retire an interim marker left in the code by phase 0:

- [D1 type system](plans/2026-07-30-014-d1-type-system-design.md) - assignability,
  generic inference, narrowing dataflow, join and union normalization, canonical
  type serialization. Unblocks phases 2, 3, and 4; retires `// D1-interim`.
- [D2 effects and purity](plans/2026-07-30-015-d2-effects-purity-design.md) -
  the effect-row atom set and its capability mapping, row inference and join, the
  purity predicate, and `Proof<T, P>`'s property domain. Unblocks phases 4 and 5;
  retires `// D2-interim`.
- [D3 canonical form and wire](plans/2026-07-30-016-d3-canonical-form-wire-design.md) -
  the lexical grammar, the canonical formatter, digest pre-images, protocol
  payload schemas, and the equivalence-validator taxonomy. Unblocks phase 6.

Four risks carry across phases. The generics retrofit in phase 2 has a long
tail, mitigated by the frozen signature corpus and by ordering constraints
before inference. Normalization in phase 6 may not be confluent, mitigated by
running the double-normalize property test from day one and falling back to
advisory-only rows. Hand-written meta payloads would multiply drift gates, which
is why the ground rule above bans them. Silent decisions leaking into wire
formats is why D1 lands before phase 2, D2 before phase 4, and D3's digest
section before the phase-1 hash freeze.

Two spelling decisions stay unresolved: the no-ASI flip waits for phase 6 and
its unique-parse-insertion validator, because the live parser has `return`-ASI
today; and the pipe operator (`|>`) and `interface` both stay shipped until the
D workstream produces a migration policy for removing published surface.

## Reset And Simplification

The reset ledger is
[2026-07-28-001-reset-simplification-plan.md](plans/2026-07-28-001-reset-simplification-plan.md).
Waves 0 through 3 and wave 6 are executed, and waves 4 and 5 are done except
for three items:

- Shared IR shape helpers (wave 4, item 4). The shared import and binding index
  shipped as `packages/zts/src/module_facts.zig` and all six analyzers adopted
  it. The shape-helper library is deferred, and the orchestration move is closed
  as declined: it had an architectural justification and no performance or
  correctness one, and it needed an IO boundary inside `pipeline.zig` that does
  not exist. Revisit only with a concrete consumer for a fourth `LoweredModule`
  phase, such as a build cache or incremental compile.
- The collector's role (wave 5, item 3). Inverted by the wave 0 RSS
  measurement. The memory defect it started from was found, fixed, and closed by
  a two-hour soak (per-runtime lifetime arena), but what the collector still
  earns has not been measured. No GC code is deleted until the remaining growth
  is attributed.
- `comptime.zig` unification (wave 5, item 4). Replacing its separate tokenizer,
  parser, and value model with evaluation over the main IR after parse would
  delete roughly 1,800 lines and structurally resolve the `==` inconsistency. It
  needs more comptime tests first.

VM-loop dedupe stays deferred behind the FaaS hardening, engine facade, and
measurement gates. The standalone plan is
[Deferred VM Loop Dedupe Plan](archive/DEFERRED_VM_LOOP_DEDUPE_PLAN.md).
