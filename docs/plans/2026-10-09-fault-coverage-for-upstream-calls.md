# Plan: fault coverage for upstream calls

Status: accepted 2026-10-09, revision 2. Source: follow-up R3
of the [flow-checker plan](2026-10-08-flow-checker-sinks-in-callees.md),
section 9. Code references are to local `main` at `423cb4b8`. The owner
approved implementation on 2026-10-09 (section 6).

## 1. Summary

`fault_covered` cannot be proven for a handler whose only I/O is a `fetch`,
even when the handler returns 502 on `if (!res.ok)`. A prototype, an export
audit, and two plan reviews measured it on 2026-10-09. Their reports, probes,
diffs, and a U1 build are in the session scratchpad (`r3/`, `r3/fable/`).
Nothing was committed.

Two causes, both confirmed by measurement:

1. `zttp:fetch` declares no `failure_severity`, so it takes the default
   `.none`, and `getOrPutEntry` drops every site whose effective severity is
   `.none` (`packages/zts/src/fault_coverage.zig:331-336`). The value
   `.upstream` was designed for this case when fault coverage arrived
   (`513579bd`, 2026-03-25: "upstream (fetchSync): 2xx is informational"). No
   declaration of it exists in the tree or in reachable history.
2. The path generator records an I/O success or failure constraint for `x.ok`
   only when the callee's metadata says `.result`
   (`packages/zts/src/path_generator.zig:1180-1203`, the check at line 1197).
   `fetch` declares `.returns = .object` with the signature
   `{ ok: boolean; status: number; ... }` (`packages/modules/src/net/fetch.zig`).
   `if (!res.ok)` still branches as ordinary control flow, but it creates no
   fetch failure constraint, so no fetch site is ever covered.

Fixing those two is not enough. **The prototype of that fix proves
`fault_covered` for handlers that ignore a failing `fetch`**, because the
analysis does not see every failable call:

3. Fault-coverage entries come from path constraints, and on route roots from
   the tracked I/O stubs (`fault_coverage.zig:247-263`). The tracked stubs
   (`io_seq`) see only `const x = call()` and bare `call();` statements on an
   emitted path. A failable call inside a nested function or callback, inside a
   user helper, inline in an expression (`fetch(b).body`), as a call argument,
   as a `match` scrutinee, or in a branch that does not return is never counted.
   Measured by the review on the prototype with U1 applied: six probes of this
   shape prove `fault_covered` with the second call uncounted. One shipped
   example is already vacuous today: `examples/parallel/parallel.ts` proves
   `fault_covered` (2 of 2 sites) while its three `fetch` calls sit in nested
   functions (`parallel.ts:26-34`).
4. On the handler root, every call of one function shares one entry: the key
   uses call site 0 (`fault_coverage.zig:276-285`, `:321-325`), so one covered
   call covers all (probe p8: two `jwtVerify`, the second unchecked, proves
   `fault_covered` today). The generated-test stub overrides are keyed by
   function name, so a path where the first `fetch` succeeds and the second
   fails stubs both as failing (review probe f11 gives a wrong expected
   status).
5. A walk that is not exhaustive (`pathsExhaustive = false`, for example a loop
   summarized once) still lets `fault_covered` hold (review probe f7).

So the plan first makes the analysis fail closed on every failable call it
cannot see, then widens what counts.

## 2. Observed facts

### 2.1 Prototype measurements (variant A: severity on the binding plus an `ok`-record fork)

| Probe | Baseline | Prototype A | A + U1 (review build) |
|---|---|---|---|
| p1 `fetch(url)`, `!res.ok` returns 502 | false, 0/0 | true, 1/1 | true |
| p3 fetch result never checked | false, 0/0 | false | false |
| p4 two fetches, only the first checked | false | **true (wrong)** | false, 2/1 |
| p6 `!res.ok` returns 200 (fallback) | false | true | true |
| p7 `res.status !== 200` returns 502 | false | false | false |
| p8 control: two `jwtVerify`, only the first checked | **true (wrong today)** | true | false, 2/1 |
| p9 routed, route function has an unchecked fetch | true | false | false |
| f1, f2, f3, f6, f12, f14: second fetch nested, inline, in a helper, as a scrutinee, as an argument, in a non-returning branch | false | **true (wrong)** | **true (wrong)** |
| f10 `env(...) ?? default` beside a checked `jwtVerify` | true | true | false |

