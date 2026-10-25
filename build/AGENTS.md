<!-- agent-spine: area -->

# build

This area owns the root Zig build graph, package wiring, named tasks, and aggregate task reach.

Build modules may compose repository packages. No import boundary applies because this area defines the dependency graph.

## Invariants

- **Every build task has a route in `agents.json`, and a task that nothing runs states why.**
  An unreachable task can appear healthy while no aggregate runs it. `check-spine` holds each route against the live graph. Proved by `zig build check-spine`.

- **The live build graph supplies one completed task census to the spine checker.**
  Source spelling must not become a second task authority. Proved by `zig build check-spine`.

## Decisions that bind here

D-001, D-005
