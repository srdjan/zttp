# Reset worklog, 2026-10-25

Plan: [2026-10-25-reset-implementation-plan.md](2026-10-25-reset-implementation-plan.md). The plan owns findings, phases, and acceptance.
This worklog records execution, commands, exit statuses, and stop-rule results.

## Decisions

- 2026-10-25: the owner answered "as recommended". This selects option (a) for Decisions 1 to 5.
- 2026-10-25: the owner chose Decision 6 (a). R0 waited until the concurrent session finished.

## Environment

- Private caches: `ZIG_LOCAL_CACHE_DIR=/private/tmp/claude-501/zttp-reset-20261025/local`, `ZIG_GLOBAL_CACHE_DIR=/private/tmp/claude-501/zttp-reset-20261025/global`.
- `DEEPSEEK_API_KEY` is unset for every run.
- Logs: `/private/tmp/claude-501/zttp-reset-20261025/logs/`.

## R0. Baseline and preservation evidence

- Base commit: `315559e808392d4e579fa182814c3516b0a19c80`. Tree: `4d4153885f67ff2b61101e1882000e9e91586ac8`.
- `git status --porcelain` printed nothing at the base.
- Full gate: `bash scripts/verify.sh` exit 0 after 863 seconds; the log ends with "all per-commit gates passed". Log: `r0-verify.log`.
- Analyzer digests (step 6): `zig build` exit 0. The loop over `git ls-files 'tests/corpus/**.ts' 'examples/**.ts'` digested 215 sources: 69 exit 0, 146 exit 1, 203 distinct digests.
- Determinism (step 7): two runs are byte-identical (`cmp`). The kept file is `/private/tmp/claude-501/zttp-reset-20261025/analyzer-digests.txt`, SHA-256 `dc517607120da3ae21f3ad02afaf5edc99d0fa18405284390c70337967da5b80`. No case is excluded.
- F14 measurement (step 8), first attempt: five `zig build test` runs without `-j1` all exited 0 in 82 to 103 seconds. This is not evidence: run 1 reported 157 cached steps, so most tests did not execute. The repeat uses a fresh local cache for each run.
- F14 measurement, repeat: five `zig build test --summary all` runs, each with a fresh local cache. All exited 0 in 124 to 177 seconds, each with "213/213 steps succeeded; 7765/7771 tests passed (6 skipped)". Process-wide state is therefore not a measured cause of the macOS `-j1` need, and R11c is dropped as the plan specifies. `-j1` stays in `tooling/verify.zig`.
- Counts at the base: aggregate 7765 passed of 7771 (6 skipped); `test-zruntime` 239 passed of 240 (1 skipped); `test-cli` 618 passed, 1 skipped. The ordered `run test` counts are in `/private/tmp/claude-501/zttp-reset-20261025/r0-step-counts.txt` (SHA-256 `c65127e8bb1bdf97db5e3e1512d84288b8e0f6ee358e1cdf70ca264ad11dfef9`).
- Bytecode identity golden (steps 3 to 5): `packages/tools/src/bytecode_identity_golden.zig` and its embedded golden `bytecode_identity_golden.txt`. Each `examples/` and `tests/corpus/check/good` handler compiles through `precompile.compileHandler` with the options of the build command. 63 inputs: 58 digested, 5 refused by name. The floor is 60 inputs, and at least half must be digested. Write mode: `ZTTP_WRITE_BYTECODE_GOLDEN=1` from a fresh cache.
- Determinism: two runs from an empty cache gave the same golden. A one-byte sabotage of a golden line made `test-precompile` and `zig build test` exit 1 with "bytecode identity drift" and the path.
- Limits: the test reads handler sources at run time, so a cached pass after an edit to `examples/` or the corpus can be stale. The test walks directories, so an untracked `.ts` file under those roots fails it. Five aggregate roots analyze `precompile.zig`, so the aggregate runs the test five times (7765 to 7770 tests). The aggregate took 131 seconds after the change, inside the 124 to 177 second range at the base.
- After the cherry-pick: fresh-cache `zig build test` exit 0 (7770/7776 passed, 6 skipped); `zig build check-spine` exit 0; the protection check against `315559e8` exit 0.
- R0 exit: complete. The bytecode golden joins the protection list from R1 on.

## R1. Authority documents

- `docs/roadmap.md`: the stale review header and the reset paragraphs now name the 2026-10-25 plan as the reset authority and the 2026-10-14 reset as complete. The paragraph about the completed 2026-10-20 hardening plan was removed.
- `docs/plans/README.md`: added this plan and worklog. The 2026-10-14 row and the archive note now say that plan is complete and no longer the authority.
- `advisor-plans/README.md`: plan 005 Phase 4 is closed by the 2026-10-14 reset (`ad1aa961` to `10115d98`).
- Exit check: `git grep -i 'reset authority|active reset'` finds only rows that name the 2026-10-25 plan as the authority.
- Gates, staged tree: `test-doc-links`, `test-docs-drift`, `check-spine`, `zig build test` all exit 0. The protection check against `e1ed0d34`, including the bytecode golden, exit 0.

