# Zig agent spine

Status: execution authorized on 2026-10-14.

## Objective

Connect repository authorities, area ownership, binding decisions, solution notes, and verification gates through native Zig tooling.
The user selected Option A after the agent-spine audit.
Option A preserves the requirement for Zig tooling and replaces the skill's Deno implementation with a native port.

## Settled constraints

Work directly on local `main`. Commit each complete unit and never push.
Preserve runtime behavior, analyzer behavior, and existing gate ownership.
Keep repository policy in `agents.json`, rather than constants in the command.
Do not add Python or Deno tooling.
Keep the full local gate in `scripts/verify.sh` sequential.
Seek approval before a script expected to exceed two minutes.
Keep measured durations absent until measured.

## Implementation units

1. Add the native spine command and its behavior tests under `tooling/`.
2. Add `agents.json`, the decision ledger, area contracts, and selected solution bindings.
3. Replace source line anchors with declarations or accurate file references.
4. Connect the command and gate to the live build graph, generate root blocks, and complete verification.

These units share one installation contract. Each complete unit receives its own commit after the relevant checks pass.
The documentation migration remains separate from the native command where that boundary permits a meaningful commit.

## Native command contract

`zig build brief -- <path>` reports the governing root authority, nearest marked area, invariants, decisions, notes, and gates.
Without a path, `brief` reports orientation and tasks that require explicit user authorization.
`zig build check-spine` checks the installed spine without writing.
`zig build check-spine -- --write` regenerates root blocks only after every other check passes.
`zig build test-spine` runs behavior tests and executable rejection probes.
The aggregate `test` step runs both the installed check and its tests.

The build passes a newline-delimited task census from `b.top_level_steps` after all steps exist.
The census includes implicit install and uninstall steps.
The gate does not parse source spellings or launch a nested build.
The manifest declares `runner: zig build` and a workspace with `kind: zig-build`.
That workspace kind documents the native port's graph census instead of a source regular expression.

The command checks both directions of task classification, including duplicates and stale rows.
Task intent is verify, build, run, measure, or operate.
Task effect is none, local-write, remote-read, or remote-write.
Approval is none or explicit-user.
Every remote-write declaration requires explicit-user approval, independent of runner permissions.
Zig tasks have no Deno permission flags, so effect reach remains a source-review responsibility.

## Structural checks

The gate requires a workspace, marked area, task, verify command, decision, and existing Git-tracked path.
A failed or empty Git census fails the gate.
An area has two opening paragraphs, bold invariant leads, binding decisions, and valid enforcing tasks.
An area contains no more than 80 lines.
Each invariant names a gate, and the gate report states structural evidence limits.

The ledger validates ascending unique ids, dates, statuses, bindings, reasons, tasks, and reciprocal supersession links.
A standing decision must reach an existing tracked path or a marked area citation.
A superseded decision remains historical and does not need a live binding.
A binding can use an exact path, directory, or glob, with optional leading `./`.

Solution-note bindings resolve to current paths. Their declared proving tasks must exist.
The native port leaves `docsPolicy` off because existing documentation has its own ownership and drift checks.
The gate checks source anchors independently of that setting.
Zig anchors use parsed declarations rather than regex matches in comments or strings.
The anchor check rejects numeric line and range anchors in inline code and Markdown links.
Historical file references retain their Git revision and do not claim a current declaration.

Generated blocks use `<!-- generated: areas -->` and `<!-- generated: gates -->`, with matching end markers.
Missing, duplicated, reversed, or incomplete markers fail the gate.
The comparison tolerates table whitespace and separator formatting.
The writer leaves the root file unchanged when any preceding check fails.

## Anchor migration

A migration preserves surrounding facts and historical meaning.
The migration uses the enclosing declaration only when source and context support that declaration.
A stale or removed declaration becomes an accurate file reference when no reliable symbol can be recovered.
A historical source reference retains its Git revision.
The migration does not invent current symbols from old line numbers.
The reviewer reads every changed line and checks the chosen targets.

## Verification

Start with a small executable fixture, then run the installed command against the repository.
The fixture validates the entire clean, mutated, and restored pipeline before repository scale changes.
Every rejection probe asserts exit codes 0, 1, and 0, then the exact relevant rejection message.
The rejection census covers every verdict enum member or states a mechanism in an explicit exception row.
Tests use the public command contract and lightweight temporary files.

Required checks include unfiltered `zig build test-spine`, `zig build check-spine`, and a navigation drill.
The drill starts from `brief` and reaches the authority, owner, invariant, and decisive gate within three hops.
Build wiring checks include `test-step-coverage`, `test-script-reachability`, documentation checks, and `release-check`.
After a small pipeline check, the final canonical gate is `bash scripts/verify.sh`.
The user must authorize that script before execution because its recorded runtime exceeds two minutes.
The main agent reviews delegated diffs and runs authoritative checks.

## Completion

The installed spine passes its own checks and the canonical gate.
Navigation reports usable links for files in the selected areas.
No copied Deno scripts, temporary migration command, or audit output enters Git.
The worklog records exact check results and remaining evidence limits.
Next action owner: I will execute the accepted native installation.
