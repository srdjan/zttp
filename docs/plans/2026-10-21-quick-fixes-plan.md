# Plan: three quick fixes (owner-approved D1(a), 2026-10-21)

Repo: /Users/srdjans/Code/_TEAMOK/ZTTP, local main at 791d73d5. Zig 0.16.0. Commit each unit separately on local main. Never push.

## Q1. Align release version copies to VERSION (0.23.0)

Problem: VERSION is 0.23.0. Six copies say 0.22.4, so `release_check.test.every release version copy in this repository equals VERSION` (tooling/release_check.zig:811) fails and `zig build test` fails at HEAD.

Edit these lines to 0.23.0 and change nothing else:
- build.zig.zon:3 `.version = "0.22.4",`
- packages/zts/build.zig.zon:3
- packages/runtime/build.zig.zon:3
- packages/zts/src/root.zig#version `pub const string = "0.22.4";`
- README.md:6 `# zttp v0.22.4`
- install.sh:6 `(current: v0.22.4)`

Do not touch CHANGELOG.md (release notes are the owner's) or the historical mentions in docs/plans/2026-10-20-hardening-pruning-plan.md.
Check: `zig build test-release-check` exits 0. `./zig-out/bin/zttp --version` prints 0.23.0 after `zig build`.
Open question for the validator: does `packages/zts/src/root.zig#version` feed any hashed identity (policy, registry, meta-drift pins) so that `zig build test-meta-drift` or goldens change? If so, regenerate through the documented command, never by hand.

## Q2. `zttp proofs verify` must pass the policy section to acceptance

Problem: packages/runtime/src/proofs/bundle.zig:370-378 calls `proof_activation.accept` with `.policy_section_digest` but not `.policy_section`. `proof_activation.Inputs.policy_section` (proof_activation.zig:41) documents that null supplies no resource authority and a guarded artifact is refused. Every guarded artifact therefore fails `proofs verify` with `REJECTED at guard_coverage (runtime_policy_missing)` and the false hint "Resolvable by rebuilding", while `zttp serve` (server.zig:1517-1528) accepts the same binary.

Fix: add `.policy_section = payload.policy_section,` to that call. `payload` is a `self_extract` payload, which has `policy_section: ?[]const u8` (self_extract.zig:50).
Test: add a regression test in bundle.zig next to "verify passes a bundle written by writeBundle" (line 1305). Build a guarded artifact (a handler with a computed env key under a policy `{"env":{"allow":["APP_NAME"]}}`, the pattern in build_command.zig test "real guarded artifacts reach consumer acceptance in expression positions" near line 1775), bundle it, run verify with proof required, and assert acceptance. Prove the test bites: with the one-line fix reverted, the test must fail. Record that you observed the failure.

## Q3. `deploy` / build must refuse an artifact that production acceptance refuses

Problem: `zttp deploy` printed `error[ZTS400]` and "1 flow error(s)", then wrote the artifact and printed "Deployed:" with exit 0. The binary then refused to start: "activation: proof acceptance failed at policy (required_property_not_established); refusing to serve". No production acceptance runs on the build path. (The only `proof_activation.accept` calls in build_command.zig are in test helpers, lines ~1772 and ~2069.)

Fix: in packages/runtime/src/build_command.zig `writeArtifactTail` (line 657), after the certificate, policy section, contract JSON and attestation exist, and before `capabilities.create_artifact`, run the same consumer acceptance that `Server.acceptEmbeddedCertificate` runs at startup (server.zig ~1495-1560):
- `proof_activation.accept(allocator, .{ certificate bytes, bytecode, dep_bytecodes, contract_section = contract_json, policy_section_digest = runtime_policy_digest, policy_section = policy_section, identity = (identity from the validated contract, as the server does), provenance }, pcc.policy.production)`.
- Then `contract_runtime.promote(validated, assessment, digest)`; refuse if it returns null, exactly as the server does. Validate the contract JSON with `contract_runtime.parseContractJson` + `contract_runtime.validate(raw, .{ .bytecode = ... })` as `loadArtifactForSource` does (line 2009).
- Provenance: production policy has no provenance requirement (proof-checker/src/policy.zig:114-123). Use `.absent`; do not claim `.signature_verified` for a signature nobody verified.
- On refusal: print one line naming the stage and code, in the server's wording, e.g. "Build refused: production acceptance failed at {stage} ({code}); the artifact would refuse to serve." Return a distinct error (e.g. `error.ProofAcceptanceFailed`) so the command exits 1 without a stack trace. Write no output file.
- No certificate or no contract: the server refuses these at startup, so the build must refuse them too.

Route the check through a new field on `ArtifactTailCapabilities` (struct at line 565), for example `accept_artifact`, so existing test probes (`PayloadCapture`, the `probe.capabilities()` callers) that deliberately write artifacts the server must refuse keep working with a pass-through. `production_artifact_tail_capabilities` (line 650) uses the real check. Do not gate on `builtin.is_test`.
Tests (in build_command.zig):
1. With production capabilities but a capturing `create_artifact`, a handler that production acceptance refuses returns `error.ProofAcceptanceFailed` and `create_artifact` is never called.
2. A handler that production acceptance accepts (the minimal `Proof<Response, "deterministic" | "read_only" | "state_isolated" | "no_secret_leakage" | "result_safe">` returning `Response.text("ok")`) still reaches `create_artifact`.
Prove test 1 bites by temporarily making the production check a pass-through and observing the failure.

End-to-end check (manual, scratchpad): reproduce with the handler
```
import { env } from "zttp:env";
function handler(req: Request): Response {
  const key = req.url;
  const v = env(key);
  return Response.text("ok");
}
```
in a fresh `zttp init` project; `zttp deploy --no-attest` must now exit 1 and leave no new binary; the starter template from `zttp init` must still deploy and serve 200.

## Verification (main session runs these itself)

Unfiltered: `zig build test` (expect 0 failures), `zig build test-zruntime`, `zig build test-server`, `zig build smoke-v1`, `zig build smoke-getting-started`, `zig fmt --check` on touched files, `zig build check-spine`. Redirect output to a file and read the exit status directly; never `| tail` then `$?`.

## Validation corrections (codex gpt-6-astra review, accepted)

Q1. packages/zts/src/root.zig#version feeds the expert session digest (packages/pi/src/session/protocol_identity.zig:39) and aggregate proof ids (packages/pi/src/aggregate_proof.zig:566). Old 0.22.4 sessions will report SessionProtocolMismatch and old ledger receipts prove_drift. This is the intended effect of the owner's version bump. No pin or golden needs regeneration (expert_meta.zig:12 uses a separate version; goldens.zig:203 excludes it). Checks: `zttp --version` prints `zttp 0.23.0`, `zts --version` prints `zts 0.23.0`.

Q2. The build_command.zig helper near 1772 uses the development policy; bundle verify uses production (policy.zig:114). The regression fixture must first be shown to pass production acceptance with policy bytes present and to carry a guard. Then bundle it and call verify with require_proof true. Assert semantic acceptance and the line `Guards:    1 of 1 covered (env_key)` (bundle.zig:396). With the fix removed, the test must fail with error.ProofRejected and `guard_coverage (runtime_policy_missing)`, not a generic failure. Suite: `zig build test-cli` (build/runtime_tests.zig:35).

Q3.
- `zttp compile`, `zttp build` and `zttp deploy` all reach buildArtifact (build_command.zig:167, 374, 484). All three refuse. No development-artifact exception exists on these paths. Dev serving, live reload and -Dhandler builds use other paths (server.zig:1474) and must stay unchanged.
- Identity: use exactly the projection in server.zig:1626 `observedArtifactIdentity`, from the parsed and validated serialized contract. Pass every dep bytecode and the exact policy section bytes.
- Refusal criterion: `contract_runtime.promote` returning null (contract_runtime.zig:142), as at startup (server.zig:1531). Provenance `.absent`.
- Clean exit: handle `error.ProofAcceptanceFailed` in all three dev_cli.zig handlers (compile :271, build :297, deploy :338), so the command exits 1 with the explanatory line and no stack trace and no success message. Missing certificate, missing contract and contract-validation failures also need explained refusal lines. Keep OutOfMemory distinct. When promote fails without `assessment.rejection()`, print a fallback line, as startup does.
- Both test probes, ArtifactTailProbe (build_command.zig:1232) and PayloadCapture (:1964), get an explicit pass-through `accept_artifact`. The test at :1326 requires creation with no contract and must keep passing.
- Tests must use the real production acceptance function and replace only artifact creation. Establish: the refusal fixture reaches acceptance rather than failing compilation; refusal returns ProofAcceptanceFailed with zero create calls; the accepted fixture calls create once; production refuses a missing certificate and a missing contract; a refused build leaves an existing output file unchanged.
- No module-boundary.allow or proof-swallow.allow row is needed (build_command.zig is outside the swallow scan list). Do not move error handling into proof_activation.zig.
