# Walker soundness plan: close the confirmed walk fail-opens

Status: revised 2026-10-22 after one validation round (Codex astra for facts, Fable for the argument). The owner chose decision 9(a) with "a" on 2026-10-22.

Authority: the owner chose decision 8(a) with "a". That answer also accepted decision 5(a): plan, validate, and implement a fix for the confirmed fail-opens. It accepted decision 6(a): probe the five suspects first. It accepted decision 7(a): defer the contract diff gaps and the six properties that never reach the ledger.

Evidence: `docs/plans/2026-10-22-coupling-census-worklog.md`, sections "U5 lead probes", "Decision 6 probes", "Plan research probes", and "Validation round". The probe sources are in `/private/tmp/claude-501/probes/`, `/private/tmp/claude-501/probes/s/`, and `/private/tmp/claude-501/fable/`. Those directories are scratch, so each unit copies its probe sources into tests.

## Problem

Each analysis pass in zts has its own hand-written recursive walk over the IR. Each walk names the node tags that it knows, and it ends with `else => {}`. When a walk misses a tag that has children, the pass never sees those children, and it reports a verdict for code it did not read. Some walks also keep checked state that is set on sight and never scoped, so a check in one branch clears the obligation in another.

### Confirmed defects

| ID | Pass | What fails | Condition | Effect | Probe |
|---|---|---|---|---|---|
| D1 | effect walks: `walkBaseExpr`, `includeReachableNodeEffects` | No `assert` descent. | A capability call is inside `assert`. | `retry_safe` and `idempotent` are proven for a handler that writes the cache. CHECK exits 0 with a capsule. | `in_assert.ts`, `cap_in_assert.ts` |
| D2 | effect walks, `isSafeDataShape` | `.spread` reads word `b` (`getUnary`). The operand is in word `a` (`getOptValue`). `object_spread` is read as a property. | A capability call is inside a spread operand. | The same false proof as D1. | `in_spread.ts`, `in_objspread.ts` |
| D3 | `handler_verifier.zig` descent | No `assert`, no nested `function_decl`, no closure body. | An unchecked `result.value` read is inside one of them. | No ZTS303, and a false ZTS305 for `assert`. | `res2_assert.ts`, `res2_closure.ts` |
| D4 | `handler_verifier.zig` checked state | `ok_checked` and `narrowed` are set on sight and are not scoped to a block. A reassignment does not clear `ok_checked`. | `if (flag) { if (!result.ok) { return ...; } }`, then `result.value`. Or a `let` Result that is checked, reassigned, and read. | No ZTS303 or ZTS309. | `res_nested.ts`, `res_let_reassign.ts`, `opt_renarrow.ts` (Fable) |
| D5 | `type_checker.zig` `killNarrowingsAssignedIn` | No descent into an initializer, a call, a ternary, a `match`, an `assert`, a closure, or an assignment target. | `const y = (x = undefined);` in a `for...of` body. | A narrowing survives, and `needS(x)` is accepted with `x` undefined. | `n2_init.ts` |
| D6 | `type_checker.zig` `bodyReturnType`, the `assert` arm | No `for...of` descent and no `assert` error expression in the return join. ZTS204 does not compare an `assert` error expression with the declared return type. | A callback returns inside a loop or through `assert`. | The return type is too narrow. No end-to-end pass was found, because ZTS204 refuses the generic shape. | `r3_forof.ts` |
| D7 | `route_resolution.zig` mutation and escape scans | `assignmentRootBinding` gives null for a non-identifier root, and `bindingIsMutated` skips it. `bindingEscapesStableResolutionDepth` does not scan `for...of` iterables, `match` discriminants, or `expr_stmt` values. | `[routes][0]["GET /"] = bad;`, or `for (const t of [routes]) { t["GET /"] = bad; }`. | The table is treated as stable. The unchecked read in `bad` is not reported, and totality is not re-checked. | `rt2_arrayroot.ts`, `rt_forof.ts` (Fable) |
| D8 | `path_generator.zig` `trackModuleCallUnder` | A module call is recorded only when it is the whole `const` initializer, the whole `expr_stmt` value, or the left of `??`. | A write is nested in an expression, for example `return Response.text(String(cacheSet(...)))`. | `prove-behavior` reports an edit that removes the write as `equivalent`. | `diff_ret2_a.ts` to `diff_ret2_b.ts`, `diff_ret3` (Fable) |
| D9 | `contract_diff.zig` `canonicalPathsEqual` | Every non-literal argument gives the token `?`, and `?` equals `?`. | An edit changes `cacheSet("items", a, ...)` to `cacheSet("items", b, ...)`. | `equivalent`, `"safe": true`. | `diff_one_dyn.ts` to `diff_one_dyn_b.ts` |
| D10 | `behavior_canonical.zig` `signaturesEqual` | The same `?` equality, and a string literal with `\|` makes the encoding ambiguous. | An edit drops the second of two dynamic-key writes. | `equivalent_modulo_laws`, `"safe": true`. | `diff_two_dyn.ts` to `diff_one_dyn.ts` |
| D11 | `path_generator.zig` `walkPaths` | `assert` is treated as a statement with no branch. A failed `assert` returns its error expression, or halts with status 500 when it has none (`emitAssert` in `parser/codegen.zig`, and the runtime in `handler_instance.zig`). | An edit changes an `assert` error response from status 200 to 500. | `equivalent`. The same edit in an `if` branch is `breaking`. | `as_a.ts` to `as_b.ts` |
| D12 | `strict_checker.zig` | Six `.spread` arms read word `b`. `collectCallCounts` reads `object_spread` as a property. The walks do not enter closures. | A spread operand or a closure holds the refused form. | ZTS612, ZTS622, ZTS608, and nested strict checks can miss a refusal, and `contract_builder.zig` then sets `canonical` true. ZTS620 is missed in a closure. ZTS604 is a false refusal in a closure. | Codex arm table, `res_closure_guard2.ts`, `opt_closure.ts` (Fable) |
| D13 | `bool_checker.zig` | `.spread` is treated as a leaf, and `object_spread` is read as a property. | A boolean misuse is inside a spread operand. | A missed boolean error. Boolean errors gate contract extraction in `pipeline.zig`. | Codex (code read, no probe) |
| D14 | `type_checker.zig` narrowing across a call | A narrowing is not killed when a call runs a closure that assigns the narrowed variable. Inside the closure the variable is an `upvalue` binding with another key, and no call kills narrowings. | `let x: string \| undefined`; a closure sets `x = undefined`; an `x === undefined` early return; the closure is called; then `needS(x)`. | No ZTS203. Only the unrelated ZTS604 and ZTS600 refuse the probe today. | `/private/tmp/claude-501/w4/p/o1.ts` (found during W4) |
| D15 | `path_generator.zig` paths through a `match` expression | A `match` used as an expression (for example `return match (x) { ... }`) yields one behavior path, so its arms are not separate paths. | An edit adds an arm to a `match` that a handler returns. | `prove-behavior` reports `equivalent` (found during W7b, present before it). | not yet probed in a committed test |

