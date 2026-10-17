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
| `e6f8381f` | switch remaining callers to direct typed parsing (U16) |
| `d2697471` | remove legacy typed frontend reconstruction (U17) |
| `66fb05c2` | bind edits to recovered workspace ownership (U18) |
| `6f39fc48` | remove retired proof-review state helpers (U19) |
| This worklog's commit | reconcile final documentation and evidence (U20) |

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

## U17: remove reconstruction

U16 is committed as `e6f8381f` after its completed acceptance audit.
Main owns the U17 source changes, review, and verification.
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
The reviewed presentation relocation and its existing tests now enter the repository.
U17's direct parser migration is accepted by the read-only Astra review.
The unfiltered `test-zts` run passes 2,707 tests with one skip. The frontend
batch passes all 45 steps, including the corpus, contract, module-boundary,
and layering gates. The registry and spine batch, normalization check, and
format check also pass. Exact catalog identity remains unchanged.

The direct-source migration now covers diagnostic presentation, checker and
pipeline fixtures, ASI and fuzz censuses, example evidence, printer and bytecode
controls, runtime witness and error rendering, and the check command. The
stripper and TypeMap implementation files, exports, TypeEnv joins, and test
oracles are removed. The direct fixtures retain literal contract and bytecode
results, semantic owners, allocation failure controls, and original-source
admission spans. The first post-removal unfiltered ZTS run exited 0 with 2,717
passes and one skip. The retained direct test file was then renamed and its
oracle scaffolding entered a second review pass. Its private source preflight
scanner and duplicate Store lowering driver are removed. Direct fixtures pin
the speculative group and three header fallback constructions with literal
pool and owner expectations.

The post-removal `diagnosticCatalogHash()` probe exits 0 and matches the
pre-removal hash exactly:
`657967a5eab118485ffc7038480ab754ab8f8f95782e7ffe4f52424056525d15`.
Build and run receipts are `catalog-after-build-v2` and `catalog-after-run`
under the temporary U17 work directory.

The sandbox initially denied staging the rename and deletions through
`git add -A`. An explicit path staging command later succeeded. A temporary
index under the U17 work directory let Git-backed structural gates run before
the local commit.
With that index, the ZTS layering gate passes (166 reachable files, zero
cross-tier edges) and the module-boundary test passes (54 allowed reaches).
The local main commit remains unavailable until the Git directory is writable.
The aggregate gate reaches 8,627 passes but cannot pass in this sandbox:
loopback listeners and connections return `EPERM` in recorder, cassette,
simulator, runtime server, stand-in, and CLI cases. Its first run also found
two gate harness issues. The docs-drift exclusion followed the removed
stripper rather than the relocated diagnostic text; that exclusion is now
bound to `source_diagnostics.zig` and its named gate passes. Temporary Git
fixtures inherited the alternate index and emptied later file censuses; a
scoped Git wrapper now preserves the 477 package Zig paths through fixture
writes, and the affected structural gates pass in a separate unfiltered run.

## U18: recovered workspace owner

`RecoveredWorkspace` acquires the lock and completes recovery before callers
can commit or read pending receipts. It captures the canonical root, rejects a
different commit root before writing, and requires close and reopen after a
failed commit. Five production callers use this owner. The receipt retry test
checks that a pending receipt exists before retry and that durable recording
precedes acknowledgement. Astra accepted the implementation.

The unfiltered `test-expert-app` run reached 908 passes, one skip, two failed
tests, and one crash. The stand-in, simulator, recorder, and cassette batch
reached 1,590 passes, 14 failed tests, and one crash. All failures reached
local bind or connect operations denied with `EPERM` by this sandbox. No U18
fixture failed before a network operation. Receipts are under `u18-work/`.

## U19: remove retired proof-review state

The fresh caller census found no remaining use of the retired proof-review
state, type, or I/O helpers. The ledger owns its `.zttp` directory creation.
The three unused helpers, their exports and test imports, the CLI force import,
and the stale module-boundary row are removed. A sentinel test compares the
literal proof JSONL row, including its newline, and confirms that an existing
`.zttp/deploy-state.json` file retains its exact bytes. Astra accepted the
source and the revised sentinel.

The named proof-review, boundary, docs, links, and runtime-purity batch passes
17 steps and 28 tests (`u19-work/named-core-v1`). The unfiltered CLI run after
the sentinel change reaches 603 passes, one skip, and three failures, all in
loopback cases denied by the sandbox (`u19-work/cli-row-v1`). `smoke-v1` also
stops when its local server cannot respond (`u19-work/cli-smoke-v1`).

## U20: documentation and measurements

The architecture, TypeScript, feature-detection, and user guides now describe
the direct parser, parser-owned syntax, and recovered workspace owner.
The current-doc census finds no reference to the deleted frontend or
proof-review helpers. `scripts/audit-docs.sh .` passes. The unfiltered
documentation, link, and spine batch passes (`u20-docs-v1`).

