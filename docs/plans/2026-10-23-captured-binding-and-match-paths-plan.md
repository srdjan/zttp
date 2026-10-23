# Captured binding and match path plan: narrowing joins, capture identity, and match arm paths

Status: revised 2026-10-23 after one validation round (Codex astra for facts, Fable for the argument). Decision 13 (the path analysis version) waits for the owner. T1 to T4 do not depend on it.

Authority: on 2026-10-23 the owner answered decisions 10, 11, and 12 of the walker soundness plan with "as recommended". That answer chose 10(a): one type-checker unit for D14 and the missed ZTS620 on a captured boolean. It chose 11(a): a unit that forks one behavior path for each arm of a returned `match`. It chose 12(a): defer the six residual gaps. Research and validation for 10(a) found seven more fail-opens in the same narrowing, capture, and walk code (D16, D18, D20, D21, D22, D23, and the loop and `match` restore paths in D16). This plan includes them, because the fix for 10(a) changes the same mechanism and is not sound without them. The owner sees them in the next report and can remove them.

Evidence: the probes are in `/private/tmp/claude-501/d14/p/`, `/private/tmp/claude-501/d15/p/`, `/private/tmp/claude-501/fable2/`, and `/private/tmp/claude-501/w4/p/o1.ts`. The Codex fact check is in `/private/tmp/claude-501/codex2/facts.md`. Each unit copies its probes into tests.

## Defects

Every probe was run against a build of HEAD (`b583806f`). In the probe outputs, ZTS500 and ZTS606 are proof-profile notes and are ignored.

| ID | What fails | Probe (fails today) | Control (refused today) |
|---|---|---|---|
| D14 | No call kills a narrowing. A closure assigns the narrowed variable through an `upvalue` reference whose key is not the narrowed key. | `o1.ts`: no ZTS203 | a direct `x = undefined` before the read: ZTS203 |
| D16 | `endNarrowScope` restores every journal entry, so a kill inside a branch is undone when the branch closes. A `for...of` body restores a snapshot, and a `match` arm restores the discriminant by hand, with the same effect. | `br_assign.ts`; `p8_loop_call.ts` | `br_ctrl.ts`: ZTS203 |
| D18 | The assignment arm reads the declared type with `binding_types.get(key)`. An `upvalue` target has the closure's capture key, which `binding_types` does not hold, so the check is skipped. | `cap_assign.ts`: no ZTS200 | `cap_assign_ctrl.ts`: ZTS200 |
| D19 | An `upvalue` reference resolves through `active_declared_types`, which is empty after `check`. | W9 `bc_closure_upvalue.ts`: no ZTS620 | `bc_closure_local.ts`: ZTS620 |
| D20 | An `upvalue` reference resolves by name to the innermost stack entry. A `for...of` binding and a `match` pattern binding never enter the stack, so a capture of one resolves to an unrelated outer binding with the same name. | `p1_unsound.ts`, `p2_unsound.ts`: no ZTS203 | `p1_unsound_direct.ts`, `p2_unsound_direct.ts`: ZTS203 |
| D21 | `walkExpr` has no arm for `member_access`, `optional_chain`, `computed_access`, `spread`, or `object_spread`, and its `else` arm does nothing. A call in a member base or a spread operand is never checked. | `p4_objbase_hole.ts`, `p4_spread_hole.ts`: no ZTS203 | `p4_ctrl.ts`: ZTS203 |
| D22 | The same `binding_types.get(key)` guard skips a parameter, whose type is in the parameter map and the environment. | `p16_param_assign.ts`: no ZTS200 | `p16_ctrl.ts`: ZTS200 |
| D23 | `installBranchNarrowing` derives the narrowing for the right operand of `&&` from the syntax of the left operand, after the left operand was walked. A kill inside the left operand is then undone. | `reinstall_and.ts`: `x !== undefined && (x = undefined) === undefined && needS(x) > 0` passes; `p15_and_chain_reinstall.ts` with a call | `reinstall_if.ts`: ZTS203 |
| D15 | A `return` is a leaf, so a returned `match` gives one path with status 200 (`extractExprStatus` does not read a `match`). | `m_a.ts` to `m_b.ts` (an added arm) and `m_a.ts` to `m_c.ts` (405 to 500) are `equivalent` | `m_a.ts` to itself is `equivalent` |

