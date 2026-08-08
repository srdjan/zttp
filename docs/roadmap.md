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

Five more of the same class turned up later, in the flow checker rather than in the
effect row, and all five are closed. The shape they share: an empty label set is the
positive claim that a value carries nothing, and each returned one where the honest
answer was that the checker could not look. The check that scans for swallowed errors
cannot see this - nothing is discarded, a wrong answer is returned. The whole class is
written up in
[docs/solutions/security-issues/empty-label-set-claimed-a-value-was-clean.md](solutions/security-issues/empty-label-set-claimed-a-value-was-clean.md),
including the probe method that found every one of them.

`userCallLabels` summarizes a callee's return labels, and every exit that could not read
the body - past the depth cap, past the parameter cap, or a call through a value with no
declaration to find - returned the union of the call's arguments, which for a
zero-argument call is empty. `env("SECRET_KEY")` behind a helper chain reached the
response unlabelled and `no_secret_leakage` held. Those exits now carry the `unknown`
label, and a sink it reaches clears every property that sink decides rather than proving
it. The caps cost precision now, never soundness.

The egress options object had two. Hoisted into a binding it is no longer a literal, so
every by-name extractor answered empty and only the whole-object body fallback ran - and
the body arm checks neither `credential` nor the URL-side properties, so a caller's token
in `const opts = { headers: { authorization: token } }` reached the third party with
`no_credential_leakage` proven. A computed key, `{ [field]: token }`, is invisible to the
same extractors even when the object is a literal, and the `body:` early return can stop
the whole-object fallback from running at all. Both now route the whole object to one
sink that assumes any field. Recognizing the second needed the `is_computed` flag rather
than a failed name lookup, because `getPropertyKeyName` resolves `{ [field]: v }` to
"field" - the variable holding the key, not the key.

The fourth was the closure, and the audit that found the first three declared it absent.
`["a", "b"].map(() => env("SECRET_KEY"))` reaching the response proved
`no_secret_leakage`: `inferLabels` had no arm for an arrow or function expression, so the
callback contributed the empty set. A closure now carries the labels of the value calling
it would produce. What the audit did was enumerate the unhandled tags that could appear
in a value position and conclude only the comma-expression pair qualified, which no
parser path emits - it did not notice that closures are values and are passed as
arguments constantly. Reading the arms is how that was missed; probing each position is
how it was found, and the sweep that gates the determinism work below is the systematic
version of the probe.

The fifth came out of that sweep, and it is the one the closure fix did not cover. A
module export answers with its declared return labels, which describe what the module
produces and cannot describe what a caller's callback returns, so
`parallel([() => env("SECRET_KEY")])` still proved `no_secret_leakage` after closures
carried labels everywhere else. Only closure-derived labels are unioned into a module
call's result - unioning every argument would taint results that carry no argument data -
and a durable export drops `nondeterministic` and only that label, because a recorded and
replayed clock read is the same on every run while a secret the same callback returns is
still a secret.

Audited and found sound in the same pass: the response resolver's step limit, which falls
back to a label-only sink check on the whole return value; `refineEnvLabels`, which keeps
the `secret` label when the env name is not a literal instead of downgrading it to
`config`; and `inferLabels` over an object literal, which merges every property value
whether or not the key can be named. Also checked and left alone: the response sink reads
argument zero only, which matches what leaves the process, since `Response.json/text/html`
take `status` from their second argument and drop everything else. If those helpers ever
honor custom headers, that argument becomes a sink in the same change.

The caps that remain cost precision, never soundness, and the cost was measured rather
than assumed. Over all 55 example handlers the depth cap trips zero times and the
parameter cap zero times, so memoizing the summary over the call graph would buy nothing
and was not built. The only fallback that fires is the one for a call with no declaration
to walk, twice, both from a relative file import - and that one did cost something real:
splitting a handler across files lost both leakage proofs. `exportedReturnLabels` walks
one imported module and answers its function's return labels with the parameters left
unlabelled, which the caller unions with its own argument labels. One level deep, so the
imported module's own imports stay untraceable and the answer never claims more evidence
than one file provides.

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