Examples (61 files), `zts check --json`: with A, 4 change, each only in its
fault-coverage output (`fault_covered` false to true, 1/1 sites):
`fetch/weather-app.ts`, `fetch/weather-forecasts.ts`, `fetch/webhook.ts`,
`system/gateway-static.ts`. With A + U1, `gateway-static.ts` goes back to
false (2 sites, 1 covered), because its `env("APP_NAME") ?? "demo"` becomes an
uncovered site (decision Q7). The count of examples where `fault_covered`
holds is 11 at baseline, 15 with A, 14 with A + U1. The corpus case
`cache-counter` moves from 0/0 to 1/0 sites under U1.

Generated tests: at baseline the failing-fetch path of p1 fails (expected 502,
actual 200). The default stub `{"id":"1"}` has no `status`, and replay defaults
a missing `status` to 200 (`packages/runtime/src/runtime_http.zig:1626`);
replay does not read a stub's `ok`, the Response derives it from `status`
(`packages/zts/src/http.zig:199,224`). With the prototype's stubs (failure
status 503) both generated cases pass.

### 2.2 Identity and replay

- The binding change moves `module_registry_hash` (`c75cb499...` to
  `59f990c9...`); `policy_hash` and `semanticsHash` do not move. 16 of 19
  cassettes then need a re-record, because tool results that print the
  registry-derived `module_graph_hash` change (the `meta` and `modules`
  results; `packages/tools/src/agent_protocol.zig:664-665`).
- A variant that infers the severity without the binding change (variant B)
  keeps the registry hash but still breaks 2 cassettes, because their recorded
  `fault_covered` changes. The meta-drift gate checks hash pins and cannot see
  a verdict change when every pinned hash stays the same. Rejected.
- U1 alone moves no final-handler corpus verdict and no hash (review F7), so it
  can be measured and replayed alone. U1 changes the count text of one contract
  golden (`modules_all`, probably "1 of 3" to "1 of 4"; measure).
- The acceptance kernel does not check `fault_covered`; `packages/proof-checker`
  has no reference to it, and its certificate has no policy-hash field
  (`packages/proof-checker/src/certificate.zig:107-125`). `policy_hash` is
  enforced where a stamped contract is validated at runtime
  (`packages/runtime/src/contract_runtime.zig:1546-1556`; an all-zero hash
  skips the check) and in proof replay. Ten tracked files pin the policy hash
  today: `policy-hash.txt`, `scripts/check-meta-drift.sh`,
  `docs/consumer-contract-envelope.json`, `docs/convergence.json`,
  `docs/coverage.json`, and the expert goldens `meta`, `verify_paths_clean`,
  `verify_paths_missing`, `canonicalize_mixed`, `canonicalize_mixed_simulate`.
- `upgrade_verifier` classifies a lost `fault_covered` as critical, so a
  handler that loses the property under U1 reports a critical regression.

### 2.3 The export audit

