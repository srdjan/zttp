# Plan: flow-checker sinks in callees, captured values, and stores

Status: accepted 2026-10-08, revision 2. Source: section 7 of the
[boolean and arity plan](2026-10-08-boolean-and-arity-checks.md), decision
P1 (a): this plan is written and fixed before that plan. Code references are
to local `main` at `f63415a8`. The owner approved implementation on 2026-10-08 (section 6).

## 1. Summary

The flow checker decides `no_secret_leakage`, `no_credential_leakage`,
`input_validated`, `injection_safe`, and `pii_contained`. Two research agents
measured it with probe censuses and throwaway prototypes on 2026-10-08. Their
diffs, probes, generators, and logs are in the session scratchpad
(`plan-flow-callee/`, `plan-flow-store/`). Nothing was committed.

**The defect is much wider than section 7 recorded.** A census of 504 probes
(4 label families, 7 sinks, 18 callee kinds) found 220 that prove a property
while they leak. Only a sink written directly in the handler body, or in a
directly routed function, is refused. Every sink inside a called function is
silent, and a value captured by a closure carries no label at all, so even a
closure that returns `Response.json({ k: token })` proves
`no_secret_leakage` (observed). This is the fail-open class in AGENTS.md: a
proven property that is false.

A prototype with three parts reduced the 220 to 26, kept replay at 19 of 19,
newly refused no example, and changed one contract golden. The 26 that remain
need two more units (cross-file helpers and credential reads through a passed
request).

A review with 30 more probes found three more fail-open causes: a
module-level constant carries no label, so `const token = env("API_TOKEN")`
at module scope returned from the handler is proven clean (observed, no
helper involved); an unresolved call whose result is discarded never runs its
sinks; and recursion stops widening labels at the active frame. Artifacts
proven by the old checker also stay valid, because nothing in the policy hash
changes when the analyzer is fixed.

A separate fail-open: a secret passed to a sub-handler with `zttp:workflow`
`call` and echoed back reaches the response while `no_secret_leakage` is
proven (observed).

A scope question, not a defect: the documented promise of `no_secret_leakage`
is "no secret-labelled value reaches a response, header, or egress call"
(`docs/proofs-and-receipts.md:75`). A secret written to the durable store or a
queue breaks no documented promise. Section 7 of the source plan called that
gap a fail-open; that was wrong. Decision Q3 decides the scope.

## 2. Observed facts

### 2.1 Root causes

1. **Sinks are silent during summaries.** `checkExprSinks` returns at once
   while `summary_returns` is set (`packages/zts/src/flow_checker.zig:3240-3244`,
   "diagnostics belong to the handler walk"). Called bodies are walked under a
   summary: `functionCallLabels`, `closureResultLabels`,
   `exportedReturnLabels`, `listedToolRouteLabels`, and route dispatch. The
   handler walk also enters nested declarations structurally
   (`flow_checker.zig:1930`), but a `function` declaration is misread there
   (the boolean and arity plan, unit B0), and every callee kind the census
   measured stayed silent. `check` walks only the handler
   and the `routerMatch` roots. A return value inside a summary is merged into
   the summary instead of reaching `checkResponseSink`.
2. **Captured values carry no label.** The scope analyzer keys a captured
   variable by the inner function's scope and upvalue slot. `flow_checker.zig`
   never handles that binding kind (no occurrence of `upvalue` in the file), so
   a captured read returns the empty label set, or, through a key collision,
   the labels of an unrelated inner parameter. Both are wrong; the first is
   the "empty set claims clean" class in AGENTS.md.
3. **A re-walked callee keeps stale labels.** A `var_decl` writes labels only
   when they are non-empty, so a callee walked once with a secret argument
   taints a later clean call.
4. **Module-level declarations carry no label.** `check` walks only the
   handler and the route roots (`flow_checker.zig:459-465`), so a
   module-level `var_decl` never runs and a read of a `.global` binding
   returns the empty set. Observed: `const token = env("API_TOKEN") ?? "";` at
   module scope, then `return Response.json({ k: token })` in `handler`,
   passes `zts check` with exit 0 and `no_secret_leakage` holding. This needs
   no helper and no closure.
