# Native stack limit for script recursion

Status: approved plan, revision 2, 2026-11-14, at commit `2fa69e89`. A Fable
review and a Codex astra review checked revision 1. This revision resolves
their findings. The owner chose option (a) of D7 on 2026-11-14: write a plan,
with a reproduction test, to limit recursion depth in the interpreter. The
owner answered "yes, approved" on 2026-11-14: option (a) of D8 and D9. That
authorizes U1 to U4 on local `main`, with no push, no paid model call, and no
re-record.
Source: U4 of [Expert result card and test run](2026-11-14-expert-result-card-plan.md).

## Goal

A handler with deep or unbounded recursion ends with `CallStackOverflow` in
every build mode. Under `zttp serve`, that request gets status 500, and the
server answers the next request. No build mode ends the process on a signal.

## Findings

These are observations from 2026-11-14 on macOS aarch64, one run each, unless
a line says otherwise.

1. The default proof profile refuses a recursive handler with ZTS500, because
   recursion loses `cost_bounded` and `fault_covered`. The crash needs an
   author who returns a narrow `Proof` capsule that leaves those properties
   out, for example `Proof<Response, "state_isolated">`.
2. The interpreter limits script calls to `call_stack_size` frames, 1024 by
   default (`packages/zts/src/context.zig#ContextConfig`).
   `Context.pushFrame` returns `CallStackOverflow` at the limit.
   `packages/zts/src/interpreter/frame.zig#callBytecodeFunction` calls it.
3. Every script call reaches `callBytecodeFunction`. A handler call enters
   through `HandlerInstance.callFunction`
   (`packages/runtime/src/handler_instance.zig#HandlerInstance`). A script
   call inside the handler, including a tail call, enters through `doCall`. A
   callback from a native function such as `map` enters through
   `invokeCallback`, `callFunctionWrapper`, and `callFunction`.
   `frame.run` runs module top-level code at load time only. The first
   revision of this plan put the stack base in `frame.run`, which was wrong.
4. Each script call is also a native call: `callBytecodeFunction` calls
   `Interpreter.dispatch`, which calls `callBytecodeFunction` again. Nothing
   compares 1024 frames with the size of the native stack.
5. Results by build mode:

   | Build | `zttp test`, direct recursion | `zttp test`, recursion through `map` | `zttp serve`, unbounded recursion |
   | --- | --- | --- | --- |
   | Debug | depth 190 passes; depth 195 ends on a signal, exit 134 | not measured | SIGBUS on a connection worker; the server process ends |
   | ReleaseSafe | depth 1000 passes; depth 1023 gives `CallStackOverflow` | `CallStackOverflow` between 300 and 600 levels | status 500 twice; the server stays up |
   | `-Doptimize=fast` | same as ReleaseSafe | `CallStackOverflow` | status 500 twice; the server stays up |

6. Native stack for one script frame, from the stack pointer over 100 frames
   in `lldb` (Fable probe): Debug 85,424 bytes, ReleaseSafe 4,000 bytes,
   `-Doptimize=fast` 3,920 bytes. The `map` path costs about the same for
   each script frame, with two script frames for each level. 1024 frames
   therefore need about 87.5 MiB in Debug and about 4.0 MiB in
   `-Doptimize=fast`.
7. The thread stacks are 16 MiB. `zttp test` runs the handler on the main
   thread, and both binaries set `LC_MAIN stacksize 16777216` (`otool -l`).
   Connection workers use the default `std.Thread` stack of 16 MiB
   (`packages/runtime/src/server_connection_pool.zig`). This is why a run with
   `ulimit -s 2048` changed nothing. Linux is not measured: there, the main
   thread stack probably follows `ulimit -s`.
8. A bounded native function can recurse below the last script call. With
   script recursion at depth 185, a leaf `JSON.stringify` of an array nested
   500 deep ends Debug on a signal. With nesting 5, the same depth passes.
   One `writeJson` level costs about 2.7 KB in Debug, an inference from one
   trace. The JSON writer stops at depth 512, so its worst case is about
   1.4 MiB. `renderNode` and the JSON parser are not measured. `requestJson`
   on a body nested 5000 deep did not crash at depth 180 in Debug.
9. The server maps the error to status 500 through `HandlerError`. Through a
   native callback, `CallStackOverflow` first becomes `NativeFunctionError`,
   and the status is still 500.
10. Debug is the mode of `zig build`, `zig build test`, and `zig build run`.
    Release archives use `zig build -Doptimize=fast` (`scripts/release.sh`).
    On macOS aarch64, a release build has about four times the stack that
    1024 frames need. The crash therefore reaches developers and test suites
    today, not users of a macOS release archive. A larger `dispatch` frame
    could remove that margin without a test failing.
11. `zttp test` stops the whole run on a handler error. It prints
    `error: Handler execution failed: error.CallStackOverflow`, exits 1, and
    prints no `Results:` line. This plan does not change that.

## Decision D8: the mechanism

- (a) A stack floor for each thread, checked at each script call.
  Recommended. At the outermost script entry of a call, the interpreter reads
  the bounds of the current thread's stack and stores a floor address: the low
  end of the stack plus a headroom. The outermost entry is `frame.run`, or
  `callBytecodeFunction` when `state_depth` is 0. A nested entry, such as a
  `map` callback, keeps the floor. Each `callBytecodeFunction` compares
  `@frameAddress()` with the floor and returns `CallStackOverflow` below it.
  The headroom covers the deepest bounded native leaf, which U1 measures, plus
  a margin. macOS gives the bounds through `pthread_get_stackaddr_np` and
  `pthread_get_stacksize_np`, and Linux through `pthread_getattr_np`. Other
  targets set no floor and keep today's behavior. After the fix, Debug refuses
  recursion at roughly 170 frames, an estimate from findings 6 to 8. Release
  builds still stop at 1024 frames first. The two limits therefore differ by
  a factor of about 6.
  A constant budget from a recorded base would need no thread call. It would
  have to assume the smallest stack, and the Linux main thread is not
  measured, so this plan does not use it.
