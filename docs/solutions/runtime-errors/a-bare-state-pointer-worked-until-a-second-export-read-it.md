---
title: A bare state pointer worked until a second export read it
date: 2026-09-24
category: runtime-errors
module: zts SDK module state (zttp:fetch, zttp:service)
problem_type: runtime_error
component: tooling
symptoms:
  - The first runtime call to fetchWithRetry crashed with a bus error; the faulting address was a heap address called as a function.
  - Every serviceCall failed with NativeFunctionError, although the system file named the service.
  - fetch from zttp:fetch worked in every test, so the shared state looked correct.
root_cause: wrong_api
resolution_type: code_fix
severity: high
tags: [zts, sdk, module-state, envelope, zttp-fetch, zttp-service, layout-coincidence, runtime-test-gap]
---

# A bare state pointer worked until a second export read it

## Problem

An SDK module (one under `packages/modules/src/`) reads its state with the
SDK's `getModuleState` (`packages/zttp-sdk/src/context.zig:21`). On the zts
side that goes through `zttpSdkGetModuleState`, which does not return the
slot's pointer: it reads the slot as an `SdkStateEnvelope` and returns the
envelope's `user_ptr` (`packages/zts/src/module_binding/bridge.zig:298-335`).
The zts installers for `zttp:fetch` and `zttp:service` stored a bare pointer
with `ctx.setModuleState` instead. The module therefore read the first word of
its own state struct as `user_ptr`, and used whatever that word pointed at as
its state.

## Symptoms

For `zttp:fetch`, the first word of `FetchState` is `runtime_ptr`, which the
installer set to the enclosing `InstalledState`. So the module read
`InstalledState` as if it were `FetchState`. The first two fields of both are a
runtime pointer and a call function of the same shape, so `fetch` called the
runtime callback directly and worked. `fetchWithRetry` also reads
`deadline_passed_fn`, and M4 T6 U3 added `refuse_fn`; at those offsets
`InstalledState` holds other data, so the first call jumped to a heap address.
For `zttp:service`, the misread state held no services, so every
`serviceCall` threw. No runtime test called either export before 2026-09-24.

## What Didn't Work

Reading the installer and the module separately showed nothing wrong: each
used a correct-looking pointer to `base`. The comment on
`installSdkModuleState` already warned against a bare pointer, but nothing
checks it. A debug print of the address the module received against the
address the installer stored showed a 24-byte difference, which is what
exposed the envelope read.

## Solution

Install the state through the envelope, as `sql.zig` and `ledger.zig` already
did (`packages/zts/src/modules/data/sql.zig:27`), and look up an existing state
through `getSdkModuleStatePtr`:

```zig
// before
ctx.setModuleState(MODULE_STATE_SLOT, @ptrCast(&installed.base), &stateDeinitAdapter);

// after
try module_binding.sdk_bridge.installSdkModuleState(ctx, MODULE_STATE_SLOT, @ptrCast(&installed.base), sdkDeinit);
```

The deinit becomes a C-ABI `fn (*anyopaque) callconv(.c) void`, and the state
keeps its own allocator because the envelope passes none. See
`packages/zts/src/modules/net/fetch.zig:75-110` and
`packages/zts/src/modules/net/service.zig:48-86`. Fixed on local main in
commits `7c443a72` (fetch) and `b82fb912` (service). The tests
`fetchWithRetry without a credential reaches the upstream once` and
`serviceCall reaches the upstream a system file names` in
`packages/runtime/src/zruntime_tests.zig` fail without the fix.

## Why This Works

The reader and the writer now agree on one layout. The coincidence could hide
the defect only because both structs start with the same two fields; any field
past them exposed it, and only an export that read such a field could fail.

## Prevention

A zts file that installs state for a module imported from `zttp-modules` must
use `sdk_bridge.installSdkModuleState`. `ctx.setModuleState` with a bare
pointer is correct only for an engine-coupled module whose reader also calls
`ctx.getModuleState` (`io`, `scope`, `durable`, `workflow` are of this kind).
A check for this is a grep, not yet a gate: a file under
`packages/zts/src/modules/` that imports `zttp-modules` and calls
`ctx.setModuleState` is suspect.

One passing export does not show that the shared state is right. When an SDK
module has several exports, give each one that reads a different state field a
runtime test through a real `HandlerInstance`, not only unit tests of its
option parsing. Both defects lived because the only runtime-tested export used
the fields that happened to line up.