`smoke-getting-started` builds and initializes the app, then fails at its
`zttp dev` loopback listener with `EPERM` (`u20-smoke-v1`). The compile-bench
pilot and 50-iteration measurements pass (`u20-compile-pilot-v1` and
`u20-compile-50-v1`). All eight fixtures retain their IR-node, bytecode, and
codegen-byte counts. The 50-iteration times are lower than the U1 baseline in
this one host observation; they are not a general speed claim.

`bench-check` fails three times against the committed five-run baseline:
`intArithmetic` by 8.69%, then `stringOps` by 9.21% and 9.38%
(`u20-bench-check-v1` through `v3`). The repeated string result rules out a
single one-off threshold crossing. This advisory gate remains unresolved;
the baseline is unchanged and no release-readiness claim follows from it.

## Final local checks and limits

Astra found and Main corrected four documentation wording errors about lock
order, parser replay, receipt acknowledgement, and detection layers. The final
`test-proof-swallow`, docs-drift, doc-links, test-spine, and check-spine batch
passes (`u20-recheck-v1`). The first final aggregate found seven obsolete
proof-swallow allowlist rows after the type-consumer deletion; those rows were
removed. The unchanged `scripts/verify.sh` then reports proof-swallow OK:
16 files, 141 reviewed swallows, 87 silent arms, and zero unreviewed.

The verification script stops at its aggregate step with 8,649 of 8,681 tests
passed, six skipped, 24 failed, and two crashed (`u20-verify-v1`). Its eight
failed roots are the recorder, cassette, simulator, expert, stand-in, runtime,
server, and CLI network suites. Their failures reach local bind or connect
operations denied with `EPERM`; no remaining structural gate fails. The
standalone `test-zruntime` reaches 221 passes and ten loopback `EPERM` failures
(`u20-zruntime-v1`). The script cannot reach later steps in this sandbox.

Run separately after that stop: ReleaseFast and the verified handler
precompile both pass (`u20-release-build-v1`, `u20-handler-build-v1`). The
33-file normalization check, module-spec render check, agent determinism gate,
and policy hash comparison pass. `zig fmt --check` over `build.zig`, `build/`,
`packages/`, and `tooling/`, the docs link audit, and `git diff --check` pass.

U17, U18, and U19 have separate local main commits. U20 closes in the commit
that carries this worklog. The unrelated untracked sibling-module plan remains
untouched and excluded from every commit.

## Post-U20 verification follow-up (2026-10-17)

The sandbox still refuses a loopback `127.0.0.1` listener with `EPERM`, so the
full `scripts/verify.sh` network suites cannot pass here. The aggregate
`zig build test` at `e56636a9` reaches 8,677 of 8,709 tests passed, six
skipped, 24 failed, and two crashed. Its eight failed roots have the same
loopback-dependent failure classes as U20; no new full-script verdict is
claimed. This checkout remains local and unpushed.

Two more `bench-check` runs fail against the committed September baseline, one
on `intArithmetic` by 10.48% and one on `stringOps` by 11.59%. The built-in
timer includes parse, compile, and execution in `loadCodeNoHandler`; its
`ops_per_sec` is not an execution-only measure. The benchmark programs and
their reported interpreter and optimization counters match the baseline.

To separate source changes from host conditions, the September source commit
`e8e2c0dc` was built from a temporary `git archive` with the same Zig 0.16.0
binary as this checkout. Fifteen alternating `zig build bench -- --json --quiet`
runs per source used the same machine and the suite's per-benchmark best
aggregation. The comparison was not a new checked-in baseline:

| Benchmark | September source built today | Current source built today | Current difference |
| --- | ---: | ---: | ---: |
| `stringOps` | 19,047,619 ops/s | 18,726,591 ops/s | -1.69% |
| `propertyAccess` | 18,037,518 ops/s | 16,784,155 ops/s | -6.95% |
| `gcPressure` | 7,693,491 ops/s | 7,321,716 ops/s | -4.83% |

Every current case is within 8% of its same-host September-source result.
The September source itself reaches only 19,047,619 `stringOps` ops/s today,
7.62% below its committed 20,618,556 ops/s result. Host load was elevated
during these measurements, and the same-host differences are still noisy;
they do not establish that the remaining gaps are source regressions. The
committed `bench-check` still fails, its baseline remains unchanged, and
release readiness still requires an unsandboxed full verification run and a
quiet-host benchmark rerun or further controlled investigation.

## Loopback-enabled verification follow-up (2026-10-17)

Loopback binding now succeeds. At `727fc930`, the unchanged
`bash scripts/verify.sh` exits 0. Its aggregate suite, standalone
`test-zruntime`, ReleaseFast build, verified handler precompile, smoke flow,
panic isolation, structural gates, policy hash, and final format check all
pass. The earlier sandbox limit is closed for this checkout.

The advisory `bench-check` still fails three times against the committed
September baseline. Each invocation takes the best per benchmark from five
runs. All three stop on `propertyAccess`, at 10.16%, 9.87%, and 10.06% below
the recorded 19,700,551 ops/s. No baseline was replaced.

