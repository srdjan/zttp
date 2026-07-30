# Plan: one orchestrator, and the `LoweredModule` phase it unblocks

**Status:** DECLINED, option 3 of section 8, decided 2026-07-30. Task 1 landed anyway at commit
`8c27464c` and stands on its own; Tasks 2-5 will not be done.

This document is kept rather than deleted because the decision needs its reasoning attached.
The clause is not open work, and the next reader should not reopen it without the new
justification section 8 asks for.

**Source:** the orchestration clause of wave 4 item 4. Its original justification, that
`PathGenerator` and `FlowChecker` run more than once per compile, was measured and refuted
(`docs/plans/2026-07-30-006-item4-c3-findings.md`). This plan restates the justification
honestly and scopes the work to what that justification supports.

**Ground truth:** measured at commit `ef58324e` on 2026-07-30.

## 1. The honest justification

There is no performance case and no correctness case. Both passes already run once, and the
shared index work (C1, C2) already removed the duplicated import walks. What remains is one
architectural claim, and it is the file's own:

> A fourth `LoweredModule` phase is intentionally not added until `precompile.zig`'s
> codegen-bearing orchestrator migrates; introducing the type before it has a real producer
> would ship dead API.
> — `pipeline.zig` header

So the deliverable is not "move code". It is: **make `LoweredModule` have a real producer, so
the phase pipeline covers compilation end to end instead of stopping at `CheckedModule`.**
Anything that does not serve that is out of scope, however tempting it looks while reading a
4,594-line file.

If that claim does not justify the cost to you, the correct outcome is to close the clause as
declined rather than to do it. Section 8 is where that decision belongs.

## 2. The constraint that shapes everything

`pipeline.zig` production code performs **zero** file, process, or libc IO. Its only
`file_io` reference is inside a test (`pipeline.zig:874-876`). That is not an accident:
`file_io.zig` carries 21 `std.c`/`std.posix` references and the engine has an `analyzer_only`
build (`build.zig:558`) that strips libc, the interpreter, the JIT, the GC, and SQLite for the
wasm analyzer.

`precompile.zig`, by contrast, has 148 references to `std.fs`, `file_io`, `std.process`,
`std.c.write`, or `debugPrint`.

**Therefore the orchestration cannot simply move.** It has to be split along a line that did
not previously need to be drawn:

| Stays in `packages/tools/precompile.zig` | Moves to `packages/zts/pipeline.zig` |
| --- | --- |
| Reading source files | Type stripping |
| Writing the generated `.zig` artifact (`writeZigFile`, ~250 lines of emitters) | Parse, atom and string table setup, JSX mode |
| Every `debugPrint` and stderr report | IR optimization |
| SQLite schema validation (`validateSqlContract`, `openSqlSchemaDatabase`) | Handler verification and flow analysis (already there) |
| Policy enforcement printing (`printSandboxReport`, `printPropertiesReport`) | Contract extraction (already there) |
| CLI argument parsing (`runCompileWithArgs`) | Bytecode verification |
| Multi-module file reading | Bytecode serialization (`bytecode_cache.serializeBytecodeWithAtomsAndShapes`) |
| | AOT dispatch analysis |

Everything in the right column is already `zts` code that `precompile.zig` merely calls in
order. That is the good news, and it is what makes this feasible at all: `codegen.zig`,
`bytecode_cache.zig`, and `stripper.zig` all live in the engine.

Everything in the left column must NOT move, and a plan that lets it drift across the boundary
breaks the wasm analyzer build. `zig build wasm` is therefore a gate on every task here, not
an afterthought.

## 3. What `compileHandler` actually does

628 lines (`precompile.zig:1510-2137`). Read in order, its steps are:

1. Type strip for `.ts`/`.tsx` (`:1529`)
2. String and atom table init (`:1568`)
3. Parse (`:1575`), JSX mode for `.jsx`/`.tsx` (`:1580`)
4. File-import check, diverting to the multi-module path (`:1609`)
5. IR optimization (`:1633`)
6. Handler verification, collecting violations from three sources (`:1719-1728`)
7. Wire `BoolChecker` type annotations for opcode specialization (`:1845`)
8. Bytecode verification (`:1857`)
9. Object literal shapes from the parser (`:1867`)
10. Bytecode serialization (`:1871`)
11. Contract build, with AOT when contract output or policy validation is on (`:1941`)
12. Exhaustive test generation from path analysis (`:1977`)

Steps 1 through 12 are all engine operations. What makes `compileHandler` un-movable today is
not the steps but what is interleaved between them: `debugPrint` calls, error formatting, and
the result struct it assembles for the CLI.

Step 7 is the one to watch. It borrows a type map owned by `resolved.bool_checker` and passes
it to codegen; the comment at `:1845-1846` says the pass-through borrow is safe. Any reordering
that changes when `resolved` is destroyed breaks it silently, because a stale borrow is not a
compile error.

## 4. Design

`LoweredModule` is added as the fourth phase, owning what steps 7 through 10 produce:

```zig
pub const LoweredModule = struct {
    checked: *const CheckedModule,   // borrow, for the same reason CheckedModule borrows ResolvedModule
    bytecode: []u8,                  // owned, serialized with atoms and shapes
    shapes: []const ObjectShape,     // borrowed from the codegen
    verified: bool,                  // bytecode_verifier verdict
};

pub fn lower(allocator, checked: *const CheckedModule, opts: LowerOptions) !LoweredModule
```

