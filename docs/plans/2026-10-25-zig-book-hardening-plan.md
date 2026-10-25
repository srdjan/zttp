# Zig book hardening plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Apply the patterns from `/Users/srdjans/Code/zig-book` that close confirmed safety defects in ZTTP, and establish the measurement that any speed change needs first.

**Architecture:** Each task fixes one defect class at its shared root, with a regression test that fails before the fix. Hostile-input regressions that kill a process go into the existing process-level gate `packages/tools/src/cli_abuse_check.zig`. Analyzer errors that no code maps reach the user through one mapping at the `zts` CLI edge. The speed work starts with a request-path benchmark, and no runtime default changes until that benchmark has a number.

**Tech Stack:** Zig 0.17.0, the existing `zig build` graph, `std.testing`.

**Spec:** This file. The sources are the book (chapters 3, 5, 6, 7, 8, and 11), three read-only audits run on 2026-10-25, a Fable reasoning review, and a Codex astra fact-check. The audits ran against `a517da4c` plus 8 uncommitted owner files. The probe inputs were under `/tmp/zttp-audit/`. They are not committed, so each task's first step reproduces its defect.

## How the book maps to ZTTP

ZTTP already applies most of the book. The plan does not propose these again:
- The struct-of-arrays IR, with an `extra` side array and unconditional size locks (`parser/ir.zig`).
- Sentinel indices, reserve-then-fill for the IR, and the flat type pool with `(start, count)` children.
- Comptime `StaticStringMap` predefined atoms.
- The NaN-boxed 8-byte `JSValue` and labeled-switch dispatch.
- The per-request bump arena, the `retain_capacity` connection arena, preallocated stacks, and the bounded runtime pool.
- 0.17 API names and `SafeAllocator`.
- 97 `checkAllAllocationFailures` calls.
- Parser depth limits: 512 for programs and types, and 64 for the expression profile.
- Per-function `@setRuntimeSafety(true)` in the proof-checker kernel, enforced by `zig build test-kernel-safety`.

The book rules that ZTTP breaks in places are these four:
- Ch. 8, "Limits on everything": a recursive pass over input needs a depth bound that returns an error.
- Ch. 8, "Build modes": a checked cast is not input validation in `fast` mode.
- Ch. 3, "When the error is memory" and "Rules": never swallow an error and continue with a made-up value.
- Ch. 3, "Fatal errors at the edge": the process should exit only in `main`.

Release binaries build with `-Doptimize=fast` (`scripts/release.sh`). Outside the proof-checker kernel, a shipped binary has no runtime safety checks.

## Defects

"Confirmed" means a probe ran or the code was read with the effect traced. "Probable" means the next named check must confirm it.