D13 has no probe yet. W10 writes one before it changes code.

D14 and D15 are out of scope for this plan. D14 needs its own design, because a sound rule must kill narrowings of every captured variable that any called closure can assign. D15 needs `walkPaths` to fork a path for each arm of a `match` expression. Both are recorded here for the owner and for a later unit.

## Design

The defect class is one walk that does not know every child of every node. Thirteen local fixes would close these cases and leave the class open for the next tag or the next walk. This plan adds one shared, exhaustive child map. The fixed walks use the map for every tag that they do not name, so a new node kind fails to compile in one place and each walk descends into it by default.

`IrView` already has three partial descents: `forEachChild` (statements only), `subtreeContains`, and the private `forEachSubNode` in `proof_ir.zig`. This plan does not migrate `forEachChild` or `forEachSubNode`, because `proof_ir.zig` lowering feeds certificate bytes. It fixes `subtreeContains`.

The new map yields the **expression children** of a node: every child node that holds code, in source order, including function bodies. It excludes binding positions (a declared name, a parameter, a pattern-bound identifier) and import specifiers. It also excludes `match` patterns. A pattern test is evaluated at runtime, but its parser-built `isDict(x)` call would reach `handleCall` in the effect walk, miss `importOf` and `userFnOf`, and set `row.lower_bound` on every type-test `match`. No consumer needs pattern children today (Fable probe `res_match2.ts`). The doc comment states this exclusion and its reason.