Of 119 exports in 29 modules (the audit's tally), several can return a value
the handler can observe as a failure while declaring `.none`: the network and
orchestration calls (`fetch`, `fetchWithRetry`, `serviceCall`, the
`zttp:workflow` results, `parallel`, `race`), boolean or `undefined` outcomes
(`cacheSet`, `schemaCompile`, `verifyWebhookSignature`, `signal`, `signalAt`,
`cacheIncr`, `setCookie`, `base64Decode`), and about ten pure-data `Result`
exports. Which of these count as faults is a judgment the audit labels as
inferred. `callTool` and `rateCheck` return `Result`, so the generator already
forks on them; `rateCheck` also returns plain `undefined` on some errors, which
no fork represents. `parseIso` declares `expected`, but its failure is
`undefined` from a non-optional `number`, which no fork represents.
`workflow.call` declares the same top-level `ok: boolean` record as `fetch`.

### 2.4 Documents

`docs/verification.md:629` already promises a fork at every I/O success or
failure boundary, and the deploy manifest says "all I/O failure modes handled
correctly" (`packages/tools/src/deploy_manifest.zig:905`). The severity table
in `docs/verification.md` has no `upstream` row. `spec_discharge.zig:137`
suggests "add an explicit failure path for every critical I/O call site". The
enum doc names `fetchSync`, which survives only as a legacy runtime ambient
that the strict checker refuses (`strict_checker.zig:2044-2047`). The
`.upstream` info diagnostic for a 2xx fallback reaches no output: text output
prints only warnings, JSON carries counts, and the matrix prints `OK` (review
F3).

## 3. Constraints

- **K1 (no wrong true).** No unit may let `fault_covered` hold while a failable
  call is uncounted, uncovered, or invisible to the walk. U1 lands before U2
  for this reason.
- **K2 (census, two directions).** A gate drives the real path generator over a
  probe per failable export: the probe must produce a failure fork and a stub
  that fails it; and every export whose declared return can fork must have a
  severity other than `.none` or an allowlist row with a reason. Count per
  verdict, with a floor; a sabotage of the fork rule must make it fail
  (AGENTS.md gate rules).
- **K3 (replay).** Every unit runs `test-expert-app -j1` offline (no
  `ZTTP_CODEGEN_RECORD`, no `ZTTP_CODEGEN_QUALIFY`, `DEEPSEEK_API_KEY` unset)
  and records which cassettes move and why.
- **K4 (evidence).** Unfiltered named steps, exit status read directly; the
  full `scripts/verify.sh` (offline, in a worktree) before the re-record.

## 4. Units

**U0: the severity census gate.** Per K2. It runs the path generator on a
generated probe per export with `failure_severity != .none` and asserts a
failure fork and a failing stub; it asserts the reverse direction for exports
whose return can fork. Today's expected rows: `parseIso` (no fork for its
`undefined` failure) and `rateCheck`'s `undefined` failures, each with an
allowlist row that names the follow-up. Seen failing first by sabotaging one
fork kind.

**U1: count every failable call, and fail closed on the rest.**
- (a) On the handler root, seed an entry for every failable stub on each
  emitted path, as route roots do, keyed by call site. Key the generated-test
  stub overrides by call site too.
- (b) Fail closed on what the walk cannot see: scan the whole IR for calls to
  exports whose effective severity is not `.none`; a call that no emitted path
  holds as a site blocks `fault_covered` (unproven, with a fact naming the
  call), in the pattern of `routeDispatchesResolved()`.
- (c) `pathsExhaustive = false` blocks `fault_covered`.
- (d) `call(...) ?? fallback` on an optional-returning export counts as covered
  (decision Q7).
Measure alone before U2: every example, corpus case, contract golden, stand-in,
`test-cli`, `test-zruntime`, and replay. Expected: verdicts move only toward
false; p8 goes false.

**U2: `fetch` counts as an upstream call.** Declare `.failure_severity =
.upstream` on `fetch` and `fetchWithRetry`. Add the `ok`-record fork: `x.ok`
forks when the callee's parsed return type is a record with a top-level
`ok: boolean` field (read through the type environment, not by scanning the
signature text) and the export's severity is not `.none`, so `workflow.call`
does not change. Add success and failure stubs that carry `status` (200 and
503) and the other fields replay reads. Add a fact
`upstreamFallbackSites` to the fault-coverage trace, so a 2xx fallback on an
upstream failure is visible. Regenerate the module spec and the consumer
envelope; move the registry pins. Tests: p1 to p10, the review's f-probes, a
nested-`ok` negative, and `workflow.call` unchanged.

**U3: version the path analysis in the policy hash.** Add a
`path_analyzer_version` beside `flow_analyzer_version` and hash it into
`policyHash()`, so a contract stamped before U1 and U2 is refused where the
runtime validates the policy hash. Update all ten pins listed in 2.2 except the
evidence files, which U5 republishes.

**U4: documents.** Add the `upstream` row to `docs/verification.md`; state that
every failable call counts, that the analysis fails closed on calls it cannot
see, and that a 2xx fallback on an upstream failure is reported but covered;
reword the `spec_discharge.zig:137` suggestion and the deploy-manifest line;
fix the enum doc (`fetchSync`, and the `.none` text); note that losing
`fault_covered` under the new analysis reports as a critical upgrade
regression.

