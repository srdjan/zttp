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

## G7 Runtime proof extras: `proof` alias, capsules, audit ring

### Removed

- `packages/runtime/src/proof_cli.zig`, `capsule.zig`, and `proof_audit_ring.zig`
- The `proofs replay` subcommand (`Subcommand.replay`, its parser row, its help text, and its dispatch in `proofs_cli.zig`). `zttp proofs replay x` now prints "unknown subcommand".
- The `zttp proof` alias (`cmdProof` and its table row in `dev_cli.zig`). `zttp proof replay x` now prints "Unknown command: proof".
- `dev --record-proof`: the flag handling, the `--trace` desugaring, `recordProofManifest`, and the help lines in `dev_command.zig`.
- The capsule callback: `capsuleReplayProbe` in `dev_command.zig` and its registration `pi_app.capsule_probe.setProbeFn(...)` in `dev_cli.zig`.
- The audit ring push sites (`pushRouteBlocked`, `pushCacheHit`) in `server.zig`, and the ring reads and `audit_ring.clear()` calls in `proof_card_tui.zig`.
- Two tests in `proofs_cli.zig` (replay as a subcommand, replay missing capsule) and one in `proof_card_tui.zig` (requests pane renders audit events). A new test in `proofs_cli.zig` asserts that `replay` is refused and absent from the help. `test-cli` went from 868 to 846 passed: 20 tests lived in the three deleted files (6, 10, and 4), three more were removed, and one was added.
- Docs: `docs/cli.md` (the `--record-proof` text, the `proofs replay` lines, the deprecated-alias paragraph), `docs/proofs-and-receipts.md` (one phrase naming the audit ring), and `docs/plans/2026-09-19-feat-agent-handler-spec.md` (the ring citation became `pre-rebase:`).
- Help text: `cli_help.zig` and the `proofs` row in `dev_cli.zig` no longer list `replay`.

### Kept on purpose

- `proofs list`, `show`, `diff`, `watch`, `export`, `badge`, `bundle`, `verify`, `gate`, and the HTML and Markdown renders.
- `proof_ledger.zig` (no row kind changed), `replay_runner.zig`, `witness_replay_lib.zig`, `zttp ledger replay`, and the release workflow step. `replay_runner.replayOne` has other callers (`replay_turn.zig`, `witness_replay_lib.zig`, `runtime_cli.zig`), so no code from `proof_cli.zig` had to move.
- `packages/pi/src/capsule_probe.zig` and its `app.zig` and `tests.zig` references. They are G10 scope. No code calls `capsule_probe` now, since the registration is gone.
- The `--replay`, `--test-file`, and `--trace` runtime flags on `serve` and `dev`.
- `tooling/release_check.zig` needed no change: the proof-surface check reads only `badge`, `bundle`, and `verify` from `proofs_cli.zig`.
- The `Proof<...>` capsule vocabulary (ZTS611, `CONCEPTS.md` "Proof capsule", `defect_seeds.zig`): it is a language construct, not the recorded-trace capsule.

### Judgments the plan did not settle

- The Requests pane. `proof_card_tui.zig` laid out three columns, and the third column held the audit ring. With the ring gone, G7 removed the pane content and its "Requests" header and kept the three-column geometry. The third column now holds only the status bar's Baseline cell and is blank in the other rows. The frame width stays 100 columns, the status bar and Why row are unchanged, and the `ColumnWidths.requests` field became `status`. A two-column reflow is a possible later change.
- `dev --record-proof` is not refused by `dev`. The flag now passes through to `serve`, which handles it as it handles any unknown flag.
- G7 left `packages/pi/src/app.zig:37-40` comments about the capsule probe seam unchanged (G10 deletes that seam).

### Dead code for G15 and G10

- G10: `packages/pi/src/capsule_probe.zig`, its `app.zig` export, and its `tests.zig` import. Nothing calls it.
- G15: nothing else in `packages/runtime` was reached only by the three deleted files. `zts.trace` and `file_io` have other users.

### Invariant 8 patterns

```
git grep -n -i -E "proof_cli|\bcapsule\.zig|proof_audit_ring|audit_ring|AuditRing|--record-proof|record_proof|proofs replay|proof replay|zttp proof replay|\.zttp/capsules|proofs? alias|cmdProof\b|replayActiveCapsule|capsuleReplayProbe|recordProofManifest" -- docs README.md CLAUDE.md AGENTS.md STRATEGY.md CONCEPTS.md .agents .github scripts build build.zig packages tooling examples
```

Remaining hits: plan text of this series, the `pre-rebase:` citation, an unrelated "proof replay" phrase in `docs/plans/2026-10-09-fault-coverage-for-upstream-calls.md`, `packages/pi/src/capsule_probe.zig` comments (G10), unrelated `Proof alias` test names, and frozen cassette text under `packages/pi/src/simulator/testdata`.

### Checks

All commands ran with `DEEPSEEK_API_KEY` unset and private Zig caches. Each exit status was read from a redirected run.

- Exit 0, unfiltered: `zig build`, `test-cli` (846 passed, 1 skipped, 0 failed), `test-server`, `test-expert-app`, `test-release-check`, `test-module-boundary`, `test-docs-drift`, `test-step-coverage`, `test-doc-links`, `test-runtime-purity`, `test-script-reachability`, `test-zruntime` (alone), and `zig build test`.
- `zig fmt --check build.zig build/ packages/ tooling/` and `bash scripts/audit-docs.sh`: exit 0.
- Invariant 4 after G7: `policy_hash` `b2038448...7ae3`, `module_registry_hash` `3bc86b0d...713d`, and `spec-hash` `83b822bd...77b8` equal the baselines. `git diff --stat -- policy-hash.txt docs/coverage.json docs/convergence.json docs/spec/` is empty.
- Invariant 3: nothing under `packages/pi` changed. The only `pi` references to deleted files are the unregistered `capsule_probe` seam, which imports none of them.

