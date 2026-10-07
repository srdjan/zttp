# Contributing

How to build, how to test, and the conventions a PR must respect before merge. For agent-facing conventions and repo automation guidance, see [AGENTS.md](AGENTS.md) and [CLAUDE.md](CLAUDE.md).

## Prerequisites

Use Zig `0.16.0` stable. The full verifier also requires Python 3, `jq`, Z3,
and ripgrep. Ripgrep is part of the recorded expert output, so its in-process
fallback does not produce the same cassette bytes. The semantics gate requires
Z3 unless you set `ZTTP_Z3=off` to skip the SMT checks explicitly. A run with
that setting does not verify the SMT soundness boundary.

## Build

```bash
zig build                              # debug
zig build -Doptimize=ReleaseFast       # release
zig build -Dhandler=handler.ts         # precompile a handler
```

## Test

```bash
bash scripts/verify.sh                 # the full gate; CI runs exactly this
zig build test                         # aggregate suite, including examples
zig build test-zts                     # engine only
zig build test-zruntime                # runtime only, a standalone root
bash scripts/test-examples.sh          # optional focused example check
zig build bench                        # Zig-native microbenchmarks
```

`zig build test` leaves out the standalone runtime root, the smoke and
panic-isolation steps, and shell-driven registry gates. It includes the
end-to-end example handlers. `scripts/verify.sh` runs the full sequence, and
`ci.yml` uses it as the authoritative test command. A PR that passed only
`zig build test` can still fail CI.
[Test Steps](docs/internals/testing.md) maps which step runs what.

Run the relevant focused step while you work. Run `scripts/verify.sh` before
you open a PR. You can run `scripts/test-examples.sh` by itself when you debug
handler-facing behavior, but you do not need to run it after `zig build test`.
If you touched the compile-time checkers or the rule registry, also run:

```bash
zig build release
./zig-out/bin/zts describe-rule --hash   # must match policy-hash.txt
```

Larger benchmarks live in the sibling repo `../zttp-bench`; do not add benchmark scripts here.

## Adding a virtual module

SDK-pure virtual modules live in `packages/modules/src/`; engine-coupled ones live in `packages/zts/src/modules/`. `packages/zts/src/builtin_modules.zig` maps every specifier to its implementation. Each module must:

1. Declare a `pub const binding = ModuleBinding{...}` next to its implementation file, with explicit `required_capabilities` (clock, crypto, random, stderr, sqlite, filesystem, network, env, runtime_callback, policy_check). The type and the enforcement helpers live in `packages/zts/src/module_binding.zig`.
2. Enter and leave the active-module context via the shared helpers in `module_binding.zig`; the `test-capability-audit` build step enforces this.
3. Annotate each exported function with its effect class (read / write / none) so contract extraction can derive handler properties.
4. Ship fixtures under `tests/validate/` or an example under `examples/` covering both success and failure paths.

## Adding a compile-time rule

Rules live in the checker cluster (`type_checker.zig`, `flow_checker.zig`, `fault_coverage.zig`, `bool_checker.zig`, `handler_contract.zig`) and are surfaced through `zts describe-rule`. When you add or remove a rule:

1. Update the corresponding checker and regenerate the rule registry if needed.
2. Run `./zig-out/bin/zts describe-rule --hash > policy-hash.txt` and commit the new hash.
3. Add a case under `tests/corpus/` that trips the diagnostic, with a `.diag` golden, and run `zig build diagnostic-corpus-write` (see `tests/corpus/README.md`). Review the golden against the case's stated intent, then raise `minimum_cases` in `packages/tools/src/diagnostic_corpus_gate.zig`.

## Code style

- `zig fmt` before every commit. CI does not auto-format.
- Types `UpperCamelCase`, functions/variables `lowerCamelCase`, files lowercase (`server.zig`, `handler_instance.zig`).
- Use native Zig error unions (`!T`) for expected failures across the engine and runtime. `Result<T>` is a user-facing JS and verification construct in handlers, not a Zig engine pattern.
- `errdefer` every allocation. `orelse` over `?` unwrap on hot paths.
- No `catch unreachable` on request paths. If the invariant is real, return a typed error and handle it.
- Do not introduce shared mutable state between pool workers; see `HandlerPool` / `LockFreePool`.

## Commits and pull requests

- Keep commit subjects short, lowercase, and descriptive (`feat(deploy): ...`, `fix(parser): ...`). The repo already uses Conventional Commits loosely.
- Each PR should have: a one-line summary, rationale, the `zig build test*` commands you ran, and doc or example updates if behavior changed.
- Update [CHANGELOG.md](CHANGELOG.md) under the `[Unreleased]` section for any user-visible change. Internal refactors can be omitted.
- Do not commit generated output (`zig-out/`, `.zig-cache/`).
- Do not commit secrets, credentials, or anything under `~/.zttp/`.

## Reporting bugs

For non-security bugs, open a GitHub issue with a minimal reproducer (handler source, CLI flags, the actual vs. expected output). For security reports, follow [SECURITY.md](SECURITY.md).
