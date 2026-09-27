# Review: rederiving the acceptance kernel (`packages/proof-checker`)

Status: implemented 2026-09-25. Owner: this repository. Measured on 2026-09-24 against
commit `dea0eddc`. The trusted-node fix, the kernel build mode, the removal of
`rule_family_mismatch`, and Phases 0 to 4 are committed. See "Results" at the end.

## Owner decisions (2026-09-25)

1. **Kernel build mode: `ReleaseSafe` in release builds.** Done in `0384765a`. All three
   declarations of the kernel dependency (root, `packages/runtime`, `packages/tools`) compute
   the same mode, so they still dedup into one module. Measured on the kernel fixture: about
   1.5 us per `check` call under `ReleaseFast` and about 1.95 us under `ReleaseSafe`, paid
   once per start in `Server.start`. A real handler certificate was not measured.
   **Correction (2026-09-26):** the pin had no effect. On Zig 0.16.0 runtime safety follows
   the root module, so a ReleaseSafe dependency under a ReleaseFast root runs with no checks
   (measured with a two-module probe). The pin is removed; every non-test kernel function
   now begins with `@setRuntimeSafety(true)`, enforced by `zig build test-kernel-safety`.
   The timing difference above therefore did not come from runtime safety.
2. **`rule_family_mismatch`: removed, number 1503 retired.** Done in `ecacf029` and
   `45e80999`. The policy hash did not move: it covers the zts rule registry, and zts does not
   import the kernel. Only the vocabulary envelope changed.
3. **`Assessment` redesign (T1): accepted for Phase 4, after Phase 0.**
4. **`work_spent` (M4): keep the count identical** with one walk over both member kinds, so
   Phase 2 is a pure refactor. Its acceptance check is that every `Assessment` from the kernel
   suite and the ratchet corpus is identical before and after.
5. **T5 and T6: accepted for Phase 4. T7: declined.** The owner left the choice to the
   implementer. T7 fails its own precondition: the stage does not follow from the code.
   `obligation_missing` is emitted under `obligation_reconstruction` (`checker.zig:991`) and
   under `evidence_check` (`:1194`), so deleting `Rejection.stage` would lose information.
6. **Section 7 behavior questions: pin the current behavior.** Phase 0 pins that a rewrite
   with no translation section is not checked, and that the residual-plan member loop keeps
   its current shape. Neither changes in this series.

## 1. Executive summary

`packages/proof-checker` is the only code in this repository whose verdict decides whether
an artifact may serve production traffic. Its architecture already meets the target: it is
a leaf that imports only `std`, allocates nothing, holds no mutable statics, and reaches no
ambient capability. The review found no hexagonal violation to repair.

The weakness is inside the package, and it is in the tests more than in the code. A
mutation probe of 204 non-equivalent single-point mutants killed 80 (39%). In `checker.zig`,
which produces the verdicts, the suite killed 21 of 88 (24%). Specific consequences, each
reproduced by the supervisor on a fresh build cache:

- Disabling the executable-root comparison (`checker.zig:1537`) leaves all 183 kernel tests
  green. No `.zig` file in the repository names `executable_root_mismatch`,
  `graph_member_extra`, or `zero_commitment`.
- Deleting the empty-ledger-id refusal (`invariant.zig:424`) leaves all 183 tests green.
- Mutant C16 (an unknown non-zero evidence rule decodes as "no rule") survives. Production
  code refuses it today (`certificate.zig:513-516`), but no test holds that refusal, and
  `validEvidenceShape` (`checker.zig:1420-1421`) accepts a null rule for `trusted`, `tested`,
  and `not_established` edges. A regression on that one line is a silent fail-open.

The code side has measured, low-risk reductions. Three independent drafts, each green on the
full suite with a fresh cache, cut production decision points from 998 to 779 (-219, -22%)
and the maximum cyclomatic complexity from 59 to 39. Type-driven changes add to this: they
make contradictory `Assessment` values unrepresentable and delete a reason code
(`rule_family_mismatch`) that nothing can produce.

The order is fixed by the playbook rule that a rederive is only as safe as the suite that
judges it: tests first (Phase 0), then mechanical reductions, then type-driven changes.

Target after the plan, all projected from measured drafts unless marked: production
branches 998 to about 780, maxCC 59 to 39, functions with CC above 10 from 27 to 19,
mutation kill rate from 39% to a floor of 90% of non-equivalent mutants (a target, to be
measured).

