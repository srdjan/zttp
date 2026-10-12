# Code review fixes for the R3 and R4 fault coverage series

Status: done, revision 2 (Fable review folded in; Codex astra could not run: its tool host timed out twice). Result below. Source: `/code-review --fix` over the 46 commits on
local `main` ahead of `origin/main` (R3, R4, and the minimal design audit). The
review kept 10 findings after verification and refuted 7. This plan fixes all
10 and says why one of them needs only a comment change.

## Version and corpus decision

`path_analyzer_version` stays at 3. Version 3 is not pushed. These fixes repair
defects in the version 3 analysis before release, so no contract that a
released analyzer stamped can disagree with them. After the fixes land, the
offline replay (`env -u DEEPSEEK_API_KEY zig build test-expert-app`) decides
the next step. If the replay passes, convergence and coverage are republished
offline. If the replay fails, the owner decides on a DeepSeek re-record.

## Units

Each unit is one commit. Unit letters name the implementer group.

### U1 (group A): a failable call in an `if` condition counts as walked

Finding 0. `scanUnseenFailableCalls` (`packages/zts/src/path_generator.zig:532`)
puts only `io_stubs[*].call_site` in `seen`. A call used directly as an `if`
condition, such as `if (!verifyWebhookSignature(b, s, sig)) return 401`, is
never in `io_seq`: `walkPaths` runs `trackModuleCall` only for `var_decl`
initializers and `expr_stmt`. `extractBooleanCallConstraint` still gives the
call a `stub_truthy` or `stub_falsy` constraint with `call_site` set to the call
node, and `FaultCoverageChecker.analyze` (`fault_coverage.zig:276`) counts and
covers a site from its constraints. The scan therefore lists a site that the
checker counted, and `fault_covered` drops. R4 F5 gave `verifyWebhookSignature`,
`cacheSet`, `signal`, and `signalAt` a severity, so this now fires on the
idiomatic guard.

Fix: in `scanUnseenFailableCalls`, also put in `seen` the `call_site` of every
constraint on every emitted test whose variant carries a `StubInfo`
(`stub_truthy`, `stub_falsy`, `result_ok`, `result_not_ok`, and the `stub` of
`status_is`), when the site is not `null_node`. Update the doc comment of the
scan: a call that a path constraint tests is walked.