Descent alone is conservative only for walks that have no scoped state. The validation round confirmed this for three of them:
- The effect walk compares `discarded_call` with the whole `expr_stmt` value, so a nested call never gains the sink exemption.
- The narrowing-kill walk only kills more. The one refusal that can disappear is ZTS107 (a redundant narrowing), and it disappears correctly.
- The I/O tracker only records more calls.

The verifier is different. Its checked state is set on sight, so descending into a closure body would let a guard inside the closure clear the obligation for the enclosing scope. W3 therefore scopes the state first and adds the descent second.

## Units

Each unit is one commit. Each unit adds its probe sources as tests through the public entry point that the pass's existing tests use. Each test asserts the expected value, and the probe and its control give different verdicts. Run every build with a private `ZIG_LOCAL_CACHE_DIR` and `ZIG_GLOBAL_CACHE_DIR` under `/private/tmp/claude-501/`, with `DEEPSEEK_API_KEY` unset.

### W1: the expression-child map in `parser/ir.zig`

Add `IrView.forEachExpressionChild` (or an iterator with the same contract). The callers have different error sets: `WalkError`, `error{OutOfMemory}`, and `void` in `type_checker.zig` and `handler_verifier.zig`. The implementer chooses a signature that composes with all of them, and writes the reason in the doc comment. Do not put `anyerror` in a caller's signature.

- The switch names all 69 `NodeTag` members and has no `else` arm. The storage map from the Codex round is in the worklog, section "Validation round".
- `.spread`, `.object_spread`, `await_expr`, `yield_expr`, `throw_stmt`, `return_stmt`, `expr_stmt`, `export_default`, and `export_all` yield the `getOptValue` operand.
- `object_property` and the object method kinds yield the value, and they also yield the key when the key node is not a string. The parser refuses computed keys today, but the storage keeps a key node.
- `function_expr` and `arrow_function` yield the body, not the parameter list. `function_decl` and `var_decl` yield the initializer.
- `match_arm` yields the body only. The IR has no guard.
- `pattern_element`, `pattern_rest`, and `pattern_default` yield the default value, not the nested pattern.
- `try_stmt` and `labeled_stmt` have no typed accessor. Add a minimal accessor, or decode the payload in the map with a comment.
- The 15 leaf tags yield nothing.

Fix `subtreeContains`: read `.spread` with `getOptValue`, and add `assert_stmt` and `object_spread`.

Tests: for each of the 32 tags that the parser produces and that carry children, parse a small program and check the exact list of children. Add `subtreeContains` tests for a spread operand, an object spread operand, and an `assert` condition.

### W2: the effect walks (D1, D2)

In `effect_inference.zig`, in both `walkBaseExpr` and `includeReachableNodeEffects`: add an `assert_stmt` arm that walks the condition and the error expression, fix `.spread`, and walk an `object_spread` member's operand in the `object_literal` arm. Replace `else => {}` with a descent through the map. `contract_builder.zig` `computeProperties` combines both projections, so both must change. In `isSafeDataShape`, fix `.spread` and keep `else => false`.

Tests: `in_assert.ts`, `in_spread.ts`, and `in_objspread.ts` give `read_only`, `retry_safe`, and `idempotent` false. `cap_in_assert.ts` is refused. The controls `base.ts`, `in_spread_base.ts`, and `cap_base.ts` keep their results.

### W3a: scoped checked state in the verifier (D4)

In `handler_verifier.zig`, give `walkForResultsAndRefs` a journal of `ok_checked` and `narrowed` changes for each block. At the end of the block, the walk restores every flag that the block changed, except a change that an early-return guard in the same block made for the code after it. This is the same model as `beginNarrowScope` and `endNarrowScope` in `type_checker.zig`. An assignment to a tracked Result binding clears `ok_checked`. An assignment of an optional-producing call to a tracked optional binding clears `narrowed`.

Tests: `res_nested.ts` and `res_let_reassign.ts` give ZTS303, and `opt_renarrow.ts` gives ZTS309. A guard at the handler's top level still clears the obligation for the code after it: `res2_base.ts` with an `if (!result.ok) { return ...; }` guard gives no ZTS303.

### W3b: verifier descent (D3)