## G8 Developer CLI extras: `witnesses` and `ratchet show`

### Removed

- `packages/runtime/src/witnesses_cli.zig` (5 tests) and `ratchet_command.zig` (12 tests). `test-cli` went from 846 to 829 passed, which is exactly those 17 tests.
- The `ratchet` and `witnesses` command rows, `cmdRatchet`, `cmdWitnesses`, and the imports and test anchors for both files in `dev_cli.zig` and `cli_main.zig`. `zttp ratchet x` and `zttp witnesses list` now print "Unknown command".
- Their two lines in the `Advanced` block of `cli_help.zig` (`help --all`). The block now lists only `version`.
- The `runtime witness_corpus` row in `scripts/module-boundary.allow`. Only `witnesses_cli.zig` reached that module from `packages/runtime`. The plan said `live_reload.zig` uses `witness_corpus`, but it reads only `result.pinned_witness_regressions` from the analyzer, so the row was unused and the gate failed until G8 removed it.
- Docs: `docs/cli.md` (the section is now "Spec Ratchet" and keeps the `provenSpecs` and `declaredSpecs` text), `docs/proofs-and-receipts.md` (the "CLI" subsection, the `synthesize` mention, the `witnesses_cli.zig` see-also row), `docs/contracts-and-sandboxing.md` (the `ratchet show` example line), `docs/user-guide.md` and `docs/verification.md` (one mention each). `docs/solutions/runtime-errors/builtin-graph-teardown-use-after-free.md` now cites `pre-rebase:packages/runtime/src/ratchet_command.zig`.
- One stale comment in `packages/zts/src/witness_corpus.zig` that named `zts witnesses list`.

### Kept on purpose

- `packages/zts/src/witness_corpus.zig`, `packages/pi/src/tools/zts_expert_ratchet.zig`, `pi_witnesses.zig`, `proof_ratchet.zig`. Nothing under `packages/pi` changed. The comments in `zts_expert_ratchet.zig` that name `zttp ratchet show` and `zttp ratchet check` are stale. They are under `packages/pi`, which Phase 1 may not touch, so they wait for Phase 3.
- `zttp check` (the gate that `ratchet check` duplicated) and the `.zttp/witnesses/` on-disk corpus layout.

### Judgment calls the plan did not settle

- `scripts/test-module-boundary.sh` used `witnesses_cli.zig` as one of two injected scan failures. Its comment said both files carry the runtime `spec_discharge` reach, so dropping both scans makes the row look unused and reproduces the misleading verdict the probe guards against. After G8 only `counterexample_pipeline.zig` has that reach, so the probe injects the failure for that one file. The assertion is unchanged: the gate must exit non-zero and must print "failed to scan tracked Zig files for runtime". No other surviving runtime file has `spec_discharge` reach, so no substitute subject exists. The gate passes with the one-file probe.
- With the CLI gone, the docs tell a reader to pin a witness by creating its `<key>.pinned` marker file by hand (the layout section already defines the marker). The docs do not offer a manual replacement for `prune` or `synthesize`.
- The `Advanced` section of `help --all` stays with one row (`version`).

### Dead code for G15

- `witness_corpus.synthesizeStructural` with its two tests and the `UnsupportedSpec` path, and `spec_discharge.isCauseOnly` (its only caller): only `witnesses_cli.zig` called them. A comment at `spec_discharge.zig:94` names `synthesizeStructural`.
- `witness_corpus.pin` and `witness_corpus.prune` with their tests: no production caller remains outside the file's own tests. `isPinned` has a live caller (`precompile_check.zig`), so keep it. `selectFewShot` also shows no caller outside its own tests in `packages/`; G15 should confirm and decide.
- `witness_corpus.zig` itself and `pi_witnesses.zig` are Phase 3 per the plan.

### Invariant 8 patterns

```
git grep -n -i -E "witnesses_cli|ratchet_command|ratchet show|ratchet check|zttp ratchet|zts ratchet|zttp witnesses|zts witnesses|witnesses (list|pin|unpin|prune|synthesize)|cmdRatchet|cmdWitnesses|RatchetError" -- docs README.md CLAUDE.md AGENTS.md STRATEGY.md CONCEPTS.md .agents .github scripts build build.zig packages tooling examples advisor-plans
```

Remaining hits: plan text of this series and `advisor-plans/005-feature-removal-rebase.md`, the `pre-rebase:` citations in `docs/proofs-and-receipts.md`, the builtin-graph solution doc, and `cli_main.zig`, and the two stale comments in `packages/pi/src/tools/zts_expert_ratchet.zig` (Phase 3).

### Checks

All commands ran with `DEEPSEEK_API_KEY` unset and private Zig caches. Each exit status was read from a redirected run.

- Exit 0, unfiltered: `zig build`, `test-cli` (829 passed, 1 skipped, 0 failed), `test-module-boundary` ("module boundary: OK (84 internal modules, 68 allowed package reaches)"), `test-docs-drift`, `test-step-coverage`, `test-script-reachability`, `test-doc-links`, `test-release-check`, `zig build test`, and `test-zruntime` (alone).
- `zig fmt --check build.zig build/ packages/ tooling/` and `bash scripts/audit-docs.sh`: exit 0.
- Invariant 4 after G8: `policy_hash` `b2038448...7ae3`, `module_registry_hash` `3bc86b0d...713d`, and `spec-hash` `83b822bd...77b8` equal the baselines. `git diff --stat -- policy-hash.txt docs/coverage.json docs/convergence.json docs/spec/` is empty.
- Invariant 3: nothing under `packages/pi` changed.

## G9 Analyzer command extras

### Removed