A suspect was probed and rejected. A closure that names a variable declared later in its enclosing function (`fwd.ts`) reads an outer variable with the same name. The parser resolves a name to the binding visible where it parses the name, and code generation uses that binding. `fwd_rt.ts` served "outer". The type checker agrees with the runtime, so it is not a defect.

A finding outside the type checker was made during research. W6 and W8 changed which forks the path generator emits and what fault coverage can prove. The doc comment on `path_analyzer_version` says such a change must raise the version. Neither unit raised it. Decision 13 covers it.

## Design

### Narrowing joins (D16, D23)

A narrowing holds after a branch only if it holds on every path through the branch that reaches the code after it. The journal keeps undoing what a branch installed. What changes is that the kills a branch made are applied again at the join.

- A journal entry records `killed: bool`. `killNarrowing`, `killNarrowingsInScope`, and `killAllNarrowings` write `true`. `putNarrowed` writes `false`.
- `endNarrowScope(mark)` restores every entry as it does today. It also returns the set of keys with a `killed` entry at or after `mark`. The caller applies that set at the join with `killNarrowing`. When an enclosing scope is open, that kill is journaled there in turn, so a kill survives every scope it is nested in.
- `if`: the then set applies only when the then branch can fall through, and the else set only when the else branch can fall through. `branchAlwaysReturns` decides this. The else branch is walked after the then scope is restored, so it does not see the then branch's kills.
- `&&` and `||`: the right operand's set applies after its scope.
- `match` arms: the hand-written save and restore of the discriminant becomes a `beginNarrowScope` and `endNarrowScope` pair, with `putNarrowed`. The union of the arms' sets applies after the `match`.
- `for...of`: the body walk is wrapped in a scope. After the snapshot is restored, the body's set applies.
- A nested function body: `narrowed` is saved at entry and restored at exit, and the body's kills do not apply at the declaration. The body has not run at that point. A call that runs it is handled by D14.
- D23: before `installBranchNarrowing` installs a narrowing derived from a condition, it skips every key that a kill touched while that condition was walked.

The cost is precision. `if (c) { x = "other"; }` after an early-return guard now loses the narrowing of `x`, although `x` is a `string` on both paths (Fable `p6_assign_string_in_branch.ts`). Assignment narrowing would keep it, but it would also turn refusals into passes, and this plan predicts none. That move is accepted. The sweep lists each file where it happens.

### Capture identity (D18, D19, D20, D22)

The parser records, for each function scope and each upvalue slot, the declaring binding (`source_scope_id`, `source_slot`). `flow_interp.zig` already builds a `CaptureTable` from the `ScopeAnalyzer`, and `flow_checker.zig` already receives the `ScopeAnalyzer`. The type checker uses the same record.

- The type checker receives the `ScopeAnalyzer` (or a shared `CaptureTable`) from the same place that the flow checker gets it. An `upvalue` reference resolves to the declaring binding by identity. The name search on `active_declared_types` is no longer used for an `upvalue`.
- `declaredTypeForBinding` for an `upvalue` resolves the declaring binding, then does the same lookups as for a direct read of that binding. It does not read `narrowed`, because a closure can run at any time. This works after `check` too, so the strict checker's ZTS620 query gets a type (D19).
- The assignment arm resolves the declared type of any identifier target through one lookup: `binding_types`, then the parameter type, then `declaredTypeForBinding`, after it maps an `upvalue` to its declaring binding. It reports ZTS200 when the value is not assignable (D18, D22).
- When the record is not available, for example in a caller that builds a `TypeChecker` without a parser, an `upvalue` gets no type. That is the unknown type, which skips checks and grants nothing. It is not the result of a name search.

Typed captures expose refusals inside closures that `check` skipped before. They can also remove a refusal that an unknown type caused. Each such move is listed and read.

### A call can run a closure that assigns an outer binding (D14)

The analyzer cannot tell which closure a call reaches. `route_resolution.zig` resolves some immutable identifiers to their function, but not a function value in general. The rule is therefore program-wide.

