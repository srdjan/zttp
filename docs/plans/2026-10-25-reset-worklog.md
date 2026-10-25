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
