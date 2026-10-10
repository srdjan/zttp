# Plan: fault coverage follow-ups (R4)

Status: approved 2026-10-10, revision 2. Source: the follow-ups of the
[R3 plan](2026-10-09-fault-coverage-for-upstream-calls.md), section 7 and
section 9. Code references are to local `main` at `1d821395`. Revision 1 was
reviewed by Fable and Codex astra (section 8).

## 1. Summary

R3 made `fault_covered` count `fetch` and fail closed on failable calls that
the walk cannot see. This plan closes the gaps that R3 left, and one older gap
that the review found:

1. **Wrong true today.** `if (!auth.ok && req.method === "POST") return 401;
   return 200;` proves `fault_covered`. The fall-through of an `&&` condition
   is emitted as one path, so the case "the call failed and the method is GET"
   is never enumerated. Reproduced at `1d821395`: `fault_covered` holds with 3
   of 3 sites while a failed `jwtVerify` on a GET returns 200 with the private
   data.
2. **Wrong true today.** The unseen-call scan reads one file. A handler with
   a checked `fetch` that also calls an imported helper with an unchecked
   `fetch` proves `fault_covered`. Reproduced at `1d821395`.
3. `if (res.status !== 200)` creates no fetch failure constraint. Only
   `res.ok` forks (R3 probe p7).
4. Flow witnesses do not fork on `res.ok`.
5. Twelve census rows wait for a decision, and `serviceCall`, `workflow.call`,
   `parallel`, `follow`, `saga`, and `fanout` have no census row.

R4 F0 is done: `1d821395` stops the `builtin_modules.zig` severity test from
calling `cacheSet` total.

## 2. Observed facts

### 2.1 Who decides `fault_covered`

Two production paths in `packages/tools/src/precompile.zig` decide the handler
property: `analyzeHandlerPaths` (`:1408`, `:1458`, written at `:2038`) and
`compileHandler` (`:2753`, `:2804-2807`). `zts check`, the agent protocol, the
wasm analyzer (`wasm_analyzer.zig:107`, `skip_contract = false` at `:114`), and
four `packages/pi` callers reach them. The durable workflow property
(`contract_builder.zig:3837`) and the system property (`system_linker.zig:1241`)
are separate calculations. Other generator callers (`precompile.zig:2131`,
`:2475`, `severity_census.zig:538`, `property_diagnostics.zig:657`) do not call
`faultAnalysisComplete()`.

### 2.2 The `&&` fall-through

`walkBlock` gives the then-path of `if (a && b) return X` the constraints of
`a` and `b`, and the fall-through the negation of each
(`path_generator.zig:1150-1174`). Short-circuit evaluation reaches the
fall-through when `a` is false, or `a` is true and `b` is false. One path is
emitted, and `pathsExhaustive()` stays true. When a conjunct is not
recognized (a direct `req.method === "POST"`), the fall-through holds only
`!a`. Probe `p_and.ts` proves `fault_covered`; `zts gen-tests` emits a GET that
expects 401, which cannot pass. Probe `p_fetch_and.ts` hides an
`upstreamFallbackSites` fact. Three `&&` conditions exist in examples
(`handler-full.tsx:46,67`, `weather-forecasts.ts:20`), none in the DeepSeek
corpus expected handlers. Whether `||` has the mirror defect in its then-path
needs to be measured.

### 2.3 The unseen-call scan and imports

- `scanUnseenFailableCalls` (`path_generator.zig:411`) reads one IR. It
  detects calls to, and value uses of, failable builtin exports
  (`:441-469`), with the `??` exemption (`:444`). `scanImports` fills
  metadata only for `resolution == .builtin` (`:941-957`).
- `ImportRecord.Resolution` is `builtin`, `partner`, or `unresolved`
  (`module_facts.zig:72`). One record exists per imported binding, so two
  names from one file give two records. Whole-clause `import type` is erased
  before parsing (`stripper.zig:1783`) and gives no record.
- `collectImportedFnSummaries` (`precompile.zig:530`) reads `./` and `../`
  siblings for the flow checker. For the flow checker, a missing entry is
  conservative. It returns an empty list on a freestanding build (`:545`) and
  skips other specifiers and resolve failures with `continue` (`:551-554`).
  **For fault coverage, an empty or partial list means "scanned clean", the
  opposite polarity.** The wasm analyzer would then get a wrong true.
