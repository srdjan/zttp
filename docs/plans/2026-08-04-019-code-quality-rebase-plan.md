# Code quality rebase plan

Status: proposed, not approved for implementation

Date: 2026-08-04

Checkout: `main` at `662c2416c11418ba14d2948d23741792c7079431`

## Executive summary

The repository is healthy enough to refactor, but it is not ready for a broad rewrite. The live checkout passes 4,753 aggregate tests, with 5 skips and no failures. The main risk is not failing tests. It is that several important behaviors do not yet have tests or measurements strong enough to protect a reimplementation.

The highest-priority finding is a type-soundness defect in generic intersection instantiation. `tryInstantiateGenericApp` copies at most 16 intersection members and can rebuild a changed intersection from that truncated slice. The type pool deliberately preserves intersections longer than 16 because dropping a member drops a constraint. This needs an end-user `zts check` reproduction before any adjacent type-system refactor.

After that prerequisite, two bounded rederives offer the clearest measured simplification:

- Replace the private parser in `comptime.zig` with the main parser IR and a small, explicit evaluator.
- Replace the handwritten contract JSON decoder with a typed wire DTO plus pure projection into owned domain values.

Together, those files currently contain 2,434 production branch points outside inline tests. A conservative AST count identifies at least 389 removable decisions, reducing the pair to at most 2,045 and the repository baseline from 49,639 to at most 49,250. This is a floor, not a target. Both implementations should be derived from public behavior, documentation, and black-box fixtures, not translated line by line from the old control flow.

Four production thread-local channels can also become explicit ownership:

- active module authorization belongs on `Context`
- parallel workflow collection belongs on `Context`
- JSON shape caching belongs on `HiddenClassPool`
- the unwritten `current_interpreter` channel can be removed

That reduces production `threadlocal` declarations from 10 to 6 without changing the deliberate process-level panic, entropy, math-randomness, and trace channels.

The internal-module allowlist is useful containment, not a completed architecture boundary. It currently records 102 internal reaches across four consumer packages. It must never grow during this work. It should shrink only when a cohesive public port replaces a real cluster of internal imports. A physical package split is not justified yet.

## Scope and decision rules

This is a planning artifact only. It does not approve behavior changes, delete code, or modify generated outputs.

Implementation must follow these rules:

1. Preserve public behavior unless the user explicitly approves a contract change.
2. Reproduce correctness defects through the closest user-facing path before fixing them.
3. Derive replacements from tests, documentation, serialized fixtures, and public interfaces. Do not translate the old implementation line by line.
4. Track type-driven quality separately from branch reduction. Exhaustive tagged-union switches are a strength even when they increase the raw count.
5. Keep each phase independently reviewable and green.
6. Do not widen `scripts/module-boundary.allow`, weaken runtime-purity checks, or edit generated files by hand.

## Baseline measurements

### Repository baseline

The measurements below were taken from the live checkout. Code lines include test bodies. Production branch points exclude inline Zig `test` blocks. A branch point is an `if`, non-default switch prong, loop, `catch`, `orelse`, boolean `and` or `or`, or a distinct return inside a branch body. Cyclomatic sum is `1 + branch points` per production function.

| Measure | Baseline |
|---|---:|
| Zig code lines | 224,449 |
| Production branch points | 49,639 |
| Package cyclomatic sum | 56,874 |
| Named Zig test declarations | 3,853 |
| Production `threadlocal` declarations | 10 |
| Allowlisted cross-package internal reaches | 102 |
| Source line or branch coverage | unavailable |

The branch metric is reproducible with `std.zig.Ast`; it should be checked into a small repository tool before it becomes an acceptance gate. The current source tree has no source line or branch coverage integration, and no percentage is inferred from test counts.

### Package shape

| Package | Production functions | Branch points | Cyclomatic sum | Named tests | Production import expressions |
|---|---:|---:|---:|---:|---:|
| `modules` | 198 | 1,613 | 1,811 | 104 | 69 |
| `pi` | 1,065 | 5,935 | 7,000 | 790 | 556 |
| `proof-review` | 81 | 350 | 431 | 29 | 25 |
| `runtime` | 1,694 | 8,614 | 10,308 | 817 | 522 |
| `tools` | 725 | 6,137 | 6,862 | 361 | 168 |
| `zts` | 3,549 | 26,615 | 30,164 | 1,733 | 927 |
| `zttp-sdk` | 152 | 146 | 298 | 12 | 50 |