## R2, R3, R11a, R11b, R11d

Two Sonnet workers ran these phases in separate worktrees from `eb30c586`. Opus reviewed each commit and cherry-picked them onto `main`.

| Commit | Phase | Result |
|---|---|---|
| `90ddf21e` | R2 | `binding_key.zig`, `handler_function.zig`, `ok_record.zig`, and `source_line.zig` hold the moved helpers. `root.zig` keeps each export name. `flow_interp.zig` no longer imports `path_generator.zig`. Only `parser/error.zig` takes the shared source-line body; the copies in `repair_validator.zig` and `canonicalize.zig` differ and stay. |
| `de2e086b` | R3 | `pipeline.check` deleted. It had five test call sites, not three; they now run `CheckedModule.init`, `runVerifier`, and `runFlow` with the same allocation-failure assertions. Stale comments and the `legacy_parser` and `legacy_atoms` names corrected. |
| `6fbee685` | R11a | The F10 defect is confirmed: the new regression test failed before the fix (expected `handler.ts`, found `/x`). `cli_shared.serve_value_flags` is the one table. Limit: the parser still dispatches by hand, so a value flag added only to the parser is not caught. |
| `972fd065` | R11b | `providers/response_sanitize.zig` holds the shared parse, depth check, inspection, and reasoning removal. `ReasoningRule` selects the provider rule. `decodeResponseValue` stays in each client, because tool-call ids and raw tool envelopes differ. Request building is unchanged. |
| `c8eeed94` | R11d | `check-meta-drift.sh` reads the policy pin from `policy-hash.txt`. A scratch probe showed that the new read fails on a changed hash. |
| this commit | R2 review fix | The moved `findHandlerFunction` and `returnsOkRecord` left the files that `check-proof-swallow.sh` lists. `handler_function.zig` and `ok_record.zig` are added to that list, and `AGENTS.md` now says thirty files. |

Integrated gates on `main` with the review fix staged, each exit 0: `test-proof-swallow`, `test-zts`, `test-zts-layering`, `test-module-boundary`, `test-precompile`, `test-cli`, `test-zruntime`, `test-cassette`, `test-expert-app`, `test-recorder-smoke`, `test-meta-drift`, `test-expert-golden`, `check-spine`, `test-docs-drift`.
Fresh-cache `zig build test --summary all`: exit 0, 7773/7779 passed (6 skipped). The three added tests are the R11a regression tests.
Analyzer digests: byte-identical to R0 (`cmp` exit 0). Protection check against `eb30c586`: exit 0.

`release-provenance` fails at `eb30c586`, before any reset change: `docs/coverage.json` is stale against sourceCommit `56433c50`. It is a release-readiness gate, not a per-commit gate. The offline republish rewrites protected evidence files, so it waits until after R13 and needs its own owner step.

## R4 owner checkpoint

The dry-run census substituted 199 test sites. Then 22 of 3042 `test-zts` tests failed. The real `zts check` confirms that production refuses `void` ("write `undefined`") and `any`, and that it parses `identity<T = /,/, U>` and refuses it with ZTS601. No row showed a user-visible production difference.
- 2026-10-25: the owner chose Decision 7 (a). Rows 1 and 2 are deleted. Rows 19 to 22 change `: void` to `: undefined`. The G1, G3, G4, G5, and G6 rows expect the production value and assert refusal locations through admission diagnostics.

## R4

| Commit | Phase | Result |
|---|---|---|
| `0db65951` | R4a | 53 test sites outside `typed_frontend_tests.zig` use `initAdmission(.compile)`. Rows 1 and 2 (tests of the removed typed-only mode) are deleted. Rows 19 to 22 use `: undefined` and keep their assertions. |
| `bd8f1658` | R4b | The worker's mechanical commit (`initTyped(` 146 to 0, `initAdmission(` 7 to 153) and its expectation commit are squashed, so `main` has no commit with failing tests. No test is deleted; one is renamed (row 14). |
| `201c63e9` | R4c | `JsParser.initTyped` is deleted, together with the tail of `Parser.parse` that ran only for a typed parse without admission. `init` and `initExpression` do not parse type syntax, and `initAdmission` returns earlier, so the tail was unreachable. |

Row 18 needed a ruling during R4b. Production reports `const value: = 1;` as `unexpected_token` at offset 11 and `missing_semicolon` at offset 6, while the typed-only mode reported offset 13. Production output does not change, so this is the G3 and G4 ruling: the test asserts the exact production counts and locations. The reported location of a missing type (the colon, not the `=`) is a diagnostic-quality candidate for the Decision 2 window.

