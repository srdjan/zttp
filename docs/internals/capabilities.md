# Module Capabilities

Virtual modules exposed through `zttp:*` imports run inside the handler's JavaScript context but often need to touch external resources (clock, RNG, filesystem, network). Capabilities record exactly which resources each module's Zig implementation is allowed to reach; an implementation that reaches outside its declaration panics at build time rather than silently misbehaving.

Read this end-to-end before adding a new virtual module.

## The capability enum

`ModuleCapability` is declared in [`packages/zts/src/module_authorization.zig`](../../packages/zts/src/module_authorization.zig) and re-exported through `module_binding`. Eleven variants exist today:

| Capability | Gates |
|---|---|
| `env` | Reading process environment variables (used by sandbox policy checks, not by the module's own config). |
| `clock` | Real wall-clock and monotonic time (`std.time.timestamp`, `std.time.milliTimestamp`, monotonic counters). |
| `random` | Hosted OS-seeded cryptographically secure randomness (UUID generation, nanoid, jitter). |
| `crypto` | Cryptographic primitives (HMAC, hash functions, constant-time comparison, JWT sign/verify). |
| `stderr` | Writing to the process stderr stream for diagnostic output. |
| `runtime_callback` | Invoking the host runtime back into JS (scope lifecycle hooks, durable oplog replay, I/O dispatch, service routing). |
| `sqlite` | Opening and querying the embedded SQLite connection. |
| `filesystem` | Reading files from disk outside the sandbox root (service contracts, request fixtures). |
| `network` | Making outbound network calls. |
| `policy_check` | Consulting the handler's derived `RuntimePolicy` to authorize a resource access before it happens. |
| `websocket` | Touching WebSocket gateway state and hibernated attachment state. |

These are governance metadata for the module internals. They do not affect handler-level effect classification (`deterministic`, `read_only`, etc.) or `RuntimePolicy` derivation; those are separate analyses driven by the `effect` annotation on each exported function.

## Enforcement model

Every module declares a `ModuleBinding` with three relevant fields:

```zig
.specifier = "zttp:foo",
.effect = .read,
.required_capabilities = &.{ .clock, .policy_check },
```

Two cooperating helpers in `module_binding.zig` turn the declaration into an enforcement contract:

1. **`wrapNativeFnWithCapabilities(user_fn, specifier, required_capabilities)`** is a comptime wrapper that the resolver ([`packages/zts/src/modules/internal/resolver.zig`](../../packages/zts/src/modules/internal/resolver.zig)) applies automatically to native exports whose module declares capabilities. The wrapper pushes an `ActiveModuleScope` onto the receiving `Context` before calling the user function and restores the previous scope on exit. Capability-free native exports skip the wrapper. SDK `ModuleFn` exports remain wrapped even with an empty capability list because module identity also governs state-slot access.

2. **`requireCapability(handle, capability)`** is the call-site check. Inside a module implementation, any operation that touches the guarded resource calls `requireCapability(handle, .clock)` (or the read-only sibling `hasCapability`). The opaque handle resolves to the same `Context`, and the check reads that Context's active scope. It returns `error.MissingModuleCapability` when the capability is absent. Because the wrapper is applied by the resolver, an implementation that calls a guarded helper without the declaration in its binding will panic in the build-time `test-capability-audit` pass before reaching runtime.

Each `Context` owns its authorization scope. Nested calls save and restore the previous scope with the `ActiveModuleToken` returned from `pushActiveModuleContext`, while two contexts alternating on one worker thread remain isolated. If a panic skips wrapper cleanup, the runtime quarantines that Context and `Context.deinit` clears its scope before module-state destructors run.

Modules that also need manual pushes (for example, when a helper runs before the wrapped entry point) import the binding helpers directly:

```zig
const token = mb.pushActiveModuleContext(ctx, binding.specifier, binding.required_capabilities);
defer mb.popActiveModuleContext(token);
```

Production code uses this pattern for service-state installation before the wrapped entry point. Most module calls rely on the resolver-installed wrapper.

The extension SDK and runtime bridge are revision-locked. Native extensions must rebuild against the `zttp-sdk` revision that matches their target runtime. Handle-bound crypto operations use distinct symbol names, so an extension that references either changed operation fails at link time instead of calling through an incompatible native ABI.

## Module inventory

### Modules that declare capabilities

| Specifier | Capabilities | Notes |
|---|---|---|
| `zttp:auth` | `crypto`, `clock` | JWT sign/verify, bearer parsing, timing-safe equality, HMAC webhook verification. |
| `zttp:cache` | `clock`, `policy_check` | TTL expiry requires clock; `policy_check` consults the handler's cache-namespace policy. |
| `zttp:crypto` | `crypto` | SHA256, HMAC, base64. |
| `zttp:durable` | `runtime_callback` | Replay and live execution dispatch back into the runtime for oplog replay and signal wake-ups. |
| `zttp:env` | `env`, `policy_check` | Reads `getenv` and then checks the key against the handler's env allowlist. |
| `zttp:fetch` | `network`, `runtime_callback` | Dispatches outbound HTTP through the runtime callback path after host-policy checks. |
| `zttp:id` | `clock`, `random` | UUID v7 and ULID mix clock; nanoid is pure random. |
| `zttp:io` | `runtime_callback` | `parallel()` and `race()` schedule outbound fetches through the runtime's I/O collector. |
| `zttp:log` | `clock`, `stderr` | Timestamped log emission. |
| `zttp:queue` | `runtime_callback` | Mailbox send, lease, ack, nack, and reply dispatch through the server-owned actor queue. |
| `zttp:ratelimit` | `clock` | Token bucket expiry. |
| `zttp:scope` | `runtime_callback` | Request-scoped lifecycle hooks call back into the runtime at request end. |
| `zttp:service` | `network`, `filesystem`, `runtime_callback` | Reads cross-handler service contracts from disk and dispatches via the runtime. |
| `zttp:sql` | `sqlite`, `policy_check` | SQLite connection plus query-name allowlist check. |
| `zttp:websocket` | `clock`, `runtime_callback`, `network`, `filesystem`, `policy_check`, `websocket` | Sends frames, manages rooms, and serializes hibernated attachment state through the gateway. |
| `zttp:workflow` | `runtime_callback` | `call`, `follow`, `fanout`, and `saga` dispatch to co-located sub-handlers through the runtime. |

### Modules that declare no capabilities

These modules are pure compute - string manipulation, parsing, URL encoding, structural routing, type-directed decoding - and run without a wrapper. They appear in `modules/` with a `ModuleBinding` whose `required_capabilities = &.{}` or that omits the field.

- `zttp:compose`
- `zttp:decode`
- `zttp:http`
- `zttp:router`
- `zttp:text`
- `zttp:time`
- `zttp:url`
- `zttp:validate`

The absence of a capability does not make these modules "trusted": they still go through the resolver and still respect the handler's effect classification. It means only that their implementation does not touch any resource on the guarded list.

## The build-time audit

`zig build test-capability-audit` grep-walks `packages/modules/src/` and `packages/zts/src/modules/` looking for direct references to sensitive operations (clock reads, RNG, crypto primitives, filesystem, stderr, sqlite handles) that bypass the checked helpers. A hit fails the build with the offending file and line. The audit is the broad helper-bypass tripwire - it watches every module implementation, including internal helpers.

`zig build test-module-governance` is the public built-in governance gate. It runs `zts verify-modules --builtins --strict --json` against the authoritative built-in set from `packages/zts/src/builtin_modules.zig` and fails on:

- direct forbidden effect usage
- undeclared helper-capability use
- binding/spec specifier drift
- binding/spec capability drift
- missing spec artifacts for public built-ins

Run it after any change under `modules/`:

```bash
zig build test-capability-audit
zig build test-module-governance
```

The release CI job runs both checks explicitly. Local `zig build test` also depends on `test-module-governance`.

## Adding a new module

Follow these steps, in order:

1. **Declare the `ModuleBinding`** in your new `modules/foo.zig` with `specifier`, `effect` (`.read`, `.write`, or `.none`), and `required_capabilities`. Capability list must be exact - list nothing you do not call, and list everything you do call.
2. **Wire the exports** into `modules/root.zig` so the resolver picks them up.
3. **Call guarded helpers only through `module_binding` wrappers.** If you need a direct call inside a helper function, push and pop the active scope on its Context manually (see the pattern above).
4. **Run the audits**: `zig build test-capability-audit test-module-governance` must pass.
5. **Run the full test matrix**: `zig build test test-zts test-zruntime`.
6. **Add a fixture** under `tests/validate/` and, if the module has a handler-visible surface, an example under `examples/` with a `.test.jsonl` wired into `scripts/test-examples.sh`.
7. **Update this document** with the new row in the capability table.

If the module needs a capability not yet in the enum, you are extending the governance surface itself: add the variant to `ModuleCapability`, teach the audit pass to recognize the new guarded operations, and update the table above. A new capability is a security-relevant change and should go through a CODEOWNERS review.

## Cross references

- [`packages/zts/src/module_authorization.zig`](../../packages/zts/src/module_authorization.zig) - cycle-neutral capability and active-scope vocabulary.
- [`packages/zts/src/module_binding.zig`](../../packages/zts/src/module_binding.zig) - public re-exports for wrappers, Context-owned scope, and `requireCapability`.
- [`packages/zts/src/modules/internal/resolver.zig`](../../packages/zts/src/modules/internal/resolver.zig) - where `wrapNativeFnWithCapabilities` is applied per exported function.
- [`SECURITY.md`](../../SECURITY.md) - reporting and scope.
- [`docs/verification.md`](../verification.md) - the handler-level verification pass that lives alongside capability enforcement.