5. **An unresolved call whose result is discarded is silent.** A call past the
   summary depth cap (8) or parameter cap (8), or a call through a
   function-typed parameter, returns its argument labels plus `.unknown`. That
   fails closed only when the result reaches a sink. When the result is
   discarded, the unwalked body's sinks never fire (Fable probes: a chain of 9
   helpers ending in a log; a 9-parameter helper; `apply(f)` calling `f(t)`;
   the same through a record method). `unknownRouteCallLabels`
   (`flow_checker.zig:2690-2697`) already clears the sink properties for an
   unresolved route call; the other summary exits do not.
6. **Recursion stops at the active frame.** When the callee is on the summary
   stack, `functionCallLabels` returns the argument union
   (`flow_checker.zig:3093-3097`) and never re-walks with wider labels, so a
   secret introduced in the recursive argument never reaches the sink in the
   base case (Fable probe).
7. **Old artifacts stay proven.** `precompile.zig:3245-3251` copies the flow
   properties into the contract, and the acceptance kernel takes
   `no_secret_leakage` on the producer's word (`consumerChecked`,
   `packages/proof-checker/src/proof_system.zig:92`). The only analysis hash is
   `policyHash()` over rule metadata, which the flow fixes do not move. So a
   certificate built before the fix for a leaking handler stays valid.
8. History: `666b8a18` introduced summaries to stop wrapper functions from
   laundering taint through their return values. Before it, nested function
   bodies were already walked structurally. The early return in the summary
   path is inference: it probably avoids duplicate reports (re-walks per call site and per
   `inferLabels` evaluation) and reports with unbound parameters.

### 2.2 Census before and after the prototype

| Verdict | Before | After A | After A+B+C |
|---|---|---|---|
| Refused (correct) | 76 | 234 | 270 |
| Fail-open | 220 | 62 | 26 |
| Held (no leak, or not a sink by policy) | 208 | 206 | 206 |
| Over-refusal | 0 | 2 | 2 |

A: sinks evaluated during summaries, with deduplication per (node, kind,
message), parameter binding for closures passed to array methods, and an XSS
check on a callee's direct `Response.html` return. B: captured reads resolved
by name (an over-approximation). C: each declaration overwrites its labels.

All 147 clean controls stayed held in every build. Every refusal carries the
sink-specific code (ZTS400 to ZTS407), reported once at the sink node.

**The 26 remaining fail-opens:**
- 14 rows for a helper imported from another file: `precompile.zig:588` walks
  the imported file in a separate `FlowChecker` through
  `exportedReturnLabels`, with unlabelled parameters, and discards its
  diagnostics and properties.
- 12 credential rows where a helper receives `req`: the credential label is
  given to `req.headers.authorization` only for the request binding that the
  handler, a route walk, or a listed-tool summary installs
  (`flow_checker.zig:483`, `:2633`), not for a `req` passed to a helper.

**The 2 over-refusals:** a callee builds `Response.html(userInput)` and the
caller discards it.

**Gaps no part of the prototype touches, present in the handler body too:**
- `return fetch(url, { body: secret })`: the return path never calls
  `checkExprSinks`.
- A sink inside an expression, such as `const rs = [fetch(..., { body: t })]`:
  `checkExprSinks` examines only the top call of a statement or initializer.

### 2.3 Prototype blast radius (A+B+C)

- `test-diagnostic-corpus`: 192 of 192 (the corpus grew with the census
  probes only in the prototype worktree).
- `test-standin`: 56 of 56. `test-expert-app -j1`: replay 19 of 19.
- `test-proof-swallow`: 3 new discard sites (prototype hygiene).
- `test-contract-golden`: `packages/tools/tests/fixtures/contract/durable_approval.ts`
  loses `deterministic`, `idempotent`, and `no_secret_leakage`. Part B causes
  it: the `.unknown` label of `durable.waitSignal`, read through a captured
  variable, now reaches the response. This exposes an earlier fail-open
  (decision Q1).
- Examples: only `examples/durable/approval.ts` changes, for the same reason.
  It already fails with ZTS500; no example is newly refused.
- No existing flow-checker unit test failed: route-function tests cover routed
  sinks (`flow_checker.zig:5678`), but no test covers a sink in a called
  helper.

### 2.4 Stores, queues, and workflow calls