Gates on `main`, each exit 0: `test-zts`, `test-zts-cli`, `test-diagnostic-corpus`, `test-standin`, `test-precompile`, `check-spine`. Fresh-cache aggregate: 7771/7777 passed (6 skipped); the delta of 2 is the two deleted tests. Digests: byte-identical. Protection against `ea02c3f7`: exit 0. `git grep -n 'JsParser.initTyped' -- packages` prints nothing.

## R6b, R6c, R6d

| Commit | Phase | Result |
|---|---|---|
| `2ebf2e33` | R6b | `precompile.zig` goes from 12,647 to 1,768 lines. Nine sibling files hold the CLI, the CHECK facade (`precompile_check_run.zig`), contract and policy building, SQL validation, reports, test generation, virtual-import validation, stderr helpers, and the CHECK tests. D-006 now also binds `precompile_check_run.zig`. |
| `07625ffc` | R6c | `agent_protocol.zig` goes from 6,327 to 727 lines across ten operation files. `schemaHash` and the meta payload moved unchanged. |
| `3a71cedb` | R6d | `ConnectionPool` moves to `server_connection_pool.zig`. `check-runtime-purity.sh` checks both files; a probe with an added zts import failed the gate. |
| this commit | R6b review fix | `precompile.zig` was never in the proof-swallow list. `precompile_check_run.zig` and `precompile_contract.zig` are added. Opus reviewed all 23 sites: the verdict is `CheckResult.totalErrors()`, the sum of the stage counters. Each site either drops presentation after its counter is set, or converts the error into a counted refusal. Two silent `else` arms got `// exhaustive:` reasons. The gate reports 32 files, 185 reviewed swallows, 0 unreviewed. |

`git show --color-moved=plain` agrees with the motion claim: the non-moved added lines are headers, imports, re-exports, and signatures that gained `pub` (195, 255, and 60 lines).
Gates on `main`, each exit 0: `test-precompile`, `test-agent-protocol`, `test-contract-golden`, `test-proof-swallow`, `test-module-boundary`, `test-cli`, `test-production-branch-metric`, `test-expert-golden`, `test-agent-determinism`, `test-meta-drift`, `test-server`, `test-zruntime`, `test-panic-isolation`, `test-runtime-purity`, `test-docs-drift`, `check-spine`. Fresh-cache aggregate: 7771/7777 passed (6 skipped). Digests: byte-identical. Protection against `201c63e9`: exit 0.
`AGENTS.md` says that `server.zig` holds the path traversal checks; they live in `server_static.zig` (`resolveStaticFile`). R13 corrects that sentence.

## R6a, R6e, R5

| Commit | Phase | Result |
|---|---|---|
| `5f9d44a4` | R6a | `type_syntax.zig` (12,697 lines) becomes a facade of 2,727 lines over `type_syntax_store.zig`, `type_syntax_scan.zig`, `type_syntax_parser.zig`, and `type_syntax_support.zig` (the test runtime). |
| `612505ae` | R6e | The tests of `flow_checker.zig` (5,536 to 152 lines) and `pipeline.zig` (5,288 to 1,636 lines) move to `flow_checker_tests.zig` and `pipeline_tests.zig`. The R6a and R6e diffs remove 313 tests and add 313 tests. |
| `08f459bf` | R5a | Typed `IRStore` constructors (`addCall`, `addFunction`, `addMember`, and the others) replace `IRStore.add(Node)` at every call site. Each constructor packs the same fields as the old adapter arm. |
| `27301601` | R5b | `IRStore.add`, `IRStore.get`, and the struct form of `Node` are deleted. `Node` stays only as the namespace of the payload types. The test `node creation` tested the deleted adapter and is deleted. The cherry-pick conflicted with R6a, because R6a moved `TestRuntime` to `type_syntax_support.zig`; the R5b hunk is applied there. |
| this commit | R6e review fix | `pipeline.zig` imported `pipeline_tests.zig` at the top level for an unused `JsParser` alias. The two lines are deleted. |

Gates on `main` at `27301601`, each exit 0: `test-zts`, `test-zruntime`, `test-examples`, `test-contract-golden`, `test-meta-drift`, `test-proof-checker`, `test-zts-layering`, `test-diagnostic-corpus`, `test-step-coverage`, `test-proof-swallow`, `test-module-boundary`, `test-docs-drift`, `test-standin`, `test-cli`, `check-spine`, and a fresh-cache `test-precompile` (bytecode golden).
Fresh-cache aggregate: 7770/7776 passed (6 skipped). The delta of 1 from R4 is the deleted `node creation` test. Digests: byte-identical. Protection against `a7a4462f`: exit 0. After the review fix, `test-zts` exits 0.
`git grep` for `nodes.add(` and `IRStore.get` prints nothing.
Open: the R5 `bench-check -Doptimize=fast` gate waits for a host with load under 4. Two workers run in parallel now, and the load was 3.91 to 9.01 at the gate run.

## R12a

