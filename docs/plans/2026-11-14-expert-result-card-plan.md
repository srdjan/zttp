# Expert result card and test run

Status: approved plan, revision 2, 2026-11-14, at commit `07a9dad2`. The owner
answered "a" on 2026-11-14: option (a) of D3R, D4, and D6. That authorizes U1
to U4 on local `main`, with no push, no paid model call, and no re-record. A Fable review and a Codex astra review checked revision 1. This
revision resolves their findings.
Source: [Expert interface options](2026-11-14-expert-interface-options.md). The
owner chose option (a) of D1 to D3 there. The review evidence below makes D3
(a) unworkable, so this plan asks the owner to decide D3 again (D3R).

## Goal

A developer states an intent in `zttp expert` and approves one card. Before the
approval, the card shows the verdict, the proof properties that the change
loses or gains, the contract changes, the result of the project test suite on
the candidate, and the diffs.

Steps today: 4 (start, intent, approve, run `zttp test`). Steps after this
plan: 3 (start, intent, approve). The proposal counted 5 steps today, with
"ask for tests" as step 4. That was wrong: the model cannot call the test
generator (finding 3).

## Findings that shape the plan

These are observations from the code at `07a9dad2`. The reviewers confirmed
each one, or I checked it myself.

1. `zttp init` writes `tests/handler.test.jsonl`
   (`packages/runtime/src/init_command.zig#scaffoldProject`). Every new project
   has a suite from the first turn.
2. A change set accepts `.ts` files only (`packages/pi/src/change_set.zig`).
   The model cannot change a test row.
3. `workspace_gen_tests` has effect `write_workspace`, and
   `packages/pi/src/registry/tool.zig#ToolDef.allowedOn` refuses that effect on
   the model surface. No recorded cassette contains the tool name.
4. pi cannot import the runtime test runner, because
   `packages/runtime/build.zig` imports `pi_app`. The corpus intent check starts
   the `zttp` binary instead
   (`packages/pi/src/expert_codegen_eval.zig#runIntentCheckCaptured`).
5. `zttp test` reads `tests/handler.test.jsonl` under the project root when no
   path is given, and it needs `zttp.json`
   (`packages/runtime/src/test_command.zig#testCommand`). It prints a `PASS` or
   `FAIL` line for each test and a final `Results:` line on stderr. It returns
   an error without a `Results:` line when it cannot run, for example with more
   than one `outboundHosts` entry or a failed pre-test check.
6. The proof overlay is deleted when `packages/pi/src/aggregate_proof.zig#prove` returns. The
   overlay holds the read set: `.ts`, `.js`, `.json`, and `.sql` files by
   suffix, plus the configured entry and policy. A configured SQLite database
   is rebuilt from its schema, without rows
   (`packages/pi/src/workspace_snapshot.zig#Snapshot`). Test suites are not
   in the read set.
7. The approval prompt (`packages/pi/src/repl.zig#approveEdit`) prints the file
   count, the proof id, and the diffs. It prints no verdict and no properties.
   `AggregateProof` holds `baseline_primary_properties` and
   `primary_properties`, and `packages/pi/src/ui_payload.zig#PropertiesSnapshot` (`forEachChange`)
   computes the delta.
8. `packages/zts/src/contract_diff.zig#diffContracts` computes env, egress,
   route, and capability changes. pi uses it for information
   (`packages/pi/src/proof_enrichment.zig#loadProveSummaryForPatch`), and live reload uses it as
   a gate. `scripts/module-boundary.allow` permits `pi contract_diff`.
9. Ten recorded `trace.json` files hold an approval preview digest, and
   `simulator/runner.zig` compares it at each approval.
   `packages/pi/src/simulator/observation.zig#approvalPreviewDigest` hashes only `proof_id`,
   the changes, and `system_proven`.
10. `TurnEndReason` has no member for a turn that proposes no change set. That
    turn reads `approved` (`packages/pi/src/session/events.zig#TurnEndReason`).
11. No path from `packages/runtime/src/dev_cli.zig#dispatchExpert` to `pi/src/app.zig`
    carries the path of the `zttp` executable today.
12. Standing decision D-003 keeps RPC mode removed. This plan adds no RPC mode.