- `packages/tools/src/review_patch.zig`, `mock_server.zig`, `training_export.zig`, `packages/pi/src/gate_report.zig`, `packages/zts/src/extension_bindings.zig`, `scripts/zts-training-export.sh`
- The commands `review-patch`, `mock`, `zts-training-export`, `verify-module-manifest`, and `extension-status` from `zts_cli.commands`, and `gate-report` from the `zttp` command table. `zttp mock x` and the others now print "Unknown command".
- In `packages/tools/src/expert.zig`: `runVerifyModuleManifest`, `runExtensionStatus`, and everything only they reached (the entry type and loader, the argument parser, the text and JSON writers, `writeLabelSetText`, `writeContractRuleText`, `writeExportJson`, both help printers, and three parser tests). `meta`, `verify-paths`, and `verify-modules` stay.
- `extension_bindings` import and concatenation in `builtin_modules.zig`: `all` is now `builtins`.
- The `zts-training-export` build step (`build/artifacts.zig`), the `test-training-export` root (`build/host_tests.zig`), and the `zts-training-export` row in `scripts/manual-steps.allow`.
- `pi_app.runGateReportCommand`, the `gate_report` import in `app.zig`, and its import in `tests.zig`.
- The `extension_bindings.zig` row in `scripts/zts-tiers.allow`, the `tools trace` row in `scripts/module-boundary.allow` (only `mock_server.zig` reached `zts.trace` from `packages/tools`), and the `zttp mock --replay` ban row in `scripts/check-docs-drift.sh`.

### Edits that follow from the deletions

- `cli_help.zig`: removed the `gate-report` line from `help --all`, dropped `zttp review-patch` from the advanced-commands test, and reworded one test comment that used `review-patch` as its example.
- `bool_checker.zig`, `module_manifest.zig`, `docs/consumer-contract.md`: comments and one sentence that named `extension_bindings.all` or `extension-status`.
- `init_command.zig`: the `init --extension` path stays. Removed the two "Next steps" lines that named `zts verify-module-manifest` and `zts extension-status`, and the "Validate the manifest" section of the generated extension README. The README line about `zttp-module.json` now says the analyzer reads it through `--module-manifest`, which `precompile_args.zig` still accepts. The "partner module" wording in the init help text stays because it is accurate.
- `scripts/check-docs-drift.sh`: the minimum for parsed dispatch commands fell from 40 to 33. This gate floors its own input. G9 removed seven commands (45 to 38), so the old floor failed. The new floor keeps the same margin of five.
- Docs: `docs/cli.md` (command list, the `gate-report` paragraph, the whole Training Export section), `docs/internals/testing.md`, `docs/internals/zts-expert-contract.md`, `docs/proofs-and-receipts.md`, `examples/README.md` (now points `.test.jsonl` files at `zttp test`), `packages/pi/README.md`.

### `review-patch` text in `packages/pi`: model-visible, left alone

`expert_workflow.zig:162` is the `spec_goal` workflow route. `workflowNote` injects it into the session as a system note, so it reaches the model request. It names the registered tool `zts_expert_review_patch`, not the deleted CLI command. `expert_codegen_eval.zig:567` compares a tool name in code. Both stay and wait for Phase 3 with the tool.

The doc comment at the top of `packages/pi/src/tools/zts_expert_review_patch.zig` still says "matching the CLI's `zts review-patch --diff-only` semantics". The file is a tool definition, so Phase 1 may not touch it. The comment is stale. It goes in Phase 3.

`packages/pi/src/skills/fix-violations.md:11` says `review_patch --diff-only`. The plan already assigns that skill text to Phase 3. `packages/pi/README.md` now says `zts_expert_review_patch` with `diff_only`, which is the tool name.

### Dead code for G15

- `module_audit.verifyManifestPath` (`packages/tools/src/module_audit.zig:257`) has no caller and no test. Only the two deleted commands called it. Its helper `appendManifestDiagnostic` still has a caller in the same file.
- `module_manifest.parse` is still used by `contract_builder.zig`, `precompile_args.zig`, `manifest_registry.zig`, and others. No `module_manifest.zig` function lost its last caller.
- `ModuleMetadata.Manifest` text and JSON writers are gone with `expert.zig`. Nothing else remained.

### Judgments the plan did not settle

- Lowering the floor in `check-docs-drift.sh` and removing the `tools trace` and `zttp mock --replay` rows follow invariant 7: each subject went in this group.
- `examples/README.md` named `zttp mock` as the way to replay `.test.jsonl` fixtures. I pointed it at `zttp test`, which runs the same file format (`[tests.jsonl]` argument). I did not run an example through `zttp test`.
- `docs/cli.md` kept the "Tool Contract Gate" section and `--gate-log`. Only the `gate-report` reader went.
- The `release-artifact` reason in `scripts/manual-steps.allow` had one row. It has none now, and the gate passes, so no reason list needed an edit.

### Invariant 8 patterns

```
git grep -n -i -E "review_patch\.zig|review-patch|gate_report|gate-report|training_export|training-export|mock_server|zttp mock|zts mock|extension_bindings\.zig|extension-status|verify-module-manifest|runVerifyModuleManifest|runExtensionStatus|extension_bindings\.all" -- docs README.md CLAUDE.md AGENTS.md STRATEGY.md CONCEPTS.md .agents .github scripts build build.zig packages tooling examples RELEASE_CHECKLIST.md
```

Remaining hits: plan text of this series, `advisor-plans/005-feature-removal-rebase.md`, the model-visible `zts_expert_review_patch` tool name and its stale comment in `packages/pi` (Phase 3), `skills/fix-violations.md` (Phase 3), and frozen cassette text under `packages/pi/src/simulator/testdata`.

### Checks

All commands ran with `DEEPSEEK_API_KEY` unset and private Zig caches. Each exit status was read from a redirected run.

