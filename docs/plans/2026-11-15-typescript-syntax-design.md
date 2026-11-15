# TypeScript-compatible syntax design

Status: option A accepted as the design direction, 2026-11-15. The source migration is not authorized.

## Authority and scope

This file is the plan authority for this session's repair and design work.
The restrictions enforcement plan remains separate and unchanged by this task.

The user authorized the fallback `assert` repair and one repair agent.
The user requested a design for TypeScript-compatible forms of four extensions.
The user did not authorize the syntax migration.

The design must preserve structural aliases, nominal identity, pattern matching, and invariant assertions.
The target is a restricted TypeScript subset with the current ZTS runtime and proof semantics.
Valid TypeScript grammar does not establish equivalent TypeScript checking or execution.
The proposal must state those evidence limits separately.

## Units

| Unit | Owner | Files | Acceptance | Turn budget |
| --- | --- | --- | --- | --- |
| Reject fallback assertions | `fix_fallback_assert`, Sol with high effort | The repair files listed below | Public regression fails before repair; unfiltered ZTS suites pass in the aggregate gate | 28 tool rounds |
| Design compatible syntax | Main agent | This file; temporary examples outside tracked source | Four mappings, semantic constraints, and TypeScript compiler results | 16 tool rounds |
| Review and commit | Main agent | Only reviewed task files | Required gates pass; isolated local commits preserve unrelated staged work | 24 tool rounds |

## Constraints

Work stays on local `main`. No agent pushes changes.
The repair must report ZTS002 for a fallback assertion.
Plain assertions must retain their current checks and narrowing.
The repair must not change the authoritative restriction rule.
The design must not change the interpreter or proof checker.
Existing diagnostic and evidence contracts remain binding.
D-012 requires the recorded model replay to remain valid before the repair can land.
No paid model recording belongs to this task.

## Current work

The repair agent owns parser changes and affected tests.
The main agent owns the design, independent review, aggregate checks, and commits.
The agent must report before it expands beyond necessary test conversions.

I approved conversions in ten additional Zig files because their tests contain the refused syntax.
The repair's owned paths are:

```text
docs/typescript.md
packages/zts/src/root.zig
packages/zts/src/parser/parse.zig
packages/zts/src/parser/ir.zig
packages/zts/src/parser/ir_children_tests.zig
packages/zts/src/ir_identity.zig
packages/zts/src/handler_verifier.zig
packages/zts/src/path_generator.zig
packages/zts/src/strict_checker.zig
packages/zts/src/flow_interp.zig
packages/zts/src/type_checker.zig
packages/zts/src/contract_builder.zig
packages/zts/src/fault_coverage.zig
```

I also own three dependent fixtures outside ZTS:

```text
packages/pi/src/tools/pi_repair_plan.zig
packages/runtime/src/server_test.zig
examples/handler/feature-probes.ts
```

The first unfiltered `test-zts` run failed the new package-root regression before the parser repair.
The first `test-expert-app` run after the repair failed a planning fixture that still used fallback syntax.
That fixture now uses plain `assert` and retains its original expected plan.
The server fixture now uses an explicit guard and retains its exact 405 response expectation.

The server suite then found a fallback assertion in the feature-probe example.
That example now uses an explicit guard and preserves its response.
The unfiltered server and expert suites passed after these conversions.

My review found that one proposed test conversion removed its only return of a credential.
The repair agent restored that return with an explicit guard. I reviewed the correction.
The agent's named `test-zts` run stopped after two minutes without a complete verdict.
The agent reported that its direct engine run passed 1102 tests and skipped one test.
That run does not establish the complete named suite's result.

I started the canonical gate against the reviewed tree.
The aggregate suite found further fallback syntax in dependency, behavior-diff, narrowing, and security fixtures.
Those fixtures now use plain assertions or explicit returns, with their original behavioral expectations.
The permanent security fixtures retain their identities and refusal expectations.
The scan of packages and examples found no other fallback statements outside the intentional parser regression.

The repair agent also converted `packages/tools/src/precompile_check_tests.zig`.
My review removed duplicate guard fixtures and reused the existing guard cases.
I also converted `packages/tools/src/precompile.zig` and `packages/tools/src/flow_false_proofs.zig`.
No cassette, policy hash, or proof expectation changed.
I stopped the first canonical run after it reported those fixture failures.
I restarted the canonical gate after the final fixture conversions.

The rebuilt CLI accepted plain `assert` with exit zero and no diagnostics.
The rebuilt CLI refused fallback `assert` with exit one and ZTS002 at line 2, column 15.

