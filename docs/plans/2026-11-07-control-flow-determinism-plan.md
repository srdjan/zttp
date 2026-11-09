# Control-flow determinism: a branch on a value that varies between requests must clear `deterministic`

Fable found this defect on 2026-11-07, during the review of the default-profile ZTS606 plan (`2026-11-07-default-profile-zts606-plan.md`, finding F1). Under Decision 7 (a) of that plan, Opus probed it at HEAD and wrote this plan while U1 of that plan ran. Fable checked its argument and Codex astra checked its facts; "Review findings" lists each finding and its resolution. Decision 3 needs the owner, because the fix changes a recorded DeepSeek case. The owner did not answer the decision question within 60 seconds on 2026-11-07. Under "keep going", Opus started only U0, which commits nothing and is part of both "Accept all" and "Measure first". After U0, the owner approved Decision 3 (a) on 2026-11-07. Decisions 1, 2, and 4 had no answer within 60 seconds, so Opus took the recommended options 1 (a), 2 (a), and 4 (a). U1 and U2 run in the scratch worktree `/tmp/zttp-g4/wt-det`, based on local main, because U2 of the default-profile ZTS606 plan uses the main tree at the same time. Opus moves the result to local main before the re-record.

## Status

| Unit | Status |
|---|---|
| U0 | Done on 2026-11-07, no commit: see "U0 results" |
| U1 | Implemented in the scratch worktree and reviewed by Opus. The implementer gate run from an empty cache: 16 of 18 steps and `check-spine` exit 0; `test-expert-app` and `test` fail only on the jwt-auth replay (1 of 3585 tests). No commit until the re-record |
| U2 | Implemented in the scratch worktree (option (a') of Decision 2), with U2b, the review fixes of U3. The Opus gate run from an empty cache: 20 of 21 steps and `check-spine` exit 0; `test-expert-app` and `test` fail only on the codegen replay, where all 11 recorded cases diverge because the policy hash and the diagnostic text changed. No commit until the re-record |
| U3 | In progress: reviews, probes, repair check, and the first mutants done; see "U3 results" |

## Reproduction

Observed on 2026-11-07 at `6af15c69` with the Debug build at `/tmp/zttp-g4/out`. The probes are in `/tmp/zttp-g4/probes/det/` and `/tmp/zttp-g4/probes/pA8c/`. Unless the row says otherwise, each handler declares `Proof<Response, "deterministic">` and reads `const t = Date.now();`.

| Probe | Shape | `deterministic` | CHECK |
|---|---|---|---|
| s1 | `if (t % 2 === 0) { return Response.text("even"); } return Response.text("odd");` | PROVEN | 0 errors |
| s2 | `Response.text(t % 2 === 0 ? "even" : "odd")` | PROVEN | 0 errors |
| s4 | `match (t % 2) { when 0: "even" default: "odd" }` into the response | PROVEN | 0 errors |
| s5 | `for (const i of range(t % 3)) { parts.push("x"); }`, then `parts.join("")` | PROVEN | 0 errors |
| s6 | `if (Math.random() > 0.5)`, two texts, no `Date.now()` | PROVEN | 0 errors |
| s7 | the branch chooses status 201 or 200 | PROVEN | 0 errors |
| s13 | `let s = "even"; if (t % 2 === 1) { s = "odd"; }` into the response | PROVEN | 0 errors |
| s15 | `assert t % 2 === 0;`, then `Response.text("ok")` | PROVEN | 0 errors |
| s17 | `dep.ts` exports `pick()`, which branches on `Date.now()` and returns "a" or "b"; the handler returns `Response.text(pick())` | PROVEN | 0 errors |
| s17, handler2 | `dep2.ts` exports `stamp()`, and the handler branches on `stamp() % 2 === 0` | PROVEN | 0 errors |
| s18 | `const r = rateCheck("k", 5, 60); if (r.ok) { ... "ok" } ... "slow down"` | PROVEN | 0 errors |
| s19 | `const v = cacheGet("ns", "k"); if (v === undefined) { ... "miss" } ... "hit"` | PROVEN | 0 errors |
| s11 | s1 under `Proof<Response, "deterministic" \| "idempotent" \| "retry_safe" \| "read_only">` | all four PROVEN | 0 errors |
| p_modinit (Fable) | `const SEED = Date.now() % 2 === 0 ? "a" : "b";` at module top, and the handler returns `Response.text(SEED)` | PROVEN | 0 errors |
| p_call_after_branch (Fable) | a branch on `t`, then `s = pick(req)` where `pick` has two returns, then `Response.text(s)` | PROVEN | 0 errors |
| p_map_branch (Fable) | the `if` on the clock is inside a `.map` callback that returns constants | PROVEN | 0 errors |
| p_recurse (Fable) | `if (n === 0)` in a helper with two returns, called with `t % 3` | PROVEN | 0 errors |
| jwt-auth (recorded DeepSeek case) | `const verified = jwtVerify(token, secret); if (!verified.ok) { ... 401 }` under `Guard<T> = Proof<T, "deterministic" \| "state_isolated">` | PROVEN, and `idempotent` PROVEN | 0 errors |

Controls, refused at HEAD as they must be:

| Probe | Shape | Result |
|---|---|---|
| s10 | `Response.text(String(t))` | `deterministic` not proven, ZTS500 |
| s9 | `const b = t % 2 === 0 && true;` into the response | `deterministic` not proven, ZTS500 |
| s18b | `Response.text(String(r.ok))` after `rateCheck` | `deterministic` not proven, ZTS500 with no "demoted at" cause |
| jwt value | `Response.text(String(jwtVerify(token, "s").ok))` | `deterministic` not proven, ZTS500 |
| s8 | the entry helper `late()` returns `Date.now() % 2 === 0`, and the handler branches on `late()` | `deterministic` PROVEN on the handler, but ZTS606 refuses `late` |
| s16 | the entry helper `pick()` branches on `Date.now()` and returns "a" or "b" | `deterministic` PROVEN on the handler, but ZTS606 refuses `pick` |
| s12 | s16 with `Proof<string, "deterministic">` on `pick` | the helper capsule fails, ZTS500 |

Fable also found these shapes refused at HEAD by the explicit rule: `filter`, `find`, `some`, `reduce`, a `toSorted` comparator, `slice(0, t % 5)`, `repeat(t % 3)`, `padStart(t % 5)`, `includes(String(t % 2))`, and `range(t % 3).length`. A branch on request data keeps `deterministic`: `requestJson(req).ok`, `requestText`, `req.headers.get`, `req.url.split`, `req.method`, and `Object.keys(o).length` carry no `unknown` label.

Shipped artifacts, from Opus's own command output on 2026-11-07 (the retained logs do not hold the exit status or the response bodies):

- s17: `zttp compile --no-attest` printed "zttp compile exit=0", and the binary embeds `"deterministic": true`.
- pA8c (s1 under `Proof<Response, "deterministic" | "read_only">`): `zttp compile --no-attest` printed "compile exit=0". The binary logged "Proof accepted: weakest edge trusted, 3 disclosed edge(s)". 30 requests gave 17 "even" and 13 "odd".
- Fable's PR gate probe: a change from a branch on `req.url.length` to a branch on `Date.now()` gives "Verdict: `equivalent`", with `pure` as the only lost proof.

The run cache does not depend on this claim today. `docs/verification.md` says that the shipped production policy accepts neither `deterministic` nor `read_only`, so response memoization is off (`servingSettings` in `packages/runtime/src/server.zig`). Two clean handlers under `Proof<Response, "deterministic" | "read_only">` also logged no "Proof cache: enabled" line.

## Cause

`deterministic` on the handler is a flow property. `packages/zts/src/flow_interp.zig#FlowInterp` clears it in `finishHandlerReport` when a value that reaches the response carries the `nondeterministic` or `unknown` label, and when `result.cleared` is true (an unsupported construct or a budget limit). At a control decision, the interpreter evaluates the condition and drops its value (`_ = try self.eval(s.condition, st)` for `if` and `assert`). A ternary joins the two branch values and not the condition. A loop count does not label the loop body. So a response that a varying value selects carries no label.

Decision D9 of the flow redesign made `no_secret_leakage` track explicit flow only, and `docs/verification.md` discloses that under "Implicit flow". Nothing discloses the same limit for `deterministic`. For `deterministic` the trade-off is different: a response that a branch on the clock selects is not deterministic by definition.

Helpers of the entry file are covered by a coarser rule. A helper's capsule facts come from its effect row (`packages/zts/src/effect_inference.zig`), which clears `deterministic` when the helper reaches a varying source, except a varying read that a discarded write-effect call consumes (`sinks_the_read`). So s12 fails its own capsule, and s8 and s16 get ZTS606. A function in a dependency gets no ZTS606 (`packages/tools/src/precompile_contract.zig#dischargeDependencyCapsules` keeps ZTS606 entry-only), so s17 has no such guard.

`idempotent` is `deterministic and retry_safe`. `packages/zts/src/pipeline.zig#projectFlowProperties` ANDs the flow fact into the contract and derives `idempotent` right after it, and `packages/tools/src/precompile_contract.zig#foldDependencyProperties` derives it again after the dependency fold. The initial builder properties (`packages/zts/src/contract_builder.zig#ContractBuilder`) are not final: the refresh discharges against the final ones.

## What already exists

- The labels. `nondeterministic` comes from the clock and RNG builtins and from each export whose binding declares a varying capability (`packages/zts/src/module_binding.zig#capabilityVaries` and `#exportVaries`, applied in `FlowInterp.evalExportValues`). So `rateCheck`, `jwtVerify`, and `ulid` return values labelled `nondeterministic`, though their bindings declare only `internal`. `unknown` comes from persistent and cross-call reads such as `cacheGet`, and from `Value.top`. The explicit rule already treats both as varying.
- The state. `packages/zts/src/flow_value.zig#State` holds `reachable`, `env`, `heap`, `top_cell`, and `path`. Each site that copies, joins, or builds a state does it field by field: `cloneState`, `joinStates` (which resets `path` when the two sides differ), `heapOnly`, `stateEql`, `joinSummary`, `summaryEql`, and in `FlowInterp` `heapState`, `takeSummary`, `runCallbackLoop`, `recurse`, `runBody`, `projectPersistent`, `runActivation`, `finish`, and `summarize`. `analyzeHandler` sets `entry.path = initial_path`. `PathEvidence` cannot hold the flag, because these sites reset it.
- The sink events. `observeResponse` gets the completion state, but `packages/zts/src/flow_rules.zig#SinkEvent` stores the flow and the path evidence, not the state.
- `deterministic` is a disclosed edge: the acceptance kernel accepts it on the producer's word (`packages/proof-checker/src/proof_system.zig#Property`, `consumerChecked` is false for it). So no kernel rule protects it.
- The PR gate classifies a lost `deterministic` or `idempotent` as a warning (`packages/zts/src/contract_diff.zig#loss_severity_rows`), so after the fix Fable's gate probe lists the two lost proofs and can still exit 0 with `equivalent`.
- The corpus. Codex astra searched the 13 recorded DeepSeek cases, the stand-in seeds, the 149 diagnostic corpus sources, the contract fixtures, the flow census probes, and the 33 examples. One recorded handler changes: jwt-auth (above). Its expected handler and its proposal in `responses/6.jsonl` hold the same source. The two `modules_all.ts` handlers branch on `jwtVerify(...).ok` too, but they already fail `deterministic` and `idempotent`, so their text does not change. Fable counted 0 over-reports in `examples/` and `tests/corpus/check/good/` under option (a) and under option (c), and found that the recorded log-timestamp case (reads `Date.now()` and only logs it, under a capsule that demands `deterministic`) keeps its proof under (a) and loses it under (c).
- The replay compares payload hashes, and receipt property snapshots hold `deterministic` and `idempotent` (`expectEvent` in `packages/pi/src/simulator/runner.zig`, and `packages/pi/src/simulator/observation.zig#digestReceiptPayload`). The jwt-auth proposal is accepted at HEAD and refused after the fix, so its replay diverges. A re-record is whole-corpus, and it belongs to the owner.

## Decision 1: the rule

Option (a), recommended: a sticky `varying_control` field on `State`, not in `PathEvidence`.

- Set: at each control decision whose operand carries `nondeterministic` or `unknown`, on every successor state. For a record or array `match`, the operand is each tested field and element, read through the pattern. The decisions are `if` (with and without `else`), the ternary, `match` (literal, record, nested, array, and type-test patterns, the default arm, and the implicit no-match state), `assert` (the continuing state and the failure completion), the iterable of `for...of` (set before the loop head, kept on the zero-iteration exit, on `break`, `continue`, and early returns), `&&`, `||`, `??` and the logical compound assignments, optional property access and optional calls (the skipped state), default parameters, the selection of a function value or a property-call target, router selection, and every callback loop of a builtin (`map`, `forEach`, `Array.from`, `filter`, `find`, `some`, `every`, `findIndex`, `reduce` with its initial-accumulator choice, `toSorted` comparators, `dictMapValues`, `dictFilter`, `dictFold`, `mapResult`, `mapError`, `andThen`, `orElse`, and the generic callback path of `evalExportValues`), where the callback count or the predicate is the operand.
- Keep: `cloneState` and `heapOnly` copy it. `joinStates` ORs it. `stateEql` compares it, so a loop or recursion fixpoint does not converge before the flag grows. `heapState`, `runBody`, and `recurse` carry the caller's flag into the callee. `takeSummary` and `runCallbackLoop` OR the callee's flag into the caller. `projectPersistent` and module initialization keep it: a flag set during the module initialization of the entry file or of a dependency reaches the handler's entry state (p_modinit). Nothing clears it on a path.
- Report: `SinkEvent` gets a separate control field, which `observeSink` copies and ORs when it merges events. `finishHandlerReport` clears `deterministic` for a `.response_other` event with the field set. The field is never a data label, so `no_secret_leakage` and the other flow properties do not change (D9 stays).

The flag stays set after the join so that s13 is caught: `s` holds "even" or "odd" after the join, and neither value carries a label. The cost is an over-report: a branch on a varying value that does not change the response clears `deterministic`. Examples: a branch that only logs, and `assert t > 0;` (p_assert_sanity), where the 500 response is chosen by the clock. Fable counted 0 such handlers in `examples/` and `tests/corpus/check/good/`.

Option (b): a label on values. Each value created under the flag gets `nondeterministic`. This is finer, but it touches every value constructor, and it must not reach the secret rule.

Option (c): the effect-row rule of helpers also for the handler. `deterministic` holds only when the handler reaches no varying source. It also refuses the recorded log-timestamp case, so a second recorded case drifts.

Option (d): disclose only, as D9 does for secrets. The false proof stays, and so does the false claim in the recorded jwt-auth case.

## Decision 2: the cause and the text

At HEAD, a ZTS500 for `deterministic` names the call that made the value varying, for example "demoted at line 2:14 by `Date.now()`", and the suggestion says to remove `Date.now()`, `Math.random()`, and `performance.now()` "from the response path". For a source labelled by its binding, such as `rateCheck`, the row has no cause, and the suggestion still names the three builtins (s18b).

Option (a), recommended:

- The flag carries the first decision that set it: the module, the node, and the source call of its operand. The cause names the branch line and column, in the dependency file when the branch is there.
- The text names what is known, that the response follows the branch, not that it depends on it: "the response at line {L} is reached through a branch at line {B} on a value from `{source}` (line {S}), which varies between requests. Declare a capsule without `deterministic` and `idempotent`, for example `Proof<Response, {holds}>`, or move the varying read so that no branch on it precedes the response." `{holds}` is the set the handler holds, as the default-profile suggestion builds it.
- A value cause wins over a branch cause, so s9 and s10 keep their HEAD text.
- The suggestion for a value cause with a binding source, as in s18b, names that source call and not the three builtins.

Fable's repair check at HEAD: s1 under `Proof<Response, "read_only">`, s18 under `"cost_bounded"`, and s19 under `"retry_safe"` each give 0 errors, and the fix changes only `deterministic` and `idempotent`, so these stay clean.

Option (b): no cause, and the generic "not discharged" text.

### Decision 2, revised on 2026-11-07

Opus found during the review of U1 that option (a) cannot name the source call. `packages/zts/src/flow_value.zig#Flow` holds its labels as bits, with no source. The cause "demoted at line 2:17 by `Date.now()`" comes from a syntactic scan in `packages/zts/src/contract_builder.zig#ContractBuilder` (`nondeterministic_cause`). That scan takes a varying builtin read in the handler file, which need not be the read that the branch tests. The owner did not answer the revised question within 60 seconds, so Opus took the recommended option (a'):

- Option (a'), taken: the flag records the first control decision that set it: the module and the node. A join keeps the smaller (module, node) pair, so the choice is deterministic and a fixpoint still converges. When the flow clears `deterministic` only through the flag, the contract's `deterministic` cause names that branch, with its line, column, and file. When a labelled value reaches the response, the syntactic cause stays, so s9 and s10 keep their HEAD text. The syntactic scan also learns each module export whose binding varies (`packages/zts/src/module_binding.zig#exportVaries`), so s18b names `rateCheck`. The text names the kinds of source, not the exact call.
- Option (b): add a source node to `Flow`, so that the text names the exact source call. This changes every flow combination and needs timing and mutants.
- Option (c): no new cause. The suggestion for s1 keeps "remove Date.now() ... from the response path", which does not describe a branch.

The U2 tests below follow option (a').

## Decision 3: the corpus (the owner decides)

The fix changes the recorded jwt-auth case: its accepted proposal becomes a ZTS500 for `deterministic`, so the replay of `zig build test-expert-app` and the simulator diverges. This is correct, because the handler's response depends on the token's expiry time. A partial re-record cannot be promoted, so the owner re-records the whole DeepSeek corpus.

Option (a), recommended: U0 to U2 run on local main up to the point of the commit. The replay failure of jwt-auth is the only failure allowed, and U0 confirms that it is the only one. Then the owner runs the recorder on the whole corpus. Opus commits the analyzer change and the new recordings in the order that the recorder requires, and republishes the convergence and coverage evidence offline. No commit leaves the replay red.

Option (b): fix the analyzer and leave jwt-auth on its old recording, with a replay exception. This needs a new exception mechanism and keeps a false claim in the evidence.

Option (c): Decision 1 (d), disclose only, and no re-record.

## Decision 4: execution

Option (a), recommended: U0 (measurement, no commit), then U1 (the rule), U2 (the cause and the text), and U3 (docs, adversarial review, and empirical validation). A Sonnet implementer does U0 to U2. Opus reviews each diff line by line and reruns the gates from an empty private cache. Commits wait for the re-record of Decision 3. Nothing is pushed.

## Units

| Unit | Model | Files | Acceptance | Turn budget |
|---|---|---|---|---|
| U0: prototype the rule in a scratch worktree from local main, and measure | Sonnet | worktree only, no commit | the list of every test, golden, census row, corpus case, and recorded transcript whose result changes, with the old and new value; the over-report count over `examples/` and `tests/corpus/check/good/` | 60 |
| U1: the rule (Decision 1) | Sonnet | `packages/zts/src/flow_value.zig`, `packages/zts/src/flow_interp.zig`, `packages/zts/src/flow_rules.zig`, tests | U1 tests; the 18 gates and `check-spine`, with the jwt-auth replay as the only failure | 90 |
| U2: the cause and the text (Decision 2) | Sonnet | the cause path from the flow report to `packages/zts/src/spec_discharge.zig`, tests | U2 tests; the same gates | 60 |
| U3: docs, review, validation | Opus, with Fable and Codex astra | `docs/verification.md`, `docs/proofs-and-receipts.md`, this plan | "U3 validation" | none |

### U0 results

U0 ran on 2026-11-07 in the scratch worktree `/tmp/zttp-g4/wt-det` at `6af15c69`, with a private empty cache and no provider key. The prototype changes `packages/zts/src/flow_value.zig`, `packages/zts/src/flow_rules.zig`, and `packages/zts/src/flow_interp.zig` (114 lines added, 9 removed). Nothing is committed. Logs and tables are in `/tmp/zttp-g4/det-u0-logs/`.

- Probes: every row of the first "Reproduction" table flips to not proven, with one ZTS500 under the default profile. Each repair-check probe (`p_fix_s1`, `p_fix_s18`, `p_fix_s19`) gives 0 errors. The controls and each branch on request data (`p_env_branch`, `p_hdr_branch`, `p_reqjson_branch`, and the value probes) keep their HEAD values. `no_secret_leakage` does not change on a secret-guess control or on a clock-branch probe.
- Gates: 14 of the 16 named steps exit 0. `test-expert-app` fails only on the predicted jwt-auth case: "codegen baseline replays at the committed first-attempt green rate" reports `RuntimeIntentPinMismatch` (pinned pass true, measured pass false), with 964 of 966 tests passed. `test-proof-swallow` fails on the new `else => return false` in the prototype's `patternVaries`. No test, golden, or census row asserted the false `deterministic` or `idempotent`.
- Over-report: 1 of 63 tracked `.ts` files in `examples/` and `tests/corpus/check/good/` changes. The plan predicted 0. `examples/routing/guard-flow.ts` loses `deterministic` and `idempotent` with 0 errors, because it declares only `state_isolated` and `injection_safe`. Opus reran it with both binaries. It branches on `jwtVerify(...).ok` and returns 403 or the success response. `jwtVerify` reads the clock for expiry, so the same request can get a different status at another time. Opus judges it a true positive.
- Timing: the 149 corpus files took 4 s in total over 3 rounds with each Debug binary, at a load average near 5. The loop had a resolution of 1 s, so this needs a finer measurement in U3.
- Open items for U1:
  - Give the `patternVaries` switch an `// exhaustive:` reason or a handled list, for `test-proof-swallow`.
  - Test a varying branch placed after the response sink. `projectPersistent` keeps the flag, so a sink event of the second pass can carry a flag that a later branch set. This possible over-report is not measured.
  - Check the recorded log-timestamp handler, which must keep `deterministic`. U0 did not run it.
  - Confirm the flips of `p_header` (a clock-chosen header value) and `p_holder` (a clock-chosen heap cell).
  - Probe the decisions that U0 implemented but did not observe: `&&` and `||` as statements, `||=` and `&&=`, the optional call, `dictFilter`, `andThen`, and `forEach` over `range`.
  - U0 skipped the initial-accumulator choice of `reduce`. The callback count covers an empty receiver. U0 did not set the flag from the callback results of `map`, `forEach`, `Array.from`, and `dictMapValues`, because those results are data.

### U1 tests

Each regression fails at HEAD for the reason of the gap. Each control passes before and after. Each expected value is a literal.

1. Regressions in CHECK under `Proof<Response, "deterministic">`: s1, s2, s4, s5, s6, s7, s13, s15, s18, s19, p_modinit, p_call_after_branch, p_map_branch, p_recurse, a record `match` whose tested field is varying, an optional call on a varying optional, and a `filter` callback that branches on the clock. The graph compile of s17 and of handler2 gives the same.
2. Regression: s11 proves `retry_safe` and `read_only`, and it does not prove `deterministic` or `idempotent`.
3. Controls: s10, s9, and s18b keep their ZTS500. A branch on `requestJson(req).ok`, on `req.headers.get("x")`, on `req.url.length`, and on a constant keeps `deterministic`.
4. Control: `no_secret_leakage` on `if (secret === guess)` with two responses stays proven (D9).
5. Control: pE3 of the default-profile plan (the clock value is read and not used) and the recorded log-timestamp handler keep `deterministic`.
6. The flow census (`zig build test-flow-census`) and the contract goldens: the commit message lists each changed row with its old and new value.
7. The PR gate test "run: a default-profile handler that branches on a clock helper still exits 2" of the default-profile ZTS606 plan changes: the handler then fails `deterministic` itself, so its ZTS500 row names the property, the marked ZTS606 row is accepted, and the gate gives a verdict. The test changes to that verdict, and the commit message says why.

### U2 tests

These follow Decision 2 as revised, option (a').

1. s1: the message suffix names the `if` at its line and column, with the snippet "a branch on a value that varies between requests". The suggestion is the branch text: "the response is reached through a branch on a value that varies between requests, such as a clock, random, rate-limit, cache, or token read: declare a capsule without `deterministic` and `idempotent`, or move the varying read so that no branch on it precedes the response."
2. s17: the cause names `dep.ts` and the line of the branch in it.
3. s18 and s19: the cause names the branch on `r.ok` and on `v === undefined`. At HEAD these rows have no cause.
4. s18b: the value cause names `rateCheck` with its line, and the suggestion names `rateCheck`, not the three builtins.
5. A handler with no capsule that branches on the clock (Fable's p_default_branch): the default-profile ZTS500 says "does not hold: deterministic, idempotent, pure".
6. Controls: s9 and s10 keep their HEAD message and suggestion, because a value cause wins. pE3 and the log-timestamp handler keep `deterministic`.

### U3 validation

1. Fable and Codex astra review the diffs with split briefs.
2. Every probe of "Reproduction" on `zts check`, `zts compile`, `zttp compile --no-attest` (with the embedded contract), `zttp dev`, and `zttp proofs gate`. Add Fable's probes from the default-profile ZTS606 U3 review (`/tmp/zttp-g4/u3-fable/p/`): h6 (a clock read in a nested function declaration, then a branch on it), h8 (an arrow in an object holder), and h7b (an inline arrow passed to a helper). At `bad93c63` each keeps `deterministic` with a branch on the clock value, and the nested call is treated as an unknown call. Confirm that each flips.
3. The repair check: apply each remedy that a new text names, run CHECK again, and confirm that the ZTS500 is gone and the declared capsule holds.
4. Mutants on each control decision of Decision 1 and on each state site that keeps the flag. Give each survivor a test, or record why no test can kill it.
5. Timing of `zts check` on the corpus before and after.
6. `bash scripts/verify.sh` from an empty cache, after the re-record.
7. Docs: `docs/proofs-and-receipts.md` says "The `deterministic` and `idempotent` facts of the handler ignore a branch on a clock value" in the paragraph on a ZTS606 row under the default profile. After U1 this is false: rewrite that sentence, and say that a ZTS606 row for `deterministic` is now accepted when the handler branches on the clock value.

### U3 results

Opus, Fable, and Codex astra reviewed U1 and U2 on 2026-11-07. The binaries are `/tmp/zttp-g4/out-det` (the U1 and U2 diff on `0d1b18ab`) and `/tmp/zttp-g4/out-u3` (`bad93c63`, the same flow code as the base). Opus's probes and ledger are in `/tmp/zttp-g4/det-u3-opus/`, and Fable's are in `/tmp/zttp-g4/det-u3-fable/p/`.

- Surfaces (Opus): 13 probes of "Reproduction" that the old binary proves now get a ZTS500 with the branch cause, or with `rateCheck` at 4:13 for s18b. On s1, `zts check` and `zts check --json` exit 1, the JSON trace says "The response is reached through a branch on a value that varies between requests" at 3:3, `zttp compile --no-attest` writes no binary, the compile contract holds `deterministic` false with the ZTS500 row, and `zttp dev` refuses in its preflight. s3, s9, s10, and s14 do not change. h6, h8, and h7b flip (Fable).
- Repair check (Opus and Fable): the capsule that the default-profile ZTS500 suggests gives 0 errors on 11 of 11 default-profile probes. A capsule without `deterministic` and `idempotent` gives 0 errors on s11, r01, r05, and g04. Removing `rateCheck` from s18b gives 0 errors. A response built before a branch and returned after it still fails, so the text now says "precedes the return of the response" (F8).
- Over-report (Opus and Fable): 1 of the 63 tracked files of `examples/` and `tests/corpus/check/good/` changes. `examples/routing/guard-flow.ts` loses `deterministic` and `idempotent`, because its response follows a branch on `jwtVerify`, which reads the clock. Its capsule declares neither, so it keeps 0 errors.
- D9 (Fable): no probe and no census file changes a property other than `deterministic` and `idempotent`, over 78 U1 probes, 45 earlier Fable probes, 19 "Reproduction" probes, and 60 new probes.

| Finding | Reviewer | Resolution |
|---|---|---|
| G1, blocker | Codex astra, confirmed by Opus | `for...of` over an array whose length `splice` set from the clock kept `deterministic` (probe c1). `execForOf` read the top-level flow only; the callback loops read the deep flow. U2b. |
| G2, blocker | Codex astra, confirmed by Opus | A `toSorted` comparator over `range(Date.now() % 4)` that writes an outer array kept `deterministic` (c6b). U2b. |
| G3, blocker | Codex astra, confirmed by Opus | `routerMatch` on a request whose url the handler set from the clock kept `deterministic` (c2b). Decision 1 names router selection. U2b. |
| Selection by a varying value | Codex astra | Not reproduced: the profile refuses dynamic computed access (ZTS605), `.at` on an array of functions, and `f?.()`. A varying selection of a function needs a control decision, which marks. |
| O1, should-fix | Opus | `flow_analyzer_version` stayed 9 although the `deterministic` verdict changed. U2b raises it to 10. The policy hash moves, which the whole-corpus re-record covers. |
| O5, should-fix | Opus | A discarded `rateCheck` or `fetch` before a `Date.now()` that reaches the response took the cause (o8, o9). Decision 5 (a), U2b. |
| O6 and F2, should-fix | Opus, Fable, Codex astra | The JSON trace said "`fetch` reads a clock or RNG". U2b gives an export its own text, and one classifier serves the three surfaces. |
| O2, should-fix | Opus, Codex astra | The live-reload preview gave the three-builtins text for an export cause. U2b. |
| F3, should-fix | Fable | A record pattern field that only binds a varying value counted as a test (n01). U2b tests only a literal, a type test, or a nested pattern. |
| F1, should-fix | Fable | A value from a local dependency keeps the three-builtins text with no line (g03). Not a regression. Decision 6 (a): recorded as a gap. |
| F4, F5, F6 | Fable | Over-reports of the sticky mark (c11, n04, c10b) and a branch cause that hides a write (d_carry). Accepted under Decision 1 (a); recorded as gaps. |
| F7, F8 | Fable | The branch text now names a network read and "the return of the response". U2b. |
| C8 | Codex astra | The cause scan names the log exports. Decision 5 (a) puts a builtin read first; the rest is recorded as a gap. |
| O4, C9, C11, O7 | Opus, Codex astra | A misplaced doc comment, "labelled" for "varying" in three comments, a stale count of owned allocations, and a loop inside two tests. U2b. |
| Docs | Opus, Codex astra | `docs/proofs-and-receipts.md` lines on the `deterministic` chip, the hint catalog, and the ZTS606 paragraph. Opus. |

U2b results (Opus, with the binaries `/tmp/zttp-g4/out-det2` built from the worktree after U2b):

- Probes: c1, c6b, and c2b are now refused. o8 and o9 name `Date.now()` at 5:17 and 5:35 with the builtin text, as before U2. n01 keeps `deterministic`. Every other probe of U1, U2, and U3 gives the same verdict and cause as before U2b. Two new over-reports are in the accepted class: c1d (a loop over a one-element array whose element varies, because the count rule reads the deep flow, as the callback loops already did) and c2 (a route choice on a varying url that cannot match).
- m1 (a return in a loop that the mark reaches only on the second pass) and m2 (two arms with different sites) were proved by the binary before this plan. Both are now refused, and both are CHECK rows. m3 (a loop pass that changes only the mark) came from the mutants below and is a CHECK row too.
- D9: over 297 files (the 63 tracked files and every probe set), no property other than `deterministic` and `idempotent` changes between `out-u3` and `out-det2`.
- Over-report: still 1 of 63 tracked files, `examples/routing/guard-flow.ts`.
- Repair check: the same result as before U2b, and c1, c6b, and c2b clear with a capsule without `deterministic`.
- Gates (Opus, empty cache, unfiltered): `test-zts`, `test-zts-cli`, `test-precompile`, `test-flow-census`, `test-contract-golden`, `test-expert-golden`, `test-agent-protocol`, `test-diagnostic-corpus`, `test-standin`, `test-cli`, `test-zruntime`, `test-proof-swallow`, `test-zts-layering`, `test-module-boundary`, `test-bytecode-identity`, `smoke-v1`, `test-meta-drift`, `test-examples`, and `check-spine` exit 0. `test-expert-app` and `test` exit 1 on one test, "codegen baseline replays at the committed first-attempt green rate" (3600 of 3606 tests pass in `test`, 5 skipped). The R7c census has 0 differences.

Mutants (Opus, `/tmp/zttp-g4/dmut-logs/`, each against an unfiltered named step in a worktree with the final diff):

- U2b code, E01 to E11: all 11 are killed by the new tests (`test-precompile`, `test-zts`, and `test-cli` for the preview text).
- Survivors of the first run, retried on the final diff: D24f (the join keeps the larger site) is killed by m2.
- D02f (`stateEql` does not compare the site) survived m1, because every branch in a loop body is reached on the first pass. The flow analysis does not decide `0 === 1` (probe lit.ts). A first m3 row with a write in the loop body did not kill it either. The m3 row now has a loop that reaches a helper only on its second pass, and the branch in the helper changes nothing but the mark. The D02f binary proves that handler, and the final binary refuses it at 6:5. The binary before this plan proves it too.
- D18f (a repeated sink event does not take the site of the later observation): equivalent. `samePath` merges two events only when both paths are complete. A loop marks its path incomplete, and the handler body runs on a complete path only in the first persistent pass, so no `.response_other` event is observed twice. Probes k02, k02a, and k02c give the same verdict on the D18f binary.
- D28z, D29z, D32z (the mark does not go into a callee, into a recursive pass, or through `heapState`): equivalent. The response is observed only at the completions of the handler, and `takeSummary` and the callback loop keep the caller's mark when it has one. The mark in a callee state reaches only that callee's sink events, and only `.response_other` events read it.
- D21b (`projectBranchCause` without the `was_deterministic` guard): equivalent. The function has one call site, and there the builder holds `deterministic` true whenever a handler function exists, so the guard never returns.
- D17b (no mark on a logical compound assignment): not reachable. The parser refuses `||=` with ZTS001 (probe k17).
- D14b (no mark when a varying value selects the callee): probably not reachable. ZTS605 refuses a varying index, and `.at` and `f?.()` are refused (c3, c3b, c3c, c5, c5b). A probe that can confirm it is a selection of a function that the profile accepts with no control decision before the call.
- D08z (no mark on an optional call): probably equivalent. A varying receiver comes from a selection that already marks: in k08, `find` marks at 8:22 before `o?.run()`. A probe that can confirm it is an optional receiver that varies with no selection before it.

Timing (Opus, `/tmp/zttp-g4/det-timing/`): `zts check` on the 149 tracked files of `tests/corpus/check/`, 5 interleaved rounds of `out-u3` and `out-det2` (Debug), timed per file with `EPOCHREALTIME`. The sum of the per-file minima is 1.005 s before and 1.039 s after (3 percent). The largest per-file difference of the minima is 2.5 ms. Round totals vary from 1.66 s to 2.28 s for one binary, and the load average was 15 to 32 from another process, so this run cannot separate a cost below about 3 percent from noise.

## Decisions 5 and 6, taken on 2026-11-07

U3 found two cause choices. The owner did not answer within 60 seconds, so Opus took the recommended options.

Decision 5 (a): the syntactic cause scan names a varying builtin read (`Date.now()`, `Math.random()`, `performance.now()`) before a module export. The first export is the cause only when the file has no builtin read. Reason: the scan cannot see whether a value reaches the response, and with the first-site rule a discarded `rateCheck` or `fetch` call took the cause from the `Date.now()` that reached the response (probes o8 and o9). Option (b) kept that rule, and option (c) dropped the export scan and its correct `rateCheck` cause on s18b.

Decision 6 (a): a value from a local dependency that reaches the response keeps the row text with no line, as before this plan. It is recorded under "Gaps that remain after this plan". Option (b) named a branch instead, which misleads when the value reaches the response with no branch.

## Risks

- A missed control decision or a state site that drops the flag keeps the hole open for that shape. The list in Decision 1 comes from the Codex astra census of `flow_interp.zig`. U3 mutants and probes cover each item.
- Over-report: under option (a), a branch on a varying value that does not change the response clears `deterministic`.
- `unknown` also comes from `Value.top`, so a branch on a value that the analysis could not follow clears `deterministic`. That is the fail-closed direction.
- Fixpoints: `stateEql` must compare the flag, or a loop can stop before the flag reaches its exit.
- The re-record changes the convergence and coverage evidence. The memory and the docs give the order: convergence first, then coverage.

## Gaps that remain after this plan

- `deterministic` stays a disclosed edge. The acceptance kernel does not re-derive it.
- Implicit flow for `no_secret_leakage` stays out of scope (D9).
- The PR gate counts a lost `deterministic` as a warning, not as a breaking change.
- Decision 6: when a value from a local dependency (an export of `./dep.ts`) reaches the response, the ZTS500 row has no line and its text names `Date.now()`, `Math.random()`, and `performance.now()`, which the entry file may not hold (Fable probe g03). The binary before this plan prints the same text.
- The cause scan cannot see whether a value reaches the response. A file with a discarded varying export and no builtin read names that export. The log exports (`logInfo` and the others) count as varying through their `clock` capability, though they return `undefined`.
- The mark is sticky and goes through module initialization. A module-level branch on a varying value that the handler never reads clears `deterministic` (Fable probe c11), as does a helper branch whose result the handler drops, and a branch that only logs (n04, c10b).
- A handler that writes module state and branches on the clock gets the branch cause, not the write (Fable probe d_carry). Removing the branch leaves the write.
- Pre-existing and out of scope: `range(t % 3).map(() => "x").join("")` gets `warning[ZTS401]: credential data flows into response body` on both binaries (Fable probe a11b).

## Review findings

Fable checked the argument and Codex astra checked the facts, with split briefs, on 2026-11-07 at `6af15c69`. Both used the HEAD binaries and edited no repository file. Fable's probes are in `/tmp/zttp-g4/fable2-probes`. Opus reran p_modinit, p_call_after_branch, p_map_branch, and p_recurse, read `joinStates` and `cloneState`, and checked the jwt-auth handler and a `jwtVerify` value probe.

| Finding | Reviewer | Claim attacked | Resolution |
|---|---|---|---|
| F1, should-fix | Fable | Decision 1 (a): the flag survives joins and calls | Confirmed: `joinStates` resets `path`, and many sites build a state field by field. Decision 1 now names the field, the OR rule, and each site. Three probes are U1 regressions. |
| F2, should-fix | Fable | The decision list is complete | Confirmed by p_modinit. Module initialization is in Decision 1. |
| F3, note | Fable | Coverage of callbacks and string methods | Accepted: many shapes are refused at HEAD by the explicit rule; "Reproduction" lists them. |
| F4, note | Fable | The over-report of (a) and (c) | Accepted: 0 in examples and the good corpus; log-timestamp is the counterexample to (c). Fable's statement that no recorded handler branches on a varying value is wrong: it missed that `jwtVerify` is varying (Codex astra finding C10). |
| F5, note | Fable | The `unknown` label refuses request-data branches | Not so: request data carries no `unknown`. U1 control 3 is wider. |
| F6, should-fix | Fable | Decision 2 text | Accepted: the remedy is a capsule without `deterministic`, the text says "reached through", and binding sources get a named cause. |
| F7, note | Fable | Precedence and the assert over-report | Accepted: a value cause wins; the assert shape is in the over-report class. |
| C1 | Codex astra | Probe descriptions | s8 and s16 are now separate rows. |
| C2 | Codex astra | Artifact evidence | The retained logs do not hold exit statuses or bodies; "Reproduction" says where each value comes from. |
| C3 | Codex astra | Cause | Added the `result.cleared` exception, the `sinks_the_read` qualification, and the dependency ZTS606 rule. `assert` keeps its failure as a separate completion. |
| C4, material | Codex astra | Decision 1 (a) covers every control decision | Corrected: Decision 1 now lists the census items. |
| C5, material | Codex astra | A new `State` field survives by itself | Corrected: each site is named. `flow_value.zig` is a U1 file. |
| C6, material | Codex astra | The completion flag reaches the rule | Corrected: `SinkEvent` gets a control field, and the flag carries its first decision for Decision 2. |
| C7 | Codex astra | The `rateCheck` label | It is `internal` and `nondeterministic`, through `exportVaries`. |
| C8 | Codex astra | The `idempotent` order | The initial builder properties are not final; the refresh uses the final ones. |
| C9 | Codex astra | Every default-profile text changes | Corrected: only where a property newly fails. |
| C10, material | Codex astra | The corpus drift is unknown | Confirmed by Opus: the recorded jwt-auth handler proves `deterministic` and branches on `jwtVerify(...).ok`. Decision 3 now needs the owner. |
| C11 | Codex astra | The PR gate verdict after the fix | A lost `deterministic` is a warning, so the gate can still exit 0. Recorded in "What already exists" and "Gaps". |