- Exit 0, unfiltered: `zig build`, `test-zts-cli`, `test-expert`, `test-cli` (829 passed, 1 skipped, 0 failed), `test-step-coverage`, `test-script-reachability`, `test-docs-drift`, `test-release-check`, `test-module-governance`, `test-expert-golden`, `test-doc-links`, `test-module-boundary` ("module boundary: OK (84 internal modules, 67 allowed package reaches)"), `test-expert-app`, `test-runtime-purity`, `test-standin`, and `zig build test`.
- `zig fmt --check build.zig build packages tooling` and `bash scripts/audit-docs.sh`: exit 0.
- `test-docs-drift` and `test-module-boundary` first failed (floor of 40 commands, unused `tools trace` row). Both pass after the edits above.
- The text `model_context_mismatch` appears in the output of `test-expert-app` and `zig build test`. It comes from replay tests that force a mismatch, and both steps exit 0.
- Invariant 4 after G9: `policy_hash` `b2038448...7ae3`, `module_registry_hash` `3bc86b0d...713d`, and `spec-hash` `83b822bd...77b8` equal the baselines. `git diff --stat -- policy-hash.txt docs/coverage.json docs/convergence.json docs/spec/` is empty.
- Invariant 3: no change under `packages/pi/src/skills/`, `prompts/`, `tool_registry.zig`, or `expert_persona.zig`.

## G10 Perf and equivalence receipts

### Removed

- `packages/zts/src/perf_receipt.zig`, `equivalence_receipt.zig`, `packages/pi/src/perf_probe.zig`, `equivalence_probe.zig`, `capsule_probe.zig`, `packages/runtime/src/perf_probe_lib.zig`, `equivalence_probe_lib.zig`
- The `perf_receipt` and `equivalence_receipt` exports in `contracts_root.zig` and `root.zig`, and their rows in `scripts/zts-tiers.allow` and `scripts/module-boundary.allow`
- The flags `--perf-receipt`, `--no-perf-receipt`, `--equivalence-receipt`, and `--no-equivalence-receipt`: the `cli_args.zig` bare-flag list and its test, the `cli_help.zig` lines, the `ExpertFlags` fields, the parser lines, and three tests in `packages/pi/src/app.zig`, and the two rows in `docs/cli.md`. `zttp expert --no-perf-receipt` is now an unknown flag.
- The three probe exports, the two `setEnabled` calls, and the `setProbeFn` registrations in `app.zig` and `dev_cli.zig`. The `tests.zig` and `cli_main.zig` imports.
- In `packages/runtime/src/proofs/pr_gate.zig`: the best-effort `recordEquivalenceReceiptFromContracts` call, the `sign` parameter of `analyzeHandler`, the `signed`, `sign_failure`, and `receipt_withheld` fields, the `signed_rows` parameter of `renderMarkdown`, the "No signed receipt" and "Signed receipt appended" report lines, the stderr line "no signed receipt for", and the `signed` key in each JSON handler object.

### Model-visible check

`pi_app.perf_probe.record`, `equivalence_probe.record`, and `capsule_probe` had no caller anywhere in `packages/pi`. The probes were only registered, never invoked, and they built no text for a model request, transcript, persona, or tool description. No file under `packages/pi/src/skills/`, `prompts/`, `tool_registry.zig`, or `expert_persona.zig` changed. The frozen cassettes mention none of the removed flags (`git grep` over `packages` finds no hit).

### Ledger compatibility

`proof_ledger.zig` still parses `kind=perf` and `kind=equivalence`, and `appendEvent` still serializes both (existing round-trip tests use it). Nothing in production writes them. Two new tests, "a legacy kind=perf row written by the removed probe still loads" and "a legacy kind=equivalence row written by the removed probe still loads", read raw row bytes. I captured those bytes from the deleted writers before deletion: a temporary test called `recordPerfReceiptWithKey` and `recordEquivalenceReceiptWithKey` with a fixed Ed25519 seed (32 bytes of 0x42) and dumped `.zttp/proofs.jsonl`. The rows hold a real facts object and a real JWS. Sabotaging an expected value in each test made `zig build test-cli` fail on that test, so both tests run.

### Judgments the plan did not settle

- `--no-sign` stays accepted and does nothing. The plan says to keep it. `Options.no_sign`, the `proofs_cli.zig` parser, the help text, and `docs/proofs-and-receipts.md` now say "accepted and ignored".
- The JSON `signed` key per handler is gone. It was `false` whenever signing was off or failed, and it can never be `true` now. The schema name `zttp.proof-gate.v1` is unchanged, and `docs/cli.md` never listed the key. A consumer that reads `signed` sees it missing. If the root session prefers the lowest-deletion option, restore `"signed": false` in `renderJson`.
- The run test "a critical lost proof fails the gate ... writes no receipt" became "... writes no ledger row". It runs with `no_sign = false` and still asserts that no `.zttp/proofs.jsonl` exists and now also that stderr is empty. This guards against signing coming back. It keeps `HomeOverride`.
- `proof_ledger.appendEvent` keeps its `perf` and `equivalence` parameters, and `handler_corpus.zig` stays. I delete less when the plan is silent. Both are G15 candidates (below).
- `docs/verification.md:708` listed "the expert equivalence receipt" and `prove`. G6 removed `prove`, so I rewrote the line to "`prove-behavior` and `proofs gate`".
- `docs/plans/2026-07-30-016-d3-canonical-form-wire-design.md:31` now cites `pre-rebase:packages/runtime/src/equivalence_probe_lib.zig`.

### Dead code for G15

