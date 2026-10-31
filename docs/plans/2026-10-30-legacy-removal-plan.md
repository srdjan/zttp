# Legacy removal plan, 2026-10-30

## Authority and status

This document is the plan authority for the removal of legacy code.
It owns the definition of legacy, the verdict for each item, the phase order, the verification, and the owner decisions.
The worklog `docs/plans/2026-10-30-legacy-removal-worklog.md` records execution and evidence. Phase L0 creates that worklog.

Status: approved on 2026-10-30. The owner selected option (a) for Decisions 1 to 13. The worklog records the execution.
No push, tag push, provider call, or corpus re-record is authorized by this plan.
This plan edits no file in `packages/proof-checker`.

The [reset plan](2026-10-30-reset-implementation-plan.md) stays the authority for the reset.
This plan takes over reset unit 9e (remove the unproduced `NodeTag` members) and reset unit 9f (remove legacy spellings).
Reset Phases 10 and 11 run after this plan, if the owner selects Decision 13 (a).

## Definition of legacy

Code is legacy when its only reason to exist is a past state of the product: an old writer, an old input form, or an old name.
A documented current feature is not legacy, even when its name says "legacy".
A deliberate refusal of a retired feature is not legacy. The refusal is the current behavior, and its removal would fail open.
An unused function is not legacy only because it is unused. The reset owns that class, and its rules keep exported members.

Each item in this plan has one verdict:

| Verdict | Meaning | Treatment |
|---|---|---|
| LEGACY-DEAD | No current producer, and no tagged release wrote the input. Only a hand-made file can reach it | Remove |
| LEGACY-LIVE | An input reaches it, but no current writer, document, or tracked program needs it | Remove after an owner decision when an output moves |
| LEGACY-DATA | Only data from an older release reaches it | Owner decision, because data can be stranded |
| NOT-LEGACY | A current feature, a deliberate refusal, or a false match on a word | Keep; correct the name or comment if the word misleads |

## Result of the review

Most of what the word "legacy" marks is not legacy.
Of the 83 rows below, 42 are not legacy, 10 are dead, 4 are false text, 17 are live, and 3 hold only old data.
The other 7 are duplicates, mixed rows, one row that the reset owns, and one row classed by cluster.
The real legacy code is small: four old input paths in the parser, one raw parser entry, 27 unused IR tags, a few old stored-data readers, and old output spellings.

The evidence says that the removal is safe for every tracked program.
A behavior mutation applied ten removal rows at once: A1, A2, A3, A5, A14, A17, B2w, B9, B14, and C14.
No tracked program, Markdown block, cassette source, or defect seed changed its `zts check` result.
Of 645 inputs, 9 hand probes moved, and 18 rows moved only for the output changes that rows B14 and C14 name.
The flow census held 740 of 740 probes with 0 fail-open. No replay test failed, so this plan expects no re-record.

The evidence also found five traps that a simple deletion would hit:

- Deleting `legacy_ordinary_prefix` alone makes a refused program pass (row A5). See "The A5 trap".
- Removing the scalar response fields can preserve a skipped comparison (row C14). See "The C14 trap".
- A census over `zts check` misses a live input. Row A1 has zero census hits, but one test pins its output.
- A word census misses a row that does not use the word. Section E names the three word lists.
- Tag removal moves `semanticsHash`, and two hash pins in `test-zts` move with it. The runtime then refuses an artifact from an earlier binary with `SemanticsHashMismatch`. My earlier hash probe found neither effect. It reported only the spec check, and that report was incomplete.

## Evidence and limits

The review read local `main` at `0635cd09` on 2026-10-30, on a clean tree.
All instrumentation and mutation ran in a scratch clone. No file in the main checkout changed.
Scratch evidence is in `/private/tmp/claude-501/zttp-legacy-20261030/`.

| Check | Method | Result |
|---|---|---|
| Input census | An instrumented clone prints each legacy name once per process. It ran `zts check` over 262 tracked `.ts` files, 105 fenced Markdown blocks, 43 sources decoded from cassettes, and 175 defect seeds | 585 inputs; the counts are in the ledger rows |
| Positive control | Hand probes for each zero-hit name | Each name fires, so a zero means no input in that set and not a broken probe |
| Behavior mutation | Each removal is applied as a behavior change in the clone, and the code stays | See "Mutation results" |
| Comparison script | `oracle.sh` below, over 645 inputs: the 585 census inputs plus 60 hand probes | Two base runs differ in 0 rows |
| Tag simulation | 26 of the 27 tags moved to the end of `NodeTag`, so live tags take new values. `stmt_list` kept its position | See "Tag removal measurement" |
| History | `git show <tag>:<path>` at each release tag, `git log -S`, and `gh release view` for asset names | Cited in the ledger rows |
| Completeness census | Each of the 659 lines that say "legacy", outside the 212 lines in the vendored `packages/zts/deps/sqlite`, is matched to a row. Two wider word lists added 60 and 505 lines | The remainder produced section E |

Limits:

- The census covers `zts check` only. A zero does not prove that no input exists. Row A1 shows this.
- A mutation changes behavior and leaves the code. A real deletion can expose more dependents. Each unit therefore runs its own gates.
- User machines are not visible. This machine holds 17 sessions: 15 at schema 2 and 2 at schema 4. The ledger sample covers one workspace directory.
- External consumers of `canonicalize --json` and contract JSON cannot be measured from this repository.
- Row E7 (history comments) is classified by cluster, not line by line.
- The tag simulation diff was read for one input. Unit L6 compares all rows.
- The scratch path is temporary. Appendix B lists 16 probes: the 13 that fix an expected result and the 3 new `block` probes. The other 47 probes exist only in the scratch directory. If that directory is lost, L0 rebuilds the probes from the ledger rows.
- Rows B1, B2r, B3, B6, B7, B13, C4, C10, E1, E2, E9, E10, E12, and E15 had no mutation. Their evidence is history and reading. Their pin tests in Appendix A come from reading, so a unit can find more.
- The word lists are "legacy", a second list, and a third list that added "compatib", "historical", "obsolete", "superseded", and "formerly". A legacy path that no comment names stays invisible to them.

## Mutation results

Batch 1 applied A1, A2, A3, A5, A14, A17, and B9 together.
Batch 2 kept batch 1 and added B2w, B14, and C14.

| Gate | Batch 1 exit | Batch 2 exit | Failures |
|---|---|---|---|
| Comparison script, 645 rows | 9 moved | 27 moved | Batch 1: 9 hand probes only. Batch 2 added 13 `canonicalize` rows (B14) and 5 `compile` rows (C14) |
| `test-zts` | 1 | 1 | 46 pin tests in batch 2, all in Appendix A. The 2 `compile` crashes in batch 1 came from a defect in the mutation, and batch 2 fixed it |
| `test-precompile` | 1 | Not run | 4 pin tests |
| `test-diagnostic-corpus` | 1 | Not run | 182 of 182 cases pass. The exit is the same 4 pin tests |
| `test-flow-census` | 1 | Not run | 740 of 740 probes match, 0 fail-open. The exit is the same 4 pin tests |
| `test-standin`, `test-bytecode-identity`, `test-contract-golden` | 0 | `test-contract-golden`: 0 | None |
| `test-expert-app` (offline replay) | 0 | 1 | Batch 2: 4 tests read the journal key `body`. No replay test failed |
| `test-expert-golden` | Not run | 1 | Only `canonicalize_mixed.golden.json` and `canonicalize_mixed_simulate.golden.json` |
| `test-canonicalize`, `test-agent-protocol` | Not run | 1 | 3 `canonicalize` pin tests plus the same 4 pin tests |
| `test-zts-cli` | Not run | 1 | The same 4 pin tests |
| `test-cli`, `test-server`, `test-zruntime` | 1 | `test-cli`, `test-zruntime`: 1 | 2 pin tests of A17 |
| `test-deploy-manifest`, `test-expert` | Not run | 0 | None |
| `scripts/check-semantics-spec.sh` | 0 | 0 | None: `compile` passes through the typed entry |

Raw parser measurement. `compile` through `initTyped` passes each of its tests and the semantics spec gate.
Each `.inline_code` fixture passes through the typed path, except for the 2 tests that pin the raw path on purpose.

Re-record measurement. The mutated tree passed every replay test, and the tag simulation passed replay.
So this plan expects no re-record. The expectation holds only for what ran: units L3a, L3c, L7d, and L8 are not in a mutation, and each runs replay itself.

Three later mutations ran on their own.

| Mutation | `test-cli` | `test-server` | `test-zruntime` | Reading |
|---|---|---|---|---|
| Capability skip becomes a refusal | 8 failed | 8 failed | 0 | Same 8 tests: 2 pins and 6 fixtures. See row E11 |
| Policy and artifact skips become refusals | 16 failed | 8 failed | 0 | Policy: 3 pins and 4 fixtures. Artifact: 1 pin and 8 `build_command` tests. See rows E11 and E14 |

The third mutation refused absent recording fields and absent session fields, and it panicked at the interpreter fallback.
`test-simulator` and `test-expert-app` fail the same 9 tests: 4 recording fixtures and 5 session tests. No replay test fails. Rows E16 and E18 read these failures.
`test-cassette`, `test-expert`, `test-examples`, `test-zts`, `test-zruntime`, and `test-server` exit 0.
The first run of this mutation did not compile, so its pi gates ran no test. I fixed the edit and reran those gates. These results come from the rerun.

## The A5 trap

