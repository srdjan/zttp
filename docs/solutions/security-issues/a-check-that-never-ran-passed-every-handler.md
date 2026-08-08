---
title: A check that never ran passed every handler
date: 2026-08-09
category: security-issues
module: ZigTS type pool assignability
problem_type: logic_error
component: tooling
severity: high
symptoms:
  - "Every handler in the repository passed its return-type check, because `Response.json(...)` inferred no type and the check skips when either side is absent."
  - "`function getOne(): Todo` checked and `function getTodos(): Todo[]` did not - the same name resolved at the top level of a type and not inside an array."
  - "A deferral comment named three blockers, two of which were wrong, and had read as current for four days after one of them landed."
  - "A test fixture called `parseBearer(req)` where the export takes a header string, and no gate saw it."
root_cause: logic_error
resolution_type: code_fix
related_components:
  - documentation
  - testing_framework
tags:
  - zts
  - type-checker
  - assignability
  - soundness
  - fail-open
  - proof-boundary
  - compiler-analysis
---

# A check that never ran passed every handler

## Problem

`TypePool.assignableStep` ended with two lines that answered `true` whenever
either side was a `t_ref` or a `t_generic_param`:

```zig
if (src_tag == .t_ref or src_tag == .t_generic_param) return true;
if (tgt_tag == .t_ref or tgt_tag == .t_generic_param) return true;
```

The pool holds no alias table, so it cannot resolve a name. Answering `true`
because it could not look is the fail-open D1 amendment A1 exists to delete, and
it had been deferred with a measurement: seven examples fail when the lines go.

That measurement was correct and its explanation was not, in a way that made the
work look like it belonged to a later phase. The comment said closing A1 needed
the ABI types and the durable and queue exports retyped. Deleting the lines and
sweeping every example found seven failures with three distinct causes, and the
one the comment named was the smallest part of the fix.

## Symptoms

The seven failures all read `return type does not match declared return type`,
which is one message for three different defects. Separating them needed a
minimal probe per failure rather than a reading of the diagnostic.

```ts
// 1. Six: durable.run returns the coarse `unknown`, assignable to nothing.
return run(key, () => Response.json({ ok: true }));

// 2. One: a name nested in a compound type never resolved.
type Todo = { text: string; done: boolean };
function getOne(): Todo { return { text: "a", done: true }; }    // checked
function getTodos(): Todo[] { return [{ text: "a", done: true }]; }  // did not
```

The third cause had no failure of its own, because it is the absence of a check.
`Response.json(...)` inferred nothing, and the return check compares nothing when
either side is `null_type_idx`:

```zig
const inferred = self.inferType(ret_val);
if (inferred != null_type_idx and !self.env.isAssignableTo(inferred, self.current_return_type)) {
```

So every handler in the repository had been passing its return check by never
running it. Nothing reported that. A skipped check and a passed check produce the
same output.

## Root cause

Three, and they compound. The nested-name one is the pool's ignorance of aliases:
`TypeEnv.isAssignableTo` resolved at the top level and then handed two indices to
a pool that could not resolve anything further, so `Todo` in return position
worked and `Todo` inside `Todo[]` did not. The `durable.run` one is that
`ReturnKind` names a fixed type and `run`'s return type is its callback's, so
`unknown` was the only thing the binding could say. The third is that nothing
gave the `Response` global a type, and the two ABI names are not declared
anywhere in `TypeEnv`.

The fail-open made all three invisible in the same way: an unresolved name
answered yes, so a comparison that could not be made and a comparison that
succeeded were indistinguishable at the call site and in the output.

## Resolution

- `TypePool.RefResolver` on `AssignCtx`, supplied by `TypeEnv`, so a name inside
  an array, a record field, or a function's return type resolves during the
  comparison. A name the resolver does not know stays unresolved, so A1 still
  refuses it.
- `FunctionBinding.returns_from_param`, in the two shapes that occur:
  `call_result` for `run(key, fn: () => T) -> T` and `identity` for
  `using(resource, close) -> resource`. Four exports declare it. The checker
  builds a one-parameter generic signature and infers it per call site, which
  needed `inferType` to answer something for a function expression argument -
  it answers `null_type_idx`, since the rest of the checker reaches a function
  through its recorded signature and a callback at a call site has no name to
  look up.
- `abi_types.zig` types the `Response` global from the fields `http.zig` sets on
  a constructed response, with the four constructors recognized on the global the
  way `Array.isArray` already is.

Two more fell out. A generic call whose parameters could not be bound reported
every argument a second time, because a type variable is now assignable to
nothing; `checkCallArgs` stops after reporting the call. And two `precompile`
fixtures called `parseBearer(req)` where the export takes a header string, so
`decodeArgs(&.{.string})` would have returned undefined at runtime. The
fail-open had been holding up a broken fixture.

## Prevention

**A deferral comment ages into a false one.** This site claimed inference did not
exist for four days after it landed, and nobody re-ran the experiment because the
comment read as current. The re-measurement that found the three causes was
prompted by the comment's own date, not by its content. Date a deferral, and
re-measure before quoting it.

**One diagnostic is not one defect.** Seven failures carrying the same message
looked like one blocker. They were three, and the largest of them - the check
that had never run - produced no failure at all, so counting failures would never
have found it. What separated them was a minimal probe per failure: strip the
example down until only the failing construct is left, then vary one thing.
`getOne` against `getTodos` is the whole diagnosis of the second cause.

**A skipped check and a passed check look identical.** The return check was
guarded on both sides being present, and the guard is correct - comparing against
an absent type would be noise. What was missing is that nothing ever asked how
often the guard fired. A check whose inputs can be absent should be able to
report how many times it declined to run, or a fixture should pin one case where
it must.

**Removing a fail-open is how you find what it was hiding.** None of the three
causes was reachable by reading the code. Each surfaced by deleting the two lines
and sweeping, which is the same method that found the flow-checker family in
[empty-label-set-claimed-a-value-was-clean](empty-label-set-claimed-a-value-was-clean.md).
The fixture that would obviously have caught the nested-name case does not exist,
and would have had to be written by someone who already knew names nest.