- `packages/runtime/src/handler_corpus.zig` (`runHandlerCorpus`, `runHandlerCorpusFromSource`, `HandlerCorpusStats`) and its import in `zruntime_tests.zig:642`: the perf probe was the only production caller. Only its own tests reach it now. I rewrote the header comment.
- `proof_ledger.AppendParams.perf` and `.equivalence`, and the serializer blocks for them in `appendEvent`: only tests write these kinds. Removing them means rewriting the two round-trip tests and the `.perf` use in three other ledger tests onto raw rows. `PerfPayload` and `EquivalencePayload` stay for the reader.
- `cli_shared.nowUnixMs` (`packages/runtime/src/cli_shared.zig:81`): the gate was its last caller.
- `instruction_counter.zig` stays, as the plan says.

### Invariant 8 patterns

```
git grep -n -i -E "perf_receipt|equivalence_receipt|perf_probe|equivalence_probe|capsule_probe|perf-receipt|equivalence-receipt|recordPerfReceipt|recordEquivalenceReceipt" -- docs README.md CLAUDE.md AGENTS.md STRATEGY.md CONCEPTS.md .agents .github scripts build build.zig packages tooling examples advisor-plans
```

Remaining hits: plan text of this series, earlier worklog sections, `pre-rebase:` citations in `proof_ledger.zig` and the 2026-07-30 plan, and one sentence in `handler_corpus.zig` that names the removed probe.

### Checks

All commands ran with `DEEPSEEK_API_KEY` unset and private Zig caches. Each exit status was read from a redirected run.

- Exit 0, unfiltered: `zig build`, `test-cli` (823 passed, 1 skipped, 0 failed), `test-expert-app`, `test-zts`, `test-zts-layering`, `test-module-boundary` ("module boundary: OK (82 internal modules, 65 allowed package reaches)"), `test-docs-drift`, `test-step-coverage`, `test-proof-review`, `test-script-reachability`, `test-doc-links`, `test-release-check`, `test-zruntime`, `test-runtime-purity`, `test-standin`, and `zig build test`.
- `zig fmt --check build.zig build packages tooling` and `bash scripts/audit-docs.sh`: exit 0.
- Invariant 4 after G10: `policy_hash` `b2038448...7ae3`, `module_registry_hash` `3bc86b0d...713d`, and `spec-hash` `83b822bd...77b8` equal the baselines. `git diff --stat -- policy-hash.txt docs/coverage.json docs/convergence.json docs/spec/` is empty.
- Invariant 3: nothing changed under `packages/pi/src/skills/`, `prompts/`, `tool_registry.zig`, or `expert_persona.zig`. `test-expert-app` replays offline with exit 0.

## G11 Provable-reach tooling and RPC mode

### Removed

- `packages/pi/src/expert_reach_main.zig`, `expert_reach_report.zig`, `expert_reach_corpus.zig`, `expert_reach.zig`, `expert_reach_tests.zig`
- `docs/provable-reach.json`
- `packages/pi/src/rpc_mode.zig` and the `--mode rpc` value. In `app.zig` this removed the `rpc_mode` import, the dispatch branch in `run`, the `ExpertFlags.rpc_mode` field, the `rpc` arm of `setMode`, and the `RpcModeConflictsWithPrint` error with its message. Three flag tests that exercised `--mode rpc` went, and the `--goal` conflict test now covers only `--print`.
- The `provable-reach` build step (`build/tooling.zig`), the `test-provable-reach` root (`build/host_tests.zig`), and the `provable-reach` row in `scripts/manual-steps.allow`.
- The `expert_reach.zig` and `rpc_mode.zig` imports in `packages/pi/src/tests.zig`.
- The `--mode rpc` lines in `cli_help.zig` (usage, flag list, and the help test) and RPC user documentation in `docs/cli.md`, `docs/user-guide.md`, `docs/internals/architecture.md`, `docs/internals/zts-expert-contract.md`, and `packages/pi/README.md`.

### Kept

- `docs/provable-reach.md` stays as the M3 record. Its links to the JSON and its citation of `expert_reach_corpus.zig` now read `pre-rebase:`. One sentence near the top says that the tooling, suite, and report live at the `pre-rebase` tag. The command sections say they apply at that tag.
- `STRATEGY.md`, `docs/roadmap.md`, `docs/plans/README.md`, and `CONCEPTS.md` cite `docs/provable-reach.md`, not the JSON, and did not change.
- `expert_qualification.zig`, the qualification scripts, `gate_record.zig`, session resume, `--fork`, and `/tree` are untouched. Print mode and the REPL did not change, and nothing in `rpc_mode.zig` was shared with them (its helpers were private).

### Model-visible check

Nothing removed is model-visible. `rpc_mode.zig` and the reach files only served a stdio client and a repository measurement. No prompt, persona, skill, tool description, or transcript text changed, and `git diff HEAD` shows no change under `packages/pi/src/skills/`, `prompts/`, `expert_persona.zig`, or `tool_registry.zig`.

### Judgments the plan did not settle

- `error.GoalConflictsWithPrintOrRpc` became `error.GoalConflictsWithPrint`, and its message dropped "or --mode rpc". The old name had no meaning once RPC was gone.
- `--mode rpc` now fails with `UnsupportedMode`. The messages say `(json)` and `only accepts 'json'`.
- The `.rpc` member of the tool-surface enum (`registry/tool.zig`), the `allowedOn(.rpc)` branch, and the tests that use them stay. The enum feeds the shared tool-visibility logic, so removing it is a registry change. This is a G15 candidate.
- `docs/plans/2026-09-21-0955-feat-provable-set-reach-plan.md:280` and `docs/plans/2026-10-08-minimal-design-audit.md:261` now cite `pre-rebase:`. The M3 plan link to the JSON would otherwise fail `test-doc-links`.
- `CHANGELOG.md:625` still mentions `tools.invoke` RPC access. It is history and stays.
- `docs/internals/zts-expert-contract.md`: the in-process tools section named `tools.list`. I reworded it to name the tool registry, and removed the RPC paragraph. The `propose_change_set` guarantee stays in one sentence.

### Dead code for G15

