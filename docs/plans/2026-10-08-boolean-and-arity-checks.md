# Plan: boolean checks in function bodies and call arity

Status: draft for owner approval, 2026-10-08, revision 2. Source: findings 2 and 10 of the
[Tier 1 plan](2026-10-07-tier1-test-and-diagnostic-discipline.md), section 8.
Code references are to local `main` at `f4553b0a`. This plan does not
authorize implementation.

## 1. Summary

Two research agents measured both gaps with throwaway prototypes. Neither
prototype is committed. Their diffs and logs are in the session scratchpad
(`plan-bool/`, `plan-arity/`).

**Boolean checks.** Finding 10 was described as "the boolean checker skips
function bodies". The cause is narrower and worse: the checker misreads the IR
of a `function` declaration, so it never walks the body of `handler` or of any
named helper. Arrow bodies are walked only at module scope, because the walk
never enters `handler`. An `export function` is not walked at all. The same
misread exists at two more sites. Fixing the walk alone causes false
positives, because the checker reads types after the type checker has closed
its narrowing scopes, and the type checker installs no narrowing for `&&` or
`||` guards.

**Arity.** The type checker reports too few arguments (ZTS202) for a call by
name, but it never checks for too many. The upper bound was never written for
that path. The member-call path already checks both bounds.

**Found during research, outside this plan's scope.** The flow checker
proves `no_secret_leakage` for a handler that sends a secret to a log or to an
outbound request body from inside a called function. Section 7 describes it.
Decision P1 asks whether it is planned first.

## 2. Observed facts

### 2.1 Boolean checker

- The parser stores a `function_decl` as `var_decl` data
  `{binding, init = function node, kind}` (`packages/zts/src/parser/parse.zig:579-587`).
- `bool_checker.zig:368` reads that node with `ir_view.getFunction(node)`,
  which reads six extra-data slots the declaration does not own
  (`parser/ir.zig:1923-1940`). `func.body` is then unrelated data, or the read
  returns null. `getBinding(node)` at `bool_checker.zig:375` is also wrong.
  The same misread is at `bool_checker.zig:754` (`inferFunctionReturnType`).
- `walkStmt` has no `.export_decl` arm and falls to `else => {}`.
- History: the misread arrived with the checker, `3cf1d634` (2026-03-16). No
  test uses a `function name() {}` declaration; all use arrows.
- The same `getFunction` misread is at `contract_builder.zig:3173`
  (`subtreeContains`) and `flow_checker.zig:1930` (`walkStmt`, nested
  function declarations).
- Probes: `if (5)` inside `function f` or `function handler` passes `zts
  check`; inside an arrow it reports ZTS100.
- Rule coverage today:

| Rule | Module scope | Arrow body | `function` declaration body |
|---|---|---|---|
| ZTS100, 101, 102 (condition, `&&`/`\|\|`, `!`) | boolean checker | boolean checker | none |
| ZTS103 `??` on a non-nullable (warning) | boolean, locals only | boolean, locals only | none |
| ZTS104 arithmetic, ZTS106 `+` operand | boolean, local lattice | locals only; `s - 1` with `s: string` passes | none |
| ZTS105 string `+` | type checker | type checker | type checker |
| ZTS107 tautology | boolean, local lattice | locals only | none |

  ZTS103, 104, 106, and 107 see a typed parameter only through branch
  narrowing: `inferType` accepts a narrowed type first, and otherwise answers
  `.unknown` for `.argument` bindings (`bool_checker.zig:640-649`).
- **Narrowing.** `requireBoolean` (`bool_checker.zig:893-898`) calls
  `inferTypeWithoutDiagnostics` (`type_checker.zig:281`) after the type
  checker's walk, when its narrowing overlay is closed. A prototype that records
  each boolean-context operand's type during the type checker's walk removes
  the `!== undefined` and discriminant false positives.
- **Proofs.** No proven property reads boolean diagnostics. Boolean errors
  stop `check` before the verifier and flow stages (`precompile.zig:1687`),
  abort the build (`:2286`), and make the runtime refuse the handler
  (`runtime/src/handler_instance.zig:1194`). A wider walk is not monotone: it
  also teaches the checker more function return types
  (`bool_checker.zig:373`, `:837`), which can remove existing refusals. B3
  measures changes in both directions.
- **Bytecode.** The boolean checker's `node_types` drive opcode
  specialization (`codegen.zig:845-862`). Walking declaration bodies adds
  specializations, so precompiled bytecode and artifact hashes move.
