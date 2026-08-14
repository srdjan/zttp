---
status: blocked
priority: P1
effort: L
risk: high
planned_against: 9a664a47-dirty
created: 2026-08-13
blocker: durable-order returns EmptyResponse from the exact local model
---

# Plan 027: Complete the local LFM measurement and default cutover

> Executor instructions: Follow this plan in order. Preserve the existing dirty
> implementation and empirical artifacts. Run every verification command and
> confirm the expected result before continuing. Do not flip the default, run
> either documentation generator, or promote partial evidence until the full
> local corpus can replay. Stop on every STOP condition in this plan.
>
> Drift check, run first:
>
> ```bash
> cd /Users/srdjans/Code/ZttpHome/zttp
> printf '%s  %s\n' \
>   bd151590022f2e2374559167179874895f447c714e37bcb45c8a3cf16aeb1ca4 packages/pi/src/providers/models.zig \
>   8041c986b18c949d865b0dab56cc0ae84331ee1e21a8414ab72bdb52258821f0 packages/pi/src/providers/local/client.zig \
>   7e86c1db6f9030836d939962efd0d31136a48204474475acb04fc88d922ecae8 packages/pi/src/providers/selection.zig \
>   6e4ce7240edbd8de659164de39a06eb8a84c36340dce4a5463645a3d455b54ad packages/pi/src/expert_codegen_record.zig \
>   1d6757966d2fdfcdb9fd73db6c14031246703914cd47de7c2e9ebb569b94bb1e scripts/update-convergence.sh \
>   c4ce1fa38bf099d3366f5bbc0a47e134557ee14b0a69afe250f6f3b51efd0734 scripts/update-coverage.sh \
>   2f3a226835c85d6f0b732c94366fdb2e2168fa2af635ee6fb1af04c0b1454ee3 docs/convergence.json \
>   86cbdd95306a7b270da34d8c354f10c4ed9b103576fddaaa71f94e12b9aeb401 docs/coverage.json \
>   c22ece4a9f8af3d5da8b2cc30a3858969b9b1024a175cf3b54d653d36fad414c docs/roadmap.md \
>   | shasum -a 256 -c -
> ```
>
> If any checksum fails, compare this plan with the live files before editing.
> Stop if the provider, recording, promotion, or default-selection contracts no
> longer match the Current state section.

## Status

- Priority: P1
- Effort: L
- Risk: HIGH
- Depends on: the uncommitted local-provider implementation already present in the working tree
- Category: direction, tests, docs
- Planned at: commit `9a664a47` plus the dirty-tree checksums above, on 2026-08-13
- Tracker: none

This dated plan is the approved execution authority. It remains blocked until
Step 1 proves a generic transport or tool-schema defect that can be fixed
without changing the frozen measurement contract. `docs/roadmap.md` remains
the project planning authority.

## Why this matters

The local MLX transport, provider selection, session persistence, and real tool
flow work. The product still defaults to Claude because the local corpus is not
complete. Four of nineteen local cases have artifacts, the other fifteen are
missing, and `durable-order` has twice ended in `EmptyResponse` before an
artifact could be promoted.

The remaining work must preserve the evidence boundary. A low first-draft or
intent score is a valid result and must be published. A provider request that
aborts without a replayable artifact is not a completed measurement. The
default can move only after all cases have provider-qualified evidence, the
local replay has its own coverage ratchet, and the repository gates pass.

## Goal, approach, and smallest next step

Goal: make `LiquidAI/LFM2.5-2.6B-MLX-8bit` the shared runtime and evaluation
default, backed by a complete, reproducible local corpus and regenerated
convergence and coverage reports.

Approach: diagnose the `durable-order` failure without tuning against the frozen
corpus, finish the local recording exactly once per required case, establish a
provider-qualified local ratchet, repair the independent headline replay
failures, then flip the single default authority and publish through the
repository generators.

Smallest next step: inspect the sanitized MLX response shape that produced
`EmptyResponse` and decide whether it exposes a generic transport or tool-schema
defect. Do not run another paid or long-lived corpus attempt until there is a
specific defect or model-serving change to test.

