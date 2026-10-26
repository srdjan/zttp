# Plan 011: The documented CLI flows work and fail clearly

> **Executor instructions**: Follow this plan step by step. Run every verification command and confirm the expected result before you continue. Touch only the files in scope. If a STOP condition occurs, stop and report. When done, update the status row for this plan in `advisor-plans/README.md`.
>
> **Drift check, run first**: `git diff --stat c1ecdf65 -- packages/runtime/src/server.zig packages/runtime/src/runtime_cli.zig packages/runtime/src/dev_cli.zig packages/runtime/src/proofs packages/runtime/src/proofs_cli.zig packages/runtime/src/cli_help.zig packages/tools/src/precompile_args.zig packages/tools/src/zts_cli.zig packages/tools/src/precompile_check.zig docs/user-guide.md docs/cli.md docs/reliability.md docs/roadmap.md README.md scripts/smoke-v1.sh`
> If a file in scope changed, compare the Current state facts with the live code. If they do not match, stop and report.

## Status

- **Priority**: P2
- **Effort**: M
- **Risk**: LOW to MED (M3 depends on kernel bind rules; Step 1 tests them)
- **Depends on**: plan 007 (both edit `precompile_check.zig`; do 007 first); owner Decision 20 for Step 1
- **Category**: bug (usability) and docs
- **Planned at**: commit `c1ecdf65`, 2026-10-26
- **Source**: release review 2026-10-26, findings M3, M4, M5, and the low items

## Why this matters

Three documented flows fail. A second server on a busy port silently takes the traffic. The documented `serve -e` one-liner fails with a bare "ParseError". The documented proof-bundle command names a file that `deploy` never writes and fails with a stack trace. Smaller defects (help flags, stale doc statements, a misleading card after a parse failure) add friction. Each unit below is independent and gets its own commit.

## Current state

All facts were reproduced on 2026-10-26 with a build of `c1ecdf65`, unless marked "read".

- **M3**: `packages/runtime/src/server.zig` listens with `.reuse_address = true` for the public listener (in the server start path; the other `reuse_address` sites in `server.zig`, `fetch_deadline.zig`, and `zruntime_tests.zig` are tests on port 0). Zig 0.17.0 `std/Io/Threaded.zig` sets `SO_REUSEADDR` and then `SO_REUSEPORT` at socket creation whenever `reuse_address` is true; `std.Io.net.IpAddress.ListenOptions` has no separate switch. Review note (Fable, from Linux kernel source reading, not run): on Linux the bind bucket caches the reuseport state of the first socket, so clearing `SO_REUSEPORT` on that socket after `listen` probably does not make a later bind fail; macOS reads the current socket options at the second bind. Two `zttp serve` processes on one port both stayed up, and all requests went to the second. `packages/runtime/src/runtime_cli.zig` function `reportServerError` already prints "Port N is already in use", but it never fires. Live reload swaps handlers in the same process and never reopens the listener (read).
- **M4**: `zttp serve -e "function handler(req) { return Response.json({ ok: true }) }"` prints `zttp serve: ParseError. Run \`zttp serve --help\` for usage.` and exits 1; the cause is ZTS047 (no semicolon). `runtime_cli.zig` function `validateSourceAuthority` calls `zts.pipeline.extractContract`, which returns the refusal error without text; `dev_cli.zig` function `cmdServe` formats it as a flag failure. The parse-error renderer used by `zttp check` is `packages/tools/src/precompile_stderr.zig` function `printParseErrors` (read). The broken example appears in `docs/user-guide.md` (Quick start and the serve section), `docs/cli.md` (serve), and the help text in `runtime_cli.zig`.
- **M5**: after `zttp init my-app` and `zttp deploy`, `.zttp/deploy/` holds only the binary. `docs/user-guide.md` (proof flow) runs `zttp proofs bundle --contract .zttp/deploy/handler.contract.json --binary .zttp/deploy/my-app --out bundle`, which fails with `error: FileNotFound` and a stack trace from `packages/runtime/src/proofs/bundle.zig` function `writeBundle`. `proofs_cli.zig` re-raises the error; its `isExpectedUserError` does not list `FileNotFound`. The contract is embedded in the binary payload (`build_command.zig` function `writeArtifactTail`, read). Also (read): bundle verification reads the contract from the binary payload, so a `--contract` file that differs from the binary is bundled without complaint.
- **Low items**:
  - `docs/reliability.md` says connection workers are "clamped 2-128"; `server.zig` uses `cpu_count * 2` with no clamp. It also says "The edge closes" (the `edge` command was removed). Plan 008 owns the timeout rows.
  - `zts compile --help` prints "Unknown flag: --help" and then suggests `zts compile --help` (`packages/tools/src/precompile_args.zig`, `parsePrecompileArgSlice`, accepts five named options and refuses every other long option, `--help` included). `zttp proofs bundle --help` prints "unknown argument '--help'" (`proofs_cli.zig`).
  - `docs/cli.md` says every `zts` command has an identical `zttp` form, but `zts compile <h.ts> <out.zig>` differs from `zttp compile <h.ts> -o <bin>` (`zts_cli.zig` keeps them separate on purpose).
  - After a parse failure, the human card (`packages/tools/src/precompile_check.zig` function `formatProofCard`) still prints OK for the Types, Sound mode, and Strict stages, which did not run. No test asserts those lines.
  - `packages/runtime/src/cli_help.zig` says "serverless JavaScript runtime" in two places, but `.js` sources are refused (ZTS052).
  - `README.md` shows `zttp init my-app --expert` before it says that `--expert` needs a DeepSeek key or `--provider local`.
  - `docs/roadmap.md` still lists the release-provenance republish as open; `zig build release-provenance` exited 0 at `c1ecdf65`. Plan 014 also touches the roadmap; do this deletion there if plan 014 runs first.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Setup | `unset DEEPSEEK_API_KEY; export ZIG_LOCAL_CACHE_DIR=<private dir> ZIG_GLOBAL_CACHE_DIR=<private dir>` | none |