Import counts are expressions, not unique dependency edges. They are useful for relative shape, not as a package-coupling score.

### Test baseline

| Gate | Result | Wall time |
|---|---|---:|
| `zig build test --summary all` | 4,753 passed, 5 skipped | 11.70 s |
| `zig build test-zts --summary all` | 1,737 passed, 1 skipped | 10.27 s |
| `zig build test-zruntime --summary all` | 388 passed, 1 skipped | 4.34 s |
| `zig build test-expert-app --summary all` | 738 passed, 1 skipped | 3.93 s |
| `zig build test-server --summary all` | 410 passed, 2 skipped | 3.73 s |
| `zig build test-precompile --summary all` | 93 passed | 1.28 s |
| `zig build test-modules --summary all` | 106 passed | 0.25 s |
| `zig build test-proof-review --summary all` | 29 passed | 0.17 s |
| `zig build test-sdk --summary all` | 10 passed | 0.12 s |

The warnings and missing-file messages printed by some suites are expected paths asserted by their tests. All commands exited successfully.

## Findings ranked by leverage

### P0: generic intersection instantiation can drop constraints

Evidence:

- `packages/zts/src/type_env.zig:990` handles `t_intersection` with fixed `[16]TypeIndex` buffers.
- `packages/zts/src/type_env.zig:996` truncates the live member slice with `@min(live.len, 16)`.
- If any copied member changes, `packages/zts/src/type_env.zig:1005` builds a new intersection from only that prefix.
- `packages/zts/src/type_pool.zig:560` explicitly preserves more than 16 distinct intersection members because dropping one can make assignability unsound.

Impact:

A generic intersection with more than 16 members can lose trailing obligations during instantiation. A value that should fail the last constraint can then be accepted.

Required first test:

1. Add a CLI-level fixture that invokes `zts check` on a generic intersection with 17 distinct members.
2. Make the seventeenth member the only failing obligation.
3. Confirm the current checkout incorrectly accepts it.
4. Add a safe contrast in which all 17 members are satisfied.
5. Read the verdict from the command exit status and exact diagnostic, not from absence of a grep match.

Implementation direction:

Use the allocator-backed copy pattern already used by the adjacent union arm at `packages/zts/src/type_env.zig:1007`. Preserve every member, propagate allocation failure through the existing poisoned-pool contract, and rebuild only when a member changed.

Acceptance:

- The rejecting CLI fixture fails before the fix and passes as a regression after it.
- The safe contrast remains accepted.
- Existing type-pool capacity and allocation-failure tests remain green.
- No unrelated parser, checker, or type-pool redesign is included.

This fix changes an externally observable verdict from unsound accept to reject. Implementation requires explicit user approval.

### P0: test evidence must be strengthened before high-risk rederives

#### Graceful shutdown is not exercised by its named test

`packages/runtime/src/server_test.zig:343` is named as a drain test, but it never starts the server, opens a listener, or creates an in-flight request. It calls `shutdown` on an unstarted server and checks only `!srv.running`. The real drain loop is at `packages/runtime/src/server.zig:2486`.

Add a socket-level E2E test that:

1. starts the real server on an ephemeral listener
2. holds one handler execution in flight
3. initiates shutdown through the supported control path
4. proves new connections are no longer accepted
5. proves the in-flight request finishes within the grace period
6. proves pool occupancy returns to zero

Do not refactor server shutdown or the accept loop until this test exists.

#### Expert replay covers only a narrow diagnostic slice

The generated coverage report states that the corpus trips 6 of 72 advertised registry rules. That is 8.3 percent of the registry. It also trips four diagnostics that the registry does not carry, so the policy hash cannot observe changes to those families.

For every compiler diagnostic family touched by a rederive:

- add a recorded real-loop reject case
- add a safe contrast that must remain accepted
- assert the exact rule or diagnostic identity
- regenerate `docs/coverage.md` only with `bash scripts/update-coverage.sh`

