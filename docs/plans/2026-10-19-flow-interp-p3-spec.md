# Flow redesign: P3 loops

Status: specification for implementation, 2026-10-19. The owner approved P3
(D17 Option A). Parent documents: [the redesign plan](2026-10-18-flow-checker-sound-redesign-plan.md)
and [the P2 specification](2026-10-19-flow-interp-p2-r16-spec.md). P3 extends
`packages/zts/src/flow_interp.zig` (commit `a05a39bd`). It runs in shadow, as
P2 does: no verdict and no policy hash moves.

Codex astra reviewed a first draft twice, once for facts and once for the
argument. This version resolves every finding. Two findings were runtime
defects outside the evaluator, and each has its own commit before P3: the
parser accepted `break` and `continue` in a function nested in a loop, and a
closure that escaped a block read the slot that a later binding reused.

## Facts

- The only loop is `for...of`. The parser refuses `while` and `do`
  (`parser/parse.zig` 1932), `for-in` (3920), C-style `for` (3971), labelled
  `break` and `continue` (4012, 4035), and `break` and `continue` outside a
  loop (4008, 4031). Before the parser commit that precedes P3, `in_loop`
  stayed set inside a function nested in a loop; it is now cleared at each
  function boundary.
- `ForIterStmt` holds `binding`, `iterable`, `body`, `is_const`, and
  `is_for_in` (`parser/ir.zig` 411). The parser declares the loop binding in a
  `.for_loop` scope, so a parsed loop binding is always `.local`
  (`parse.zig` 3885, `scope.zig` 255). Any other kind is a synthetic input.
- Code generation (`emitForIterLoop`, `parser/codegen.zig` 1896) evaluates the
  iterable once and keeps it on the stack. Reassigning the variable that named
  the iterable does not change the iterated value. On each iteration
  `for_of_next` (`interpreter.zig` 1595) or the fused `for_of_next_put_loc`
  (1640) reads the current length and the element at the index from the live
  value. A write to an index not yet visited is seen by a later iteration, and
  `push` lengthens the loop.
- Both opcodes iterate only an array or a range iterator (`interpreter.zig`
  1588, 1633). A string, a `Dict`, or `Bytes` runs zero iterations.
- `break` jumps to the loop end and `continue` jumps to the back edge
  (`codegen.zig` 471, 1941). Neither crosses a function boundary.

## Rules

### `for_of_stmt`

1. Evaluate the iterable once, in the current state: value `it`.
2. Fixpoint over the loop head. `head_0` is the state after step 1. Pass `k`
   (from 0) does this:
   - `body = clone(head_k)`;
   - bind the loop variable in `body` to the element value
     `readValue(head_k, it, .{ .dynamic = Value.clean })`, which is
     `readAll(head_k, it)`. That read keeps the origins and callables of every
     visible cell, so an object element stays an alias of the object in the
     array. It is taken in `head_k`, not in `head_0`, because an earlier
     iteration can write an element a later iteration reads. A write after the
     fetch in the same iteration needs no extra rule: it reaches the next head
     through the body end or a `continue`;
   - the binding update is strong in `env` when the kind is `.local` or
     `.argument`; any other kind records an unresolved entry with owner P8 and
     continues, as `bindDeclared` does;
   - execute the body in `body` with a new loop frame pushed, and pop the frame
     after the body;
   - `head_{k+1} = join(head_k, body after the body, every continue state of
     this pass)`.
3. After each pass, compare `head_{k+1}` with `head_k` by `stateEql`. When they
   are equal, the loop has converged; `head_final = head_k`. The join keeps
   `head_k`, so the chain ascends. It stops because every component is finite
   per program: heap keys are allocation and seed sites (literal and function
   sites use context 0 in P2 and P3), origins and callables are sets over those
   sites and function nodes, cell names are atoms, the label bits are finite,
   and both top flags only move from false to true.
4. The pass cap `max_loop_passes` is a field on `FlowInterp` with default 256.
   It is a fail-closed exit, not the termination argument. The equality check
   runs before the cap check, so convergence on the last permitted pass is
   convergence. When pass `max_loop_passes` ends without convergence, the loop
   records an unresolved entry with the new owner `fixpoint_limit` and uses the
   last computed head as `head_final`. That head can miss a concrete flow; the
   unresolved entry sets `cleared`, and `cleared` makes the whole function
   result non-authoritative under the P2 contract. A cap below 1 is treated
   as 1.