| ID | Defect | Status and evidence | Effect in the shipped `fast` build |
|---|---|---|---|
| F1 | `flow_interp.zig` `runActivation`: the `activations` stack has no depth bound | Confirmed by an audit probe: a chain of 250 functions, `gi(x){ return g(i-1)(x); }`, crashed `zts check` | SIGSEGV, exit 139. `zttp dev`, `zttp test`, and `zttp build` run the same analysis |
| F2 | `http.zig` `renderNode`, `:745` `renderRawChildren`, and `:411` `appendChild` have no depth bound | Confirmed by an audit probe: `v = [v]` 200000 times, then `renderToString(v)` | `zttp test` dies on SIGSEGV. Death of a live server is probable, not probed |
| F3 | `parser/codegen.zig` casts the jump offset with `@intCast` to `i16` | Confirmed by reading. An audit probe used an `if` body with 11000 or more statements | Undefined behavior. The bytecode verifier refused it in the audit's probes. A silent miscompile is probable |
| F4 | Type-pool nodes grow quadratically with the length of an addition chain or alias chain | Confirmed by an audit probe at 360 terms: n(n+1)/2 reaches 65536 at n=361 | A raw `TypePoolCapacityExceeded` escapes `main`. A wrong ZTS200 appears at 2500 aliases (probe). Time is quadratic |
| F5 | `dev_cli.zig` compares `err == error.CheckFailed`, but `doctorCommand` cannot return that error | Confirmed by a compiler membership probe | Dead branch with no runtime effect today |
| F6 | `init_command.zig` calls `std.process.exit` on `ScaffoldTargetExists`, and tests call that function | Confirmed by reading | A test for that path would kill the test runner |
| F8 | `builtins/helpers.zig` `invokeCallback` discards every callback error (`catch return null`), and `arrayMap` (`array.zig`) uses `undefined` in its place. There are 16 call sites in `array.zig`, `result.zig`, `collections.zig`, and `helpers.zig` | Confirmed by reading. An audit probe saw callback recursion "pass" depth 2000, above `call_stack_size` 1024 | A call-stack overflow, out-of-memory, or deadline error inside a callback gives `undefined` elements, and the handler continues and returns a result |
| P1 | `type_pool.zig` truncates each name to 255 bytes | Probable. A probe test confirms it | Two field names with the same first 255 bytes may compare equal |
| P3 | `security/validate.zig` `compileSchemaFromJson` has no depth bound. `coerceValue` (`:813,827`) recurses to the schema depth | Probable. A probe test confirms it | Stack overflow on a deeply nested schema |

Two audit claims were withdrawn after the review:
- **F7 withdrawn.** The longest guard summary is 148 bytes, so the 256-byte buffer cannot cut it short (`guard_report.zig`).
- **P2 withdrawn.** Callback re-entry already pushes frames (`frame.zig`). F8 is the real cause.

## Global Constraints

- Zig 0.17.0. No new dependency. No Python (AGENTS.md).
- Work on local `main`. Do not touch the 8 files that the owner has modified: `zts_agent_client.zig`, `proof-checker/src/checker.zig`, `runtime/src/server.zig`, `runtime/src/test_runner.zig`, `agent_protocol.zig`, `proof_checker_mutants.zon`, `proof_ir.zig`, `trace.zig`.
- Every new depth bound returns an error or a fail-closed verdict in every build mode. Do not use an `assert` for it.
- No new diagnostic code and no new flow verdict reason. Reuse an existing error, reason, or code.
- Do not add a `catch` in a file that `scripts/check-proof-swallow.sh` lists. Map errors at the CLI edge instead.
- Run each gate with a private `ZIG_LOCAL_CACHE_DIR`. Redirect the output to a file and read the exit status directly, not through `| tail`.
- Before any task is complete, `zig build test` and `zig build check-spine` pass. Before the final report, `bash scripts/verify.sh` passes.
- Unset `DEEPSEEK_API_KEY` for every gate run.

## Review Focus

1. **Accepted programs.** A depth bound below real handler depth turns PROVEN into unproven. Task 1 must show no verdict change in `test-flow-census`, `test-diagnostic-corpus`, and `test-standin`.
2. **Native stack, not only the logical depth.** One activation can hold up to 512 levels of expression nesting. Task 1 probes nested call sites as well as flat chains.
3. **Debug frames are larger than `fast` frames.** Each bound test runs at the bound in Debug.
4. **The verifier is the last line of defense.** After Task 2, a refused jump comes from codegen, not from the verifier.
5. **JSON mode.** Each new `cli_abuse_check` case runs in text mode and with `--json`. Stdout must be empty or exactly one JSON document.

---

### Task 1: Bound the flow interpreter's activation depth (F1)

**Files:**
- Modify: `packages/zts/src/flow_interp.zig` (`runActivation` at line 3937, and the `Owner`/reason doc at line 867)
- Modify: `packages/tools/src/cli_abuse_check.zig` (`Input`, `cases`, input writer)