## Current state

### Provider and structural flow

- `packages/pi/src/providers/models.zig:30` sets
  `default_provider = .anthropic`.
- `packages/pi/src/providers/models.zig:48` registers the exact local model with
  a 131,072-token context and an 8,192-token request output limit.
- `packages/pi/src/providers/selection.zig:54` resolves an explicit launch
  provider, then stored identity, then `models.default_provider`.
- `packages/pi/src/expert_codegen_record.zig:310` derives the evaluation
  headline from the same global default. The eventual cutover is one authority
  change, not separate runtime and evaluation switches.
- `zig build test-expert-mlx-e2e --summary all` passed on 2026-08-13 in 35
  seconds against the developer-managed loopback server. It exercised tool use,
  compiler Veto repair, approval, an applied edit, persistence, and resume.

### Local corpus

- `packages/pi/src/expert_codegen_record.zig:1425` owns the gated live recorder.
  It promotes a case only after turn completion, intent execution when declared,
  artifact validation, and replay validation.
- The local corpus root is
  `packages/pi/src/simulator/testdata/empirical/local/codegen/`.
- Four cases have active local artifacts: `health`, `validate-body`, `jwt-auth`,
  and `weather-egress`.
- Fifteen cases are missing: `durable-order`, four workflow cases, `sql-users`,
  five whole-file boundary cases, and four hole-mode cases.
- `durable-order` returned typed `EmptyResponse` twice. The model produced no
  usable assistant content or tool call. The recorder correctly left its
  previous active state untouched.
- The four readable local cases currently pass zero declared intent checks.
  `health` and `weather-egress` reached an applied edit; `validate-body` ended in
  veto exhaustion; `jwt-auth` exhausted its round-trip budget. These are honest
  observations, not reasons to re-record.
- The `weather-egress` local manifest lacks a provider-qualified
  `first_draft_veto_pass` field and cannot become headline evidence as-is.

### Ratchets and generated reports

- `packages/pi/src/expert_codegen_record.zig:1685` has an Anthropic coverage
  baseline only. A local headline fails closed with
  `MissingProviderCoverageBaseline`.
- `packages/pi/src/expert_codegen_record.zig:1942` reads provider-qualified
  first-draft expectations from flow manifests. Missing headline expectations
  fail with `MissingProviderFirstDraftExpectation`.
- `docs/convergence.json` and `docs/coverage.json` still describe the 19-case
  Anthropic corpus recorded on 2026-08-12.
- `scripts/update-convergence.sh` already emits a provider column and migrates
  historical table rows to `anthropic`.
- `scripts/update-coverage.sh` currently publishes corpus and rule coverage but
  does not identify the provider or model whose drafts produced the tripped set.
  The coverage emitter and page must carry that identity before the local
  default is published.

### Independent headline failures

The current Anthropic replay is also red:

- `jwt-auth` ends in `CassetteSequenceExhausted` because its sixteen-step
  cassette no longer covers the turn.
- `weather-egress` replays to `first_draft_pass=false` with `ZTS050`, while the
  historical compatibility pin still expects `true`.

These failures predate the local-provider implementation, but project guidance
requires the full repository gates to be green before completion.

## Decisions that remain fixed

- The exact local model is `LiquidAI/LFM2.5-2.6B-MLX-8bit`.
- The server is developer-managed, loopback-only, and never started or stopped
  by Zttp.
- Zttp never falls back from local to a cloud provider.
- Cloud providers require explicit `--provider claude` or `--provider openai`.
- Historical sessions without provider identity fail closed until the user
  selects a provider explicitly.
- Compiler-only `--goal` remains model-free.
- No score threshold applies to first draft, reached-green, intent, or
  round-trips. Record and publish poor outcomes honestly.
- Do not re-run a case until it produces a more favorable result.
- Do not change the frozen prompts, persona, tool descriptions, sampling policy,
  or budgets to teach the model a measured case. Fix only a generic defect that
  independent transport evidence proves.
