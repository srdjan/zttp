# Fail-closed guard for reassignment and mutation in the flow checker

Status: SUPERSEDED 2026-10-18 before implementation. The third validation round showed the guard premise is false (see F6). Owner decisions: Decision 5 Option A
(fix before 0.22.3); Decision 7 Option B (a fail-closed guard for 0.22.3, and
a flow-sensitive redesign of the flow checker as a separate plan after the
release). Decision 7 replaces Decision 6.

## Problem

The flow checker proves `injection_safe` and `no_secret_leakage` for handlers that
leak. Two mechanisms are missing. Both were observed with the 17:32 build of
`99bc7d74`; the checker source is unchanged at `e60335cd`. Probes are in
`/tmp/zttp-probe/`.

F1 (callback writes for non-selection methods). `mergeArgLabels`
(`packages/zts/src/flow_checker.zig`, near line 3055) captures writes made inside a
callback and rewalks the callback with the widened element labels only when the
method is `filter`, `find`, `toSorted`, `slice`, or single-argument `map`
(`iterates_values`). For `forEach`, `some`, `every`, `findIndex`, and `reduce`
it walks the callback once, with its parameters bound to the receiver's labels.
A write into a later element of the receiver therefore never reaches a later
iteration's parameter.

Observed:

- `parts = [escapeHtml(req.url), escapeHtml(req.url)]`, then
  `parts.forEach((v) => { parts[1] = req.url; acc.push(v); return 0; })`, then
  `Response.html(acc.join(""))`, declared `Proof<Response, "injection_safe">`:
  `zts check` exits 0. `zttp serve` on `/<b>x</b>` answers
  `/&lt;b&gt;x&lt;/b&gt;/<b>x</b>`.
- The same with `some` is accepted. `reduce`, `every`, `findIndex` report
  `injection_safe: true` (probed without a declared capsule).
- `parts = ["a", "b"]`, then `parts.forEach((v) => { parts[1] = secret;
  logInfo("m", { v: v }); return 0; })`, declared `no_secret_leakage`: exit 0.
- Control: the same write with no callback is refused (ZTS407); inside
  `filter` it is refused.

F2 (reduce accumulator). `closureResultLabelsBound` binds every callback
parameter to one label set, the receiver's labels. The reduce accumulator also
holds the initial value and every earlier callback result. Observed:
`parts.reduce((acc, v) => { logInfo("m", { v: acc }); return v; }, secret)`,
declared `no_secret_leakage`: exit 0.

F3 (validation round, 2026-10-18; scope now under owner decision). Probes in
`/tmp/zttp-probe/` show the root cause is wider than callbacks. Each handler
below is accepted (`zts check` exit 0) with a declared capsule:

- `const n: number = parts.push(req.url);` at top level, then
  `Response.html(parts.join(""))`, `injection_safe`. `zttp serve` returns the
  raw `<b>x</b>`. Cause: `propagateMutatingMethodTaint` has one caller
  (expression statements, near line 2465); a mutation in an initializer or any
  nested expression is not tracked.
- `const other: string[] = parts; other.push(req.url);` then `parts.join`:
  accepted; `zttp serve` returns the raw text. Cause: no alias model; the push
  taints only the `other` binding.
- `const holder = { items: parts }; holder.items.push(req.url);`: accepted.
  Cause: the mutation receiver must be a plain identifier.
- `parts.map((v, i, all) => { all.push(req.url); return v; })`, then
  `parts.join`: accepted. Cause: the callback's array parameter aliases the
  receiver.
- `dictMapValues(d, (v) => { logInfo("m", { v: v }); ... })` and the same for
  `dictFold`, where `d` holds a secret, `no_secret_leakage`: accepted. Cause:
  callbacks passed to module exports are walked by `closureResultLabels` with
  unbound parameters.

F4 (second validation round, 2026-10-18). Observed with the same build:

- Loop-carried data, no arrays involved in the leak path:
  `let s: string = ""; for (const v of ["a", "b"]) { out.push(s); s = req.url; }`
  then `Response.html(out.join(""))`, `injection_safe`: accepted; `zttp serve`
  returns the raw `<b>x</b>`. Cause: a loop body is walked once.
