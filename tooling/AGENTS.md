<!-- agent-spine: area -->

# tooling

This area owns native repository gates, measurements, evidence generation, and agent-spine navigation.

Build modules select the dependencies for each native tool. No import boundary applies because no current gate checks this directory.

## Invariants

- **The repository gate and `zts` graph gate have native behavior tests.**
  Their source scans need executable rejection evidence. Proved by `zig build test-native-gates`.

- **The `zts` graph gate checks the module boundary and the kernel leaf, and each check asserts a floor on its own input.**
  An empty scan must fail. Proved by `zig build test-native-gates`.

- **The agent spine rejects incomplete tasks, stale bindings, and invalid evidence links.**
  The checker must fail before it updates generated root blocks. Proved by `zig build test-spine`.

## Decisions that bind here

D-001, D-005
