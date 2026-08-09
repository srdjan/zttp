# Restrictions to Proofs

Generated from `packages/zts/src/restriction_registry.zig`, the machine-readable
form of the spec's restriction matrix. Each row pairs a refused construct with
the boundary the refusal protects. `zttp restrictions` prints the frozen
version-1 rows; the version-2 `restrictions` operation returns all 34.

Every entry is a deliberate cut from JavaScript or TypeScript. The rows that
predate the version-1 freeze name the failure class the cut removes and the
proof it buys. Later rows carry the boundary and the nature of the decision
instead: `essential` when nothing known keeps both the proof and the construct,
`replaced` when another construct does the job with the proof intact, and
`canonical_simplicity`, `language_simplicity`, and `provisional` for choices
that are not theorems.

The author-declared intent assertions (extracted with `-Dcontract`) and the
contract diff (`zttp proofs show`) sit above these cuts; the cuts are what make
those higher-level claims possible.

The proof card's `Trade` lens in `zttp dev` (press `Tab` to rotate) and the
matching tab in Studio render a per-property view of this table against the
current handler, so you can see which restrictions earned each `[+]` chip.

## Restrictions With A Named Proof

| Restriction | Failure class prevented | Proof unlocked | Alternative |
|-------------|-------------------------|----------------|-------------|
| `switch/case` | non-exhaustive control flow and implicit fallthrough | match coverage and exhaustive return analysis | use 'match' expression |
| `var` | scope hoisting and temporal dead zones | block-scoped data flow and reachability analysis | use 'let' or 'const' |
| `class` | implicit mutable receivers and hidden state | explicit data flow and effect analysis | use plain objects and functions |
| `while` | unbounded back-edges and non-termination | finite path enumeration and termination | use 'for...of' with a finite collection |
| `do...while` | unbounded back-edges and non-termination | finite path enumeration and termination | use 'for...of' with a finite collection |
| `for(;;)` | unbounded back-edges and non-termination | finite path enumeration and termination | use 'for (const i of range(n))' |
| `for...in` | prototype-chain iteration and non-deterministic order | deterministic iteration and shape-stable access | use 'for (const k of Object.keys(obj))' |
| `try/catch` | hidden exceptional control flow | Result narrowing and exhaustive path enumeration | use Result types and check .ok |
| `throw` | hidden exceptional control flow | Result narrowing and exhaustive return analysis | return an error Response |
| `async/await` | ambient scheduling and non-deterministic interleavings | deterministic effect boundary and replayable I/O | use fetch() from zttp:fetch, or parallel()/race() from zttp:io |
| `new` | constructor dispatch and hidden initialization effects | explicit factory call sites and visible effects | use factory functions or object literals |
| `this` | dynamic receiver binding | static call-graph and visible data flow | use explicit parameter passing |
| `== / !=` | implicit coercion paths | sound type-directed comparison | use === / !== |
| `++ / --` | hidden in-place mutation in expressions | explicit assignment effects and state isolation | use x = x + 1 |
| `regex` | opaque accept set and catastrophic backtracking | shape-checkable validation via zttp:validate schemas | use string methods (includes, startsWith, etc.) |
| `delete` | hidden-class shape mutation | shape-stable property access | build a new object literal with only the keys you keep |
| `enum` | dual numeric/string lookup and non-exhaustive cases | exhaustive match coverage on discriminated unions | use object literals or discriminated unions |
| `decorator (@)` | implicit metaprogramming and target rewriting | static call-graph and visible effect composition | use function composition |
| `namespace` | module-graph blind spots | AST-driven contract extraction | use ES6 modules |

## Further Refused Forms

These rows entered the matrix after the version-1 output froze, so they reach
clients through the version-2 `restrictions` operation rather than through
`zttp restrictions`.

