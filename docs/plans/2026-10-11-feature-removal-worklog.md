# Plan 005 Phase 1 worklog

This file records progress for [Plan 005 Phase 1](2026-10-11-feature-removal-phase-1.md). Each group adds one section. A section lists what the group removed, the checks it ran, and each judgment the plan did not settle.

## Baselines

Baseline commit: `de47a9e0`. The tag `pre-rebase` marks `b33cac5c`.

`bash scripts/verify.sh` passed at `464240f1` with exit 0 in 1,237 seconds, offline, with private Zig caches.

The invariant 4 identities below come from `zig build` on the tree at `de47a9e0`, measured before any G1 deletion. Each command ran with `DEEPSEEK_API_KEY` unset and private Zig caches.

| Identity | Command | Baseline value |
|---|---|---|
| `policy_hash` | `zig-out/bin/zts meta --json` | `b2038448f90d24c22a47c63f4f546b370a4d60b39985a7bc94e49b2bdc177ae3` |
| `module_registry_hash` | `zig-out/bin/zts meta --json` | `3bc86b0dcc9757067d695edc1cc73c942872d2c2854282df82c6cbcb5612713d` |
| `spec-hash` | `zig-out/bin/zts spec-hash` | `83b822bd0dee8e5f9a9231501f0f95b34fa48a0f08c671ade7a8bee822b877b8` |

`git diff --stat -- policy-hash.txt docs/coverage.json docs/convergence.json docs/spec/` must stay empty.

## G1 Standalone documents and the archive

### Removed

- `docs/internals/zttp-runtime-architecture.html` and `docs/internals/zttp-runtime-architecture.archify.json`
- `docs/investor-precise.html`, `docs/investor-warm.html`, `docs/antfly-zig-patterns.html`, `docs/hypermedia-explainer.html`, `docs/essay.md`
- `advisor-plans/001-tigerbeetle-inspired-predictable-performance-plan.md` and `advisor-plans/002-local-lfm-default-cutover-plan.md`
- All 90 tracked files under `docs/archive/` (86 files) and `docs/zttp-next/` (4 files)

### Retargeted citations

- A Markdown link into a deleted file became either plain text (when the sentence stands alone) or the text plus an inline code citation `pre-rebase:<path>`.
- Source and script comments that cited `docs/archive/` now cite `pre-rebase:docs/archive/...`. Files: 19 under `packages/` and 4 under `scripts/`.
- `STRATEGY.md`, `docs/roadmap.md`, `docs/plans/README.md`, two plans, six solution docs, and `docs/zts-formal-spec-northstar-advanced.md` (only its "Sources inspected" list, outside the grammar and idiom sections) cite `pre-rebase:`.
- `advisor-plans/README.md` rows 001 and 002 and the roadmap row for the predictable-performance advisory plan cite the deleted files as `pre-rebase:advisor-plans/...`.

### Defect fixed

The first table row of `docs/plans/README.md` (Plan 005 Phase 1) lacked its closing ` |`. G1 added it.

### Judgments the plan did not settle

- `docs/user-guide.md`: the sentence that sent the reader to `hypermedia-explainer.html` described only that link, so G1 dropped the whole sentence.
- `docs/README.md`: G1 removed the Antfly and Essay entries, and rewrote the Archive section to name the `pre-rebase` tag.
- `scripts/check-docs-drift.sh`: the exclusion regex `plans_exclude` named `^docs/archive/`. Its whole subject is gone, so G1 reduced it to `^docs/plans/` and updated the comment. No ban row changed.
- `.gitignore` lines 83 to 87 (archify visual-check output) stay. G1 deletes less when the plan is silent.
- `docs/roadmap.md`: the `#conditional-discovery-items` fragment of the rederive record link is gone with the link.

### Invariant 8 patterns

```
git grep -n -E "zttp-runtime-architecture|investor-precise|investor-warm|antfly-zig-patterns|hypermedia-explainer|docs/essay|essay\.md|001-tigerbeetle-inspired|002-local-lfm-default|docs/archive|zttp-next|\barchive/(plans|README|ideation|spec-explainers|vision|DEFERRED)" -- docs README.md CLAUDE.md AGENTS.md STRATEGY.md CONCEPTS.md .agents .github scripts build build.zig packages advisor-plans tooling
```

The only hits outside `pre-rebase:` citations are historical text in `advisor-plans/005-feature-removal-rebase.md` and in the plan files of this series.

### Checks

All commands ran with `DEEPSEEK_API_KEY` unset and private Zig caches. Each exit status was read directly, never through a pipe.

- `zig build test-docs-drift`, `zig build test-doc-links`, and `bash scripts/audit-docs.sh`: exit 0.
- `scripts/check-grammar-drift.sh`, `check-idiom-table.sh`, `check-docs-drift.sh`, `check-module-boundary.sh`, and `check-zts-layering.sh`: exit 0.
- `zig build` and `zig build test`: exit 0. `test-expert-app` ran inside `zig build test` and raised no `model_context_mismatch` failure.
- Invariant 4 after G1: `policy_hash`, `module_registry_hash`, and `spec-hash` equal the baselines above. `git diff --stat -- policy-hash.txt docs/coverage.json docs/convergence.json docs/spec/` is empty.
- Invariant 3: no file under `packages/pi/src/skills/` or `packages/pi/src/prompts/`, and no `expert_persona.zig` or `tool_registry.zig`, changed.

