# Pruning round 3 worklog

Plan: [round 3 plan](2026-10-23-pruning-round-3-plan.md). List: [round 3 list](2026-10-23-pruning-round-3-list.md).

## Baseline

At `1fcb0734`, `zig build test` with a private cache exited 1: 9,550 of 9,556 tests passed, 6 skipped. The failed step ran `zig-out/bin/zttp` and got `FileNotFound` while the install step rewrote it. `zig build test-expert-golden` alone exited 0.

## Round 3a

| Unit | Commit | Gates and exit statuses | Notes |
|---|---|---|---|
| U0 | this commit | `test-expert-golden` 0, `test` 0, `zig fmt --check` 0 | `build/goldens.zig` now runs `getEmittedBin()` through a file argument in all five run sites. Zig 0.17 resolves an artifact argument to `installed_path` first (`lib/compiler/Maker/Step/Run.zig`, `.artifact` arm); a file argument resolves to the generated path. The race is not reproduced on demand; the evidence is the source read and one failed baseline. The `run` and `cli` steps in `build/artifacts.zig` keep `addRunArtifact`, because a user invokes them on purpose. |
