# Expert contract card and required properties

Status: draft plan, revision 2, 2026-11-14. No code changes yet. A Fable
review and a Codex astra review checked revision 1. This revision resolves
their findings, listed under "Review of revision 1".
Source: F2 of [Expert interface options](2026-11-14-expert-interface-options.md).
The owner chose option (a) of D10 on 2026-11-14: plan F2, have Fable and
Codex astra review the plan, and bring it for approval.

## Goal

A developer pins the proof properties that a project must keep. After that,
the expert applies no change set whose candidate does not prove every pinned
property, in any approval mode. The developer pins with one command and one
key. The pin persists in `zttp.json` across sessions.

## What F2 asked for, and what this plan delivers

F2 has two halves. The first half is a card before code: the model proposes
routes, required properties, env and egress rows, and examples, and the
developer accepts them. The second half is the hold: the host refuses a later
change set that leaves the accepted contract.

This plan delivers the hold, and a card that shows and pins the contract of the
current workspace. It does not deliver the model proposal before code. D11
explains why: the proposal changes text that the model sees, and that forces a
paid corpus re-record.

The pin is an expert rule. `zttp check`, `zttp dev`, `zttp build`, and
`zttp deploy` do not read it.

## Findings

These are from a code survey and two reviews on 2026-11-14 at commit
`6f3046ff`.

1. Any new tool, persona line, catalog entry, or host text in every request
   changes `packages/pi/src/session/protocol_identity.zig#current` or the
   per-call digests that
   `validateSnapshot` of `packages/pi/src/simulator/model_client.zig#Client`
   checks.
   That identity includes the diagnostic catalog hash
   (`packages/zts/src/diagnostic_catalog.zig#catalogHash`). Such a change
   forces a DeepSeek re-record of the 13 codegen cassettes, and older
   sessions stop resuming. D-019 in `docs/decisions.md` deferred a
   model-visible change for this reason.
2. Nothing holds a change set to a list of required properties. The veto in
   `packages/pi/src/aggregate_proof.zig#prove` refuses only a diagnostic that
   is new against the baseline (`firstNewDiagnostic`). A candidate that
   narrows its own `Proof<>` capsule loses the dropped properties and passes.
   The test "the card shows a failed test row when the candidate recurses
   without bound" in `packages/pi/src/repl.zig` shows this: `fault_covered`
   and `cost_bounded` are lost, and the change set is accepted.
3. `prove` already rejects with codes that are not diagnostics:
   `handler_export_lost`, `policy_context_failed`, `baseline_analysis_failed`,
   and `candidate_analysis_failed`. Each code is a string in
   `aggregate_proof.zig` only. No catalog or hash includes them. The model sees
   such a rejection only when it fires.
4. `prove` has the candidate's final properties in `primary_properties`. They
   come from the same check result as the result card
   (`packages/pi/src/proof_enrichment.zig#propertiesSnapshot`). Every apply
   path, including `--yes`, `--print`, `--goal`, and recovery, goes through
   `prove` (Fable review).
5. A change set holds `.ts` files only
   (`packages/pi/src/change_set.zig#isSupportedSourcePath`). The model cannot
   edit `zttp.json`.
6. `zttp.json` ignores unknown keys
   (`packages/tools/src/project_config.zig#loadAbsolute`). An older zttp
   therefore accepts a project with a new key. That loader keeps no key order
   and drops unknown keys, so a writer must edit the raw JSON object instead.
   The keys `invariants`, `declaration`, and `ledger` are retired and make the
   load fail.
7. A `Proof<>` capsule names properties from
   `packages/zts/src/spec_discharge.zig#v1_spec_names`, 17 names. Each maps to
   a boolean field of `HandlerProperties`
   (`packages/zts/src/spec_discharge.zig#PropertyField`).
   The card also shows `has_egress` and `post_only`, which are facts and not
   guarantees.
8. A defect in the current code: when the policy file does not parse, the
   check reports one ZTS000 for both the baseline and the candidate
   (`packages/tools/src/precompile_contract.zig#appendPolicyDiagnostics`). The
   veto sees no new diagnostic and accepts. A broken policy file therefore
   turns off the env, egress, cache, and SQL allow lists in the expert, with
   no message (Fable probe).

## Review of revision 1

Revision 1 put the requirement in the capability policy as a new section, with
a new diagnostic POL009. The reviews found these defects in that design:

- POL009 changes `catalogHash`, and its registry row changes `policyHash`. Old
  sessions stop resuming, and the corpus must be re-recorded. That design was
  meant to avoid both (Fable, Codex).
- A typo in the new section makes the policy fail to parse, and finding 8 then
  turns off every pin and every allow list (Fable).