- Today a bare specifier (`"lodash"`) and a missing sibling both give no
  diagnostic and leave `fault_covered` true (probes `p_bare_specifier.ts`,
  `missing/`). Partner manifests carry no severity field, so a partner export
  is never failable in the fault model.
- The corpus cases `sibling-helper` and `sibling-helper-holes` import
  `./lib/settings.ts`, which calls `env("API_TOKEN")` with no `??` (line 7).
  Their verdict is false today (no site) and stays false. The trace summary
  text changes from "No failable I/O sites" to an unseen-call text. Whether a
  recorded tool result carries it needs to be measured. No example imports a
  helper with a failable call (`examples/handler/utils.ts` has none).

### 2.4 The status comparison

- `extractResultOkConstraint` (`path_generator.zig:1338`) forks only on `ok`.
  Stubs carry `status` 503 and 200 (`:2196`).
- `fetch` does not follow redirects: both request paths that serve it
  (`runtime_http.zig:1345` and the `parallel`/`race` worker at `:2511`) pass
  `.redirect_behavior = .unhandled`. `ok` is `200 <= status < 300`
  (`http.zig:199`). So a 3xx reaches the handler with `ok` false. By code
  reading (not measured), Zig's HTTP client also returns a 1xx head other than
  100-continue, and the fetch path has no 1xx handling.
- Status comparisons after a call: `examples/tools/tools.ts:76` (`fetch`), and
  four after `serviceCall` (`system/gateway.ts:33`, `users.ts:27`,
  `gateway-static.ts:17,23`). None in the DeepSeek corpus. The Claude corpus
  case `durable-order` has one; that corpus is frozen and off-headline.
- A recognized comparison that does not fork gets the default success stub on
  both branches. Probe `p_status_before_ok.ts` (`=== 404`, then `!res.ok`)
  emits a test that stubs 200 and expects 404.

### 2.5 Flow witnesses

`FlowChecker.extractResultOkConstraint` (`flow_checker.zig:5723`) requires
`.result`. The solver then stubs `fetch` with `{"id":"1"}`
(`counterexample.zig:315,362`), and replay defaults a missing status to 200.
`StubInfo` has no `ok_record` field (`counterexample.zig:34-39`). Witnesses
decide no verdict (`flow_checker.zig:5640`). The `verify` tool prints the
trace counterexample (`agent_protocol.zig:1966`), so a witness change can move
recorded text. Persisted witnesses are keyed by property, origin, and sink,
and a re-persist of a known key is a no-op, so old files keep the old stub.

### 2.6 The census and the open rows

Five rows fail with plain `undefined` and no fork (`parseIso`, `rateCheck`,
`cacheIncr`, `setCookie`, `base64Decode`; `severity_census.zig:200-230`).
Seven rows fork without a severity (`verifyWebhookSignature`, `schemaCompile`,
`cacheSet`, `signal`, `signalAt`, `callTool`, `race`; `:233-274`). Two census
reasons are wrong or incomplete: `schemaCompile` has no registry limit
(`validate.zig:118`), and several failure lists are partial (Codex finding
16).

- A failed `cacheSet` can leave an earlier value in place (`cache.zig:220`,
  `:227`). Bare `cacheSet(...)` statements: `examples/modules/modules_all.ts:45`
  and `examples/system/users.ts:33`; none in the DeepSeek corpus.
- `race` declares `.optional_object` and already forks on `undefined`. It can
  return any non-2xx Response that arrives first (`runtime_http.zig:2636`,
  `io.zig:352`).
- `callTool` fails with `invalid_arguments`, `unknown_tool`,
  `budget_exhausted`, `deadline_exceeded`, or a closed latch
  (`handler_instance.zig:2388-2425`).
- The census yields the `ok_record` shape only for an export with a severity
  (`severity_census.zig:114`), so a `.none` export with the fetch record, and
  an `.object` export with no signature, have no row in either direction.
- R3 section 9: no boolean export declares a severity yet, so the census has
  never checked a boolean failure stub.

### 2.7 Identity

A severity change moves `module_registry_hash` (`module_manifest.zig:404`).
`path_analyzer_version` (2, `path_generator.zig:161`) is hashed into
`policyHash()` (`rule_registry.zig:873,916`), which has ten pins. R3 measured
16 of 19 cassettes moving on a registry change; R4's count needs to be
measured.

