<!-- agent-spine: area -->

# packages/zts

This area owns parsing, analysis, bytecode, proof facts, and the interpreter for the restricted TypeScript profile.

Each tier imports only lower tiers. `zig build test-zts-layering` enforces the tier boundary.

## Invariants

- **Flow analysis enters routed functions and module-level data declarations.**
  An unvisited root can make a leak appear clean. Proved by `zig build test-zts`.

- **A persistent read carries unknown provenance unless a stronger binding rule applies.**
  Current call arguments do not identify data from a separate write. Proved by `zig build test-zts`.

- **A literal `env` name is secret unless the policy lists it in `env.public`.**
  The name's spelling vouches for nothing, a computed name keeps the declared
  label, and a command that reads no policy keeps every name secret. Proved by
  `zig build test-zts`.

## Decisions that bind here

D-004, D-006, D-007, D-014
