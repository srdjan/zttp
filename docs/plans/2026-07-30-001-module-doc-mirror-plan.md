# Generate the module documentation mirror

**Status:** planned.

**Source:** the remaining sub-clause of wave 4 item 0b, left open by B3
(`docs/plans/2026-07-29-005-reset-b3-module-spec-render-plan.md`). Item 0b asks for the
module spec JSON AND the documentation mirrors to be generated from the typed bindings. B3
did the JSON.

**Goal:** Generate the Module Catalog table in `docs/virtual-modules/README.md` from the
bindings, gated by the same `--check` that already guards the JSON.

**Ground truth:** measured at commit `1907397d` on 2026-07-30.

## 1. What is generatable and what is not

`docs/virtual-modules/README.md` is 105 lines. Exactly one region derives from the bindings:
the Module Catalog table at lines 11-36, which repeats each module's specifier, its export
names, and its required capabilities.

Everything else is real prose that no binding contains and none should: the usage example,
the Runtime Requirements table (operational flags like `--sqlite` and `--outbound-http`), the
Effects explanation, the `fetchWithRetry` bounds, and the Type-Only Imports section.

So this generates a managed region, not a file. Generating the whole document would either
lose that prose or require inventing binding fields to hold it, which is the mistake B3's
section 2 warns about in the other direction.

## 2. Design

One verb, not two. `module-spec-render` already renders from
`builtin_modules.builtin_governance_entries`; it gains the catalog table as a second
artifact. Both the 24 JSON files and the README region are the same data through the same
generator, so they get one command and one gate step. A second verb would double the CLI
surface for one table.

The managed region is delimited by HTML comment markers, so the boundary is visible to
anyone editing the file:

```markdown
<!-- BEGIN GENERATED: module catalog. Edit the Zig bindings, then run `zttp module-spec-render`. -->
| Module | Exports | Capabilities |
...
<!-- END GENERATED: module catalog -->
```

Row order is alphabetical by specifier, which is what the file already uses. Note this
differs from the JSON specs, which follow `builtins` registration order, because each
artifact keeps the order it already had. Within a row, export and capability order is
binding order, also matching the current file.

Empty capabilities render as `none`, matching the current file, rather than as an empty cell.

## 3. Why this is low risk

`scripts/check-docs-drift.sh` already cross-checks this table against the JSON specs, and its
`canonical_csv` helper sorts and strips before comparing (`check-docs-drift.sh:32-38`). Row
order and cell order therefore cannot break it. The script keeps its module section, per
section 8 of the Reset B design: it is now a second, independent mechanism that reaches the
bindings transitively through the generated JSON, and it is cheap.

## 4. Tasks

### Task 1: render the catalog and manage the region

Add `renderModuleCatalogTable` to `packages/zts/src/module_spec_render.zig`, and extend
`module_spec_cli.zig` to splice it into the marked region on write and compare it on
`--check`. Add the markers to the README.

**Verify:** the generated table is byte-identical to the current lines 11-36, which is
achievable here because this table has not drifted; `module-spec-render --check` exits 0;
`bash scripts/check-docs-drift.sh` exits 0; a deliberate mutation inside the region makes
`--check` exit 1 and name the README.

Byte-identity IS the acceptance test this time, unlike B3. If the table has drifted, that is
a finding to record, not a reason to lower the bar.

**Commit:** `feat(modules): generate the module catalog table from the bindings`.

### Task 2: record the result

Fill in section 5, and update the B3 plan's status note and the Reset B design doc, both of
which currently say this sub-clause is open.

**Commit:** `docs(plans): close wave 4 item 0b`.

## 5. Findings

To be filled in during execution.

| # | Finding | Resolution |
| --- | --- | --- |

## 6. Done when

- The catalog table is generated, and `module-spec-render --check` covers it.
- The check has been observed failing on a deliberate mutation inside the region.
- `bash scripts/verify.sh` exits 0 and `zig fmt --check` is clean.
- Wave 4 item 0b is closed, and the two documents that say otherwise are updated.