- The flow sinks are the response helpers (global methods), `zttp:log`,
  `fetch`, and `zttp:service` `serviceCall` (`SinkKind`,
  `flow_checker.zig:3388`; `serviceCall` at `:3280`). Probed with a secret and a
  credential, each of these holds today: `durable.signal`, `signalAt`, `step`,
  `run`, `queue.send`, `request`, `reply`, `cache.cacheSet`, `sql.sqlExec`,
  `ledger.post`, `workflow.call`, `workflow.follow`, `ratelimit.rateCheck`.
- The design so far defends on the read side: readers of stored data
  (`waitSignal`, `receive`, `cacheGet`, `sqlOne`, `sqlMany`) declare
  `.unknown`, so a handler that returns stored data loses the property.
  `CONCEPTS.md` treats a recorded secret as still a secret when replayed.
- A prototype added a `sink_args` field to bindings and a store sink kind. It
  refused 14 store probes for secrets and credentials and changed no example.
  With new rule rows (ZTS408, ZTS409), `policy_hash` moves and 16 of 19
  cassettes fail replay. With reused codes (ZTS406, ZTS405), replay holds and
  the full suite passes, but the messages name a fetch body.
- `workflow.call` declares its result `.external` (`workflow.zig:62`), which
  is neither `.unknown` nor derived from its arguments, so a sub-handler that
  echoes its input launders the label (observed).
- Store sinks inside a `durable.run` callback stay silent until the callee fix
  lands, so the store work depends on F1.

## 3. Constraints

- **K1 (census gate).** The probe census becomes a committed gate before any
  fix, so every later unit shows its effect as a change in verdict counts.
  Count per verdict, not per probe file. A fail-open row that remains needs an
  allowlist row that states its mechanism, and an unmatched row fails.
- **K2 (monotone toward refusal).** A unit may move a verdict from proven to
  refused or unproven. A move from refused to proven needs a stated reason in
  the commit and a clean control that shows the over-refusal was wrong.
- **K3 (probe method, AGENTS.md).** Each new sink path is probed by returning a
  labelled value directly (refused), then routing it through the new path
  (still refused). Assert the leak property itself, never a neighbor such as
  `deterministic`.
- **K4 (replay).** `test-expert-app -j1` after each unit. A unit that moves
  `policy_hash`, the binding catalog, or recorded diagnostic text joins the one
  batched re-record already approved as P2 of the boolean and arity plan.
- **K5 (proof-swallow).** `flow_checker.zig` is in the proof-swallow gate. No
  new discarded error without an allowlist row that states why it cannot
  weaken a verdict; prefer propagation.
- **K6 (evidence).** Unfiltered named steps; exit status read directly; a probe
  that must compile.

## 4. Units

**F0: commit the census as a gate, with expected verdicts.** Port the
generator and classifier into a Zig gate (no Python, no shell census). The
research classifier derived each cell's expected verdict from the handler-body
row, so a handler-body fail-open made a whole column read as held (credential
into an egress body was "held" in all 18 rows). The gate instead carries an
explicit expected-verdict table per (label family, sink), derived from the
documented promise, with a written reason for each held cell. Where the
promise and the implementation disagree (the promise for credentials names
only a response body or a log, `docs/proofs-and-receipts.md:76`, but the
implementation refuses credentials in an egress URL and headers), the table
records the decision Q6 makes. Count per verdict with a floor per column.
Record "no verdict" (a probe the parser or type checker refused, such as
ZTS050, ZTS105, or ZTS600) as its own class and assert it is zero, so a
refused probe never counts as a refusal of the leak. Rows: the 18 callee kinds
of the research, plus a module-level constant read in the handler, in a
helper, and captured by a closure; a 9-helper chain and a 9-parameter helper;
a callback that receives the secret from the callee (`apply(f)`) and the same
through a record method; taint introduced inside a recursion; a concise arrow
body that is a sink; a two-level import; `parallel` and `durable.run`
callbacks; and the research extras, each with the label it discharges named: `mask` with
a literal bound on a secret, `escapeHtml` on `user_input` into
`Response.html`, and `validateJson` on `user_input` into an egress body, all
inside helpers (each keeps the other labels, so a secret through them still
leaks); a return-path sink; a nested-expression sink). Today's verdicts are
the starting state; each later unit lowers the fail-open count and edits the
table.