- `session/events.zig`: `writeEntryEventLine` (line 957) has no caller left. Only `rpc_mode.zig` used it.
- `registry/tool.zig` `Surface.rpc`, the `.rpc` branch in `allowedOn`, `registry/registry.zig` test "model and rpc surfaces reject workspace writers", and the `.rpc` assertions in `app.zig` (the registry effect test). Nothing production uses `.rpc` now.
- Comments that still say RPC: `agent.zig:1029` ("--rpc"), `agent.zig:1454` (`compact` doc), `loop.zig:853`, `tools/pi_goal_candidate.zig:102,619`, `text_buffer.zig:4`, `registry/tool.zig:20,149,153`.
- `build/Context.zig` fields `pi_zts_cli_host_mod` and `project_config_mod` were passed to the reach executable. Check whether other steps still use them.

### Invariant 8 patterns

```
git grep -n -i -E "expert_reach|provable-reach|provable_reach|rpc_mode|rpc mode|--mode rpc|mode=rpc|test-provable|JSON-RPC|RpcMode" -- docs README.md CLAUDE.md AGENTS.md STRATEGY.md CONCEPTS.md .agents .github scripts build build.zig packages tooling
```

Remaining hits: `docs/provable-reach.md` (the M3 record, with `pre-rebase:` or "at that tag" wording), links to `docs/provable-reach.md` from `STRATEGY.md`, `docs/roadmap.md`, and `docs/plans/README.md`, the M3 plan text, the `pre-rebase:` citations, the `Generic JSON-RPC` comment in `registry/tool.zig`, and plan text of this series.

### Checks

All commands ran with `DEEPSEEK_API_KEY` unset and private Zig caches. Each exit status was read from a redirected run.

- Exit 0, unfiltered: `zig build`, `test-expert-app`, `test-cli`, `test-standin`, `test-step-coverage`, `test-docs-drift`, `test-doc-links`, `test-module-boundary`, and `zig build test`. `bash scripts/audit-docs.sh`: exit 0.
- The `zig build test` log contains two `[replay] model_context_mismatch` lines. They come from negative tests that check mismatch detection (a recorder and a promotion test). The step exit status is 0 and `coverage.json is stale` does not appear.
- Invariant 4 after G11: `policy_hash` `b2038448...7ae3`, `module_registry_hash` `3bc86b0d...713d`, and `spec-hash` `83b822bd...77b8` equal the baselines. `git diff --stat -- policy-hash.txt docs/coverage.json docs/convergence.json docs/spec/` is empty.

## G12 SMT layer and z3

### Removed

- `packages/zts/src/semantics_smt.zig`, `packages/zts/src/semantics_audit.zig`, `packages/tools/src/smt_solver.zig`
- In `semantics_check.zig`: `runSmt`, `runAudit`, `SmtResult`, `AuditResult`, `SmtObligation`, `SolveFn`, `collectSmtObligations`, `execLowering`, `proveSmtObligations`, and every test that used a fake solver (including the `collectSmtObligations` coverage test and the test that encoded every excluded law). The header now lists four mechanisms.
- In `semantics_cli.zig`: the `--audit` flag, the SMT and audit fields of the report, the two "smt equivalence" and "exclusion audit" text lines, the `smt` and `audit` JSON keys, and the `smt_solver` import. The aggregation test now covers the structural and corpus failures only.
- The `semantics_smt` and `semantics_audit` re-exports in `compiler_root.zig` and `root.zig`, and the `encodeRefutation` and `default_audit_timeout_ms` aliases in `root.zig`.
- The `test-smt-solver` row in `build/host_tests.zig`, the `tools semantics_smt` row in `scripts/module-boundary.allow`, the two rows in `scripts/zts-tiers.allow`, and the `test-smt-solver` row in `docs/internals/testing.md`.
- z3 from the install steps of `.github/workflows/ci.yml` and `release.yml`. The steps are now named "Install ripgrep" and install ripgrep only.

### Rewritten

- `scripts/check-semantics-spec.sh` runs `zts spec-check` and `zts spec-render --check docs/spec/semantics.spec.ts` with `set -euo pipefail`. It no longer needs `jq` and has no z3 branch.
- `docs/internals/semantics-verification.md` describes four mechanisms and the soundness boundary. It cites the removed files as `pre-rebase:`.
- Wording only: `CLAUDE.md`, `CONTRIBUTING.md` (Z3 and `ZTTP_Z3` removed from the prerequisites), `docs/README.md`, `docs/cli.md` (`ZTS75x counterexample` removed from the exit code text), `docs/zts-formal-spec-northstar-advanced.md` (`spec-check --audit` became `spec-check`), `docs/plans/2026-07-30-016-d3-canonical-form-wire-design.md`, and comments in `semantics.zig`, `compiler_root.zig`, `repair_validator.zig`, and `invariant_author.zig`.

### Kept

`semantics.zig` with `excluded_laws` and each row's `audit_timeout_ms` as data (hashed into `semanticsHash`, rendered into `docs/spec/`). `semantics_check.zig` `runCheck`, `semantics_corpus.zig`, `semantics_render.zig` (its rendered strings are unchanged, so `docs/spec/semantics.spec.ts` is byte-identical), `semantics_cli.zig` with `spec-check`, `spec-hash`, and `spec-render`, and `docs/spec/`.

### Dead for Phase 3

The `SpecCode` variants `smt_counterexample` (ZTS755), `smt_unencodable` (ZTS756), `excluded_law_holds` (ZTS757), `audit_solver_error` (ZTS758), `audit_inconclusive` (ZTS759), and `smt_unproven` (ZTS760) in `diagnostic_catalog.zig:109-114` have no producer now. The plan names ZTS757 and ZTS758; the other four are in the same state. They stay, with their rows at `scripts/corpus-uncovered.allow:107-112`, because deleting them moves `diagnosticHash`. The reason text on those rows ("produced by the semantics-conformance producer") is now inaccurate for ZTS755 to ZTS760. A Phase 3 commit that deletes the variants and rows must go with the re-record. `check-diagnostic-producers.sh` still passes ("17 variants"), so it does not cover these.