| Commit | Phase | Result |
|---|---|---|
| `e4621702` | R12a | `review.zig`, `printer.zig`, `json_util.zig`, and `spec_diagnostic.zig` move from `packages/proof-review/src/` to `packages/runtime/src/proofs/` as renames with unchanged content. The package, its zon dependency, the double-instantiation comment in `build/Context.zig`, and the `test-proof-review` step are deleted. `main.zig` collects the 28 moved tests in the counted runtime root. `runtime_main_tests` and `zruntime` gain the `zts_cli` import that `review.zig` needs. No module-boundary row changes: the moved code reaches no zts internal. |
| this commit | R12a review fix | One line in `docs/internals/testing.md` is rewrapped. |

The 28 moved tests also run in `test-cli` (621 to 649) and `test-zruntime` (239 to 266), because those roots import the moved files. Those counts do not enter the aggregate summary.
Gates on `main` with the review fix staged, each exit 0: `test-cli`, `test-step-coverage`, `test-docs-drift`, `test-module-boundary` (71 internals, 53 allowed reaches, unchanged), `test-production-branch-metric`, `test-zruntime`, `test-doc-links`, `test-server`, `test-runtime-purity`, `check-spine`, and a fresh-cache `test-precompile`.
Fresh-cache aggregate: 211/211 steps, 7770/7776 passed (6 skipped). The count is unchanged; the two deleted steps are the compile and run steps of `test-proof-review`. Digests: byte-identical. Protection against `fe84f8fc`: exit 0.

## R7

| Commit | Phase | Result |
|---|---|---|
| `bf446cc5` | R7a | The standalone checker and the extraction checker never exist together, so they become one `contract_checker` slot. `FullConfig` is deleted; the full profile fills the same `extraction_opts` as the other profiles. A custom `type_check` callback with no manifest registry no longer builds a second `ModuleFacts`, because without a registry the two copies are equal. |
| `2202281f` | R7b | `ModuleAnalysisSession.extractContract` runs the selected flow pass when it has not run and applies its properties. `projectParsedFlow` and its second `FlowChecker` are deleted. `FlowWithoutHandler` keeps both old rules for a module with no handler: `keep_defaults` for the precompile callers and `unproven` for the three one-shot entry points. Multi-module sessions select no flow, as before. `projectCompletedFlow` becomes `reportCompletedFlow`, which only prints and collects violations. One test now expects flow to run during extraction, and one test covers the two no-handler rules. |

Opus review of R7b: every caller that selects flow was checked. CHECK runs flow before extraction, so `applyFlow` projects the completed pass as the old call did. `compileHandler` ran flow directly after extraction, and now extraction runs it. The compile benchmark runs flow without extraction and is unaffected. A caller that reached extraction with an incomplete pass got `AnalysisPassIncomplete` before and gets it now.

R7a exit deviation (Decision 8 in the owner report, provisionally option (a)): `pipeline.zig` still declares a second checker and environment. Only the custom `type_check` callback session (runtime serve) uses them, because the callback must run on a fresh checker after `resolve` has checked the first one. Removing the pair would run the check twice. The resolution and contract `ModuleFacts` differ when a registry is set, and the two flow-checker slots are exclusive by profile.

R7c census, 182 `tests/corpus` cases: the pi tools refuse 39 before analysis (17 admission, 22 parse), and production reports a diagnostic in each. Of the 143 cases that the tools analyze, 46 equal production and 97 differ, because production runs stages that the bare checkers lack (148 such diagnostics). In 9 cases the tools report 10 bare-only diagnostics (ZTS305, ZTS306, ZTS400, ZTS401, ZTS407) where production reports one diagnostic from an earlier stage; the probable cause is that production stops before flow or verification, which a stage trace of those 9 cases can confirm. In 12 cases `pi_repair_plan` differs from the two flow-only tools. Limits: cassette inputs were not run, and the comparison uses code and position, not message text. The move of the tools stays class B under Decision 2.

Gates on `main`, each exit 0: `test-zts`, `test-precompile`, `test-contract-golden`, `test-cli`, `test-zruntime`, `test-expert-app`, `test-standin`, `test-diagnostic-corpus`, `test-flow-census`, `test-expert-golden`, `test-proof-swallow`, `test-compile-bench`, `check-spine`, and a fresh-cache `test-precompile`. Fresh-cache aggregate: 211/211 steps, 7771/7777 passed (6 skipped); the delta of 1 is the new no-handler test. Digests: byte-identical. Protection against `acddbffc`: exit 0. `git grep -n projectParsedFlow -- packages` prints nothing.

## R12b