## 2. Baseline measurements

Method. Decision points were counted with a scratch `std.zig.Ast` walker (not committed).
It counts `if`, `while`, `for`, each `switch` prong beyond the first, `and`, `or`, `orelse`,
and `catch`, and attributes each one to the innermost `fn` or `test`. "prodL" and "branch"
exclude `test` blocks. The walker was validated by hand on `limits.zig` before it was run on
the whole package. Line and branch coverage were not measured: Zig 0.16 has no coverage
instrumentation on macOS and kcov is not installed. The mutation kill rate is the test
strength measurement used instead.

Every mutant ran with its own fresh `--cache-dir`. A reused cache gave stale verdicts for
mutants that did not change the file size. One scout measured a mutant that reported 183
passes on a shared cache and 22 failures on a fresh one.

| File | LOC | prod LOC | branches | try | fns | max CC | CC>10 | tests | mutants killed |
|---|---|---|---|---|---|---|---|---|---|
| checker.zig | 3579 | 2373 | 335 | 107 | 87 | 59 | 8 | 80 | 21/88 (24%) |
| certificate.zig | 1492 | 1365 | 210 | 140 | 53 | 33 | 9 | 10 | 6/23 |
| invariant.zig | 1383 | 875 | 100 | 11 | 31 | 16 | 2 | 33 | 14/24 |
| residual.zig | 690 | 498 | 82 | 2 | 31 | 25 | 1 | 12 | 8/15 |
| declaration.zig | 702 | 551 | 53 | 18 | 32 | 18 | 1 | 6 | 11/12 |
| tool_catalog.zig | 792 | 661 | 51 | 42 | 34 | 15 | 2 | 6 | 6/12 |
| proof_system.zig | 340 | 289 | 43 | 0 | 11 | 9 | 0 | 5 | 2/4 |
| capability_policy.zig | 526 | 327 | 38 | 14 | 21 | 11 | 1 | 8 | 6/9 |
| verdict.zig | 569 | 512 | 36 | 0 | 22 | 13 | 1 | 6 | 4/8 |
| executable_graph.zig | 350 | 282 | 34 | 5 | 15 | 21 | 1 | 8 | 2/9 |
| policy.zig | 205 | 149 | 15 | 0 | 6 | 8 | 0 | 6 | - |
| limits.zig | 95 | 75 | 1 | 0 | 3 | 2 | 0 | 3 | - |
| **total** | 10806 | 8016 | **998** | 339 | 346 | 59 | 27 | 183 | **80/204 (39%)** |

The mutant denominators exclude equivalent mutants. There were 18 of them, each named in the
scout logs. `root.zig` and `test_root.zig` hold no logic. The suite runs in 30 ms
(`zig build test-proof-checker`), so no test is slow.

Highest-complexity functions: `checkInvariantCoverage` 59 (`checker.zig:511`),
`checkEvidence` 46 (`:1184`), `decodeRecord` 33 (`certificate.zig:471`), `decodeSection` 28
(`:738`), `bindExecutableGraph` 26 (`checker.zig:1463`), `normalizeEndpoint` 25
(`residual.zig:341`). `reasonFor` (15) and `verdict.name` (13) are also high, but they are
exhaustive per-variant tables and are not targets.

## 3. Findings, ranked by leverage

Mechanical findings are judged by the branch delta. Type-driven findings are judged by
whether an illegal state becomes unrepresentable.

### Mechanical

**M1. Identity-map `fromWire` and `name()` switches (all files except checker).** Of the 25
`fromWire` functions, 23 restate explicit enum values that `std.enums.fromInt(E, v)` already
decodes, and 5 `name()` switches return `@tagName`. Keep `AssuranceGrade.fromWire` (one-based)
and `ScopeSet` (a bitset). Measured draft across residual, executable_graph, proof_system,
invariant, and verdict: branches 295 to 187 (-108), 148 fewer lines, 183/183 pass. The
certificate share is included in M2. Risk: low, with two exceptions for gates that read
the source as text. `scripts/check-proof-ratchet.sh:49` reads the property alphabet from
the literal `.x => "x",` rows of `Property.name`. `scripts/check-residual-guards.sh:99`
regex-matches the `GuardKind` method switches. Change the ratchet gate to read the enum
fields before `Property.name` changes, and leave the `GuardKind` methods as switches.

