# Golden diagnostic corpus

Each case pins what the default check reports for one source file. The gate is
`packages/tools/src/diagnostic_corpus_gate.zig`. It runs in `zig build test`
through `zig build test-diagnostic-corpus`.

## Layout

A case is `FAMILY/KIND/NAME.ts` (or `.tsx`) with a sibling `NAME.diag`.

| Directory | Holds |
|---|---|
| `parse/bad/` | a source the front end refuses: the run stops at or before the import check |
| `parse/good/` | a source that exercises a parser rule and passes every stage |
| `check/bad/` | a source that parses and then reports a diagnostic from a later stage |
| `check/good/` | a source with a narrow `Proof<Response, ...>` capsule that passes every stage |

The gate refuses a case filed in the wrong family. It refuses a `good` case
with any diagnostic, a `good` case that skipped a stage, and a `bad` case with
no diagnostic. Every case starts with a `//` comment that says what it proves.
A `good` case needs a narrow capsule, or the check reports ZTS500.

## The `.diag` format

```
stages: strip,parse,imports,boolean,types,strict
{"code":"ZTS205","severity":"warning","message":"...","file":"check/bad/x.ts","line":5,"column":12,"suggestion":"...","repair_intent":null}
```

The first line lists the stages that ran, in pipeline order, joined by commas.
Each later line is one diagnostic, exactly as `zts check --json` writes it
(`json_diagnostics.writeDiagnosticJson`), in the order the check reports them.
The `file` field is the path relative to `tests/corpus/`, so a golden holds no
absolute path. A case with no diagnostic has the stage line only.

A stage is listed when the check performed it, including when it then reported
errors. The stages are `strip`, `parse`, `imports`, `boolean`, `types`,
`strict`, `verifier`, `flow`, `contract`, `policy`, `paths`, `trace`, `spec`,
and `canonical`. `policy` runs only when the caller supplies a policy, and the
gate supplies none. A `good` case must list every stage except `policy`. The
`types` stage runs only when the type environment exists, and `strict` only
when the strict checker exists, which is why the list is pinned.

## Commands

```
zig build test-diagnostic-corpus            # check every case
zig build test-diagnostic-corpus -- NAME    # check cases whose path contains NAME
zig build diagnostic-corpus-write           # rewrite every golden
zig build diagnostic-corpus-write -- NAME   # rewrite matching goldens
```

A filter that matches no case fails. A filtered run is not a verdict on the
corpus. Read each rewritten golden against the case's `//` comment before you
commit it: a golden that pins the wrong diagnostic is worse than none.

## The floor

`minimum_cases` in the gate is the number of committed cases. The gate fails
below it, so deleting a case fails. When you add cases, raise `minimum_cases` to
the count that the gate prints (`N case(s) found`) in the same commit. Never
lower it to make a deletion pass.

## What the gate does not do

The check runs with no policy, no declaration, no SQL schema, and no system
file, so the POL rules and the declaration rules are outside this corpus. It
reads neither `zttp.json` nor `.zttp/witnesses`, and it writes no witness.