## G2 WASM playground and browser overviews

### Removed

- `packages/tools/src/wasm_analyzer.zig`, `build/wasm.zig` (the `wasm` and `wasm-playground-publish` steps and `test-wasm-playground-publish`), `tooling/wasm_playground_publish.zig`
- `scripts/build-wasm-playground.sh`, `scripts/check-zts-language-overview.sh`, `scripts/test-zts-language-overview-browser.mjs`
- `docs/zts-language-overview.html`, `docs/zts-expert-overview.html`
- `packages/zts/src/wasm/` (four files: `interpreter.zig`, `loader.zig`, `pool.zig`, `root.zig`) and the `zts.wasm` and `engine.wasm` re-exports
- The `analyzer_only` build option and every reader of it. Each reader keeps the `analyzer_only == false` path:
  - `builtin_modules.zig`: `builtins` is the full binding array. The analyzer projection functions, the `AnalyzerOnly` stub, and the projection test went with it.
  - `builtins/helpers.zig`: the no-context rope flatten falls through to `c_allocator`.
  - `engine_root.zig`: the empty JIT-anchor `comptime` block and the `wasm` export.
  - `module_binding.zig`, `module_binding/bridge.zig`: `sdk_bridge` is always referenced.
  - `module_binding/capabilities.zig`: `fillRandomForActiveModule` always uses the ChaCha CSPRNG. The `sdk_prng` variable went with the deleted branch.
  - `packages/zts/build.zig`: `link_libc = true` for all five modules, and the SQLite C source is always compiled.
  - `build/packages.zig`: the `analyzer_only` option row.
- The `test-zts-overview-browser` step and the overview drift check on `docs-drift` (`build/artifacts.zig`), and the `step "zig build wasm"` call in `scripts/verify.sh`.

### Edits to gates and allowlists

- `scripts/manual-scripts.allow`: row `build-wasm-playground.sh`.
- `scripts/manual-steps.allow`: rows `wasm-playground-publish` and `test-zts-overview-browser`.
- `scripts/zts-tiers.allow`: four `wasm/*.zig` rows.
- `tooling/release_check.zig`: the `"zig build wasm"` marker in `verify_script_markers`, and `zig build wasm` in both fixture strings (the `verify_sh` constant near line 707 and the test fixture near line 952). All other markers stay.

### Edits to docs

`docs/README.md` (both overview entries), `docs/internals/testing.md` (step list, the publisher paragraph, and the "Six build steps" count, now "Three"), `docs/internals/semantics-verification.md`, `docs/proofs-and-receipts.md` (the website playground paragraph and one clause), `.agents/skills/zttp-build/SKILL.md` (the Wasm section and the description clause), `CLAUDE.md` (the clause "the wasm playground"), `RELEASE_CHECKLIST.md` (two wasm and playground items), and `docs/plans/2026-10-09-fault-coverage-follow-ups.md:39` (now cites `pre-rebase:packages/tools/src/wasm_analyzer.zig`).

### Judgments the plan did not settle

- `RELEASE_CHECKLIST.md` and `docs/proofs-and-receipts.md` were not in the G2 edit list. They name the deleted step and the website playground, so invariant 8 required the edit.
- `docs/internals/semantics-verification.md:56` said the injected solver keeps `std.process.Child` out of the wasm build. The sentence now says "out of the analyzer".
- `packages/zts/src/repair_intent.zig` header said "Importable from `analyzer_only` builds". It now says "Pure enum, no I/O."
- Left unchanged: `packages/modules/build.zig:12` (a comment on the freestanding `needs_libc` check, which is behavior), `precompile.zig`, `precompile_check.zig`, `parser/parse.zig` (comments and a wasm stack-size branch about freestanding builds), `policy.zig` `WasmPolicyChecker` (a separate fail-closed stub, not the deleted `wasm/` directory), the contract `wasm_policy_hash` field, and `CHANGELOG.md` history. The plan is silent on them.

### Invariant 8 patterns

```
git grep -n -i -E "analyzer_only|wasm_analyzer|build-wasm-playground|wasm-playground|zts-language-overview|zts-expert-overview|check-zts-language|test-zts-overview-browser|zig build wasm|wasm_playground_publish|build/wasm\.zig|packages/zts/src/wasm|zts\.wasm|engine\.wasm" -- docs README.md CLAUDE.md AGENTS.md STRATEGY.md CONCEPTS.md .agents .github scripts build build.zig packages tooling RELEASE_CHECKLIST.md
```

The only hit outside historical plan text is the `pre-rebase:` citation in `docs/plans/2026-10-09-fault-coverage-follow-ups.md`.

### Checks

See the G2 report for the exit status of each command. Invariant 4 after G2: `policy_hash` `b2038448...7ae3`, `module_registry_hash` `3bc86b0d...713d`, and `spec-hash` `83b822bd...77b8` equal the baselines. `git diff --stat -- policy-hash.txt docs/coverage.json docs/convergence.json docs/spec/` is empty.

