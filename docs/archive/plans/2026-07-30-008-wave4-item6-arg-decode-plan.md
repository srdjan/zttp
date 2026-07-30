# Wave 4 item 6: comptime argument decoding from `param_types`

Item 6 of `docs/plans/2026-07-28-001-reset-simplification-plan.md` reads: "Add the comptime
argument-decode wrapper for module impl functions, generated from the `param_types` already
declared in each binding."

## What the census found

Measured over the 24 builtin virtual modules (`packages/modules/src/**`, plus the five
engine-coupled workflow modules under `packages/zts/src/modules/workflow/`): 90 export
entries carry an implementation function.

Failure vocabulary on a missing or ill-typed argument is not uniform. Counted across those
files: 47 `orelse return sdk.JSValue.undefined_val`, 15 `false_val`, 12 `sdk.resultErr(...)`
with a per-function message, 6 `util.throwTypeError(...)`, 5 `util.createPlainResultErr(...)`,
and 96 arity guards spread over the same set of outcomes. A single generated prologue cannot
reproduce all of that, and the binding does not declare which outcome a function wants.

So the wrapper cannot be a blanket registration-time transform. Classifying each
implementation by whether its prologue is exactly an arity guard plus one
`extract*(args[i]) orelse return X` per declared parameter, all with the same `X`, and no
later read of `args`:

- 23 of 90 qualify. All 23 declare only `.string` parameters.
- 45 read `args` again later (optional trailing arguments, `isObject` branches, defaults).
- 16 have no mechanical extract prologue at all.
- 6 use one failure value for the arity guard and a different one per argument.

Line arithmetic for the 23: an arity guard plus 1 to 3 extract lines collapses to one decode
line, so roughly 35 lines net. That is not the reason to do this.

## The reason to do it

`param_types` is what the type checker enforces at the call site. The extraction inside the
implementation is what happens at run time. Nothing binds the two, and the census found the
gap in three places, where the implementation reads an argument position that the binding
does not declare:

| Function | `arg_count` | `param_types` | implementation reads |
|---|---|---|---|
| `cacheStats` (`data/cache.zig`) | 1 | `&.{}` | `args[0]` as a string |
| `parallel` (`workflow/io.zig`) | 1 | `&.{}` | `args[0]` as an object |
| `race` (`workflow/io.zig`) | 1 | `&.{}` | `args[0]` as an object |

A handler calling `cacheStats(123)` or `parallel("x")` therefore gets no static diagnostic.
Those are the only three: every other entry declares one parameter type per `arg_count`.

## Plan

1. Add `packages/zttp-sdk/src/args.zig` with a comptime decoder driven by a declared
   parameter list: `Decoded(param_types)` (a tuple type) and
   `decode(param_types, args) ?Decoded(param_types)`, returning null when an argument is
   missing or has the wrong JS type. Implement `.string` only, and `@compileError` on every
   other `ReturnKind` with a message saying to add the kind when a conversion needs it. All
   23 convertible functions are string-only; adding `.number` or `.object` decoding now
   would be code no caller reaches. Re-export as `sdk.decodeArgs` / `sdk.DecodedArgs`.
   -> verify: unit tests in `args.zig` for arity shortfall, wrong type, and success.

2. Convert the 23 qualifying implementations. Each keeps its own failure value at the call
   site, so behavior is unchanged by construction:
   `const a = sdk.decodeArgs(&.{ .string, .string }, args) orelse return sdk.JSValue.false_val;`
   -> verify: `zig build test-modules test-zts`, `bash scripts/test-examples.sh`.

3. Fix the three under-declared entries: `cacheStats` gets `.param_types = &.{.string}` with
   `.required_arg_count = 0` (calling it with no namespace is valid), `parallel` and `race`
   get `.param_types = &.{.object}`. `object` accepts an array at the call site
   (`type_env.isObjectLike` treats `t_array` as object-like), so array-literal callers keep
   type-checking.
   -> verify: examples pass, and `zttp check` on the io and cache examples reports no new
   diagnostics.

4. Add the completeness gate to `validateBindings` in `packages/zts/src/module_binding.zig`:
   `param_types.len` must equal `arg_count`. This is the invariant that makes the declared
   signature executable rather than decorative, and step 3 is what makes it hold.
   -> verify: the gate is a compile error, so a green build is the evidence; add a negative
   test that a deliberately under-declared binding fails, if one can be expressed without
   failing the build.

5. Regenerate the module specs (`zttp module-spec-render`), since `param_types` feeds them.
   -> verify: `./zig-out/bin/zts module-spec-render --check` clean.

Gate: `bash scripts/verify.sh`, plus `zig fmt --check`.

## Outcome, recorded 2026-07-30

All five steps done. Evidence:

- `test-sdk` went from 5 to 10 collected tests, so the new decoder tests do run. They are in
  `test_root.zig`: a `test` block inside any `packages/zttp-sdk/src/*.zig` file is never
  collected, because the SDK is a separate module from its test root. The success path needed
  the shim to grow a string table (`internString`/`resetStrings`); before, its
  `zttpSdkExtractString` reported every value as a non-string, so nothing reading a string
  argument could be tested at all.
- 23 implementations converted across 9 files. Zig 0.16 tuple destructuring keeps the
  multi-parameter form to one line: `const key, const data = sdk.decodeArgs(...) orelse ...`.
- The completeness gate was verified to fire, not just to compile: reverting `cacheStats`
  back to `.param_types = &.{}` produces
  `error: zttp:cache.cacheStats declares arg_count=1 but 0 param_types`. It also caught two
  synthetic bindings in `module_binding.zig`'s own tests, now declared.
- The two previously-silent call sites now report:
  `cacheStats(123)` gives "expected string, got 123" and `parallel("not-an-array")` gives
  "expected object, got \"not-an-array\"". Neither produced any diagnostic before.
- Behavior parity: the only byte that moved in the contract goldens is the three signatures
  gaining their `params` array in `modules.golden.json`. Nothing in the four
  `*.contract.golden.json` fixtures changed, and `bash scripts/test-examples.sh` is 43/43.

One coverage fact found on the way, not fixed here: 11 of the 23 converted functions
(`urlParse`, `urlSearchParams`, `urlEncode`, `urlDecode`, `parseCookies`, `parseContentType`,
`negotiate`, `parseIso`, `rateReset`, `slugify`, `unescapeHtml`) are called from nowhere in
the repository outside their own implementation, so no test executes them in either shape.
The conversions rest on the decoder's unit tests and on the identical check order, not on
behavioral coverage of those functions.

## What this does not do

It does not convert the other 67 implementations, and it does not add an
`on_invalid_args` policy field to `FunctionBinding` to make them convertible. Declaring the
failure value in the binding would move a per-function decision into a table for no
measured benefit: those 67 read arguments in ways a fixed prologue cannot express
(defaults, `isObject` branches, per-argument error messages). Revisit only if the failure
vocabulary is deliberately narrowed first, which is a separate decision about the JS-facing
error surface, not a refactor.