**F1: sinks during summaries (part A).** Remove the early return in
`checkExprSinks`. Deduplicate diagnostics per (sink node, kind, label family),
so a secret and a credential through one helper both report; properties are
demoted for every leaking call regardless of deduplication. Bind the
parameters of a closure passed to an array method from the receiver's labels.
Report the call chain from a call-site stack beside the summary stack. Decide
the traversal of never-called functions explicitly: the handler walk enters
nested declarations structurally today, so F1 either keeps that walk with
unlabelled parameters (reports a sink only for labels it can see) or stops it
and relies on call-site summaries. The census decides which. Callbacks a module
invokes are checked through the closures they pass.

**F1b: an unresolved call fails closed even when discarded.** Every summary
exit that returns an unresolved result (`userCallLabels`,
`functionCallLabels`, `closureResultLabels`) also clears the sink-decided
properties, as `unknownRouteCallLabels` already does: unproven, no
diagnostic. Keep the known-global exemption. Bind a callee's function-typed
parameter to the closure passed at the call site, so `f(t)` inside `apply`
resolves and becomes a refusal instead of an unproven property.

**F1c: recursion to a fixpoint.** At an active-frame hit, compare the new
argument labels with the labels the frame's parameters were bound with. If
they are not a subset, re-walk with the union until it stops growing; the
label lattice is a small fixed set, so this terminates. Otherwise clear the
sink properties.

**V: invalidate artifacts proven by the old checker.** Add a flow-analyzer
version to the policy hash (or to the certificate), and bump it with F1, so a
certificate or warm proof cache from before the fix is refused and rebuilt.
`policy_hash` is shown to the model, so this joins the batched re-record. The
metadata hash pins (`scripts/check-meta-drift.sh:51`) and `policy-hash.txt`
(checked by `scripts/verify.sh:137`) are updated in the same commit; the
`proof_ratchet`, deploy-manifest, and report goldens move with it.

**G: module-level declarations carry labels.** Walk module-level declarations
before the handler and the route roots, so a `.global` read carries the labels
of its initializer. A `.global` read with no recorded labels carries
`.unknown` (fail closed). Add a learning under
`docs/solutions/security-issues/`: this and F2 are the "empty label set" class
again.

**F2: captured values resolve lexically (precise part B).** Resolve a captured
read against a stack of active declarations, the way the type checker does
(`type_checker.zig:2950-3030` scans the active declarations backward by name
within scope), not by a whole-file name union. An unresolved capture carries
`.unknown` (fail closed). Check: the name-union false positive from the
research (a clean `x` in a helper refused because the handler has a secret
`x`) stays held. This unit changes `durable_approval.ts` and
`examples/durable/approval.ts` per decision Q1.

**F3: declarations overwrite labels (part C).** A `var_decl` always writes its
labels, including the empty set.

**F4: HTML from unvalidated input as a summary fact.** Carry "HTML built from
unvalidated input" in the summary result, so the XSS check fires only when that
value reaches the response. Removes the 2 over-refusals.

**F5: return-path, concise-body, and nested-expression sinks.** Make the
return path, a concise arrow body (`=> fetch(...).status`, which
`functionCallLabels` reads with `inferLabels` only), and sub-expressions reach
`checkExprSinks`, in callees and in the handler body.

**F6: credential reads through any request binding.** Give the credential
label to `authorization` reads on any binding that carries the request, not
only the handler's own parameter. Closes the 12 credential rows.

**F7: cross-file helpers.** `importedFunctionLabels` returns the imported
walk's properties and diagnostics with its labels, and a per-parameter sink
summary (one walk per parameter with that parameter labelled, recording the
sinks it reaches) lets the importer apply its own argument labels at each call
site. This changes who owns the imported walk's diagnostics and how they reach
the importer's report, which the unit must design. Closes the 14 import rows.

**F8: the `workflow.call` echo.** Per decision Q5. Option (a) declares
`.unknown` in the results of `call`, `saga`, `fanout`, and `follow`, per the
AGENTS.md rule for exports that return a value some other execution produced.
This moves the binding catalog (replay, K4).