## G3 Studio, demo, proof quest, tour, keystroke input, demo passport

### Removed

- `packages/runtime/src/`: `studio.zig`, `studio_stub.zig`, `demo.zig`, `demo_command.zig`, `proof_quest.zig`, `cli_tour.zig`, `keystroke_input.zig`
- `packages/tools/src/proof_quest_fixture.zig` and its `test-proof-quest-fixture` row in `build/host_tests.zig`
- `packages/pi/src/demo_passport.zig`, `demo_passport_check.zig`, and the `demo-passport-check` and `test-demo-passport-check` steps in `build/tooling.zig`
- `scripts/smoke-demo.sh`, `scripts/smoke-studio.sh`, and the `smoke-demo` and `smoke-studio` steps in `build/smoke.zig`
- The `-Dstudio` option (`build/Context.zig`, `packages/runtime/build.zig`), the `enable_studio` feature option, and the Studio selector in `runtime_features.zig`
- The `zttp studio` and `zttp demo` commands, `studioPreflight`, `extractTemplateFlag`, and the `--template` flag of `studio`
- The `--studio`, `--demo`, `--quest`, `--quest-default`, `--no-quest`, and `--no-tour` flags
- The `/studio` slash command of `zttp expert`
- The `verify.sh` step `zig build test-cli -Dstudio`, the two release.yml smoke steps, the `RELEASE_CHECKLIST.md` rows, the `manual-steps.allow` row `demo-passport-check`, and the matching markers and fixtures in `tooling/release_check.zig`

### starter_source move

`proof_quest_fixture.starter_source` became the `basicHandler` constant in `init_command.zig`, byte for byte. Check: `zttp init app-basic --template basic` ran before and after with the built binary. `src/handler.ts` has the same SHA-256 (`863c359f...0605a`) in both runs, and `app-api` and `app-htmx` are identical. The only scaffold difference is `README.md` of the basic template: the four lines about the Proof Quest and `zttp dev --quest` are gone, and so is the line about `Tab` lens rotation.

### Edits that follow from the deletions

- `live_reload.zig`: removed the quest state, the keystroke listener, the Studio hooks, the Studio footer, and `refreshDevAttestation` (it ran only under `--studio`). `Diagnostic` moved here from `studio.zig`.
- Lens rotation: `keystroke_input.zig` was the only trigger for `Tab` and `l`. `live_reload.zig` therefore lost the lens atomic, the four-lens frame cache, `rotateLens`, `writeLensHint`, and `buildCallerView`. `renderHudInner` now renders one properties-lens frame and writes it to stderr.
- `server.zig`: removed the Studio routes (`populateStudioResponse`, `handleStudioRequestSync`, the 413 size bound and its tests), the `studio` state, `syncStudioCallerReceipt`, and the `studio` and `studio_demo_root` config fields.
- `runtime_cli.zig`: removed the Studio and quest flags from `ServeFeatureFlags` and from the option parser, the help lines, and two tests.
- `proof_card_tui.zig`: removed `writeStudioFooter`, `StudioFooterOptions`, their three tests, and the two handover-lens lines "Studio has the full text" and "and a one-click copy.". The lens code itself stays.
- `dev_command.zig`: removed the quest and tour logic of `dev`, `studioCommand`, and their tests. `cli_paths.zig`: removed `resolveReentryBinaryAfterChdir` (only `demo` used it) and its test in `dev_cli.zig`.
- `packages/pi/src/repl.zig`, `commands.zig`: removed `/studio` (`isStudio`, `renderStudio`, the help line, and two tests). `app.zig`, `tests.zig`: removed the `demo_passport` import. `packages/pi/README.md` and `docs/`: removed the Studio sentences.
- `scripts/smoke-getting-started.sh` passed `--no-tour` to `zttp dev`. The flag no longer exists, so the script no longer passes it.

### Model-visible check for `repl.zig` and `commands.zig`

`/studio` is a local REPL command. `dispatchLine` returns a `ToolResult` that the REPL loop writes to stdout. The result does not enter the session transcript or any model request. No text in `expert_persona.zig`, `tool_registry.zig`, `skills/`, or `prompts/` names `studio`. The text was therefore local help and the group removed it. Invariant 3 holds: none of the protected files changed.

### Judgments the plan did not settle

- The `basic` handler comment still says "Proof Quest starter ... press `b` ... press `r`". The plan requires a byte-for-byte move, so the comment stays. It describes a removed flow and needs a later decision.
- `Tab` lens rotation is gone as a consequence of deleting `keystroke_input.zig`. The `trade`, `handover`, and `caller_view` lenses, `CallerView`, and `buildProofCertificate` stay in `proof_card_tui.zig` but nothing in `zttp dev` reaches them now. The section "The Three Lenses" in `docs/proofs-and-receipts.md` went with the rotation.
- `Server.installDevAttestation`, `attest_build_receipt.buildDevJws`, and the `signer_fingerprint_hex` field in `server.zig` have no caller outside tests now. The plan did not list them. They stay (delete less).
- `--no-quest` and `--no-tour` were deleted from `dev` instead of being accepted as no-ops, so they now fail as unknown options.
- `init_command.scaffoldProject` keeps its `.` in-place branch. Only the removed `studio` command used it. The comments no longer name Studio.
- `docs/roadmap.md:335` still lists "demo, Studio views" in a historical "no removal selected" sentence. G14 owns the roadmap rewrite.
- `packages/zts/src/witness_corpus.zig` and `packages/tools/src/{json_diagnostics,upgrade_verifier}.zig` had comments that named Studio. Only the comments changed.