The borrow of `*const CheckedModule` is not stylistic. Steps 7 to 10 read a type map owned by
`ResolvedModule.bool_checker`, so the phase that lowers must not outlive, or move, the phase
that holds it. This is the third time this pattern appears in the file, after
`CheckedModule` borrowing `ResolvedModule` and C2's index being caller-owned; the plan follows
it rather than inventing a fourth ownership story.

`precompile.compileHandler` then becomes: read the file, call the phases in order, emit the
artifact, print the reports. The phase sequencing moves; nothing else does.

## 5. Why this is the riskiest thing attempted in this reset

Three reasons, stated so they are not discovered late.

**Silent-failure surface.** Every prior plan in this series had a mechanical gate: byte-identical
goldens, identical collected-test counts, a differential over a corpus. This one moves control
flow across a package boundary, and the failure mode is a stale borrow or a changed
destruction order, which no golden detects. Step 7's type-map borrow is the specific hazard.

**No behavioral gate exists for the lowering path.** The four contract goldens cover contract
extraction. Nothing pins the serialized bytecode of a compile. So a gate has to be BUILT before
the move: a golden over the serialized bytecode bytes for a set of fixture handlers. Without
it, "the tests pass" would mean only that nothing crashed.

**The wasm build is a real constraint, not a formality.** `zig build wasm` must pass after every
task, or the analyzer stops building and nobody notices until the playground breaks.

## 6. Tasks

### Task 1: pin the lowering output before touching it

Add a golden over serialized bytecode for the existing contract fixtures: compile each, hash
the `bytecode_data` that step 10 produces, and commit the hashes. Wire it into `zig build test`
beside `contract_golden_step`.

This is the gate the rest of the plan depends on, and it has value even if section 8 declines
the move: it pins an artifact the product ships and currently nothing checks.

**Verify:** the golden passes; mutating one opcode in a fixture makes it fail and name the
fixture. A gate never observed failing is not known to work.

**Commit:** `test(tools): pin serialized bytecode for the compile fixtures`.

**DONE**, at `8c27464c`, with three deviations worth recording:

- The golden covers four INLINE sources, not the four contract fixtures. Two ways of reaching
  the fixture files were tried and rejected. `@embedFile` with a relative path is refused by
  Zig ("embed of file outside package path"), and injecting the fixtures as anonymous build
  imports broke every other test root that includes `precompile.zig` - `system_rollout.zig`
  and `canonicalize.zig` among them - because those roots have no such import. Inline sources
  cover the same four codegen shapes with no cross-root coupling.
- `zig build test-precompile` was GREEN while `zig build test` was broken by that second
  approach. Fourth instance this session of a narrow check passing while something was wrong;
  the aggregate run is the one that counts.
- Two mutation probes proved nothing before one worked. `CACHE_VERSION` belongs to a different
  serializer than the compile path uses, and `nop` is never emitted. Renumbering `push_const`
  drifts all four, which is the proof that matters.

### Task 2: extract the phase sequence with no move

Inside `precompile.compileHandler`, group steps 1 to 12 so each is a single call with no
interleaved printing, leaving `debugPrint` calls hoisted to the boundaries. Same file, same
package, no behavior change.

This is the step that makes the diff in Task 3 readable, and it can be abandoned harmlessly.

**Verify:** bytecode golden and contract goldens byte-identical; `verify.sh` exit 0.

**Commit:** `refactor(tools): separate compileHandler's phases from its reporting`.

### Task 3: add `LoweredModule` and `lower`

Move steps 7 to 10 into `pipeline.zig` behind `lower`. `precompile` calls it.

**Verify:** as Task 2, plus `zig build wasm`, plus a test asserting `lower` produces the same
bytes as the fixture golden.

**Commit:** `feat(pipeline): add the LoweredModule phase`.

### Task 4: move steps 1 to 6 behind a `compile` entry point

Only if Task 3 is clean. This is where the parse and strip sequencing moves, and it is the
largest single diff.

**Verify:** as Task 3.

**Commit:** `refactor(pipeline): own the analysis phase sequence`.

### Task 5: record what it cost

**Commit:** `docs(plans): record the orchestration move`.

## 7. What must not change

- The serialized bytecode of any fixture, at any task.
- The four contract goldens.
- Any diagnostic, or the order diagnostics are printed in.
- `pipeline.zig`'s freedom from IO. If a task needs `file_io` in production pipeline code, the
  task is wrong, not the constraint.
- `zig build wasm`.

## 8. The decision this plan needs

Estimated at four to six working sessions, touching the two largest orchestration files, with
no performance or correctness benefit and one architectural one. Three options:

1. **Do it.** Justified if `LoweredModule` unblocks work you want: a fourth phase makes the
   compile pipeline expressible as data, which is what a build cache or an incremental compile
   would need.
2. **Do Task 1 only.** The bytecode golden is worth having on its own. It pins an artifact the
   product signs and ships, and nothing currently checks it. Cheap, and it de-risks the rest if
   you return to this later.
3. **Decline the clause.** Mark it closed in the reset plan with the measurement and this
   plan's reasoning, so the next reader sees a decision rather than an omission.

My recommendation is 2, then decide. Task 1 is independently valuable, and it converts the
question from "is this refactor safe" into something the gate can answer.