### 2a. A clock or random read does not clear `deterministic` (done)

`uuid()` reported `deterministic ....... PROVEN`, and a handler could then declare that
property in a `Spec<...>` and have it discharged. It was a false proof: the function
returns a different value on every call.

`isNonDeterministic` (`effect_inference.zig`) cleared the flag for `Date.now` and
`Math.random` member calls only. A module call that reached the `.clock` or `.random`
capability left it set, so every `zttp:id` mint and every clock-reading export escaped the
rule that the equivalent global call obeys.

The fix was a few lines, and it has landed. After resolving a call's capabilities,
`deterministic` clears when the newly added set contains `.clock` or `.random`, gated on
`durable_callback_depth == 0` for the same reason the member-call rule is - inside a
`step()` the read is recorded and replayed. Per-export capability rows (item 7) are what
make it precise: `parseBearer` stays deterministic while `jwtVerify`, which reads the
clock for `exp`, does not.

The corpus re-record it was blocked on rode in the same commit. Landing it flipped the
`jwt-auth` case, as expected: its recorded handler declares no `Spec<...>`, so the default
profile demanded a `deterministic` it no longer held, the turn retried, and the committed
cassette ran out of steps mid-turn. That one case was re-recorded with
`ZTTP_CODEGEN_RECORD=1 ZTTP_CODEGEN_ONLY=jwt-auth`.

What the prediction got wrong: [convergence.md](convergence.md) was expected to move, and
the rate did not. The policy hash went `37a115c262dc` to `118885d3f647` and first-draft
pass stayed at 90% (10/11) over the same corpus. Why it held is not measured here - the
row records the outcome, not the cause. The policy hash column is what makes the two rows
comparable enough to state the outcome at all.

Observable, and met: a handler returning `uuid()` reports non-deterministic, and a
`zttp:id` import gives `mintUuid` the `.random` capability without the `.clock` that only
`ulid` reads. Both are pinned in `effect_inference.zig`.

### 2b. Non-determinism as a flow property, not a capability property (done)

`deterministic` is demoted today by the presence of a capability, not by where its value
goes. A clock read is a source; a log write is a sink. `logInfo` reads the clock for its
timestamp, that value reaches stderr and stops, and the response is identical across
runs - yet the capability rule saw only that `.clock` was reached.

The interim rule in `effect_inference.handleCall` exempts a write-effect call whose
result the statement throws away, which covers logging exactly and leaves `uuid()`
demoted. It is an approximation in the same family as the `Date.now`-only rule it
extends, and it misses a value laundered through a store: `cacheSet(k, Date.now())` then
`cacheGet(k)` into the response reads as deterministic under both the old rule and the
new one.

The sound version is a data label, and it has landed. `DataLabel.nondeterministic` is
seeded in `scanImports` from each export's own capability set - so it tracks the
per-export rows from item 7 without any binding declaring anything about determinism -
propagates for free through `LabelSet.merge`, and clears `FlowProperties.deterministic`
when it reaches a response sink. The store-laundering case is closed:
`cacheSet(k, ...)` then `cacheGet(k)` into the response now reports non-deterministic,
which neither the `Date.now`-only rule nor the interim sink heuristic could see.

The flow answer is ANDed with the capability answer rather than replacing it. Two sources,
and the flow one now covers both kinds of read: `Date.now()` and `Math.random()` are
global member calls with no import to hang a label on, so `inferCallLabels` labels the
read itself when the receiver is the undeclared global, and the value then follows the
same path a clock-reading export's does. A shadowed `Date` carries nothing, and a read
behind a helper still arrives, because the call summary collects the helper's return
labels.

That fix needed one in `LabelSet.isEmpty`, which masked bit 7 off as padding. Bit 7 is
`nondeterministic`, so a set carrying only that label read as empty, and both the sink
check and the import scan skip empty sets. No module export hit it - every clock- or
random-reading export also carries `internal` or `credential` - but the label on a bare
`Date.now()` is the first pure one.