**M2. One slot table for the eleven certificate sections (`certificate.zig`).** Five parallel
11-arm switches (`countLimitFor :625`, `recordSizeFor :641`, two in `decodeSection
:775-806`) and a hand-unrolled `encodedSize`, `sectionCount`, and `encode` with six
`if (len > 0)` guards all restate one mapping. Rederive them as one `slot(tag)` table with
`inline else` dispatch. Measured draft: certificate branches 210 to 147, CC>10 from 9 to 6,
all tests pass. A differential test showed byte-identical `encode` output for both the
minimal parts and the parts with all 11 sections. The draft also removes the two
`.identity => unreachable` prongs (`:776`, `:795`), which the early return at `:745` makes
unreachable only through control flow.

**M3. One shared wire reader (`declaration.zig`, `tool_catalog.zig`, `capability_policy.zig`).**
`Reader` is copied word for word (`declaration.zig:151-174`, `tool_catalog.zig:156-185`).
`capability_policy.zig:159-183` has a third copy as `Cursor`. Six iterators, two test
writers, two `digest()` bodies, two header checks, and six "previous must be strictly less"
loops repeat the same shape. Rederive them as a sibling `wire.zig` that imports only `std`,
with each decoder keeping its own error set through a comptime error argument. Measured
draft: the three files plus `wire.zig` go from 142 to 120 branches, and 185/185 tests pass.
Together with M2 the decoders go from 352 to 267 branches. Risk: low. `wire.zig` must be
added to `scripts/check-proof-swallow.sh`, or logic moved out of the gated
`capability_policy.zig` leaves the gate.

**M4. Tool-catalog and declaration stages are one function (`checker.zig:408-450`, `:460-502`).**
They differ only in member kind, stage, three reason codes, and decoder. The same "exactly
one member at ordinal 0 with digest D" loop appears again for the invariant spec and adapter
(`:558-597`). Rederive: `bindMember(kind, digest)` returning
`union { missing, bound, mismatch: Member }`, plus one generic bound-bytes check.

**M5. `checkInvariantCoverage` mixes two contracts (`checker.zig:511`, CC 59).** The
unconfigured path ("nothing invariant-shaped may appear") and the configured path
(pairwise witness and observation matching) share one body. The body also builds the same
`.{ .rejected = reject(.invariant_coverage, ...) }` shape 25 times. Split out
`checkInvariantSite` returning `union { refused: ReasonCode, covered: bool }`. The
`!result.ready()` check at `:717` cannot fail after the loops above it. It becomes an
assertion only after Phase 0 pins the loops.

**M6. `bindExecutableGraph` as a plain merge join (`checker.zig:1463`, CC 26).** The observed
index always equals the loop index. The `while` at `:1497` always returns, so the
`.lt => unreachable` at `:1509` exists only to satisfy it. The two lookups after the root
check (`:1549-1581`) are one helper.

Measured draft of M4 to M6 plus T2 (restructure only), T3, and T4: `checker.zig` goes from 335 to 309 branches, maxCC
from 59 to 39, production lines from 2373 to 2238. All 183 tests pass on a fresh cache. One
behavioral side effect: the work spent on the invariant fixtures rises by 9 to 10 units,
because the spec and adapter are walked separately. A single two-kind walk restores the old
figure. Decided: keep the old figure (owner decision 4).

**M7. `normalizeEndpoint` (`residual.zig:341`, CC 25).** Split it into `parseScheme`,
`authorityOf`, `splitHostPort`, and `canonicalHost`, and replace the hand-rolled
`asciiEqlIgnoreCase` with `std.ascii.eqlIgnoreCase`. Measured draft: maxCC 25 to 8, -5
branches, and a differential fuzz of 800,000 calls against the original matched every
output and error. The byte-identical second implementation in `zts/src/endpoint.zig:60-100`
is pinned by the differential test at `runtime/src/proof_activation.zig:345-349`, which must
still pass.

**M8. Small dead code.** `verdict.zig:371` (`if (artifact == .not_applicable)`) is redundant.
`SemanticState.atLeast` (`verdict.zig:28`) has no caller except its own test. In
`checker.zig`: `entryFunction` is re-derived twice with a dead `orelse` (`:946`, `:1302`),
the `count == 0` check at `:868` is covered by the handler count, and the obligation "seen"
loop (`:981-993`) is implied by the count, strict order, and reconstruction checks. Each was
confirmed by an equivalent mutant. Delete them only after Phase 0, so that an implied guard
is proven by a test before the explicit one goes.