The corrected aggregate suite, standalone runtime suite, release build, and handler precompilation passed.
The smoke test then found one fallback assertion in its dependency fixture.
I converted that fixture in `scripts/smoke-v1.sh` to plain `assert`, preserving its expected dependency diagnostic.
The scan of scripts and tooling found no other executable fallback statements.
I restarted the complete gate after that fixture correction.

The complete `bash scripts/verify.sh` run then exited zero.
The gate passed the aggregate, standalone runtime, release build, precompilation, smoke, panic-isolation, normalization, installer, semantics, and formatting checks.
The offline expert replay passed, and `zig build check-spine` passed.
These checks establish the behavior of this local macOS checkout.

The proposed surface uses standard declarations, branded types, ordinary calls, and a fluent matching interface.
The compiler will translate the recognized calls into its existing internal representation.
This representation is called IR below.

## Recommended surface

The following module name is proposed. No current `zttp:core` module supplies this interface.
`P` is the object that supplies pattern descriptors.

```ts
import { assert, match, nominal, P } from "zttp:core";
import type { Nominal } from "zttp:core";
```

### Structural aliases

```ts
type Point = { x: number; y: number };
type Box<T> = { value: T };
```

`type` replaces `structural`. The alias remains transparent and has no runtime value.
`export type` and `import type` retain normal TypeScript meaning.
Interfaces, declaration merging, and inheritance remain outside the profile.
The parser records the same alias evidence that it records today.

### Nominal identities

```ts
declare const userIdBrand: unique symbol;
type UserId = Nominal<string, typeof userIdBrand>;

const id: UserId = nominal<UserId>("u1");
```

The symbol declaration identifies the brand. It creates no runtime symbol.
The compiler admits this narrow declaration form only for type identity.
A runtime read of the declared symbol remains invalid.

`Nominal<Base, Identity>` restricts `Base` to `string`, `number`, or `boolean`.
`Identity` must refer to a declared unique symbol.
The trusted TypeScript declaration represents the nominal type as a branded intersection.
Different symbol declarations produce different identities, including across modules with the same local name.
An alias that reuses one symbol refers to the same identity.

The `nominal<T>(value)` call checks the exact base type and returns the unchanged base value.
The call preserves all flow labels and has no capability effect.
A plain base value cannot satisfy a nominal parameter.
The application needs no `as` assertion.

This form costs one extra declaration per identity.
`Nominal<string>` cannot supply a fresh identity to the standard TypeScript checker for each alias.
String tags avoid that declaration, but equal tags can merge unrelated identities across modules.
The unique symbol form avoids that change in meaning.

### Pattern matching

```ts
type Command =
    | { kind: "echo"; text: string }
    | { kind: "ping" };

function run(command: Command): string {
    return match(command)
        .with({ kind: "echo" }, cmd => cmd.text)
        .with({ kind: "ping" }, () => "pong")
        .exhaustive();
}
```

The compiler requires one complete chain in one expression.
The chain cannot escape into a variable, parameter, or dynamic call.
The compiler evaluates the subject once and tests arms in source order.
Only the selected callback body executes.
The callback parameter carries the narrowed subject type.
An omitted callback parameter means that the arm does not use the subject.
The callback parameter replaces arm-scoped field-binding syntax.
The corresponding canonical rules must recognize that binding.

| Current pattern | Proposed form |
| --- | --- |
| Literal | `.with("value", value => result)` |
| Record discriminants | `.with({ kind: "echo" }, cmd => cmd.text)` |
| Nested record or array | `.with({ pair: [0, P.any] }, value => result)` |
| Exact array length | `.with([P.any, P.any], pair => result)` |
| Scalar type test | `.with(P.string, text => text.length)` |
| Other type test | `P.boolean`, `P.number`, `P.array`, `P.Dict`, or `P.Bytes` |
| Field-presence test | `.with({ value: P.present }, record => result)` |
| Field binding or rename | A callback parameter, followed by an explicit member binding when needed |
| Final default | `.otherwise(value => fallback)` |

`P.any` represents an unconstrained position inside an array pattern.
A record pattern omits a field when that field needs no test.
`P.present` checks field presence and permits a present `undefined` value.
The six type descriptors remain valid only at the top level.
The matching interface does not expand the current pattern language.

An exhaustive closed match ends with `.exhaustive()`.
An open domain ends with `.otherwise(...)`.
The current checks for coverage and unreachable arms still apply.
Patterns contain only admitted literal data and recognized descriptors.
Effectful expressions in patterns remain invalid.

The compiler translates the chain into the current match IR.
It does not allocate a builder or invoke general callbacks at runtime.
Lowering must preserve effect order and callback parameter scope.
The TypeScript declarations track the remaining union and each callback's narrowed type.
The declarations need further checks for all current nested patterns and array cases.