5. The state after the loop is `join(head_final, every break state of every
   pass)`, both when the loop converges and when it reaches the cap.
   `head_final` stands for the paths that leave when the index reaches the
   length, after zero or more iterations. Zero iterations is included because
   every head contains `head_0`. For a non-empty literal array this adds an
   impossible path; that loses precision and keeps the over-approximation.
6. Completions (returns, assert messages, halts) and unresolved entries inside
   the body are recorded on every pass and all are kept. A later pass does not
   always subsume an earlier one, because the conditional join can remove
   `validated`. Duplicate unresolved entries do not change `cleared`.
7. Completions live outside `State`, so their growth does not affect
   `stateEql`.

### `break_stmt` and `continue_stmt`

A loop frame holds two state lists, `breaks` and `continues`. `break` appends
a clone of the current state to the innermost frame's `breaks`; `continue`
appends a clone to `continues`; both then make the current state bottom. A
frame never shares a map with a state that execution later mutates. Frames
nest: a `break` or `continue` acts on the innermost loop only. With no frame,
each records an unresolved entry with owner `refused_by_parser` and makes the
current state bottom. After the parser commit, only a synthetic node reaches
that path.

### State equality

`stateEql(a, b)` holds when all of these hold:

- the same reachability; two unreachable states are equal;
- the same `env` key set, with equal values;
- the same `heap` key set, and for each key the same `named` key set with
  equal values and equal `summary` (bottom equals only bottom);
- the same `top_cell` `named` key set with equal values, and equal
  `top_cell.summary`.

Map comparison uses the counts and keyed lookup, never insertion order. Two
values are equal when every label bit is equal, `origins_top` and
`callables_top` are equal, and the sorted, duplicate-free `origins` and
`callables` slices are equal element by element.

### Parameter values

`analyzeFunction` copies each parameter value's `origins` and `callables` into
the arena, sorted and without duplicates. A caller can then pass a slice from
its own stack, in any order, and `stateEql` and the result stay correct after
the caller returns.

### Census

`tagPlan`: `for_of_stmt`, `break_stmt`, and `continue_stmt` become `handled`.
After P3, only `call`, `spread`, and `array_pattern` stay `later`. `Owner`
gains `fixpoint_limit`. The for-of entry leaves the unresolved corpus and the
existing test that expects a for-of to be unresolved with owner P3; a loop
source with `break` and `continue` joins the resolved corpus.

## Tests

The sources are internal evaluator fixtures run through the existing
`analyzeSource` harness, not fully checked modules: test 2 mutates the array it
iterates, which the strict checker refuses (`mutable_live_iteration`). Unless a
test says otherwise, `s` is seeded with `secret` and every other parameter with
`Value.clean`. "Carries" means the joined return has `secret`; "clean" means it
does not. Each test asserts `cleared == false` unless it expects an unresolved
entry.

1. A loop-carried value needs a second pass.
   `function f(xs, s) { let r = "c"; const out = ["x"]; for (const v of xs) { out[0] = r; r = s; } return out[0]; }`
   carries. Contrast: `r = "d"` instead of `r = s` is clean.
2. A write to a later element of the iterated array.
   `function f(s) { const a = ["x", "y"]; let r = "c"; for (const v of a) { r = v; a[1] = s; } return r; }`
   carries. Contrast: `a[1] = "z"` is clean.
3. Zero iterations. `function f(xs, s) { let r = s; for (const v of xs) { r = "c"; } return r; }`
   carries. Contrast: `let r = "d";` is clean.
4. `break` reaches the exit.
   `function f(xs, s) { let r = "c"; for (const v of xs) { if (v) { r = s; break; } r = "d"; } return r; }`
   carries. Contrast, code after `break` is dead:
   `function f(xs, s) { let r = "c"; for (const v of xs) { break; r = s; } return r; }`
   is clean.
5. `continue` reaches the head.
   `function f(xs, s) { let r = "c"; const o = {}; for (const v of xs) { o.x = r; if (v) { r = s; continue; } } return o.x; }`
   carries. Contrast, `continue` skips the rest of the body:
   `function f(xs, s) { let r = "c"; for (const v of xs) { continue; r = s; } return r; }`
   is clean.
6. A return in the first pass.
   `function f(s) { const a = [s]; for (const v of a) { return v; } return "c"; }`
   carries. Contrast: `const a = ["x"];` is clean.