**F9: the promise for stores, queues, and other handlers.** Per decision Q3.
Under Q3 (a), F9 writes the exclusion into the documented promise
(`docs/proofs-and-receipts.md:75-76`, `flow_checker.zig:158`,
`contract_types.zig:624`, and the `Sink` entry in `CONCEPTS.md`) and nothing
else. Under Q3 (b), it adds a `sink_args`
binding field with a sink class, a store sink kind, the binding entries the
scope decision selects, and an entry for each new diagnostic kind in the
exhaustive `propertyTagForKind` (`flow_checker.zig:140`). Update the documented promise in
`docs/proofs-and-receipts.md:75-76`, the flow checker header
(`flow_checker.zig:158`), `contract_types.zig:624`, and the `Sink` entry in
`CONCEPTS.md`. Depends on F1, because the normal durable pattern puts the
calls inside a `durable.run` callback. The current promise text does not name
a log for secrets, but `secret_in_log` (ZTS402) refuses it; F9 adds the log
to the documented promise.

**F10: credentials in an egress body (added 2026-10-08 for Q6 (a)).** Add
the diagnostic kind `credential_in_egress_body` with a new rule row (ZTS408),
a `propertyTagForKind` entry (`no_credential_leakage`), a corpus case, and a
defect seed. Refuse a credential in a `fetch` body and an opaque init, as
ZTS406 does for a secret. Widen the credential promise in the same places as
F9. A new code follows the reasoning of Q4: a reused code names the wrong
sink. The rule row moves `policy_hash`, so F10 joins the batched re-record.

**F11: `mask` keeps `user_input` (added 2026-10-08, owner decision D1 (a)).**
F0 observed that `fetch(..., { body: mask(req.url, 4) })` proves
`injection_safe`: `mask` drops the `user_input` label as well as the secret
label, so unchecked request text reaches an egress call. Make `mask`
declassify only `secret` and `credential` (owner decision D2, 2026-10-08), and
keep `user_input` and every other label of its input. Add the census probe that F0 removed, expected refuse, and see it fail
first. Apply the AGENTS.md probe method: a declassifier must not launder a
label it was not asked to discharge. If the binding change moves the
binding catalog or `policy_hash`, F11 joins the batched re-record; otherwise
it lands with F4 to F9.

## 5. Order and verification

Order: F0, F1, F1b, F1c, F3, G, F2, F4, F5, F6, F7, F9, F11 (if it keeps
replay), then the units of the
boolean and arity plan that keep replay, then V, F8, F10, F11 (if it moves replay), and the
replay-moving units of that plan, then one re-record. F3 lands
before G and F2, because precise labels for globals and captures are only
meaningful once stale labels are gone. G lands before F2, because a captured
module constant needs module labels. V, F8, and F10 move what the model sees
and join the batched re-record.

Revised 2026-10-08 at dispatch: revision 2 put V with F1, so that no artifact
proven by the old checker survives the change. That would break replay for
every later unit of both plans, and `test-expert-app -j1` would stop being a
check for each unit. A later V adds no exposure: before V, old artifacts are
valid exactly as they are today. V must land before the re-record and before
any release.

Each unit: the census gate's new expected verdicts (written first, seen
failing on the old code), unit tests for the new paths, unfiltered
`zig build test-zts`, `test-precompile`, `test-diagnostic-corpus`,
`test-standin`, `test-contract-golden`, `test-proof-swallow`,
`test-expert-app -j1`, and the four hashes. Final: `bash scripts/verify.sh`.

## 6. Decisions for the owner

Answered 2026-10-08: Q1 (a), Q2 (a), Q3 (a), Q5 (a), Q6 (a). Q4 does not
apply, because Q3 is (a). The owner approved this plan. Sonnet subagents
implement the units in section 5 order, one commit per unit. The boolean and
arity plan follows. V, F8, and F10 join one batched DeepSeek re-record, which is
paid, so the main session confirms with the owner before it starts.

**Q1 (`durable_approval.ts` and `examples/durable/approval.ts`).** F2 makes
the `.unknown` label of `waitSignal`, read through a closure, reach the
response, so both lose `deterministic`, `idempotent`, and
`no_secret_leakage`.
Options: (a) accept the correct exposure and update the golden; (b) rule that
a value read inside a durable `run` and replayed counts as deterministic, which
needs its own design.
Recommendation: (a). The current verdict is a fail-open.