- Before the walk, `check` scans the program once through `IrView.expressionChildren`. It sets `closure_writes_outer` when any function body, at any depth, assigns an identifier whose binding kind is `upvalue` or `global`. A module-level binding is `global`, and its declaration and every reference share one key.
- When the flag is set, the `call` and `method_call` arms kill every narrowing after the callee and all arguments are walked, and they walk the arguments before `checkCallArgs`. So `f(clear(), x)` reads `x` after the kill.
- Kills inside a loop body, a `match` arm, an `&&` operand, or a condition go through the joins above. The D21 arms make every call position reachable.
- When the flag is clear, no call kills anything, and the argument order does not change.

### A returned match forks one path for each arm (D15)

- `walkPaths` `.return_stmt` calls a new helper on the returned value. For a `match_expr`, the helper records the module calls of the discriminant once, before the fork. For each arm, it saves the constraints and the I/O sequence, calls itself on the arm body, and restores them. Any other value keeps today's behavior. A nested returned `match` forks again. The helper respects `MAX_PATHS` the same way as `walkAssertFailure`.
- An arm adds no constraint, so contract bytes change only by the added paths.
- The verdicts: an added arm is `breaking`, not `additive`. `tryCanonicalEquivalence` reports "behavior path count differs" when the path counts differ, and `classify` then returns `breaking`. A changed arm status is `response_changed`, also `breaking`. T4 pins both.
- This unit changes which forks the generator emits, so `path_analyzer_version` must rise (decision 13).

Two arm edits stay invisible, because an arm adds no constraint (Fable `m_d.ts`, `m_e.ts`, `m_f.ts`): a changed arm pattern with the same status, and a body swap between two arms with the same status. A returned ternary and a `match` reached through a `const` also still give one path. T4 records all four as residual gaps.

## Decision 13: the path analysis version

W6, W8, and T4 each change which forks the path generator emits or what fault coverage can prove. The rule on `path_analyzer_version` requires a rise for each. A rise moves `policy_hash`, so contracts stamped by the older analysis are rebuilt and not trusted. The pins move too: `policy-hash.txt`, `scripts/check-meta-drift.sh`, `docs/consumer-contract-envelope.json`, and the expert goldens. When the version last rose (R4), offline replay failed until the corpus was recorded again through DeepSeek. Measured on 2026-10-23 at `b583806f` with the version set to 4 and then reverted: `test-meta-drift` and `test-expert-golden` fail on the hash pins, and `test-expert-app` fails 2 of 904 tests. One is a frozen-response test that pins the hash. The other is the codegen baseline replay, which then tries a live DeepSeek request. So a rise needs a DeepSeek re-record, which sends handler source to DeepSeek.

- (a) Raise the version to 4 once, in T4, for W6, W8, and T4 together. Move the pins in the same commit. Run the corpus re-record as a separate step that the owner approves. Recommended: one hash move and one re-record cover all three changes.
- (b) Raise it now for W6 and W8, and again in T4. Two hash moves, and two re-records if replay fails.
- (c) Raise it in T4 and do not re-record. Replay stays red until a later re-record.

## Units

Each unit is one commit. Each unit adds its probes as tests through the public entry point that the pass's tests use. Each test asserts the expected value, and the probe and its control give different verdicts.

- **T1 (D21):** the type checker's `walkExpr` reads member bases and computed keys, reads spread operands with `getOptValue`, and sends any other tag through `IrView.expressionChildren`. Tests: `p4_objbase_hole.ts` and `p4_spread_hole.ts` give ZTS203.
- **T2 (D16, D23):** the `killed` journal flag, the join rules, the `match` and `for...of` conversions, the nested function snapshot, and the condition rule. Tests: `br_assign.ts`, `reinstall_and.ts`, and a kill in a nested branch give ZTS203. `p5_else_leak.ts` and `p11_then_return_kill.ts` still pass. A narrowing installed inside a branch is still undone when the branch closes.
- **T3 (D18, D19, D20, D22):** capture identity and the assignment lookup. Tests: `cap_assign.ts` and `p16_param_assign.ts` give ZTS200. `p1_unsound.ts` and `p2_unsound.ts` give ZTS203. `p1_forof_shadow.ts` and `p2_match_binding.ts` (false refusals today) pass. A captured boolean gives ZTS620 through the strict checker.
- **T4 (D14):** `closure_writes_outer` and the call-arm kill. Tests: `o1.ts`, `f(clear(), x)`, `p8_loop_call.ts`, and `p15_and_chain_reinstall.ts` give ZTS203. A program with no outer-writing closure keeps its narrowing across a call. `p12_closure_decl_call.ts` (a call inside a closure body that is declared but not called) still passes. A module-level `let` assigned by a function gives ZTS203 after a call to that function.
- **T5 (D15, decision 13):** the returned-`match` fork, the version rise, and the pins. Tests: `m_a.ts` to `m_b.ts` is `breaking` with the path-count counterexample. `m_a.ts` to `m_c.ts` is `breaking` with `response_changed=1`. `m_a.ts` to itself is `equivalent`. Record the path count for `examples/routing/match-handler.ts` before and after.
- **T6 (records):** a worklog section with the commits, the probe results, the moved verdicts, and the gate exit codes; the progress table below; the index row in `docs/plans/README.md`; and the solution note for the walk class, updated or new.