**U5: re-record.** One paid DeepSeek re-record (decision Q6), then
`scripts/update-convergence.sh` and `scripts/update-coverage.sh` offline, three
commits in that order.

## 5. Order and verification

Order: U0, U1 (measured and replayed alone), U2, U3, U4, the full
`scripts/verify.sh` offline, then U5. U2 and U3 move replay; U5 covers them.

Each unit: a test seen failing first; unfiltered `test-zts`,
`test-precompile`, `test-diagnostic-corpus`, `test-contract-golden`,
`test-standin`, `test-flow-census`, `test-examples`, `test-cli`,
`test-zruntime`, `test-expert-golden`, `test-proof-swallow`,
`test-expert-app -j1` (offline per K3); `zts meta --json` and
`zts spec-hash --json` before and after; the 61-example diff with every change
explained.

## 6. Decisions for the owner

Answered 2026-10-09: Q1 to Q7 all (a). The owner approved this plan. Sonnet
subagents implement U0 to U4 in section 5 order, one commit per unit. U5 is a
paid DeepSeek re-record, so the main session confirms with the owner before it
starts.

**Q1 (scope of the upstream severity).** Options: (a) `fetch` and
`fetchWithRetry` now, the rest of the audit as listed follow-ups; (b) also
`serviceCall`, the `zttp:workflow` results, `parallel`, and `race` now.
Recommendation: (a). `serviceCall` declares no signature, `parallel` and
`race` return arrays, and each needs its own fork and measurement.

**Q2 (fail closed first, U1).** Options: (a) U1 with all four parts, before U2;
(b) only U1 (a), the rest later. Recommendation: (a). Without (b) and (c), U2
proves `fault_covered` for the six review probes, and `parallel.ts` stays
vacuously proven.

**Q3 (2xx on an upstream failure).** Options: (a) covered, with the new
`upstreamFallbackSites` fact (a fallback may be intended); (b) a warning that
blocks `fault_covered`, as for `critical`. Recommendation: (a).

**Q4 (version the path analysis, U3).** Options: (a) yes; (b) no.
Recommendation: (a). U1 and U2 move verdicts in both directions, and U2 already
forces the re-record.

**Q5 (how the `ok` fork is declared).** Options: (a) from the parsed return
type, only for failable exports; (b) a new explicit binding field; (c) a new
return kind. Recommendation: (a), guarded by the U0 census.

**Q6 (re-record).** Options: (a) one paid re-record after U4 and the full
verify; (b) defer U2 and U3. Recommendation: (a).

**Q7 (`call(...) ?? fallback`).** U1 would count `env(...) ?? "demo"` as an
uncovered site, which takes `fault_covered` from `gateway-static.ts` and moves
the `cache-counter` corpus case. Options: (a) a `??` fallback on an
optional-returning export counts as covered; (b) it stays uncovered, and the
affected examples are rewritten. Recommendation: (a). The `??` is the explicit
failure path for an absent value.

## 7. Follow-ups (not in this plan)

- A fork on `res.status` comparisons (probe p7).
- The rest of the audit (section 2.3), and forks for `parseIso` and the
  `undefined` failures of `rateCheck`.
- Flow witnesses (`counterexample.zig`) do not fork on `res.ok`.
- Side observation, not investigated: for p1 the `has_egress` trace says "The
  handler makes no outbound fetch calls" while `outbound_hosts` lists the
  fetch host.

## 8. Review record

Revision 1 was reviewed on 2026-10-09. Codex astra fact-checked it (28 claims
corrected or qualified, among them the `fetchSync` status, the cause of the
baseline stub failure, `rateCheck` and `callTool` already forking, the
certificate wording, and line numbers). Fable reviewed the reasoning with
probes and a U1 build: the blocker that U1 alone left six wrong trues (now
U1 (b)), the non-exhaustive walk (U1 (c)), the `??` fallback (Q7), the
invisible info diagnostic (`upstreamFallbackSites`), a census that restated its
rule (now two-directional and generator-driven), the policy-hash enforcement
point and its ten pins, and measuring U1 alone. Reports:
`r3/codex-review.md`, `r3/fable-review.md`.
