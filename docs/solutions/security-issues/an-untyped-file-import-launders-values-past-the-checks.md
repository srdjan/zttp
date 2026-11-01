---
title: An untyped file import launders a value past every check
date: 2026-11-01
category: security-issues
module: packages/zts/src/type_checker.zig (file-import typing on the compile path)
problem_type: security_issue
component: compiler
symptoms:
  - "`pick(env(\"X\"))` with a generic `pick` from a dependency compiled and read `.length`. The same-file form reports ZTS309."
  - "`for (const r of wrap([\"a\"])) { return r; }` compiled a string return from a handler that declares `Response`."
  - A rule that refused only a request-root `return` of an imported value passed its tests and left both shapes open.
root_cause: missing_validation
resolution_type: code_fix
severity: high
related_components:
  - handler_verifier
  - type_checker
  - module_graph
tags:
  - zts
  - file-imports
  - module-graph
  - fail-open
  - laundering
  - type-checker
applies_when:
  - "Extending a check to a value that crosses a file, including unit G8 of the module graph certificates plan"
  - "A checker skips a value because its type is unknown"
  - "A plan proposes a narrow rule for one position of an unknown value"
---

# An untyped file import launders a value past every check

## Problem

A file import had no type in the importer, and the checkers skip a value of unknown type. So an unknown binding did not fail a check. It turned the check off for each value that passed through it.

## Symptoms

The module graph certificates plan held a fallback for this gap. The fallback left an import unknown when its type could not cross, and refused only a request-root `return` of that import. The first implementation of unit G2b used that fallback, and its tests passed.

Review found two shapes that the rule missed. A generic export returned its argument unchanged, so `pick(env("X"))` compiled and read `.length`. The same code in one file reports ZTS309. A `for` loop over a generic `wrap(["a"])` returned a string from a handler that declares `Response`.

## What Didn't Work

The first rework tried to walk values that derive from an unknown import, in `handler_verifier.zig`. An unknown value reaches too many positions for a walk: a return, a member read, a loop variable, a call argument, and a binding that holds any of these. Each position needed its own rule, and a missed position was silent. That walk was removed.

## Solution

No unknown file import reaches the checks. A data export gets its declared or inferred type. Any other file import with no type refuses the build, whether the module uses the import or not. `TypeChecker.firstUntypedFileImport` names the binding, and `checkGraphModule` in `packages/tools/src/precompile.zig` returns `error.FileImportUntyped`:

```text
h.ts: import 'pick' has no type that can cross modules. Export a non-generic function or a value with a declared type.
```

A generic export, a type predicate, a recursive alias, and a type that does not copy all reach this refusal.

## Why This Works

An unknown type means that the checker has no answer, and the checkers read that as nothing to report. A refusal at the binding removes the unknown value before any position can read it, so the number of positions stops mattering. The rule costs some valid programs, and it can widen later: for example, when generic signatures can cross type stores.

## Prevention

Refuse at the source of an unknown value. Do not add a rule for one position of it. A rule that covers one position passes its own test and says nothing about the other positions.

Test a new cross-file rule with a value that passes through a generic function and a loop, not only with a direct return.

Unit G8 ports this work to `zttp check`, which still types no file import, so G8 must take this rule and not the fallback in the plan. The fallback text stays in the plan as history, and the worklog section `## G2b` records why it failed.
