# Reset implementation worklog

## Objective and authority

The [reset plan](2026-10-14-reset-implementation-plan.md) owns findings, design, phase order, and acceptance.
This compact worklog records the current execution state and receipts.
The user approved implementation with "reviewd, go ahead, use subagents when possible, verify with astra" on 2026-10-15.
That approval supersedes the earlier planning-only paragraph.
The task continues through U20 and the required quality checks.

## Constraints

Work stays on local main, with one local commit for each completed phase.
No push, branch, worktree, provider call, corpus replacement, or public format change is authorized.
Main owns source changes, review, integration, verification, documentation, and Git writes.
Astra xhigh supplies independent validation.
Both Sol workers reach their usage limit, so Main owns their remaining work.
No new subagent may exceed the three-agent limit.

The pinned toolchain is `/Users/srdjans/.zvm/bin/zig`, version 0.16.0.
No Python, filtered acceptance test, or concurrent pool-heavy root is permitted.
Source stays fixed during each acceptance gate.
Every receipt retains the exact command and direct process status.
The external cache is `/tmp/zttp-reset-20261015/zig-cache`.
The stable pipe runner is `/tmp/zttp-reset-20261015/run-stable-captured.rb`.
The runner retains complete native output and records its environment.
A Zig warning can include "failed command"; the direct status supplies the verdict.

The starting commit was `f917dc0b7320ecd0165e49a274311f77b3290796`.
Its tracked tree was `d3b97c46e4ee5fbd0da9174d4343887fbbbc7e16`.
The untracked Claude sibling plan remains untouched and excluded from commits.
No browser session was opened.
Detailed earlier worklog entries remain in Git at `7b4cf5b2`.
The authority retains the detailed findings and acceptance evidence.

## Completed phases

| Commit | Completed phase |
|---|---|
| `ad1aa961` | freeze current frontend and CHECK behavior (U1) |
| `2f1ca7c5` | carry sibling export effects into contracts (U2) |
| `f4967788` | consolidate module analysis lifetime (U3) |
| `a13b1849` | reuse immutable effect facts for path analysis (U4) |
| `d79afafb` | reuse immutable effects for contract extraction (U5) |
| `f8d4fce4` | bind machine operations to captured root bytes (U6) |
| `a56107e3` | parse primitive annotations beside runtime IR (U7) |
| `df11fb48` | add private compound type syntax (U8) |
| `23ef9e84` | add named declarations to private typed parsing (U9) |
| `aa5489c2` | add private generic syntax and semantic projections (U10) |
| `f48b8295` | attach typed annotations to final runtime owners (U11) |
| `0b7dc23b` | add owned syntax inputs for type consumers (U12) |
| `43beacd7` | add direct syntax for proof and printer consumers (U13) |
| `7b4cf5b2` | switch CHECK to direct typed parsing (U14) |
| this commit | switch compilation to direct typed parsing (U15) |

## U15 acceptance

Astra accepts the production source, public allocation calibration, and final execution receipts.
All ten source hashes match `u15-integrated-hashes.json` outside the repository.
The authority retains those hashes and the detailed ownership findings.

| Receipt under `/tmp/zttp-reset-20261015/` | Result |
|---|---|
| `u15-delayed-runtime/engine-v1.log` | 1,169 passed, one skipped, exit 0 |
| `u15-callers/engine-v4.log` | 1,176 passed, one skipped, exit 0 |
| `u15-callers/compiler-v2b.log` | 1,549 passed, exit 0 |
| `u15-callers/precompile-v5.log` | 254 passed, exit 0 |
| `u15-public-compile-census/full.log` | Eighteen legacy comparisons passed, exit 0 |
| `u15-frontend-v6.log` | Forty-five steps; 3,951 passed, one skipped, exit 0 |
| `u15-additional-v6.log` | Twenty-four steps; 647 passed, two skipped, exit 0 |
| `u15-runtime-v6.log` | Five steps; 226 passed, exit 0 |
| `u15-handler-v6.log` | Thirteen build steps passed, exit 0 |
| `u15-stable-cache-cli-pilot.log` | Eighteen CLI cases and five steps passed, exit 0 |
| `u15-verify-stable-v6.log` | Every step in the unchanged full script passed, exit 0 |
| `u15-final-docs-spine-v6.log` | Eight build steps passed, exit 0 |

The separate formatting check includes `build.zig`, `build`, `packages`, and `tooling` and exits 0.
The earlier full attempts remain failed receipts.
The first loses generated files from the shared cache; the removing actor is unknown.
The second passes 8,768 tests but cannot spawn the CLI through a relative cache path after changing directories.
The successful script uses an absolute external cache and unchanged source.
Installed U15 binaries and their hashes remain under `retained-binaries` outside the repository.
The earlier legacy analyzer disappears with the shared cache after its eighteen-case comparison finishes.
All completed comparison receipts and source inputs remain intact.

## Current work: U16 remaining frontend callers

No U16 production source enters the repository yet.
The temporary work lives under `/tmp/zttp-reset-20261015/u16-work`.
The authority records source findings, measured corrections, and the fresh observer design.
Astra accepts the fresh owner and transactional admission transfer.
The first frozen observer root passes 1,176 unfiltered engine tests, with one skip.
That result does not close the new measured compatibility gaps.

The first native experiment restores four missing legacy `any` refusals.
The array and initialized-comma controls retain their parser errors.
Independent controls then expose assignment comments, raw lookahead parentheses, and keyword function names.
The next observer draft must close those gaps before integration.
The working overlay also contains an unreviewed printer capture draft and a parse-identity draft.
The frozen v3 snapshot excludes the printer capture draft.

Prepared inline source must remain separate from raw virtual source and file TypeScript.
The server retains `<inline>`; the shared loader retains `<eval>`.
Machine graph records retain imports before the first failed statement.
The benchmark retains IR optimization and its existing allocator boundaries.
The printer requires complete source capture, including source refused by the runtime parser.
Preparation OOM retains `strip_failed`; later printer allocation failure still propagates.
Partial semantic Store contents do not establish complete printer observation.

## Remaining work and next action

Main owns U16 observer corrections, remaining caller migration, exact comparisons, Astra review, and its local commit.
U17 removes reconstruction only after production legacy calls reach zero.
U18 encodes recovered workspace ownership.
U19 removes unused proof-review state after a fresh caller census.
U20 reconciles documentation, measured performance, final evidence, and the required quality checks.
Main will continue until all approved phases finish.
