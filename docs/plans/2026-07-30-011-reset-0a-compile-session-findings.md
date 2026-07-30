# Reset 0a: the compile session, measured

Item 0a of `docs/plans/2026-07-28-001-reset-simplification-plan.md`, section 4.5. The first
slice, removing the three infallible constructors, shipped as
`docs/plans/2026-07-29-001-wave4-reset-a-fallible-compile-plan.md` and told the next reader to
write a separate plan for the rest. This is that document, written after measuring rather than
before.

**Ground truth:** measured 2026-07-30 at commit `a0f289f3`, ReleaseFast unless stated.

## What section 4.5 asked for, clause by clause

| Clause | Verdict |
| --- | --- |
| One fallible `CompileRequest` to `CompiledModule` API | Not built, and the reason is a decision already taken. See section 3 |
| Explicit Parsed, Resolved, Checked, Contracted, Lowered stages | Parsed, Resolved, and Checked exist in `pipeline.zig`. Lowered is DECLINED (`2026-07-30-007`). Contracted is a function, not a phase type, and nothing asked for the type |
| Stop recreating type, environment, and checker state during contract extraction | DONE, `2cdbbad9` |
| One idempotent `deinit` on an owned result | Partly. `HandlerContract.deinit` is the owned result for the contract path, and `build` now has an unwind so it is reached on failure. There is no single result spanning bytecode and contract, because there is no single orchestrator to produce one |
| Move compile benchmarking off the arena that masks nested-function ownership | DONE, `a0f289f3` |
| Every compile path, including every failure stage, leak-free under `std.testing.allocator` | DONE for parse, resolve, check, and contract extraction, `5ee01ba3`. Not asserted for the codegen and serialization stages, which live in `precompile.zig` |

## 1. The duplicated type session was real, and it was two of everything

Measured by counting constructor calls on a Debug build, driven through `zts`:

```
zts check handler.ts                      TypeChecker=2 TypeEnv=2 TypePool=2 BoolChecker=1
zts check handler.ts --contract           TypeChecker=2 TypeEnv=2 TypePool=2 BoolChecker=1
zts check handler.ts --types --contract    TypeChecker=2 TypeEnv=2 TypePool=2 BoolChecker=1
zts compile handler.ts out.zig             TypeChecker=2 TypeEnv=2 TypePool=2 BoolChecker=1
```

Both productions sit in `pipeline.zig`: `resolve` builds one, and
`extractContractFromParsed` built a second from the same `TypeMap`, with the same
`populateModuleTypes` call and the same `service_type_context`, then re-ran the type check over
the same root. Not similar, identical.

Cost, with in-process timers on a warm ReleaseFast build:

| Segment | Per compile |
| --- | --- |
| `resolve` type check | 20 to 55 us |
| Contract-extraction env build | 20 to 57 us |
| Contract-extraction type check | 3 to 8 us |
| Whole in-process run, `check --contract` | 850 to 1,100 us |

So the duplicate is about 4 percent of the in-process run. End-to-end process wall clock is 3
to 4.5 ms and is dominated by exec, so the change is not resolvable there, and the 200-run
timings before and after differ by less than their own round-to-round spread. The reason to do
it is the ownership, not the microseconds; the microseconds are recorded so nobody claims more.

`ExtractContractOptions.resolved` now carries the session. It is deliberately narrow: a resolve
with no type env leaves `type_checker` null and extraction builds its own, and a caller that
overrode `type_check` still gets its override run. Contracts are byte-identical, checked by the
four goldens and by diffing `contract.json` with the reuse forced off.

## 2. The failure sweep, and the three defects it found

The acceptance criterion is objective, so it is now a test: parse, resolve, check, and extract,
229 allocations, one failure injected per iteration, leaks reported by
`std.testing.allocator`.

**The parser hung on an out-of-memory.** `ErrorList.addErrorAt` set `errors_truncated` and
returned. Nothing read that flag - it was written in three places and read in none - so
`hasErrors()` stayed false, `parse` took its recovery branch, and `synchronize` returns without
advancing when the current token starts a statement. The same statement was then parsed
forever. Reproduced at fail index 7 on a five-line handler and confirmed with a sampled stack:
`parse` to `parseStatement` to `parsePrefixExpr` to `errorAtCurrent` to `addErrorAt`, on repeat.

This is worse than a leak. A leak ends when the process does; this one does not end.

**`ContractBuilder.build` had no unwind.** Its contract literal contained three fallible
expressions, so a later one dropped the earlier ones, and the five discharge phases after the
literal each added to a contract nobody would free. 259 leaked allocations.

**An errdefer cannot be disarmed.** Adding the contract's unwind turned the leaks into double
frees, because six locals - `routes`, `saga_calls`, the two index copies, the handler path, and
`declared_specs` - kept their own errdefers alive after ownership moved. Each is now emptied at
the point of transfer. This is the same lesson as the `payload_memory` walk and the B1 ladders:
the transfer point is where the ownership has to be stated, and until it is stated it is
guessed.

None of the three were introduced here. All three were reachable from `zts check` on any
handler, on a machine under memory pressure.

## 3. Why there is no `CompileRequest` type

The clause says the session "subsumes the weaker proposal elsewhere in this document to merely
move `precompile.zig`'s orchestration into `pipeline.zig`: the orchestration move is the same
work done properly."

That orchestration move was planned in detail and DECLINED
(`docs/plans/2026-07-30-007-lowered-module-plan.md`, section 8, option 3). The reason is not
effort, it is a boundary: `pipeline.zig` production code performs zero file, process, or libc
IO, because the wasm analyzer build strips libc, while `precompile.zig` carries 148 such
references. A `CompileRequest` to `CompiledModule` API that owns bytecode as well as the
contract has to span that boundary, so building it means re-taking the declined decision, not
implementing an open one.

What the clause was actually about - one fallible entry, one owned result, one deinit, and no
state rebuilt between stages - is delivered for the analysis half, which is the half that lives
in `pipeline.zig`. The codegen half stays where the IO is.

Reopen this only with the concrete consumer section 8 of the lowered-module plan asks for: a
build cache or an incremental compile. At that point the type has a producer and the boundary
question has an answer that is not architectural taste.

## 4. What is left

- The failure sweep covers the analysis stages. Codegen, bytecode verification, and
  serialization are not swept, because they are driven from `precompile.zig`, which does IO.
  A sweep there would need a fixture harness rather than an in-file test.
- `intent_value` in `ContractBuilder.build` has no unwind between its construction and the
  contract literal. The sweep did not reach it, which means either the window is unreachable or
  the corpus does not carry an `export const intent`. Worth one targeted fixture.
