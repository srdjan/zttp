<!-- agent-spine: area -->

# packages/pi

This area owns the expert loop, provider adapters, deterministic stand-in, veto, transcripts, and change receipts.

The area reaches `zts` through approved module surfaces. `zig build test-module-boundary` enforces this boundary.

## Invariants

- **The expert loop simulates a proposed edit before it writes the edit.**
  A failed veto must not produce a verified change receipt. Proved by `zig build test-expert-app`.

- **The stand-in recovers a complete source baseline or refuses the edit.**
  An absent baseline must not become an empty file. Proved by `zig build test-standin`.

- **Every enabled stand-in guard family has rejecting and property-preserving evidence.**
  The gate must observe each declared veto class. Proved by `zig build test-standin`.

## Decisions that bind here

D-002, D-003