- An older zttp refuses a policy file with an unknown section, so its build
  fails (Fable probe).
- The hold was differential. A pinned property that the baseline already lost
  stayed lost after later edits (Codex, Fable).
- The policy stage runs before the stages that set `fault_covered` and
  `cost_bounded` (Codex, Fable).
- `handler_policy.zig` cannot import `v1_spec_names` across the tier boundary
  (Codex).
- The test fixtures need a project config, a real `--yes` path, and capture of
  stdout (Codex).

Revision 2 uses the design that Fable proposed. The pin is a key in
`zttp.json`, and `prove` enforces it as a host rejection. It needs no parser
change in zts, no catalog entry, no registry row, and no new check stage.

## Decision D11: where the requirement lives

- (a) A `requiredProperties` key in `zttp.json`, enforced in `prove` as a host
  rejection after the diagnostic comparison. Recommended. The check is
  absolute: the candidate must prove every required property, whatever the
  baseline proves. The model sees the rejection text only when a project has
  the key, and no corpus case has it.
- (b) A model tool that proposes the contract before code, and a card that
  asks for approval. This is the full F2. It needs a DeepSeek re-record of the
  13 cassettes, and older sessions stop resuming. It can follow (a) at the next
  re-record round, as D-019 did for response headers.
- (c) A `properties` section in the capability policy with a diagnostic
  POL009. This was revision 1. The reviews found the defects above.

## Decision D12: what `/contract` pins

- (a) The proven properties only. Recommended. The card also shows routes, env
  reads, and egress endpoints, but it does not write them. An env or egress
  allow list also restricts a precompiled handler at run time, so pinning it
  is a larger change than an expert rule.
- (b) The proven properties, the env reads, and the egress endpoints.

## Decision D13: example requests

- (a) Defer them. Recommended. The model cannot write test rows (finding 5),
  and the host has no source of examples that a developer has checked.
- (b) The host writes test rows from the intent assertions of the handler
  (`packages/zts/src/intent_extractor.zig#extract`). Nothing runs those
  assertions today, so their shape needs its own review.

## Decision D14: the policy parse defect of finding 8

- (a) Fix it in this plan, as U1. Recommended. The fix is in the same function
  as U2, and the pin depends on the same veto.
- (b) Record it, and fix it in a separate plan.

## Units, if D11 to D14 are (a)

Each unit gets its own commit on local `main`. No unit pushes, calls a paid
model, or re-records the corpus. Sonnet implements U1 to U4. Opus reviews each
diff and runs each acceptance check again with an empty `ZIG_LOCAL_CACHE_DIR`.
The budgets are estimates, not measurements. An implementer at its budget
stops and hands back its status.

### U1: Refuse a change set when the policy file does not parse

- Model: Sonnet. Turn budget: 30.
- Files: `packages/pi/src/aggregate_proof.zig` and its tests.
- Change: when a policy is configured and the candidate's policy source does
  not parse, `prove` rejects with `policy_context_failed`. The message names
  the policy file and the parse error. A baseline with a broken policy gets
  the same rejection, so the developer sees it before any change applies.
- Test first: a workspace with a policy that forbids an env read, and a
  candidate that reads it. With a valid policy the candidate is rejected
  today. With the same policy plus a syntax error, the candidate is accepted
  today. Record that failure in the commit message. After the change, the
  candidate is rejected with the exact message.
- Acceptance: unfiltered `zig build test` and
  `env -u DEEPSEEK_API_KEY zig build test-expert-app`. The second step replays
  the corpus and must pass with no cassette change.

### U2: Required properties in `zttp.json`

- Model: Sonnet. Turn budget: 45.
- Files: `packages/tools/src/project_config.zig` (the key),
  `packages/pi/src/aggregate_proof.zig` (`discoverConsistentContext` reads
  `zttp.json` from the snapshot and already fills `policy_relative`; the
  rejection goes in `prove`), the tests beside them,
  `packages/pi/src/repl.zig` (fixtures), `docs/decisions.md` (a new D-020),
  and `docs/user-guide.md`.
- Format: `"requiredProperties": ["state_isolated", "cost_bounded"]`. Each
  name must be in `v1_spec_names`. Reach that list through the curated
  surface of `packages/zts/src/root.zig`. If pi needs a new export, add it
  there and run `zig build test-module-boundary`.
- Rejection: after the diagnostic comparison, `prove` rejects with
  `required_property_lost` when the candidate does not prove a required
  property. The message names each missing property and says that
  `zttp.json` requires it. It also rejects when `primary_properties` is null
  and the key is present, and when a name is not in `v1_spec_names`. The
  message for an unknown name gives the nearest valid name.