7. A return in a later pass.
   `function f(s) { let r = "c"; for (const stop of [false, true]) { if (stop) { return r; } r = s; } return "c"; }`
   carries. Contrast: `r = "d"` is clean. A second form returns through an
   assert message: `assert !stop, r;` in place of the `if`, with the assert
   completion carrying `secret` and the contrast clean.
8. A labelled primitive iterable.
   `function f(s) { let r = "c"; for (const ch of s) { r = ch; } return r; }`
   carries. At runtime a string runs zero iterations; this result is a
   conservative over-approximation, kept on purpose. Contrast: seed `s` clean,
   and the result is clean.
9. Nested loops.
   - Inner `break` leaves only the inner loop:
     `function f(xs, s) { let r = "c"; let t = "c"; for (const a of xs) { r = t; for (const b of xs) { t = s; break; } } return r; }`
     carries, because the outer loop runs again after the inner `break`.
     Contrast: `t = "d"` is clean.
   - Inner `continue` stays in the inner loop:
     `function f(xs, s) { let r = "c"; for (const a of xs) { let u = "c"; for (const b of xs) { r = u; u = s; continue; } } return r; }`
     carries through the inner head. Contrast: `u = "d"` is clean.
10. The element keeps its origins.
    `function f(s) { const item = { x: "c" }; for (const v of [item]) { v.x = s; return item.x; } return "c"; }`
    carries. Contrast: `v.x = "d"` is clean.
11. Heap summaries take part in equality.
    `function f(s) { const a = ["c"]; const b = ["c"]; const c = ["c"]; for (const v of ["c", "c", "c"]) { a[0] = b[0]; b[0] = c[0]; c[0] = s; } return a[0]; }`
    carries; it needs three passes and only summaries change on the later
    ones. Contrast: `c[0] = "d"` is clean.
12. Origins converge, not only labels.
    `function f(s) { const p = { x: "c" }; const q = { x: s }; let m = p; let n = p; for (const v of ["c", "c"]) { m = n; n = q; } return m.x; }`
    carries; the labels of `m` stay clean while its origins grow. Contrast:
    `const q = { x: "d" };` is clean.
13. The iterable is evaluated once.
    `function f(s) { let a = ["c"]; let r = "c"; for (const v of a) { r = v; a = [s]; } return r; }`
    is clean, because the loop still reads the first array. Contrast:
    `a[0] = s` in place of `a = [s]` carries.
14. The cap. With `max_loop_passes = 1`, test 1 records owner `fixpoint_limit`
    and `cleared == true`. With the default cap, test 1 records neither.
15. A synthetic `break` outside a frame records owner `refused_by_parser` and
    `cleared == true` (the existing synthetic-probe pattern).
16. Parameter values. Two calls of `analyzeFunction` with the same origins in
    a different order and with a duplicate give equal results, and a result
    stays valid after the caller's origin slice goes out of scope.
17. The P2 tests pass, with the one for-of expectation moved to the resolved
    corpus. The census reports `later` only for `call`, `spread`, and
    `array_pattern`.

## Verification

`zig build test-zts`, `zig build test-proof-swallow`,
`zig fmt --check build.zig build/ packages/`, then `bash scripts/verify.sh`
with a private `ZIG_LOCAL_CACHE_DIR` and `DEEPSEEK_API_KEY` unset.

The reviewer applies each mutation alone and confirms that at least one named
test fails:

| Mutation | Expected failing test |
| --- | --- |
| Drop the body end from the head join | 1 |
| Drop the continue states from the head join | 5 |
| Drop the break states from the exit join | 4 |
| Read the element in `head_0` instead of `head_k` | 2 |
| Start the exit from the first body state instead of the head | 3 |
| Keep only the last pass's completions | 7 |
| Replace the element value with its labels only | 10 |
| Leave `summary` out of `stateEql` | 11 |
| Compare only labels in value equality | 12 |
| Re-evaluate the iterable on each pass | 13 |
| Do not record `fixpoint_limit` at the cap | 14 |
| Let `break` leave every frame instead of the innermost | 9 |

## Not in P3

- Calls, including `push`, stay unresolved until P4. A sound `push` transfer
  adds its argument to the receiver's summary.
- P4 must keep captures from earlier iterations when a strong update rebinds
  the loop variable, join every capture one abstract closure stands for, and
  allocate call contexts from a bounded, reused set. The parent plan's bound on
  contexts stays binding.
- A consumer of `FunctionResult` must treat `cleared` as clearing every flow
  property before it uses a return, heap, completion, or callee summary. P9
  adds the consumer-level regression test.