The mutation that sets `legacy_ordinary_prefix` to null changes this program from refused to accepted:

```ts
export function handler(req: Request): Response { return Response.text("ok"); }
function isS(x: unknown): x is
{ return true; }
```

The old binary reports ZTS204 at `return true`. The mutated binary reports 0 errors.
The cause: the old second parse supplied an ordinary type for the empty narrowing, and that type refused the return value.
With no second parse, the function has no declared return type to check.
This is the same class as the fail-opens in `AGENTS.md`: the code reports a verdict for something it never read.

Unit L4c therefore replaces the second parse with an explicit refusal of an empty narrowing. It does not only delete the path.
The test comes first. It asserts the refusal, and it must fail on a tree where only the prefix is gone.

## The C14 trap

`syncLegacyRouteResponse` sets `response_schema_dynamic` to true when a route has more than one response.
`compareResponses` in `packages/zts/src/contract_diff.zig` reads that scalar, and it returns `.unchanged` when both sides are dynamic.
So a route with two static responses never reaches the comparison of its `responses` array. This is an observation from the code.
The effect on a user is probable. `zts prove-behavior` reports `breaking` for a plain handler with a changed 404, because it compares paths. `diffContracts` has no such second check, and `live_reload.zig` uses it when no old source exists.
The check that confirms the effect is the first step of unit L7c.

A pure move of the scalar logic would write this skip down as a literal expected value.
Unit L7c therefore drops the "more than one response" clause. A dynamic variant still counts as dynamic, so an unchanged computed handler stays `.unchanged`.
The comparison gets stricter for static routes with more than one response. Decision 10 names that move.

## A live gap outside this plan

The comment beside `artifact_sha256` in `packages/tools/src/precompile_cli.zig` says that the runtime verifies the embedded bytecode at boot.
I built `examples/handler/handler.ts` with `zttp compile`, and the artifact holds an all-zero `artifactSha256`. So `verifyArtifactHash` skips for that artifact. That is an observation.
The effect on tamper detection is not measured. `proof_activation.zig` rebuilds the artifact graph at boot, so another check can cover this path.
This is not legacy code, so this plan does not change it. The owner decides whether a separate fix follows.

## Tag removal measurement

| Check | Exit | Note |
|---|---|---|
| `test-bytecode-identity`, `test-contract-golden`, `test-expert-golden`, `test-meta-drift`, `test-flow-census`, `test-proof-checker`, `test-expert-app` | 0 | Offline replay passes |
| `zts check --json --contract`, `zts canonicalize --json` | No row moved | 645 inputs |
| `zts compile --verify --contract` | 333 rows moved | One row read: only `contract.json` field `semanticsHash` differs |
| `test-zts` | 1 | Two hash pins: `direct single-module full and sound extraction preserve contract bytes`, `explicit omitted selection preserves native ABI holes and hides authored signatures` |
| `scripts/check-semantics-spec.sh` | 1 | Fix: `zts spec-render --out docs/spec/semantics.spec.ts` |

Effects of a moved `semanticsHash`:

- `docs/spec/semantics.spec.ts` needs a regeneration.
- `docs/convergence.json` and `docs/coverage.json` hold the old value until the next release republish. `test-docs-drift` and `test-meta-drift` pass with the old value.
- `session/protocol_identity.zig` hashes it, so `zttp expert --resume` refuses a session from an earlier build with `SessionProtocolMismatch`. That hash also holds the compiler version, so each release already does this.
- `ledger.zig` compares it in a stored receipt. That comparison also holds the compiler version, so the same reasoning applies.
- `verifySourceIdentity` in `packages/runtime/src/contract_runtime.zig` compares it. A new binary refuses a contract or artifact from an earlier binary with `SemanticsHashMismatch`. A self-extracting binary carries its own runtime, so a deployed binary keeps running. Decision 12 names this effect.

## Preservation

"All features continue to work" has one meaning here: every output in the reset "Preservation contract" stays byte-identical, except a moved output that this plan names and an owner decision accepts.

### Comparison script

Phase L0 saves two scripts. `oracle.sh` writes one row for each input. `compare.sh` compares those rows with the frozen base.
Unlike `digest.sh`, they also cover `canonicalize --json`, fenced Markdown blocks, cassette sources, defect seeds, and hand probes.

```bash
# Usage: bash oracle.sh <label> <bin-dir>
set -u
L=${L:-/private/tmp/claude-501/zttp-legacy-20261030}
label=$1; BIN=$(cd "$2" && pwd); IN=$L/oracle-in; out=$L/oracle/$label; W=$L/oracle/work
mkdir -p "$out"; : > "$out/rows.tsv"
sum() { shasum -a 256 < "$1" | cut -d' ' -f1; }
tmo() { perl -e 'alarm 20; exec @ARGV' "$@"; }
cd "$IN" || exit 1
while IFS= read -r -d '' f; do
  dir=$(dirname "$f"); base=$(basename "$f")
  command rm -rf "$W"; mkdir -p "$W"
  ( cd "$dir" || exit 9
    code=0; tmo "$BIN/zts" check "$base" --json --contract > "$W/co" 2> "$W/ce" < /dev/null || code=$?
    echo "$code" > "$W/cc"
    code=0; tmo "$BIN/zts" compile --verify --contract "$base" "$W/out.zig" > "$W/po" 2> "$W/pe" < /dev/null || code=$?
    echo "$code" > "$W/pc"
    code=0; tmo "$BIN/zts" canonicalize "$base" --json > "$W/no" 2> "$W/ne" < /dev/null || code=$?
    echo "$code" > "$W/nc" )
  tree=$(cd "$W" && find . -type f -print0 | LC_ALL=C sort -z | xargs -0 shasum -a 256 | shasum -a 256 | cut -d' ' -f1)
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$f" "$(cat "$W/cc")" "$(sum "$W/co")" "$(sum "$W/ce")" \
    "$(cat "$W/pc")" "$(cat "$W/nc")" "$(sum "$W/no")" "$tree" >> "$out/rows.tsv"
done < "$L/oracle-in.z"
```

```bash
# Usage: bash compare.sh <label> [allowed-file]
# The allowed file lists one input path per line. It defaults to no moved row.
set -u
L=${L:-/private/tmp/claude-501/zttp-legacy-20261030}
FLOOR=${FLOOR:-648}
base=$L/oracle/base1/rows.tsv; new=$L/oracle/$1/rows.tsv; allow=${2:-/dev/null}
work=$(mktemp -d)
[ "$(wc -l < "$base" | tr -d ' ')" = "$FLOOR" ] || { echo "base row count is not $FLOOR"; exit 2; }
[ "$(wc -l < "$new" | tr -d ' ')" = "$FLOOR" ] || { echo "new row count is not $FLOOR"; exit 2; }
/usr/bin/awk -F'\t' 'NR==FNR { b[$1]=$0; next } !($1 in b) || b[$1]!=$0 { print $1 }' "$base" "$new" | LC_ALL=C sort > "$work/moved"
LC_ALL=C sort -u "$allow" > "$work/allowed"
LC_ALL=C comm -23 "$work/moved" "$work/allowed" > "$work/unexpected"
LC_ALL=C comm -13 "$work/moved" "$work/allowed" > "$work/unmoved"
echo "moved=$(wc -l < "$work/moved" | tr -d ' ') unexpected=$(wc -l < "$work/unexpected" | tr -d ' ') allowed_unmoved=$(wc -l < "$work/unmoved" | tr -d ' ')"
/usr/bin/sed 's/^/unexpected: /' "$work/unexpected"; /usr/bin/sed 's/^/allowed but unmoved: /' "$work/unmoved"
[ ! -s "$work/unexpected" ] && [ ! -s "$work/unmoved" ]
```

The columns are: input, check exit, check stdout, check stderr, compile exit, canonicalize exit, canonicalize stdout, and the tree of all files.
Each unit lists its allowed moved rows before it starts. `compare.sh` exits 1 for a moved row outside the list, and for a listed row that did not move.
An allowed file spells each input as `rows.tsv` does, for example `./_probe/ex/lc.ts`.
I tested `compare.sh` on saved rows: a self-comparison exits 0, an unlisted move exits 1, a listed move exits 0, and a stale list row exits 1.
The self-comparison is the floor: two base runs must differ in 0 rows, and the row count must be 648. Phase L0 adds the three `block` probes in Appendix B to the 645 inputs that the evidence used.

### Stored-data set

The comparison script runs `zts` only. It never loads a stored file, and it never serves a request.
Phase L0 therefore builds this set with the base binaries, in the scratch directory:

- A self-extracting artifact of `examples/handler/handler.ts`, from `zttp compile handler.ts -o app`.
- A proof bundle of that artifact, from `zttp proofs bundle --binary app --out bundle`.
- A project ledger `.zttp/proofs.jsonl` with `kind=deploy` rows from `zttp deploy`, plus the `kind=perf` and `kind=equivalence` rows from the fixtures in `proof_ledger.zig`.

The new binaries then read this set. The artifact serves `GET /`, and the check compares the status and the `message` field, because the body holds a timestamp. `zttp proofs verify` reads the bundle. `zttp proofs list`, `show`, `diff`, and `export` read the ledger.
Each unit that changes a stored-data reader compares stdout, stderr, and exit status with the base binaries. L3b, L3d, L7c, L8a, and L9 run it.
From L6 on, a refusal with `SemanticsHashMismatch` is the expected result for a reader that verifies source identity.

