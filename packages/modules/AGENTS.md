<!-- agent-spine: area -->

# packages/modules

This area owns native implementations and binding metadata for each `zttp:` virtual module.

The area imports the SDK contract. No import boundary applies because no current gate enforces a stricter package boundary.

## Invariants

- **A persistent-read export declares unknown provenance in its return labels.**
  Cache and SQL reads return data from separate writes. Proved by `zig build test-zts`.

## Decisions that bind here

D-007

D-013 permits one shared store: the `zttp:ratelimit` `RateStore`. A handler pool owns it and every access holds its mutex. It holds no JS value.