### pi_app pass condition

`git grep -n pi_app packages/runtime/src` lists `cli_args.zig`, `cli_doctor.zig`, `dev_cli.zig`, `dev_command.zig`, `handler_corpus.zig`, `witness_replay_lib.zig`, and one more file: `proof_cli.zig:308`, a doc comment that names the `pi_app.capsule_probe` seam. The plan's list omits it. The comment existed before G3 and is not an import.

### Invariant 8 patterns

```
git grep -n -i -E "zttp studio|-Dstudio|enable_studio|_zttp/studio|studio_mod|studio\.zig|studio_stub|\bzttp demo\b|demo_command|demo\.zig|smoke-demo|smoke-studio|demo-passport|demo_passport|proof_quest|proof-quest|--quest|--no-quest|--no-tour|--studio|--demo\b|cli_tour|keystroke_input|test-demo-passport|Proof Passport demo|Proof Theater|proof theater|studioCommand|studioPreflight|printStudioHelp|cmdStudio|cmdDemo|isStudio|renderStudio|writeStudioFooter|/studio\b" -- docs README.md CLAUDE.md AGENTS.md STRATEGY.md CONCEPTS.md .agents .github scripts build build.zig packages tooling RELEASE_CHECKLIST.md
```

The only hits are historical text in the plan files (`docs/plans/2026-09-19-feat-agent-handler-spec.md`, `docs/plans/2026-09-27-m5-a3-sse-framer-design.md`, and the plans of this series).

### Checks

All commands ran with `DEEPSEEK_API_KEY` unset and private Zig caches. Each exit status was read directly from a redirected run.

- `zig build test-cli`: exit 0, 867 passed, 1 skipped, 0 failed.
- `zig build test-server`: exit 0 (the test binary reports 502 passed, 2 skipped, 0 failed).
- `zig build test-zruntime`, run alone: exit 0.
- `zig build test-expert-app`: exit 0 (the test binary reports 1118 passed, 1 skipped, 0 failed). The log line `model_context_mismatch at turn 0/2` comes from the test "simulator recorder promotes and replays a complete two-Turn flow", which passes. It is a negative case, not a corpus replay failure.
- `zig build test-step-coverage` (103 steps), `test-script-reachability` (47 scripts), `test-release-check`, `test-docs-drift`, `test-module-boundary`, `test-runtime-purity`: exit 0.
- `zig build smoke-getting-started` and `zig build smoke-v1`: exit 0, both print PASS.
- `zig build` and `zig build test`: exit 0.
- `zig fmt --check build.zig build/ packages/ tooling/` and `bash scripts/audit-docs.sh`: exit 0.
- Invariant 4 after G3: `policy_hash` `b2038448...7ae3`, `module_registry_hash` `3bc86b0d...713d`, and `spec-hash` `83b822bd...77b8` equal the baselines. `git diff --stat -- policy-hash.txt docs/coverage.json docs/convergence.json docs/spec/` is empty.
- Invariant 3: no file under `packages/pi/src/skills/` or `packages/pi/src/prompts/`, and no `expert_persona.zig` or `tool_registry.zig`, changed.

## G4 Edge runtime

### Removed

- `packages/runtime/src/edge_server.zig`, `packages/runtime/src/edge_server_stub.zig`, and `docs/edge.md`
- The `-Dedge` option (`build/Context.zig`, `packages/runtime/build.zig`), the `enable_edge` field of `RuntimeFeatureConfig`, and the `enable_edge` feature option
- The edge selector in `runtime_features.zig`. The file stays and holds only the live-reload selector.
- The `zttp edge` verb in both binaries: `edgeCommand`, `parseEdgeConfigPath`, `printEdgeHelp`, and the `edge` dispatch branch in `runtime_cli.zig`, plus `cmdEdge` and the `edge` registry row in `dev_cli.zig`
- The `edge` line in `runtime_help_text` (`runtime_cli.zig`), the `edge` entry of `dispatched_verbs`, and the `edge` line of `help --all` (`cli_help.zig`)
- The `edge_server.zig` import in the `main.zig` test block. The edge tests went with the file. No other test changed.
- The "Optional Surfaces" section of `docs/cli.md` (it held only `edge`), the `docs/user-guide.md` and `docs/README.md` links to `edge.md`, the `docs/roadmap.md` Supported Now item, the `-Dedge` line and description clause in `.agents/skills/zttp-build/SKILL.md`, the `-Dedge` clause in `CLAUDE.md`, the edge name in the `docs/internals/testing.md` and `build/runtime_tests.zig` coverage lists, and the edge entry in the `docs/internals/architecture.md` package table

### Retargeted citations

