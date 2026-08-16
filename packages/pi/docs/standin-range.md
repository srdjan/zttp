<!-- Generated file. Do not edit. Run `zig build zttp-standin -- --range > packages/pi/docs/standin-range.md` to regenerate it. -->

# Deterministic stand-in range

Range version: `step-6-v2`

Range hash: `4073fceb29543e5d8956e747ff2cef9d33b7938c51af0d8b584e49ed40361046`

The deterministic playbook server supports the entries below. Use `zig build zttp-standin -- --range` to print this document.

This server is a scripted responder, not a model. Its drafts and defect seeds are authored by repo code to produce declared outcomes through the same veto and repair loop, so it can show that the harness runs correctly and can say nothing about what a model would draft. Convergence numbers come from recorded model turns only; see `docs/convergence.md`.

## `explain`

- Task kind: `review_explain`
- Result: text answer
- Behavior: Use live module facts and return a concise text explanation. Do not edit a file.
- Canonical prompt: Explain how Response.json works
- Example paraphrases:
  - Explain the Response.json helper
  - What does Response.json return?

## `review`

- Task kind: `review_explain`
- Result: text answer
- Behavior: Read the handler and return a concise text review. Do not edit a file.
- Canonical prompt: Review handler.ts for correctness and compiler compliance
- Example paraphrases:
  - Review handler.ts for compiler compliance
  - How does handler.ts handle errors?

## `add-route`

- Task kind: `route_add`
- Result: workspace edit
- Behavior: Read the handler, inspect module facts, and propose one complete route edit.
- Canonical prompt: Create a handler in handler.ts that responds to GET /health with Response.json({ ok: true }).
- Example paraphrases:
  - Create a GET /health route
  - Add route POST /users to handler.ts

## `add-env`

- Task kind: `env_feature`
- Result: workspace edit
- Behavior: Read the handler, inspect zttp:env, and propose one complete configuration edit.
- Canonical prompt: Add the APP_NAME environment variable to handler.ts
- Example paraphrases:
  - Add the APP_NAME environment variable
  - Read configuration with zttp:env

## `write-test`

- Task kind: `test_generation`
- Result: unsupported test-file write
- Behavior: Read the handler and its JSONL tests, then refuse the write because the aggregate transaction accepts only source files.
- Canonical prompt: Write test case for the successful health response
- Example paraphrases:
  - Add test coverage for the successful health response
  - Add a jsonl test case for the health handler

## `fix`

- Task kind: `violation_fix`
- Result: workspace edit
- Behavior: Inspect the violation and repair facts, then propose one complete handler edit.
- Canonical prompt: Fix the ZTS300 compiler error in handler.ts
- Example paraphrases:
  - Fix the ZTS300 compiler error
  - Repair this handler's compiler error

## `fill-hole`

- Task kind: `hole_fill`
- Result: workspace edit
- Behavior: Read the compiler's typed-hole frame, fill one site through `zts_expert_fill_hole`, and apply what the tool returns.
- Canonical prompt: Fill the remaining hole in handler.ts
- Example paraphrases:
  - Fill the hole on line 3 of handler.ts
  - Replace the hole() in handler.ts with an expression

## Reserved task kinds

These kinds stay outside the range on purpose. They are what the negative corpus and the out-of-range grammars assert an absence against, so covering one would delete its own gate.

- `unknown`
- `handler_scaffold`
- `spec_goal`
- `workflow_authoring`
- `sql_feature`
- `auth_jwt`

## Defect seeds

Drafts the stand-in emits expecting the veto to reject them, so the rejection half of the loop is reachable with no live model. Each seed declares what the loop does with its bad draft; the declaration is re-derived by running the real veto, never trusted.

| Seed | Code | Outcome |
|---|---|---|
| `let-binding` | `ZTS604` | salvaged |
| `compound-assign` | `ZTS613` | salvaged |
| `var-binding` | `ZTS001` | model_retry |
| `dead-code` | `ZTS304` | model_retry |
| `unchecked-result` | `ZTS303` | compiler_repair |
| `unchecked-optional` | `ZTS308` | compiler_repair |

## Hole seeds

Skeletons whose response expressions are holes. The arm reads the file, publishes the frame through the real in-process `zts_expert_query` holes operation, fills one site through `zts_expert_fill_hole`, and applies what the tool returns. Multi-hole seeds repeat that sequence on the next turn, so each accepted proposal becomes the next frame's baseline.

| Seed | Holes |
|---|---|
| `single-hole` | 1 |
| `two-holes` | 2 |
