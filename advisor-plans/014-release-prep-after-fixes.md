# Plan 014: The release record matches the code, and the evidence is current

> **Executor instructions**: Follow this plan step by step. Run every verification command and confirm the expected result before you continue. Touch only the files in scope. If a STOP condition occurs, stop and report. When done, update the status row for this plan in `advisor-plans/README.md`.
>
> **Drift check, run first**: `git log --oneline v0.24.0..HEAD | wc -l` and `git status --short`
> The tree must be clean. Every other plan in this series that the owner selected must be DONE.

## Status

- **Priority**: P1
- **Effort**: S
- **Risk**: LOW
- **Depends on**: every selected plan from 007 to 013, and the re-record if plan 013 or U2 or U3 ran
- **Category**: docs (release)
- **Planned at**: commit `c1ecdf65`, 2026-10-26
- **Source**: release review 2026-10-26, finding M6 and the stale roadmap row

## Why this matters

`CHANGELOG.md` `[Unreleased]` is empty although 172 commits landed after v0.24.0, including user-visible analyzer changes and possibly breaking parser changes. The roadmap still lists the release-provenance republish as open. The 2026-10-26 `bool_checker` audit (Decisions 14 and 15) is not in the repository. `zig build release-provenance` (`tooling/release_provenance.zig`, `validateEvidenceFile`) accepts the published evidence only when the net difference between its source commit and the release commit touches nothing but the four evidence files. So the evidence must be republished after the last other change.

## Current state

- `CHANGELOG.md`: `## [Unreleased]` has no entries; `## [0.24.0] - 2026-10-23` follows. `RELEASE_CHECKLIST.md` (Prepare And Tag) gives the promotion steps and requires Highlights and Breaking changes; `sh scripts/render-release-notes.sh vX.Y.Z release-notes.md` fails on a missing or empty section.
- User-visible commits after v0.24.0 named by the release review: `382ffeaa` (header params read inside spread operands), `2e4ce352` (no ZTS605 for a static key declared in a callback), `e91aafc6` (HEAD replies without bodies), `68c26be9` (schema depth bounded at 512), `766154dd` (names over 255 bytes refused), and possibly breaking `5085f2be` (get and set data keys refused; large radix literals read exactly) and `df97cbbd` (complete binding signatures required). Read each with `git show --stat <sha>` and its message before you classify it.
- `docs/roadmap.md`: the release-provenance item in "Open owner decisions after the reset". Plan 011 Step 4 may already have removed it.
- `docs/plans/2026-10-25-reset-worklog.md`: last section "Owner decisions 8 to 11, 2026-10-26". Decisions 14 (a) and 15 (a) of 2026-10-26: a read-only audit of the `else => {}` walks in `packages/zts/src/bool_checker.zig` found no fail-open; `inferBlockReturnType` can infer a too-narrow type because it skips returns nested in loops; production `requireBoolean` decides through the authoritative type checker, so the narrow inference cannot change a ZTS100 verdict when a type environment exists (untyped sources, which ZTS052 refuses, and several tests run without one). The local inference also supplies specialization hints (`annotateNodeType`), which this audit did not assess. The owner chose no change.
- Evidence publish: `scripts/update-convergence.sh`, then `scripts/update-coverage.sh`, each on a clean tree, each with its own new, empty `ZIG_LOCAL_CACHE_DIR` (the build does not declare `ZTTP_EVIDENCE_PUBLISH` as an input, so a warm cache skips the replay and the script fails with `MissingOrDuplicateMarker`), each followed by its own commit.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Release notes | `sh scripts/render-release-notes.sh vX.Y.Z release-notes.md` | exit 0 |
| Docs and spine | `zig build test-docs-drift`, `zig build test-doc-links`, `git add -A && zig build check-spine` | `0` each |
| Full gate | `bash scripts/verify.sh` | `0` |
| Evidence | `ZIG_LOCAL_CACHE_DIR=<new empty dir> bash scripts/update-convergence.sh < /dev/null`, then the same for `update-coverage.sh` with another new empty dir | exit 0 each |
| Provenance and passport | `zig build release-provenance`, `zig build release-check` | `0` each |

Unset `DEEPSEEK_API_KEY` for every command.

## Scope

**In scope:** `CHANGELOG.md`, `docs/roadmap.md`, `docs/plans/2026-10-25-reset-worklog.md`, `docs/convergence.json`, `docs/convergence.md`, `docs/coverage.json`, `docs/coverage.md`.

**Out of scope:** `VERSION` and the version copies (the owner sets the release number); tagging; `scripts/release.sh`; pushing.

## Steps

### Step 1: Fill `[Unreleased]`

Write Added, Changed, Fixed, and Breaking changes entries for every user-visible commit after v0.24.0, including the plans from this series that landed. Each breaking change names its migration action.

**Verify**: review the section by reading; Step 3 renders it after the owner promotes it.

### Step 2: Close the stale records

Delete the release-provenance item from `docs/roadmap.md` if it is still there. Append a section "Owner decisions 14 and 15, 2026-10-26" to the reset worklog with the facts above.

**Verify**: `test-docs-drift`, `test-doc-links`, and `check-spine` exit 0. Commit Steps 1 and 2.

### Step 3: Hand edits by the owner, then the full gate

STOP and hand over to the owner. The owner sets `VERSION` and every version copy, promotes `[Unreleased]` to `[X.Y.Z] - <date>` as `RELEASE_CHECKLIST.md` describes, and commits. Every hand edit must land before Step 4, because a later change to a non-evidence file makes the evidence stale. Then run the full gate.

**Verify**: `sh scripts/render-release-notes.sh vX.Y.Z release-notes.md` and `bash scripts/verify.sh` exit 0 on the committed tree.

### Step 4: Republish the evidence last

Run the convergence publish with a new empty cache and commit `docs/convergence.json` and `docs/convergence.md`. Then run the coverage publish with another new empty cache and commit `docs/coverage.json` and `docs/coverage.md`. Compare the published numbers with the previous row; a change in the first-draft, final-green, round-trip, or intent numbers must be explained by a plan in this series or the re-record.

**Verify**: `zig build release-provenance` and `zig build release-check` exit 0.

## Done criteria

- [ ] `[Unreleased]` lists every user-visible change, with migrations for breaking ones.
- [ ] The roadmap and worklog are current.
- [ ] `verify.sh`, `release-provenance`, and `release-check` exit 0, and the evidence commits are the last two commits.

## STOP conditions

- A selected plan is not DONE.
- A publish script fails. Read its log first: a stale-cassette failure means a hashed surface moved without a re-record; any other build or test failure is a defect to diagnose before you assign a cause.
- A commit that changes a non-evidence file lands after the evidence commits; republish again.

## Maintenance notes

- The owner then tags the coverage commit and runs `bash scripts/release.sh vX.Y.Z --no-publish`, as `RELEASE_CHECKLIST.md` describes. A later commit that changes a non-evidence file makes the evidence stale again.