- Effect to state in the docs: when the baseline already lacks a required
  property, every change set is rejected until a candidate proves it again, or
  the developer removes the name.
- Tests first, with literal expected text:
  1. An expert turn through `runCardTurn`, with the recursive candidate of
     finding 2 and `"requiredProperties": ["cost_bounded"]`: the change set is
     rejected, no card is shown, no question is asked, and the handler source
     is unchanged.
  2. The same turn with the auto-approve policy of `--yes`: the change set is
     rejected and the source is unchanged.
  3. A candidate that keeps `cost_bounded`: the change set is accepted.
  4. A baseline that already lacks `cost_bounded`, and a candidate that still
     lacks it: rejected.
  5. An unknown name: rejected with the nearest-name message.
  6. A census over `v1_spec_names`: the key accepts each name.
  `runCardTurn` needs a way to write `zttp.json` and to select the approval
  policy. Add the smallest fields to `CardTurnSpec`.
- Acceptance: unfiltered `zig build test`, `zig build test-cli`, and
  `env -u DEEPSEEK_API_KEY zig build test-expert-app` with no cassette change.
  `scripts/check-meta-drift.sh` passes.

### U3: The `/contract` card

- Model: Sonnet. Turn budget: 45.
- Files: `packages/pi/src/repl.zig`, one small writer for `zttp.json` in
  `packages/pi/src/`, and the tests beside them.
- `/contract` prints a card for the current workspace: the routes, the proven
  properties, the required properties, any required property that is not
  proven, the env reads, and the egress endpoints. It reads them from the same
  check that the veto runs. A proven property is a name in `v1_spec_names`
  whose field in `HandlerProperties` is true. Then the card asks
  `Require the proven properties? [y/N]`.
- On `y`, the host writes the union of the required and the proven properties
  to `requiredProperties`. It never drops a required property.
- `/contract drop <name>` removes one name.
- The writer parses `zttp.json` as a raw JSON object, changes the one key,
  and writes the object back with two-space indentation. The order of the
  keys and every unknown key stay. It writes to a temporary name and renames
  it, under `RecoveredWorkspace.acquire`
  (`packages/pi/src/change_transaction.zig`). If the lock is held or
  `zttp.json` does not parse, it prints the reason and writes nothing.
- The command adds no entry to the model transcript.
- Tests through `ReplStdio`, with stdout and stderr captured and literal
  expected text: the card of a `zttp init` project; the exact `zttp.json`
  after `y`, with an unknown key kept in place; the file after
  `/contract drop`; the parse-error path; the held-lock path. Then the turn of
  U2 test 1, run after `/contract` and `y`, is rejected.
- Acceptance: unfiltered `zig build test`,
  `env -u DEEPSEEK_API_KEY zig build test-expert-app` with no cassette change,
  and `zig build smoke-v1`.

### U4: Documentation

- Model: Sonnet. Turn budget: 15.
- Files: `docs/user-guide.md`, `CHANGELOG.md` (`[Unreleased]`: the pin under
  "Added", the U1 fix under "Fixed"), and `../ZTTP-WEBSITE`, as `AGENTS.md`
  requires for a feature.
- The website states the behavior that U2 and U3 checked. It says that the
  feature is in development and not released. Run `deno task verify` there,
  and commit locally.

### U5: Closing validation

- Owner of the work: Opus.
- A Fable subagent and Codex astra review the diff of U1 to U3 with split
  briefs.
- Mutants, each run against the unfiltered step:
  - U1: the parse failure is ignored again;
  - U2: the rejection is skipped;
  - U2: the rejection compares with the baseline, so a lost pin stays lost;
  - U2: a null `primary_properties` passes;
  - U2: an unknown name passes;
  - U3: `y` writes the proven set and drops a required property;
  - U3: the writer drops an unknown key.
  Each mutant must fail a test.
- Final gate: `env -u DEEPSEEK_API_KEY bash scripts/verify.sh`, then
  `zig build bench-check` with the load stated.

## Measurement

Steps to pin: two, the command `/contract` and the key `y`. The goal holds when
every change set whose candidate does not prove a pinned property is rejected.
U2 tests 1 and 2 check that for the interactive and the `--yes` modes. How
often developers pin, and how often a pin rejects a change set, needs
measurement after a release.

## Out of scope

The model proposal before code (D11 (b)), example rows (D13 (b)), pinning env
and egress (D12 (b)), the pin in `zttp check`, `zttp dev`, `zttp build`, and
`zttp deploy`, and a release.

## Decision D15: execution

- (a) Run U1 to U5 on local `main` with one commit for each unit, no push, no
  paid model call, and no re-record. Recommended.
- (b) Stop after this plan.
