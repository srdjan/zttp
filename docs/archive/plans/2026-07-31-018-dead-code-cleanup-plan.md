# Dead code cleanup

Removes functions and constants that no call site anywhere in the tree names.
Behavior preserving: every item is unreachable today, so no observable behavior
can change. No logic is straightened, no signature is altered, no test is
rewritten.

## Evidence

Detection built an identifier frequency table over all 461 git-tracked `.zig`
files, then joined it against every `fn` and `const` declaration. A count of 1
means the name occurs exactly once in the corpus: its own declaration. That
also rules out re-exports, because `pub const foo = mod.foo;` would raise the
count.

Result: 103 dead functions spanning 1190 lines of brace-matched bodies, plus 14
dead constants. Doc comments and blank separators removed alongside them are
not in that 1190.

Baseline: `zig build` exits 0, working tree clean.

Two facts the scan does not cover, both accepted:

- Transitive death. A function kept alive by one dead caller still scores above
  1. Step 14 re-runs the census after the removals land and repeats to fixpoint.
- Non-`.zig` files, and branches that are reachable but never exercised.

## Scope

In: tier 1 and tier 2 from the findings report.

Out, deliberately:

- `packages/zts/src/sqlite.zig`, 10 unused `bind*`/`column*` wrappers. Unused,
  but the symmetric surface of a C binding exported as `pub const sqlite` from
  both `packages/zts/src/root.zig:134` and `packages/zttp-sdk/src/root.zig:12`.
  Deleting half a facade is a product call, not a cleanup call.
- `packages/zts/src/atom_table.zig:69 pruneUnused`.
  `docs/archive/plans-advisory/011-cap-reuse-unbounded-atom-growth.md` records
  it as deliberately deferred, not forgotten. Removing it contradicts a written
  decision.

## Risks

**Module boundary gate.** `scripts/check-module-boundary.sh` fails in both
directions: an unlisted reach fails, and a row nothing uses fails too. If a
deletion in `runtime`, `tools`, or `pi` removes the last reach into a `zts`
internal module, `zig build test-module-boundary` goes red. The fix is to drop
the now-unused row from `scripts/module-boundary.allow` in the same commit, and
say so in the message. Steps 11 through 13 run that gate.

**Zig lazy analysis.** A never-called `pub fn` is not semantically analyzed, so
dead code can hide compile errors. Step 3 removes one confirmed instance.
Deleting such code cannot break the build; it can only stop hiding rot.

**Archived docs.** `docs/archive/plans-advisory/005-use-utf16-string-indexing.md`
names `codepointLength` and the archive `011` names `pruneUnused`. Archived
plans are historical records. Do not edit them.

**No checkpoint commit needed.** Working tree is clean at plan time.

## Verification per step

Every step runs, in order, and all must pass before the commit:

1. `zig build`
2. the package test step named in the item
3. `zig fmt --check build.zig packages/`

A red check is fixed before the next item starts. No accumulating broken state.

## Steps

Ordered leaf-first: engine internals with no cross-package reach come before
`runtime`, `tools`, and `pi`, where the boundary gate can fire.

### 1. Drop the unreachable Map and Set builtins

Delete `packages/zts/src/builtins/map.zig` (216 lines) and
`packages/zts/src/builtins/set.zig` (156 lines) whole, plus the two re-export
lines `packages/zts/src/builtins/root.zig:16-17`.

All 11 exported functions are unreachable. The comment at `map.zig:32` states
why: the constructor is not installed as a global and `new` is rejected at
parse time, so no language path reaches it. Neither file has a test.

Verify: `zig build test-zts`.

### 2. Drop the unused ErrorBuilder facade

Delete the `ErrorBuilder` struct, `packages/zts/src/parser/error.zig:301-390`,
and the `test "error builder patterns"` block at `:408`, which is the struct's
only caller. Delete the dead alias `packages/zts/src/parser/parse.zig:40` and
the re-export `packages/zts/src/parser/root.zig:60`.

19 of 21 methods score 1. The other two, `init` and `expectedIdentifier`, are
named only by that one test.

