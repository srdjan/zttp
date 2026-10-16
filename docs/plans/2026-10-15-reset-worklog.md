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
| `2019e62d` | switch compilation to direct typed parsing (U15) |

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

## U16 acceptance

U16 switches the remaining production frontend callers to original-source parsing.
Astra accepts the integrated source, observer ownership, inline source profiles, and public server control.
All 34 source hashes match the retained manifest after the complete verification script.
The authority owns the detailed findings, failed experiments, exact comparisons, and acceptance evidence.

| Receipt under `/tmp/zttp-reset-20261015/` | Result |
|---|---|
| `u16-frontend-final-v1` | 3,961 passed, one skipped, forty-five steps, exit 0 |
| `u16-additional-final-v1` | 1,376 passed, one skipped, fifty steps, exit 0 |
| `u16-runtime-final-v1` | 230 passed, five steps, exit 0 |
| `u16-server-final-v1` | 335 passed, two skipped, five steps, exit 0 |
| `u16-normalize-final-v1` | 33 files printed; no skip, refusal, or byte difference; exit 0 |
| `u16-spine-final-v1` | Four steps passed, exit 0 |
| `u16-format-final-v2` | All required Zig paths passed, exit 0 |
| `u16-verify-final-v1` | Every unchanged script step passed, exit 0 |

The Pi comparison matches forty-four payloads and all 9,850 stdout and stderr bytes.
The graph comparison matches twelve records and all 5,944 stdout and stderr bytes.
The inline CLI comparison matches twelve outcomes and functional output, with allocator leak counts retained.
The generated-test comparison matches eight outcomes and functional output.
Those last two comparisons exclude implementation stack traces; the authority states their exact limits.
The imported runtime control uses the existing arena lifetime and does not establish individual payload cleanup.

## Current work: U17 remove reconstruction

U16 acceptance is complete and ready for its isolated local commit.
Main owns that commit and the subsequent U17 source changes.
The fresh census records remaining legacy test oracles and adapters outside production entry paths.
Astra identifies the required semantic compatibility rules and test controls that must remain.
Main will remove the oracle last after the replacement behavior fixtures pass.

Temporary U17 work remains under `/tmp/zttp-reset-20261015/u17-work`.
The native AST inventory identifies 438 declarations and 186 tests in the differential module.
Its identifier closure is an inventory, not permission to delete dependent tests.
The pre-removal catalog hash and three measured signature-order fixtures remain in that directory and the authority.
The TypeEnv measurement passes all 156 unfiltered tests.
The presentation candidate passes seven rendering tests, then 817 tests through its relocated source owner.
The catalog hash remains exact after that temporary relocation.
`working-zts` contains the temporary relocation and later comment cleanup; no U17 source enters the repository yet.
Its temporary forwarding alias remains necessary until the old scanner disappears.

## Remaining work

Main owns U17 removal, exact behavior controls, final census, required gates, Astra review, and its local commit.
U18 introduces recovered workspace ownership without moving proof, approval, or durable session policy.
Astra records the owner API, distinct initialization errors, failed-commit policy, and acknowledgement ordering in the session review.
U19 removes unused proof-review state after a fresh caller census.
U20 reconciles documentation, measured performance, final evidence, and the required quality checks.
Main will continue through all approved phases and the quality checks.

Astra accepts the final U16 execution audit with no remaining blocker.
The final documentation gate passes all eight steps with exit 0.
Main owns the exact-path local commit and subsequent U17 migration.