**Interfaces:**
- Produces: `const max_activation_depth: usize = 64;`. At that depth, `runActivation` runs `try self.record(func_node, tag, .budget_limit);` and then `return error.BudgetExhausted;`, the same as `tick` at line 2517. The doc for `budget_limit` becomes "the root analysis reached `max_steps` or the activation depth limit".

- [ ] **Step 1: Write the failing tests** in `flow_interp.zig`:
  - `test "a call chain past the activation limit records budget_limit"`: a chain of 2000 functions called from the handler. Assert that the analysis returns, with `budget_limit` in its unresolved records.
  - `test "a 32-function call chain keeps its verdict"`: assert the verdict that the current code gives.
- [ ] **Step 2:** Run `zig build test-zts`. Expected: the test runner dies on a signal at the 2000-function test.
- [ ] **Step 3:** Implement the interfaces block.
- [ ] **Step 4: Native-stack probe.** Generate 60 functions of the form `g_i(x){ return [[[ ... g_{i-1}(x) ... ]]]; }`, with 400 bracket levels each. Run `zts check` on the file in Debug and in a `-Doptimize=fast` build. If either build dies on a signal, add one native depth counter. `eval`, `exec`, and `runActivation` share it, and it uses the same record-then-`BudgetExhausted` exit. Size it from the deepest passing Debug depth divided by 2, and add the probe as a test.
- [ ] **Step 5:** Run `zig build test-zts`, `zig build test-flow-census`, `zig build test-diagnostic-corpus`, and `zig build test-standin`. Expected: all pass, with no verdict or golden change. If a corpus verdict changes, stop and report the handler and its call depth.
- [ ] **Step 6:** Add `Input.call_chain` (the 2000-function file) to `cli_abuse_check.zig`, with one text case and one JSON case. Set `exit_code` to the code that the fixed build returns. An unproven property alone does not exit 1 (`zts_cli.zig`). Run `zig build test-cli-abuse`. Expected: PASS. Revert Step 3, confirm that the case fails on a signal, and then restore it.
- [ ] **Step 7:** Commit with the message `bound flow interpreter activation depth`.

### Task 2: Range-check source-sized narrowing in codegen, and map unmapped errors at the CLI edge (F3, F4 edge)

**Files:**
- Modify: `packages/zts/src/parser/codegen.zig` (`resolveJumps` at line 2443, and each other site that Step 3 finds)
- Modify: `packages/zts/src/tests/frontend_fuzz.zig` (the closed error list that begins at line 475)
- Modify: `packages/tools/src/zts_cli.zig` (the edge where analyzer errors become output and exit codes)

**Interfaces:**
- Produces: `error.JumpTooFar` from `CodeGen.generate`.
- Produces: at the `zts` CLI edge, an analyzer error that no code maps becomes one ZTS000 diagnostic whose message carries `@errorName(err)`. It goes through the same writer as the existing ZTS000 at `zts_cli.zig`, in text and JSON mode, with exit code 1. `error.OutOfMemory` is not mapped, and it propagates unchanged.

- [ ] **Step 1: Write the failing test.** Add `test "a jump past the i16 range is refused in codegen"`. Parse a source with an `if` body of 15000 statements of `y = y + 1;`, and assert `error.JumpTooFar` from `generate`. The existing `TooManyConstants` test at line 2674 builds IR directly. This test parses source.
- [ ] **Step 2:** Run `zig build test-zts`. Expected: FAIL with the panic "integer does not fit in destination type".
- [ ] **Step 3:** Replace the cast with `std.math.cast(i16, wide) orelse return error.JumpTooFar`. List every other `@intCast` in `codegen.zig` whose operand grows with the source: code length, local count, argument count, and label count. Convert each one to `std.math.cast(...) orelse return error.<...>`. Name each site that you leave unchanged, with its invariant, in the commit message. Add `JumpTooFar` to the closed list in `frontend_fuzz.zig`.
- [ ] **Step 4: Write the edge test** in `zts_cli.zig`: `test "an unmapped analyzer error is one ZTS000 diagnostic"`. Inject an error that no code maps through the existing test seam that the ZTS000 tests at lines 740-749 use. Assert one complete JSON document with `"code":"ZTS000"` and the error name, and exit code 1. Implement the mapping.
- [ ] **Step 5:** Run `zig build test-zts`, `zig build test-zts-cli`, `zig build test-cli`, and `zig build test-cli-abuse`. Expected: PASS.
- [ ] **Step 6:** Commit the codegen change and the edge mapping separately.