- `docs/plans/2026-09-22-m4-release-contract.md:158,167` now cite `pre-rebase:packages/runtime/src/edge_server.zig`.
- `docs/solutions/security-issues/edge-chunked-encoded-body-amplification.md` stays. Its Solution paragraphs now cite `server.zig` (`completeRequestLength`, line 899, and `readRequestData`, line 850) and `pre-rebase:` for the edge lines. Its verification command no longer names `-Dedge`.
- `main.zig` comment: compile coverage of `handler_instance.zig` now comes from `test_runner.zig`, not from `edge_server.zig`.

### Judgments the plan did not settle

- The plan cites `server.zig:1053,1116` for the lesson. Those lines are stale after G3. The chunked encoded-cap code is at `server.zig:850` and `899-928`, and the solution doc cites those lines.
- The solution doc cited `edge_server.zig` also in its Solution section (lines 34 and 36), not only at lines 45 and 47. Invariant 8 required the edit, so G4 rewrote those too.
- The edge regression test (one-byte chunks with 1,100-byte extensions, `edge_server.zig:1031`) went with the file. `server.zig` has no equivalent test. The solution doc now says so. G4 did not add a test (out of scope). A later group or a follow-up commit can add one.
- `packages/runtime/src/cli_shared.zig` `featureCompiledOut` has no caller now (only `edge` used it, since G3 removed Studio). It stays, and G15 owns it.
- `docs/solutions/` frontmatter title and tags of the chunked-amplification note still say "edge". The file name stays by plan. `CHANGELOG.md` history lines about the edge server stay.
- The `dev_cli.zig` import `feature_options` was already unused before G4. It is untouched.
- `docs/plans/2026-10-11-feature-removal-phase-1.md` and `advisor-plans/*` still name edge as historical plan text.

### Dead code for G15

- `cli_shared.featureCompiledOut` (no caller; its doc comment still uses `edge` as the example).

### Invariant 8 patterns

```
git grep -n -i -E "edge_server|edge_server_stub|-Dedge|enable_edge|zttp edge|zttp\.edge|edge\.md|edge runtime|edge-runtime|EdgeServer|edgeCommand|cmdEdge|printEdgeHelp|parseEdgeConfigPath|in-process edge|edge router|edge config|edge_enabled" -- docs README.md CLAUDE.md AGENTS.md STRATEGY.md CONCEPTS.md .agents .github scripts build build.zig packages tooling RELEASE_CHECKLIST.md advisor-plans CHANGELOG.md
```

Remaining hits: `pre-rebase:` citations, the solution doc (history of the fix), `cli_shared.zig:128` (comment on the dead `featureCompiledOut`), `CHANGELOG.md` history, `advisor-plans/`, and plan text of this series.

### Checks

All commands ran with `DEEPSEEK_API_KEY` unset and private Zig caches. Each exit status was read directly from a redirected run.

- `zig build`, `zig build test-cli` (867 passed, 1 skipped, 0 failed), `test-server`, `test-zruntime` (alone), `test-step-coverage`, `test-docs-drift`, `test-release-check`, `test-runtime-purity`, `test-script-reachability`, `test-module-boundary`, `test-doc-links`, and `zig build test`: exit 0.
- `bash scripts/audit-docs.sh` and `zig fmt --check build.zig build/ packages/ tooling/`: exit 0.
- `zttp edge` now prints "Unknown command: edge" and the help text.
- Invariant 4 after G4: `policy_hash`, `module_registry_hash`, and `spec-hash` equal the baselines. `git diff --stat -- policy-hash.txt docs/coverage.json docs/convergence.json docs/spec/` is empty.
- Invariant 3: nothing under `packages/pi` changed.

## G5 AOT native-handler path and dead builtins

### Removed

- `packages/tools/src/transpiler.zig`, `packages/zts/src/builtins/symbol.zig`, `packages/zts/src/builtins/weak_collections.zig`, `scripts/build_minimal_dyld.sh`, and `scripts/run-jsx.sh`
- `-Daot` (`aot_enabled` in `build/Context.zig`, its `--aot` forwarding in `build/artifacts.zig`) and `--aot` with `emit_aot` in `precompile_args.zig`
- In `precompile.zig`: the transpiler branch and its fallback early return in `compileHandler`, the `emit_aot` option and its readers, the `CompiledHandler` fields `aot` and `transpiled_source` (with their cleanup), the `AotAnalysis.handler_loc` field, the transpiled-source branch and the `has_aot` code generation in `writeZigFile` (about 170 lines, including the generated `aotHandler`, `aot_metadata`, `emitAotBodyValExtraction`, and `contentTypeFor`), the `handler_path` parameter of `writeZigFile`, the `IrTranspiler` import, and the `transpiler.zig` test import. The test "unsupported AOT statements emit a runtime bail without taking the error return" went with the transpiler.
- `has_aot` and `aotHandler` in `embedded_handler_stub.zig`, and the production `embedded_handler.has_aot` dispatch with the unused `embedded_handler` import in `handler_instance.zig`
- The `symbol` and `weak_collections` imports and the `WeakMapData`, `WeakSetData`, `createSymbol`, `createWellKnownSymbol`, `initWeakCollections`, and `initSymbol` re-exports in `builtins/root.zig`
- Rows in `scripts/zts-tiers.allow` (`builtins/symbol.zig`, `builtins/weak_collections.zig`) and `scripts/manual-scripts.allow` (`build_minimal_dyld.sh`, `run-jsx.sh`)
- Docs: `docs/verification.md` no longer shows `-Daot`. `docs/contracts-and-sandboxing.md` no longer says route patterns need `-Daot`: the contract always read routes through `analyzeAot`.