### Feature map

| Feature | Check | Run at |
|---|---|---|
| Analyzer output | Comparison script; `test-zts-cli`; `test-precompile`; `test-diagnostic-corpus` (182 cases) | Each unit |
| Soundness of refusals | `test-flow-census` (740 probes, 0 fail-open); `test-proof-swallow`; `test-standin` | Each language unit |
| Proof acceptance | `test-proof-checker`; `test-proof-checker-mutants`; `test-proof-ratchet`; `test-kernel-safety` | L3b, L3d, L4 to L7, L9 |
| Bytecode and contract identity | `test-bytecode-identity`; `test-contract-golden`; `test-meta-drift` | Each unit |
| Expert, offline | `test-expert-app` with a scrubbed environment; `test-expert`; `test-expert-golden`; `test-cassette`; `test-simulator` | Each unit that changes Zig |
| Serving and isolation | `test-zruntime`, which is outside `zig build test`; `test-server`. L9 adds `test-panic-isolation` and `test-module-scope-panic` | Each unit that changes Zig |
| Virtual modules | `test-modules`; `test-module-governance` | L6, L9 |
| CLI surface | `test-cli`; `surface.sh`; `eprobe.sh` (11 `-e` shapes) | Each unit that changes Zig |
| User flows | `smoke-v1`; `smoke-getting-started`; `test-examples` | L9, and each unit in L5 and L7 |
| Performance | `bench-check`, read with host load | L5, L6, L9 |
| Everything | `bash scripts/verify.sh` from an empty cache | L9 |

Each pin test that a unit changes is listed in Appendix A. A failure outside that list stops the unit.
A unit that deletes a pin test states the observable behavior that the test held.
The unit then names the test that now holds that behavior, or states that the behavior left on purpose.

## Verdict ledger

Each row is an item that some reader could call legacy. The row IDs stay stable through the worklog.
"Input census" means the 585 inputs in the section "Evidence and limits". A row that names no hit had zero hits in that census.
Sizes count lines that mention a name. A size is not a removal estimate.

### A. Language surface

| ID | Item, as a symbol in a path | Verdict | Evidence | Effect of removal | Unit |
|---|---|---|---|---|---|
| A1 | `.legacy_call` policy and `legacy_call_arguments` in `packages/zts/src/parser/type_syntax_store.zig`, its selectors in `parser/parse.zig`, and the `compatibility_*` order in `packages/zts/src/type_env.zig` | LEGACY-LIVE | No input census hit reaches the store policy. A generic arrow after a line comment reaches it. No document names the form | A generic arrow after a line comment stops reporting ZTS203. It reports the single ZTS200 that the same program reports with no comment | L4a |
| A2 | Erased type prefix: `selectErasedTypePrefix`, `parseErasedExpressionPrefix`, `tryParseErasedBlockPrefix` in `parser/parse.zig`, and `reserveErasedTypePrefix`, `ErasedTypePrefixCompatibility` in `parser/type_syntax_store.zig` | LEGACY-LIVE | `reserveErasedTypePrefix` has zero hits in the input census. A positive control proves that the probe fires. `const x = <T>(1);`, `const x = <T> { id: 1 };`, and the statement `<T> { const a = 1; }` pass today, and `T` need not exist | These forms change from accepted to ZTS002, as `<string>"a"` already does. No tracked program moves | L4b |
| A3 | `ErasedTypePrefixCompatibility.ignored_parameters` | LEGACY-LIVE | Agent A marked this row NOT-LEGACY. The census refutes that verdict for the erased prefix: this member goes with A2. `declaration_parameters` and `ignored_declaration_parameters` on generic owners are current | With A2 | L4b |
| A4 | `LegacyReturnKind`, `hasLegacyGuardFacet` in `parser/type_syntax_store.zig` and `parser/type_syntax_parser.zig` | NOT-LEGACY | `x is T` is documented in `docs/typescript.md`. The census reaches both members | L4c deletes the field if no reader remains. Otherwise it takes a rename | L4c |
| A5 | `legacy_ordinary_prefix` in `ReturnSyntax` and its use in `populateDirectReturn` in `packages/zts/src/type_env.zig` | LEGACY-LIVE | Only a predicate header with no literal " is " reaches it: `x is<TAB>string` and `x is<newline>{`. Zero census hits | See the trap below this table | L4c |
| A6 | `legacy_recorded_span` in `GenericCaptureSpans` | NOT-LEGACY | Every generic owner sets it. 101 census hits | Rename only | L2 |
| A7 | `legacy_bound_span` in `ProjectedGenericParameter` | NOT-LEGACY | It is the bound of `<T extends X>`, a current feature | Rename only | L2 |
| A8 | `scanLegacyPlainQuoted`, `scanLegacyGenericQuotedCore`, `scanLegacyMatchingBracketCore`, `LegacyQuoteFailure`, `LegacyTemplateFrame`, `LegacyMatchingBracketScan`, `appendLegacyQuoteFailure` in `parser/type_syntax_scan.zig` | NOT-LEGACY | `scanLegacyPlainQuoted` runs on 472 of 585 inputs, and `scanLegacyGenericQuotedCore` runs on 475. Together they run on 477 | Rename only | L2 |
| A9 | `LegacyCompoundDiagnostic` and sibling helpers in `packages/tools/src/precompile_check_tests.zig`, plus test names that say "legacy" | NOT-LEGACY | Test support and test names | Rename only | L2 |
| A10 | `legacy_types_import`, `LegacyTypesImport`, `containsLegacyTypesImport`, restriction id `restriction.legacy-types-module` | NOT-LEGACY | ZTS053 is a deliberate refusal. The restriction id is hashed into `restriction_matrix_hash` | Rename the Zig names. Do not rename the restriction id | L2 |
| A11 | `packages/zts/src/compat.zig` | NOT-LEGACY | Clock and lock adapters for Zig 0.17, imported by 10 files and exported from `root.zig` | None | None |
| A12 | The words "compat" and "compatibility" in `type_env.zig`, `contract_census.zig`, `spec_discharge.zig` | Mixed | `type_env.zig` matches belong to A1. The others name `incompatible_with_import` (ZTS501), a current rule | With A1 | L4a |
| A13 | 27 `NodeTag` members with no producer in `parser/ir.zig`, and `addCase`, `addLabeled`, `addLoop`, `addSequence`, `addSwitch`, `addTry` | LEGACY-DEAD | No producer. The six builders have no production caller. See "Tag removal measurement" | `semanticsHash` moves; no other output moves | L6 |
| A14 | Raw entry `Parser.init` in `parser/parse.zig` and `parser/root.zig` | LEGACY-LIVE | Two production callers remain: `compile` in `packages/zts/src/compiler.zig` and the raw arm of `loadCodeWithCachingInternal` in `packages/runtime/src/handler_instance.zig`. 149 test call sites use it: 136 in `parse.zig`, 8 in `parser/root.zig`, 4 in `frontend_fuzz.zig`, and 1 in `precompile_gen_tests.zig` | See "Raw parser measurement" | L5 |
| A15 | `initExpression` | NOT-LEGACY | `kernel_identity.zig` needs an expression-only parse | None | None |
| A16 | `initSourceObserver` | NOT-LEGACY | Admission itself uses it | None | None |
| A17 | Raw parse of `HandlerSource.inline_code`: the raw arm of `loadCodeWithCachingInternal` in `packages/runtime/src/handler_instance.zig` | LEGACY-LIVE | The field is documented in `docs/internals/api-reference.md`, so the field stays. No production code produces it. Only its raw parse is legacy | An inline source that admission refuses fails at load. See "Mutation results" | L5b |

### B. Stored data and wire forms