Handler determinism is now the flow answer, and only that. The change waited on a sweep
of every position that can hold a value, because retiring a backstop means asserting the
walk has no blind spots left, and the first attempt at this measurement produced a false
proof rather than a win: with `computeProperties` switched to a flow-only answer, the
handler that only logs a timestamp flipped to `PROVEN` as intended, and
`[1, 2, 3].map(() => Date.now())` reaching the response reported `PROVEN` too. The sweep
that followed found two more holes, both since closed.

What each source answers now:

- **flow** decides the handler's `deterministic`, from whether a varying value reaches the
  response.
- **`contract_builder`** answers only whether there was a handler to walk. Its scan for
  `Date.now` and `Math.random` still runs, but to name the first varying call site for the
  reload HUD rather than to set the property.
- **the effect row** answers the per-function question, which flow cannot reach:
  `function_specs` reads it directly to discharge a helper's `Proof<...>` capsule. The
  interim sink rule in `handleCall` stays with it, for that surface alone.

`idempotent` is re-derived after the flow answer lands. It is computed from determinism,
the contract builder computes it before the walk runs, and leaving it there had `uuid()`
in a response reporting `deterministic ---` beside `idempotent PROVEN` - the worse of the
two to get wrong, since idempotent is what claims safety under at-least-once delivery.

Six tests in `contract_builder.zig` were asserting determinism through a helper that never
ran the flow walk; they passed because the presence rule answered there. Four dropped the
assertion and three cases moved to `precompile.zig`, where the walk runs.

Why it is worth doing rather than living with the approximation: `deterministic` is the
declarable property authors reach for most, and it feeds `idempotent`
(`deterministic and retry_safe`). A property that answers from "was a capability
touched" rather than "did the value reach the answer" will keep producing false negatives
that authors work around by narrowing their `Spec`, which widens the emitted set in
exactly the direction item 7 is trying to shrink.

Observable, and met: a handler that writes a timestamp to a cache and reads it back into
the response reports non-deterministic, and one that logs a timestamp reports
deterministic - both from the flow rather than from the capability set, and the second
now at the contract level rather than only inside the flow checker.

`flow_checker.zig` pins the label side: each direction of the cache case, the untouched
baseline, both global reads, a shadowed `Date`, a read behind a helper, a read inside a
closure, and a durable callback keeping determinism while still carrying a secret.
`precompile.zig` pins the contract side, where the two answers are combined: the logging
handler, the minted id with its `idempotent`, and the durable step in both its callback
and its eager form.

### 3. Typed holes (done)

All three slices have landed. `hole()` exists as a builtin typed `never`, so a
handler with a hole on one branch checks clean with both paths enumerated and its
properties proven; reaching one answers 501 rather than the 500 a real fault produces,
in all three response paths. `zts check --json` publishes a `holes` array carrying each
site's function, line, column, the value type the expression must produce (with the
phantom capsule marker erased), and the capability budget the handler declared but has
not yet spent.

The two pieces that were missing have landed, and one of them was not the job it was
written up as. The undischarged obligations were a projection: spec discharge and capsule
discharge both finish before holes are collected, so the failures were already sitting in
`spec_diagnostics` and only needed attributing by function. A hole in a helper carries
what that helper breaks (ZTS606) or claims and does not hold (ZTS500); a hole in the
handler carries the handler's. The implicit default profile reports its failures as one
comma-joined name, which is right for the HUD and useless to a consumer matching on
names, so this surface carries them apart.

The in-scope bindings were described as needing scope reconstruction the IR does not
retain. It does retain it - the parser keeps the whole scope tree, block nodes carry their
scope id, and `TypeEnv.getVarTypeByBinding` already answers by scope and name - but none
of that was needed either. The enclosing function's parameters plus every declaration the
hole comes after, ordered by node index, is the same answer for every shape the subset
allows: a binding written below the hole has the higher index and stays off the list,
which is what keeps an uninitialized name from being offered. Block structure is not
modelled, so a binding from a sibling block that already closed is still listed. That
over-offers rather than under-offers, and an offered name that does not resolve fails
loudly at the next check rather than silently.