### Kept on purpose

- `analyzeAot`, `AotAnalysis`, `countAotPatterns`, and every call that feeds `extractContractFromAnalysis`. In `compileHandler` the contract branch now calls `analyzeAot` once as `route_analysis`. Before G5 the default build did the same (`aot` was null without `--aot`, so `temp_aot` supplied the routes).
- The test-only `aot_override` seam in `handler_instance.zig` (`setAotOverrideForTest` and the `builtin.is_test` branch) and every test that uses it. G5 renamed its comment to "TEST SEAM" and its log text to "handler override failed". The label `aot_attempt` stays.
- The contract wire fields named `aot` (`HandlerContract.aot`, `RouteInfo.aot`, `AotInfo`). They are contract JSON and move the artifact hash if removed.
- The `cached_dispatch` fast path in `handler_instance.zig`. It runs static routes from the bytecode dispatch table and is not the native-handler path.

### Routes unchanged (extra proof)

The contract path is `zts compile --verify --contract <handler> <out.zig>`, which writes `contract.json` beside the output. `zts check --json --contract <handler>` printed the same bytes before and after. The three examples (`examples/handler/handler.ts`, `examples/routing/router.ts`, `examples/hypermedia/order.ts`) have an empty top-level `routes` array in this build, so two scratch handlers with non-empty route tables also ran. One uses `match (request.url)` with three exact arms. The other uses `request.path === ...` with two exact `if` arms. Both sit in the scratchpad, not in the repository.

Commands, run with `DEEPSEEK_API_KEY` unset and the private caches. Each ran against a `zig build` binary of the same tree, before the edits and after them:

```
zig-out/bin/zts compile --verify --contract <handler> <dir>/out.zig
zig-out/bin/zts check --json --contract <handler>
```

Results of `cmp` between the before and after runs, per handler: `contract.json`, the saved routes section, and the `check --json` output are byte-identical for all five handlers (exit 0 for each compile). The scratch handlers show 3 and 2 exact routes (`/api/a`, `/api/b`, `/api/c`; `/ping`, `/version`). Before G5, `zts compile --aot` on the two scratch handlers also produced the same `contract.json` as the run without `--aot`.

The generated `out.zig` differs in exactly one place: the five lines `pub const has_aot = false;`, the `aotHandler` stub, and a blank line are gone.

### Judgments the plan did not settle

- The plan names the `has_aot` field only. G5 also removed the generated and stub `aotHandler` function and `aot_metadata`. After the `has_aot` check went, nothing called `aotHandler`, and the stub always returned `error.AotBail`.
- G5 removed the `CompiledHandler.aot` field, `AotAnalysis.handler_loc`, and the `handler_path` parameter of `writeZigFile`. Only the deleted generator read them.
- G5 removed the unused `embedded_handler` import from `handler_instance.zig`. It left the build wiring that attaches the import to `runtime_instance` (`packages/runtime/build.zig:149`), because `dev_cli.zig` and `runtime_cli.zig` still need the import in other modules. Whether the `runtime_instance` attachment is dead needs a separate check (G15).

### Dead code for G15

- `packages/runtime/build.zig:149`: `embedded_handler` anonymous import on the `runtime_instance` module. `handler_instance.zig` no longer imports it. Confirm no other file in that module does, then drop it.
- Stale comments that name the AOT path: `handler_analyzer.zig:62` ("intended for AOT precompile paths") and `:602` ("AOT-only dynamic pattern"), `runtime_config.zig:135,247`, `server.zig:2580`, `runtime_cli.zig:719`, `docs/consumer-contract.md:166`. `HandlerAnalyzer.enableJsonBodyParsePatterns` and the `request_json_parse` body source still feed the contract route table, so they are code to keep, not to delete.
- Symbol support in `object.zig` and `value.zig` (`WellKnownSymbol`) lost its builtin creators, `createSymbol` and `createWellKnownSymbol`. G5 did not check whether the engine still reaches that support.

### Invariant 8 patterns

```
git grep -n -i -E "transpiler|IrTranspiler|emit_aot|has_aot|aot_metadata|aotHandler|\-Daot|--aot|aot_enabled|build_minimal_dyld|run-jsx|builtins/symbol|weak_collections|createWellKnownSymbol|createSymbol|initWeakCollections|WeakMapData|WeakSetData|initSymbol|transpiled_source" -- docs README.md CLAUDE.md AGENTS.md STRATEGY.md CONCEPTS.md .agents .github scripts build build.zig packages tooling
```

Remaining hits are historical plan text only: `docs/plans/2026-09-23-m4-t5-scope-and-grants-design.md`, `2026-10-08-boolean-and-arity-checks.md`, `2026-10-11-feature-removal-phase-1.md`, `2026-10-11-shared-analysis-first-unit.md`, and `2026-10-11-shared-analysis-worklog.md`.

### Checks

All commands ran with `DEEPSEEK_API_KEY` unset and private Zig caches. Each exit status was read directly from a redirected run.