| ID | Item | Verdict | Evidence | Effect of removal | Unit |
|---|---|---|---|---|---|
| B1 | Per-part `tool_use` journal records in `packages/pi/src/session/events.zig` and `reconstructor.zig` | LEGACY-DEAD | Only commits `c0d0787b` and `ca494237` (2026-08-15, same day) touched a persister `part_index`. No tag wrote it. 0 stored files hold it | A hand-made record reports `CorruptEventsLog` | L3 |
| B2r | Reader fallback `orelse body` for tool results and display payloads | LEGACY-DEAD | Every writer from `v0.19.0` on writes `llm_text` | A hand-made record reports `CorruptEventsLog` | L3 |
| B2w | Writer duplicate `"body"` next to `"llm_text"` | LEGACY-LIVE | The reader no longer needs it after B2r. It stores each tool result twice | Journal bytes change. No reader in this repository reads the field after B2r | L7 |
| B3 | String form of display records | LEGACY-DEAD | A schema 1 writer existed: `git log --all -S 'proof_card: []const u8'` finds it, and tags `v0.16.0-rc3` to `rc8` hold it. `events.zig` refuses each record whose `v` is not 4 before a display reader runs. Schema 4 writers do not write the string form | A hand-made schema 4 record reports `CorruptEventsLog` | L3 |
| B4 | `LegacySessionIdentity` in `packages/pi/src/providers/selection.zig` | NOT-LEGACY | Agent B leaned to dead. That is refuted: `app.zig` autoloop passes `.model_free = true`, so a model-free session stores a null provider. Probable; resume such a session to confirm | Rename only | L2 |
| B5 | Session schema below 4 | NOT-LEGACY | A clean refusal with no old-form reader | None | None |
| B6 | Ledger rows `kind=perf` and `kind=equivalence` in `packages/runtime/src/proof_ledger.zig` | LEGACY-DATA | Writers removed in `509ead28` (2026-10-12). `v0.21.1` has 2 production writer sites and 5 test sites. `v0.22.0` has 2 test sites only. No consumer reads either payload. `.zttp/proofs.jsonl` on a user machine can hold them | A strict reader fails `zttp proofs list`, `show`, `diff`, `watch`, `export`, and `badge` for that project. Decision 6 picks the treatment | L8 |
| B7 | Test "appendEvent without perf payload omits the field for back-compat" | NOT-LEGACY | It pins current rows. It goes with B6 only if payload fields go | With B6 | L8 |
| B8 | Contract JSON version 2 keys in `packages/zts/src/contract_json_parser.zig` | NOT-LEGACY | `agent_protocol_check.zig` writes version 2 today | None | None |
| B9 | `backfillApiRouteCollections` in `contract_json_parser.zig` | LEGACY-DEAD | `requestBodies` first appears between `v0.16.0` and `v0.17.0`. `sourceIdentity` first appears between `v0.18.0` and `v0.19.0`. `validate` refuses a contract with no identity, so each contract that passes `validate` already holds the arrays. Three readers skip `validate`: `zttp proofs bundle --contract PATH`, `proof_activation.zig`, and `attestPayload` in `runtime_cli.zig`. They read only retired fields, identity, and hashes, not the arrays | Only a hand-made contract changes. Two pin tests go | L3b |
| B10r | `rejectRetiredFields`, `retired_authority.zig` | NOT-LEGACY | Without the refusal an old contract parses with its fields ignored, which fails open | None | None |
| B10p | Empty retired placeholders in contracts and attest claims | NOT-LEGACY | Both contract parsers accept an empty value, and tests pin that. No separate code does this: `rejectRetiredFields` tests `len != 0`, and an empty value equals the wire default. A refusal needs new optional wire fields, so removal adds code | None | None |
| B11 | Self-extract format 7 | NOT-LEGACY | One accepted version | None | None |
| B12 | Certificate and agent protocol versions | NOT-LEGACY | One accepted version each | None | None |
| B13 | `retired_providers` in `packages/runtime/src/cli_auth.zig` (also C10) | LEGACY-DATA | Keys that `v0.21.x` stored in `~/.zttp/providers.json`. `zttp auth revoke` is the only way to delete them | Removal strands a stored secret on disk | L8 |
| B14 | `legacyKind` in `packages/tools/src/canonicalize.zig` | LEGACY-LIVE | Five intents print old `kind` names in `canonicalize --json`. Two goldens hold them. Cassettes hold none | Five JSON values change | L7 |
| B15 | Duplicate of A4 | NOT-LEGACY | See A4 | With A4 | L2 |
| B16 | Duplicate of C1 | See C1 | See C1 | With C1 | L1 |
| B17 | `corpusVersion()` in `packages/pi/src/expert_codegen_record.zig` | LEGACY-LIVE, Zig name only | Its comment calls it a compatibility accessor, and it returns `headlineInputIdentity().bytes`. The function name is not an identity input. The JSON key `corpusVersion` stays, because `docs/coverage.json` and `tooling/coverage_union.zig` use it | None. Callers use `headlineInputIdentity().bytes` | L2 |
| B18 | `ri_cpu_time_qos_legacy` | NOT-LEGACY | It mirrors a macOS struct field | None | None |
| B19 | "placeholder for API compatibility" comment in `packages/runtime/src/server.zig` | NOT-LEGACY | The tuple needs a value. The comment wording is the only issue | Comment only | L1 |

### C. Product, tooling, and documents

| ID | Item | Verdict | Evidence | Effect of removal | Unit |
|---|---|---|---|---|---|
| C1 | Bare `zttp-runtime <handler>` in `main` in `packages/runtime/src/runtime_cli.zig` | NOT-LEGACY | The comment says "Backward-compatible default", but `CLAUDE.md`, `examples/README.md`, and the `zttp-build` skill document this form, and `zig build run -- handler.ts` needs it | Comment only | L1 |
| C2 | Deferred verbs `login logout review grants revoke-grant` | NOT-LEGACY | A deliberate refusal of a deferred feature | None | None |
| C3 | Command tables against `docs/cli.md` | NOT-LEGACY | Every row is documented | None | None |
| C4 | `ZTS_TRACE_FUN_DECL` in `parser/parse.zig` | LEGACY-LIVE | An old debug print, 9 lines, reachable in a release build. No document names it | Stderr changes only when the variable is set | L3 |
| C5 | "retired instruction-counter" wording | NOT-LEGACY | "Retired" is the CPU term | Wording in `agents.json` and the generated `AGENTS.md` row | L1 |
| C6 | `scripts/*.allow` rows and scripts | NOT-LEGACY | Each path resolves | None | None |
| C7 | Runtime cost fuse | NOT-LEGACY | An unwired feature. Reset Decision 2 (a) keeps it, and this plan does not reopen that decision | None | None |
| C8 | Appendix A census of the reset | Mixed | 70 rows at HEAD by an approximate script. Reset rules keep most. `absentReceiverOf` and `addSequence` have no reference. `pruneUnused` has a documented deferral | Delete `absentReceiverOf`. `addSequence` goes with A13 | L3c |
| C9 | Retired authority refusal | NOT-LEGACY | Same reason as B10r | None | None |
| C10 | Duplicate of B13 | See B13 | See B13 | With B13 | L8 |
| C11 | Retired `credential` option in `fetch` | NOT-LEGACY | A deliberate refusal | None | None |
| C12 | Proof-checker retired ordinals | NOT-LEGACY | Reserved wire values must never be reused | None | None |
| C13 | Duplicate of B6 | See B6 | See B6 | With B6 | L8 |
| C14 | Scalar `responseStatus` and sibling fields: `ApiRouteInfo` in `packages/zts/src/contract_types.zig`, `syncLegacyRouteResponse` in `contract_builder.zig`, scalar views in `contract_diff.zig` | LEGACY-LIVE | The comment says "kept for backward compatibility with older contract.json consumers". The writer emits them. No cassette holds them. `full_v1.json` does | Contract JSON bytes change. See Decision 10 | L7 |
| C15 | Dual emission of `policy_denied_sql` in `capabilities.zig` | NOT-LEGACY | `docs/cli.md` documents both shapes | Comment only: "Phase 4 deprecates" names no plan | L1 |
| C16 | `root.zig` "Legacy single-pass parser removed", `build/tooling.zig` python history, and similar text | LEGACY-DEAD text | History only | Comment only | L1 |
| C17 | "Policy-hash drift detection" section in `packages/pi/README.md` | LEGACY-DEAD text | `injectDriftNote` does not exist. `agent_bootstrap.zig` returns `SessionProtocolMismatch` | Text only | L1 |
| C18 | Retired expert items | NOT-LEGACY | Current refusals and eval cases | None | None |
| C19 | Dead paths in `docs/solutions` | NOT-LEGACY | Solution notes record history by design | None | None |
| C20 | "Witness Corpus" text in `docs/proofs-and-receipts.md`, `docs/cli.md`, `docs/verification.md`, `docs/README.md`, `docs/user-guide.md` | LEGACY-DEAD text | `zts check` on a violating handler creates no `.zttp`. `witness_corpus.zig` does not exist | Text only | L1 |
| C21 | Closed plans in `docs/plans` and `advisor-plans` | Not decided here | Reset Decision 6 governs the archive tag | None in this plan | None |
| C22 | Examples and templates | NOT-LEGACY | No retired module, tool, or setting occurs | None | None |

### E. Rows that the completeness census added

The three audits used keyword samples. I then listed all 659 lines that say "legacy" and removed the lines that a row names.
Fable then showed that a word census misses other words.
A second pass therefore read 60 lines for words such as "backward", "deprecated", "older contract", and "accepted and ignored".
These rows came from the remainder. A word census has a limit: a legacy path that no comment names stays invisible to it.