### Invariant assertions

```ts
assert(typeof value === "string");
```

The trusted TypeScript declaration is:

```ts
export declare function assert(condition: boolean): asserts condition;
```

The compiler translates the recognized call into the current assertion IR.
The compiler accepts the assertion only as a standalone direct call.
The call keeps forward narrowing, invariant faults, and flow checks.
It accepts exactly one argument. It has no fallback overload.
Expected failures continue to use `if` and `return`.
The application does not declare an assertion signature or implement a throwing function.

## Recognition and trust

The compiler recognizes imported binding identities, not identifier text.
Renamed imports keep their identity. An unrelated function named `assert` gains no compiler authority.
The matching descriptors follow the same rule.
The compiler ships one trusted declaration file for the proposed module.
Recognition follows module resolution and precedes proof analysis.
Application declarations cannot claim an intrinsic identity or add proof facts.

This proposal changes source syntax, not the execution path or proof kernel.
The existing label analysis and obligation checks apply to the translated IR.
Source locations must refer to the original TypeScript calls and patterns.

## Alternatives

Native `switch` and `if` statements use standard grammar and cover ordinary branching.
They do not provide an expression with nested patterns and uniform coverage checks.
Using them for every current match requires helper functions or a wider analysis of control flow.
The matching interface keeps the existing pattern engine and lowering boundary.
It adds recognition of fixed call chains and trusted declarations for pattern types.
The implementation size and TypeScript checking cost need measurement before adoption.

Comments such as `@nominal` would keep declarations short.
The standard TypeScript checker would still treat those aliases as structural.
The symbol brand makes the identity visible to that checker.

## Validation

The installed TypeScript compiler reports version 7.0.2.
The checked prototype files are ignored under `demos/typescript-syntax-study/`.
The prototype supplies declaration files only. It supplies no JavaScript runtime module.

```sh
tsc --strict --noEmit --target es2022 --module nodenext --ignoreConfig demos/typescript-syntax-study/proposed.ts
tsc --strict --noEmit --target es2022 --module nodenext --ignoreConfig demos/typescript-syntax-study/rejected.ts
```

The positive command exited zero.
It checked aliases, nominal construction, a record-union match, and forward assertion narrowing.
The negative command exited one and reported each expected error:

| Case | Result |
| --- | --- |
| Assign `OrderId` to `UserId` | TS2322 |
| Assign a plain string to `UserId` | TS2322 |
| Construct a string identity from a number | TS2345 |
| Omit the `echo` arm before `.exhaustive()` | TS2684 |
| Pass a fallback argument to `assert` | TS2554 |

These checks establish the prototype examples' grammar and static types.
They do not establish runtime interoperability, complete declaration coverage, or current acceptance by ZTS.
The proposal remains unimplemented.

TypeScript defines [unique symbol identity](https://www.typescriptlang.org/docs/handbook/symbols.html#unique-symbol).
TypeScript also defines [assertion signatures](https://www.typescriptlang.org/docs/handbook/release-notes/typescript-3-7.html#assertion-functions).
Its [narrowing reference](https://www.typescriptlang.org/docs/handbook/2/narrowing.html#exhaustiveness-checking) explains exhaustiveness through `never`.

## Migration after approval

The owner must approve changes to the authoritative restrictions and formal source profile first.
The migration must account for diagnostic changes and D-012 before changing model-visible outputs.
The compiler must ship declarations that match its registered module exports.
The compiler must recognize and translate the new forms before examples migrate.
The normalizer must rewrite each old form deterministically and preserve source locations in diagnostics.
Module-aware rewrites must preserve exported type identities and convert nominal constructor calls through resolved bindings.
A rewrite with an unresolved identity must refuse instead of guessing.
Characterization cases must compare output, effects, labels, fault behavior, and proof verdicts across both forms.
The website must describe the development change after those checks pass.
The transition must end with one canonical form for each concept.

## Evidence and decisions

The original probe accepted both plain and fallback assertions with exit status zero.
Before the repair, the parser read the optional fallback expression.
The restriction reference requires ZTS002 for that form.

The owner selected option A for Decision 1 on 2026-11-15.
Option A, accepted: use the declarations and recognized calls in this proposal.
Option B, not selected: use native control flow and give up the direct pattern expression surface.
Acceptance of the design does not by itself authorize a source migration.

## Next action

The repair is committed as `5707ae91` on local `main`.
The canonical gate and TypeScript prototype checks passed within their stated scopes.
I will use option A when preparing the implementation plan.
The plan must preserve the migration constraints stated above.