| Commit | Phase | Result |
|---|---|---|
| `9f30af51` | R12b-1 | `tooling/zts_graph_gate.zig` gains the `module-boundary` and `kernel-leaf` subcommands (`tooling/module_boundary_gate.zig`, `tooling/kernel_leaf_gate.zig`) with 34 tests on in-memory inputs. |
| `84fae480` | R12b-2 | `test-module-boundary` and `test-proof-checker-purity` run the built gate with `has_side_effects`. `check-module-boundary.sh`, `check-proof-checker.sh`, `test-module-boundary.sh`, and one `manual-scripts.allow` row are deleted. D-005 binds `tooling/zts_graph_gate.zig` and records the move. |

The worker ran 29 module-boundary probes and 61 kernel probes on scratch copies of the tree, first against the old scripts and then against the new gate. All 90 give the same exit status. Three deviations are deliberate. The new scan counts every reach on a line; the awk scan read only the first, so two reaches on one line passed before. The probe that injected a failing `awk` has no subject now; an unreadable file covers that rejection. The old kernel script crashed under bash 3.2 before its last census check; the new gate runs it. New floors, not triggered on the tree: a scan with zero reaches fails, and an unreadable kernel file or a failed `git ls-files` fails with its own message.
Opus review: the scan resets aliases per file, and the git pathspec `packages/<pkg>/*.zig` matches nested files, so `bench/` stays in scope. The code moves from 535 shell lines to about 1,610 Zig lines, including the tests.
Gate output, unchanged before and after: `module boundary: OK (71 internal modules, 53 allowed package reaches)` and `proof-checker: leaf boundary holds; 199 tests across 13 files`.
Gates on `main`, each exit 0: `test-module-boundary`, `test-proof-checker-purity`, `test-zts-layering`, `test-native-gates`, `test-script-reachability`, `test-step-coverage`, `test-docs-drift`, `test-doc-links`, `test-spine`, `check-spine`. Fresh-cache aggregate: 211/211 steps, 7805/7811 passed (6 skipped); the delta of 34 is the new gate tests. Digests: byte-identical. Protection against `6b07bd5a`: exit 0.

## R8 stop and rulings

The R8 census compared 352 type texts between `TypeExprParser` and the standalone annotation entry: 239 signature census rows, 16 declared module signatures (5 returns, which are the `returnsOkRecord` inputs, and 11 parameters), 13 ambient rows, and 84 literal texts from tests. Two disagree: `bool` and `bool[]`. The old parser reads `bool` as `boolean`; the one grammar reads it as an unresolved name. No binding, ambient row, or census row uses `bool`.
Opus measured production on `main`: a handler annotated `bool` fails `zts check` with ZTS203 ("expected bool, got true") and ZTS100, and the same handler with `boolean` passes the type stages. Authored `bool` is already refused, so the change moves no production output. Ruling: the ambient test asserts that `bool` does not resolve, and its comment is corrected. `resolveType` keeps its name and calls the one grammar. Tests of the old grammar are deleted with it, pool tests move to the new entry, and parity tests become exact canonical-key assertions.

## R12c

| Commit | Phase | Result |
|---|---|---|
| `4d469b52` | R12c-1 | `scripts/test-gate-floors.sh` takes the built kernel-safety gate as its argument, and `addGateFloorProbe` passes it. The empty-list and 12-file probes fail with the same exit status and text as before. |
| `4440f1df` | R12c-2 | The no-argument rebuild branches of `check-agent-determinism.sh`, `check-meta-drift.sh`, `check-zts-layering.sh`, `test-release-workflow.sh`, `check-kernel-safety.sh`, `check-residual-guards.sh`, and `run-production-branch-metric.sh` are deleted (452 to 419 lines). Each script refuses a missing argument or a non-executable path with a usage message and a non-zero exit. `docs/internals/agent-protocol-v2.md` said that `verify.sh` runs the determinism gate; it now names `zig build test-agent-determinism`. |

Before the edit, the worker confirmed that every build route passes the artifact and that no script, workflow, or AGENTS file runs the seven scripts directly.
Gates on `main`, each exit 0: `test-script-reachability`, `test-capability-audit` (runs the gate-floor probe), `test-agent-determinism`, `test-meta-drift`, `test-zts-layering`, `test-release-workflow`, `test-kernel-safety`, `test-residual-guards-drift`, `test-production-branch-metric`, `test-step-coverage`, `test-docs-drift`, `test-doc-links`, `check-spine`. Fresh-cache aggregate: 211/211 steps, 7805/7811 passed (6 skipped), unchanged. Digests: byte-identical. Protection against `763eb37e`: exit 0.

## R12d-1

| Commit | Phase | Result |
|---|---|---|
| `557cb1a5` | R12d-1 | `build/step_coverage.zig#classify` is the one walk of the build graph. It sorts each top-level step as `aggregate`, `verify`, `release`, or `manual`, and `test-step-coverage` reads its facts from it. The task census carries `<name> <route>`, and every `agents.json` task carries a route; a manual task also carries a reason, and only a manual task does. `check-spine` fails a missing route, a value outside the four, a route that differs from the graph, a manual task without a reason, and a reason on another task. |