| ID | Item | Verdict | Evidence | Effect of removal | Unit |
|---|---|---|---|---|---|
| E1 | `legacy_root` fallback in `install.sh`, and its 41 `LEGACY_` lines in `scripts/test-install-archive-safety.sh` | LEGACY-LIVE | `v0.18.0` assets are `zigttp-*`, and `v0.19.0` assets are `zttp-*` | `ZTTP_VERSION=v0.18.0` stops installing. Decision 11 covers this row | L7 |
| E2 | `ZTS_PIC_DISABLE_RECOVERY` in `packages/zts/src/interpreter/ic.zig` | LEGACY-LIVE | The comment says "(legacy behavior)". No document names it. One call site | Behavior changes only when the variable is set | L3 |
| E3 | `srdjan/zigttp` and `zigttp.timok.com` | NOT-LEGACY | These are the real repository and site addresses | None | None |
| E4 | "legacy GC path" in `packages/zts/src/pool.zig` | NOT-LEGACY | `loadHandlerCached` clears `ctx.hybrid` on purpose so that handler objects survive arena resets. `use_hybrid_allocation` stays in the runtime configuration | Comment only | L1 |
| E5 | Column clamp in `packages/tools/src/json_diagnostics.zig` | NOT-LEGACY | Current output behavior for a column above 65535 | Test name only | L2 |
| E6 | `allow_queries` comment in `packages/zts/src/module_binding.zig` | NOT-LEGACY | `handler_policy.zig` parses this section today | Comment only | L1 |
| E7 | History comments: 603 pattern lines by cluster, including `codegen.zig`, `flow_evidence.zig`, `handler_verifier.zig`, `path_generator.zig`, `bool_checker.zig`, `json_wire.zig`, `value.zig`, `effect_inference.zig`, `corpus-uncovered.allow` | Classified by cluster only | L1b, L1c, and L1d classify each line. A line that states a current rule stays | Comment only | L1 |
| E9 | `--no-sign` on `zttp proofs gate` in `packages/runtime/src/proofs_cli.zig`, `pr_gate.zig`, and `scripts/proof-gate.sh` | LEGACY-LIVE | Accepted and ignored. `docs/cli.md` states that. The gate used to append signed `kind=equivalence` rows | An external script that passes the flag fails with an unknown-flag error. Decision 6 covers this row | L8a |
| E10 | `ReviewFacts.parseJson` default values in `packages/runtime/src/proofs/review.zig` | LEGACY-DATA | The comment says that older persisted proof facts still load. It goes only if old ledgers stop loading | Decision 6 (a) keeps it. Decision 6 (b) removes it | L8a |
| E11 | The null skip in `verifyCapabilityMatrix` and the all-zero skip in `verifyPolicyHash`, in `packages/runtime/src/contract_runtime.zig` | LEGACY-DEAD | `contract_builder.zig` sets both values at each tag from `v0.19.0`, and the writer always emits `sandbox`. Mutation: 2 skip pins, 1 shared pin, and 6 hand-built fixtures fail. `test-zruntime` stays 0. `verifySourceIdentity` beside them already refuses a missing value | Only a hand-made contract changes. It reports `CapabilityMatrixMismatch` or `PolicyHashMismatch`. The field stays optional in the parser | L3d |
| E14 | The all-zero skip in `verifyArtifactHash` | NOT-LEGACY | A real artifact from `zttp compile` holds an all-zero `artifactSha256`, so `zttp compile` reaches this skip. Only `zts compile` stamps the hash. Mutation: 8 `build_command` tests fail. See "A live gap outside this plan" | None | None |
| E15 | Aliases and an unused parameter: `pathsMatch` in `packages/zts/src/root.zig`, `loadHandler` in `handler_instance.zig`, and the `allocator` parameter of `destroy` in `packages/zts/src/pool.zig` | LEGACY-LIVE | No production caller uses `pathsMatch`. `loadHandler` calls `loadCode`, and `engine_adapter.zig` is its one production caller. `destroy` ignores the parameter. `root.zig` is a protected surface, so Decision 4 covers this row | An embedder that calls `zts.pathsMatch` must call `zts.routePatternsMatch`. An embedder that calls `loadHandler` must call `loadCode` | L5d |
| E16 | The absent skip for `ModelCheckpoint.request_budget` and `normalized_input_tokens` in `packages/pi/src/simulator/model_client.zig` | LEGACY-DEAD | Each of the 13 committed traces holds both fields, and the recorder writes both. Mutation: 4 hand-built test fixtures fail, and no replay test fails. `wire_request_sha256` stays optional, because a semantic client leaves it null. The `.unmeasured` result of `draftExpectation` stays: no per-turn count exists | Only a hand-made recording changes. No cassette changes | L3f |
| E17 | `allow_asi` in `parser/parse.zig`, called the "compatibility mode" | NOT-LEGACY | `ir_identity.zig` uses it to compare the unrepaired source with the repaired file. That comparison is current behavior. The source of a repair has no semicolons yet | Comment only | L1 |
| E18 | Optional `provider` and `model` in session `Meta`, and `LegacySessionIdentity` | NOT-LEGACY | `app.zig` runs a model-free session, and such a session writes schema 4 metadata with no provider. `--resume` on it needs `--provider`. The comment "only while decoding sessions created before provider persistence" is false. All 15 local sessions with no provider are at schema 2, which the gate refuses | The Zig error name and the comment change. The message text stays | L1, L2 |
| E19 | The word "compatibility" on current code: the `flow_checker.zig` facade, `compact` in `agent_compaction.zig`, `executeSemanticPlan`, the native `Result` fields `ok` and `value`, the embedded placeholder in `server.zig`, and the parse-error mapping in `session/reconstructor.zig` | NOT-LEGACY | Each is the current path for its feature. None reads an old form | Comment only | L1 |
| E20 | The undefined result for an unknown callable shape in `interpreter/call.zig` | LEGACY-LIVE | Its comment says "preserve historical behavior". With a panic at that line, `test-zts`, `test-zruntime`, `test-server`, and `test-examples` exit 0. A zero does not prove that no program reaches it. Decision 7 covers this row | That call stops with an error. It does not push `undefined` | L3e |
| E12 | Second handler argument: `cached_handler_arg_count` and `createCapabilitiesObject` in `packages/runtime/src/handler_instance.zig` | LEGACY-LIVE | An unfinished injection path. The object is always empty, and no document or example uses it. `zts check` accepts a handler with a second parameter | That parameter reads `undefined`, not `{}`. Decision 7 covers this row | L3e |
| E13 | False text beside live code: the `jit/baseline.zig` reference in `interpreter/ic.zig`, the `proof` alias in `scripts/check-docs-drift.sh`, "not used by new parser" in `parser/root.zig`, "backward compatibility" in `module_binding/types.zig`, and "kept for future implementation" in `bytecode.zig` | LEGACY-DEAD text | No `jit` file is tracked, and no `proof` row exists in `dev_cli.zig`. `CodeGen` receives `strings` and `atoms` | Comment only | L1 |
| E21 | `old_checker_misses`, `Miss`, `inMissTable`, and the "old checker" text in `packages/tools/src/flow_precision_expectations.zig` | LEGACY-DEAD | The flow interpreter replaced the old checker. The table is empty, and it exempts a checker that no longer exists. Unit L1c review found this row | Test support only. A miss then fails with no table lookup | L3c |
| E22 | `Law.audit_timeout_ms` in `packages/zts/src/semantics.zig`, and the comments that describe the removed SMT encoder and audit | LEGACY-DEAD | No code reads the field. The removed audit read it. The comment beside it says that it is outside `semanticsHash`, and `docs/internals/semantics-verification.md` says that it is inside. Unit L1b review found this row | None. L3c stops if `semanticsHash` moves | L3c |
| E23 | `old_intro`, `new_intro`, and the `## Repeatability` cut in `renderConvergenceMarkdown` in `tooling/evidence_publish.zig` | LEGACY-DEAD | A one-time migration of `docs/convergence.md`. That file holds the new intro, and it holds no `## Repeatability` section, so both steps change nothing. Unit L1d review found this row | A publish over the committed document writes the same bytes | L3c |
| E8 | `func_overrides` fallback in `packages/zts/src/counterexample.zig` | NOT-LEGACY | The comment says "Legacy fallback". `flow_evidence.zig` sets `call_index` only when the checker knows the call, and `sameCall` documents the function-name key as the other case | Comment only | L1 |

## Phases

Each unit is one commit or a named series. Each unit is small enough to review alone.
Class A units move no protected output. Class B units move an output that a decision names.
Sonnet implements. Opus reviews each diff line by line and runs the gates. The dispatch packet carries the row text, the allowed moved rows, and the allowed pin tests.
The reset "Common rules" apply: private cache, scrubbed `DEEPSEEK_` and `ZTTP_` variables, saved exit status, `git add` before `check-spine`, and no line anchors in documents.
This plan adds one rule: commit with `git commit --only <paths>`, because another session can have staged files.
Each unit ends with these checks, plus its row:

```bash
zig build > "$R/logs/build.log" 2>&1; echo "build=$?"
bash "$L/oracle.sh" <unit> ./zig-out/bin; bash "$L/compare.sh" <unit> "$L/allow/<unit>.txt"; echo "compare=$?"
zig build test > "$R/logs/test.log" 2>&1; echo "test=$?"
zig build check-spine > "$R/logs/spine.log" 2>&1; echo "spine=$?"
```

### L0. Baseline

| Unit | Class | Model | Files | Acceptance | Turns |
|---|---|---|---|---|---|
| L0 | A | Opus | Worklog only | `bin-base` holds the three binaries at the base commit. The stored-data set exists, and the base binaries read it with exit 0. The three `block` probes join the snapshot. Two runs of the comparison script differ in 0 rows at 648 rows. `surface.sh` and `eprobe.sh` tables are saved. The aggregate test count and skip count are recorded | 10 |

### L1. Text that states a false or historical fact

| Unit | Class | Model | Rows | Acceptance | Turns |
|---|---|---|---|---|---|
| L1a. Documents | A | Sonnet | C17, C20, C5 | `git grep -n -i 'injectDriftNote\|witness_corpus\|witness corpus' -- . ':!docs/plans' ':!docs/solutions' ':!CHANGELOG.md'` prints nothing. `test-doc-links`, `test-docs-drift` exit 0. `packages/pi/README.md` states `SessionProtocolMismatch` and journal version 4 | 20 |
| L1b. Comments in `packages/zts` | A | Sonnet | E7, E13, and the rows below | See the rule below | 25 |
| L1c. Comments in `packages/runtime`, `packages/tools`, `build` | A | Sonnet | C1 wording, C15, C16, B19, E7, E13 | See the rule below | 20 |
| L1d. Comments in `packages/pi`, `packages/modules`, `scripts`, `tooling` | A | Sonnet | C16, E4, E6, E7, E8, E13 | See the rule below | 20 |