Tests (in `path_generator.zig` or `fault_coverage.zig`, through
`analyzeSourceFaultCoverage` or the generator's public API):
- `if (!verifyWebhookSignature(...)) return 401; return 200` gives zero unseen
  calls and the site is covered.
- The same for `if (!cacheSet(...))` with a non-2xx failure status.
- A call in an `if` whose then-branch does not test it, such as
  `if (verifyWebhookSignature(...) && x) ...`, is still counted. State the
  observed result in the test name.
- Precompile-level: a handler with only the guarded `verifyWebhookSignature`
  call has `properties.fault_covered == true`.

### U2 (group A): ok-record stubs carry `ok`

Finding 2. `okRecordStub` and `statusStub` (`packages/zts/src/status_check.zig:180-215`)
emit `{"status":...,"statusText":...,"headers":{},"body":...}` with no `ok`.
Only `fetch` replays through `runtime_http`, which derives `ok` from `status`.
`fetchWithRetry` and `serviceCall` are ok-record exports that replay through
`trace.makeReplayStub`, which parses the JSON verbatim, so `res.ok` is
undefined and the success path takes the failure branch.

Fix: emit `"ok":true` or `"ok":false` in every ok-record stub, after
`statusText`, matching the shape at `zruntime_tests.zig:3968`. The value is
`isOkStatus(status)`. First confirm by reading `runtime_http.zig` that the fetch
replay path ignores a stub `ok` field or agrees with it. Update the doc comment
of `okRecordStub`. Update every pinned copy of the old strings
(`git grep -n '"statusText"'` under `packages/`: `counterexample.zig`,
`flow_checker.zig`, `severity_census.zig`, `path_generator.zig`,
`pre-rebase:packages/runtime/src/replay_turn.zig`, `test_runner.zig`, `zruntime_tests.zig`); change only the
copies that are generator output, not hand-written fixtures that model a real
recorded fetch.

Test: an end-to-end replay test (in `zruntime_tests.zig` or wherever a stub
already replays through `makeReplayStub`) shows that a `serviceCall` stub from
`okRecordStub(true)` makes `res.ok` true, and `okRecordStub(false)` makes it
false.

### U3 (group A): a path with no satisfying request or stub is not emitted

Finding 3. `applyStatusTests` (`path_generator.zig:2128`) keeps the old stub
when `chooseStatus` returns null, and `emitTestCase` still emits the path. The
generated test then expects a status the stub cannot produce.

Fix: `applyStatusTests` returns whether every call it handled has a satisfying
status. `emitTestCase` computes this before it increments `path_count` and
before it allocates anything; when it is false, `emitTestCase` returns without
emitting the test, the path cost, or a behavior. Apply the same rule to the
request constraints of U4: two different `req_method` values, or a
`req_method` value that equals a `req_method_not` value on the same path, make
the path infeasible (same for `req_url`). Replace the doc comment that says an
infeasible path keeps its stub.

Check whether dropping a path can change `pathsExhaustive`, the truncation
note, or `handler_tests_end` bookkeeping, and keep those correct. An infeasible
path is not a truncation.

Tests:
- `const res = fetch(u); if (!res.ok) return 502; if (res.status === 404) return 404; return 200;`
  emits no test with expected status 404, and no behavior with status 404.
- `if (res.status === 404 && res.status === 500)` on one call emits no path for
  the then-branch.

### U4 (group A): `!==` on `req.method` and `req.url` constrains the false side

Finding 4. `negateConstraint` (`path_generator.zig:1801`) returns null for
`req_method` and `req_url`. So `req.method !== "POST"` has no constraint where
it is false, and every path after the guard `if (req.method !== "POST") return 405`
sends `GET`.

Fix, following `counterexample.zig:72-73` and `solveRequest` (`:251`):
- Add `req_method_not` and `req_url_not` to `path_generator.Constraint`.
  `negateConstraint` maps `req_method` and `req_method_not` to each other, and
  the same for `req_url`. `negateConstraint` then never returns null for these
  variants.
- `emitTestCase` sets `method` from a `req_method` constraint when one exists.
  Otherwise it picks a method that differs from every `req_method_not` value on
  the path (`GET`, then `POST`, then `PUT`, ...). The same for `url`, with an
  alternate path such as the one in `alternateUrl`. U3 drops a path whose
  request constraints conflict.
- Fix every exhaustive switch over `Constraint` that the compiler reports.
  `FaultCoverageChecker.analyze` already ignores non-stub variants; update its
  comment if it counts the variants.
- The test name descriptor in `emitTestCase` gets a short form for the new
  variants (for example `!POST`).

Tests:
- `if (req.method !== "POST") return 405; const r = jwtVerify(t, s); if (!r.ok) return 401; return 200;`
  gives the 401 and 200 paths method `POST`, and the 405 path a method other
  than `POST`.
- `if (req.method !== "GET") return 405; return 200;` gives the 405 path a
  method other than `GET`.
- `if (req.method === "GET") return 1; if (req.method === "POST") return 2; return 3;`
  gives the third path a method that is neither `GET` nor `POST`.

### U5 (group B): one fault coverage record across check, compile, and text output

Findings 5, 6, 7.

5: `FaultCoverageInfo.isCovered` (`contract_types.zig:609`) includes
`unseen_calls` but not path exhaustiveness or route-dispatch resolution, and
`unseen_calls` is not serialized. The written `faultCoverage.isCovered` and
`report.zig:159` `clean` can say true while `properties.fault_covered` is
false, and a decode-then-encode round trip can flip `isCovered`.

Fix 5:
- Add `analysis_complete: bool = true` to `FaultCoverageInfo`, documented as
  `PathGenerator.faultAnalysisComplete()` at stamping time. `isCovered` becomes
  `covered == total_failable and total_failable > 0 and unseen_calls == 0 and analysis_complete`.
- Both stamping sites set it from `faultAnalysisComplete()`.
- `contract_json_parser.zig` reads the serialized `isCovered` (use the same
  versioned key that `contract_json_writer.zig:797` writes through
  `contractKey`) and restores `analysis_complete = isCovered or !(covered == total_failable and total_failable > 0)`.
  A decoded contract then writes the same `isCovered` that was read. A missing
  `isCovered` restores `analysis_complete = true`.
- The writer output does not change shape: no new JSON key.

6: the compile path (`precompile.zig:3065-3082`) sets `contract.fault_coverage`
only when `total_failable > 0` and never sets
`property_provenance.fault_covered`. The check path
(`analyzeHandlerPaths`, `precompile.zig:1607-1655`, and its stamping at
`:2260-2283`) sets both.

Fix 6: extract the fault part of `analyzeHandlerPaths` (checker run, the
`FaultCoverageInfo`, `fault_clean`, the unseen cause and its owned snippet)
into one function that both paths call, so the record, the property, and the
cause come from one place. The compile path sets `contract.fault_coverage` when
`total_failable > 0 or !faultAnalysisComplete()` (its current property
condition), and sets `property_provenance.fault_covered` and
`owned_fault_cause_snippet` the way the check path does. Do not change when the
check path writes `fault_coverage`; that would change every contract of a
handler with no failable call.

7: `zts check` text output (`precompile_check.zig:549`) prints
`Fault coverage: covered/total paths covered` from counts that exclude unseen
calls, omits the line when `total` is 0, and the Properties block has no
`fault_covered` line.

Fix 7: add `fault_unseen: u32` to `CheckResult`, set from the analysis. Add
`writeProven(writer, "fault_covered", props.fault_covered)` to the Properties
block. Print the fault line when `fault_total > 0 or fault_unseen > 0`, as
`Fault coverage: {covered}/{total} failable call sites covered`, followed by
`, {unseen} not on any path` when `fault_unseen > 0`. The counts are call
sites, not paths. Update every golden or test that pins the old line.

Tests:
- Round trip: a contract with counts covered, `unseen_calls > 0`, written,
  parsed, and written again, gives the same bytes and `isCovered: false`.
- A handler with a checked `jwtVerify` inside `for (const i of range(2))`
  writes `isCovered: false` and `report.zig` `clean == false`.
- Compile path: `return Response.text(jwtVerify("t","s").error);` produces a
  contract with `fault_coverage != null`, `unseen_calls == 1`, and
  `property_provenance.fault_covered != null`.
- Text output for the same handler contains `fault_covered` and the unseen
  count.

### U6 (group B): read imported helpers at the revision under analysis

Finding 1. `analyzeHandler` (`packages/runtime/src/proofs/pr_gate.zig:776`)
checks the base source of a handler, but `collectImportedFailableCalls` and
`collectImportedFnSummaries` read every imported helper from the working tree
(`readFilePosix`). A PR that adds an unchecked `fetch` to `./lib.ts` therefore
gives both contracts `fault_covered == false`, and the gate reports no
regression. The flow summaries had the same defect before R4. When `--head`
names a ref, the after side has it too.

`packages/pi/src/proof_enrichment.zig` `computeProveSummary` is not affected:
its before and after differ only in the edited handler, and the helpers on disk
are the same for both sides. Record this in the commit message.

Fix:
- Add an import source reader to `CheckOptions`:
  `import_reader: ?ImportReader = null`, where `ImportReader` is a context
  pointer plus a function `read(ctx, allocator, path) anyerror![]u8`. Null keeps
  `readFilePosix`.
- Thread it through `runCheckOnPreparedSource` to `collectImportedFnSummaries`,
  `importedFunctionSummary`, `collectImportedFailableCalls`, and
  `scanImportedFileTree`. Any read failure stays the existing blocked or
  unresolved answer.
- In `pr_gate.zig`, the before side passes a reader that runs
  `git show <base>:<repo-relative path>` (reuse `readAtRef`). The after side
  passes a reader for `opts.head` when it is set, and null otherwise. Compute
  the repo-relative path from the resolved import path and `cwd`; measure what
  `std.fs.path.resolve` returns for a relative handler path in Zig 0.16 before
  you rely on it.

Test (beside the existing git-repo tests in `pr_gate.zig`): a base commit with
`handler.ts` importing `./lib.ts` whose helper has no failable call, and a head
working tree where `lib.ts` adds an unchecked `fetch` and `handler.ts` also
changes. The gate reports the `fault_covered` true-to-false change.

### U7 (group B): one loader for an imported file

Finding 9 (cleanup). `scanImportedFileTree` (`precompile.zig:694`) and
`importedFunctionSummary` (`:784`) repeat the read, `PreparedSource`, parse,
and `buildModuleFacts` sequence. Extract one loader that both call, and that
takes the U6 reader. The loader owns the source, the prepared source, the atom
table, the parser, and the module facts, and is initialized in place because
the parser holds a pointer to the atom table. Each file is still parsed once per
walker; a shared cache is out of scope.

### U8 (me): the `rateCheck` comment states the allocation exception

Finding 8 is accepted as a comment defect only. When building the error value
itself fails with `OutOfMemory`, `rateErrorResult` propagates the error, which
the success path at `ratelimit.zig:236` also does with its own `try
sdk.createObject`. Returning `undefined` again would bring back the shape that
R4 F6 removed. Change the comment at `ratelimit.zig:213` to say that every
failure is an error Result unless the error value cannot be allocated.

## Verification

Each group runs, unfiltered: `zig build test`, `zig build test-zruntime`,
`zig build test-cli`, and the step that owns each changed file (see
`docs/internals/testing.md`). After both groups land, I run
`env -u DEEPSEEK_API_KEY bash scripts/verify.sh` and
`env -u DEEPSEEK_API_KEY zig build test-expert-app`, and read each exit status
from a file, not through a pipe.

## Revision 2: Fable review resolutions

These override the unit text above where they disagree.

R1 (U3, Fable 1). Only `req_method` conflicts make a path infeasible: two
different `req_method` values, or a `req_method` equal to a `req_method_not` on
one path. `req_url` stands for both `req.url` and `req.path`
(`path_generator.zig:1634`, `:1658`), which the runtime keeps distinct, so a
`req_url` conflict is not evidence of infeasibility. `req_url` keeps last-wins.
When no `req_url` is on the path, `url` is a value that differs from every
`req_url_not` value.

R2 (U1, Fable 2). Add `pub fn countedSite(self: Constraint) ?StubInfo` on
`path_generator.Constraint`: the `StubInfo` for `stub_truthy`, `stub_falsy`,
`result_ok`, and `result_not_ok`, and null for every other variant (an
exhaustive switch, no `else`). `FaultCoverageChecker.analyze`
(`fault_coverage.zig:276-285`) and the U1 scan both use it, so the set the
scan treats as walked is exactly the set the checker counts. `status_is` is not
in it.

R3 (U4, Fable 3). `dupePathCondition` (`path_generator.zig:133`) maps
`req_method_not` and `req_url_not` to null, as it maps `status_is`.
`PathCondition.Kind` does not change, and contract bytes do not gain a kind.

R4 (U5, Fable 4). `analysis_complete` has no default. Every constructor sets
it, so the compiler names each one. Document on the field that after a decode a
false value cannot be told apart from `unseen_calls > 0`.

R5 (U6, Fable 5). A PR that changes only an imported helper is still not
analyzed: `changedHandlers` (`pr_gate.zig:543`) lists only changed files, and
the helper classifies as a non-handler. U6 does not fix that. Record it in the
U6 commit message and in `docs/roadmap.md` as a known gap of the gate.

R6 (U3, Fable 6). A path where one call site carries both polarities
(`result_ok` and `result_not_ok`, or `stub_truthy` and `stub_falsy`) is
infeasible and is not emitted. Example:
`const res = fetch(u); if (!res.ok && res.status === 200) return 1; return 2;`
emits no path expecting 1.

R7 (U6, Fable 7). Measured by Fable under Zig 0.16.0: `std.fs.path.resolve`
keeps relative inputs relative. The reader uses a relative path as given and
`std.fs.path.relative(cwd, p)` for an absolute one. It refuses a result that
starts with `..`, and runs `git show <ref>:./<rel>` with `cwd` as the git
working directory. A refusal or a failed `git show` is the existing blocked or
unresolved answer.

R8 (U5, Fable 8). `proof_trace.zig:583` branches on `!paths_exhaustive` for the
"not exhaustive" summary. It branches on `!fc.analysis_complete` instead, with
text that covers an unresolved route dispatch too.

R9 (U8, Fable 9). U8 is done: commit `b738b911`.

R10 (version, Fable). `path_analyzer_version` stays 3. The paragraph for 3 at
`path_generator.zig:195-203` is amended to describe the fixed analysis: a
failable call that a path condition tests is walked, an infeasible path is not
emitted, and negative request constraints. The direction argument for the
commit message: a pre-fix version 3 artifact under-claims `fault_covered`
relative to the fixed analysis (U1 only adds proven cases) and over-lists
behaviors (U3 removes paths). No stale local artifact can claim a property that
the fixed analysis refuses.

## Result

All eight units landed on local `main`: U8 `b738b911`, U2 `37f2954e`, U4
`51c87420`, U3 `dbbf4209`, U1 `1b3bd35c`, U5 `447ea1c7`, U7 `1dffdc82`, U6
`6d6cfdea`. `path_analyzer_version` stays 3 and the policy hash did not move.
On the merged tree, `scripts/verify.sh` and the offline
`zig build test-expert-app` (no `DEEPSEEK_API_KEY`) exited 0, so no re-record
is needed.

Two plan claims proved wrong:
- U1: `if (verifyWebhookSignature(...) && x)` is walked after the fix, not
  counted as unseen. Each `&&` conjunct that tests the call gives it a path
  constraint. A call under `||` gets no constraint and stays unseen.
- U6: the gate does not report the `fault_covered` change. `classify` and
  `behavioralVerdict` in `pr_gate.zig` ignore `effect_changes`, so no property
  change reaches the verdict. U6 makes each side's contract correct, and the
  tests assert `fault_covered` on each side through `checkSides`. Whether the
  gate ranks a property loss is an open decision for the owner.