Route counts over 92 tasks: 66 aggregate, 4 verify, 4 release, 18 manual. The 18 manual tasks are the 18 rows of `scripts/manual-steps.allow`, with the same reason slugs. The worker probed seven scratch edits of `agents.json`; each made `check-spine` exit 1 with a message that names the task and the graph value. `test-spine` adds one test with six rejection scenarios.
Opus review: the aggregate set is a subset of the verify set, which is a subset of the covered set. So the manual and release-only verdicts equal the old ones, and the output line `step coverage: OK (92 steps, 18 run by hand with a stated reason, 4 run only at release)` is unchanged. A step with no dependency steps counts as aggregate, as it counted as run before.
Gates on `main`, each exit 0: `test-spine`, `test-step-coverage`, `test-script-reachability`, `test-docs-drift`, `test-doc-links`, `check-spine`. Fresh-cache aggregate: 211/211 steps, 7806/7812 passed (6 skipped); the delta of 1 is the new spine test. Digests: byte-identical. Protection against `e0dc252b`: exit 0.

## R12d-2

| Commit | Phase | Result |
|---|---|---|
| `29a843fc` | R12d-2a | `scripts/manual-steps.allow` (18 rows) is deleted. `agents.json` and `check-spine` own the manual-step declarations. `test-step-coverage` reports the classification and keeps its census floors. |

Parity probe on scratch copies, before the deletion: a deleted row for `run`, a row for the covered `test-zts`, and a row for a missing step each made the old `test-step-coverage` and the new `check-spine` fail on the same task. A scratch build step that nothing reaches fails `check-spine` and `zig build test`; `test-step-coverage` alone now passes it, by design.
Deviations from R12 step 5, for the owner report:
- `scripts/manual-scripts.allow` stays (10 rows). Scripts are not build tasks, so the route field has no successor for it.
- Unit 2b is not done. The table that `check-docs-drift.sh` compares is the host test roots table, and its Root column comes from `build/host_tests.zig#host_test_roots`, which `agents.json` does not carry. The table stays hand-kept, and the comparison stays as its link to the build.

R12 exit numbers, R0 (`f52d8e4a`) to now: build steps 93 to 92, files under `scripts/` 54 to 50, shell scripts 43 to 40, allowlist rows 458 to 472. The allowlist exit condition is not met (Decision 9 in the owner report). `manual-steps.allow` (18) is gone and `manual-scripts.allow` went from 11 to 10. `proof-swallow.allow` grew from 162 to 185, because R2 and R6b brought moved analysis code under that gate. `zts-tiers.allow` grew from 171 to 181, because each new zts file from the R2 and R6 splits needs a tier row.
Gates on `main`, each exit 0: `test-spine`, `test-step-coverage`, `test-script-reachability`, `test-docs-drift`, `test-doc-links`, `check-spine`. Fresh-cache aggregate: 211/211 steps, 7806/7812 passed (6 skipped). Digests: byte-identical. Protection against `f0249694`: exit 0.

## R9a

| Commit | Phase | Result |
|---|---|---|
| `4cf853d5` | R9a | `HandlerProperties.coverageProblem` checks a property list by name: every `HandlerProperties` field is a member or is excluded with a reason, every member is a field (of the same type, for a struct), and no name is both. `FlowProperties`, `counterexample.PropertyTag`, `spec_discharge.PropertyField`, and the flow census and precision enums call it at compile time. Each list is an explicit subset. No enum order changes. |

Exit probes on scratch copies: removing `cost_bounded` from `HandlerProperties` fails `test-zts` (exit 1) and `test-flow-census` (exit 1) with "exclusion names no HandlerProperties field: cost_bounded" in each list. Adding `probe_new_property` fails both with "HandlerProperties field is neither a member nor excluded: probe_new_property".
R9b census: six `formatDiagnostics` exist. Five (bool, flow, verifier, strict, type) are one function that differs only in the scope text and the kind-to-code mapping. A throwaway test over six sources found 0 byte differences between each formatter and the projection with one shared writer. Fault coverage prints another shape and stays separate. The merge is class A on this evidence.
Gates on `main`, each exit 0: `test-diagnostic-corpus`, `test-expert-golden`, `test-cassette`, `test-meta-drift`, `test-zts`, `test-proof-swallow`, `test-contract-golden`, `test-flow-census`, `test-module-boundary`, `test-zts-layering`, `check-spine`. Fresh-cache aggregate: 211/211 steps, 7807/7813 passed (6 skipped); the delta of 1 is the `coverageProblem` test. Digests: byte-identical. Protection against `8e366ac2`: exit 0.

## R8