Rule for L1b to L1d: delete the historical clause. Rewrite a comment only when the deletion leaves a false sentence.
A rewrite cites its symbol in the worklog, and Opus reads each rewrite against that symbol.
No code token changes: `git diff --word-diff` on Zig files shows comment text only. The comparison script moves 0 rows. The worklog gives the count for each cluster.
The diff of each unit stays small enough for one review. A larger cluster takes its own commit.

### L2. Names

| Unit | Class | Model | Rows | Acceptance | Turns |
|---|---|---|---|---|---|
| L2. Renames | A | Sonnet | A6, A7, A8, A9, A10 Zig names, B4, B17, E5, E18, `LegacyCapturingClient` | The comparison script moves 0 rows. `zts meta --json` is identical. The restriction id `restriction.legacy-types-module` stays. Stop if a rename moves any hash. Test names change only where the word "legacy" is false | 25 |

Rows A4 and B15 wait for L4c, because that unit may delete `LegacyReturnKind`.

### L3. Dead readers and stray switches

| Unit | Class | Model | Rows | Acceptance | Turns |
|---|---|---|---|---|---|
| L3a. Journal readers | A for written data | Sonnet | B1, B2r, B3 | A new test asserts that a hand-made `part_index` record, a `body`-only record, and a string display record each report `CorruptEventsLog`. `test-expert-app`, `test-expert` exit 0 | 20 |
| L3b. Contract backfill | A for accepted data | Sonnet | B9 | The two pin tests go. A new test asserts the parse of a contract with no arrays leaves them empty. `test-zts`, `test-contract-golden`, `test-zruntime` exit 0. The comparison script moves 0 rows | 15 |
| L3c. Debug switches and dead support | A | Sonnet | C4, C8, E2, E21, E22, E23 | `git grep -n 'ZTS_TRACE_FUN_DECL\|ZTS_PIC_DISABLE_RECOVERY\|absentReceiverOf\|old_checker_misses\|audit_timeout_ms\|old_intro' -- packages tooling` prints nothing. `semanticsHash` stays. `test-flow-census`, `test-evidence-publish`, `test-evidence-marker` exit 0. `bench-check` is compared with the baseline | 20 |
| L3d. Capability and policy skips | A for written data | Sonnet | E11 | The 3 pin tests in Appendix A assert the refusal. The 6 fixtures in Appendix A gain a matrix and a policy hash. The stored-data artifact still serves `GET /`. `test-cli`, `test-server`, `test-zruntime` exit 0. The comparison script moves 0 rows | 15 |
| L3e. Undocumented runtime paths | B, Decision 7 | Sonnet | E12, E20 | `createCapabilitiesObject` is gone. A new test asserts the literal value of a second parameter. The fallback in `call.zig` returns an error. `test-zruntime`, `test-server`, `test-examples` exit 0 | 15 |
| L3f. Recording fields | A for committed data | Sonnet | E16 | Replay refuses a checkpoint with no `request_budget` or `normalized_input_tokens`. The 4 fixtures in Appendix A gain both fields. No file under `packages/pi/src/simulator/testdata` changes. `test-expert-app`, `test-simulator`, `test-cassette` exit 0 | 15 |

### L4. Old input forms

Each unit needs its decision. Each unit writes the failing test first, runs it, and records the failure in the commit message.

| Unit | Class | Model | Rows | Allowed moved rows | Turns |
|---|---|---|---|---|---|
| L4a. Generic arrow after a comment | B, Decision 1 | Opus plans, Sonnet implements | A1, A12 | `_probe/ex/lc.ts`, and any row with a generic arrow after a line comment. A moved row of another shape stops the unit | 30 |
| L4b. Erased type prefix | B, Decision 2 | Opus plans, Sonnet implements | A2, A3 | `_probe/erased/a.ts`, `_probe/erased/b.ts`, `_probe/ex2/p1.ts`, `p2.ts`, `p3.ts`, `p6.ts`, `p7.ts`, `_probe/block/b1.ts`, `b2.ts`, `b3.ts` | 40 |
| L4c. Predicate second parse | B, Decision 3 | Opus plans, Sonnet implements | A4, A5, B15 | `_probe/ex/e7.ts`: message and location only; it stays refused | 30 |

L4a also removes `compatibility_*` in `packages/zts/src/type_env.zig` when no reader remains.
L4b also updates the two fuzz grammars in `packages/zts/src/tests/frontend_fuzz.zig`, so that a seed no longer asserts the erased form.
An erased block such as `<T> { const a = 1; }` passes today. After L4b it must report ZTS002 and must not parse as a block.
L4c derives the return kind from `ReturnSyntax.structure`. It deletes `LegacyReturnKind` and `hasLegacyGuardFacet` if no reader remains. Otherwise it renames them.

Each L4 unit also runs `test-zruntime`, `test-server`, `test-precompile`, `test-diagnostic-corpus`, `test-standin`, `test-flow-census`, `test-proof-swallow`, and `zts meta --json` with no hash move.
Stop if a change to `grammar_registry.zig`, a corpus file, or a cassette seems necessary.

### L5. One parser entry

| Unit | Class | Model | Rows | Acceptance | Turns |
|---|---|---|---|---|---|
| L5a. `compile` | A if the measurement holds | Sonnet | A14 | `compile` uses the typed entry. `bash scripts/check-semantics-spec.sh` exits 0. The comparison script moves 0 rows | 15 |
| L5b. `inline_code` | B, Decision 4 | Sonnet | A17 | `.inline_code` stays in `HandlerSource`, and it passes admission. `docs/internals/api-reference.md` states that. The two pin tests assert the refusal. `test-zruntime`, `test-server`, `test-cli` exit 0 | 20 |
| L5c. Raw entry | A | Sonnet, one commit per test file | A14 | `Parser.init` has no raw form. The 149 test call sites use the production parse mode, as reset units 3a to 3c did. D-016 names two entries: `initExpression` and `initSourceObserver`. No expected value moves | 60 |
| L5d. Aliases | B, Decision 4 | Sonnet | E15 | `pathsMatch` leaves `root.zig`, and its test goes. `loadHandler` callers use `loadCode`. `destroy` loses the parameter. `test-module-boundary`, `test-zruntime`, `test-server` exit 0 | 15 |

### L6. Unused IR tags

| Unit | Class | Model | Rows | Acceptance | Turns |
|---|---|---|---|---|---|
| L6. `NodeTag` | B, Decision 12 | Sonnet | A13 | No `.unproduced` row remains. The six builders are gone. `Opcode` does not change, and `test-bytecode-identity` exits 0. In each moved compile row, the only changed line is `semanticsHash`. The two hash pins take the new literal values, and the commit names them. `zts spec-render --out docs/spec/semantics.spec.ts` regenerates the spec, and `check-semantics-spec.sh` exits 0. `test-zruntime`, `test-server`, `test-modules` exit 0 | 40 |

Stop if an opcode, `grammarHash`, or a field other than `semanticsHash` moves.

### L7. Output spellings

| Unit | Class | Model | Rows | Acceptance | Turns |
|---|---|---|---|---|---|
| L7a. Journal `body` | B, Decision 5 | Sonnet | B2w | A new journal has no `"body"` key. A journal from the base binary still loads, by a fixture written from base output | 10 |
| L7b. Canonicalize names | B, Decision 9 | Sonnet | B14 | `legacyKind` is gone. Only the two named goldens change, by regeneration | 10 |
| L7c. Scalar response fields | B, Decision 10 | Opus plans, Sonnet implements | C14 | See the steps below | 35 |
| L7d. Installer | B, Decision 11 | Sonnet | E1 | `install.sh` has one asset form. `scripts/test-install-archive-safety.sh` loses its `LEGACY_` block and keeps its floor | 10 |

Unit L7c steps:

1. Write a table test over `responses` shapes through `diffContracts`, with literal verdicts. Include two static responses with a changed status. Run it. That row must fail with `.unchanged`, which confirms the trap.
2. Change `compareResponses` to a local dynamic test: `responses_dynamic`, or any dynamic variant. Drop the "more than one response" clause. The table must pass, and an unchanged computed handler must stay `.unchanged`.
3. Remove the scalars from the writer, the parser, `ApiRouteInfo`, and `contract_diff.zig`. Delete `syncLegacyRouteResponse`.
4. Regenerate only `full_v1.json` and the `contract_census` golden. The commit names them.

Stop if step 1 passes, because the trap then has another cause. Stop if a change to `packages/proof-checker` seems necessary.

### L8. Old stored data

| Unit | Class | Model | Rows | Acceptance | Turns |
|---|---|---|---|---|---|
| L8a. Ledger rows and `--no-sign` | B, Decision 6 | Sonnet | B6, B7, E9, E10 | With option (a): `kind=perf` and `kind=equivalence` parse as opaque rows, and the payload types go. On the stored-data ledger, `zttp proofs list`, `show`, `diff`, and `export` print the same bytes as the base binary. `--no-sign` is gone from the code, `scripts/proof-gate.sh`, `docs/cli.md`, and `docs/proofs-and-receipts.md` | 20 |
| L8b. Retired providers | B, Decision 8 | Sonnet | B13, C10 | With option (a): `zttp auth revoke claude` still deletes the stored key. `zttp auth claude` prints the unknown-provider text | 10 |

### L9. Final gate and hand-off