### Type-driven

**T1. Before Phase 4, `Assessment` could hold contradictory states (`verdict.zig:457-506`).** It could represent
`policy_accepted` with a rejection (mutant V5 survives), `policy_accepted` with a null
grade, a grade below `proof_checked`, and a stop below `policy_accepted` with no rejection.
The kernel never produced these values, but the runtime paid to defend against them:
`contract_runtime.zig:428` has `grade orelse return null`, and `server.zig:4674-4694` tests
both impossible shapes. The initial proposed shape was:

```zig
pub const Reached = union(enum) { parsed, integrity_verified, proof_checked: ?AssuranceGrade };
pub const Outcome = union(enum) {
    accepted: struct { grade: AssuranceGrade, properties: PropertyVerdicts, disclosed_edges: u32 },
    rejected: struct { reached: Reached, rejection: Rejection },
};
```

`proof_checked` keeps an optional grade, because the policy rejections at `checker.zig:1337`
and `:1349` stop there without one. Nine construction sites outside the package change.
Risk: medium, because this is a public API used by runtime and tools. `Assessment.reject`
also hard-codes `development_only = false` (`verdict.zig:501`), a claim nothing checked. The
new shape must carry that field honestly. The Phase 4 type uses an `Outcome`
union. Its accepted member requires a grade and a declared development flag.
Its rejected member requires a `Rejection`, a `Reached` value, and an optional
development flag. The flag is null until certificate decoding returns an
identity. A `proof_checked` rejection can have an optional grade. Provenance,
work spent, property verdicts, disclosed edges, guard verdicts, and invariant
verdicts stay on `Assessment` because both outcomes can report them.

**T2. `rule_family_mismatch` has no reachable producer (`verdict.zig:206`).** The checks at
`checker.zig:1237` and `:1250` re-test what `validEvidenceShape` (`:1412`) already refused.
Rederive the evidence stage as `classify(entry, property) ?Claim` with
`Claim = union(enum) { proved: Rule, translation_validated: Rule, solver, trusted, tested,
not_established }`, handled by one exhaustive switch. Measured: `checkEvidence` goes from
CC 46 to 16, and the total branch count stays flat, as expected for a type-driven change.
Decided and done: the reason code was removed (owner decision 2). The policy hash did not
move; only the vocabulary envelope changed.

**T3. The entry function is found three times.** `checkIrShape` already forces exactly one
handler. Return `union { entry: u32, rejected: Outcome }` from it and pass the entry on
explicitly. This deletes the two dead `orelse` branches in M8. It is included in the
`checker.zig` draft numbers.

**T4. `executable_graph.Error` is one set shared by four functions (`executable_graph.zig:152-158`).**
`push` can only fail two ways, which forces a closed-set `else =>` at `checker.zig:1491`.
`push` also reports count overflow as `NotOrdered` (`:192`), so the checker labels it
`graph_member_out_of_order`. Give each function its own error set, and add
`CountExceeded` to `push`.

**T5. Before Phase 4, `invariant.Spec` carried states the decoder never produced (`invariant.zig:182-195`).**
`schema: u16` admitted schema 7, which `recordAt` (`:237`) treated as v1. `Spec.kind` was always
`.balance_conservation_v1` and had no production reader. Phase 4 uses
`Schema = enum(u16) { v1 = 1, v2 = 2 }` with a `kinds: union(Schema)` field and removes
`kind`. The external reader in `tools/src/invariant_config.zig` reads the tag.

**T6. Before Phase 4, `PropertyVerdicts` did not tie the accepted bit to the grade (`verdict.zig:428-453`).**
`accept()` could set a bit whose grade slot was null. Phase 4 uses
`[count]union(enum) { none, graded: G, accepted: G }`. Both public read methods
retain their behavior for valid entries.

**T7. `Rejection.stage` is independent of `code`.** `checker.zig:276-281` reports
decode-block codes under `.limits`, and `else => .unknown_enum_member` swallows the rest of
the session error set. Decide whether the stage follows from the code. If it does, derive
it and delete the field.

## 4. Test-correctness findings (prerequisites)

These block every code phase. Each item names the behavior that a new test must pin through
the public `check` or `decode` entry. In every case the listed mutant survived on a fresh
cache.

Security-relevant, fail-open if the guarded line regresses:

- Artifact binding (`checker.zig`): the root mismatch (BND04), missing required graph
  kinds (BND03b), `proof_ir` member digest not equal to `identity.ir_root` (BND05), the
  certificate member not equal to the commitment digest (BND06), and an extra observed
  member that sorts after every claimed member (BND02). The only extra-member test uses
  `dep_bytecode`, which is wire kind 2.
- Evidence (`checker.zig`): `obligation_without_evidence` (EVD11), a property with both
  refused and graded evidence (EVD12), a non-trusted grade in the trusted inventory (EVD09),
  `witness_missing` (EVD07), and the fabricated-property path. The test at `:2863` accepts
  either `rule_premise_unmet` or `fabricated_property`, so it pins neither.
- Invariant coverage (`checker.zig`): every guard on the unconfigured path (INV01-04). A
  `ledger_call` with no spec is accepted under the mutant. Also a witness `code_offset` that
  differs from its observation (INV15), and an unwitnessed `ledger_call` when the counts are
  equal (INV24).
- IR shape (`checker.zig`): a bad node id, a handler that is not a function, a non-zero root
  parent, two handlers (IRS02-04, IRS11), and the depth bound. The depth bound needs
  `max_depth = 2` on the three-deep fixture, because `max_depth = 1` cannot tell `>=` from
  `>` (IRS07).
- Certificate decoding: an unknown non-zero evidence rule (C16); a non-zero `aux` on a
  non-aux IR tag and IR flag byte `0x02` (C13, C22); one reserved-range probe per record type
  (C14, C15, C17, C18, C19, C23, C24; only Obligation byte 3 is probed today); identity flag
  `0x02` (C08); slack bytes inside a table section (C09, a malleable encoding); and each
  required section dropped in turn (C07; only `evidence` is dropped today).
- Executable graph: a golden root literal. Mutants G4, G5, and G7 show that no test proves
  the root binds the ordinal, the count, or the kind.
- Capability policy: a `max_policy_bytes + 1` input (P01; the test at `:453-461` asserts only
  the constant), and an SQL flag byte or enabled byte of 2 (P02, P03). P03 is read as
  "disabled" today.
- Invariant spec: an empty ledger id (I11), and the ledger id, currency, scale, matcher, and
  kind-count bounds (I7, I8, I12, I13, I14, I1). `invariant.zig` has no decode-error census,
  and 10 of its 26 `DecodeError` members are never asserted.

Structural weaknesses in the suite:

- The error censuses in `certificate.zig:1420`, `declaration.zig:638`, and
  `tool_catalog.zig:753` need only one probe per error, so a second site that returns the
  same error goes unprobed. Seven reserved-byte sites share `ReservedFieldNonZero` and
  survive for that reason. Change the census to count sites, not errors.
- About 18 reason codes have no test anywhere in the repository. Only the tool-catalog and
  declaration stages have a reason-code census. Add censuses for the binding, evidence,
  invariant, and guard codes.
- The certificate round trip proves only self-consistency. The only producer
  (`runtime/src/proof_certificate.zig:347`) calls the kernel's own `encode`, so a layout
  error made in both directions passes every test in the repository. Add one pinned
  golden-bytes vector, or its SHA-256, for a certificate with all 11 sections.
- These tests assert nothing: `checker.zig:2447-2450`, `residual.zig:507-513`, and
  `proof_system.zig:335-340` discard a value with `_ =`. `verdict.zig:552-569` checks only
  that each name is not empty.
- These tests assert only the stage or `!accepted`: `checker.zig:2777`, `:2886`, `:2954`,
  `:2969`, `:2979`, and `:3176`. The test at `:2473` is titled "omitted, extra, duplicated, or
  reordered guard" but covers only omitted and extra.
- Every fixture has exactly one ledger call, one guard, and one handler, so no test crosses a
  multi-site boundary. Most surviving ordering mutants depend on this.
- Tool-catalog bounds: the test "a catalog at the entry and export bounds decodes" (`:778`)
  writes no exports (T10). Also missing: InvalidUtf8 cases for four string fields (T03-T06),
  GET and POST of one path in the same catalog (T01), and a declaration case that is ordered
  only by source kind (D12).

## 5. Architecture findings

The kernel meets the hexagonal target. It is pure, allocation-free, and has no container
`var`, no `threadlocal`, and no `extern`, `export`, `asm`, or `@embedFile`. The gaps are at
its boundary.