### Task 3: Bound HTML rendering depth (F2)

**Files:**
- Modify: `packages/zts/src/http.zig` (`renderNode`, `renderRawChildren`, and `appendChild`)

**Interfaces:**
- Produces: `const RENDER_MAX_DEPTH: u32 = 512;`. `RenderError` gains `RenderDepthExceeded`. Each of the three functions takes `depth: u32` and checks it the same way as `writeJsonDepth` at line 867. The public entry points pass 0.

- [ ] **Step 1: Write the failing tests.** Add `test "renderToString refuses nesting past the render limit"`. Build a nested array 600 levels deep in a test `Context`, following the existing tests in `http.zig`, and assert `error.RenderDepthExceeded`. Add a depth-511 test that renders in Debug. Add the same pair for `h()` children through `appendChild`.
- [ ] **Step 2:** Run `zig build test-zts`. Expected: the depth-600 tests fail.
- [ ] **Step 3:** Thread `depth` through the three functions.
- [ ] **Step 4:** Run `zig build test-zts`, `zig build test-examples`, and `zig build test-server`. Expected: PASS. If the depth-511 test overflows in Debug, set the limit to the deepest passing depth divided by 2, and record the measurement in the comment.
- [ ] **Step 5:** Commit with the message `bound html render recursion depth`.

### Task 4: Propagate callback errors from higher-order builtins (F8)

**Files:**
- Modify: `packages/zts/src/builtins/helpers.zig`, `builtins/array.zig`, `builtins/result.zig`, and `modules/data/collections.zig` (the 16 `invokeCallback` call sites)

**Interfaces:**
- Produces: `pub fn invokeCallback(ctx, call_fn, func_obj, call_args) !value.JSValue`, which returns the callback's error unchanged. Each caller becomes `anyerror!value.JSValue`, which matches `object.NativeFn` (`object.zig`), and uses `try`.

- [ ] **Step 1: Write the failing tests**, following the existing tests that run source through a `Context`:
  - `test "an error inside a map callback fails the call"`: a `map` callback that recurses past `call_stack_size`. Assert `error.CallStackOverflow` from the handler call, not an array of `undefined`.
  - The same assertion for `filter` and `reduce`.
- [ ] **Step 2:** Run `zig build test-zts`. Expected: FAIL. The call returns a value.
- [ ] **Step 3:** Change `invokeCallback` and its 16 callers as the interfaces block states. Where a caller also discards an allocation error (for example `arrayPush ... catch return undefined` at `array.zig`), propagate it in the same edit.
- [ ] **Step 4:** Run `zig build test-zts`, `zig build test-zruntime`, `zig build test-examples`, and `zig build test-server`. Expected: PASS. A handler that relied on `undefined` from a failing callback now fails. Report each such handler before you change it.
- [ ] **Step 5:** Commit with the message `propagate callback errors from higher-order builtins`.

### Task 5: Make type-pool growth linear in chain length (F4)

This task is a diagnosis task, and the root cause is not known. Use the `ce-debug` skill.

**Files:**
- Investigate: `packages/zts/src/type_checker.zig`, `type_env.zig`, and `type_pool.zig`
- Modify: the root-cause site
- Modify: `packages/tools/src/cli_abuse_check.zig`

