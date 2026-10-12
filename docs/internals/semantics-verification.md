# Semantics Verification

The semantics registry records the meaning of each IR node and each bytecode
opcode. `zttp spec-check` (equally `zts spec-check`) checks that registry
against the IR and bytecode tables. This document describes the four
mechanisms, the declared soundness boundary, and the generated artifacts that
ride on the same registry.

Source: `packages/zts/src/semantics.zig` holds the registry,
`packages/zts/src/semantics_check.zig` interprets it, and
`packages/tools/src/semantics_cli.zig` is the command layer.

## The Four Mechanisms

`semantics_check.zig` and `semantics_corpus.zig` run four mechanisms, ordered
from weakest but total to strongest but scoped.

1. **Table coverage.** The IR and bytecode alphabet size is pinned at comptime.
   The drift gate lives in `semantics.zig` and is reported by the check.
2. **Stack effect.** Every value lowering must net exactly one stack value,
   measured against the `bytecode.getOpcodeInfo` arity table. Any opcode
   outside the symbolic registry fails loud.
3. **Symbolic lowering.** `exec(lower(node))` must equal `denote(node)`, proven
   by structural equality of RPN denotations. This includes the refinement
   check: a fused opcode must equal its base sequence.
4. **Differential corpus.** The registry's denotations run against the real
   compiler over a corpus (`packages/zts/src/semantics_corpus.zig`). This
   closes the gap mechanism 3 cannot see, that the declared lowering matches
   what codegen actually emits.

The registry currently asserts no algebraic laws. Every tempting equivalence,
`neg` involution included, sits in `excluded_laws` instead, so the registry
never over-claims a law the engine's value model refutes.

## The Soundness Boundary

The registry declares four excluded laws. Each one holds over unbounded
mathematical integers and fails on the engine's value model:

- associativity of `+`, which fails on f64 rounding past 2^53,
- commutativity of `+`, which fails on string concatenation,
- involution of `!`, which fails on truthiness coercion,
- involution of unary `-`, which fails on number coercion.

`excluded_laws` and each row's `audit_timeout_ms` stay in `semantics.zig` as
data. They are hashed into `semanticsHash` and rendered into the spec. No code
checks them against a solver any more. An earlier SMT layer proved the value
rules with `z3` and refuted the excluded laws over a faithful value model. That
layer, with its `--audit` flag and the `ZTTP_Z3` variable, was removed in plan
005. The code lives at the `pre-rebase` tag as
`pre-rebase:packages/zts/src/semantics_smt.zig`,
`pre-rebase:packages/zts/src/semantics_audit.zig`, and
`pre-rebase:packages/tools/src/smt_solver.zig`.

The diagnostic codes `ZTS755` to `ZTS760` named failures of that layer. They
remain in the catalog because removing them would change the diagnostic hash.
No producer emits them now.

## The Release Gate

`scripts/verify.sh` runs `scripts/check-semantics-spec.sh`. The script runs
`zts spec-check` and `zts spec-render --check docs/spec/semantics.spec.ts`. It
fails when either command fails. No external solver is required.

## Generated Artifacts

`spec-hash` prints the registry hash for CI assertions, the way
`describe-rule --hash` prints the policy hash.

`spec-render` renders the registry as a readable TypeScript spec at
`docs/spec/semantics.spec.ts`. `spec-render --check <path>` is the CI drift
gate: 0 when the committed spec matches the registry, 1 when it is stale.

`module-spec-render` applies the same pattern to the virtual-module specs. The
typed Zig bindings in `packages/zts/src/module_binding.zig` are authoritative,
and `packages/modules/module-specs/*.json` is generated from them. That is 26
files, with output paths taken from `builtin_governance_entries`. The command
also owns the Module Catalog table in `docs/virtual-modules/README.md`, a
marked region between `<!-- BEGIN GENERATED: module catalog ... -->` and
`<!-- END GENERATED: module catalog -->`. The rest of that file is hand-written
prose.

`module-spec-render --check` gates all 27 artifacts in `scripts/verify.sh` and
reports every stale path: the 26 JSON specs plus the catalog table. A missing
region marker is exit 2 rather than a skip.

Do not hand-edit the JSON files or that table. Edit the binding and regenerate.

## Exit Codes

`spec-check` returns 0 when the registry conforms, 1 on a divergence, and 2 on
error. See [CLI Reference](../cli.md#analyzer-commands) for the analyzer
surface.
