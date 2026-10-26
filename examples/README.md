# Examples

The examples demonstrate ordinary TypeScript handlers and retained virtual modules.
Each adjacent `.test.jsonl` file contains requests and expected responses for `zttp test`.
`scripts/test-examples.sh` checks runtime responses and the advertised static checks.

## Start here

[handler/spec-guardrails.ts](handler/spec-guardrails.ts) declares four proof properties on its return type.
The compiler checks determinism, idempotence, secret leakage, and injection safety.
A call to `Date.now()` prevents the determinism proof.

[handler/handler.ts](handler/handler.ts) shows routes and an explicit `Proof<T, P>` declaration.
[handler/secret-leak.ts](handler/secret-leak.ts) deliberately returns a secret and demonstrates the ZTS400 refusal.

## Handler groups

`handler/` contains proof declarations, effect budgets, local imports, and runtime language probes.
[handler/handler-with-imports.ts](handler/handler-with-imports.ts) imports local helper files.
[handler/sugar.ts](handler/sugar.ts) shows callbacks, array operations, and `Object.keys`.
[handler/effects-capsule.ts](handler/effects-capsule.ts) demonstrates effect budgets and diagnostics ZTS610 and ZTS623.
[handler/spec-fails-idempotent.ts](handler/spec-fails-idempotent.ts) deliberately fails its declared idempotence proof.

`routing/` contains branching, pattern matching, and early-return guards.
`modules/` contains handlers that use several virtual modules. `modules-all/` holds `modules_all.ts`, an integration example that imports `zttp:auth`, `zttp:validate`, and `zttp:cache`.
The `zttp.json` files in `modules/`, `routing/`, and `patterns/` name a `policy.json`. Its `env.public` list names the env values that handlers in that directory may return; every other literal env name is secret to the flow analysis.
`fetch/` contains outbound HTTP examples that require explicit allowed hosts.
[fetch/webhook.ts](fetch/webhook.ts) forwards a POST request through `zttp:fetch`.

`patterns/` maps TypeScript patterns to the supported language described in [the TypeScript guide](../docs/typescript.md).
`sql/` contains a tagged SQL query handler and its schema.
`autoloop/` contains a deliberately failing handler for agent repair.
The autoloop example is illustrative and does not enter the example gate.

## Run an example

```bash
zig build run -- examples/handler/spec-guardrails.ts -p 3000
zig build cli -- serve examples/handler/spec-guardrails.ts -p 3000 --watch --prove
zts check examples/handler/spec-guardrails.ts
zttp test examples/handler/handler-ts.test.jsonl
```

`zttp check` runs the strict analyzer.
Without an explicit `Proof<T, P>`, the analyzer requires all seventeen default specification names.
A handler that calls a virtual module does not hold `pure`, so it declares a narrow capsule.
`zttp test` and `zttp deploy` refuse the same handlers that `zttp check` refuses.
The example gate checks the runtime responses and runs `zttp check` on each handler.
Seven files are outside the `zttp check` loop. `utils.ts` is a helper module and `sql-crud.ts` has its own check with a schema. `feature-probes.ts`, `secret-leak.ts`, `spec-fails-idempotent.ts`, and `autoloop/handler.ts` exist to show a refusal or a refused form. The `modules_all.ts` example returns a signed token that the flow analysis labels secret.
Pattern and SQL examples also run their advertised static checks.

The JSONL runner substitutes virtual-module I/O and creates a fresh runtime for each request.
The runner proves only the responses covered by the adjacent assertions.
Unsupported language diagnostics include the restriction, its reason, and a supported alternative.
`zts restrictions` lists the complete restrictions.
