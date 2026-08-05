---
title: Ambient module authority crossed ZTS Contexts
date: 2026-08-05
category: security-issues
module: packages/zts native module authorization
problem_type: security_issue
component: authentication
symptoms:
  - "Two ZTS Contexts on one thread could observe the same active native-module authority"
  - "Module state-slot checks followed ambient module identity instead of the ModuleHandle's Context"
  - "A recovered panic could skip scope restoration and leave the failed Context's authorization dirty"
root_cause: thread_violation
resolution_type: code_fix
severity: high
related_components:
  - zttp-sdk
  - native-module-bridges
  - runtime-panic-recovery
tags:
  - native-module-authorization
  - context-isolation
  - ambient-authority
  - thread-local
  - panic-recovery
  - module-handle
  - extension-abi
applies_when:
  - "Dynamic authority governs resources owned by a specific execution object"
  - "Several execution contexts can alternate or nest on one worker thread"
  - "Non-local recovery can skip ordinary defer-based restoration"
---

# Ambient module authority crossed ZTS Contexts

## Problem

Before this fix, native-module authorization lived in a thread-local slot even
though the capability policy and module state it governed belonged to a ZTS
`Context`. `hasCapability` and `requireCapability` accepted a `ModuleHandle` but
ignored it, so the last scope installed on the thread decided what every handle
could do.

That made thread identity a proxy for object authority. Alternating Contexts
could observe the wrong capability set or module identity, and a recovered panic
could skip the wrapper defer that restored the thread-local scope.

## Symptoms

- Installing different scopes on two Contexts made both handles follow one
  ambient scope instead of their own owner.
- State-slot authorization used the ambient module specifier, so a handle did
  not determine which Context and module identity governed the access.
- Nested calls happened to be safe only while every scope change followed one
  global LIFO order on the thread.
- `setjmp`/`longjmp` panic recovery skipped wrapper defers, leaving no reliable
  restoration point inside the failed call stack.

## What Didn't Work

- Deleting the state channel was not valid. Capability checks and state-slot
  checks still consumed live module identity and authority.
- Relying only on wrapper `defer` cleanup covered normal returns and Zig errors,
  but not the runtime's non-local panic recovery.
- Passing a handle to bridge functions without deriving every authorization
  decision from it left ambient authority in the trust boundary.
- Checking only that a panic was recovered could pass without proving that the
  intended inner scope was dirty before quarantine or clear during teardown.

## Solution

The authorization scope moved onto the object whose resources it governs.
`Context` now owns an optional `ActiveModuleScope`, initialized to `null`:

```zig
active_module_scope: ?module_authorization.ActiveModuleScope,
```

Capability and module-state checks resolve the opaque handle back to that same
Context. Missing scope denies access. Restoration tokens carry both the owner
and its previous value:

```zig
pub const ActiveModuleToken = struct {
    context: *Context,
    previous: ?ActiveModuleScope,
};

pub fn popActiveModuleContext(token: ActiveModuleToken) void {
    token.context.active_module_scope = token.previous;
}
```

Both native wrappers and SDK adapters push the receiving Context's scope,
invoke the module, and restore through the owner-bound token. Independent
Contexts can therefore restore in a non-global-LIFO order without disturbing
one another. See `packages/zts/src/module_binding/capabilities.zig:62-148` and
`packages/zts/src/module_binding_adapter.zig:196-218`.

Every bridge authorization also follows the handle. The crypto bridge converts
its handle to a Context before calling the guarded implementation, while SDK
module-state reads and writes verify slot ownership against the same handle
before accessing that Context. See
`packages/zts/src/module_binding/bridge.zig:260-325`.

Panic recovery has a separate cleanup contract. The failed Context is
quarantined instead of reused, and `Context.deinit` clears its active scope
before any module-state destructor runs. The dedicated panic probe performs a
real inner `@panic`, proves the outer Context retains only its own authority,
asserts that the failed inner Context still holds the exact skipped scope, then
deinitializes it and checks from a destructor callback that authority was
already revoked. See
`packages/runtime/src/module_scope_panic_probe.zig:32-112`.

Making crypto bridge calls handle-bound changed their native ABI. The SDK and
runtime now use the distinct symbols `zttpSdkSha256WithHandle` and
`zttpSdkHmacSha256WithHandle`, and generated extension guidance requires a
rebuild against the target runtime revision. An extension built against the
previous SDK that references either changed crypto symbol now fails at link
time instead of calling through an incompatible signature.

## Why This Works

The same Context now owns the capability policy, module state, and active module
identity used to authorize them. A handle can observe only its owner's scope,
regardless of other work on the thread.

Owner-bound restoration composes locally. Reentrant calls restore each caller's
scope, error returns restore the outer scope, and unrelated Contexts do not
share a stack. If non-local recovery skips restoration, quarantine destroys the
dirty owner and revokes authority before teardown can call module or extension
cleanup code.

The panic probe is non-vacuous because it observes all three distinct states:
outer authority preserved during recovery, the failed inner scope still dirty
after the skipped defer, and the failed scope cleared before destructor
callbacks.

## Prevention

- Store live dynamic authority on the object that owns the governed resources.
- Require opaque bridge handles to identify both the authorization owner and
  the state owner. Never fall back to ambient authority.
- Make restoration tokens carry their owner, not only a previous value.
- Test alternating owners in an order that is deliberately not globally LIFO.
- Test reentrant success, error unwinding, and non-local panic recovery as
  separate lifecycle paths.
- Before asserting panic cleanup, prove the exact dirty state that cleanup is
  supposed to remove.
- Revoke authority before teardown invokes destructors, finalizers, or plugin
  callbacks.
- Rename native symbols when their ABI shape changes, and document the rebuild
  contract for extensions.

Run the focused coverage with:

```sh
zig build test-zts
zig build test-module-scope-panic
zig build test-panic-isolation
zig build test-sdk test-cli
```

## Related Issues

- [Remove orphaned thread-local state without replacing it](../architecture-patterns/remove-orphaned-thread-local-state.md) covers the complementary dead-state case. Delete an unconsumed channel; relocate a live one behind its real owner.
- [Difference is not the claim, and a probe that does not compile is not a probe](../conventions/difference-is-not-the-claim-and-a-probe-must-compile.md) explains why the panic probe asserts the exact dirty and clean states.
- [A gate that counts nothing still reports a pass](../conventions/a-gate-that-counts-nothing-still-reports-a-pass.md) explains why the dedicated executable is wired into the broader panic gate.
- [Module capabilities](../../internals/capabilities.md) is the canonical description of the current enforcement model.
- [Test steps](../../internals/testing.md) maps the standalone panic coverage into the full verification gate.