- `walkForResultsAndRefs`: add an `assert_stmt` arm that sends the condition and the error expression to `walkExprForRefs`, and a `function_decl` arm. Replace `else => {}` with a descent through the map.
- `walkExprForRefs`: add `function_expr` and `arrow_function` arms. Fix `.spread`. Replace `else => {}` with a descent through the map.
- A nested function body is walked with every `ok_checked` and `narrowed` flag cleared, and the walk restores the flags afterwards. A closure can run at any later time, so no check outside it holds inside it. An assignment inside a nested body never narrows the enclosing scope. This costs precision, and it is fail-closed.

`assert result.ok` does not narrow today (`res3_assertok.ts`). That is a false refusal, so it is out of scope.

Tests: `res2_assert.ts` and `res2_closure.ts` give ZTS303, and `res2_assert.ts` gives no ZTS305. Fable's `res_closure_guard2.ts`, `res_closure_guard3.ts`, and `opt_closure2.ts` keep their current refusals.

### W4: the type checker (D5, D6)

- `killNarrowingsAssignedIn`: the `assignment` arm also descends into the target. Replace `else => {}` with a descent through the map, including nested function bodies. Correct the comment: a missed kill is the unsound direction.
- `bodyReturnType`: add `for_of_stmt` and `for_in_stmt` arms. A loop can run zero times, so a `return` inside the loop does not end the function. The implementer reads how the `if`-only shape gets ZTS208 today (`r6_if_only.ts`) and gives the loop the same treatment. Add an `assert_stmt` arm that joins the type of the error expression.
- The `assert_stmt` arm of the statement walk compares the error expression with the declared return type, with the same check that `return_stmt` uses.

Measure before the commit. List each corpus, example, and fixture handler that gets a new ZTS204.

Tests: `n2_init.ts` gives ZTS203, and `n2_base.ts` still gives ZTS203. `r3_forof.ts` gives ZTS203 at `needS(v)`. Fable's `r5_forof_only.ts` stays refused. An `assert` variant of `r3` gives ZTS203. A function `(): string` with `assert c, 5;` gives ZTS204.

### W5: the route resolver (D7)

- `assignmentRootBinding` returns a tagged result, for example `union(enum) { binding: ir.BindingRef, untracked, none }`. An `array_literal` root descends into each element's root. Another non-identifier root is `untracked`, and `bindingIsMutated` counts it as a mutation of every table. An identifier root with no binding keeps its current behavior.
- `bindingEscapesStableResolutionDepth` scans every value position through the map, including `for...of` iterables, `match` discriminants, and `expr_stmt` values. `callKeepsArgumentLocal` uses the same scan.

`bindingIsMutated` also runs on callee parameters, so an `untracked` root anywhere in the file unresolves every router table. Measure that cost before the commit, and list each changed verdict.

Tests: `rt2_arrayroot.ts` and `rt_forof.ts` give ZTS302 and ZTS303. `rt2_base.ts` and `rt2_direct.ts` keep their results.

### W6: the I/O tracker (D8)

In `path_generator.zig`, `trackModuleCallUnder` descends through the map and records every module call in source order. A call in the right operand of `??`, or in a branch of a ternary, runs only on some paths. The implementer chooses how to record it, and the choice must not drop a call from every path. Nested function bodies are not descended, because `walkPaths` does not descend into them either.

Tests: `diff_ret2_a.ts` to `diff_ret2_b.ts` and `diff_ret3_a.ts` to `diff_ret3_b.ts` are `breaking`. A self-diff of each file stays `equivalent`.

### W7a: the law half of the argument compare (D10)

- In `computeArgSignature`, give `?` for a string literal that contains `|`.
- In `signaturesEqual`, return false when either signature has a `?` token.
- Update the doc comments in `behavior_canonical.zig` and in the contract format documentation.

Tests: `diff_two_dyn.ts` to `diff_one_dyn.ts` is `breaking`. `diff_two_lit.ts` to `diff_one_lit.ts` stays `breaking`. Two identical literal-key writes collapsed to one stay `equivalent_modulo_laws`. Add a unit test with two adjacent `?` signatures.

### W7b: the structural half of the argument compare (D9)

