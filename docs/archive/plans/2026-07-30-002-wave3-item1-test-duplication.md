# Wave 3 item 1: the test duplication was already gone

**Status:** done. No refactor was needed; the item's premise no longer held.

**Source:** wave 3 item 1 of `docs/plans/2026-07-28-001-reset-simplification-plan.md`:
"Stop double-executing the zruntime and server suites. `main.zig:10-18` imports both
`zruntime.zig` and `server.zig` into the aggregate test root while standalone roots run the
same tests again."

**Gate from the plan:** standard, plus identical collected-test counts before and after.

**Ground truth:** measured at commit `0898e713` on 2026-07-30.

## 1. What was measured

| Measurement | Value |
| --- | --- |
| `zig build test` collected tests | 4,095 across 16 test binaries |
| Of which, the aggregate runtime root (`main.zig`) | 521 |
| `zig build test-zruntime` collected tests | 494 |
| Effect of deleting `_ = @import("zruntime.zig")` from main.zig's test block | zero: 521 before, 521 after, sum 4,095 both ways |
| Positive control: adding one test to main.zig | 521 to 522, so the instrument detects a single-test change |

The positive control matters. Without it, "the count did not move" is indistinguishable from
"the measurement did not work".

## 2. Why the premise no longer held

Two separate reasons, one per suite named in the item.

**The server half was never true.** The standalone step roots at
`packages/runtime/src/server_test.zig` (`packages/runtime/build.zig:113-114`), a different
file from the `server.zig` that main.zig imports. Two files, two disjoint sets of tests, no
duplication.

**The zruntime half was fixed earlier and documented.** `zruntime_test_step` is not wired
into `test_step`, and `build.zig:774-778` already records why: parallel duplicate roots have
produced intermittent libc/JIT/arena teardown TRAPs on macOS. So `zig build test` runs that
root zero times, not twice.

What remained was not duplication but a misleading import, and the reason is precise.
`zruntime.zig` is the root of its own build module (`packages/runtime/build.zig:100-101`). It
was the ONLY entry in main.zig's test block that is also a module root: cross-checking every
`b.path("src/*.zig")` module root against that block gives `benchmark.zig`, `cli_main.zig`,
`compile_benchmark.zig`, `main.zig`, `server_test.zig`, and `zruntime.zig`, and of the block's
seven imports only `zruntime.zig` appears there. A file import of another module's root
collects none of its tests, which is exactly what the measurement shows.

## 3. What changed

Nothing executable. Two statements that were false were corrected:

- `packages/runtime/src/main.zig` dropped `_ = @import("zruntime.zig")`. It read as test
  coverage and delivered none. Compile coverage is unaffected because `edge_server.zig`, two
  lines below, imports `zruntime.zig` anyway.
- `build.zig:709-710` claimed the main.zig root "covers runtime_cli, zruntime, server,
  proof_adapter, cli_shared". The zruntime part was false. The comment now lists what the
  root actually covers and says where that root does run.

## 4. The finding worth keeping

An import that looks like test coverage and provides none is worse than a missing import,
because it stops anyone from asking the question. The same shape appeared twice in this
session already: `module_facts.zig`'s tests silently did not run until `root.zig` referenced
it, and B3 found 84 exports whose data a count-only tripwire reported as healthy. Three
instances in one session of a check that reads as covering more than it does.

The general rule: whenever a build file asserts what a test root covers, that assertion is
worth measuring once, with a positive control, because nothing enforces it.

## 5. Verification

- `zig build test` collects 4,095 tests before and after, same per-binary multiset.
- `zig build test-zruntime` exits 0 and still collects 494.
- `bash scripts/verify.sh` exits 0.
- `zig fmt --check build.zig packages` is clean.