Also unconsumed after G12: `semantics.excluded_laws` and `Law.audit_timeout_ms` have readers only in `semantics_render.zig` and the hash. Keep them while `semanticsHash` and `docs/spec/` are published identities.

### Probe: `check-semantics-spec.sh` still fails when a check fails

- Probe 1: appended one byte to `docs/spec/semantics.spec.ts`. `bash scripts/check-semantics-spec.sh` exited 1 and printed `spec-render --check: the committed spec is stale`. I restored the file from a copy. The script then exited 0, and `git diff --stat -- docs/spec/` was empty.
- Probe 2: in a scratch tree (`scratchpad/simplify/probe2`), a stub `zig-out/bin/zts` exited 1 for `spec-check` and 0 otherwise. The copied script exited 1. With a stub that always exits 0, the copied script exited 0.

### Invariant 8 patterns

```
git grep -n -i -E "semantics_smt|semantics_audit|smt_solver|runSmt|runAudit|SmtResult|AuditResult|test-smt-solver|ZTTP_Z3|\bz3\b|spec-check --audit|encodeRefutation|default_audit_timeout|collectSmtObligations" -- docs README.md CLAUDE.md AGENTS.md STRATEGY.md CONCEPTS.md CONTRIBUTING.md .agents .github scripts build build.zig packages tooling
```

Remaining hits: `pre-rebase:` citations in `semantics-verification.md`, `semantics.zig`, `invariant_author.zig`, and the d3 plan, the sentence in `semantics-verification.md` that says `--audit` and `ZTTP_Z3` were removed, and the Phase 1 plan text.

### Checks

All commands ran with `DEEPSEEK_API_KEY` unset and private Zig caches. Each exit status was read from a redirected run.

- Exit 0, unfiltered: `zig build`, `test-zts`, `test-zts-cli`, `test-zts-layering`, `test-module-boundary`, `test-release-check`, `test-release-workflow`, `test-diagnostic-corpus`, `test-docs-drift`, `test-step-coverage`, `test-script-reachability`, `test-doc-links`, `test-standin`, `test-expert-app`, and `zig build test`. `bash scripts/check-semantics-spec.sh`, `bash scripts/check-diagnostic-producers.sh`, `bash scripts/audit-docs.sh`, and `zig fmt --check build.zig build packages tooling`: exit 0. `coverage.json is stale` does not appear in the `zig build test` log.
- Invariant 4 after G12: `policy_hash` `b2038448...7ae3`, `module_registry_hash` `3bc86b0d...713d`, and `spec-hash` `83b822bd...77b8` equal the baselines. `git diff --stat -- policy-hash.txt docs/coverage.json docs/convergence.json docs/spec/ packages/zts/src/diagnostic_catalog.zig` is empty. `diagnosticHash` is not in `meta --json`. `diagnostic_catalog.zig` is unchanged, `docs/coverage.json` still holds `6b7fead4...1191`, and `test-standin` and `test-expert-app` (which check it) pass.
- Invariant 3: nothing changed under `packages/pi/src/skills/`, `prompts/`, `tool_registry.zig`, or `expert_persona.zig`.

## G13 baseline

Unfiltered `zig build test-standin` before G13a (HEAD `22dc9b1a`), run with `DEEPSEEK_API_KEY` unset and private Zig caches, exit 0: `Build Summary: 6/6 steps succeeded; 56/56 tests passed`, and the run step line `run test 56 pass (56 total)`. G13b and G13d must reproduce `56/56 tests passed`. The step runs only tests whose name contains `stand-in` (`standin_only` in `build/host_tests.zig` sets `.filters = &.{"stand-in"}`), so a ported test keeps `stand-in` in its name.

## G13a Neutral home for propose_change_set

### Moved

`packages/pi/src/providers/anthropic/propose_change_set.zig` is now `packages/pi/src/providers/propose_change_set.zig` (`git mv`). Its four relative imports changed depth (`../turn.zig`, `tool_catalog.zig`, `../contract_gate.zig`, `../registry/tool.zig`). No other line of the file changed.

### Importers updated (14 files)

`cassette_tests.zig`, `gate_record.zig`, `loop.zig`, `standin_main.zig`, `standin_tests.zig`, `tests.zig`, `simulator/recorder.zig`, `providers/capture_sink.zig`, `providers/cassette_client.zig`, `providers/anthropic/client.zig`, `providers/anthropic/tools_schema.zig`, `providers/deepseek/client.zig`, `providers/local/client.zig`, `providers/openai/client.zig`. In `cassette_client.zig` the import alias `anthropic_propose_change_set` became `propose_change_set` (four uses), because the file is no longer under `anthropic/`. `tools_schema.zig` stays in place.

### Checks

All commands ran with `DEEPSEEK_API_KEY` unset and private Zig caches. Each run was redirected to a file and the exit status read directly.

- Exit 0, unfiltered: `test-expert-app` (1048 of 1049 passed, 1 skipped), `test-cassette` (425/425), `test-simulator` (927/927), `test-standin` (56/56, equal to the G13 baseline), `test-module-boundary`, `zig build`, and `zig build test` (9132 of 9138 passed, 6 skipped). `zig fmt --check` on the 15 changed files: exit 0.
- Invariant 2: the `test-expert-app` log and the `zig build test` log contain `model_context_mismatch at turn 0/2` only from the two negative tests (a recorder test and a promotion test), as in G12. `response_order_mismatch` and `coverage.json is stale` do not appear.
- Invariant 3: `git diff --stat` over `tool_registry.zig`, `expert_persona.zig`, `skills/`, and `prompts/` is empty.
- Invariant 4 after G13a: `policy_hash` `b2038448...7ae3`, `module_registry_hash` `3bc86b0d...713d`, and `spec-hash` `83b822bd...77b8` equal the baselines. `git diff --stat -- policy-hash.txt docs/coverage.json docs/convergence.json docs/spec/` is empty.
- Invariant 8: `git grep -n "anthropic/propose_change_set" -- docs README.md CLAUDE.md AGENTS.md STRATEGY.md CONCEPTS.md .agents .github scripts build build.zig packages` returns only the Phase 1 plan and this worklog (historical text). `advisor-plans/005-feature-removal-rebase.md` also names the old path.