The owner chose decision 9(a). When a compared path has a `?` token on either side, the diff is not a safe no-op. Two handlers with an equal IR identity (`ir_identity.zig`) stay `equivalent`. Contract bytes do not move. The implementer confirms that `ir_identity.zig` gives an identity for a whole handler module and that `prove-behavior` can reach it; if it cannot, stop and report.

Tests for every option: `diff_one_dyn.ts` to `diff_one_dyn_b.ts` is not a safe no-op. `diff_same.ts` to itself stays `equivalent`.

### W8: `assert` paths (D11)

In `path_generator.zig`, handle `assert_stmt` in `walkPaths` itself and in `walkBlockFrom`. An unbraced branch body reaches `walkPaths` without `walkBlockFrom`. Model `assert c, e` exactly as `if (!c) { return e; }`:
- Track the module calls in `c` on both paths.
- Fork one failure path for each case in `falseCases(c)`, with the status of `e`, and track the calls in `e` on the failure path only.
- With no error expression, the failure status is 500.
- Continue the block under `extractAllConstraints(c)`.

Add a status helper for an expression. Correct the `else` arm comment in `walkPaths`.

This unit can move `fault_covered` from refused to proven, because `assert result.ok, e` puts `result_not_ok` on a failure path. That move is correct. List every moved verdict and golden in the worklog. None of the five contract-golden inputs has an `assert` handler, so the golden count needs measurement.

Tests: `as_a.ts` to `as_b.ts` is `breaking` with `response_changed=1`. `if_a.ts` to `if_b.ts` stays `breaking`. Check the path count for one `assert` handler and for an unbraced `if` body that holds an `assert`.

### W9: the strict checker (D12)

In `strict_checker.zig`: fix the six `.spread` arms (`isPureExpr`, `walkExpr`, `findScrutineeFieldRead`, `scanLiveMutation`, `collectExprAssignments`, `collectCallCounts`), and fix the `object_spread` read in `collectCallCounts`. Make the walks that decide ZTS604, ZTS620, ZTS608, ZTS612, and ZTS622 descend into closure bodies. An assignment inside a closure counts as a reassignment for ZTS604.

Measure the new refusals on the corpus, the examples, and the fixtures before the commit.

Tests: a spread probe for ZTS612, ZTS622, and ZTS608. `res_closure_guard2.ts` gives ZTS620. `opt_closure.ts` gives no ZTS604.

### W10: the boolean checker (D13)

Write a probe first: a boolean misuse inside an array spread operand and inside an object spread operand. If the probe shows no missed error, record that and change nothing. Otherwise, fix `.spread` and `object_spread` in `bool_checker.zig`.

### W11: records

- Worklog: one section for each unit, with the probe results before and after, the moved verdicts and goldens, and the gate exit codes.
- `AGENTS.md`, proof-swallow paragraph: add one sentence. A walk that ends in `else => {}` over node tags is the same class as a discarded error, and a new walk uses `forEachExpressionChild` for its default arm.
- A solution note under `docs/solutions/security-issues/` through the ce-compound skill.
- The `docs/plans/README.md` index row.

## Order

W1, W2, W3a, W3b, W4, W5, W6, W7a, W7b, W8, W9, W10, W11.

## Stop conditions

The implementer stops and reports to the lead in each of these cases. The lead brings the case to the owner.

- `test-expert-app` replay fails, or `test-meta-drift` moves. Model-visible bytes moved, and a DeepSeek re-record needs owner approval.
- A unit changes a verdict from proven to refused, and the defect that the unit fixes does not cause the change.
- A unit changes a verdict from refused to proven, and this plan does not predict it. The predicted cases are in W4 (none expected), W5 (none expected), and W8 (`fault_covered`).
- `test-proof-swallow` refuses an arm, and the fix would need an allowlist row whose mechanism is not already in the allowlist. A row that joins an existing group with the same verified mechanism, for example the `handler_verifier.zig` `allocation_failed` poison, is the lead's call, and the commit says so.
- A unit would change `proof_ir.zig` lowering or certificate bytes.

## Gates