- **Fixed in `d8d31f06`: trusted edges at absent IR nodes were accepted.** A trusted edge
  carries no rule, so its `node_id` never reached the rule path's bound. Trusted inventory
  `.node` members were never bounded either, and `trustedEdgeDeclared` compared the `u16`
  member against a truncated `u32`. A probe certificate with 3 IR nodes and a disclosed
  trusted edge at node 7 was accepted under `policy_mod.production`. Every evidence node and
  every inventory node is now bounded, and three tests pin the refusal. One test also covers
  a node that differs above 16 bits. The widened comparison has no test of its own: that
  needs more than 65,536 IR nodes, and the default limit forbids it.
- **The kernel runs without runtime safety in release binaries.** Releases build
  `-Doptimize=ReleaseFast` (`.github/workflows/release.yml:129`), and the root build (then `build.zig:226-229`; since 0384765a `proof_checker_optimize` in `build/Context.zig` selects ReleaseSafe)
  passes that mode into the kernel dependency. An out-of-range cast, a slice outside its
  bounds, or overflow reached from certificate bytes is a panic in the Debug tests and
  undefined behavior in production. Every such site checked in this review has an explicit
  guard, but section 4 shows that many guards are not pinned by a test. Option: build the
  kernel dependency as `ReleaseSafe` whenever the root is not `Debug`. The kernel runs at
  artifact validation, so a safety panic refuses the artifact. Decided and done (owner
  decision 1).
- **Enum bitmasks without a width guard.** `GuardKind` into `u8` (`checker.zig:794`),
  `AddressScope` into `u8` (`residual.zig:220`), and `Property` into `u16`
  (`verdict.zig:428-451`). A new member past the width is undefined behavior in
  `ReleaseFast`. Use `std.EnumSet`, or add a `comptime` assert on the member count.

- **Producer code lives in the kernel.** The certificate encoder (`certificate.zig:951-1188`)
  is called in production by `runtime/src/proof_certificate.zig:326-368`. Four test encoders
  are `pub` in the kernel: `checker.test_support :1592`, `certificate.fixture :1189`,
  `declaration.test_support :321`, and `tool_catalog.test_support :381`. Runtime tests use
  the last two. `docs/threat-model.md:42-46` says the authority surface is one directory.
  That directory now also holds encoding. Keep the encoder in the kernel (one definition of
  the format is better than two), but gate it: production kernel code may not reach
  `test_support` or `fixture`, and the golden vector from section 4 must pin the format
  independently.
- **The public surface is wider than its use.** 229 `pub` declarations, 130 named outside the
  package, 80 used only in their own file. Candidates to make private: the record-size
  constants, digest-domain strings, and `*Table` aliases in `certificate.zig`, plus
  `root.GuardVerdicts` and `root.InvariantVerdicts`, which have no users. The whole
  `capability_policy` namespace has no external user.
- **The purity gate has holes** (`scripts/check-proof-checker.sh`). Its forbidden list has
  no `std.Io`, `std.log`, `std.debug.print`, `std.c.`, `std.atomic`, `@embedFile`, `extern`,
  or `asm`, and nothing checks for container `var` or `threadlocal`. Its floors are
  `min_tests=40` against 183 tests and `min_sources=6` against 14 files, so 143 tests could
  be deleted without a failure. Raise the floors to the current counts minus a small margin,
  and add the missing patterns.
- **Wire formats defined twice.** Declaration, tool catalog, capability policy, residual
  catalog, and endpoint normalization each have a producer copy. Each has a drift check,
  with one exception: the tool-catalog magic is duplicated (`tools/src/tool_catalog_encoding.zig:17`
  and `tool_catalog.zig:56`) and not compared at compile time. The schema is compared.
- **Panics a certificate might reach.** `checker.zig:105` (`std.debug.assert`, undefined
  behavior in ReleaseFast) and `checker.zig:1509` must be shown to be unreachable from input
  bytes. M6 deletes the second. The `certificate.zig` prongs were checked and are guarded by
  `:745`.

## 6. Docs to update

- `packages/proof-checker/build.zig:9` names `scripts/check-proof-checker-purity.sh`. The
  script is `scripts/check-proof-checker.sh`. This is stale today.