A binding whose type no annotation reaches reads `unknown` rather than a guess. A wrong
type is worse than an absent one: it is the difference between an agent asking and an
agent confidently writing an expression that cannot compile.

The third slice has landed. `zts_expert_holes` gives the agent that whole frame, and the
persona instructs it to fill one hole per turn rather than regenerate the file. The tool
calls the production analyzer in-process, so it works in an isolated handler workspace
without depending on the repository build graph. Before this the data was reachable only
inside a full `zts check --json` envelope that the tool description never mentioned, so
the agent had no reason to look for it.

The loop change has landed, and the thing it replaced was an instruction. Asking the
agent to fill one hole per turn is not a mechanism: a turn that hands back a whole file
emits from the model's full distribution whatever the persona said, and the veto is left
to reject what came out - the subtractive loop holes exist to replace.

`zts_expert_fill_hole` is the enforcement. Its input is one expression and one hole's
coordinates, and the edit it produces replaces the bytes of that `hole()` call and
nothing else. No argument can make it touch a second line, so "one hole per turn" stops
being an instruction the model can decline and becomes the shape of the only edit
available. The coordinate match is exact rather than nearest: a stale coordinate is the
expected failure here, because filling one hole moves every later hole on the same line,
and the useful answer is a refusal naming the frame to re-read.

Why: this is the only item that changes the convergence mechanism rather than measuring
or enforcing it. Today the loop is subtractive - the agent emits from its full
distribution and the veto rejects. With holes the compiler constructs the frame, and the
emittable set per step narrows to one typed expression in a known context. Set
convergence stops being statistical and becomes structural.

Observable: round-trips to first green fall for hole-mode sessions against whole-file
sessions on the same model. Measured on 2026-08-03 and published as the fourteenth row of
[convergence.md](convergence.md): median 3 round-trips for the hole arm against 5 for
whole-file, over four cases paired with the whole-file case of the same task. Every hole
case also passed first draft with zero veto retries, which is the mechanism rather than
the aim - a `fill_hole` edit cannot produce a whole-file rejection.

Two caveats travelled with the number. The hole arm is handed the frame, so part of the
saving is work it was not asked to do; that is the mechanism, and it means the comparison
is hole mode end to end against writing from scratch. The recorded arm also seeds one hole
per case because two proposed fills in one turn did not compose when the measurement was
taken. That defect is fixed by carrying one accepted fill to the next turn, publishing a
fresh compiler frame, and filling the next site against the bytes now on disk. The offline
stand-in proves the two-turn composition over a two-hole seed through the real server,
publisher, fill tool, veto, and apply path. The history and resolution are in
[two hole fills in one turn do not compose](solutions/logic-errors/two-hole-fills-in-one-turn-do-not-compose.md),
so future live comparisons can add multi-hole cases without folding that loop defect into
their round-trip number.

### 4. Widen the mechanical repair lane (done)

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
`packages/zts/src/repair_intent.zig`; 13 now reach a source edit, and the autoloop
drives 5 properties rather than 3.

The count moved from 8 to 13 by wiring up rewrites that already existed. Five intents -
`replace_ternary_with_if`, `name_const_above_template`, `lift_default_to_body`,
`flatten_destructure`, `drop_unused_index_alias` - had builders in the canonicalizer
reachable only through the normalize loop, which rewrites a whole file.
`canonicalize.applyStatementIntent` asks the narrow question a repair client actually
has: build this pass's rewrites, keep the one carrying this intent at this line, splice
it. It refuses on two matches rather than guessing, because `Intent` carries no column,
and on a span containing another rewrite, because that ordering takes the normalize loop
several passes and a single apply has one.

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

