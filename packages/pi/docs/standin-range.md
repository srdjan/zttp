<!-- Generated file. Do not edit. Run `zig build zttp-standin -- --range > packages/pi/docs/standin-range.md` to regenerate it. -->

# Deterministic stand-in range

Range version: `step-4b-v1`

Range hash: `fdc716ea980438935d9d0d1478ba2d5847294fea4e36cc3331d7738f985e56de`

The deterministic playbook server supports the entries below. Use `zig build zttp-standin -- --range` to print this document.

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
- Result: workspace edit
- Behavior: Read the handler and its JSONL tests, then propose one complete test-file edit.
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
