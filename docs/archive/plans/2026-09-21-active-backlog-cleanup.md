# Active backlog cleanup

Status: complete. The user selected milestone 1 on 2026-09-21 after the
codebase and documentation review at `1b0686a1`.

## Scope

Reconcile the roadmap with implemented behavior. Give each remaining work item
a status, dependency, next action, and completion check. Preserve proposals as
proposals. This milestone does not authorize runtime changes, provider runs,
performance work, or the later proposed milestones.

Archive completed and superseded execution records after checking their status
against code and Git history. Keep reference designs and open proposals indexed.
Repair links to moved records, including links inside those records. Classify
the documents under `docs/zttp-next/` and correct the contributor test guidance.

## Verification and delivery

Review all substantive edits and file moves. Run the documentation drift and
link gates without test filters. Check remaining references to old paths and
confirm every retained plan has an index entry. No source behavior changes, so
the full runtime and release suites are outside this milestone.

Commit each complete documentation unit on local `main`. Do not push. Record
the observed checks here and move this completed record to the archive.

## Completion record

The roadmap now separates delivered behavior, open work, and proposals. Each
remaining item states its status, dependency, next action, and completion
evidence. Only M1 was selected; M2 through M4 remain proposed.

Moved 22 historical execution records and the delivered boundary-type draft
to the archive. Corrected stale guard, invariant, corpus, and compile-time
parser status claims. Preserved the reset's remaining questions and the ledger
startup measurement in the roadmap. D1, D2, and D3 remain design references;
the custom agent-handler specification remains proposed. New indexes classify
all retained plans and product proposals.

Independent review found two scope notes to retain: the exported-constant and
generic boundary-type questions, and the reset's default to keep working
features. Both are now explicit in the roadmap. No bypass or new deletion is
claimed by this documentation change.

Contributor guidance and the PR checklist now agree with aggregate example
coverage and name verifier prerequisites. This unit is committed as
`eb91262c`.

The unfiltered `zig build test-docs-drift test-doc-links -j1 --summary all`
run exited 0 with all seven build steps successful. A separate reference check
found no remaining mentions of the 23 moved paths. Exact before/after
comparison confirmed that all 21 changed files under `packages/` and `scripts/`
contain only documentation-path replacements. The retained-plan census had
non-empty input and found an index entry for every plan.

No runtime behavior changed. The full runtime and release suites, provider
recordings, and benchmarks were not run for this documentation milestone.