`repair_available` answers from the registry instead of a constant, and every
declared-law row is now `implemented`: the two arrow-to-function rewrites, let-to-const,
its for-of form, compound assignment, and the bool compare. Six of eighteen intents are
gradable, and ZTS604 and ZTS620 advertise exact repairs. A `status` distinct from
`method` is what kept that honest while they waited, and it still does: the four M3 rows
name the right method and the semantic kernel they need does not exist, so they answer
false.

`candidate_grade` stopped being a constant with them. It was true by accident while no
row was implemented; it answers from the registry now, so `canonicalize` calls a rewrite
`mechanical_repair` exactly when something discharges it - the same condition
`repair_available` keys on, read from the same place.

`repair_validator.validateApplication` is what discharges it, and it lives beside the
registry rather than beside the rewrite on purpose. A validator that reuses the
producer's own scanner cannot catch the producer drifting - it would re-derive the same
wrong answer and agree with itself. This one re-locates the comparison independently,
recomputes the law's rewrite from the original line, and accepts only a byte-for-byte
match confined to the diagnostic's line.

It is solver-free by decision. `semantics_check.runSmt` degrades to "skipped" when z3 is
absent, so routing a discharge through the solver would make a published protocol field
answer differently on a machine without z3. The SMT layer stays what it is: a
design-time audit of the law catalog, not a per-application gate.

The discharge is published next to the existing verification in
`pi_apply_repair_plan`, which answers a different question. A candidate can introduce no
new diagnostics and still not be the law's rewrite: `x === true` edited to `!x`
type-checks exactly as well as `x` does and means the opposite.

The independence is checked rather than asserted. A differential test in
`canonicalize.zig` runs the rewriter and the law over the same real inputs and requires
them to agree byte for byte, driven off `rewrite_row_intents` so a row that becomes
gradable without a fixture fails instead of shipping untested. The compound-assignment
law is the one that earns it: `total -= fee + tax` must become
`total = total - (fee + tax)`, and without the parentheses it reassociates to
`(total - fee) + tax` and computes something else, so a validator that accepted the
unparenthesized form would grade a value-changing edit as an equivalence.

Observable: compiler-authored apply share rises on the item-2 corpus, and
`repair_available: true` appears on the wire for a named, tested subset. The second half
is done. The first is measurable against [convergence.md](convergence.md) and has not
moved yet - the eleven-case corpus contains no case whose first draft trips one of the
five newly reachable rules.

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

The plumbing is in place and the measurement is not. "Through the existing
OpenAI-compatible provider path" was optimistic: the path existed but had no way to be
pointed anywhere. `base_url` was a `Config` field nothing set, and the model id came
from `models.zig`, which only knows hosted models - so a local runtime was unreachable
even though it speaks the same wire shape. `ZTS_OPENAI_BASE_URL` and `ZTS_OPENAI_MODEL`
now set both, an off-registry model takes the provider default output ceiling rather
than inheriting a hosted model's, and unset means the hosted path is exactly what it
was.

To run it, with any server that serves the OpenAI Responses shape:

```bash
export OPENAI_API_KEY=unused-by-a-local-server
export ZTS_OPENAI_BASE_URL=http://127.0.0.1:11434/v1/responses
export ZTS_OPENAI_MODEL=qwen2.5-coder:7b
zig build test-expert-app          # replay first: confirms the harness is sound offline
# then the live corpus run, and `bash scripts/update-convergence.sh` to publish
```

What remains is running it, which needs a local model server. Note the wire shape is the
Responses API, not Chat Completions - a runtime that serves only the latter needs a
shim, and that is worth checking before reading a failure as a result about the model.

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

### 7. Per-export capability rows (done)

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