- Existing Claude response evidence remains provider-qualified. Re-record a
  Claude case only when the replay proves its request sequence stale and the
  corpus protocol requires a fresh observation.

## Commands you will need

The operator, not the executor, owns this prerequisite:

```bash
mlx_lm.server --model LiquidAI/LFM2.5-2.6B-MLX-8bit --host 127.0.0.1 --port 8080
```

| Purpose | Command | Expected on success |
|---|---|---|
| Readiness | `curl --fail --silent http://127.0.0.1:8080/health` | JSON status is `ok` |
| Model identity | `curl --fail --silent http://127.0.0.1:8080/v1/models` | Exact 8-bit model ID is present |
| Structural E2E | `zig build test-expert-mlx-e2e --summary all` | Four build steps succeed and the real flow test executes |
| Local named recording | `ZTTP_CODEGEN_RECORD=1 ZTTP_CODEGEN_PROVIDER=local ZTTP_CODEGEN_MODEL=LiquidAI/LFM2.5-2.6B-MLX-8bit ZTTP_CODEGEN_ONLY=<case> zig build test-expert-app -Dtest-filter="record codegen baseline corpus" --summary all` | One named case completes, validates, and promotes |
| Local replay | `ZTTP_CODEGEN_REPLAY_PROVIDER=local zig build test-expert-app -Dtest-filter="codegen baseline replays at the committed first-draft pass rate" --summary all` | All 19 cases replay with no missing, stale, mixed-model, or missing-expectation error |
| Focused suites | `zig build test-expert-app test-cassette test-simulator test-cli --summary all` | All four suites pass |
| Structural gates | `zig build test-docs-drift test-doc-links test-module-boundary test-proof-swallow --summary all` | All four gates pass |
| Generated convergence | `bash scripts/update-convergence.sh` | Local provider and model row written through the generator |
| Generated coverage | `bash scripts/update-coverage.sh` | Local provider/model coverage JSON and Markdown written through the generator |
| Aggregate | `zig build test --summary all` | Exit 0 with no failed test |
| Full gate | `bash scripts/verify.sh` | Exit 0 with the repository's complete receipt |
| Diff hygiene | `git diff --check` | No output and exit 0 |

## Scope

In scope, the only files and directories the executor may modify:

- `packages/pi/src/providers/local/` for a generic, reproduced transport or
  tool-envelope defect only.
- `packages/pi/src/expert_codegen_record.zig` for provider-qualified pins,
  coverage identity, and the local coverage baseline.
- `packages/pi/src/simulator/artifact_contract.zig`,
  `packages/pi/src/simulator/artifact.zig`,
  `packages/pi/src/simulator/recorder.zig`, and their adjacent tests only if a
  generic artifact defect blocks faithful recording or replay.
- `packages/pi/src/simulator/testdata/empirical/local/codegen/` for recorder-
  generated local artifacts.
- `packages/pi/src/simulator/testdata/empirical/codegen/` and
  `packages/pi/src/providers/testdata/codegen/` only for protocol-required
  Anthropic re-recordings. Do not edit response bytes or manifests by hand.
- `packages/pi/src/providers/models.zig` for the final one-line default flip.
- `scripts/update-convergence.sh`, `scripts/update-coverage.sh`, and
  `scripts/check-convergence-emitter.sh` for provider-qualified generated output.
- `docs/convergence.md`, `docs/convergence.json`, `docs/coverage.md`, and
  `docs/coverage.json` only through their repository generators, except for
  reviewed narrative corrections in the non-generated part of
  `docs/convergence.md`.
- `README.md`, `packages/pi/README.md`, `docs/cli.md`, `docs/user-guide.md`,
  `docs/internals/zts-expert-contract.md`, `docs/roadmap.md`,
  `packages/runtime/src/cli_help.zig`, `packages/runtime/src/cli_doctor.zig`, and
  `packages/runtime/src/dev_cli.zig` for current-default wording and preflight
  expectations.