- (b) Run each handler on a thread whose stack fits 1024 Debug frames. That
  needs about 90 MiB for each thread, plus the leaf headroom. It moves the
  limit and does not check it.
- (c) Make script calls use no native recursion. This removes the defect
  class, but it is the largest change. It works against the single-switch
  design of `Interpreter.dispatch`, and the performance risk is not measured.
- (d) Set `call_stack_size` to 128 in Debug. 128 frames need about 10.9 MiB,
  which fits a 16 MiB stack with the JSON leaf. It needs no address check. It
  fails on a smaller stack, such as a Linux main thread with an 8 MiB limit,
  and it does not protect a release build against frame growth.

## Units, if D8 is (a)

Each unit gets its own commit on local `main`. No unit pushes, calls a paid
model, or re-records the corpus. Sonnet implements U1 to U3. Opus reviews each
diff and runs each acceptance check again with an empty `ZIG_LOCAL_CACHE_DIR`.

### U1: Reproduction tests and leaf measurement

- Model: Sonnet. Turn budget: 35.
- Tests first. Each runs `zttp` as a child process, so that a crash fails one
  test and not the runner. `scripts/smoke-v1.sh` (`zig build smoke-v1`) and
  `scripts/test-panic-isolation.sh` (`zig build test-panic-isolation`) already
  start `zttp test` and `zttp serve` as children.
  1. `zttp test` on an unbounded recursive handler with a narrow capsule
     prints `CallStackOverflow` and exits 1, with no signal.
  2. `zttp serve` on the same handler gives status 500 to one request, and
     answers a second request.
  3. `zttp test` on script recursion at depth 180 with a leaf
     `JSON.stringify` of an array nested 500 deep ends with no signal.
- Run the three tests on Debug before any fix. Confirm that each fails
  because the child ends on a signal, exit 134. Record that in the commit
  message.
- Measure, with a probe that is not committed: the Debug stack cost of
  `renderNode` at its depth limit and of the JSON parser at its depth limit.
- Acceptance: the three tests exist and fail on Debug for the reason above.
  The two leaf measurements are in the commit message.
- Result, commit `6030aac7`: the three checks are in
  `scripts/test-panic-isolation.sh`. Opus ran `zig build test-panic-isolation`
  again with an empty cache. The existing panic checks passed. Each of the
  three new checks failed: both `zttp test` runs ended with exit 134, and the
  server process ended before it answered `/deep`. Debug estimates, one probe
  each: `renderToString` at its limit costs 0.85 MB to 1.03 MB, and
  `JSON.parse` at its limit costs 0.43 MB to 0.60 MB. Without a leaf, depth 192
  passes and depth 193 crashes.

### U2: The stack floor

- Model: Sonnet. Turn budget: 45.
- Files: `packages/zts/src/interpreter/frame.zig`,
  `packages/zts/src/context.zig`, one stack-bounds function for macOS and
  Linux, and the tests beside them.
- Change: the check from D8 (a). The headroom constant states the measured
  leaf that sets it. The error stays `CallStackOverflow`, so no caller changes.
- Change: the card test "the card says zttp test ended on a signal when the
  candidate crashes it" in `packages/pi/src/repl.zig` loses its crash. It
  changes to the `CallStackOverflow` line and a matching name. A second test
  keeps the signal line: its `zttp` binary is a two-line shell script that
  ends itself on SIGABRT. The test states that no real crash source remains.
- Acceptance: the U1 tests pass. A test shows that Debug passes recursion at
  depth 100 and refuses unbounded recursion with `CallStackOverflow`.
  Unfiltered `zig build test`, `zig build test-zruntime`,
  `zig build test-cli`, `zig build smoke-v1`, and
  `zig build test-panic-isolation` pass. A fixture that recursed between the
  new Debug limit and depth 190 would fail one of these steps.
  `zig build bench-check` passes, with the host load stated beside the result.

### U3: Changelog

- Model: Sonnet. Turn budget: 10.
- File: `CHANGELOG.md`, `[Unreleased]`, under "Fixed". The entry says that the
  crash affected Debug builds, and that macOS release archives already
  returned status 500.
- The website does not change, because a macOS release archive does not show
  the defect.

### U4: Closing validation

- Owner of the work: Opus.
- A Fable subagent and Codex astra review the diff of U1 and U2 with split
  briefs.
- Mutants, each run against the unfiltered step:
  - remove the floor check;
  - set the headroom to zero;
  - store the floor on every call, so that a callback resets it;
  - store the floor once at module load, so that a request on another thread
    uses a stale floor.
  Each mutant must fail a test.
- Final gate: `env -u DEEPSEEK_API_KEY bash scripts/verify.sh`.

## Out of scope

The `zttp test` behavior of finding 11, a recursion limit in the proof, signal
recovery in the server, a Linux measurement, and targets other than macOS and
Linux.

## Decision D9: execution

- (a) Run U1 to U4 on local `main` with one commit for each unit, no push, no
  paid model call, and no re-record. Recommended.
- (b) Stop after this plan.
