# Native agent spine

The agent spine connects repository rules to the files and gates that those rules govern.
The owner selected native Zig tooling on 2026-10-14.
This installation ports the agent-spine contract without adding a Deno dependency.

## Commands

```sh
zig build brief
zig build brief -- packages/runtime/src/proof_activation.zig
zig build check-spine
zig build check-spine -- --write
zig build test-spine
```

`brief` reports ownership, boundaries, invariants, standing decisions, relevant solution notes, and gates.
The orientation report also names tasks that require explicit user authorization.
The report reads that requirement from `approval`, including tasks that only write local files.

`check-spine` fails when a structural link or task declaration disagrees with the repository.
`--write` updates generated root blocks only after the other checks pass.
`test-spine` runs the native behavior tests and rejection probes without a test filter.
The aggregate test step runs both the installed check and its tests.

## Authorities

[`agents.json`](../../agents.json) holds repository paths, task policy, the runner, and documentation settings.
The live Zig build graph supplies task names, including implicit install and uninstall steps.
The build completes that graph before writing the census file that the native command reads.
The command does not start a nested build or infer tasks from source text.
The workspace kind `zig-build` records this native contract.

[`AGENTS.md`](../../AGENTS.md) holds repository instructions and generated area and gate tables.
Marked area contracts add rules beyond the existing import boundary.
The marker is `<!-- agent-spine: area -->`.
Each area starts with ownership and boundary paragraphs, followed by invariants and binding decision ids.
Each invariant names the gate that supplies its evidence.

[`docs/decisions.md`](../decisions.md) preserves decisions and their reasons.
A standing decision reaches a current tracked path or a marked area citation.
A superseded decision remains in the ledger with reciprocal supersession links.
A product refusal without a behavioral gate uses `Gate: none`.

Solution notes can declare `binds` paths and a `proves` task in frontmatter.
`brief` joins those fields to the file that the agent inspects.
The native checker validates declared bindings and proving tasks.

## Evidence limits

The spine proves structural consistency, rather than semantic relevance or behavior correctness.
The existing behavior suites remain the authority for the behavior named in a contract.
Task effects require source review because Zig tasks do not declare Deno permission flags.
An unclassified, duplicate, or stale task fails the spine check.
A remote write always requires explicit user authorization in the manifest.

`docsPolicy` remains off because the repository keeps product documentation, plans, and historical reports.
Existing documentation gates own their drift and links.
Source-anchor checks remain active independently of `docsPolicy`.
The checker reads complete inline code spans and Markdown link targets.
Compound prose citations still require review because the checker does not parse every citation spelling.
Source citations use a parsed declaration or an accurate file reference.
Historical references retain their revision and do not claim that a removed declaration exists in the current tree.
Fenced code examples remain code, rather than prose citations.

## Canonical gate

[`scripts/verify.sh`](../../scripts/verify.sh) remains the full local gate.
The script runs the aggregate tests and standalone runtime root in separate processes.
The spine does not introduce another aggregate verification command.

[`docs/internals/testing.md`](testing.md) maps the existing test roots and evidence limits.
The [installation plan](../plans/2026-10-14-agent-spine-plan.md) defines the accepted scope.
The [worklog](../plans/2026-10-14-agent-spine-worklog.md) records execution and verification results.