**Q2 (scope).**
Options: (a) F0 to F8 with F1b, F1c, V, and G in this plan, F9 per Q3; (b)
F0 to F6 now, F7 (cross-file) and F8 later.
Recommendation: (a). Every unit in it closes a proven property that is false.

**Q3 (the promise for stores, queues, and other handlers).** Today the read
side is fail-closed in-process: `waitSignal`, `receive`, `cacheGet`, `sqlOne`,
and `sqlMany` declare `.unknown`, so a stored value read back is unproven.
Options: (a) keep that design and write the exclusion into the documented
promise, so it says what it covers; (b) widen the promise to "no
secret-labelled value leaves the request": response, log, egress, persistent
store (durable, queue, cache, SQL, step results), or another handler, and make
each of those a sink.
Recommendation: (a) now, in this plan. It is sound today and needs no
re-record. Option (b) is a coherent wider promise, but only as a whole: making
signal and queue payloads sinks while cache, SQL, and step writes stay open is
not a principled line. The first draft recommended that partial line; the
review corrected it.

**Q4 (diagnostic identity, only if Q3 is (b)).**
Options: (a) new codes with rule rows, a corpus case, and a defect seed each,
which moves `policy_hash`; (b) reuse ZTS406 (a secret in a fetch body) and
ZTS405 (a credential in a fetch URL), whose messages name the wrong sink.
Recommendation: (a). A message that names the wrong sink teaches the wrong
repair, and V moves `policy_hash` anyway.

**Q5 (`workflow.call`).**
Options: (a) declare `.unknown` in the results of `call`, `saga`, `fanout`,
and `follow` (closes the echo); (b) also make the `init` argument a sink;
(c) resolve the sub-handler through the system catalog, as `callTool`
resolves its route functions, and carry labels across.
Recommendation: (a) now. A gap remains: the sub-handler receives the secret as
its own request, labels it `user_input`, and may log it with
`no_secret_leakage` proven in both files (reasoned from the binding and the
census, not probed; it needs a system bundle). Decide (b) or (c) together
with Q3 (b).

**Q6 (the credential promise for egress).** The documented promise names only
a response body or a log (`docs/proofs-and-receipts.md:76`); the
implementation also refuses credentials in an egress URL and headers, but not
in an egress body.
Options: (a) widen the promise to all egress and refuse the egress body too;
(b) narrow the implementation to the documented promise.
Recommendation: (a). A credential sent to a third party in a request body is a
leak by any reading.

## 7. Review record

Fable reviewed revision 1 on 2026-10-08 with 30 probes against the base and
prototype binaries. Applied: module-level globals (blocker, new unit G),
unresolved discarded calls (F1b), recursion fixpoint (F1c), the porous census
classifier (F0 expected-verdict table), invalidation of old artifacts (V), the
deduplication key, the concise arrow body (F5), and the revised Q3 and Q5.
Probes that held correctly: Result values, match-arm bindings, `join` and
`reduce` in helpers, a generic identity, `for ... of`, and record field
assignment; string `+` is refused by ZTS105, so it cannot launder.

## 8. Other findings

- `const ok = durable.signal("k", "n", token); return Response.json({ ok })`
  gives ZTS400 on a boolean: durable exports union their eager-argument labels
  into the result (over-taint, observed).
- ZTS305 ("declared variable is never used") fires on a variable used only
  inside a closure, such as one passed to `durable.run` or returned from a
  nested arrow (observed in two probes and in the capture probe above). It is a
  separate defect in the handler verifier's reference counting
  (`handler_verifier.zig:1322`), which the flow fixes do not repair.
- `durable_dead_runs_cli.zig:170` prints a dead-run record verbatim. Whether
  that record holds step values that may be secrets is not checked.

Codex astra fact-checked revision 1 on 2026-10-08. Applied in revision 2: the
early-return line range; `listedToolRouteLabels` as a fifth summary walker;
the structural walk of nested declarations (F1 now decides that traversal);
capture reads that collide with an inner parameter's key; the type checker's
backward name scan; route and listed-tool request bindings; `serviceCall` as
an egress sink; the history of `666b8a18`; route-function sink tests; the
ZTS405 and ZTS406 meanings; the label each sanitizer control discharges; the
metadata pins that V updates; F7's diagnostic ownership; `propertyTagForKind`
for new kinds; and ZTS305 as a separate handler-verifier defect.