### Why D3 (a) does not work

Fable probed a project from `zttp init`. It replaced the handler with a JSON
response and ran `zttp test`. The result was exit 1 with
`FAIL root renders greeting html`. Under D3 (a), the gate refuses that change
set. The model cannot edit the row (finding 2), so the turn either uses all 5
attempts and ends on `veto_exhausted`, or the model keeps the old greeting to
pass. The second outcome is the goal weakening that the proposal set out to
prevent. A rule that refuses only new failures fails the same way, because the
greeting row passes on the baseline. A runner that cannot run (finding 5) would
refuse every change set, and the model cannot fix that cause either.

## Units

Each unit gets its own commit on local `main`. No unit pushes, calls a paid
model, or re-records the corpus. Sonnet implements U1 to U3. Opus reviews each
diff line by line and runs each acceptance check again with an empty
`ZIG_LOCAL_CACHE_DIR`.

### U1: Result card

- Model: Sonnet. Turn budget: 40.
- Files: `packages/pi/src/loop.zig` (`ChangeSetApprovalPreview`,
  `applyVerifiedChangeSet`), `packages/pi/src/repl.zig`, and the test files
  beside them.
- Change: the preview carries the verdict, the property changes from
  `PropertiesSnapshot.forEachChange`, and the contract changes from
  `diffContracts`, baseline against candidate. A pure function renders the
  card in this order:
  1. the verdict line;
  2. each lost property;
  3. each contract change: an env name, egress host, route, or capability that
     the change adds or removes;
  4. each gained property;
  5. the test line, which U2 fills;
  6. the diffs, as today.
- Change: when a turn ends with no change set, the REPL prints one line that
  says that no change was proposed. `TurnEndReason` and the `--print` exit
  codes stay as they are.
- Kept: `--yes` behavior, and `approvalPreviewDigest`, which must not hash the
  new fields. The recorded cassettes then stay valid, and the render tests
  alone bind the new card lines.
- Acceptance: render tests with literal expected card text for a gained
  property, a lost property, an added egress host, and a removed route. One
  test for the no-change line. The existing `approveEdit`, `selectApprovalFn`,
  and `renderEditDiff` tests pass, or change only where the card adds lines.
  Unfiltered `zig build test-expert-app`, `zig build test-simulator`, and
  `zig build test` pass.

- Result, 2026-11-14: complete at `6667de86`. Opus review added removed
  capabilities and a tighter no-change rule: the line prints only when the turn
  recorded a result. A probe showed that a route matched with `req.path` in
  handler code is not in the check-mode contract. The card therefore shows
  router-registered routes only. `test-expert-app`, `test-simulator`,
  `test-module-boundary`, and `zig build test` exited 0 on an empty cache.

### U2: Test run before approval

- Model: Sonnet. Turn budget: 45.
- Files: `packages/tools/src/project_config.zig`,
  `packages/runtime/src/test_command.zig`, `packages/runtime/src/dev_cli.zig`,
  `packages/pi/src/app.zig`, `packages/pi/src/loop.zig`,
  `packages/pi/src/workspace_snapshot.zig` or `aggregate_proof.zig`, and the
  test files beside them.
- Test first: write the test "the card shows a failing suite row before
  approval". Its candidate passes the proof and fails one suite row. Run it
  before the change and confirm that it fails because the card has no failing
  row. Record that result in the commit message.
- Change, in this order:
  1. Move the default suite path `tests/handler.test.jsonl` into
     `project_config.zig`. `testCommand` and pi read it from there, so the rule
     has one home.
  2. `dispatchExpert` passes the path of the running `zttp` executable to pi.
     Tests pass the path from `locateZttpBinary`.
  3. In `applyVerifiedChangeSet`, before the approval call, and only under the
     interactive approval policy: when the project has the default suite, the
     host materializes the candidate overlay and runs
     `<zttp binary> test <absolute suite path>` with the overlay as working
     directory, stdin closed, and the output bounded.
  4. The host maps the result to one of three test lines. A `Results:` line
     means the suite ran: the card names the suite file, shows the `Results:`
     line, and lists each `FAIL` row first. No `Results:` line means the suite
     could not run: the card shows the first error lines. No suite, or no
     binary path, gives "Tests: none" or "Tests: could not run" with the cause.
  5. The result goes to the developer only. The model sees nothing new, and
     the gate rule is as chosen in D3R.
