---
title: A missing import entry was conservative for one proof and clean for another
date: 2026-10-10
category: security-issues
module: ZigTS fault coverage, imported-file scan
problem_type: security_issue
component: tooling
severity: high
symptoms:
  - "`zts check` reported `fault_covered` true for a handler that called an imported helper with an unchecked `fetch`."
  - "A handler that imported a sibling file that did not exist, or a bare package such as `lodash`, also proved `fault_covered`, with no diagnostic for the import."
  - "The planned fix copied the flow checker's sibling-file collector, which is correct for the flow checker, so a code review of the copy would not show the hole."
root_cause: logic_error
resolution_type: code_fix
related_components:
  - documentation
  - testing_framework
tags:
  - zts
  - fault-coverage
  - fail-open
  - soundness
  - imports
  - cross-file
  - proof-boundary
---

# A missing import entry was conservative for one proof and clean for another

## Problem

The fault-coverage scan read only the handler file. Plan R4 (`docs/plans/2026-10-09-fault-coverage-follow-ups.md`, unit F2) extended it to imported files. The first design reused the shape of the flow checker's sibling-file collector. That shape omits an entry when it cannot answer. For the flow checker an omission is conservative; for fault coverage it reads as "scanned, nothing failable", so the property was proven on files that nobody scanned.

## Symptoms

- A handler with a checked `fetch` that also called an imported helper with an unchecked `fetch` proved `fault_covered`.
- An import of a missing sibling file, or of a bare specifier such as `lodash`, gave no diagnostic and left `fault_covered` true.
- The wasm analyzer has no filesystem. A literal copy of the collector returns an empty list there, so every relative import would also have proved clean.

## What Didn't Work

- **Copying the existing collector.** `collectImportedFnSummaries` (now `collectImportedAnalyses` in `packages/tools/src/precompile_imports.zig`) returns an empty list on a freestanding build (`packages/tools/src/precompile_imports.zig`). It skips a resolve failure with `continue` (`packages/tools/src/precompile_imports.zig`), and it skips a specifier that is not `./` or `../`. Each of these is a safe default for its consumer: a missing summary makes the flow checker treat the call as unresolved, which clears every property the call's sinks decide. The revision-1 plan said only "in the pattern of `collectImportedFnSummaries`". A plan reviewer (Fable) found that the pattern has the opposite polarity for fault coverage. The main session reproduced both wrong trues before any code was written.
- **Guarding only the absent input.** Revision 1 also said "with no input, a relative import counts as one unseen call". That covers a caller that supplies nothing. It does not cover a caller that supplies a list with one record missing, and that list would have been trusted.

## Solution

The scan answers per import record, and absence is never read as clean.

- `collectImportedFailableCalls` (`packages/tools/src/precompile_imports.zig`) returns an optional. A freestanding build returns null (`packages/tools/src/precompile_imports.zig`), never an empty list. For every record that is not a builtin, it gives one entry: `clean`, `failable` with the first call, or `blocked` with a reason. A bare specifier, a partner module, an unreadable or unparsable file, and a chain deeper than `max_import_depth` are blocked.
- A sibling is scanned as a whole file, and its own imports are scanned in turn. The visited set is seeded with the handler's own path (`packages/tools/src/precompile_imports.zig`), so a cycle back through the handler stops without listing the handler's sites again. A file that is already on the walk returns `.clean` (`packages/tools/src/precompile_imports.zig`), because the frame that opened it already scanned its own calls and stops at the first failable one.
- `PathGenerator.scanImportRecords` (`packages/zts/src/path_generator.zig`) cross-checks the input against the handler's own import facts by slot. Only an explicit `.clean` entry is skipped (`packages/zts/src/path_generator.zig`). A record with no entry, a null input, a blocked entry, and a failable entry each count as one unseen call at the import line, which blocks `fault_covered`. A partner record always counts (`packages/zts/src/path_generator.zig`), whatever the input says.

The rule became plan constraint K5: every non-builtin import record must have an entry, and a record with no entry counts as unseen.

## Why This Works

The polarity lives in the consumer, not in the helper. The same "no entry" means "unknown, so prove nothing" to the flow checker and "nothing found, so proven" to fault coverage. The fix moves the decision to the consumer that knows its polarity. The generator enumerates the records itself and requires an answer for each one. A producer that drops a record therefore cannot make the property hold, and neither can a producer that returns nothing.

## Prevention

- When you reuse a collector, a summary map, or a default from another analysis, ask what an absent entry means to the new consumer. If absence means "clean" there, the producer must answer every input explicitly, and the consumer must count its own inputs and treat a missing answer as unseen.
- Return an optional for "this caller cannot answer", not an empty collection. An empty collection is a valid answer, so it cannot also mean "no answer".
- Test the omission directly, not only the success cases. These tests pin each shape: `"an import scan that omits one record leaves that record unseen"` and `"no import scan counts a relative import as one unseen call at its import line"` (`path_generator.zig`); `"a sibling helper with an unchecked fetch blocks fault_covered"`, `"a sibling that does not exist blocks fault_covered"`, `"a bare specifier import blocks fault_covered"`, and `"a chain of imports past the depth limit blocks fault_covered"` (`precompile.zig`); `"a partner import is unseen even when an answer calls it clean"` (`path_generator.zig`).
- Name the polarity in the doc comment of each collector. `collectImportedFailableCalls` states that its polarity is the opposite of `collectImportedFnSummaries`.

This is one more instance of the fail-open class that AGENTS.md describes, in which a function returns a value that claims more than it checked. See [empty-label-set-claimed-a-value-was-clean.md](empty-label-set-claimed-a-value-was-clean.md) and [a-module-level-declaration-carried-no-label-so-its-secret-proved-clean.md](a-module-level-declaration-carried-no-label-so-its-secret-proved-clean.md). The new element here is that the helper was correct for its first consumer and became fail-open only when a second consumer reused it.
