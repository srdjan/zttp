---
title: Remove orphaned thread-local state without replacing it
date: 2026-08-05
category: architecture-patterns
module: packages/zts interpreter and packages/runtime workflow dispatch
problem_type: architecture_pattern
component: development_workflow
severity: medium
applies_when:
  - "A deleted feature leaves a thread-local or global state channel behind"
  - "Every remaining write only clears, saves, or restores the same empty value"
  - "Panic recovery contains cleanup for state that no live path establishes"
tags:
  - thread-local
  - ownership
  - feature-removal
  - panic-recovery
  - workflow-dispatch
  - e2e-testing
---

# Remove orphaned thread-local state without replacing it

## Context

Removing a feature does not always remove the state channel that supported it. In this case, deleting the JIT removed the productive users of `current_interpreter`, but left a public thread-local declaration in the interpreter and defensive code around nested workflow dispatch. Before this cleanup, the remaining sites only saved, restored, or cleared an empty value. The code looked like runtime ownership even though no live path established that ownership.

Panic recovery made the residue look necessary. A nested handler panic uses `longjmp`, so defers in the skipped handler frames do not run. The recovery boundary therefore deserves special scrutiny, but that does not make cleanup for already-dead state useful.

## Guidance

Treat an orphaned state channel as a removal problem, not as a request for a better global.

First, prove the channel has no productive writer or reader. Search assignments as well as references, then use history to identify the feature that originally owned it:

```sh
rg -n 'current_interpreter' packages scripts
git log -S'current_interpreter' -- packages/zts/src/interpreter.zig packages/runtime
```

A set of save, clear, and restore operations is not evidence that a value is live. Trace at least one non-empty value from establishment to consumption. If no such path exists, the cleanup code preserves ceremony rather than behavior.

Second, characterize the safety-sensitive path before removal. For nested panic recovery, the test must prove all of these observations in one run:

- the child reaches the real isolated panic boundary
- the dispatch error contains the exact `HandlerPanicked` detail rather than an arbitrary failure
- the outer handler continues and returns the expected response
- a later request succeeds through the rebuilt child slot
- a single-slot pool is used, so recovery cannot pass by selecting an untouched slot

The repository E2E encodes those observations in `scripts/test-panic-isolation.sh:133-165`. The exact server-log assertion at line 152 proves the injected child panic reached the guarded boundary. The response assertion at lines 146-149 proves the outer interpreter continued with a `WorkflowDispatchFailed` response whose detail is `HandlerPanicked`. `--pool 1` at line 137 binds the recovery request to the quarantined and rebuilt slot.

Third, delete the declaration and every null-preservation site in the same reviewable change. Do not introduce a context field, parameter, or replacement thread-local unless a remaining consumer requires a value. In this case, nested workflow dispatch stays a direct call:

```zig
const dispatch_result = registry.dispatch(name, view);
```

The actual panic state remains where it is owned. `packages/runtime/src/panic_recovery.zig:50-93` keeps a per-thread stack of address-taken recovery frames for nested guarded calls. On panic, it restores the enclosing frame before jumping. `packages/runtime/src/runtime_pool.zig:791-806` then treats only the address-taken frame as valid on the panic branch and returns `error.HandlerPanicked`; the pool's quarantine path recycles the failed runtime.

Finally, accept the secondary tightening the deletion exposes. Removing the interpreter import from runtime made the `runtime interpreter` entry in `scripts/module-boundary.allow` unused. The boundary gate correctly required deletion of that stale permission.

## Why This Matters

An orphaned global is not harmless documentation. It advertises ownership that no subsystem has, encourages new code to depend on a dead channel, and adds failure-path cleanup where the safe set of operations is deliberately small. Around `setjmp` and `longjmp`, every unnecessary recovery action also expands the surface that must be reasoned about after ordinary stack unwinding has been skipped.

Deletion makes the runtime model more accurate. Nested panic state belongs to the recovery-frame stack, interpreter state belongs to the interpreter object passed through normal calls, and failed handler instances belong to the pool's quarantine and recycle path. No replacement channel is needed when no value crosses those boundaries.

The E2E details matter just as much as the deletion. Checking only status 599 can pass on an unrelated dispatch failure, and checking recovery with a multi-slot pool can pass through a slot that never panicked. Exact error identity plus a single-slot pool turns a green result into evidence for the intended causal chain.

## When to Apply

- After deleting a feature that owned process-global or thread-local state.
- When all remaining references to a state channel are cleanup or preservation code.
- Before replacing a global with context plumbing solely because the global exists.
- When a failure-path test can accidentally pass through a different error or resource instance.

Do not apply this pattern when a live path still establishes and consumes the value. In that case, rederive the correct owner and lifetime first, then move the state behind that owner with tests for nested and alternating contexts.

## Examples

The misleading shape preserves a value without demonstrating that it can be non-empty:

```zig
const saved_interpreter = interpreter.current_interpreter;
defer interpreter.current_interpreter = saved_interpreter;
interpreter.current_interpreter = null;
```

The correct result for an unwritten and unread channel is no state operation at all:

```zig
const dispatch_result = registry.dispatch(name, view);
```

The verification sequence is structural and behavioral:

```sh
test -z "$(rg -n 'current_interpreter|clearThreadStateAfterPanic' packages scripts)"
zig build test-panic-isolation -j1 --summary all
zig build test-module-boundary -j1 --summary all
bash scripts/verify.sh
```

## Related

- [Ambient module authority crossed ZTS Contexts](../security-issues/ambient-module-authority-crossed-zts-contexts.md) covers the live-state counterpart: derive the real owner, move authority behind it, and test alternating and panic-skipped lifetimes.
- [A gate that counts nothing still reports a pass](../conventions/a-gate-that-counts-nothing-still-reports-a-pass.md) explains why a green gate needs a non-vacuous input.
- [Difference is not the claim, and a probe that does not compile is not a probe](../conventions/difference-is-not-the-claim-and-a-probe-must-compile.md) explains why an assertion must identify the exact path it claims to test.
- [`docs/internals/testing.md`](../../internals/testing.md) maps the repository's build and verification gates.