| Commit | Phase | Result |
|---|---|---|
| `d6c6e0a4` | R8a | `type_syntax_lowering.parseTypeText` parses one whole standalone type text with the authored-source parser and lowers it into the pool. `TypeEnv.resolveType` (and so `module_types`, `ambient_names`, and `ok_record`), the signature census, and the agent protocol digest test call it. The ambient test asserts that `bool` does not resolve. |
| `e05e9231` | R8b | `TypeExprParser`, `parseTypeExpr`, and their two identifier helpers are deleted (`type_pool.zig` loses about 700 lines). 44 `type_pool` tests, 11 `type_env` tests, and one typed-frontend test call `parseTypeText` with unchanged assertions; none is deleted. The three parity tests assert the canonical keys and pool names that the old parser produced, recorded before its removal. |

The census was repeated after the whole-text rule was added, with the same result: 0 disagreements except `bool` and `bool[]`. For four malformed groups the old parser returned null but left stray names in the pool; `parseTypeText` leaves the pool unchanged.
Gates on `main`, each exit 0: `test-modules`, `test-zts`, `test-precompile`, `test-flow-census`, `test-zts-layering`, `test-proof-swallow`, `test-meta-drift`, `test-contract-golden`, `test-diagnostic-corpus`, `test-module-boundary`, `test-agent-protocol`, `test-cli`, `test-zruntime`, `check-spine`. Fresh-cache aggregate: 211/211 steps, 7807/7813 passed (6 skipped), unchanged. Digests: byte-identical. Protection against `4cf853d5`: exit 0. `git grep -n TypeExprParser -- packages` prints nothing.

## R9b

| Commit | Phase | Result |
|---|---|---|
| `c2b5e4c1` | R9b-1 | `diagnostic_projection` gains `scopeText`, `writeProjected`, and `writeAll`. The bool, flow, verifier, strict, and type `formatDiagnostics` are each one `writeAll` call. Fault coverage keeps its own formatter. |
| `c31846ba` | R9b-2 | `HandlerProperties.namesCoverageProblem` checks lists that name properties as data: `contract_diff.propertyLossSeverity`, `spec_discharge.suggestionFor`, `proof_trace.property_info`, the attestation header chip list, and the precompile properties report. The loss-severity and suggestion chains become tables read by the same functions. |

Extended census before the merge: 134 synthetic diagnostics over every severity, four help shapes, and three positions, with 0 differences against the projection path. The 982-line formatter dumps before and after the merge are byte-identical. Opus checked R9b-2 by diff: the 12 suggestion names and texts are identical, the loss-severity map is unchanged, and the report rows keep their order and text. A scratch field added to `HandlerProperties` fails each of the ten property lists.
Gates on `main`, each exit 0: `test-diagnostic-corpus`, `test-expert-golden`, `test-cassette`, `test-expert-app`, `test-standin`, `test-meta-drift`, `test-zts`, `test-precompile`, `test-zts-cli`, `test-proof-swallow`, `test-contract-golden`, `test-flow-census`, `test-cli`, `test-zruntime`, `test-zts-layering`, `test-module-boundary`, `test-docs-drift`, `check-spine`. Fresh-cache aggregate: 211/211 steps, 7807/7813 passed (6 skipped), unchanged. Digests: byte-identical. Protection against `89882288`: exit 0.

## R13a and R10a, R10b

| Commit | Phase | Result |
|---|---|---|
| `ebcf5c97` | R13a-1 | `AGENTS.md` names `resolveStaticFile` in `packages/runtime/src/server_static.zig` for the path traversal checks, the three CHECK files of the proof-swallow list, and thirty-two files. The architecture, testing, protocol, and area documents describe the reset design. |
| `3eb976df` | R13a-2 | Decisions D-010 (tests use the production parse mode), D-011 (each analyzer fact has one producer), and D-012 (model-visible changes wait for one re-record window). The D-005 amendment from R12b is present. |
| `e58b46df` | R13a-3 | `.agents/skills/zttp-models/SKILL.md` is a link to `../../../.claude/skills/zttp-models/SKILL.md`. The two copies were the same blob before the change. |
| `1d156b41` | R10b | `IrView.expressionChildren` already names all 69 node tags with no `else` arm. `parser/ir_children_tests.zig` adds one decision row per tag (27 yield children, 15 leaf with a reason, 27 not produced by the parser) and checks the yielded children against parsed witnesses. |
| this commit | R13a review fix | D-010 states the measured count: 199 test sites, from the R4 census. |