## Order

T1, T2, T3, T4, T5, T6. T1 comes first because it makes every call position reachable for T4. T2 comes before T4 because T4's kills need the joins.

## Predicted moves

- T1 to T4 add refusals: ZTS200, ZTS203, ZTS620, and any other type error that a walked or typed position exposes.
- T2 can refuse a correct program that assigns a narrowed variable inside a branch (the `p6` shape). T4 can refuse a correct program in which a call follows a narrowing, when any closure in the program writes an outer binding.
- T3 can remove a refusal that an unknown captured type caused, and it removes the two false refusals `p1_forof_shadow.ts` and `p2_match_binding.ts`.
- T5 adds paths for every handler that returns a `match`. Contract goldens and cost envelopes can move for those handlers, and the policy pins move.

## Stop conditions

The implementer stops and reports to the lead in each of these cases. The lead brings the case to the owner.

- `test-expert-app` replay fails, or `test-meta-drift` moves, in T1 to T4. In T5 both are expected under decision 13, and the lead confirms that each moved pin is the version rise and nothing else.
- A verdict moves from refused to proven, other than the moves predicted for T3.
- A tracked example or fixture gains a refusal. The lead reads it before the commit. A real type error is fixed in the source or accepted. A refusal of the predicted `p6` or T4 shapes is accepted and listed. Any other refusal stops the unit.
- `test-proof-swallow` refuses an arm, and the fix needs an allowlist row whose mechanism is not already in the allowlist.
- A unit would change `proof_ir.zig` lowering or certificate bytes.

## Gates

Each unit runs these steps unfiltered and reads each exit status directly: `zig fmt --check packages`, `zig build install`, `test-zts`, `test-precompile`, `test-contract-golden`, `test-diagnostic-corpus`, `test-flow-census`, `test-proof-swallow`, `test-standin`, `test-expert-app`, `test-meta-drift`, `test-cli`, `test-examples`, `test-server`, `test-zruntime`, `test-zts-cli`, `test-module-boundary`, `test-docs-drift`, `test-doc-links`, `check-spine` (after `git add`), and `zig build test --summary all`. Each unit also runs `zts check --json` over every tracked `*.ts` file and compares the output with the commit before it. After the last code unit, the lead runs `bash scripts/verify.sh`.

## Out of scope

- The six residual gaps of the walker soundness plan (decision 12(a)).
- Assignment narrowing.
- A per-binding kill rule for D14.
- The boolean checker's own narrowing restore. It has the same save and restore shape and was not probed.

## Progress

| Unit | State |
|---|---|
| T1 | done: `walkExpr` reads member bases, computed keys, spread operands, and object spread members, and sends any other tag through `expressionChildren`; `p4_objbase_hole.ts` and `p4_spread_hole.ts` give ZTS203; the 296-file sweep is byte-identical; `zig build test` 200/200 steps, 9483/9489 tests |
| T2 | done: journal entries record kills, `endNarrowScope` returns them, and each join applies the kills of the branches that fall through; `match` arms and loop bodies use journaled scopes; a nested function body discards its kills; a kill in a condition voids its guard; `br_assign.ts` and `reinstall_and.ts` give ZTS203, `p5` and `p11` still pass, `p6` is refused (accepted cost); three stale swallow rows deleted under decision 14(a); the 296-file sweep is byte-identical; `zig build test` 200/200 steps, 9497/9503 tests |
| T3 | not started |
| T4 | not started |
| T5 | waits for decision 13 |
| T6 | not started |
