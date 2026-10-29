---
name: handler-scaffold
description: Scaffold a minimal zts handler with typed request parsing and error handling.
---
Create a minimal zts handler following these conventions:
- Read nearby handlers and call `zts_expert_query` with operation `modules` before choosing imports.
- Use explicit `Request` and `Response` types and add a narrow `Proof<T, P>` when the handler mutates state or uses effects.
- Use typed request parsing only when the route needs it; otherwise keep the scaffold small.
- All errors must be returned as structured JSON responses, never thrown.
- Import only the specific zttp modules you need.
- Use `zttp:decode` for request parsing and `zttp:validate` for schema validation. Bind each Result to its own `const` and check it with `if (!r.ok)` before reading `.value`. Pass `r.value`, not `r`.
- Read a parsed request body with `decodeJson(schema, req.body ?? "")`. To read without a schema, check `isDict(v)`, then call `dictGet(v, key)` from `zttp:collections`. Never write `v.name` on the `.value` of `requestJson` or `parseJson`.
- Read a fetch response with `decodeJson` over `.text()` when its fields matter. Do not read fields from `.json()`.
- An index read `xs[0]` is `T | undefined`. Bind a possibly undefined value to a `const`, then check `=== undefined` before you read it, or use `?.` and `??`.
- Use `Response.json()` for all JSON responses, `Response.text()` for plain text.
- No classes, no async/await, no try/catch. Branch on a Result with `if (!r.ok)`, never with `match`, `=== true`, or `isOk()`.
- Run `zts_expert_verify_paths` before editing when modifying an existing file, and let the compiler veto verify the complete scaffold before apply.

Start with the minimal passing scaffold and add complexity only as needed.