- Kept: `autoApprove`, `--yes`, `--print`, the corpus replay, and the
  stand-in run no tests, because no card consumes the result.
- Acceptance: the first test passes. Literal card tests for a passing suite,
  a suite that cannot run, and no suite. A probe on a project from `zttp init`
  with a configured SQLite database shows the same `Results:` line in the card
  as `zttp test` gives on disk. Unfiltered `zig build test-expert-app`,
  `zig build test-standin`, `zig build test-module-boundary`, and
  `zig build test` pass.
- Measurement: time `zttp test` on a project from `zttp init` with
  `hyperfine -N -i`. This includes the second analyzer run of the pre-test
  check. The result is the latency that the card adds when a suite exists.

- Result, 2026-11-14: complete at `77a8494f`. The test-first test failed before the
  change because the card ended after the verdict line. `zttp test` on a
  `zttp init` project took 48.0 ms on average (Debug build, hyperfine). All U2
  gates exited 0 on an empty cache. Open risk: the run has no timeout, so a
  suite that does not end would hold the approval prompt. The handler profile
  has no `while` loop, and `for...of` walks a finite array. No timeout was
  added without evidence that a run can hang.

### U3: Documentation and website

- Model: Sonnet. Turn budget: 25.
- Files: `docs/user-guide.md` (Expert Mode, "How a turn runs"),
  `docs/cli.md` (Expert Mode), `CONCEPTS.md` if it defines the approval
  prompt, and `../ZTTP-WEBSITE/static/index.html`.
- The docs say that the card reports the result of the project suite, and that
  the suite is only as strong as its rows. A suite from `zttp gen-tests`
  checks the status code of each path.
- Acceptance: `zig build check-spine` passes after `git add`. In
  `../ZTTP-WEBSITE`, `deno task verify` passes and the change is committed
  locally. The website states the feature as a development change, not a
  release.

### U4: Closing validation

- Owner of the work: Opus.
- A Fable subagent and Codex astra review the combined diff of U1 and U2 with
  split briefs. Fable attacks the argument with probes. Codex checks the facts,
  the ownership, and the driver paths. Each brief carries the diff and this
  plan, not my conclusions.
- Probes: the four U1 card cases and the three U2 test lines on a scratch
  project. The interactive card needs a model turn. If the owner provides one,
  I run it. Otherwise the render tests and the U2 tests are the evidence, and
  the report says so.
- Mutants, each run against the unfiltered step: drop the lost properties from
  the card, drop the removed routes, treat a missing `Results:` line as a pass,
  ignore a missing binary path, and run the suite on the disk workspace instead
  of the overlay. Each mutant must fail a test.
- Final gate: `env -u DEEPSEEK_API_KEY bash scripts/verify.sh`.

## Out of scope

F3 to F6 of the proposal, F2 as a card before code (D4), any RPC mode, any
change to the persona or the tool catalog, test generation by the model, and
any corpus re-record.

## Decisions

**D3R: What a failing test does.** This replaces D3 of the proposal.

- (a) The card shows the failing rows first, and the developer approves or
  rejects. The model gets no retry. Recommended.
- (b) The model gets one retry with the failing rows. The card then shows the
  result of the second draft. This costs one model call for each failing
  suite, and it adds pressure to weaken the handler when a row is stale.
- The original D3 (a), refusal as a veto, is not offered. The section "Why D3
  (a) does not work" gives the evidence.

**D4: F2, the contract card.**

- (a) The card shows the contract changes after code (U1). F2 as a card before
  code is deferred. No new tool, no re-record, and no loss of session resume.
  Recommended.
- (b) Plan F2 as a card before code for the next re-record window. This needs
  a new tool, a persona line, a full corpus re-record that the owner runs, and
  a new protocol identity. Existing sessions stop resuming.

**D6: Execution.**

- (a) Run U1 to U4 on local `main` with one commit for each unit, no push, no
  paid model call, and no re-record. Recommended.
- (b) Stop after this plan.
