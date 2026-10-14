<!-- agent-spine: area -->

# packages/proof-checker

This area owns the consumer acceptance kernel. The kernel decides whether a deployment artifact may serve.

The kernel imports only `std` and sibling files. `zig build test-proof-checker-purity` enforces this boundary.

## Invariants

- **The acceptance kernel remains a leaf and its test suite remains nonempty.**
  The kernel cannot depend on producer authority or ambient capabilities. Proved by `zig build test-proof-checker-purity`.

- **Kernel safety checks remain active under a ReleaseFast root.**
  Untrusted certificate data must cause a refusal or a checked panic. Proved by `zig build test-kernel-safety`.

## Decisions that bind here

D-005
