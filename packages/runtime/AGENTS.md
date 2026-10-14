<!-- agent-spine: area -->

# packages/runtime

This area owns the CLI, server, request isolation, artifact activation, and the bridge to the analyzer.

Runtime code reaches only approved `zts` internals. `zig build test-module-boundary` enforces this boundary.

## Invariants

- **The server refuses a static path that escapes its configured root.**
  A request must not read a file outside the configured directory. Proved by `zig build test-server`.

- **A recovered handler panic does not retain module authority for another request.**
  Each request must start with its own authorization state. Proved by `zig build test-panic-isolation`.

- **An artifact passes independent acceptance before the runtime creates its handler pool.**
  Contract parsing alone cannot authorize proof-based runtime behavior. Proved by `zig build test-server`.

## Decisions that bind here

D-004, D-005
