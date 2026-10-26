# Plan 012: Provenance and security claims say exactly what they check

> **Executor instructions**: Follow this plan step by step. Run every verification command and confirm the expected result before you continue. Touch only the files in scope. If a STOP condition occurs, stop and report. When done, update the status row for this plan in `advisor-plans/README.md`.
>
> **Drift check, run first**: `git diff --stat c1ecdf65 -- packages/runtime/src/verify_cli.zig packages/runtime/src/attest/envelope.zig docs/cli.md docs/user-guide.md docs/proofs-and-receipts.md docs/threat-model.md docs/roadmap.md SECURITY.md` and, in `../ZTTP-WEBSITE`, `git log -1 --format=%h -- static/index.html`
> If a file in scope changed, compare the Current state facts with the live code. If they do not match, stop and report.

## Status

- **Priority**: P1
- **Effort**: S
- **Risk**: LOW (output wording, one JSON field, docs)
- **Depends on**: owner Decision 19 for Step 1. Steps 3 and 4 are skipped if the re-record window (plan 013 and the U2 and U3 units) lands before the release.
- **Category**: security (disclosure) and docs
- **Planned at**: commit `c1ecdf65`, 2026-10-26
- **Source**: release review 2026-10-26, findings M1, H1 (interim), M2 (interim)

## Why this matters

`zttp verify <url>` prints "Signature verified" after it checks the signature against a public key that the endpoint itself supplies. Any endpoint can mint a key and pass. Separately, two analyzer limits let a declared `no_secret_leakage` capsule pass for a handler that leaks: the `env()` name rule (H1) and the `mask` bound (M2). Their code fixes (U2 and U3) wait for the re-record window. Until then, users must be told. This plan changes no verdict and no hashed surface.

## Owner decision required

Decision 19: the exit status of an unpinned `zttp verify`.
- (a) Exit 0, with output that says the key is not pinned and a JSON field `keyPinned: false`. Existing automation keeps working, but automation that checks only the exit status still sees success for an unauthenticated signer. **Recommended only if the owner accepts that consequence.**
- (b) A distinct non-zero exit status for an unpinned result. Automation that never pins starts to fail, which forces it to pin or to opt out explicitly.

Step 1 below implements (a). For (b), add the new exit code beside the existing ones in `verify_cli.zig`, return it when no `--trust-key` is given, and document it in Step 2.

## Current state

- `packages/runtime/src/attest/envelope.zig`, function `verify`: parses the public key from the JWS protected header and checks the Ed25519 signature against it. It checks neither `signed_at` nor any origin or host binding.
- `packages/runtime/src/verify_cli.zig`: function `run` compares fingerprints only when `--trust-key` is given; without it, the exit status is `exit_ok` (0). Exit codes: 0 ok, 1 argument error, 2 not attested, 3 bad signature, 4 key mismatch, 5 HTTP error. `renderClaimsHuman` starts with `Signature verified: {s}`. `renderClaimsJson` writes `assurance: "provenance_only"` and has no pinned field. A comment marked "TODO(slice 2)" asks for a fixture test of `run`. Tests in the same file assert the literal `"Signature verified: https://example.test\n"` and the JSON shape.
- No doc mentions `--trust-key` (`docs/cli.md`, `docs/user-guide.md`); only `SECURITY.md` describes pinning. `docs/threat-model.md` does not cover `zttp verify`. The website (`../ZTTP-WEBSITE/static/index.html`) says "Anyone can run `zttp verify <url>` to check the signature" and "Signed and publicly verifiable".
- H1, reproduced 2026-10-26: with `structural LeakProof<T> = Proof<T, "no_secret_leakage">;`, a handler returning `Response.json({ v: env("STRIPE_SK") ?? "" })` passes `zts check` (exit 0); the same with `env("DATABASE_URL")` and `env("SESSION_COOKIE")` passes; `env("DB_SECRET")` is refused. Cause: `packages/zts/src/flow_interp.zig` function `declaredLabels` labels a literal `env` name `config` unless it contains SECRET, PASSWORD, PASSWD, KEY, TOKEN, PRIVATE, CREDENTIAL, or AUTH (case-insensitive).
- M2, reproduced 2026-10-26: `mask(env("API_SECRET") ?? "", 1000)` and `mask(..., 4)` both pass the same capsule. Any numeric literal bound declassifies (`flow_interp.zig`, the declassification check that reads `declassify_bound_arg`). `mask(text, visible)` (`packages/modules/src/platform/text.zig` function `maskImpl`) reveals the trailing `visible` bytes when the input is longer than `visible`, and masks the whole input otherwise. So `mask(secret, 39)` on a 40-byte secret reveals 39 bytes.
- `docs/proofs-and-receipts.md` defines `no_secret_leakage` as "no secret-labelled value reaches a response body or header, a log, or an egress call" and has a section "Known Limits of the Security Chips" whose table lists shapes by version.
- Website rule (`AGENTS.md`, Documentation): "When a change adds an important feature or improvement, update `../ZTTP-WEBSITE` in the same work session." Keep claims tied to checked behavior; run `deno task verify` there before committing; never push or deploy. The website states the verify claim directly, so this plan corrects it.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Setup | `unset DEEPSEEK_API_KEY; export ZIG_LOCAL_CACHE_DIR=<private dir> ZIG_GLOBAL_CACHE_DIR=<private dir>` | none |
| CLI tests | `zig build test-cli > c.log 2>&1; echo $?` | `0` |
| Docs | `zig build test-docs-drift`, `zig build test-doc-links` | `0` each |
| Aggregate, spine, full gate | `zig build test`, `git add -A && zig build check-spine`, `bash scripts/verify.sh` | `0` each |
| Website | `cd ../ZTTP-WEBSITE && deno task verify` | exit 0 |

