# Flow redesign: P4 calls and captures

Status: specification for implementation, 2026-10-19. The owner approved P4
(D18 Option A). Parent documents:
[the redesign plan](2026-10-18-flow-checker-sound-redesign-plan.md),
[the P2 specification](2026-10-19-flow-interp-p2-r16-spec.md), and
[the P3 specification](2026-10-19-flow-interp-p3-spec.md). P4 extends
`packages/zts/src/flow_interp.zig` (commit `9d6e641d`). It runs in shadow: no
verdict and no policy hash moves (R9).

Codex astra reviewed a first draft for facts and for the argument. Both found
the same five defects in it: a failed helper `assert` was treated as ending
the request, the capture scan by name disagreed with the parser, a method call
on a joined receiver could reach a builtin, a second module declaration could
replace a resolved function, and optional calls lost their skip path. A second
round on the revision confirmed those fixes and found five more: a builtin
method read into a variable and called later, a capture seeded on one branch
only, the IR's 13-bit scope for parameters and imports (fixed in its own
commit before P4), labels on a callee value, and a module declaration inside
an `if`. This version resolves every finding.

## Scope

P4 resolves a call whose callee is not a property access: a local or captured
binding, a parameter, a module-level function, a call result, or a join of
those (ternary, match, logical operators). It adds captured bindings,
recursion, and callable sets. These stay unresolved, with the owner named:

- a call whose callee is a `member_access`, `optional_chain`, or
  `computed_access` (owner P5). The runtime can dispatch such a call to a
  builtin method of a string, an array, or another builtin value, and a P2
  value cannot exclude a primitive alternative after a join. P5 owns the
  builtin operation census and refines this rule. Route dispatch through
  `routerMatch` is part of this case;
- a read of a module-level binding that is not a resolved function, and an
  import from another user module (P8);
- call-site spread (new owner `refused_by_strict`): the strict checker refuses
  it (ZTS616), and the runtime does not evaluate the spread operand
  (`codegen.zig` 1144 emits `call_spread`, which pushes `undefined`).

## Facts

- The source parser produces one call tag, `call` (`parse.zig` 5402); the IR
  also defines `method_call`, which the parser does not produce. Code
  generation treats a `member_access` or `optional_chain` callee as a method
  call (`codegen.zig` 1030) and a `computed_access` callee as a regular call
  (1067). `obj?.m(args)` skips the lookup and the arguments when `obj` is
  nullish (1117).
- `this`, `new`, classes, getters, setters, and rest parameters are refused by
  the parser (`parse.zig` 5002, 5034, 5847, 3551). Parameter defaults are
  refused (3654); the evaluator's default join is for synthetic IR only.
- A `function` in expression position is refused (5015). `function_expr` is
  the internal node of a function declaration (3827). An arrow with an
  expression body has a `return_stmt` body (6046).
- A module-level declaration binds `.global` with its atom as the slot
  (`scope.zig` 224); a read parsed before the declaration is
  `.undeclared_global` (327). Both read the same atom-backed global at
  runtime. A second module declaration with the same name appends without
  rejection and its initializer writes the same global. An assignment to a
  module `const` is not refused by the parser, the type checker, or the strict
  checker. Module-level declarations are never captured (282).
- A function declared inside a function binds `.local`; the runtime
  initializes it at its statement (`codegen.zig` 1792).
