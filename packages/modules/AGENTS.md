<!-- agent-spine: area -->

# packages/modules

This area owns native implementations and binding metadata for each `zttp:` virtual module.

The area imports the SDK contract. No import boundary applies because no current gate enforces a stricter package boundary.

## Invariants

- **A persistent-read export declares unknown provenance in its return labels.**
  Cache and SQL reads return data from separate writes. Proved by `zig build test-zts`.

- **Module state allocates through `sdk.getStateAllocator`.**
  `sdk.getAllocator` memory lives until the request ends, and a pooled runtime frees none of it before then. A store, a registry, or a cache that lives across requests, and every value it owns, must use the state allocator or the allocator that the store captured from it. Proved by `zig build test-server`.

## Decisions that bind here

D-007

D-013 permits one shared store: the `zttp:ratelimit` `RateStore`. A handler pool owns it and every access holds its mutex. It holds no JS value.

## Rule detail

These sentences hold the reasons behind the persistent-read rule in the root `AGENTS.md`.

A persistent read hands back a value some separate write put there, and the read call holds no reference to that value, so no dataflow rule can reach it and only the binding knows. `derives_from_args` cannot close that finding: `argDerivedLabels` unions only the current call's own arguments, which for `cacheGet("ns", "k")` are two string literals. `derives_from_args` is the right answer for a pass-through, where the return *is* an argument; the retired `returns_from_param` binding field is no longer part of the API. Expect `.unknown` to move a verdict from PROVEN to unproven rather than to refused; an export deriving its result from the limiter's or the generator's own state, like `rateCheck` or `uuid`, is not this shape.

No export changes a JavaScript argument in place: `dictSet` in `packages/zts/src/dict.zig` returns a copy. The flow evaluator relies on this rule. It records no write to persistent state for a native export call, so that `dictGet(TABLE, key)` on a module table stays read-only. No gate checks the rule. An export that must change an argument in place needs a persistent-write event in `packages/zts/src/flow_interp.zig` first, or a handler that passes it a module array keeps `state_isolated`.