## Scope

**In scope:** `verify_cli.zig` (rendering and its tests), `docs/cli.md`, `docs/user-guide.md`, `docs/proofs-and-receipts.md`, `docs/threat-model.md`, `docs/roadmap.md`, `SECURITY.md`, and `../ZTTP-WEBSITE/static/index.html`.

**Out of scope:** `envelope.zig` verification logic, exit codes, origin binding and freshness (deferred to receipt slice 2), and every analyzer file (U2 and U3 own the code fixes).

## Steps

### Step 1 (M1): Unpinned output says so

Pass `pinned: bool` (true only when `--trust-key` matched) into `renderClaimsHuman` and `renderClaimsJson`. Human output: when pinned, keep `Signature verified: <url>`; when not pinned, print `Signature valid against the key the endpoint supplied (key not pinned): <url>`, then `  pin it with --trust-key <fingerprint>`. In both cases add one line: `  signed_at is the signer's own claim; no host is bound to this claim.` JSON: add `"keyPinned": true|false`. Exit status per Decision 19. Update the two human-output test literals and add a `keyPinned` assertion to the JSON test, plus one test for the pinned case.

**Verify**: `zig build test-cli` exits 0.

### Step 2 (M1): Document pinning and its limits

`docs/cli.md` and `docs/user-guide.md`: document `--trust-key <fingerprint>`, state that without it the signer is not authenticated, and state that claims carry no host binding and no checked time. `docs/threat-model.md`: add `zttp verify` with the same limits. `docs/roadmap.md`: add a row for receipt identity binding (well-known endpoint, transparency log, origin and freshness binding) as deferred. Website: change the two statements so they say the signature is checked and that pinning a key authenticates the signer.

**Verify**: `test-docs-drift`, `test-doc-links`, and `deno task verify` in the website repository exit 0.

### Step 3 (H1 interim): Disclose the env name rule

Skip this step if U2 has landed. In `docs/proofs-and-receipts.md`, under "Known Limits of the Security Chips", add a dated paragraph and table row: in the current version, an `env()` value counts as secret only when its literal name contains one of the eight substrings above; a handler that returns `env("DATABASE_URL")` or `env("STRIPE_SK")` can prove `no_secret_leakage`; rename such variables to include one of the substrings, or do not rely on the chip for them. Name the planned fix (every literal name is secret unless the policy lists it in `env.public`).

**Verify**: `test-docs-drift` and `test-doc-links` exit 0.

### Step 4 (M2 interim): Disclose the mask bound

Skip this step if U3 has landed. Add a row: any numeric literal `visible` argument to `mask` declassifies the result, and `mask` reveals the trailing `visible` bytes of a longer input, so `mask(secret, 39)` on a 40-byte secret can prove `no_secret_leakage` while it reveals 39 bytes. Name the planned fix (a literal bound of 4 or less).

**Verify**: same as Step 3.

## Done criteria

- [ ] An unpinned `zttp verify` result is labelled unpinned in human and JSON output.
- [ ] `--trust-key` and the provenance limits are documented; the website matches.
- [ ] Steps 3 and 4 are done, or U2 and U3 have landed.
- [ ] `test-cli`, `test-docs-drift`, `test-doc-links`, `zig build test`, `check-spine`, `bash scripts/verify.sh`, and `deno task verify` exit 0.

## STOP conditions

- A script, smoke test, or tool parses the `Signature verified` line (search `scripts/`, `tooling/`, and `packages/` first; `tooling/release_check.zig` only checks help text).
- The website repository has uncommitted changes that are not yours.
- A gate fails twice after reasonable local correction.

## Maintenance notes

- When receipt slice 2 lands, revisit the unpinned wording and the roadmap row.