## 3. Constraints

R3's K1 to K4 hold: no wrong true; a census in two directions with a floor;
offline replay per unit; evidence from unfiltered named steps with the exit
status read directly. In addition:

- **K5 (per-record polarity).** The imported scan answers per import record.
  Every `facts.imports` record with `resolution != .builtin` must have an
  entry: scanned clean, scanned with failable calls, or blocked. A record with
  no entry counts as one unseen call at its import line. No input at all (for
  example the freestanding build) means no record has an entry.
- **K6 (replay expectations).** F1 to F4 are expected to keep replay at 19/19
  or to move only measured recorded text. From F5 on, replay fails until F9
  re-records; that failure is expected and is not a defect.

## 4. Units

**F1: enumerate the short-circuit cases of a condition.** For the
fall-through of `if (c1 && ... && cn) <exit>`, emit one path per recognized
conjunct `ci` false with `c1..c(i-1)` true; when a conjunct is unrecognized,
also emit the path with every recognized conjunct before it true (decision
D6). A later conjunct that tests a failable call also adds a case with its
failure, because short-circuit evaluation skips the test but the call has
already run (found in F1: without it, `opaque && !auth.ok` stays a wrong true).
Measure `||` in the then-path and apply the mirror rule if it has the
same defect. Tests, each seen failing first: `p_and.ts` raises the critical
warning and loses `fault_covered`; `p_fetch_and.ts` reports one
`upstreamFallbackSites`; generated tests for both pass. Measure the three
example sites.

**F2: scan failable calls in imported files.**
- (a) Extract the scan core into a public function over an `IrView`, the
  atoms, and the file's import facts. It returns failable calls and value
  uses, with the `??` exemption.
- (b) In `precompile.zig`, add `collectImportedFailableCalls`. It returns an
  optional per-record result; a freestanding build returns null, never an
  empty list. For every `.unresolved` record: a `./` or `../` specifier is
  resolved, read, stripped, and parsed (the frontend follows the file
  suffix, so `.tsx` works), scanned as a whole file (D1), and its own imports
  are scanned in turn. A visited set, seeded with the handler's own path,
  stops cycles. A read, strip, parse, or resolve failure, a chain deeper than
  `max_import_depth`, or any other specifier gives a blocking entry. A
  `.partner` record follows D7.
- (c) `PathGenerator` takes the result as an input and applies K5.
  `faultAnalysisComplete()` includes it. Both production paths supply it.
- (d) `fault_unseen_cause` keeps its location on the handler's import line
  and names the sibling file in the snippet.
- Tests, each seen failing first: probe `sibling/` blocks; the same helper two
  files deep blocks; a sibling that exports `const f = fetch` blocks; a `.tsx`
  sibling blocks; `missing/` blocks; a bare specifier blocks; a cycle that
  includes the handler terminates without listing the handler's own sites;
  a pure helper does not block; no input blocks; an input that omits one
  record blocks.
- Measure: every example, the corpus, and the `sibling-helper` recorded text.

**F3: fork on a status comparison.** Recognize `x.status OP n` and
`n OP x.status`, where `x` is an identifier bound to an `ok_record` call, `OP`
is `===`, `!==`, `<`, `<=`, `>`, or `>=`, and `n` is an integer or float
literal (a unary minus over one is allowed; `NaN` and `Infinity` are
identifiers and are not literals). Evaluate in source order at every integer
status from 100 to 599. The failure side is the value at 503. The comparison
forks only when the value at 200 is the other side and every status in the
D2 range gives the failure side. It then yields `result_not_ok` on the
failure side and `result_ok` on the other. One classifier serves F3 and F4.
For a recognized comparison that does not fork, each branch's stub carries the
smallest status in 100..599 that takes that branch, and no coverage
constraint is recorded.
- Tests: p7 (`!== 200` returns 502) proves `fault_covered`; `=== 200` with
  the success branch first proves it; `>= 300` and `>= 400` do not fork under
  D2; `=== 404` does not fork, and `p_status_before_ok.ts` gives a passing
  generated test; `const s = res.status` does not fork; a shadowed `res` keeps
  the outer fork. Generated tests pass end to end for every proven probe.