Fifteen further alternating runs of the archived September source and current
source on the same, less busy host narrow the source difference. Their
per-benchmark best results are 19,004,180 versus 18,168,604 ops/s for
`propertyAccess` (-4.40%), and 8,116,883 versus 7,855,459 ops/s for
`gcPressure` (-3.22%). The median-run differences are -5.82% and -6.40%,
respectively. Every current case is within 8% of the archived source's
same-host best over these 15 runs. This comparison is diagnostic, not a
passing `bench-check`: the official five-run gate remains red, and the
remaining property and allocation gaps have no established source cause.

## Property benchmark investigation (2026-10-17)

The benchmark build settings match the September source: `zttp-bench` uses
ReleaseFast in both. The engine's property access hot path has no direct source
change since that baseline. The built-in timer wraps `loadCodeNoHandler`, so
it includes parsing, code generation, and the first 50,000-iteration call.

An archived U1 reset checkpoint (`ad1aa961`) and the current source were run
in 15 alternating built-in benchmark pairs. `propertyAccess` reached
17,831,669 versus 16,914,749 ops/s by per-source best (-5.14% current).
Interpreter and optimization counters matched for all thirteen cases. This
comparison includes cold compilation and execution and does not isolate the
cause of the difference.

The runner's existing `--script --bench` mode timed an exact copy of its
`propertyAccess` function after loading, using a temporary `.ts` file outside
the repository. In 20 paired, warmed 500,000-iteration calls, the best results
were 16,879,346 for U1 and 16,919,901 ops/s for current (+0.24%). In 40
paired, unwarmed 50,000-iteration calls, the best results were 17,295,053
and 17,059,024 ops/s (-1.36%). Those runs use the typed file path rather
than the built-in virtual JavaScript path, so they are a runtime-path probe,
not a substitute for `bench-check`.

The host was saturated during this follow-up: load average reached 17.72,
`top` reported 0% CPU idle, and many independent Deno processes were active.
Run medians moved far more than the best results. The evidence does not
justify changing property access code or replacing the baseline. A new
five-run gate measurement needs an idle host before source attribution or a
release performance verdict.

## Idle-host benchmark and profile follow-up (2026-10-17)

After the Deno workload ended, `top` reported 74–86% CPU idle and the host
remained on AC power. Two consecutive official five-run `bench-check` calls
still fail against the committed September baseline, now on `intArithmetic`
by 8.83% and 9.10%. The failing case changed from `propertyAccess` without a
source edit, so the stored absolute result remains sensitive to host state.

Fifteen alternating runs of the archived September source and current HEAD
on this idle host show `intArithmetic` best at 19,623,233 versus 19,193,857
ops/s (-2.19% current). The September source itself is 5.14% below its
committed result. `propertyAccess` is 18,587,360 versus 17,531,556 ops/s
(-5.68% current), and `gcPressure` is 7,891,414 versus 7,363,770 ops/s
(-6.69% current). The same-host gap is below the gate's 8% per-case limit for
each, but the official gate still fails against its stored baseline.

A 20-pair execution-only probe through the runner's existing `--script --bench`
mode times 500,000 `propertyAccess` iterations after loading. September's
best is 19,003,458 ops/s and current's is 17,665,347 (-7.04%); both report
five million cache hits out of five million accesses. Longer 400-million
iteration calls take 22.390 seconds and 24.061 seconds, respectively, with
two billion cache hits each. Ten-second macOS samples of each binary put
their time in the same interpreter dispatch and property setter paths. They
do not isolate one changed function. The script probe uses a temporary typed
file, while the built-in case uses virtual JavaScript.

The performance gate remains unresolved. No runtime code, benchmark policy,
or baseline was changed on this evidence.

## Historical benchmark narrowing (2026-10-17)

The September 28 checkpoint (`4d18c679`) builds with the same Zig 0.16.0
toolchain. Fifteen alternating baseline/midpoint/current runs of the built-in
suite show that the best `intArithmetic` result overlaps across all three:
21,240,441, 21,222,410, and 21,141,649 ops/s. The corresponding
`propertyAccess` medians are 18,416,206, 18,057,060, and 17,253,278
ops/s; each revision's best result exceeds 18.8 million. This spread makes
a five-run absolute comparison an unstable way to attribute a source change.

The runner's execution-only `propertyAccess` probe gives a clearer trend.
Across 15 alternating triplets, September, midpoint, and current medians are
18,879,323, 18,483,605, and 17,798,661 ops/s. Fifteen idle-host pairs of
the October 15 reset checkpoint (`ad1aa961`) and current give medians of
17,963,641 and 17,901,256 ops/s, so the recent reset does not explain the
gap. All of these probes report five million inline-cache hits in five
million accesses.

To check the October 7 match-pattern series, 20 alternating execution-only
pairs used its preceding revision (`a990caf8`) and final revision
(`bdc23b06`). Their medians are 18,173,227 and 18,091,034 ops/s; their
ranges overlap. The 392 added lines in `interpreter.zig` in that series are
tests, and the 20 commits from the September 28 midpoint to the preceding
revision do not change the interpreter, object, inline-cache, context, or GC
source files. These measurements do not identify a source-level cause. The
official `bench-check` remains red; the baseline and gate policy remain as
committed.