Each unit runs these steps unfiltered and reads each exit status directly: `zig fmt --check`, `zig build test-zts`, `test-precompile`, `test-contract-golden`, `test-diagnostic-corpus`, `test-flow-census`, `test-proof-swallow`, `test-standin`, `test-expert-app`, `test-meta-drift`, `test-cli`, `test-examples`, `test-server`, `test-zruntime`, `test-docs-drift`, `test-doc-links`, `check-spine` (after `git add`), and `zig build test`. After the last code unit, the lead runs `bash scripts/verify.sh`.

## Out of scope

- The contract diff gaps and the six properties that never reach the ledger (decision 7(a)).
- `contract_builder.zig` `scanFunctionNodeForApiFacts`. It misses `assert` and spreads, and it records request schema refs, auth flags, and response facts. The U5 census found no property that reads those facts: `post_only` reads only route methods and `api_routes_dynamic`, and the runtime builds `requires_bearer` and `request_schema_refs` only in test fixtures.
- The unclear arms `registerModuleBindings`, `markCallThroughHolder`, `type_checker.zig` `walkStmt`, `walkExpr`, and `inferType`.
- Migration of `forEachChild` and the `proof_ir.zig` `forEachSubNode` to the new map.
- Narrowing through `assert result.ok` in the verifier.

## Decision 9: the structural compare of a dynamic argument (decided: option a)

- (a) A safe no-op needs exact arguments. When a compared path has a `?` token on either side, the diff is not a safe no-op. The exception is two handlers with an equal IR identity (`ir_identity.zig`), which stay `equivalent`. Contract bytes do not move. An edit to a handler that passes a dynamic argument to a module call then gets `breaking` ("needs review"), even when the edit does not touch that call. Recommended: it is sound, small, and adds no new output word.
- (b) An identity token. A non-literal argument's signature becomes the canonical text of its subtree, with single-assignment `const` initializers inlined. This is more precise. Every dynamic `arg_signature` in contract JSON changes, and a same-named binding whose initializer changes compares equal unless the inliner follows it.
- (c) A new classification, for example `unproven`. This changes the public JSON vocabulary and every consumer of `Classification`.

## Progress

| Unit | State |
|---|---|
| W1 | done: `IrView.expressionChildren` and the `subtreeContains` fix; `zig build test` 200/200 steps, 9250/9256 tests |
| W2 | done: effect walks reach `assert` and spread operands; `cap_in_assert.ts` now exits 1; `zig build test` 200/200 steps, 9255/9261 tests |
| W3a | done: block-scoped checked-flag journal; `res_nested`, `res_let_reassign`, `opt_renarrow` now refused; one allowlist row (`setCheckedFlag catch-poison`); residual: a `for...of` body that reads then reassigns a Result is not caught on the second iteration |
| W3b | done: the verifier walks `assert`, nested functions, closures (with every flag cleared), and spread operands; upvalue reads map to a unique declared binding; residual: a hoisted `function` that reads a Result declared later is not resolved |
| W4 | done: the kill walk reaches every assignment; the return join covers loops, `if` without a covering return, and `assert`; ZTS204 checks an `assert` error expression; one fixture (`flow_false_proofs.zig`) wraps its `assert` message in `Response.text`; 296-file sweep unchanged |
| W5 | done: an array-literal or untracked assignment root counts as a mutation; the escape scan checks every value position through the child map; `!routes` and `typeof routes` now stay resolved (sound precision gain); 296-file sweep unchanged |
| W6 | done: the tracker records nested calls, `return` values, `if` conditions, `for...of` iterables, `match` discriminants, and inline callbacks; an added call on a preserved path is now `breaking` (was `additive`); 14 handlers gain io entries; residuals: a named closure called later, a `match` arm body that is a bare expression, a changed ternary condition |
| W7a | done: a `?` token never equals another signature in the law canonicalizer, and a `|` literal encodes as `?`; no tracked contract changed |
| W7b | done (decision 9(a)): a path with a `?` argument never matches its twin unless both sources have an equal IR identity and import only `zttp:` modules; adding a route to a `routerMatch` handler is now `breaking`; `--prove` live reload blocks a formatting-only save of a handler with a local import and a dynamic argument |
| W8 | done: `assert c, e` forks one failure path for each way `c` is false, with the status of `e` or 500 for a bare assert; an edit to an assert error response is now `breaking`; `fault_covered` can become true when `assert result.ok` guards a failable call |
| W9 | not started |
| W10 | not started |
| W11 | not started |