| Unit | Class | Model | Files | Acceptance | Turns |
|---|---|---|---|---|---|
| L9. Final | A | Opus | Plan status, worklog, `CHANGELOG.md`, `docs/roadmap.md`, `docs/decisions.md` | All commands below exit 0. Each moved row in the comparison script traces to an allowed list | 20 |

Run `bash scripts/verify.sh` from an empty local cache with the scrubbed environment.
Run `zig build smoke-v1`, `zig build smoke-getting-started`, and `zig build test-examples`.
Compare the final table with the base: `surface.sh`, `eprobe.sh`, the comparison script, and the stored-data set.
Run `git grep -n -i legacy -- packages build tooling scripts ':!packages/zts/deps'`. Each remaining line must carry a row in the worklog with its reason.
Add one `## [Unreleased]` line for each breaking change, with its migration action, as `RELEASE_CHECKLIST.md` requires.
The offline replay stays green, so no re-record is part of this plan. A unit that fails replay stops and waits for a D-012 window, as reset Decision 5 states.
`release-provenance` stays a release gate, and the next release republishes evidence.

## Owner decisions

No removal runs before the owner answers. Each decision below moves an output, or strands data.
"Remove" in option (a) means the full unit above.

Decision 1: generic arrow after a comment (A1).
- (a) Recommended. Remove. The one affected program reports the single ZTS200 that it already reports with no comment.
- (b) Keep the policy and the `compatibility_*` order in `type_env.zig`. L4a does not run.

Decision 2: erased type prefix (A2, A3).
- (a) Recommended. Remove. `const x = <T>(1);` and `const x = <T> { id: 1 };` change from accepted to ZTS002. The form has no defined meaning, because `T` need not exist. A user program with this form stops compiling.
- (b) Keep it. L4b does not run.

Decision 3: predicate second parse (A5, and A4 if it empties).
- (a) Recommended. Remove it and add an explicit refusal of an empty narrowing. The program stays refused. Its message and location can change.
- (b) Keep it. L4c does not run, and A4 takes a rename in L2.

Decision 4: raw parser, `inline_code`, and Zig aliases (A14, A17, E15).
- (a) Recommended. `.inline_code` stays in `HandlerSource` and passes admission. An embedder's inline source that admission refuses now fails at load. D-016 shrinks to two raw entries. `zts.pathsMatch` and `loadHandler` go.
- (b) Keep D-016 as it stands. L5 does not run.

Decision 5: duplicate journal `body` (B2w).
- (a) Recommended. Remove it. `events.jsonl` stops storing each result twice. A reader outside this repository that reads `body` must read `llm_text`.
- (b) Keep it. L7a does not run.

Decision 6: ledger rows `kind=perf` and `kind=equivalence`, and the ignored flag `--no-sign` (B6, E9, E10).
- (a) Recommended. Keep both kinds as opaque rows, and remove the payload types and `--no-sign`. An old project ledger keeps working. A script that passes `--no-sign` must drop it.
- (b) Remove both kinds and `--no-sign`. A ledger that holds such a row fails `zttp proofs list`, `show`, `diff`, `watch`, `export`, and `badge` for that project.

Decision 7: undocumented runtime paths (E12, E20).
- (a) Recommended. Remove both. A handler with a second parameter reads `undefined` there, not an empty object. A call on an unknown callable shape stops with an error, and no tracked program reaches that call.
- (b) Keep it. L3e does not run.

Decision 8: retired provider keys (B13, C10).
- (a) Recommended. Keep `zttp auth revoke claude` and `zttp auth revoke openai`. Remove the rest. A stored secret must stay deletable.
- (b) Remove all of it. A stored key stays on disk until the user edits `~/.zttp/providers.json`.

Decision 9: `canonicalize --json` kind names (B14).
- (a) Recommended. Print the current tag names, with a release note. A CI check that matches an old name must update.
- (b) Keep the five old names. L7b does not run. A code comment calls the version 1 surface frozen, so this option has a real basis.

Decision 10: scalar response fields in contract JSON (C14).
- (a) Recommended. Remove them. `compareResponses` then compares each static route with more than one response, so a changed status there reports `breaking`, where it reports `unchanged` today. A `dev --prove` hot-swap can stop for that route. A reader of `responseStatus` must read `responses`.
- (b) Keep them. L7c does not run, `syncLegacyRouteResponse` takes a rename in L2, and the skipped comparison stays.

Decision 11: installer fallback for `zigttp-*` assets (E1).
- (a) Recommended. Remove it. `ZTTP_VERSION=v0.18.0` or older stops installing and reports the existing missing-archive error.
- (b) Keep it. L7d does not run.

Decision 12: tag removal and the moved `semanticsHash` (A13).
Reset Decision 5 (a) selected this unit, but that decision did not state this effect, so this plan asks again.
- (a) Recommended. Remove the tags. The new runtime refuses an artifact from an earlier binary with `SemanticsHashMismatch`, and the release note says "Rebuild and redeploy earlier artifacts". A self-extracting binary keeps running.
- (b) Keep the tags. L6 does not run, and the 27 unused members stay in `NodeTag`.

Decision 13: order against the reset.
- (a) Recommended. Run L0 to L9 before reset Phases 10 and 11, so that those phases document the final design.
- (b) Finish the reset first. Those documents then need a second pass.

## Definition of done

The plan is complete when these all hold:

- Every row with a removal verdict and an approved decision is gone from live source.
- `git grep -i legacy` over `packages`, `build`, `tooling`, and `scripts`, without the vendored `packages/zts/deps`, matches only rows that the worklog keeps with a reason.
- Each moved row in the comparison script traces to a named allowed list.
- `bash scripts/verify.sh` exits 0 from an empty cache, with no test skipped beyond the base skip count.
- `docs/decisions.md`, `docs/internals/api-reference.md`, `docs/roadmap.md`, and `CHANGELOG.md` state the final design.
- No file in `packages/proof-checker` changed.
- No cassette, corpus file, or prompt changed.

## Validation record

Two reviewers checked this plan on 2026-10-30, with split briefs. Fable attacked the reasoning. Codex (`gpt-6-astra`, xhigh, read-only) fact-checked 287 claims.
I verified each load-bearing claim myself before I acted on it. Each finding below has its disposition.

### Fable: reasoning

| Finding | Severity | Disposition |
|---|---|---|
| L7c "each diff verdict stays" writes a skipped comparison down as a literal value | High | Accepted. See "The C14 trap". Unit L7c now runs a failing test first, and Decision 10 names the stricter verdict |
| `zig build test` excludes the `test-zruntime` root, so Zig units in L4, L6, and L8 had no check on that root | High | Accepted. Each Zig unit runs it |
| The comparison script never loads stored data or serves a request | Medium | Accepted. See "Stored-data set". I built the set on the base binaries: the artifact builds, the bundle verifies, and `GET /` returns 200 |
| A17, A4, and B9 used wrong wording, and the LEGACY-DEAD definition was too wide | Medium | Accepted. The rows and the definition changed |
| A word census found only rows that say "legacy" | Medium | Accepted. Rows E9 to E13 came from a second list |
| L1b was too large to review, and it rewrote where it could delete | Medium | Accepted. L1 is split by package, and deletion is the default |
| The A1 effect was stated as one file | Low | Accepted. L4a states the program shape |
| B10p has no code to delete | Low | Accepted, and B10p is NOT-LEGACY. Unit L8b and the old Decision 7 went |

### Codex: facts

Codex reported 21 defects in 287 claims. I confirmed 19 as written. Items 7 and 8 needed an adjusted reading, because the verdict stayed and only the stated reason changed.

| Number | Defect | Disposition |
|---|---|---|
| 1 | A7 named a type that does not exist | Fixed: `ProjectedGenericParameter` |
| 2 | A8 count of 472 covered one scanner | Fixed: 472, 475, and 477 together |
| 3 | A14 and L5c count of 158 included non-test sites | Fixed: 149 test call sites |
| 4 | B3 said that no writer existed | Fixed. A writer shipped in `v0.16.0-rc3` to `rc8`. The verdict stays, because `events.zig` refuses each record whose `v` is not 4 |
| 5 | B6 site counts were wrong | Fixed |
| 6 | The ledger failure scope named `gate`, which does not read the ledger | Fixed: `list`, `show`, `diff`, `watch`, `export`, and `badge` |
| 7 | B9 missed `zttp proofs bundle --contract` | Fixed. The verdict stays, on a new argument: `validate` refuses a contract older than `sourceIdentity`, and the other readers do not read the arrays |
| 8 | B10p said that no code accepts empty placeholders | Fixed the wording. Tests pin the acceptance. The verdict stays, because no separate code does this |
| 9 | B17 said that a rename forces a re-record | Fixed. The Zig name is not an identity input, so the row moves to L2. The JSON key stays |
| 10 | The session count was incomplete | Fixed: 17 sessions |
| 11 | 212 vendored sqlite lines were excluded and not disclosed | Fixed. The exclusion is stated, and the L9 grep names it |
| 12 | Appendix B did not list each probe | Fixed the claim, and added the two `erased` probes that moved |
| 13 | The script wrote rows and compared nothing | Fixed. `compare.sh` is added and tested |
| 14 | A relative binary path failed | Fixed. `oracle.sh ./zig-out/bin` then `compare.sh` ran from the repository and moved 0 of 645 rows |
| 15 | `test-server` is inside `zig build test` | Fixed |
| 16 | `zts spec-render` needs `--out` | Fixed |
| 17 | `git commit --only` is not a reset rule | Fixed. This plan states the rule |
| 18 | Three pin tests were missing from Appendix A | Fixed |
| 19 | C20 missed `docs/user-guide.md` | Fixed. `docs/README.md` also needed the same edit |
| 20 | `pathsMatch` compatibility alias had no row | Added as E15 |
| 21 | Optional recording fields had no row | Added as E16 |

