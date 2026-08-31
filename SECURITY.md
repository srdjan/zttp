# Security Policy

## Supported Versions

Only the latest tagged release and `main` receive security fixes. Release candidates (`-rcN`) are supported until the corresponding final release ships.

## Reporting a Vulnerability

Report suspected vulnerabilities privately via GitHub Security Advisories:

https://github.com/srdjan/zigttp/security/advisories/new

Do not open public issues for security reports. After triage you will receive a remediation plan or a rationale for closing the report.

Include, where possible:

- Affected version (tag, commit, or binary hash)
- Minimal reproducer (handler source, CLI flags, request)
- Observed vs. expected behavior
- Impact assessment (panic, isolation bypass, data exposure, etc.)

## Scope

In scope: the runtime (`packages/runtime/`), the zts engine and virtual modules (`packages/zts/`), the build-time tooling (`packages/tools/`), and the `zttp deploy` client path.

Out of scope: the hosted control plane itself (`api.zttp.dev`), which has its own reporting channel, and third-party extensions built with `zttp-sdk`.

## Threat Model Summary

The high-level boundaries enforced by zttp:

1. **Handler isolation.** Each request acquires a `Runtime` instance from a pool. The runtime derives proof-authoritative reuse only from properties that an accepted certificate cleared under consumer policy. Without that promotion, pooling stays bounded by request count. Arena-escape and string-table audits run on every release; failures are logged via the runtime metrics (`arena_audit_failures`, `persistent_escape_failures`).

2. **Capability boundary.** Virtual modules declare `required_capabilities` in their `ModuleBinding`. The set is aggregated into the handler's contract and used by deployment policy to refuse mounts that exceed the granted surface. Each capability is also enforced at module call time: every guarded operation in `packages/zts/src/module_binding.zig` routes through `requireCapability` (returning `error.MissingModuleCapability`) or its panicking `*Checked` siblings, so a module that touches `clock`, `crypto`, `random`, `stderr`, `env`, `sqlite`, `filesystem`, `network`, `runtime_callback`, or `policy_check` without declaring it is stopped before the resource is reached. The `policy_check` capability is itself the gate through which the handler's derived `RuntimePolicy` authorizes a resource access (cache namespace, env key, SQL query/write). See [docs/internals/capabilities.md](docs/internals/capabilities.md) for the full enforcement map.

3. **HTTP boundary.** Headers reject CRLF and NUL bytes before allocation (commit `6e65bb7`, `packages/runtime/src/http_types.zig`). Body size defaults to 1 MiB and is rejected with 413 on overflow. Static-file paths reject traversal (`..`), absolute paths, drive letters, and NUL bytes (`isPathSafe`); a second-line canonical-realpath check (`isCanonicalPathInsideRoot`) catches symlink escapes.

4. **Attestation trust model.** The JWS protected header carries the full Ed25519 public key. `zttp verify <url>` validates the signature against that embedded key and prints the key fingerprint. This proves "the holder of this key signed these claims" - not "this key belongs to a specific publisher." The well-known attestation document exposes the same claims for inspection; it does not establish publisher identity by itself. Third-party verifiers that care about identity should pin keys with `--trust-key <hex>` or apply an explicit trusted-origin policy.

5. **Self-extracting binary integrity and acceptance.** The 32-byte trailer's CRC-32 is a corruption check, not a security check. The JWS signs the bytecode, contract, rule-policy, capability, serialized runtime-policy, and executable-graph identities. The graph includes dependency bytecode, nested functions, constant pools, source and semantic identities, proof IR, and a cycle-safe digest of every authority-bearing certificate section. Startup reconstructs that graph and runs the independent proof checker before it creates the handler pool. A valid signature alone cannot authorize execution. See [docs/internals/architecture.md - Deploy Artifact](docs/internals/architecture.md#deploy-artifact).

6. **Bytecode integrity.** Only bytecode that passes `packages/zts/src/bytecode_verifier.zig` is dispatched into the VM. The verifier validates opcodes, operand bounds, the constant pool, stack discipline, and jump targets before the first instruction executes. Untrusted bytecode (e.g. a tampered self-extracting payload) is rejected before bytecode execution.

7. **No runtime multipart parser.** `multipart/form-data` request bodies are passed to the handler unparsed. Handlers must parse boundaries themselves and reject malformed inputs; the runtime guarantees only `Content-Length` and total-body-size enforcement (default 1 MiB). Treat handler-side multipart parsing as untrusted-input handling.

## Related Documents

- [docs/threat-model.md](docs/threat-model.md) - public runtime and tooling threat model
- [docs/verification.md](docs/verification.md) - compile-time verification invariants
- [docs/internals/capabilities.md](docs/internals/capabilities.md) - capability enforcement map
- [packages/zts/src/module_binding.zig](packages/zts/src/module_binding.zig) - capability enforcement surface