- `zig build`: exit 0.
- Unfiltered, exit 0 each: `test-precompile`, `test-zts`, `test-zts-layering`, `test-script-reachability`, `test-contract-golden`, `test-cli` (868 passed, 1 skipped, 0 failed; the same count as a run at HEAD), `test-server`, `test-examples`, `test-step-coverage`, `test-docs-drift`, `test-module-boundary`, `test-zruntime` (alone), `test-runtime-purity`, `test-release-check`, `test-doc-links`.
- `zig build test`: exit 0 on the final run. A first run exited 1 because `check-script-reachability.sh` and `check-zts-layering.sh` read `git ls-files`, and a `git stash` and `git stash pop` that G5 used for a count comparison had put the deleted files back into the index. `git rm --cached` fixed the index. The rerun passed.
- `zig fmt --check build.zig build/ packages/ tooling/`: exit 0.
- Invariant 4 after G5: `policy_hash` `b2038448...7ae3`, `module_registry_hash` `3bc86b0d...713d`, and `spec-hash` `83b822bd...77b8` equal the baselines. `git diff --stat -- policy-hash.txt docs/coverage.json docs/convergence.json docs/spec/` is empty.
- Invariant 3: nothing under `packages/pi` changed.

## G6 Precompile options for external generators, and `prove`

### Removed

- `packages/tools/src/manifest_alignment.zig`, `property_expectations.zig`, `openapi_manifest.zig`, `sdk_codegen.zig`, `precompile_buildtime.zig`, `prove.zig`, `precompile_prove.zig`, and `prove_upgrade.zig`
- The `zts prove` and `zttp prove` command (the row in `zts_cli.zig`; `zttp` reads the same registry). `prove-behavior` stays.
- The build options `-Dmanifest`, `-Dexpect-properties`, `-Dgenerator-pack`, `-Dfault-severity`, `-Dreport`, `-Dopenapi`, `-Dsdk`, `-Dreplay`, `-Dtest-file`, `-Dprove`, and `-Dgenerate-tests`, with their `PrecompileOptions` fields in `build/Context.zig` and their forwarding in `build/artifacts.zig`.
- The matching precompile flags `--manifest`, `--expect-properties`, `--generator-pack`, `--fault-severity`, `--report`, `--openapi`, `--sdk`, `--replay`, `--test-file`, `--prove`, and `--generate-tests` in `precompile_args.zig`. Each is now refused by name as `UnknownFlag`. A new test covers all eleven.
- In `precompile.zig`: the generator-pack types and reader (`ResolvedGeneratorPack`, `dupJsonValue`, `resolveGeneratorPack`), the build-time replay and test blocks, the OpenAPI, SDK, prove, manifest-alignment, property-expectation, and report blocks of `runCompileWithArgs`, `writeSdkArtifact`, and three tests (`resolveGeneratorPack` twice, `writeSdkArtifact`). The usage line in the header lost the removed flags.
- In `report.zig`: the manifest-alignment and property-expectations sections, the `alignment` and `prop_result` parameters of `buildReport`, and the integration flags that named removed options. Only `sql_schema` and `declaration` remain in `IntegrationSection`. `report.zig` stays as its own test root (`test-report`) and as the subject of one test in `precompile.zig`. It has no production caller now.
- `test-manifest-alignment`, `test-openapi-manifest`, and `test-property-expectations` rows in `build/host_tests.zig` and `docs/internals/testing.md`.
- The `.metadoor-*/` block in `.gitignore`, which only the generator pack consumed.
- Docs: `CLAUDE.md`, the `zttp-build` skill, `docs/user-guide.md`, `examples/README.md`, `docs/verification.md` (the `-Dgenerate-tests` heading), `docs/consumer-contract.md` (`-Dreplay` became `--replay`), `docs/contracts-and-sandboxing.md` (the OpenAPI and SDK section, build-time replay, `-Dprove`, and the external enrichment flags are gone; the upgrade-verdict text stays, retitled "Upgrade Verdict"; `-Ddeclaration` stays under "Consumer declaration"), `docs/cli.md`, `docs/proofs-and-receipts.md`, `docs/internals/architecture.md`, `README.md`, `docs/README.md`, and the historical plan `docs/plans/2026-09-23-m4-t2-tool-catalog-design.md` (`pre-rebase:` citations).
- Test help list in `cli_help.zig`: the `zttp prove` entry.
- Comments: `upgrade_verifier.zig` now names `system_rollout.zig` as its caller. `route_match.zig` no longer names the deleted users.

### Kept on purpose

- `-Dhandler`, `-Dverify`, `-Dcontract`, `-Dpolicy`, `-Dsql-schema`, `-Dsystem`, `-Ddeclaration`, `gen-tests`, `prove-behavior`, and `upgrade_verifier.zig`.
- `CompileOptions.generate_tests` in `compileHandler`. A test uses it and a contract build writes `handler.auto-tests.jsonl` through the same condition. Only the CLI flag went.
- The runtime flags `--watch --prove`, `--replay`, `--test-file`, and `--trace` on `zttp serve` and `zttp dev`. They are runtime options, not precompile options.
- `.gitignore` entries `proof.json` and `proof-report.txt` (outputs of the deleted `prove` command).
- `consumer-contract.md:927` ("the build report" in a proposed requirement): it is spec text, not a flag.