- **Finding 15 was described backwards.** `check` reports the boolean stage
  first, then types, then strict, each with an early return on errors only
  (`precompile.zig:1687`, `:1713`, `:1754`); warnings and advisories are
  still shown. All three checkers have already run inside
  `pipeline.resolve` (`pipeline.zig:197-257`). Only the reporting stops early.

### 2.2 Measured blast radius of the walk fix

With the walk fix and walk-time context types (prototype P2):

- **Examples newly refused:** `parallel/parallel-simple.ts`,
  `parallel/parallel.ts` (ZTS100 on `.ok` of an `unknown` result: true
  positives by the sound-mode rule), `patterns/json-and-dict.ts` (ZTS102 on
  `!isDict(document)`: a false positive), and `system/gateway-static.ts`
  (ZTS102 on `!health.ok` without `--system`; probable cause: an unknown type
  without the system file).
- **Examples with a new warning:** `patterns/nominal-brand.ts:67` (ZTS107, a
  tautology the example writes on purpose).
- **Examples that already failed, with changed diagnostics:**
  `handler/handler-full.tsx` (true positive), `jsx/jsx-ssr.tsx` (false
  positive: a nested member read through an inline record parameter type), and
  `workflow/timeout-orchestrator.ts` (false positive: the local lattice types
  `Result.error` as a non-optional string).
- **Corpus:** two goldens change (`dict_entries_reduce`,
  `dict_entry_round_trip`), both from the `isDict` false positive, which also
  uncovers ZTS627 and ZTS628.
- **Stand-in:** two of 56 fail (one probably from `isDict`; one not
  investigated).
- **Replay:** 18 of 19. `parallel-secret` gains a ZTS102 at line 13 (`if
  (!ok)` on an `unknown` value): a true positive that needs a re-record.
- **Test fixtures:** two need rewriting (`test_runner` "actor queue flag",
  `verify_paths_core` "surfaces ZTS400").

### 2.3 Arity

- `checkCallArgs` (`type_checker.zig:3886`). The member path checks both
  bounds (`:3900-3906`). The identifier path checks only the lower bound
  (`:3992-3997`). The argument-type loop stops at the shorter count (`:4020`),
  so surplus arguments are walked as expressions (`:861`) but never compared
  with a parameter.