Items 20 and 21 showed that the second word list was too narrow. A third list read 505 more lines and added rows E17 to E20.

### Open limits

No reviewer ran a removal. The mutations changed behavior in a scratch clone. A real deletion can expose more dependents, so each unit runs its own gates.
No reviewer saw this final text after the last edits. The edits after the Codex run are the dispositions above, rows E15 to E20, and `compare.sh`.

## Appendix A. Pin tests

The combined mutation failed 59 tests, the tag simulation adds 2 hash pins, and the skip mutation adds 9 for L3d. The third mutation adds 4 for L3f. Reading adds 3 for L3a and L8a, and 1 for L5d. The total is 78.
Attribution is by test name, because the combined run cannot separate rows. Each unit records its real subset in the worklog.
A failure outside this list stops the unit.

| Unit | File | Tests |
|---|---|---|
| L3a (B2r, B3) | `packages/pi/src/session/reconstructor.zig` | reconstructTranscript preserves legacy display and body payloads |
| L3b (B9) | `contract_json_parser.zig` | parseFromJson compatibility matrix preserves legacy API response backfill; parseFromJson legacy request backfill deduplicates schema refs |
| L3d (E11) | `contract_runtime.zig` | pins: verifyCapabilityMatrix skips when matrix is absent; verifyPolicyHash skips when hash is absent; a stamped contract with no sandbox block still validates |
| L3d (E11) | `contract_runtime.zig` | fixtures: validate promotes Raw to Validated when integrity checks pass; validate rejects artifact-hash drift; runtime validation refuses missing or stale source identity |
| L3d (E11) | `server.zig` | fixtures: a live swap drops the promotion the replaced artifact earned; promotion refuses a policy rejection; source replacement keeps failed state and retires successful generations together |
| L3f (E16) | `packages/pi/src/simulator/model_client_test.zig` | every Chat Completions provider rebuilds its wire digest on replay; simulator client rejects a semantic mismatch without consuming the response; simulator summarizer consumes a purpose-specific request checkpoint |
| L3f (E16) | `packages/pi/src/simulator/runner_test.zig` | flow runner continues a real multi-Turn transcript and preserves exact workspace bytes |
| L5d (E15) | `packages/zts/src/root.zig` | stable pathsMatch compatibility alias remains callable |
| L4a (A1) | `parser/parse.zig` | admission spaced function lists retain call arguments and runtime headers |
| L4a (A1) | `typed_frontend_tests.zig` | typed generic arrow allocation failures restore every store array; named function comment allocation failures follow source progress; untyped named function comment gaps retain final compatibility owners; typed generic arrows retain final owners and legacy projection windows; nested legacy-call line-comment arrow retains captures and semantic projection; direct phase two consumer matrix preserves generics and headers; direct phase three preserves actual and compatibility call construction; direct phase three refuses malformed call order before selection; direct phase three allocation failures retain selection and incomplete calls; direct callable generic allocation failures close scopes by construction stage; admission header fallback preserves grouped and raw arrow type construction |
| L4a (A1) | `precompile_check_tests.zig` | CHECK preserves arrow capture after line comment text |
| L4b (A2, A3) | `tests/frontend_fuzz.zig` | fuzz: direct compile holds its contract on every seed; fuzz: direct collect holds its contract on every seed |
| L4b (A2, A3) | `source_frontend.zig` | direct source retains every syntax owner family |
| L4b (A2, A3) | `parser/parse.zig` | admission preserves measured module export and operand prefixes |
| L4b (A2, A3) | `typed_frontend_tests.zig` | first erased object prefix preserves runtime and exact ownership; failed erased object prefix restores the earlier syntax checkpoint; erased object prefix type allocation failures restore the typed seed; projected erased prefix allocation failures restore the typed seed; erased prefix matrix preserves runtime ownership and projection order; erased prefixes retain direct void admission diagnostics; spaced erased prefixes preserve assignment and general captures; direct erased prefix projection retains bounds and valid empty ranges; prefix projections merge with callable generic parameters in source order; recovered erased block removes nested syntax and retains progress; erased prefix relationships reject invalid intervals and owner swaps; erased object prefix node failures restore every store array; bounded erased prefixes preserve direct consumer admission |
| L4b (A2, A3) | `precompile_check_tests.zig` | CHECK preserves admitted generic prefixes without function owners; CHECK preserves typed arrow return forms and parameter refusals; CHECK preserves measured recovery contexts and raw recognition guards |
| L4c (A5) | `parser/type_syntax_store.zig` | ordinary empty predicate retains the complete compatibility parse; return validation enforces empty predicate and compatibility facets |
| L4c (A5) | `parser/type_syntax_parser.zig` | admitted return preserves spelling and disjoint compatibility roots |
| L4c (A5) | `typed_frontend_tests.zig` | named and arrow returns retain predicate facets; ordinary predicates parse whole grammar compatibility roots; empty predicate narrowing retains the untrimmed whitespace tail; predicate compatibility range cannot own narrowing nodes; predicate header type allocation failures restore the seed checkpoint; direct predicates preserve construction and checker behavior |
| L8a (B6) | `packages/runtime/src/proof_ledger.zig` | a legacy kind=perf row written by the removed probe still loads; a legacy kind=equivalence row written by the removed probe still loads |
| L5b (A17) | `packages/runtime/src/runtime_pool.zig` | prepared evaluation caches bytecode and reload restores raw virtual parsing |
| L5b (A17) | `packages/runtime/src/zruntime_tests.zig` | prepared evaluation omits authored types while raw virtual and file profiles remain distinct |
| L6 (A13) | `typed_frontend_tests.zig` | direct single-module full and sound extraction preserve contract bytes |
| L6 (A13) | `pipeline_tests.zig` | explicit omitted selection preserves native ABI holes and hides authored signatures |
| L7a (B2w) | `packages/pi/src/session/events.zig` | appendEvent serializes tool_result with llm_text body alias and ui_payload |
| L7a (B2w) | `packages/pi/src/session/persister.zig` | appendEntry on tool_result under cap writes body unchanged; appendEntry preserves a large projected tool result exactly; appendEntry with no_persist_tool_output writes a structural placeholder |
| L7b (B14) | `packages/tools/src/canonicalize.zig` | every rewrite row has a v1 name, and only the renamed five differ; writeJson envelope covers all deterministic refactor kinds; dynamic literal-prefix capability alias is not treated as static |
| L7c (C14) | `contract_census.zig` | the full fixture writes the committed golden bytes; the full fixture writes, parses, and writes the same bytes; the golden bytes parse and write back unchanged |
| L7c (C14) | `handler_contract.zig` | parseFromJson roundtrip preserves api route response schema |
| L7c (C14) | `contract_json_writer.zig` | version 2 writes only snake_case keys; version 2's key set is exactly the snake_case image of version 1's |

## Appendix B. Hand probes

Each probe has a request handler after the line shown, unless the source already holds one.
A probe that defines a form becomes a committed test in its unit. These are the literal expected results.

| Probe | Source | Base result | Expected result |
|---|---|---|---|
| `ex/lc.ts` | `const id = // note` newline `<T>(value: T): T => value;` newline `const probe: number = id("x");` | ZTS203 and ZTS200 "type 'T' is not assignable to type 'number'" | One ZTS200 "type 'string' is not assignable to type 'number'" |
| `ex2/p1.ts` | `const x = <T> (1);` | 0 errors | ZTS002 |
| `ex2/p2.ts` | `const x = <T> { id: 1 };` | 0 errors | ZTS002 |
| `ex2/p3.ts` | `const x = <T>(1);` | 0 errors | ZTS002 |
| `ex2/p4.ts` | `const y = 2;` newline `const x = (<number> y);` | ZTS002 | ZTS002 |
| `ex2/p5.ts` | `function f(a: number): number { return <number> (a); }` | ZTS002 | ZTS002 |
| `ex2/p6.ts` | `const s: string = <string>(1);` | ZTS200 "type '1' is not assignable to type 'string'" | ZTS002 |
| `ex2/p7.ts` | `const s = <string>(1);` | 0 errors | ZTS002 |
| `erased/a.ts` | `const x = <T> { id: 1 };` | 0 errors | ZTS002 |
| `erased/b.ts` | `const x = <T>(1);` | 0 errors | ZTS002 |
| `block/b1.ts` | `<T> { const a = 1; }` | 0 errors | ZTS002 (probable; L4b confirms) |
| `block/b2.ts` | `function f(): number { <T> { const a = 1; } return 1; }` | 0 errors | ZTS002 (probable; L4b confirms) |
| `block/b3.ts` | `function f(): number {` newline `<T> { return 1; }` newline `}` | 0 errors | ZTS002 (probable; L4b confirms) |
| `ex/e7.ts` | `function isS(x: unknown): x is` newline `{ return true; }` | ZTS204 at `return true` | Refused. The code and location are for L4c to record |
| `ex/e7b.ts` | `x is<TAB>string` in a return type | ZTS211 | ZTS211 |
| `ex/g.ts` | `function isS(x: unknown): x is string { return typeof x === "string"; }` | Passes | Passes |

Mutation evidence covers the rows that moved. The three `block` probes ran on the base binary only.