- Measure: `tools.ts:76`.

**F4: flow witnesses fork on `res.ok` and on the F3 comparison.** Add
`ok_record` to `StubInfo`, accept an `ok_record` export in
`FlowChecker.extractResultOkConstraint`, use the F3 classifier, and give the
witness stub the generator's `okRecordStub` shape. Test: a secret reaches the
response only when `!res.ok`; the witness carries the 503 stub and the
generator-side replay reaches the leak (not PI's `reproducedViolation`, which
reads the first stub). Record that `verify` evidence text can move, and that
old persisted witnesses keep the old stub (F8 states it).

**F5: severity decisions and census reach (D3).** Change the bindings that D3
selects. Extend the census reverse direction: an export whose declared return
parses to an `ok`-record is probed whatever its severity, and an `.object`
export with no signature needs a row with a mechanism. Add rows for
`serviceCall` (if D3 leaves it), `parallel`, `follow`, `saga`, and `fanout`.
Correct the `schemaCompile` reason and mark the failure lists as
representative. Show the sabotage "a boolean failure stub returns true" failing
the gate, because F5 adds the first boolean severity. Regenerate the module
spec and the consumer envelope, and move the registry pins. Measure the four
`serviceCall` example sites and the two bare `cacheSet` sites, and predict the
diff before running it.

**F6: plain `undefined` failures (D4).** Per D4.

**F7: version the path analysis.** `path_analyzer_version` from 2 to 3, and
the ten pins.

**F8: documents.** `docs/verification.md`: the short-circuit paths, the
cross-file scan and what blocks it, the partner position, the status fork and
its range, the new severities, and old persisted witnesses. The severity enum
doc. This plan's result.

**F9: re-record (D5).** One paid DeepSeek re-record, then
`scripts/update-convergence.sh` and `scripts/update-coverage.sh` offline, three
commits in that order.

## 5. Order and verification

Order: F1, F2, F3, F4 (each measured and replayed alone, K6), then F5, F6, F7
adjacent, then F8, the full `scripts/verify.sh` offline in a worktree, then
F9. Each code unit: a test seen failing first; the unfiltered steps that R3
section 5 lists; `zts meta --json` and `zts spec-hash --json` before and
after; the example diff with every change explained (61 tracked `.ts` and
`.tsx` files, which include the helper `utils.ts`). Sonnet subagents implement
F1 to F8, one commit per unit.

## 6. Decisions for the owner

Answered 2026-10-10: D1 to D7 all as recommended. The owner approved this
plan, including one paid DeepSeek re-record (F9) after F8 and the full verify.

Answered 2026-10-10 during F5: **D8** replaces the `schemaCompile` row of D3.
The D3 recommendation (`expected`) was wrong: it predicted a cost only for
`cacheSet`. `schemaCompile` is called at module scope, on no path, so any
severity makes it an unseen call. F5 measured the cost: four contract goldens,
`sql/sql-crud.ts` losing its declared `fault_covered`, `validate-external.ts`
losing it, and three DeepSeek corpus cases with the idiom. A failed compile
leaves the schema absent, so `validateJson`, `validateObject`, and
`coerceJson` answer `schema not found` (`validate.zig:218`), and those are
critical. The owner chose to keep `.none`, with a census row under a new
mechanism, `subsumed_by_critical`.

**D1 (extent of the imported scan).** (a) The whole imported file,
transitively, as the same-file scan does; (b) only the functions that the
imported names reach. Recommendation: (a). An unused failable helper in a
sibling then blocks, as one in the handler file already does.

**D2 (which statuses a status check must send to failure).** (a) The
complement of `ok`: every status in 100..199 and 300..599; (b) 300..599, plus
a runtime unit that turns a 1xx final head into the synthetic 599 response;
(c) 400..599. Recommendation: (a). It matches `ok` exactly with no runtime
change. `!== 200` and `=== 200` fork; `>= 300` and `>= 400` do not, and the
handler can write `!res.ok`. The 1xx runtime behavior goes to section 7.

**D3 (severities).**

