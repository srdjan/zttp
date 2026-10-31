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

## Rule detail

These sentences hold the history behind the seed rule in the root `AGENTS.md`.

`scripts/unseeded-rules.allow` once carried nineteen rows. The rows that went were closed by giving a rule a producer or by deleting a rule no execution order could surface, never by writing a seed. A row naming a code that the registry advertises and nothing constructs is a false advertisement in a hashed policy surface. `scripts/check-diagnostic-producers.sh` catches that shape, because a gate keyed on the code cannot: see [a-guard-that-every-input-satisfied-refused-the-first-new-one](../../docs/solutions/conventions/a-guard-that-every-input-satisfied-refused-the-first-new-one.md) and [a-stale-cassette-is-loud-and-an-unsatisfiable-seed-is-silent](../../docs/solutions/logic-errors/a-stale-cassette-is-loud-and-an-unsatisfiable-seed-is-silent.md).