Replay is a regression ratchet for its declared fixtures. It is not general source coverage or general model-quality evidence.

#### Source coverage is absent

Before modifying the contract decoder, compile-time evaluator, server lifecycle, or broad verifier code, establish whether the current Zig toolchain can produce stable source line or branch coverage for the relevant test binaries. If it can, add a small checked gate with an input floor. If it cannot, record that limitation and use explicit behavior matrices plus mutation probes for each changed decision family.

No phase may claim coverage preservation from test counts alone.

### P1: active module authorization is hidden in thread-local state

Evidence:

- `packages/zts/src/module_binding/capabilities.zig:53` declares `active_module_context`.
- Native wrappers already receive a `Context` or a `ModuleHandle` convertible to `Context`.
- The current test at `packages/zts/src/module_binding/capabilities.zig:588` covers one invocation, not nested or reentrant invocation.

Rederive the authorization flow so the active module scope is an explicit stack or scoped value owned by `Context`. Capability checks, module identity, and state-slot access should read the same explicit scope.

Prerequisite tests:

- nested native module call with different capabilities
- reentrant call that restores the outer scope
- failure and panic paths that cannot leak the inner scope
- two independent contexts alternating on one thread

Acceptance:

- remove `active_module_context`
- preserve fail-closed authorization
- preserve wrapper ABI unless a separate behavior change is approved
- add no hidden singleton or new allowlist row

### P1: workflow collection and JSON shape caching have the wrong owner

`packages/zts/src/modules/workflow/io.zig:137` stores `parallel_collector` in a thread-local even though the parallel and race operations already carry context. Move a collector stack to `Context` so nested parallel or race operations restore their parent collector explicitly.

Required tests:

- nested parallel inside parallel
- race inside parallel and parallel inside race
- abort and error cleanup
- alternating independent contexts on one worker thread

`packages/zts/src/builtins/json.zig:97` stores hidden-class indexes in a thread-local cache and resets it when a new context is created. Hidden-class indexes belong to a specific pool. Move this cache to `HiddenClassPool` so ownership and lifetime are aligned.

Required tests:

- alternate two contexts with distinct hidden-class pools
- parse identical and different shapes in each context
- destroy one context and continue using the other
- confirm no index from one pool is reused in another

### P1: `current_interpreter` is dead global state

`packages/zts/src/interpreter.zig:37` declares `current_interpreter`, but the live checkout has no non-null write. The remaining sites only save, clear, and restore null around nested dispatch paths.

After adding or confirming nested dispatch and panic-recovery coverage, delete the declaration and its null-preservation ceremony. This is removal, not a replacement channel.

Acceptance:

- no `current_interpreter` references remain
- nested dispatch and panic recovery remain green
- production `threadlocal` count falls by one

### P1: rederive the contract JSON decoder around a typed wire model

Current shape:

- `packages/zts/src/contract_json_parser.zig` has 2,900 code lines and 1,508 production branch points.
- The generic JSON lexer and value parser account for at least 54 core decisions.
- The top-level field dispatch accounts for at least 40 more.
- The remaining projection code contains legacy defaults, ownership transfer, compatibility, and semantic validation that cannot be assumed redundant.

Omit the existing parser when designing the replacement. Derive a `ContractWire` representation from:

- the canonical writer and its golden JSON fixtures
- the public proof receipt and contract documentation
- malformed-input tests
- current unknown-field, optional-field, default, and legacy behavior
- allocation ownership and failure behavior

Parse the wire DTO with `std.json`, then project it through pure functions into owned domain values. Keep boundary validation explicit. Unknown-field handling must remain forward-compatible at the same boundary unless a contract change is approved.

Mechanical floor:

- remove at least 94 core AST decisions
- reduce file branch points from 1,508 to at most 1,414
- preserve byte-identical canonical output for existing golden fixtures

Acceptance matrix:

- every current valid golden contract
- omitted optional fields and every documented default
- unknown fields at every supported nesting level
- malformed tags, numbers, arrays, objects, and truncated input
- legacy and backfill cases
- allocation failure and deinitialization under `std.testing.allocator`
- semantic round trip: write, parse, compare domain value