`ErrorList.addExpectedError` and `ErrorList.addErrorAt` stay: `parse.zig` calls
them directly at `:1429`, `:1485`, `:3118`, `:3136`, `:3148` and across the
unsupported-feature diagnostics at `:215-270`.

Verify: `zig build test-zts`.

### 3. Drop clearCompiledCodePointers, which calls a method that does not exist

Delete `packages/zts/src/context.zig:390-402`.

It calls `self.clearCompiledCodeRecursive(...)` at `:393` and `:397`. That
method has no definition in the tree. The only definition lives in
`.worktrees/optimize-zts-compile-throughput-baseline/packages/zts/src/context.zig:880`,
an untracked stale worktree. The build stays green only because Zig does not
analyze a `pub fn` nobody calls. Any caller would fail to compile.

Own commit, typed `fix` not `chore`, because it records rot rather than tidying.

Verify: `zig build test-zts`.

### 4. Drop the unused hybrid allocation helpers

Delete `allocEphemeral:448`, `createEphemeral:457`, `allocPersistent:466`,
`createPersistent:475`, and `isHybridEnabled:529` from
`packages/zts/src/context.zig`.

The whole hybrid-allocator entry surface is unreached. Keep the `hybrid` field
and keep `isEphemeralValue:533`, which scores above 1 and is live.

Verify: `zig build test-zts`.

### 5. Drop unused parser IR helpers

`packages/zts/src/parser/ir.zig`: `litNull:591`, `getMut:671`,
`fromIndices:811`, `fromIndexCount:816`, `getCount:848`, `getIndex2:853`,
`addExtraValue:974`, `getExtraValue:1001`.

Verify: `zig build test-zts`.

### 6. Drop unused parser scope helpers

`packages/zts/src/parser/scope.zig`: `findLocalMut:128`,
`isDeclaredInCurrentScopeByAtom:388`, `isDeclaredInCurrentScope:394`,
`getEnclosingFunction:410`, `inFunction:426`, `inLoop:432`,
`getUpvalueInfo:454`.

Verify: `zig build test-zts`.

### 7. Drop unused token predicates

`packages/zts/src/parser/token.zig`: `isAssignment:225`,
`canStartExpression:249`.

Verify: `zig build test-zts`.

### 8. Drop unused memory-layer helpers

- `packages/zts/src/value.zig`: `getValue:209`, `getId:292`
- `packages/zts/src/heap.zig`: `setRemembered:406`, `getRemembered:414`, the
  write-barrier pair that was never wired
- `packages/zts/src/arena.zig`: `createAligned:138`, `remainingBytes:232`
- `packages/zts/src/object.zig`: `createWithArenaFast:1413`
- `packages/zts/src/gc.zig`: `releaseUpvalue:786`

Verify: `zig build test-zts`.

### 9. Drop unused string, number, console, and http helpers

- `packages/zts/src/string.zig`: `codepointLength:63`,
  `concatStringNumberWithArena:1401`, `concatNumberStringWithArena:1427`
- `packages/zts/src/builtins/number.zig`: `numberToFixed:208`,
  `numberToString:236`
- `packages/zts/src/builtins/console.zig`: `consoleWarn:19`
- `packages/zts/src/http.zig`: `createRequest:41`

Verify: `zig build test-zts`.

### 10. Drop unused analysis and codegen helpers, and the unchecked fsync

- `packages/zts/src/semantics.zig`: `isSpecifiedNode:349`,
  `isSpecifiedOpcode:356`
- `packages/zts/src/type_env.zig`: `getVarTypeByLoc:727`
- `packages/zts/src/strict_checker.zig`: `isCanonicalProfile:103`
- `packages/zts/src/parser/ir_opt.zig`: `getReplacement:82`
- `packages/zts/src/parser/codegen.zig`: `generateFunction:309`
- `packages/zts/src/bytecode.zig`: `getCodeVersion:1128`
- `packages/zts/src/wasm/interpreter.zig`: `callPolicyCheck:35`
- `packages/zts/src/trace.zig`: `fsyncFd:1809`, superseded by
  `fsyncFdChecked:1813`