- `AGENTS.md:37` says the fourteen files in `check-proof-swallow.sh` cover "the consumer-side
  acceptance kernel". Only `checker.zig` and `capability_policy.zig` are listed
  (`scripts/check-proof-swallow.sh:59-60`). Either add the other kernel files or correct the
  sentence. Add `wire.zig` if M3 lands.
- `residual.zig:301-303` says the producer and the checker call one function. The producer
  has its own copy in `zts/src/endpoint.zig`.
- `docs/consumer-contract.md:486-545` (ZTCAT1 and ZTDCL1 layouts, bounds, decoder paths),
  `:580-600` (generated alphabet table with kernel paths), and `:619-623`. The generated
  parts are regenerated, not hand-edited.
- `docs/consumer-contract-envelope.json` (generated) if T2 removes a reason code.
- `docs/internals/testing.md:318-340`, if the purity gate changes.
- `docs/internals/architecture.md:23`, `docs/threat-model.md:42-46`: the leaf and
  one-directory claims, if the encoder policy changes.
- `docs/verification.md:782` (`Property.consumerChecked`), if the ratchet gate changes.
- Plans that cite kernel line numbers: `docs/plans/2026-09-22-m4-release-contract.md:46,112`
  and `docs/plans/2026-09-23-m4-t3-catalog-binding-design.md:54,134,191-192`. These move on
  any edit. They are historical records, so leave them unless a plan is still in progress.

## 7. Additional re-basing tasks

- **A mutation-probe build step.** The kill rate was the only test-strength measurement
  available, and this review measured it with scratch shell scripts. A `zig build
  test-proof-checker-mutants` step, written in Zig as AGENTS.md requires, would apply a
  committed mutant list to a copy of the package, run each mutant with a fresh cache, and
  fail on a surviving non-equivalent mutant. The equivalent mutants would be an allowlist
  with a stated reason for each row, in the style of `scripts/unseeded-rules.allow`. This is
  what keeps the Phase 0 gains from decaying.
- **A verdict-path census.** Iterate `ReasonCode` and require that each code is produced by
  at least one kernel test or has an allowlist row. This would have caught
  `rule_family_mismatch` and the 18 unpinned codes.
- **Move `check-residual-guards.sh` off Python.** It regex-parses `residual.zig`, and
  AGENTS.md treats Python as legacy to remove when an area is touched. M1 and M7 touch it.
- **Budget accounting for `Section.get`** (`capability_policy.zig:50-58`). Each lookup is
  O(index) and is not charged to the budget. Low priority.
- **The residual-plan member loop** (`checker.zig:745`) spends no budget and does not require
  ordinal 0 or a single member, unlike every other member binding. This is a behavior
  question for the owner, not a mechanical fix.
- **Rewrites are not checked when the translation section is empty** (`checker.zig:1078`
  returns before `checkRewrites`, mutant TRN10). Decide whether a rewrite with no
  translation is refused, and pin the answer.

## 8. Phased plan

Every phase is one or more commits. Each phase ends green on the listed commands, read from
the exit status directly and never from a `-Dtest-filter` run.

**Phase 0: tests and gates, no production change.** Add every test in section 4, the golden
certificate vector, the golden graph root, the site-counting error censuses, and the
reason-code census. Raise the purity-gate floors and add the missing patterns. Fix the two
stale doc references. Build the mutation-probe step (section 7). Decide the kernel build mode (section 5) from a measured cost.
Verify: `zig build test-proof-checker`, `zig build test-proof-checker-purity`,
`zig build test-proof-checker-mutants`.
Expected: at least 90% of non-equivalent mutants killed in every file (baseline 39%), and
every `ReasonCode` either produced by a test or allowlisted with a reason. Production
branches unchanged at 998.

**Phase 1: table-driven mechanical cuts (M1, M2, M3).** Move the ratchet gate off the
`Property.name` text first, then replace the identity maps, add the certificate slot table,
and add the shared `wire.zig`. Add `wire.zig` to `check-proof-swallow.sh`.
Verify: Phase 0 commands plus `zig build test-proof-ratchet-drift`,
`zig build test-residual-guards-drift`, `zig build test-proof-swallow`, `zig build test`.
Expected: branches 998 to about 805 (-108 from M1 and -85 from M2 plus M3, both measured).
Mutation kill rate held.