| CLI, server, precompile | `zig build test-cli`, `zig build test-server`, `zig build test-precompile`, `zig build test-zts-cli`, `zig build test-cli-abuse` | `0` each |
| Flows | `zig build smoke-v1`, `zig build smoke-getting-started` | `0` each |
| Docs | `zig build test-docs-drift`, `zig build test-doc-links` | `0` each |
| Aggregate, spine, full gate | `zig build test`, `git add -A && zig build check-spine`, `bash scripts/verify.sh` | `0` each |

## Scope

**In scope:** the files listed in the drift check, plus tests beside them.

**Out of scope:** diagnostic text and codes, `policy-hash.txt`, contract goldens, the codegen corpus, and the website (no public claim changes in this plan).

## Steps

### Step 1 (M3): A busy port refuses a second server

Owner Decision 20 decides the mechanism before this step starts:
- (a) Clear `SO_REUSEPORT` after `listen` (small change), adopted only if the test below passes on macOS and in the Linux arm64 release container. **Recommended as the first attempt.**
- (b) A hand-built listener for the public socket: `socket`, `SO_REUSEADDR` only, `bind`, `listen`, then wrap it as a `std.Io.net.Server` (about 25 lines that replace std networking for this one socket). Approve now as the fallback, so a Linux failure in (a) does not stop the plan at release time.

First write the test: in `server_test.zig`, start a server on an ephemeral port, then a second bind on that port with the server's listen options must fail with `error.AddressInUse`; a restart right after a clean stop must succeed. Confirm that the test fails on macOS at `c1ecdf65`.

Then implement (a): keep `reuse_address = true` (restart over TIME_WAIT), and right after the public listener's `listen` call clear `SO_REUSEPORT` with `std.posix.setsockopt(listener.socket.handle, std.posix.SOL.SOCKET, std.posix.SO.REUSEPORT, std.mem.asBytes(&@as(c_int, 0)))`, guarded by `@hasDecl(std.posix.SO, "REUSEPORT")`, with a one-line comment that says why. Run the test on macOS and in the Linux arm64 container that `scripts/release.sh` builds (`zttp-release-linux:0.17.0-arm64`, run `zig build test-server` in a fresh clone inside it). If the Linux run fails, replace (a) with (b) when the owner approved (b); otherwise STOP.

**Verify**: the test passes on macOS and in the Linux container. Reproduce manually on macOS: a second `zttp serve` on a busy port prints "Port N is already in use" and exits non-zero.

### Step 2 (M4): serve shows parse diagnostics

In `validateSourceAuthority`, on `error.ParseError`, render the parse errors with the same renderer that `zttp check` uses (export it from `packages/tools/src/precompile.zig` if it is not reachable) and return a new error that `cmdServe` reports with exit 1 and no flag-usage hint. Add the missing `;` in the three places in two docs (`docs/user-guide.md` twice, `docs/cli.md` once) and in the help text.

**Verify**: `zttp serve -e "function handler(req) { return Response.json({ ok: true }) }"` prints a ZTS047 line with a location. The corrected doc one-liner serves `{"ok":true}`. `zig build test-cli` exits 0.

### Step 3 (M5): bundle works from the deploy output

In `writeBundle`: when `--binary` is given and `--contract` is not, write the binary payload's contract as `handler.contract.json`; when both are given and the bytes differ, refuse with a message. Replace the bare read of `--contract` with an error that names the path. Add `FileNotFound` handling so no stack trace prints. Update the `proofs bundle` help and `docs/user-guide.md` to `zttp proofs bundle --binary .zttp/deploy/my-app --out bundle`. Add bundle and `zttp proofs verify bundle --require-proof` steps after the deploy step in `scripts/smoke-v1.sh`.

**Verify**: `zig build smoke-v1` exits 0; a missing `--contract` path prints one line naming the path and exits 1.

### Step 4 (low): help flags, card, and wording

- `zts compile --help` and `zttp proofs bundle --help` print their usage and exit 0.
- `formatProofCard` prints `SKIPPED (parse failed)` for stages that did not run when `parse_errors > 0`; add a substring test in `packages/tools/src/precompile_check_tests.zig`.
- `cli_help.zig`: replace "serverless JavaScript runtime" with "agent-compiler and local runtime for zts TypeScript".
- `docs/cli.md`: name `compile` as an exception beside `expert` and `ledger`.
- `docs/reliability.md`: correct the worker count statement to match `server.zig`, and replace "The edge closes" with "The server closes".
- `README.md`: one sentence before `zttp init my-app --expert` that names the DeepSeek key or `--provider local`.
- `docs/roadmap.md`: delete the release-provenance row, unless plan 014 already did.

**Verify**: `zig build test-precompile`, `test-zts-cli`, `test-cli`, `test-docs-drift`, `test-doc-links` exit 0.

## Done criteria

- [ ] Each step's verification passed, and each step is its own commit.
- [ ] `zig build test`, `smoke-v1`, `smoke-getting-started`, `check-spine`, and `bash scripts/verify.sh` exit 0.
- [ ] No file outside the scope list changed.

## STOP conditions

- Step 1: the owner has not chosen Decision 20, or option (a) fails on either platform and the owner did not approve option (b).
- Any step moves `policy-hash.txt`, a contract golden, or the codegen replay.
- A gate fails twice after reasonable local correction.

## Maintenance notes

- Reviewers should run the corrected user-guide commands end to end in a scratch directory.