- `build.zig` for default-dependent executable-boundary tests.

Out of scope:

- Changing the selected local model or adding a second implicit model.
- Adding cloud fallback, provider inference from credentials, or automatic MLX
  lifecycle management.
- Raising budgets, changing sampling, or teaching the persona a corpus-specific
  answer.
- Rewriting frozen prompts to improve the measured score.
- Editing generated response fixtures, manifests, convergence JSON, coverage
  JSON, or coverage Markdown by hand.
- Manually editing any changelog or generated/vendor directory.
- Phase 7 model-minimal syntax work under
  `docs/plans/2026-08-09-024-zts-model-minimal-phase7-plan.md`.
- Unrelated cleanup in the existing dirty working tree.

## Git and workflow guidance

- Work directly on local `main` unless the user explicitly requests a branch.
- Preserve every unrelated local modification. Do not reset, restore, or stash
  the existing implementation as a whole.
- Commit subjects in this repository are short and often lowercase. Keep the
  corpus evidence, default flip, generated reports, and verification-relevant
  docs in one atomic cutover commit unless review finds a safe earlier
  infrastructure commit that leaves the default unchanged.
- Never push, open a pull request, publish, deploy, or mutate a remote.

## Steps

### Step 1: Establish a non-mutating compatibility diagnosis

Re-open `packages/pi/src/providers/local/client.zig`, the provider-neutral tool
catalog, and the response capture order. Determine whether the model emitted a
valid structured call or raw Liquid tool envelope that the adapter discarded.
Use sanitized response structure only. Do not persist reasoning text or raw user
source in diagnostics.

Acceptable fixes are generic and testable, such as recognizing a documented
wire shape, preserving a valid tool call through reasoning removal, or fixing a
provider-neutral schema serialization defect. Add a focused regression test
that fails on the current code before changing the decoder.

Do not alter the corpus prompt, persona, tool descriptions, model, output
budget, or generation defaults. Those changes would tune the system against its
evaluation set and invalidate the measurement.

Verify:

```bash
zig build test-expert-app test-cassette --summary all
zig build test-expert-mlx-e2e --summary all
```

Expected: all offline provider tests pass, the structural real-model flow still
executes, and any decoder fix is covered by a regression test.

STOP if the sanitized response is a valid model response with neither content
nor a tool call and no generic implementation defect explains it. Report that
the exact model cannot complete the frozen case under the settled request
contract. Do not retry the case or flip the default.

### Step 2: Record the local corpus without re-rolling

Record one named case at a time. Start with `durable-order` only after Step 1
produces a concrete fix or the operator changes a model-serving defect without
changing the settled generation contract. Preserve each promoted generation.

For the four existing cases:

- Keep `health`, `validate-body`, and `jwt-auth` unless a generic request-shape
  fix makes their request checkpoints stale.
- Re-record `weather-egress` once because its current artifact lacks the
  provider-qualified first-draft observation required of a headline case.
- Treat intent misses, veto exhaustion, and budget exhaustion as measured
  outcomes. Do not retry them for a better score.

Record each of the fifteen missing cases once. A case may finish without an
applied edit. It must still produce a valid executable flow artifact, preserve
the exact provider/model/revision/MLX-LM identity, and replay its own response
sequence.

After recording, run:

```bash
ZTTP_CODEGEN_REPLAY_PROVIDER=local \
  zig build test-expert-app \
  -Dtest-filter="codegen baseline replays at the committed first-draft pass rate" \
  --summary all
```

Expected: 19 of 19 cases resolve, all cassette model headers agree, every flow
has a provider-specific first-draft observation, and the command emits one
local `[codegen-convergence]` line plus one `[proof-coverage]` line.

STOP on `EmptyResponse`, a malformed or partial tool envelope, a missing
response fixture, a stale request checkpoint, mixed model identity, or failed
artifact validation. Preserve previously promoted cases and report the exact
case and typed failure.

### Step 3: Establish the local coverage ratchet