Eight of the 24 modules are tightened, each verified against its implementation rather
than its comment: `zttp:auth` (parseBearer and timingSafeEqual reach neither crypto nor
clock), `zttp:id` (only ulid reads the clock), `zttp:websocket` (traced through dispatch
to the runtime callbacks and the connection pool: only send and close write to the
socket, only serializeAttachment can touch disk), `zttp:ratelimit` (rateReset removes a
map entry and reads no clock), `zttp:sql` (`sql()` registers a statement in a map and
opens no database), `zttp:crypto` (base64 is a transport encoding: both impls are
`std.base64` over the module allocator and reach no gated helper), `zttp:cache`
(cacheDelete unlinks by key and cacheStats sums counters already held, so neither
evaluates an expiry or reads a clock), and `zttp:service` (the system.json read happens
once in `installState`, so the one export reaches no file).

Nothing is left to narrow. The rest are single-capability, where there is nothing to
say, or their exports each reach the whole module set: `zttp:env` has one export that
uses both its capabilities, and all four `zttp:log` exports stamp a timestamp and write
to stderr.

The last tightening did not land quietly, and that is the part worth keeping. Taking the
clock off `cacheStats` flipped a golden fixture's `deterministic` from false to true,
because the flow checker read its varying-value label off the capability set and the
module-level `.clock` had been covering a call that returns live counters. The verdict
was right and the reason was an accident. The same rule was already wrong on `zttp:sql`,
which declares no clock: a handler returning `sqlOne` rows proved `deterministic` while
its answer moved under it, and `examples/sql/sql-crud.ts` declared the property on that
basis. A read from mutable module state is now a second varying source - `stateful` plus
a `.read` effect - which no capability set can express. Written up as
[a-proxy-signal-carried-a-proof-it-never-claimed](solutions/logic-errors/a-proxy-signal-carried-a-proof-it-never-claimed.md).

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
the module's crypto and clock capabilities. It is `a tightened export carries only what
it reaches` in `packages/zts/src/effect_inference.zig`, alongside one per tightened
module.

### 8. Unified repair vocabulary, then the deferred wire verbs (done)

Collapse the parallel repair vocabularies into the one the spec assumes, then ship
`verify`, then `simulate_edit`, then `apply_repair`.

Why this rank, plainly: the agent package is the only client today and it reaches
simulate and repair in process, so no convergence behavior changes on the day the verbs
ship. Shipping `apply_repair` before the vocabulary is unified would freeze inconsistent
vocabularies into a public protocol, which is worse than the current honest refusal.
These become strategic the moment a second client exists - an editor, or the item-5
model run driven from outside the agent package. Ship `verify` first then, because a
minimal external client needs verify and simulate and nothing else.

The vocabulary is one enum. `Refactor` carried a free string where `StatementRewrite`
carried a typed `RepairIntent`, and five of its names differed from the tag by more than
spelling - `canonicalize_arrow_helper` against `replace_arrow_with_function` - which is
what made it a second vocabulary rather than a rendering of the first. The
string-to-intent mapper the normalize trace needed retires with it, and the confluence
harness enumerates typed rows, so a new intent nobody pairs against is a visible gap in
the same vocabulary the compiler emits. The v2 wire publishes `intent`, which mattered
most: `canonicalize` already ships, so it had been emitting the producer-local string
into a public protocol - the exact freezing this item exists to prevent. v1 keeps its
five names, which D3 §6 freezes, and `legacyKind` is the only place they survive.

`verify` shipped on a registry that already existed. The deferral read "needs the
verifier discovery registry", and `proof_trace.property_info` is the closed set, with a
comptime check tying it to `HandlerProperties`. `verifiers` derives from it, so a
property added to the contract reaches `meta` and `verify` without an edit and the
protocol can never advertise a name it would then refuse. Verdicts are projected out of
`proofTrace` rather than recomputed: a verification surface is where two implementations
disagreeing costs the most.

`simulate_edit` shipped on the collapsed vocabulary, which is what its deferral was
waiting on. A repair is the object `canonicalize` published, round-tripped unchanged.
`original` is required rather than optional - it is the client's snapshot of the line it
decided to change, and an absent snapshot would make the staleness check silently skip.

`apply_repair` shipped once the registry had six rows rather than one. It is the only
operation on this wire that writes, and it is gated four ways before it does. Every
repair's intent must be gradable, because applying a rewrite unasked is a stronger claim
than advertising it - `add_trailing_return` exists to change what the program does and
can never be auto-applied. Each repair is then applied on its own and discharged against
its law on the actual edit, so one that names `replace_let_with_const` and rewrites the
line to something else is caught rather than trusted. The result runs the veto, and one
new diagnostic refuses the whole set. Applying one at a time rather than in bulk is what
makes the second gate meaningful: a bulk apply plus one check could not say which repair
was wrong, nor catch two rewrites each wrong in ways that cancel in the final text.

Atomic by construction, and the tests assert it as file bytes rather than a status code:
a refusal that had already written would report the same reason as one that had not.

With it, spec 4.8's closed operation set is fully served, so the dispatch lost its
`else => unreachable` prong - an unhandled operation is now a compile error.

Observable: a client outside the agent package completes a propose, simulate, verify
cycle over the wire with no in-process access. Met, as `an external client completes
propose, simulate, verify over the wire` in `packages/tools/src/agent_protocol.zig`:
three `respond` calls, each request carrying only what the previous response published,
ending with an assertion that the file on disk never changed. Running it is what found
the gap it now covers - `verify` read only files, so a client could simulate a repair and
then only ask about the file it had not repaired. It takes an optional `content`, and the
digest covers whatever was analyzed.

### Sequencing

Items 1 and 6 start in parallel; both are small and neither depends on anything. Item 2
lands next and publishes its first table. Item 4 rides alongside. Item 3 begins once
item 2 provides a baseline to compare against. Item 5 runs the day item 2's live mode
works. Item 7 follows item 1. Item 8 waits for a second client or for the vocabulary,
whichever arrives first.

Every item on this agenda has shipped, and as of 2026-08-03 both open measurements are
closed too. Item 5's small-model row and item 3's hole-mode comparison are published as
the thirteenth and fourteenth rows of [convergence.md](convergence.md). Both needed
sessions recorded against a live model, which is why they stayed open, and both needed a
fix to the harness before they could be published honestly: the model column was printed
from a compile-time constant rather than read from the cassettes, and the hole arm's
first seeds carried a violation the differential veto could not see past.

What that leaves open is not measurement either. The hole-fill composition defect is now
closed offline. Recording variance between two runs of the same prompt remains a property
of the model measurement, and four paired cases remain a thin basis for the round-trip
comparison.

What the agenda leaves behind, for the next reader deciding where the gap still is: the
provable set is true as far as the standing checks can see (item 1, and the two fail-open
classes written up in `docs/solutions/`), the gap is published and dated
([convergence.md](convergence.md)), and the mechanisms moved from rejection toward
construction - six intents repair mechanically, and a turn can spend itself on one typed
hole. The twenty-case corpus is now the binding constraint on all three legs, which is
the honest next thing to grow.

The 2026-08-03 `InsufficientCredit` failure exposed a separate design problem: routine
development of the recorder, veto outcomes, compiler repair, and hole loop could not reach
their production paths without model turns. Those paths are now exercised offline. A
loopback Anthropic response traverses the production record tee and replay client; defect
seeds cover retry, salvage, and compiler-authored repair; and hole seeds cover the
in-process publisher plus multi-turn composition. Live model access is required only to
create an empirical cassette or publish a model-behavior row, not to develop or verify
the machinery around it.

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

Phases 0 through 2 are done. The executed plans and the program's decision log
are in [docs/archive/plans/](archive/README.md); phase 2's plan is still
[docs/plans/2026-08-04-018-zts-advanced-rev4-phase2-plan.md](plans/2026-08-04-018-zts-advanced-rev4-phase2-plan.md).

Phase 2 met its exit against the frozen signature corpus: 24 modules and 90
exports, every emitted signature parsing with no fallback to `unknown`, and
pinned digests. Assignability amendment A1, which makes an unresolved name an
error rather than `true`, was the one piece of its scope left open, and it is
closed. It had been deferred to phase 5 on the reading that it needed the ABI
types and the durable and queue exports retyped; re-measuring found three causes
and only one of them was that.

A name nested in a compound type never resolved, because the pool holds no alias
table: `getOne(): Todo` checked and `getTodos(): Todo[]` did not. `durable.run`
returns its callback's type, which `ReturnKind` cannot spell, so it declared the
coarse `unknown`. And `Response.json()` inferred nothing, so the handler return
check has been passing by never running - a fact the fail-open kept invisible.
The three fixes are `TypePool.RefResolver`, `FunctionBinding.returns_from_param`,
and `abi_types.zig`. Zero of 55 examples report the A1 signal now.

What that leaves for phase 5 is the ABI itself rather than A1. `abi_types.zig`
describes today's shipped `Response`, not spec section 7.2, which renames the
constructors to `responseJson<T>: Result<Response, JsonError>` and types the
request side over `Bytes`, `Dict`, and `JsonValue` - none of which exist before
phases 3 and 4.

| Phase | Scope | Exit |
|---|---|---|
| 3. Source `null`, recursive aliases, match upgrades | `null` as explicit data with the `??`/`?.`-rejected-on-null diagnostic and its repair; contractive recursive aliases over a finite type graph with memoized unfolding; match binding fields, rename and shorthand bindings, type-test patterns, and effectful arms with exactly-one-arm evaluation. | `JsonValue` minus the Dict arm compiles; exhaustiveness over null, literals, and type tests. |
| 4. Dict, JSON, Result completion | `Dict` and `zttp:collections` with persistent semantics, SameValueZero keys, and insertion order; `zttp:json` with a closed error taxonomy and policy-driven limits; `zttp:result` completion (`unwrapOr`, `orElse`, `collectAll`) with effect-row-polymorphic combinators per D2. | Dict determinism and SameValueZero tests; JSON round-trip and limit tests; `collectAll` first-error test. |
| 5. Bytes, ABI re-typing, defaults, Effects ceiling | `Bytes` and `zttp:bytes`; the HTTP, WebSocket, queue, and durable ABIs re-typed to the spec's 7.2 shapes including total `responseText`; trailing scalar default parameters; the decidable `Effects`-ceiling rule with repairs computed from the inferred row. | fetch, websocket, and queue examples re-typed; ceiling-rule repair tests. |
| 6. Full idiom table, validators, gate-complete protocol | The remaining idiom rows; equivalence validators per D3's method taxonomy, with any row lacking a registered validator shipping advisory-only; fixed-point normalization with a published pass bound; batch `apply_repair` and multi-property `verify`; the full registry-generated meta payload set. | Double-normalize byte-identity over the whole corpus; atomic `apply_repair` rejection tests; meta drift gates wired into `scripts/verify.sh`. |

Three design documents own the decisions the phases consume. Two of them also
retire an interim marker left in the code by phase 0:

- [D1 type system](plans/2026-07-30-014-d1-type-system-design.md) - assignability,
  generic inference, narrowing dataflow, join and union normalization, canonical
  type serialization. Unblocks phases 2, 3, and 4; retired `// D1-interim`, and
  no marker of that name is left in the tree.
- [D2 effects and purity](plans/2026-07-30-015-d2-effects-purity-design.md) -
  the effect-row atom set and its capability mapping, row inference and join, the
  purity predicate, and `Proof<T, P>`'s property domain. Unblocks phases 4 and 5;
  retires `// D2-interim`.
- [D3 canonical form and wire](plans/2026-07-30-016-d3-canonical-form-wire-design.md) -
  the lexical grammar, the canonical formatter, digest pre-images, protocol
  payload schemas, and the equivalence-validator taxonomy. Unblocks phase 6.

Four risks carry across phases. The generics retrofit in phase 2 had the long
tail the plan named, and the frozen signature corpus is what bounded it; what
the corpus could not bound was A1, and the sweep over every example is what
bounded that instead - seven failures, each traced to a cause before any of them
was fixed.
Normalization in phase 6 may not be confluent, mitigated by
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