- [ ] **Step 1: Reproduce.** Write two tests:
  - `test "a 511-term addition chain type-checks"`: 511 terms is under the parser's chain limit of 512 (`parse.zig`). Also assert that the pool node count is at most `c * n`, with `c` taken from Step 2.
  - `test "a 2500-alias chain reports no ZTS200"`.

  Expected today: the first test fails with `TypePoolCapacityExceeded`, and the second reports ZTS200.
- [ ] **Step 2: Measure.** Count pool nodes at 100, 200, and 300 terms. Find the call that adds nodes for each prefix. Write the root cause into the worklog before you edit code.
- [ ] **Step 3:** Fix the root cause once, at the shared site. Do not add a `catch` to `type_checker.zig`: it is listed in `check-proof-swallow.sh`. Task 2's CLI edge mapping covers any exhaustion that is still reachable.
- [ ] **Step 4:** Run `zig build test-zts`, `zig build test-diagnostic-corpus`, `zig build test-contract-golden`, `zig build test-standin`, and `zig build test-proof-swallow`. Expected: PASS. Explain any golden change in the commit message.
- [ ] **Step 5:** Add `Input.add_chain` (511 terms) to `cli_abuse_check.zig`, with the exit code of a clean check. Run `zig build test-cli-abuse`.
- [ ] **Step 6:** Commit with the message `linear type pool growth on long chains`.

### Task 6: Probe and close P1 and P3

**Files:**
- Modify only when a probe confirms the defect: `packages/zts/src/type_pool.zig` (P1) and `packages/modules/src/security/validate.zig` (P3)

- [ ] **Step 1:** Write the probe tests:
  - `test "field names that differ after byte 255 are distinct types"` (P1)
  - `test "schema nesting past 512 is refused"` (P3). P3's bound also bounds `coerceValue`.
- [ ] **Step 2:** Run them with `zig build test-zts` and `zig build test-modules`. A passing probe stays as a regression test. Record "not a defect" in the worklog.
- [ ] **Step 3:** If a probe fails, apply its fix:
  - P1: return the existing `TypePoolCapacityExceeded` through `failName` for a name longer than 255 bytes, so that the check fails closed.
  - P3: add a `depth` parameter to `compileSchemaFromJson` with a limit of 512, the same as `json_mod`.
- [ ] **Step 4:** Rerun the two steps. Expected: PASS. Commit each confirmed fix separately.

### Task 7: Fuzz the analysis stages with deep shapes

**Files:**
- Modify: `packages/zts/src/tests/frontend_fuzz.zig`

- [ ] **Step 1:** Add generators for call chains, flat binary chains, long `if` bodies, and alias chains. A `Smith` value sets each size, inside the existing 4096-byte input cap.
- [ ] **Step 2:** For each input that the parser accepts, run type checking and flow analysis. The oracle: a result, or an error from the closed list that Task 2 extended, and every diagnostic span lies inside the source.
- [ ] **Step 3:** Run `zig build test-zts`. Expected: PASS. This task has no revert check. The 4096-byte cap allows about 136 chained functions, which is under the Debug crash depth.
- [ ] **Step 4:** Commit with the message `fuzz analysis stages with deep shapes`.

### Task 8: Errors at the edge (F5, F6)

**Files:**
- Modify: `packages/runtime/src/dev_cli.zig` and `:132`
- Modify: `packages/runtime/src/init_command.zig`

- [ ] **Step 1:** In `dev_cli.zig`, replace the `err == ... or` chain at line 228 with a `switch` on `err` that omits `CheckFailed`. The compiler now checks each name against the set. Run `zig build test-cli`. Expected: PASS. Commit with the message `remove dead CheckFailed branch in doctor`.
- [ ] **Step 2: Write the failing test** `test "init into an existing target returns ScaffoldTargetExists"`. Call `initCommand` on a temporary directory that already holds the target. Today this test kills the runner.
- [ ] **Step 3:** Return the error. `reportScaffoldConflict` (`init_command.zig`) still prints the message, and the caller at `dev_cli.zig` exits 1. The message and the exit code do not change.
- [ ] **Step 4:** Run `zig build test-cli` and `zig build smoke-v1`. Expected: PASS. Commit with the message `return scaffold conflict instead of exiting`.