| Restriction | Boundary protected | Nature | Enforced by |
|-------------|--------------------|--------|-------------|
| eval, dynamic import, reflection, Proxy | closed program and semantics coverage | `essential` | `ZTS001`, `ZTS002` |
| mutable live iteration | loop finiteness and stable cost | `replaced` | `ZTS622` |
| unchecked recursive cycle | totality and bounded cost | `essential` | no diagnostic |
| native module with unbound contract | effect and authority integrity | `essential` | no diagnostic |
| `any`, type assertions (`as` and angle-bracket forms), `satisfies` | type evidence integrity | `essential` | `ZTS041`, `ZTS042`, `ZTS043` |
| effectful `?:` | visible evaluation and one mutation spelling | `provisional` | `ZTS612` |
| compound assignment | visible evaluation and one mutation spelling | `provisional` | `ZTS613` |
| rest parameters | visible evaluation and one mutation spelling | `provisional` | `ZTS001` |
| chained conditional arms | one form per branch shape | `canonical_simplicity` | `ZTS621` |
| numeric record keys | one keyed-collection model | `canonical_simplicity` | `ZTS001` |
| multiple record spreads | fixed-shape elaboration without field-presence tests | `canonical_simplicity` | `ZTS614` |
| fallback `assert` | one explicit early-return spelling | `canonical_simplicity` | `ZTS002` |
| interface | one closed data and module model | `language_simplicity` | no diagnostic |
| object methods, getters, setters | explicit functions and effects | `language_simplicity` | `ZTS001` |

## Rows No Diagnostic Rejects

Three rows sit in the matrix with no rule code behind them. Each says why:

- **unchecked recursive cycle** - not a rejection by design: recursion runs, and phase 0 downgrades the totality and cost claims instead (spec_discharge refuses the capsule, path_generator reports the coverage cause).
- **native module with unbound contract** - enforced outside the rule registry, by module manifest authentication and `zts verify-modules`, which emit no registry rule code.
- **interface** - still admitted: `interface` parses and type-checks today, and its removal is blocked on the migration policy the D workstream owes.

## Why

Per-restriction rationale, one sentence each.

- **switch/case** - fallthrough makes coverage ambiguous and lets cases share state through implicit fallthrough.
- **var** - hoisting and function-scoping create temporal dead zones the verifier cannot reason about.
- **class** - implicit mutable receivers hide data flow from the contract extractor.
- **while** - unbounded back-edges defeat finite path enumeration.
- **do...while** - unbounded back-edges defeat finite path enumeration.
- **for(;;)** - C-style loops carry no bound; gen-tests cannot enumerate every iteration.
- **for...in** - for...in walks the prototype chain; iteration order is implementation-defined.
- **try/catch** - exceptions are an invisible second return channel that bypasses the type system.
- **throw** - throw is the producer side of the hidden exception channel.
- **async/await** - ambient scheduling produces interleavings the replay log cannot reproduce.
- **new** - constructor dispatch combined with prototypes hides effects from the IR.
- **this** - the binding of `this` is dynamic and unreadable from the IR.
- **loose equality and implicit coercion** - loose equality coerces operands, creating control-flow paths the type checker cannot see.
- **++ / --** - in-place mutation hides write effects in expression positions.
- **regex literal or ambient RegExp** - regex literals describe an opaque accept set the validator cannot reason about.
- **delete** - delete mutates hidden-class shape, defeating shape-stable property access.
- **enum** - TS enums emit dual numeric/string lookups that bypass exhaustive match checking.
- **decorator** - decorators rewrite their target at runtime in ways the contract extractor cannot trace.
- **namespace** - TS namespaces compile to closures with mutable internals invisible to the module graph.
- **eval, dynamic import, reflection, Proxy** - essential until a closed dynamic-code model exists
- **mutable live iteration** - replaced by snapshot iteration
- **unchecked recursive cycle** - recursion runs, but these claims require evidence
- **native module with unbound contract** - essential
- **`any`, type assertions (`as` and angle-bracket forms), `satisfies`** - essential to the selected checker model
- **effectful `?:`** - language-simplicity choice, provisional pending the 14.2 paired-task measurement
- **compound assignment** - language-simplicity choice, provisional pending the 14.2 paired-task measurement
- **rest parameters** - language-simplicity choice, provisional pending the 14.2 paired-task measurement
- **chained conditional arms** - exact repair when constructible, else proposed refactor
- **numeric record keys** - canonical simplicity; use a string key, or an array when the keys are dense indices
- **multiple record spreads** - canonical simplicity; write explicit fields over one base
- **fallback `assert`** - use `if` plus `return`
- **interface** - language-simplicity choice
- **object methods, getters, setters** - language-simplicity choice
