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
