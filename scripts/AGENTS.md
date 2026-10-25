<!-- agent-spine: area -->

# scripts

This area owns repository shell gates, allowlists, regeneration commands, and the canonical verification script.

No import boundary applies. `zig build test-script-reachability` checks that each script has an execution route or manual declaration.

## Invariants

- **Every tracked script is invoked by repository automation or declared manual.**
  An orphaned gate can keep its name while checking nothing. Proved by `zig build test-script-reachability`.

## Decisions that bind here

D-001