### P1: rederive `comptime()` on the main parser IR

Current shape:

- `packages/zts/src/comptime.zig` has 1,904 code lines and 926 production branch points.
- Its private scanner and parser account for at least 295 core decisions.
- It duplicates JavaScript lexical and precedence behavior already owned by the main parser.

Omit the private parser when designing the replacement. Use the main parser to produce IR, reject every node outside a small explicit allowlist, and evaluate allowed nodes with an exhaustive tagged-union switch. Keep evaluation pure except for injected environment and hash capabilities.

The public behavior in `docs/typescript.md` is the starting contract, including arithmetic, bitwise, loose and strict equality, comparisons, boolean and nullish operators, ternaries, literals, selected string and array methods, `Math`, `JSON`, `hash`, and injected `Env` values. Any proposal to remove loose equality, narrow accepted syntax, alter coercion, or change emitted literal bytes is an external behavior change and requires approval.

Mechanical floor:

- remove at least 295 private parser and scanner decisions
- reduce file branch points from 926 to at most 631
- reduce the two selected files from 2,434 to at most 2,045 branch points
- reduce the repository from 49,639 to at most 49,250 branch points

Acceptance matrix:

- every documented operator and built-in
- precedence and associativity contrasts
- strict and loose equality coercion cases
- numeric bases, separators, exponent forms, `NaN`, and infinities
- strings, escapes, templates, arrays, objects, and member access
- environment and hash capability injection
- forbidden calls, mutation, loops, declarations, and nondeterministic operations
- malformed and incomplete expressions with stable error class and location
- exact emitted literal bytes for golden cases

Exhaustive IR handling may add branch points. That is acceptable when it replaces implicit fallthrough with type-driven correctness. The mechanical floor applies to removal of the duplicate parser, not to gaming the metric.

### P2: contract the internal boundary by capability, not by file movement

`packages/zts/src/root.zig` exposes a curated surface plus 77 internal modules. `scripts/module-boundary.allow` records 102 internal reaches:

- runtime: 33
- tools: 48
- pi: 19
- proof-review: 2

The gate fails both an unlisted reach and an unused row. Preserve that bidirectional behavior.

Do not split `zts` physically yet. Many internal files use relative imports, and moving them before defining cohesive ports would increase duplicate analysis and wiring. Instead:

1. classify the 102 reaches by capability, such as compile, verify, contract, diagnostics, and runtime execution
2. identify clusters used together by more than one consumer
3. expose the smallest immutable request and response types on the curated surface
4. migrate one consumer cluster at a time
5. delete exactly the allowlist rows made unused by that migration
6. reject any phase that increases the allowlist

The acceptance metric is monotonic: 102 must never increase. Do not set a lower target until the first classification names concrete ports and consumers.

## Documentation corrections

The planning surface has drifted from the live code and history:

- `docs/plans/2026-07-28-001-reset-simplification-plan.md` still says the reset is proposed and unapproved, while `docs/roadmap.md` records most reset waves as executed.
- `docs/plans/2026-08-04-018-zts-advanced-rev4-phase2-plan.md` describes phase work that appears in current history, but the active documents do not conclusively record phase completion.
- D1 and D2 contain ground-truth statements that no longer match the implemented type and effect systems.

Use `docs/roadmap.md` as the single active roadmap authority. Treat dated plan files as decision records with explicit status. In the documentation phase:

1. verify each claimed implementation against the live checkout and tests
2. mark completed or superseded dated plans without rewriting their historical rationale
3. update D1 and D2 statements that describe current behavior
4. update `docs/internals/architecture.md` only after an ownership or boundary change lands
5. update `CONCEPTS.md` only if a newly accepted term has project-specific meaning
6. regenerate `docs/coverage.md` and `docs/convergence.md` only through their scripts
7. never hand-edit module specs or `CHANGELOG.md`

## Phased delivery plan

### Phase 0: make the evidence trustworthy

Deliverables:

- check in the Zig AST metric tool with parser fixtures and a non-empty input floor
- determine source coverage feasibility for the current Zig toolchain
- add the real graceful-shutdown E2E test
- add reject and safe-contrast fixtures for each diagnostic family selected for change
- add contract JSON and `comptime()` behavior matrices before replacement work