### Contract output unchanged

The method is the G5 method. `zts compile --verify --contract <handler> <dir>/out.zig` and `zts check --json --contract <handler>` ran at HEAD (`525410b0`) before the edits and on the edited tree after them, for the same five handlers (`examples/handler/handler.ts`, `examples/routing/router.ts`, `examples/hypermedia/order.ts`, and the two scratch route handlers from G5). `cmp` shows `contract.json`, the routes section, `check.json`, `out.zig`, and `handler.auto-tests.jsonl` byte-identical for all five. Exit codes were equal before and after (compile 0 each; check 0 for `handler.ts`, 1 for the other four, as at HEAD).

### Judgments the plan did not settle

- The plan names `prove.zig` and the heading says `prove`. G6 removed the `prove` command row with the file. The command was documented in `docs/cli.md`, `docs/contracts-and-sandboxing.md`, and `docs/proofs-and-receipts.md`; those references changed.
- `report.zig` imported two deleted modules, so G6 had to cut its manifest and property sections although the plan says to remove only the production output path. The remaining `buildReport` and `writeReportJson` serve tests only.
- `.gitignore`: the plan names line 53, which is the generator-pack comment. G6 deleted the whole block (comment and `.metadoor-*/`).
- `docs/contracts-and-sandboxing.md`: the upgrade-verdict prose describes live reload and `rollout`, so G6 kept it and retitled the section rather than deleting it.
- `docs/verification.md`: the "Exhaustive Path Analysis" section describes `PathGenerator` and fault coverage, which a contract build still runs. G6 kept it and removed only the flag from the heading and first sentence. G6 also dropped the bullet "Build report alongside other PROVEN labels".

### Dead code for G15

- `contract_diff.writeProofJson`, `contract_diff.writeProofReport`, and their tests in `packages/zts/src/contract_diff.zig`: only `prove.zig` and `prove_upgrade.zig` called them.
- `upgrade_verifier.writeUpgradeManifestJson` and `upgrade_verifier.writeUpgradeReport` (and their tests): same callers.
- `zts.routePatternsMatch` and the `zts.pathsMatch` alias at `packages/zts/src/root.zig:727,731`: only `manifest_alignment.zig` used them outside their own test. They are curated public surface, so removal needs a decision.
- `packages/tools/src/report.zig` as a whole (`buildReport`, `writeReportJson`, the section types) and `test-report`: no production caller. The plan keeps it while a test uses it (`precompile.zig`, "an incomplete fault analysis writes isCovered false and report clean false").

### Invariant 8 patterns

```
git grep -n -i -E "manifest_alignment|manifest-alignment|property_expectations|openapi_manifest|sdk_codegen|precompile_buildtime|precompile_prove|prove_upgrade|\bprove\.zig|-Dmanifest|-Dexpect-properties|-Dgenerator-pack|-Dfault-severity|-Dreport|-Dopenapi|-Dsdk|-Dreplay|-Dtest-file|-Dprove|-Dgenerate-tests|--generator-pack|--expect-properties|--fault-severity|--openapi|--sdk\b|--test-file|--generate-tests|test-property-expectations|test-manifest-alignment|test-openapi-manifest|zts prove\b|zttp prove\b|ResolvedGeneratorPack|resolveGeneratorPack|writeSdkArtifact|runProvePipeline|runBuildTimeReplay|runBuildTimeTests|writeBuildReport|generator pack" -- docs README.md CLAUDE.md AGENTS.md STRATEGY.md CONCEPTS.md .agents .github scripts build build.zig packages tooling examples
```

Remaining hits: `pre-rebase:` citations in the m4-t2 design plan, plan text of this series, `.github/releases/v0.21.0-corrected.md` (release history), and the refusal test in `precompile_args.zig`, which names the removed flags on purpose.

### Checks

All commands ran with `DEEPSEEK_API_KEY` unset and private Zig caches. Each exit status was read from a redirected run.

- Exit 0, unfiltered: `zig build`, `test-precompile`, `test-zts-cli`, `test-report`, `test-cli` (868 passed, 1 skipped, 0 failed; the G5 count), `test-contract-golden`, `test-examples`, `test-step-coverage`, `test-docs-drift`, `test-script-reachability`, `test-release-check`, `test-doc-links`, `test-module-boundary`, `test-zts-layering`, `test-runtime-purity`, `zig build test`, and `test-zruntime` (alone).
- `zig fmt --check build.zig build/ packages/ tooling/` and `bash scripts/audit-docs.sh`: exit 0.
- After the change `zts prove a b` prints "Unknown command: prove", `zts compile --openapi` prints "Unknown flag: --openapi", and `zig build -Dreplay=x` prints "invalid option: -Dreplay".
- Invariant 4 after G6: `policy_hash` `b2038448...7ae3`, `module_registry_hash` `3bc86b0d...713d`, and `spec-hash` `83b822bd...77b8` equal the baselines. `git diff --stat -- policy-hash.txt docs/coverage.json docs/convergence.json docs/spec/` is empty.
- Invariant 3: nothing under `packages/pi` changed.