## G13b Stand-in on the chat-completions wire

### Decision

The stand-in tests run on the local client (`AgentSession.initLocal`, `providers/local/client.zig`). `deepseek.validateBaseUrl` is unchanged: it still requires HTTPS, and no loopback exception exists. The local client posts to `<root>/v1/chat/completions` and accepts only a plain-HTTP loopback root with no path, so the stand-in serves exactly `POST /v1/chat/completions` and the tests pass `server.url(allocator, "")` as the root.

### Changed

- `standin/server.zig`: the route is `POST /v1/chat/completions`; the 400 text says "invalid Chat Completions request"; the header comment names Chat Completions. The health route is unchanged.
- `standin/request.zig`: `parse` reads a top-level `messages` array. A `user` message has a string `content`. An `assistant` message with `tool_calls` supplies the path of the last `workspace_read_file` call (`readCallPath`). A `tool` message with string `content` plays the part of `function_call_output`. A compaction summary arrives as two user messages (the marker, then the body), so a `summary_follows` flag replaces the old two-part content array. `readInputText` and `isUserMessage` are gone. The nine request tests carry the same assertions on the new body shape. No test was added or removed.
- `standin/playbook.zig`: `protocol` is `chat-completions-json`. `renderToolCall` and `renderText` emit one non-streaming `chat.completion` object (`choices[0].message` with `tool_calls` or `content`, `finish_reason` `tool_calls` or `stop`, and a zero `usage`). The two miss texts name `ZTTP_MLX_BASE_URL`. The add-route rendering test asserts the JSON shape.
- `standin_main.zig`: the openai `sse_parser` and `response_assembler` imports are gone; the two decode tests use `local_client.decodeResponse`. The miss text assertion names `ZTTP_MLX_BASE_URL`.
- `standin_tests.zig`: the openai imports are gone. All nine sessions use `initLocal` with the stand-in root as `base_url`, and the tools come from `local_client.writeToolsArray` (helper `buildLocalToolsJson`). The seven decode sites call `local_client.decodeResponse(allocator, "", body)`.
- `standin_range_tests.zig`: the same decode change. A new helper `expectSingleToolCall` handles one case the old assembler did not have: the local decoder already remaps a well-formed `propose_change_set` call into `.change_set`, so the helper accepts that shape for `propose_change_set` and `.tool_calls` for every other tool.
- Docs: a paragraph in `docs/solutions/architecture-patterns/deterministic-stand-ins-exercise-model-paths-offline.md` and the `standin/` line in `packages/pi/README.md`. `packages/pi/docs/standin-range.md` (generated) is unchanged because it does not describe the wire.

### Not touched

`providers/openai/`, `providers/anthropic/`, the provider arms in `agent.zig` (including `ZTS_OPENAI_BASE_URL` and the `/v1/responses` URL tests), `repl.zig`, `cli_auth.zig`, and the enum. These are G13d. `docs/coverage.md` and `docs/convergence.md` are unchanged.

### Seed equivalence

The `test-standin` output before G13a and after G13b is identical line for line, apart from the cache path in the `failed command` line: `seeded retry arm 54/54`, `compiler repair arm 4/4`, `seeded salvage arm 6/6`, `veto classes 64/64`, `rule accounting 62 advertised = 61 seed-verified + 1 accounted unseeded`, the `[seed-coverage]` JSON line, `generated routing 448/448`, and the rest. No seed tripped a different rule.

### Checks

All commands ran with `DEEPSEEK_API_KEY` unset and private Zig caches, with output redirected and the exit status read directly.

- Exit 0, unfiltered: `test-standin` (56/56, equal to the G13 baseline), `test-residual-guards-drift` (56/56), `test-expert-app` (1048 of 1049, 1 skipped), `test-cassette` (425/425), `test-simulator` (927/927), `test-convergence-emitter`, `test-step-coverage`, `test-docs-drift`, `test-doc-links`, `test-script-reachability`, `test-module-boundary`, `test-diagnostic-producers`, `zig build`, and `zig build test` (9132 of 9138, 6 skipped). `zig fmt --check` on `standin/` and `standin_*.zig`: exit 0. `zig build zttp-standin -- --range` builds the executable and prints the range document.
- Invariant 2: the only `model_context_mismatch at turn 0/2` lines are the two negative tests. `response_order_mismatch` and `coverage.json is stale` do not appear. `docs/coverage.json` and `docs/convergence.json` are unchanged.
- Invariant 3: `git diff --stat` over `tool_registry.zig`, `expert_persona.zig`, `skills/`, and `prompts/` is empty.
- Invariant 4: `policy_hash` `b2038448...7ae3`, `module_registry_hash` `3bc86b0d...713d`, and `spec-hash` `83b822bd...77b8` equal the baselines. `git diff --stat -- policy-hash.txt docs/coverage.json docs/convergence.json docs/spec/` is empty.
- Invariant 8: `git grep -n "openai-responses-sse\|v1/responses" -- docs README.md CLAUDE.md AGENTS.md .github scripts build build.zig packages` leaves only `agent.zig` URL tests, `providers/cassette_record.zig:440`, and `providers/openai/client.zig:30` (all G13c or G13d), plus the plan files.