### Task 9: Request-path benchmark and a 0.17 baseline

**Files:**
- Modify: `packages/runtime/bench/benchmark.zig` (a new request-path section behind `zig build bench`)
- Modify: `benchmarks/perf-baseline.json`

**Interfaces:**
- Produces: a `request_path` section. It drives `HandlerPool.executeHandler` (`runtime_pool.zig`) with `examples/handler/handler.ts` for 1024 requests at the default count-bounded policy, which recycles each slot after 64 requests. It reports p50 and p99 nanoseconds per request, the p99 of recycle requests on their own, and allocator calls per request.

- [ ] **Step 1:** Add the section. Before it reports any number, it asserts a floor: 1024 requests completed and at least 16 recycles observed.
- [ ] **Step 2:** Run `uptime` and continue only when the load average is below 4. Run `zig build bench-check -Doptimize=fast` against the committed baseline, which was recorded on 0.16.0, and record each delta in the worklog.
- [ ] **Step 3:** Run `zig build bench -Doptimize=fast` three times, and record the runs and the machine in the worklog.
- [ ] **Step 4:** Re-record `benchmarks/perf-baseline.json` on 0.17.0. State the Step 2 deltas in the commit message, so that the new baseline is not compared only with itself.
- [ ] **Step 5:** Commit with the message `request-path benchmark and 0.17 baseline`.

## Decision for the owner

**Decision 1: reuse slot buffers on recycle.**

Today a recycled slot frees its core runtime, and the replacement allocates it again. The arena is 1 MiB (`runtime_config.zig`), the value stack is 1 MiB (`context.zig`), and the core allocation is in `pool.zig`. Reuse would apply the book's "static allocation after init" pattern, and it is a probable p99 gain. It also touches request isolation.
- 1a (recommended, chosen by the owner on 2026-10-25): decide after Task 9 reports the p99 of recycle requests.
- 1b: drop the item now.

## Deferred, with reasons

- **Error-compare gate.** There are 146 compares on 123 lines, and one dead branch. Converting the typed compares would edit 3 of the owner's modified files. Task 8 fixes the dead branch with a `switch`.
- **Rename the deprecated `ArrayListUnmanaged` alias (342 sites).** In 0.17 it is the same type as `std.ArrayList`, so the rename changes no behavior.
- **Atom table `string_bytes` layout (ch. 7).** It saves memory only. The default policy recycles a slot at 64 requests, which bounds the atom count.
- **5-byte tokens and lazy IR locations (ch. 6).** The parser keeps only the current token, and codegen needs line and column for each node (`codegen.zig`). Measured handlers have 16 to 214 IR nodes.
- **Analysis memory attribution.** `wide_lists` reached an 18.2 MB check peak in one audit run. Attribution is research to do first, not a plan task.
- **The other 110 `std.process.exit` calls outside `main`.** Process tests such as `cli_abuse_check` already reach them. A change there gives in-process testability only.
- **Named error sets on 999 public functions.** No confirmed defect, and a large diff.
- **`Io.Group` per-file fan-out (ch. 10).** Multi-file analysis exists, but no benchmark shows that it is slow.
- **A `JSObject` size lock.** No code depends on its size.
- **Coverage-guided fuzzing.** The build does not run `--fuzz` (`frontend_fuzz.zig`).

## Order of work

1. Tasks 1, 2, and 3 first, because they close inputs that kill a process.
2. Task 4, because it closes silent wrong results.
3. Task 5, which is open-ended.
4. Task 6, then Task 7, which needs Tasks 1 to 5.
5. Tasks 8 and 9 are independent and can run at any point.

Task 9 must finish before Decision 1.