- A closure reads a captured binding through an `.upvalue` reference: its
  `scope_id` is the closure's function scope and its `slot` is an upvalue
  index. The scope analyzer records, for each function scope, each upvalue's
  `source_scope_id` and `source_slot` (`scope.zig` 31, 355): the exact
  declaring binding. A name-based scan (the old checker's `resolveCaptures`)
  disagrees with it for duplicate declarations in one scope and for an
  unbraced conditional declaration.
- A failed `assert cond, msg` emits `ret` (`codegen.zig` 1987): in a helper it
  returns `msg` to the caller. A failed `assert cond;` returns `undefined` to
  the caller the same way. At the root, the returned value goes through normal
  response conversion.
- Calling a value that is not a function fails with `NotCallable`, which the
  runtime answers with a 500 (`call.zig` 42, `handler_instance.zig` 1280,
  `server.zig` 539). The handler does not continue.
- After `c846beef`, a captured binding's slot is not reused while its frame
  lives.

## Rules

### Calls with an unresolved callee

A call whose callee is a `member_access`, `optional_chain`, or
`computed_access` keeps the P2 behavior (evaluate the callee and the
arguments, return `top`) and records owner P5. A call with a `spread`
argument records `refused_by_strict` and returns `top`. Both clear the result,
so the state after them is not used for a verdict.

### Property reads

The value of a `member_access`, `optional_chain`, or `computed_access` read,
and of a match-pattern field binding, has `callables_top` set. The receiver
can be a string, an array, or another builtin value after a join, and the
read can then return a builtin method: `const g = x.slice; g();` with `x` a
string runs `String.prototype.slice`. A later call of that value records
`unknown_callee`. P5 refines this with the operation census. Elements bound by
a `for...of` keep the P3 rule: iteration reads elements, not methods.

### Callee values

For any other call, evaluate the callee, then the arguments in source order.
With callee value `c`:

1. `c.callables_top`: record `unknown_callee` and return `top`, even when
   `c.callables` also holds known functions.
2. `c.callables` empty: the runtime fails with `NotCallable`. Record owner P5
   and return `top`; P5 decides whether this is a builtin.
3. Otherwise run every function in `c.callables` with the arguments and join
   the values and states. The run order does not matter, because joins
   commute. The call's value then takes `c.labels` by `mergeValues`: a result
   chosen through a labelled callee carries its labels, as a read through a
   labelled key does (R1). Which callee's writes happen depends on that
   choice; that is control flow, which D9 excludes.

### Frames

A call runs the callee body in a new frame. The frame's `env` holds only the
callee's own bindings; `heap` and `top_cell` are the caller's. The callee
reaches caller locals only through capture cells, which are in the heap. On
entry the call saves the loop-frame stack and gives the callee an empty one;
it restores the stack on exit.

The callee's normal completions are every `return`, every failed `assert`
(value: the message, or `clean` without one), and the fallthrough (value
`clean`). The call's value is their join, and the caller's state after the
call is the caller's `env` with `heap` and `top_cell` from the join of their
states. With no reachable completion, the state after the call is bottom.
At the root, completions keep their P2 kinds (`returned`, `assert_message`,
`halt`) in `FunctionResult.completions`.

Parameter `i` is bound to argument `i`, canonicalized as in P3, and joined
with a default value when the IR has one. A missing argument is `clean`.

### Module-level functions

A `.global` or `.undeclared_global` identifier resolves to a function value
when all of these hold:

- exactly one declaration in the program binds `.global` with its atom
  (`function_decl`, any `var_decl`, an import binding, at any depth, inside
  `export_decl` or not, including an unbraced declaration under an `if`);
- that declaration is a `function_decl`, or a `const` whose initializer is an
  `arrow_function`, and it is a direct statement of the program body or the
  declaration of a direct `export_decl`, so module initialization runs it
  before any request;
- no `assignment` in the program targets an identifier of kind `.global` or
  `.undeclared_global` with that atom.

The value is the function's site and callable, as P2 builds for a function
value. Any other `.global` or `.undeclared_global` read stays P8.

### Captures

`FlowInterp` takes an optional capture table built from the parser's
`ScopeAnalyzer`: for each function scope and upvalue slot, the source binding
key `packBindingKey(source_scope_id, source_slot)`. The captured set is every
source key in the table. Without a table, every upvalue read records
`capture_unplaced` and reads `top`. P9 wires the table into the pipeline.

A captured binding lives in one capture cell, shared by every activation of
its function and every loop iteration: the heap site
`SiteKey{ .kind = .capture, .node = <the source key>, .context = 0 }`.
Every write to a captured binding is weak, and no captured binding is written
to `env`: a declaration and its initializer (`let x;` writes `clean`), an
assignment in the owner, an assignment through an upvalue, a parameter
binding, a loop-variable binding, a function declaration, and a match-pattern
binding. Every read, in the owner or through an upvalue, reads the cell.

The write must be weak because one cell stands for several concrete
bindings: two calls of `function mk(v) { const x = v; return () => x; }`
create two closures over two `x`, and a strong write by the second call would
hide the first call's value.

A closure is created inside the activation that declares what it captures,
after the declaration (the parser resolves a name only to an earlier
declaration), so within one root analysis every capture cell a closure reads
was seeded by that activation, and a cell absent on a path stands for the
runtime's `undefined`, which is `clean`. A root is the exception: when the
analyzed function itself has upvalues, nothing seeded them. `analyzeFunction`
then records `capture_unseeded` once and seeds each of those source cells with
`top`. A seeded parameter value whose callables name a nested function is a
test input only; the pipeline does not produce one.

### Recursion

The interpreter keeps the stack of active function activations. A call of a
function `f` that is active is recursive. It uses the innermost active record
of `f`, which holds `entry` (the join of the arguments, `heap`, and `top_cell`
of every call the record stands for) and `summary` (the join of the record's
completion values and states from its last pass; bottom before the first
pass ends).

A recursive call joins its arguments, `heap`, and `top_cell` into the record's
pending entry and returns `summary`: its value, with its `heap` and `top_cell`
joined with the caller's. While `summary` is bottom, the state after the
recursive call is bottom. When a pass of the record ends, it compares the
pending entry with `entry` and the new summary with `summary` by `stateEql`
and `valueEql`. If either changed (losing `validated` is a change), it updates
both and runs the body again from the new `entry`. The record stops when
neither changes. Convergence is checked before the cap.
`max_recursion_passes` (default 64) is the fail-closed cap: reaching it
records `fixpoint_limit`.

Under weak heap writes, a completion state contains the heap the activation
started from, so joining the summary state with the caller's state
over-approximates the heap after the call. Mutual recursion converges through
nested reruns: an inner record uses its ancestors' current summaries, and an
ancestor that grows traverses the cycle again.

### Budget

`max_steps` counts `eval` and `exec` visits for one root, across every call
and pass. Exhaustion records `budget_limit` and returns
`error.BudgetExhausted` up to `analyzeFunction`, which returns a cleared
result; no partial summary or completion is kept as normal. The counter is
reset by `analyzeFunction`. The default is set from the measurement under
Verification.

### Census

`call` becomes `handled`. `spread` gets the new plan `refused_by_strict`.
`.upvalue` reads resolve. `Phase.p4` is removed if nothing else names it.
`Owner` gains `unknown_callee`, `capture_unplaced`, `capture_unseeded`,
`budget_limit`, and `refused_by_strict`. The P2 owner P4 for a local function
read before its declaration becomes `read_before_declaration`. After P4 only
`array_pattern` is `later`. The obsolete P4 owner assertions in the P2 tests
move to their new owners.

## Tests

Internal evaluator fixtures through `analyzeSource`, with the capture table
built from the harness parser. `s` is seeded `secret` and other parameters
`clean`, unless stated. Each test has a clean contrast (the secret replaced by
a literal) and asserts `cleared == false` unless it expects an unresolved
entry. Conditions use booleans. "Carries" means the joined return has
`secret`.

1. A local call: `function f(s) { function id(x) { return x; } return id(s); }` carries.
2. A later return: `function f(c, s) { function g(c) { if (c) { return "c"; } return s; } return g(c); }` carries.
3. A callee writes the caller's object: `function f(s) { const o = { x: "c" }; function w(t) { t.x = s; return 0; } w(o); return o.x; }` carries.
4. A callee that never returns: `function f(s) { function spin() { return spin(); } spin(); return s; }` has no returned value and an unreachable exit.
5. A helper assert returns its message: `function f(c, s) { function g() { assert c, s; return "c"; } return g(); }` carries; `g(); return "ok";` is clean.
6. A callable set in both node orders: `const a = () => "c"; const b = () => s;` and, separately, `const b = () => s; const a = () => "c";`, each with `return (c ? a : b)();`, carry.
7. A capture written after the closure: `function f(s) { let r = "c"; const g = () => r; r = s; return g(); }` carries.
8. A closure writes the owner's binding: `function f(s) { let r = "c"; const w = () => { r = s; return 1; }; w(); return r; }` carries.
9. Two activations of a captured `const`: `function f(s) { function mk(v) { const x = v; return () => x; } const a = mk(s); const b = mk("c"); return a(); }` carries.
10. Two activations of a captured parameter: `function f(s) { function mk(v) { return () => v; } const a = mk(s); mk("c"); return a(); }` carries.
11. A captured match binding: `function f(s) { return match ({ text: s }) { when { text }: (() => text)() default: "c" }; }` carries.
12. A captured loop variable read in a later activation's loop: `function f(s) { let first = () => "c"; let seen = "c"; function mk(xs) { let last = () => "c"; for (const v of xs) { seen = first(); last = () => v; } return last; } first = mk([s]); mk(["c"]); return seen; }` carries.
13. Exact capture identity: `function f(s) { let x = s; let x = "c"; return (() => x)(); }` carries (the parser binds the first declaration), and an unbraced conditional declaration follows the parser's binding with its source and expectation written in the test.
14. Module-level functions: `function help(x) { return x; } function f(s) { return help(s); }` carries; with `f` first (a forward `.undeclared_global` read) it carries; a second declaration `let help = (x) => "c";` records P8; an assignment `help = (x) => "c";` inside another function records P8; an unbraced `if (false) function help(x) { return "c"; }` as the only declaration records P8.
15. Recursion through the entry: `function f(s) { function r(n, acc) { if (n) { return acc; } return r(true, s); } return r(false, "c"); }` carries.
16. Recursion through the summary heap, three forms: with `p` seeded `origins_top`, `function r(p, n, x, y) { if (n) { p.out = x; return 0; } r(p, true, y, y); return p.out; }` called as `r(p, false, "c", s)`; the same with `p` a local object literal; and the same with `out` a captured `let` instead of a field. Each carries.
17. A capture written in one recursive pass and read in a later one: `function f(s) { let r = "c"; function rec(n) { const out = r; if (n) { return out; } r = s; return rec(true); } return rec(false); }` carries.
18. Mutual recursion through a captured binding: `function f(s) { let b; function a(n, x) { if (n) { return x; } return b(true, s); } b = (n, x) => a(n, x); return a(false, "c"); }` carries.
19. Recursion through a callable set: `function f(c, s) { let g = (n, x) => "c"; function a(n, x) { if (n) { return x; } return g(true, s); } g = c ? a : g; return g(false, "c"); }` carries.
20. Recursion inside a loop with `break` and `continue` after it: `function f(s) { function r(n, x) { if (n) { return x; } return r(true, s); } let out = "c"; for (const v of [false, true]) { out = r(false, "c"); if (v) { break; } continue; } return out; }` carries.
21. A labelled callee: `function f(s) { const a = () => "c"; const g = s || a; return g(); }` carries through the callee's labels.
22. A known callable joined with an unknown one: `function f(c, g) { const h = c ? (() => "c") : g; return h(); }` with `g = Value.top` records `unknown_callee`.
23. Method calls are P5: `function f(s) { const a = [() => "c"]; return a.map(() => s)[0]; }` and `function f(s) { const o = { m: () => "c" }; return o.m(); }` record P5.
24. An extracted method is `unknown_callee`: `function f(c, s) { const x = c ? { slice: () => "c" } : s; const g = x.slice; return g(); }` records `unknown_callee`.
25. An empty callable set is P5: `function f(x) { return x(1); }` with `x` clean.
26. Call-site spread records `refused_by_strict`.
27. A nested root: analyzing `inner` in `function outer(s) { function inner(c) { if (c) { s = "c"; } return s; } return inner; }` records `capture_unseeded` and is cleared.
28. The budget: the measured count of a source with nested calls in a loop; with `max_steps` one below it the root records `budget_limit` and is cleared; on the same interpreter with the same limit, a smaller root that calls the same callee then succeeds and carries its exact expected result.
29. The recursion cap: with `max_recursion_passes = 1`, test 15 records `fixpoint_limit`; with its measured pass count it converges.
30. The P2 and P3 tests pass with their P4 owners moved; the census reports `later` only for `array_pattern`.

## Verification

`zig build test-zts`, `zig build test-proof-swallow`, `zig fmt --check`, and
`bash scripts/verify.sh` with a private cache and `DEEPSEEK_API_KEY` unset.
The implementer reports the largest visit count over the tests and the census
corpus, sets the `max_steps` default to at least ten times it, and reports both
numbers.

Each mutation alone must fail a named test:

| Mutation | Test |
| --- | --- |
| Join only the first return | 2 |
| Keep the caller's heap after the call | 3 |
| Treat a helper assert as a root completion | 5 |
| Call only the first callable | 6 |
| Read a capture cell as `clean` | 7 |
| Keep a captured binding in `env` | 8 |
| Write a capture cell strongly | 9, 10, 12 |
| Write a match binding to `env` | 11 |
| Place captures by name | 13 |
| Resolve a module function despite a second declaration | 14 |
| Resolve a module function declared under an `if` | 14 |
| Do not join recursive arguments into the entry | 15 |
| Replace the entry with the pending input instead of joining | 15 or 17 |
| Return the caller's heap and top cell from a recursive call | 16 |
| Do not join the recursive call's heap into the pending entry | 17 |
| Drop the callee's labels from the call value | 21 |
| Ignore `callables_top` when known callables exist | 22 |
| Resolve a method call | 23 |
| Leave `callables_top` off a property read | 24 |
| Skip the root `capture_unseeded` seeding | 27 |
| Do not reset the step counter | 28 |