- A write in an `if` condition: `if (parts.push(req.url) > 0) { ... }`:
  accepted; `zttp serve` returns the raw text. Cause: conditions are scanned for
  sinks, not walked for writes.
- A literal receiver: `["a", "b"].forEach((v, i, all) => { if (i === 0) {
  all[1] = secret; } logInfo(...v...) })`, `no_secret_leakage`: accepted.
- A closure that reassigns an outer `let` is refused with ZTS604 ("let binding
  is never reassigned"), so that shape fails closed today.

The second fact check found that `check()` resets almost no walk state, that
imported cross-file summaries carry no write effects, that the seven module
callbacks are reached through `argDerivedLabels`, that Result methods (`map`,
`mapErr`, `andThen`, `match`) take callbacks (`match` inside an object
literal), and that optional-chain calls skip the callback binding.

The fact check also found: the runtime invokes callbacks for `map`, `filter`,
`forEach`, `every`, `some`, `find`, `findIndex`, `reduce`, `toSorted`, and
`Array.from`; seven module exports take callbacks (`dictMapValues`,
`dictFilter`, `dictFold`, `mapResult`, `mapError`, `andThen`, `orElse`); the
`flow-census.allow` mechanism column is a closed set; the update scripts refuse
untracked files, so this plan file must be committed or moved before a
republish.

Class: the fail-open class in AGENTS.md (a value claims more than was
checked). F1 is probably older than today's commits; nothing before `3e960e3b`
tracked callback writes. That is not confirmed by a probe on an older build.


F5 (branch joins). Observed with the same build, `Proof<Response,
"injection_safe">`:

- `let x: string = req.url; if (req.url.length > 3) { x = escapeHtml(req.url); }
  return Response.html(x);`: accepted. `zttp serve` on `/<a` returns `/<a`.
- `let x = escapeHtml(req.url); if (...) { x = req.url; } else { x =
  escapeHtml(req.url); }`: accepted. `zttp serve` on `/<b>x</b>` returns it raw.

Cause: a simple assignment replaces the binding's labels, and the walk keeps
the labels of the branch it walked last. Branches are not joined.

## Why a guard

Every shape in F1 to F5 except the reduce accumulator and the module callback
parameters needs a reassigned binding or a mutated array or record. Without
reassignment and mutation, every binding holds one value and every value is
immutable, which the current walk models: the order of the walk cannot change
a binding's labels, a loop iteration cannot feed the next one, and a callback
cannot change its receiver. The guard makes the flow properties unproven when
that precondition does not hold. A flow-sensitive redesign that proves such
handlers is deferred.

## Change

G1 (precondition scan). Add a pass to `FlowChecker.check` that runs before the
walk and visits every node of the file's IR, not only the nodes the walk
reaches. The pass records the first node (in source order) of any of these
forms:

- an assignment whose target is an identifier (any `let` or parameter
  reassignment, in any function or closure, including module level);
- an assignment whose target is a member or computed member;
- a compound assignment or an update expression, if the IR can hold one
  (ZTS613 and the parser refuse them, but the guard does not depend on that);
- a call whose callee is a member access or an optional chain with one of the
  property names `push`, `pop`, `shift`, `unshift`, `splice`, `sort`,
  `reverse`, `fill`, `copyWithin`, whatever the receiver;
- a `delete` expression, if the IR can hold one.

Use an exhaustive `switch` on the node tag for the scan, with no `else` arm,
so that a new IR tag fails to compile until it is classified. Scanning the
whole file rather than reachable code over-refuses only for dead code, and it
cannot miss a position.

G2 (effect). If G1 found a node, call `clearAllSinkProperties` after the walk
(the six properties: `no_secret_leakage`, `no_credential_leakage`,
`input_validated`, `pii_contained`, `injection_safe`, `deterministic`) and
store the node in a new field `unmodelled_state: ?NodeIndex`. The walk still
runs and still emits every diagnostic it finds, so a leak the walk sees stays
refused; the guard only removes proofs. Do not add a diagnostic code: a new
code needs a registry row, a producer, and a defect seed, and an unproven
property is already reported through the proof trace.

G3 (explanation). The proof trace must say why each cleared property is
unproven, with the construct and its line and column, for example "flow
analysis does not model reassignment or mutation: assignment to `x` at 3:5".
Find how `packages/zts/src/proof_trace.zig` summarizes a flow property that is
false with no diagnostic (the `unresolvedCallLabels` case) and extend that
path. If no such path exists, stop and report; do not add a diagnostic code.

G4 (imported files). A cross-file function is analysed through an imported
summary built by a `FlowChecker` over its own file. Add the G1 result of that
file to the summary, and when a call applies a summary that carries it, apply
G2 to the caller. Test it with a helper in a second file that pushes into its
argument.

G5 (callback inputs). Two holes need neither reassignment nor mutation: the
reduce accumulator (F2) and module-export callbacks (F3). Bind every parameter
of a walked callback to `mergeValues(receiver labels when the call is a method
call, labels of every argument that is not a callback, labels of the callback's
own earlier results)`, and rewalk the callback until the bound labels do not
change, bounded by `max_fixpoint_passes`; on exhaustion call
`unresolvedCallLabels` (which clears the properties) and use its result.
Apply this rule on every route that walks a callback:

- `mergeArgLabels`, for callees that are a member access or an optional chain;
- `argDerivedLabels`, before its early return, for the `derives_from_args`
  exports (`dictMapValues`, `dictFilter`, `dictFold`, `mapResult`, `mapError`,
  `andThen`, `orElse`);
- `closuresWithin`, for other module exports;
- a callback inside an object literal argument (Result `match`), direct or
  named.

G6 (flow_analyzer_version). Raise it from 4 to 5, with the comment: "5 makes
the flow properties unproven when the file reassigns a binding or mutates an
array or record, and binds callback parameters to the receiver, the
non-callback arguments, and the callback's earlier results." Re-pin the policy
hash in the eleven files that `55bb0049` and `3e960e3b` re-pinned:
`policy-hash.txt`, `scripts/check-meta-drift.sh`,
`canonicalize_mixed.golden.json`, `canonicalize_mixed_simulate.golden.json`,
`meta.golden.json`, `verify_paths_clean.golden.json`,
`verify_paths_missing.golden.json` (under `packages/tools/tests/fixtures/expert/`),
`packages/runtime/src/build_command.zig`, `packages/zts/src/pipeline.zig`,
`packages/pi/src/tools/zts_expert_query.zig`, and
`packages/zts/src/typed_frontend_tests.zig`. Take every value from a failing
run. `packages/pi/src/expert_codegen_record.zig` expectations change only
with the re-record, from its measured output.

G7 (documentation). State the guard in `docs/proofs-and-receipts.md` where the
flow properties are described, and add the flow-sensitive redesign to
`docs/roadmap.md`. Add this plan to `docs/plans/README.md`.

## Tests

T1 (unit tests in `flow_checker.zig`, through `runFlowDiagnostics` and
`runFlowProperties`, and through the typed pipeline for at least the first
shape of each group, because the direct helpers have no type checker):

- every shape in F1 to F5 that involves reassignment or mutation: the property
  is false, and the trace reason from G3 is present;
- G1 positions: an assignment inside an `if` condition, a `return`
  expression, a call argument, a callback, a nested closure, a module-level
  function, and dead code after a `return`;
- G4: a cross-file helper that pushes into its argument;
- G5: reduce with a secret initial value and a callback that logs only `acc`
  (refused), with a clean initial value (proves), and with a callback that
  returns the secret on one path and logs `acc` (refused); each of the seven
  module exports with a secret in the dict or Result and a callback that logs
  its parameter (refused); Result `match` with callbacks in an object literal;
  an optional-chain call with a callback.

Contrast tests that must still prove: a handler with only `const` bindings
that builds HTML with `map`, `join`, `concat`, and spread; a loop over
`const` data with no reassignment; reduce over clean data. Show each contrast
failing when the safe value is replaced by the raw one, so none is vacuous.

Existing tests that expect a proof for a handler that mutates or reassigns now
fail. Expected, from the fact check: the safe cases of
`selection callbacks carry writes into selected elements` (near line 6299,
including `other.raw = req.url` at line 6311) and of `map callbacks see values
written into later elements`. Update each to expect the property false and
cite the guard. List every changed assertion in the commit message. Do not
delete these tests: the precise rules they cover stay in place for the
redesign.

T2 (flow census). Add two `Spec` kinds to
`packages/tools/src/flow_census_probes.zig`, each with a `group` value and
with the census floor raised by the number of new probes: `mutating_push`
(the labelled value reaches the sink through an array that is pushed to) and
`module_callback_param` (the labelled value is in a dict and a
`dictMapValues` callback consumes it). `mutating_push` sets the `unresolved`
flag, so its expectation is `refuse_or_unprove`. `module_callback_param` takes
the default expectations. Any other observed mismatch: stop and report,
because the mechanism column of `scripts/flow-census.allow` is a closed set.

T3 (probes from outside). Rebuild, then rerun every probe in
`/tmp/zttp-probe/`. Each leaking probe must no longer prove its declared
capsule. `ctl_safe` must still prove `injection_safe`.

## Verification and evidence order

1. With a private `ZIG_LOCAL_CACHE_DIR` and `DEEPSEEK_API_KEY` unset:
   `zig build test-zts`, `test-flow-census`, `test-expert-golden`,
   `test-zruntime`, `test-examples`, `test-cli`, `test-standin`,
   `test-diagnostic-corpus`, `test-contract-golden`. Read each verdict from the
   exit status of an unfiltered run.
2. Sabotage: disable G1 and confirm its T1 tests fail; disable G5 and confirm
   its tests fail. Restore.
3. Commit 1: G1 to G7 and the tests.
4. `zig build test-expert-app` offline; it is expected to fail because the
   policy hash moved.
5. DeepSeek re-record: a one-case trial first (expected quarantine), then the
   full corpus. Report the first-attempt rate before (84%, 11/13) and after,
   and name each case whose verdict changed. Commit 2: the corpus and its
   measured expectations.
6. `scripts/update-convergence.sh`, commit 3. `scripts/update-coverage.sh`,
   commit 4.
7. `zig build release-provenance`, then `bash scripts/verify.sh`, both with a
   private cache.

## Out of scope

- The flow-sensitive redesign (branch joins, loop fixpoints, a heap model).
- The `SelectionWrites` mechanism and the selection and `map` output rules
  stay as they are; they become reachable only through files the guard does
  not clear, and the redesign will rely on them.

## Risks

- Over-refusal: every handler that uses `push` or reassigns a `let` loses its
  flow proofs. The re-record, the census, and `test-examples` measure this.
  Report the count; do not narrow the guard during the re-record.
- A model that sees the new trace reason may rewrite handlers to avoid
  mutation. That is the intended direction, but it changes the corpus
  behaviour, which the re-record measures.

## F6 (third validation round): the guard premise is false

Observed with the same build, with no reassignment and no mutation:

- A helper called in an `if` condition logs `env("SECRET_KEY")`; the handler
  declares `no_secret_leakage`: accepted. `zttp serve` with `SECRET_KEY` set
  wrote the secret to the log. Cause: conditions are scanned for sinks and the
  scan does not enter called functions.
- `const r: Request = req.url.length > 3 ? req : req;` then
  `Response.text(r.headers.authorization ?? "")`, `no_credential_leakage`:
  accepted. `zttp serve` echoed the `Authorization` header. Cause: request
  identity does not survive a ternary.
- `cacheSet("ns", "k", secret, 60); Response.json(cacheIncr("ns", "k", 0, 60))`,
  `no_secret_leakage`: accepted. Cause: `cacheIncr` declares no `.unknown`
  return label.
- `[secret].forEach(cond ? leaks : leaks)`, where `leaks` logs its argument,
  `no_secret_leakage`: accepted. Cause: a callback chosen by an expression is
  not resolved.

Each of three validation rounds found new holes that no earlier unit covered.
A guard that lists constructs cannot be shown complete against that evidence.