R10a census (96 node-tag switches in the 32 proof-swallow files): 4 name every tag, 8 descend through the child visitor, and the rest return a constant, delegate, or carry an `// exhaustive:` reason. Of 30 walk-like switches with a non-descending default, 27 carry a reason. Two delegate to their expression walk. `proof_ir.build` maps unlisted tags to a leaf; its module header states that the lowering keeps the six node kinds that totality depends on, so this is the design and not a skip.
R10a route probe: 22 route shapes, each returning `env("SECRET_KEY")` from the route body. 19 are refused, 1 clean control proves clean, and 5 stop at an earlier stage with no contract. No shape proves a leak clean. Limit: one leak form, typed `.ts` sources only.
Opus scope ruling for R10c: classifiers and recognizers that return a conservative constant keep their defaults. R10c migrates only fact-collecting walks whose default drops a child.
Gates on `main`, each exit 0: `test-zts`, `test-flow-census` (734 match, 0 fail-open, 0 over-refusal), `test-standin`, `test-diagnostic-corpus`, `test-proof-swallow`, `test-contract-golden`, `test-zts-layering`, `test-module-boundary`, `test-doc-links`, `test-docs-drift`, `test-spine`, `check-spine`. Fresh-cache aggregate: 211/211 steps, 7809/7815 passed (6 skipped); the delta of 2 is the R10b tests. Digests: byte-identical. Protection against `c31846ba`: exit 0.
Follow-up for the R13 final pass: `docs/contracts-and-sandboxing.md` names `server.zig:updateContract`, which no longer exists. That reference was stale before the reset.

## R5 bench-check

`zig build bench-check -Doptimize=ReleaseFast` on `main` at `1d156b41`, load 2.06 to 2.19: exit 1, `intArithmetic` 11.76% below the committed baseline (limit 8%). Every other row passed.
Interleaved runs of `bench-check` on R0 (`f52d8e4a`) and `main`, load 2.2: R0 failed once (8.30%) and passed twice; `main` failed three times (10.08%, 10.45%, 11.36%).
21 alternating runs of the two bench binaries, load 1.9, operations per second:

| Row | R0 median | `main` median | Change |
|---|---|---|---|
| `intArithmetic` | 19,944,156 | 19,546,520 | -2.0% |
| `propertyAccess` | 18,274,853 | 18,301,610 | +0.1% |
| `functionCalls` | 11,720,581 | 11,715,089 | 0.0% |
| `httpHandler` | 6,443,298 | 6,393,861 | -0.8% |

The `intArithmetic` row runs for about 2.4 ms, and the two ranges overlap (R0 19.07M to 23.07M, `main` 18.72M to 20.06M). Both medians are 13% to 15% below the baseline of 22,967,386, so R0 also misses the 8% limit on this host in its median. The measured reset effect is -2.0% on one row and no change beyond 0.8% on the others. The R5 exit condition ("`bench-check` stays within its limits") is not met on this host, and it is not met at R0 either. No baseline file is changed (`benchmarks/perf-baseline.json` is protected).

## R10c

| Commit | Phase | Result |
|---|---|---|
| `54038dcd` | R10c-1 | `effect_inference`: `collectFunctionsIn` and `registerModuleBindings` keep their scope boundaries as named arms (`if_stmt`, `for_of_stmt`, `function_expr`, `arrow_function`, and `block` for bindings), and their default arms descend through `IrView.expressionChildren`. |
| `08c6bd8e` | R10c-2 | `path_generator`: the default arm of `walkPaths` descends. The tags that reach it today hold nothing to walk. |
| `7fda3441` | R10c-3 | `type_checker`: `walkStmt` descends; `admitTypePredicates` keeps its module-level boundary arms and descends. |

No migration: `flow_interp` (its interpreter names every tag or refuses, and `bindPattern` is a pattern boundary), `handler_verifier` (its fact walks already descend), and `type_env` (a classifier). Classifiers and recognizers that return a conservative constant keep their defaults.
Opus review: `collectFunctionsIn` records each function by its binding (scope and slot), so the wider descent cannot confuse two functions with the same name.
Stopped by the stop rule, not committed, for owner Decision 11 (class B):
- `contract_builder.scanFunctionNodeForApiFacts` dropped spread operands. For a route that returns `Response.json({ ...{ auth: req.headers["authorization"] } })`, `contract.json` lists no header parameter before and lists `authorization` after.
- `strict_checker.collectStaticLiterals` (and two sibling collectors) descend with the statement-only `forEachChild`. For `xs.map((x: number): number => { const k = "a"; return o[k]; })`, ZTS605 is reported before and not after; the same code at top level is accepted before and after. The change removes a refusal.
Both inputs were written for the probe. The corpus, the goldens, and the digests do not move with either patch. The patches and inputs are kept outside the repository under the reset scratch directory (`r10c-stopped`).
Gates on `main`, each exit 0: `test-zts`, `test-flow-census` (734 match, 0 fail-open, 0 over-refusal), `test-standin`, `test-diagnostic-corpus`, `test-proof-swallow`, `test-contract-golden`, `test-precompile`, `test-expert-app`, `test-zts-layering`, `test-cli`, `test-zruntime`, `check-spine`. Fresh-cache aggregate: 211/211 steps, 7809/7815 passed (6 skipped), unchanged. Digests: byte-identical. Protection against `7e86feb7`: exit 0.
Not in scope: `bool_checker.walkStmt` has the same `else => {}` default; `bool_checker` is not in the R10 file list.