- History: lower bound only since `630397e5` (2026-03-18, "For now, treat all
  params as required"). `7149c52c` (2026-08-15) removed default parameters but
  added no upper bound.
- Arity sources: `FunctionSig.param_count` for declarations and `const` arrows;
  `info.params.len` for function-typed parameters; `arg_count` and
  `required_arg_count` for `zttp:*` exports; the ABI table for `requestBody`
  and siblings. Ambient globals (`String`, `Number`, `range`) have no
  signature and stay unchecked; builtin methods are unchecked except seven
  array methods with modeled signatures (`type_checker.zig:2715`).
- The spec requires fixed arity: "Every call supplies every declared argument"
  (`docs/zts-formal-spec-northstar-advanced.md:781-782`). Lines 1139-1141 still
  say "except for trailing defaults", which `7149c52c` made stale.
  `docs/typescript.md:214` claims an argument-count check for virtual modules.
- **Existing false positives.** Signatures are keyed by the line of the
  parameter list and by name. A function and an inline arrow on one line merge
  into one signature, and two nested functions with one name collide. Both
  already give a false ZTS202 for a correct call today.
- **Binding defect.** `durable.signalAt` declares `arg_count = 3`
  (`modules/workflow/durable.zig:69`), but `signalAtNative` reads `args[3]` as
  a payload (`:251`). The flow checker probably never sees that payload. A
  probe (a secret as the fourth argument) can confirm it.
- **Measured** (prototype v2: upper bound on the identifier path, reusing
  ZTS202, skipped when the annotation count differs from the declared count):
  catalog and policy hashes unchanged; replay 19 of 19; corpus 165 of 165; no
  seed changes; no passing example newly refused. `test-examples` fails for
  `examples/workflow/wait-signal-orchestrator.ts`, which calls `signalAt` with
  four arguments. With the binding also fixed, 16 of 19 cassettes fail replay,
  because the model sees the binding catalog.

## 3. Constraints

- **C1 (replay).** Replay compares what the model sees: the `meta` output
  (`policy_hash`, `grammarHash()`), the binding catalog, and the code,
  message, position, suggestion, and count of each diagnostic in a recorded
  turn. A unit that changes any of these runs `zig build test-expert-app -j1`.
  A stale cassette is recorded in the unit's report, not repaired. All
  re-records are batched under decision P2.
- **C2.** Every refusal added by this plan is proved by a corpus case and a
  unit test written first and seen failing.
- **C3 (no false positives at landing).** A walk or bound that newly refuses a
  program may land only after each false-positive source measured in 2.2 or
  2.3 is fixed or explicitly accepted by the owner.
- **C4 (fail-open discipline).** `type_checker.zig` and `flow_checker.zig` are
  in the proof-swallow gate. No new discarded error without an allowlist row.
- **C5 (evidence).** Unfiltered named steps, exit statuses read directly, a
  probe that must compile, never a `-Dtest-filter` result.

## 4. Units: boolean checks

**B0: one `function_decl` accessor, behavior-neutral.** Make the IR read of a
function declaration impossible to get wrong: a `getFunctionOfDecl` helper
reads the `init` of a `function_decl`, and `getFunction` on a `function_decl`
fails in both IR implementations (`Node.Data` is a bare union, so on the
`.node_list` implementation that type-checker unit tests use the misread is a
Debug panic today). Fix the sites:
- `bool_checker.zig:368` and `:754`: read through the helper for the return
  type only, and keep returning before the body walk, so B0 changes no
  boolean diagnostic. B3 removes that return after B1 and B2 land.
- `contract_builder.zig:3173` (`subtreeContains`, reached from about `:1093`):
  read through the helper. This widens the expert-loop scope summary for a
  hole, which moves prompts, not contracts; `test-expert-app` measures it.
- `flow_checker.zig:1930`: return for a nested `function_decl`, exactly as the
  summary path does today. Walking its body eagerly would report sinks with
  unlabelled parameters for a nested declaration but not for a nested arrow,
  and would pre-empt the walk policy that the section 7 plan owns.
The other readers of `function_decl` already use `getVarDecl` (Fable review,
2026-10-08: `type_checker.zig:760`, `strict_checker.zig:378`,
`proof_ir.zig:216`, `effect_inference.zig:335`, `path_generator.zig:946`,
`ir_identity.zig`, the transpiler). Probe set, run before and after:
`if (5)` inside a `function`, an `export function`, a nested function, and an
arrow inside `handler`; a nested declaration that sends an env secret to a
log, a `fetch` body, and the response, with `no_secret_leakage` asserted
unchanged; one scope-summary golden.

**B1: walk-time context types with operator guards.** Record the type of each
boolean-context operand during the type checker's walk, while narrowing is
live, and make `requireBoolean` prefer it. The type checker installs no
narrowing for `&&` or `||` today (`type_checker.zig:1913` is the only `and_op`
handling), so B1 must also narrow the right operand under the left operand's
guard (negated for `||`), including in ternary conditions. Measured on the
research prototype without this: `v !== undefined && v`,
`e.kind === "a" && e.flag`, `v !== undefined && v ? 1 : 0`, and
`v === undefined || !v` were all refused. Add one corpus case per form. Key
records by node index: each node is walked once (if branches, `for ... of`, and
`match` arms each run in their own narrowing scope), and the
`inferTypeWithoutDiagnostics` fallback covers nodes the type checker skips.

**B2: false-positive sources.** Fix, each with a corpus case and a test:
- `isDict(x)` in a boolean context (ZTS102 at module scope today);
- a nested member read through an inline record parameter type
  (`props.todo.done`);
- `Result.error ?? ...` typed as non-optional in the local lattice (ZTS103);
- `typeof` narrowing over `unknown`;
- the element variable of `for (const x of xs)` over `boolean[]`.

True positives that B3 will expose and that need a written idiom, not a
checker change: `.ok` read on an `unknown` result (`parallel` declares
`returns = .object`, `io.zig:54`, and the examples type results `unknown`),
and `o?.flag` with `flag?: boolean`. B3 rewrites each mover to an explicit
form; decision P5 picks between a narrowing idiom and a typed `parallel`.

**B3: walk `function` and `export function` bodies.** Uses B0. Lands only
after B1 and B2 (C3). Arrows inside `handler` are reached for the first time
here too, because today the walk never enters `handler`. Movers: the example
sources and test fixtures in 2.2, each rewritten to the sound-mode form, and
the `parallel-secret` cassette (P2). `nominal-brand.ts` follows decision P4.

**B4: report every computed stage, one message per node.** `check` emits the
boolean, type, and strict diagnostic sets that `pipeline.resolve` already
computed, then stops. Today an error in an earlier stage hides the later
stages (finding 15); warnings are not hidden. Removing that gate alone would undo U4.4: `if (n + "y")` would
print ZTS105 and ZTS100, and `(n + "y").trim()` would add ZTS600 from the
strict checker. So B4 suppresses a boolean or strict diagnostic whose node
lies under a node that already has a type diagnostic. Add the finding 15
probes as corpus cases with their expected counts. Measure with
`test-expert-app`.

**B5: typed parameters for ZTS103, 104, 106, 107.** Use the type checker's
types for parameters instead of `.unknown`, so `s - 1` with `s: string` is
refused. Depends on B1's operator guards. Measure the blast radius first, like
2.2. Scope per decision P3.

## 5. Units: arity

**A0: signature identity.** Signatures are created in the stripper before a
parser binding exists (`stripper.zig:2704-2708` sets `context_line` and
`context_col`), and `type_env.zig:587-690` indexes them by line. Key them by
(signature line, column), match that key to the function node's location, and
bind it through the existing `bindCallableMetadata`. Fix the same line keying
in `hasCompleteFunctionAnnotation` (`strict_checker.zig:1559`), or the
same-line case still trips ZTS601. Check: the two collision probes from the
research (a function and an arrow on one line; two nested functions with one
name) become passing corpus cases.

**A1: upper bound for source callees, no skip.** On the identifier path,
refuse surplus arguments with ZTS202 for declarations, `const` arrows, nested
and generic functions, and function-typed parameters. For a source function,
take the count from the IR `params_count` of the bound function. For a
function-typed parameter, which has no body node, take `info.params.len` from
its type (`type_checker.zig:2994`). Do not skip when the annotated count
differs: the research prototype's skip is a fail-open, because ZTS601 fires
only for a function with a name (`strict_checker.zig:1547-1548`), and its
completeness test accepts `sig.param_count >= params_count`
(`strict_checker.zig:168`, `:1557`). Observed
today: `const f = (a: number, b): number => a; f(1, 2, 3)` passes with no
diagnostic. So A1 also makes ZTS601 refuse a partly annotated anonymous
arrow. Message: "expected N" or "expected N to M". Add
`tests/corpus/check/bad/call_with_too_many_arguments.ts`, a partial-arrow
case, and a unit test per callee kind. Measure replay: the ZTS601 extension
may touch recorded drafts.

**A2: upper bound for module exports and the `signalAt` binding.** Declare the
payload parameter of `signalAt` (`arg_count = 4`, `required_arg_count = 3`),
because the runtime reads `args[3]` and the shipped example passes four
arguments; refusing at the native would break that example. Enforce the
export upper bound. The research called the payload "unseen by the flow
checker"; Fable measured that it is seen (returning it gives ZTS400). The real
gap is that the flow checker has no durable or queue sink at all (`SinkKind`,
`flow_checker.zig:3388`): `signal("k", "n", token)` with its declared payload
passes too. That gap moves to the section 7 plan. This unit breaks replay of
16 cassettes, so it waits for decision P2.

**A3: documents.** Fix the spec text at lines 1139-1141 and
`docs/typescript.md:214`.

## 6. Order and verification

Order: B0, B1, B2, A0, A1, A3, B3, B4, B5, A2. B3, B4, and A2 move replay;
they run last so that one re-record (P2) covers them.

Each unit: a test seen failing first, then the fix; unfiltered
`zig build test-zts`, `test-diagnostic-corpus`, `test-standin`,
`test-expert-app -j1`; the four hashes before and after. Final: `bash
scripts/verify.sh`. Precompiled artifact hashes move with B3 (bytecode
specialization); release provenance is an offline republish.

## 7. Found during research: a flow-checker fail-open

Observed 2026-10-08 with `zig-out/bin/zts` built from `main`. Each handler
below passes `zts check` with exit 0, and `no_secret_leakage` holds:

- a top-level helper that calls `logInfo(token, ...)` with
  `token = env("API_TOKEN") ?? ""`, called from the handler;
- the same inside a nested `function` declaration, or a nested arrow;
- a nested arrow that receives the token as a parameter and logs it;
- a top-level helper that sends the token as a `fetch` body.

The same flows written directly in the handler are refused (ZTS402, ZTS406).
A secret returned from a helper into the response is refused (ZTS400), so
return-value summaries work.

Cause, confirmed in source: `checkExprSinks` returns at once while
`summary_returns` is set (`flow_checker.zig:3240-3243`, "diagnostics belong to
the handler walk"), and every non-root body is walked only under a summary
(`functionCallLabels`, `closureResultLabels`, `exportedReturnLabels`, route
dispatch). `check` walks only the handler and the `routerMatch` roots. So no
walk ever evaluates a sink inside a callee.

A second gap belongs to the same plan: the flow checker has no durable or
queue sink (`SinkKind`, `flow_checker.zig:3388`), so a secret passed as a
`durable.signal` or `signalAt` payload passes too (Fable probes, 2026-10-08).

This is the fail-open class in AGENTS.md: `no_secret_leakage` is PROVEN for a
handler that leaks. It needs its own plan, with a probe census over every sink
kind (log, egress URL, egress body, egress headers, opaque egress options,
response, and the missing durable store and queue sinks, which need new sink
kinds, not only summary-mode reporting) times every callee kind (top-level helper, nested declaration, nested arrow, closure
parameter, routed function, exported function). A likely fix shape: evaluate
sinks during summary walks with a per-sink-node deduplication, so a callee
summarized at several call sites reports once.

## 8. Decisions for the owner

Answered 2026-10-08: P1 (a), P2 (a), P3 (a), P4 (a), P5 (a). The owner
approved this plan. Per P1, the flow-checker plan for section 7 is written and
fixed first; this plan follows. The DeepSeek re-record runs longer than two
minutes and is paid, so the main session confirms with the owner before it
starts.

**P1 (the flow-checker fail-open in section 7).**
Options: (a) plan and fix it first, then this plan; (b) this plan first;
(c) one combined plan.
Recommendation: (a). It makes a proven property false, which is worse than a
missing lint, and it may move recorded turns too, so it belongs in the same
re-record batch.

**P2 (one batched DeepSeek re-record).** B3 (`parallel-secret`), A2 (16
cassettes), possibly A1 (the ZTS601 extension), and probably the section 7
fix move replay.
Options: (a) one re-record after the last replay-moving unit of both plans;
(b) defer B3 and A2 and land only the units that keep replay.
Recommendation: (a), and only after B1, B2, and B4 land, so the re-record
bakes no false positive into the cassettes.

**P3 (typed parameters, B5).**
Options: (a) include B5 in this plan, gated on its own measurement; (b) defer
it.
Recommendation: (a). Without it, `s - 1` with `s: string` stays accepted
everywhere a parameter is involved.

**P4 (`nominal-brand.ts:67`, an intentional tautology).**
Options: (a) rewrite the example so it does not trip ZTS107; (b) accept the
warning.
Recommendation: (a). Examples teach the model.

**P5 (the `.ok` read on an `unknown` result from `zttp:io` `parallel`).** B3
refuses it in two examples and in the `parallel-secret` cassette. The refusal
is right by the sound-mode rule, but the root is that `parallel` returns an
untyped `object` (`io.zig:54`).
Options: (a) rewrite the movers with an explicit narrowing idiom now; (b) give
`parallel` a typed result first, which moves the binding catalog (replay).
Recommendation: (a), with (b) recorded as a later item.

## 9. Review record

Fable reviewed revision 1 on 2026-10-08. Applied: B1 operator guards
(blocker), A1 without the skip plus ZTS601 for anonymous arrows, A0 keyed by
line and column, B0 behavior-neutral at the flow site, B4 deduplication per
node, the corrected A2 framing, and the confirmed cause in section 7. Codex
astra fact-checked the citations; its corrections are listed below.

Codex astra corrections, applied in revision 2: argument bindings reach the
boolean lattice through branch narrowing; a wider walk is not monotone;
`check` stops early only on errors; surplus arguments are walked but not
compared; seven array methods have modeled signatures; B0 keeps the boolean
body walk off until B3; A1 takes a function-typed parameter's count from its
type; ZTS601's completeness test accepts a longer signature. Recorded
omissions: the egress-URL and opaque-egress sinks belong in the section 7
census; declaring `signalAt`'s fourth parameter does not make its payload a
flow sink, and the runtime serializes that payload
(`runtime/src/durable_executor.zig:468`) with no encodability check in the
binding, which A2 adds as a `param_types` entry if the binding vocabulary
supports it.