Hold point:

Do not begin the high-risk rederives until the relevant black-box matrices fail when their protected behavior is deliberately mutated.

### Phase 1: close the soundness defect and remove dead state

Deliverables:

- reproduce and fix the 17-member generic intersection truncation
- remove `current_interpreter` after nested dispatch and panic coverage proves it unnecessary

Approval:

Ask before implementation because the soundness fix changes an observable verdict.

### Phase 2: make context ownership explicit

Deliverables:

- move active module authorization to `Context`
- move parallel collector scope to `Context`
- move JSON shape caching to `HiddenClassPool`

Acceptance:

- production `threadlocal` declarations fall from 10 to 6
- nested, reentrant, cleanup, and alternating-context tests pass
- allowlisted internal reaches do not increase

### Phase 3: rederive contract decoding

Deliverables:

- typed wire DTO
- `std.json` boundary parse
- pure owned-domain projection
- compatibility, malformed-input, ownership, and round-trip matrix

Acceptance:

- canonical serialized bytes are unchanged
- file branch points are at most 1,414
- all contract gates and full verification pass

### Phase 4: rederive compile-time evaluation

Deliverables:

- main-parser IR input
- explicit allowed-node ADT handling
- pure evaluator with injected capabilities
- complete public behavior and malformed-input matrix

Approval:

Ask before implementation if any currently documented syntax, coercion, diagnostic, or output byte sequence cannot be preserved.

Acceptance:

- duplicate parser and scanner are gone
- file branch points are at most 631, unless an explicitly reviewed exhaustive switch accounts for the difference
- the combined selected slice is at most 2,045 branch points
- full verification passes

### Phase 5: ratchet architecture boundaries

Deliverables:

- classify all 102 allowlisted reaches
- design only the ports justified by repeated consumer capabilities
- migrate one consumer cluster per reviewable change
- delete matching unused allowlist rows

Acceptance:

- allowlist count never increases
- runtime purity remains green
- no physical package split without a separate, evidence-backed decision

### Phase 6: reconcile documentation and remeasure

Deliverables:

- make roadmap and dated-plan statuses unambiguous
- update current-state architecture and type/effect design claims
- regenerate generated measurement pages through their scripts
- rerun AST, tests, coverage if available, and boundary measurements

Final report:

- before and after branch points by changed file and package
- type-driven changes that intentionally increased explicit handling
- source coverage result or documented toolchain limitation
- test and mutation-probe evidence
- thread-local count
- module-boundary allowlist count

## What not to touch

Do not refactor these areas merely because a raw branch metric ranks them highly:

- `interpreter.dispatch`
- `Atom.toPredefinedName`
- `getOpcodeInfo`
- other exhaustive opcode, tag, or predefined-name switches

Their explicit exhaustive handling is type-driven and compiler-checked. A table conversion would mostly hide decisions and weaken maintenance.

Also defer:

- `contract_builder`, flow, boolean, and strict checker rewrites until source coverage or mutation-backed diagnostic matrices exist
- server request-pipeline restructuring until the real shutdown E2E test exists
- garbage collector deletion until the pending measurement in the reset roadmap is resolved
- broad parser, type-checker, and canonicalizer changes while the advanced type-system phases remain active
- extraction of `pi` into a separate repository
- physical `zts` package splitting before cohesive ports are proven
- weakening runtime purity, proof-swallow, docs-drift, or module-boundary floors
- manual edits to generated module specs, generated coverage documents, or changelogs

## Verification commands

Run the narrow gate after every change, then the full repository gate before declaring a phase complete:

```sh
zig fmt --check build.zig packages
zig build test-zts --summary all
zig build test-zruntime --summary all
zig build test-module-boundary
zig build test-proof-swallow
bash scripts/verify.sh
git diff --check
```

For generated measurement documents, use only their owners:

```sh
bash scripts/update-coverage.sh
bash scripts/update-convergence.sh
```

The checked-in AST measurement tool from Phase 0 must print its input count, production branch count, per-package totals, and parse failures. A zero-file or parse-failure run must fail.
