# Semantics Verification

The semantics registry records the meaning of each IR node and each bytecode
opcode. `zttp spec-check` (equally `zts spec-check`) checks that registry
against the IR and bytecode tables. This document describes the five
mechanisms, the SMT layer, the exclusion audit, and the generated artifacts
that ride on the same registry.

Source: `packages/zts/src/semantics.zig` holds the registry,
`packages/zts/src/semantics_check.zig` interprets it, and
`packages/tools/src/semantics_cli.zig` is the command layer.

## The Five Mechanisms

`semantics_check.zig` runs five mechanisms, ordered from weakest but total to
strongest but scoped.

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
5. **SMT equivalence.** `z3` proves that each obligation holds on all inputs.
   The obligations are every value node's `denote == exec(lower)`, which makes
   mechanism 5 a superset of mechanism 3 for value rules, plus the fused-opcode
   refinements and the registry's asserted algebraic laws.

The registry currently asserts no algebraic laws. Every tempting equivalence,
`neg` involution included, sits in `excluded_laws` instead, so the receipt
never over-claims a law the faithful model refutes.

## The SMT Layer

`packages/zts/src/semantics_smt.zig` is the pure encoder. It encodes each
equivalence obligation into an SMT-LIB2 query whose negation is put to the
solver: `unsat` means equivalent, `sat` gives a counterexample.

It encodes numbers as unbounded mathematical integers, which is an abstraction
of the engine's i32 numbers promoting to f64. The law table must therefore only
assert laws that hold under the engine's value model, not merely over the
integers. Three are deliberately excluded for this reason:

- associativity of `+`, which fails on f64 rounding,
- commutativity of `+`, which fails on string concatenation,
- `!` involution, which fails on truthiness coercion.

The solver is injected from `packages/tools/src/smt_solver.zig`, so
`std.process.Child` never enters the wasm analyzer build.

Only two conditions fail the build: a genuine counterexample (`ZTS755`) and an
ill-typed obligation (`ZTS756`). An absent, broken, or undecided solver is a
non-fatal "unproven", so CI without `z3` stays green.

Solver selection:

```bash
ZTTP_Z3=off            # opt out
ZTTP_Z3=/path/to/z3    # pin the binary
```

## The Exclusion Audit

`packages/zts/src/semantics_audit.zig` is the dual of mechanism 5. It
machine-refutes the declared `excluded_laws` (associativity and commutativity
of `+`, and involution of `!` and unary `-`) over a faithful tagged
number, bool, or string value model with JS coercion.

Each excluded law must yield a counterexample (`sat`). If an excluded law
actually holds (`unsat`), the build fails with `ZTS757`. If `z3` cannot
evaluate the model, the build fails with `ZTS758`. A timeout is inconclusive
and non-fatal at the command level, so a future law that cannot be refuted
cannot wedge plain `spec-check --audit`.

The audit is opt-in through `spec-check --audit` because its f64 associativity
refutation is slow. Interactive `spec-check` stays fast.

## The Release Gate

`scripts/verify.sh` runs `scripts/check-semantics-spec.sh`, which is stricter
than the command. It re-reads the `--json` summary and requires a complete
audit: `z3` present, every excluded law refuted, and zero inconclusive results.
A silent `z3`-absent skip or a timeout therefore cannot pass the gate with
false confidence. An explicit `ZTTP_Z3` opt-out (`off`, `none`, `0`, or
`disable`) is honored as an intentional skip and reported as such.

## Generated Artifacts

`spec-hash` prints the registry hash for CI assertions, the way
`describe-rule --hash` prints the policy hash.

`spec-render` renders the registry as a readable TypeScript spec at
`docs/spec/semantics.spec.ts`. `spec-render --check <path>` is the CI drift
gate: 0 when the committed spec matches the registry, 1 when it is stale.

`module-spec-render` applies the same pattern to the virtual-module specs. The
typed Zig bindings in `packages/zts/src/module_binding.zig` are authoritative,
and `packages/modules/module-specs/*.json` is generated from them. That is 24
files, with output paths taken from `builtin_governance_entries`. The command
also owns the Module Catalog table in `docs/virtual-modules/README.md`, a
marked region between `<!-- BEGIN GENERATED: module catalog ... -->` and
`<!-- END GENERATED: module catalog -->`. The rest of that file is hand-written
prose.

`module-spec-render --check` gates all 25 artifacts in `scripts/verify.sh` and
reports every stale path. A missing region marker is exit 2 rather than a skip.

Do not hand-edit the JSON files or that table. Edit the binding and regenerate.

## Exit Codes

`spec-check` returns 0 when the registry conforms, 1 on a divergence with a
`ZTS75x` counterexample, and 2 on error. See
[CLI Reference](../cli.md#analyzer-commands) for the analyzer surface.