Take the tripped rule set from the successful complete local replay. Add an
immutable `local_coverage_baseline` beside the Anthropic baseline in
`packages/pi/src/expert_codegen_record.zig`. Make `coverageBaseline` select by
the exact provider and model ID. Do not borrow, union, or compare against the
Anthropic set.

Add tests that prove:

- the exact local provider/model resolves to the local baseline;
- the exact Anthropic provider/model keeps the historical baseline;
- an unknown model gets no baseline;
- an empty baseline fails closed;
- removing one measured local code makes a local headline replay fail.

Extend the proof-coverage marker and generator payload with `provider` and
`model`. Render both in `docs/coverage.json` and the generated Markdown so the
coverage set remains attributable after the default changes.

Verify the local replay again while Anthropic is still the headline. Expected:
it succeeds as an off-headline measurement and reports the committed local
baseline without touching the generated headline pages.

### Step 4: Repair the current Anthropic headline replay

Run the current headline replay and handle each failure according to the corpus
protocol:

```bash
zig build test-expert-app \
  -Dtest-filter="codegen baseline replays at the committed first-draft pass rate" \
  --summary all
```

For `jwt-auth`, compare the current request sequence with its sixteen-step
cassette. If an implementation change made the sequence stale, record one fresh
Claude generation with the exact historical headline model. Do not add a
response or weaken checkpoint validation by hand.

For `weather-egress`, preserve the recorded response bytes. The replay already
proves that the current compiler produces `first_draft_pass=false` with
`ZTS050`. Update the legacy compatibility pin only after reviewing that policy
change as intentional. Regenerate the corpus identity from source. Do not
re-record until a pass appears.

Verify: the Anthropic headline replay exits 0 before the default moves. Its
published outcome may be worse than the previous row; that is acceptable.

### Step 5: Flip the single default authority

Change `packages/pi/src/providers/models.zig:30` from `.anthropic` to `.local`.
Do not add another default flag or evaluation override.

Update every current-default surface found by:

```bash
rg -n "current default|currently defaults|default remains|Claude default|defaults to Claude" \
  README.md packages/pi/README.md docs packages/runtime/src build.zig
```

At minimum, reconcile the root README, Pi README, CLI guide, user guide,
expert contract, roadmap, CLI help, doctor output, `init --expert` preflight,
and the default-dependent build expectations. Cloud authentication should read
as optional and explicit. Bare `zttp expert` and `init --expert` must check the
loopback local server before creating session or scaffold files.

Keep tests derived from `models.default_provider` where possible. Use literal
provider assertions only at product boundaries where the cutover itself is the
contract.

Verify:

```bash
zig build test-expert-mlx-e2e --summary all
zig build test-expert-app test-cassette test-simulator test-cli --summary all
zig build test-docs-drift test-doc-links test-module-boundary test-proof-swallow --summary all
```

Expected: every command exits 0. Bare expert selection is local even when cloud
keys exist, explicit Claude and OpenAI selection remains provider-scoped, and
compiler-only `--goal` never checks MLX readiness.

### Step 6: Generate and review convergence and coverage

Run the generators only after the local provider is the headline and its full
replay and coverage baseline pass:

```bash
bash scripts/update-convergence.sh
bash scripts/update-coverage.sh
```

Expected generated state:

- `docs/convergence.json` names provider `local`, the exact LFM model, 19 cases,
  the current corpus version, and the measured scores.
- The convergence table gains one local row and retains historical Anthropic
  rows with their provider identity.
- `docs/coverage.json` names the local provider and model and contains the exact
  rule set emitted by the complete local replay.
- `docs/coverage.md` reports the same provider/model, corpus version, rule
  denominator, tripped codes, and untripped codes.
- No measured score is edited or rounded by hand.

Review the generated diff. If either script reports a dirty commit marker,
retain it until the entire cutover is committed together. Do not replace it
with a clean hash manually.

### Step 7: Run the complete gate and prepare the local commit

Run:

```bash
zig build test --summary all
bash scripts/verify.sh
git diff --check
```

Then confirm:

```bash
git status --short
git diff -- docs/convergence.md docs/convergence.json docs/coverage.md docs/coverage.json
```

Expected: the aggregate and full verification exit 0, diff hygiene passes, all
nineteen local artifacts are present, generated pages match the replay, and no
file outside this plan's scope changed during execution.

Do not commit unless the user asks. Never push.

## Test plan

- Preserve all existing local transport cases for structured calls, raw tool
  envelopes, nested arguments, reasoning removal, deterministic IDs, malformed
  input, truncation, and loopback validation.
- Add one regression for the generic defect, if any, that caused
  `durable-order` to decode as `EmptyResponse`.
- Add provider/model-qualified local coverage baseline tests.
- Add proof-coverage emitter and generator tests for the required provider and
  model fields.
- Keep session selection tests for bare local, explicit cloud, stored identity,
  legacy migration, fork, resume, model mutation, and atomic failure.
- Keep CLI boundary tests for bare expert readiness, `init --expert`, help,
  doctor, RPC `session.info`, and model-free `--goal`.
- Run the real MLX structural E2E before and after the default flip.
- Replay both providers before the flip and the local headline after the flip.
- Run the full repository gate last.

## Done criteria

All must hold:

- [ ] The exact local model passes `test-expert-mlx-e2e` with no cloud key.
- [ ] Every one of the 19 frozen corpus cases has one active, valid local flow
      generation with provider, model, revision, MLX-LM version, and
      first-draft observation.
- [ ] The local replay has no missing, stale, mixed-model, or missing-pin case.
- [ ] Poor first-draft, reached-green, intent, or round-trip results remain
      visible and are not re-rolled.
- [ ] Local and Anthropic coverage ratchets are separate and exact-model
      qualified.
- [ ] `default_provider` is `.local`, and the evaluation headline derives from
      it.
- [ ] Bare expert and `init --expert` use local readiness; explicit cloud
      selection still requires only its named credential.
- [ ] `--goal` remains model-free.
- [ ] The convergence and coverage generators publish local provider/model
      identity and the measured values.
- [ ] `zig build test --summary all`, `bash scripts/verify.sh`, and
      `git diff --check` exit 0.
- [ ] No cloud fallback, model lifecycle control, evaluation-specific prompt
      teaching, or unrelated work entered the diff.
- [ ] The promoted copy under `docs/plans/` and the roadmap status agree.

## STOP conditions

Stop and report if:

- The drift check shows that provider selection, recording, or promotion has
  changed enough to invalidate this plan.
- `durable-order` still returns a valid empty assistant response after a generic
  transport defect is excluded. Do not retry or tune the frozen case.
- The fix requires another model, changed sampling, larger budgets, a corpus-
  specific persona instruction, or altered frozen prompts.
- The full local run cannot produce replayable artifacts for all 19 cases.
- Any artifact mixes providers, models, revisions, or server versions without
  an explicit reviewed reason.
- A generated page lacks provider/model attribution or disagrees with the
  replay marker.
- The Anthropic replay remains red when Step 4 is complete.
- The default flip causes any model-free, session, CLI, docs, boundary, proof,
  aggregate, or full verification gate to fail twice after a reasonable local
  correction.
- Completion requires editing response fixtures, manifests, generated JSON,
  coverage Markdown, a changelog, or generated/vendor files by hand.
- A credential, raw reasoning field, user source, or other sensitive value
  appears in logs or artifacts beyond the existing sanitized contract.

## Maintenance notes

- Reviewers should scrutinize evaluation leakage, re-recording rationale,
  provider/model provenance, and any change that converts a provider error into
  a measured case outcome.
- The corpus score is descriptive. Future release policy may add a quality bar,
  but this plan must not invent one during the cutover.
- If the exact model remains incompatible, close this plan as BLOCKED and keep
  the explicit local provider available behind `--provider local`. Do not weaken
  the completion rule to obtain the default flip.
- Keep the local coverage baseline when the compiler changes. Move it only from
  a complete replay and explain every lost fence.