| Export | Recommendation | Reason |
|---|---|---|
| `verifyWebhookSignature` | `critical` | an authentication failure |
| `schemaCompile` | `expected` | a configuration failure; a 2xx is acceptable |
| `cacheSet` | `expected` | a failed write can leave a stale earlier value; costs the two bare statements in examples, none in the corpus |
| `signal`, `signalAt` | `expected` | the target run may have finished |
| `callTool` | `upstream` | an agent handler reports a tool failure inside a 2xx stream, which `upstreamFallbackSites` then shows; `critical` would make those handlers unprovable |
| `workflow.call` | `upstream` | the same response record as `fetch`; the `ok` fork applies |
| `serviceCall` | `upstream` and the `fetch` response signature | it calls `fetchSyncResult` (`runtime_http.zig:2168`); first confirm which export `httpRequestResultJsonAlloc` serves, since it derives `ok` differently |
| `race`, `parallel`, `follow`, `saga`, `fanout` | defer, with census rows | each needs its own fork |

Options: (a) the table; (b) the table without `serviceCall`; (c) defer F5.
Recommendation: (a).

**D4 (plain `undefined` failures).** (a) `rateCheck` returns an error Result on
its `undefined` paths, and `parseIso`, `cacheIncr`, `setCookie`, and
`base64Decode` declare optional returns; (b) only the `rateCheck` change now,
the four declared-return changes in their own plan after a fallout
measurement; (c) defer all. Recommendation: (b). `x === undefined` on a plain
`number` type-checks but raises ZTS107, so the handler cannot write a clean
check until the declaration changes, and that change alters what handlers must
write.

**D5 (re-record).** (a) One paid DeepSeek re-record after F8 and the full
verify; (b) land F1 to F4 only, with the F7 version bump, and re-record then.
Recommendation: (a). Either option needs one paid re-record, because F1 to F3
move verdicts and need the version bump.

**D6 (the `&&` fall-through).** (a) Enumerate the short-circuit cases (correct
paths and generated tests); (b) mark such a walk as summarized, which blocks
`fault_covered` (cheap, but costs the three example sites). Recommendation:
(a).

**D7 (partner imports).** (a) A `.partner` record counts as one unseen call,
because a partner export has no failure model; (b) partner calls stay outside
`fault_covered`, stated in `docs/verification.md`. Recommendation: (a), per K1.
Bare unresolved specifiers block under both options.

## 7. Follow-ups (not in this plan)

- Forks for `race`, `parallel`, `follow`, `saga`, and `fanout`.
- The four declared-return changes, if D4 (b).
- A status read through a local, and compound conditions.
- 1xx final heads on the fetch path.
- A failable call inline in an expression counts as unseen rather than as a
  site, which costs `routing/router.ts` its verdict (R3 section 9).
- Contradictory constraints on one call site are not pruned
  (`p_two_checks.ts`); no wrong true follows today.
- R3's side observation on `has_egress`.
- Found in F1: request-binding recognition never fires.
  `findHandlerBindings` sets `req_binding_key` only when the first parameter
  node is `.identifier`, and the parser emits `.pattern_element`. So no
  `req_method` or `req_url` constraint is ever produced. Generated tests for a
  then-path that needs a POST therefore send a GET. A one-line fix
  (`ir_view.paramBinding`) was measured to change one example snapshot
  (`handler-full.tsx`). It still misses a direct `req.method === "X"`, and it
  moves path names and contracts, so it needs its own unit.
- `proof_trace.zig:595` prints "0 of N failable I/O site(s) have no explicit
  failure path" for a handler that is not covered only because of a critical
  2xx warning. F1 makes this reachable for `&&` conditions.

## 8. Review record

Revision 1 was reviewed on 2026-10-10. Fable reviewed the reasoning with 15
probes against a build of `1d821395`: two blockers (the `&&` fall-through
wrong true, now F1 and D6; the scan polarity, now K5 and F2), the 1xx gap in
D2, bare and partner specifiers (D7), the census blind spot, replay
expectations (K6), the inconsistent stub on a non-forking comparison, the
`serviceCall` example sites, F2 and F4 mechanics, and the dropped
inline-expression follow-up. The main session reproduced both blockers.
Codex astra fact-checked 27 claims: six corrections, among them the
`cacheSet` stale-value fact (which reversed the `cacheSet` recommendation), the
`race` row and its non-2xx responses, the `schemaCompile` registry limit, and
the depth of the import stack. Reports: scratchpad `r4/fable-review.md`,
`r4/codex-review.md`.