On the last one: `persistBuffer:1563` is the single choke point for all eleven
`persist*` paths and it calls the checked variant. The unchecked one is a
leftover, not a durability hole.

Verify: `zig build test-zts`.

### 11. Drop dead constants and type aliases

- `packages/zts/src/root.zig:209-215`: `PolicyAction`, `PolicyActor`,
  `PolicyResource`, `PolicyEnvironment`, `PolicyDenyReason`. Keep
  `PolicyInput`, `PolicyResult`, `LocalPolicyChecker`, which are live.
- `packages/zts/src/policy.zig:17-18`: `resource_kind_namespace`,
  `resource_kind_env_var`. Keep `resource_kind_host`, `resource_kind_sql_query`.
- `packages/zts/src/rule_error.zig:8` `RuleError`
- `packages/zts/src/parser/parse.zig:43` `ParseErr`
- `packages/zts/src/modules/internal/file_resolver.zig:12` `MAX_PATH_LEN`
- `packages/zts/src/context.zig:15` `interp_util`, an unused import
- `packages/pi/src/autoloop.zig:95` `DriveError`
- `packages/runtime/src/verify_cli.zig:141` `FetchError`
- `packages/runtime/src/attest/identity.zig:20` `KeyError`

Verify: `zig build test-zts`, `zig build test-zruntime`,
`zig build test-module-boundary`, `zig build test`.

### 12. Drop unused runtime helpers

- `packages/runtime/src/runtime_pool.zig`: `setEmbeddedBytecode:236`,
  `executeHandlerBorrowedLeased:449`, `getCacheStats:493`
- `packages/runtime/src/engine_adapter.zig`: `poolInUse:108`,
  `poolCapacity:112`
- `packages/runtime/src/posix_util.zig`: `isExpectedNetworkError:112`
- `packages/runtime/src/http_parser.zig`: `parseHeadersFromLines:153`
- `packages/runtime/src/handler_instance.zig`: `serializeBytecode:1251`
- `packages/runtime/src/contract_runtime.zig`: `costCeilings:237`

On `costCeilings`: `docs/archive/plans/2026-07-29-003` warns that
`deriveCostCeilings` backs `ValidatedRuntimeContract.costCeilings` and must not
be swept up. Confirm which of the two the scan flagged before cutting. If the
producer is live and only the accessor is dead, remove the accessor alone.

Verify: `zig build test-zruntime`, `zig build test-module-boundary`.

### 13. Drop unused tools and pi helpers

- `packages/tools/src/precompile_args.zig`: `parsePrecompileArgs:54`
- `packages/tools/src/manifest_alignment.zig`: `writeAlignmentJson:415`
- `packages/pi/src/property_goals.zig`: `boolPropertyNameAt:74`
- `packages/pi/src/providers/cassette_record.zig`: `modeFromEnv:47`
- `packages/pi/src/loop.zig`: `withContext:93`
- `packages/pi/src/registry/tool.zig`: `withUiPayload:50`

Verify: `zig build test`, `zig build test-cli`,
`zig build test-module-boundary`.

### 14. Transitive pass to fixpoint

Re-run the frequency census. Removing 103 callers can orphan private helpers
that previously scored above 1. Delete the new zero-reference set, re-run, and
repeat until the census returns nothing. Each round is its own commit.

Verify per round: `zig build`, `zig build test-zts`, `zig build test-zruntime`.

### 15. Full gate

`bash scripts/verify.sh`, which covers `zig build test`, `test-zruntime`,
`ReleaseFast`, `smoke-v1`, `test-panic-isolation`, `test-cli -Dstudio`, and
`zig fmt --check`.

## Expected impact

1190 lines of measured function bodies, plus surrounding doc comments, plus 14
constant declarations, plus 2 files deleted whole. Public behavior unchanged.
Two `docs/` files may need a follow-up if step 12 touches `costCeilings`.