**Phase 2: checker restructuring (M4, M5, M6, T3, T4, M8, and the `Claim` restructure from T2).** Keep the `work_spent` count identical (owner decision 4).
The unreachable `rule_family_mismatch` branches are already gone.
Verify: Phase 1 commands plus `zig build test-cli` (end-to-end acceptance in
`build_command.zig`), `zig build test-proof-ratchet`, `zig build test-invariant-drift`.
The invariant drift gate pins six exact `checker.zig` test names
(`tools/src/invariant_drift_gate.zig:105-110`), so keep them.
Expected: `checker.zig` 335 to 309 branches (measured), maxCC 59 to 39.

**Phase 3: endpoint split (M7).**
Verify: Phase 1 commands plus the runtime unit root that holds
`proof_activation.zig:345-349` (run by `zig build test`).
Expected: `residual.zig` maxCC 25 to 8, -5 branches (measured on its own).

**Phase 4: type-driven public changes (T1, T5, T6).** T1 is accepted (owner decision 3).
T5 and T6 are accepted and T7 is declined (owner decision 5). T2 is done.
Verify: `bash scripts/verify.sh` on a clean tree. This covers
`test-vocab-envelope-drift` and the policy-hash pins.
Expected: the branch count may rise. Success means the compiler refuses the contradictory
`Assessment` shapes, `contract_runtime.zig:428` and the two defensive tests in
`server.zig:4674-4694` are deleted.

## 9. What not to touch

- `foldTotality`, `ruleAt`, `anyChildTotal`, `allChildrenTotal`, `checkRewrites`, `BitSet`,
  `DepthTable`, and `RangeStack` in `checker.zig`. They are small, exhaustive, or fully
  killed.
- `reasonFor`, `SectionTag.required`, and the `EdgeKind` methods in `certificate.zig`. These
  are type-driven tables with no duplicate.
- The declaration decoder (11/12 mutants killed) and the guard per-field comparisons in
  `checker.zig` (all killed by the table test at `:2511`).
- `limits.zig`, `policy.zig`, `Budget` stickiness, the comptime guards in `invariant.zig:139-164`
  and `residual.zig:274-284`, and the pinned digest literals in `invariant.zig:867,884`.
- `DuplicateSection` in `certificate.zig`. The strict-order check subsumes it, but removing
  it changes a public reason code for no behavioral gain.
- All 18 `else =>` prongs in the non-checker files. Each one switches on a raw wire integer,
  which is an open set. M1 removes 16 of them as a side effect. None needs removal for its
  own sake.
- Scope trap: do not rederive the producer side (`runtime/src/proof_certificate.zig`,
  `zts/src/endpoint.zig`, `tools/src/*_encoding.zig`) in the same series. Its drift gates are
  what judge the kernel change.

## Results (2026-09-25)

Measured with the same scratch AST walker as section 2. The walker counts top-level test helpers
as production code, so the Phase 0 tests raised the starting count from 998 to 1066.

| Measure | Before Phase 0 | After Phase 4 |
|---|---|---|
| Kernel tests | 186 | 279 |
| Mutation kill rate, non-equivalent mutants | 80/204 (39%) | 248/248 (100%), 9 equivalent rows |
| Decision points (walker, incl. test helpers) | 1066 | 900 |
| Largest acceptance-function CC | 59 (`checkInvariantCoverage`) | 30 (`checkConfiguredInvariants`) |
| `checkEvidence` CC | 46 | 19 |
| `normalizeEndpoint` CC | 25 | 8 |

Phase 1 gave most of the branch cut (1066 to 897). Phase 2 cut complexity, not branches (897 to
895). Phase 4 added branches (to 900), as section 8 expected for a type-driven change. The plan's
projected -219 branches assumed the checker draft; the measured Phase 2 cut was smaller.

Gates added: `zig build test-proof-checker-mutants` (manual, about 100 s; the list is
`packages/tools/src/proof_checker_mutants.zon`, read at run time), a reason-code census and higher
floors in `scripts/check-proof-checker.sh`, and more forbidden patterns in the same script.

Equivalence evidence: Phase 2 printed every `Assessment` from the kernel suite (196) and the ratchet
corpus (4) before and after, and the traces were identical, `work_spent` included. Phase 3 compared
the old and new endpoint normalizer on 800,015 generated inputs. In Phase 4 the traces differ only
where the old `Assessment.reject` hard-coded `development_only = false` before an identity was
decoded; the new type reports it as unknown.

Not done: moving `scripts/check-residual-guards.sh` off Python, the `Section.get` budget, and the
producer-side rederive. These are section 7 items outside Phases 0 to 4.
