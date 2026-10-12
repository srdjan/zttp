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
