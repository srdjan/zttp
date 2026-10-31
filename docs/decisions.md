# Decisions

This ledger records structural decisions and product refusals that still govern the repository.

Read this ledger before you propose a structural change. Add a superseding entry when a decision changes.

## Repository tooling

### D-001 The agent spine uses native Zig tooling

- Status: standing
- Decided: 2026-10-14
- Binds: agents.json, build, tooling, scripts
- Gate: zig build check-spine

The accepted plan selected the native port. This choice keeps repository tooling on the existing Zig build graph.

## Product scope

### D-002 M5 agent handlers stay stopped

- Status: standing
- Decided: 2026-10-11
- Binds: docs/roadmap.md, packages/pi
- Gate: none

The owner accepted decision 3 from plan 005. That decision stopped M5 and removed the agent-handler runtime product.

### D-003 The stdin JSON agent surface stays and RPC mode stays removed

- Status: standing
- Decided: 2026-10-11
- Binds: advisor-plans/005-feature-removal-rebase.md, packages/pi, packages/tools
- Gate: none

The owner accepted decision 7 from plan 005. The external JSON surface retains the deterministic client path without RPC mode.

## Runtime architecture

### D-004 The interpreter is the only execution path

- Status: standing
- Decided: 2026-07-29
- Binds: packages/zts, packages/runtime, docs/internals/architecture.md
- Gate: none

Measurements showed that the tiered JIT did not compile on the request path. Commit `b768385e` removed the remaining tier on this date.

### D-005 The acceptance kernel stays independent and remains a leaf

- Status: standing
- Decided: 2026-08-31
- Binds: packages/proof-checker, packages/runtime, tooling/zts_graph_gate.zig
- Gate: zig build test-proof-checker-purity

The consumer must derive its verdict without producer authority. Commit `f2ecf5f3` added the independent kernel on this date. The leaf check moved from `scripts/check-proof-checker.sh` to the native graph gate (`zts-graph-gate kernel-leaf`, in `tooling/kernel_leaf_gate.zig`) on 2026-10-25, under the same step.

## Analyzer compatibility

### D-006 CHECK retains its separate imported-file traversals

- Status: standing
- Decided: 2026-10-13
- Binds: packages/tools/src/precompile.zig, packages/tools/src/precompile_check_run.zig, packages/tools/src/precompile_imports.zig, packages/zts/src/path_generator.zig
- Gate: zig build test-precompile

The imported flow and fault traversals have different stopping rules. Their reader paths, calls, order, and revision selection remain compatibility inputs.

Owner amendment, 2026-10-20: relative imports without a file extension resolve
to `.ts` using the compiler's pure path-selection rule. This narrowly extends
previously unresolved extensionless imports; already explicit paths remain
unchanged. Resolution uses no filesystem existence probes. The selected path
is read through the caller's revision reader, and flow and fault retain their
separate traversals, read order, repeated reads, and revision selection.

### D-007 Persistent reads carry unknown provenance

- Status: standing
- Decided: 2026-09-08
- Binds: packages/zttp-sdk/src/binding.zig, packages/modules, packages/zts/src/flow_checker.zig, packages/zts/src/flow_interp.zig
- Gate: zig build test-zts

A persistent read returns data from a separate write. Commit `f87f97aa` added the `unknown` binding rule on this date.

## Withdrawn findings

### D-008 Automatic semicolon repair stays withdrawn

- Status: standing
- Decided: 2026-10-10
- Binds: packages/tools/src/canonicalize.zig, docs/solutions/tooling-decisions/withdrawn-semicolon-repair.md
- Gate: none

The former repair mapped stripped positions onto original source. Commit `da7b7ddf` removed the unsafe repair on this date.

## Release process

### D-009 Releases are verified and built locally

- Status: standing
- Decided: 2026-10-18
- Binds: scripts/release.sh, tooling/repo_gate.zig, tooling/release_check.zig, build/step_coverage.zig
- Gate: zig build test-release-workflow

GitHub's macOS runner hit the 30-minute job limit in the v0.22.3 release run. The verifier step ran 29m45s before cancellation.

The owner now verifies, builds, smoke-tests, and publishes each release with `scripts/release.sh` on an Apple Silicon Mac. Linux runs inside Apple's `container` CLI.

Three choices follow from this. First (D9), releases publish no Intel macOS binary (`x86_64-macos-none`). Second (D12), `.github/workflows/ci.yml` and `.github/workflows/release.yml` are deleted, so no workflow builds or tests the repository. Third (D13), `proof-gate.yml` moves to `docs/examples/proof-gate.yml`, because `docs/proofs-and-receipts.md` documents it as a template that users copy. No workflow runs in this repository.

Fourth (D14), the Linux gate runs `scripts/verify.sh --release` in a native arm64 container. The first local run of the gate under Rosetta failed 28 compile steps. Rosetta refuses the `translate-c` helper that Zig 0.16 builds with its x86_64 backend ("bss_size overflow"). Only the Rosetta smoke test of the shipped tarball checks x86_64 Linux. That smoke test cannot catch a crash that occurs only in x86_64 Debug builds, such as the 0.22.2 crash.

## Analyzer structure

### D-010 Tests use the production parse mode

- Status: standing
- Decided: 2026-10-25
- Binds: packages/zts/src/parser/parse.zig, packages/zts/src/typed_frontend_tests.zig
- Gate: zig build test-zts

Typed analyzer tests parse through `JsParser.initAdmission(allocator, type_allocator, source, .compile)`, the mode that every typed source takes in production. Before the 2026-10-25 reset, 199 test sites used a typed mode without admission. That mode proved behavior that no user runs. The reset moved those tests to the production mode, ruled each changed expectation, and deleted `JsParser.initTyped`. A new test does not add a parse mode that production does not use.

### D-011 Each analyzer fact has one producer

- Status: standing
- Decided: 2026-10-25
- Binds: packages/zts/src/pipeline.zig, packages/zts/src/type_syntax_lowering.zig, packages/zts/src/diagnostic_projection.zig, packages/zts/src/contract_types.zig
- Gate: zig build test-contract-golden

The reset removed second copies that could drift. `ModuleAnalysisSession.extractContract` runs the selected flow pass and applies its properties to the contract, so no caller applies flow results in a second step. A standalone type text goes through `type_syntax_lowering.parseTypeText`, the grammar of authored source, and the type pool holds no second parser. The five checkers render diagnostics through `diagnostic_projection.writeAll`. Every list that names a `HandlerProperties` field calls `HandlerProperties.coverageProblem` or `namesCoverageProblem`, so a new property fails the build until each list decides. `zig build test-diagnostic-corpus` holds the diagnostic output.

## Model-visible output

### D-012 Model-visible changes wait for one batched re-record window

- Status: standing
- Decided: 2026-10-25
- Binds: packages/pi/src/prompts, packages/pi/src/simulator/testdata, policy-hash.txt, docs/convergence.json
- Gate: zig build test-expert-app

A change to a prompt, a seed, a tool output, or a wire byte moves the corpus identity and the recorded cassettes. It forces a paid DeepSeek re-record. The reset therefore stays offline: each phase proves that no golden, cassette, pin, or published evidence file moved. A change that would move one is recorded and held for one later re-record window, and no phase regenerates a golden to make a gate pass. This is Decision 2 of the reset plan, option (a), which the owner chose on 2026-10-25.

## Runtime isolation

### D-013 The rate-limit store is the one shared state between requests

- Status: standing
- Decided: 2026-10-26
- Binds: packages/runtime/src/runtime_pool.zig, packages/runtime/src/handler_instance.zig, packages/modules/src/data/ratelimit.zig, AGENTS.md
- Gate: zig build test-server

Each runtime kept its own `zttp:ratelimit` counters, so a pool of N runtimes admitted about N times the configured limit, and each recycle reset the counters. The owner chose Decision 18 option (a) of the release fixes plan on 2026-10-26. Each `HandlerPool` now owns one `RateStore`, and every runtime of that pool uses it. This store is the one permitted exception to request isolation. It holds integer counters keyed by strings and never a JS value. Every access holds its mutex. The pool frees the store after its last runtime. The counters survive live reload and recycle. Two processes do not share them. `zttp:cache` stays per runtime.

### D-014 A literal env name is secret unless the policy lists it in env.public

- Status: standing
- Decided: 2026-10-26
- Binds: packages/zts/src/handler_policy.zig, packages/zts/src/flow_interp.zig, packages/modules/src/platform/env.zig
- Gate: zig build test-zts

The flow analysis gave `env("NAME")` the label `config` when the literal `NAME` held none of eight substrings (SECRET, PASSWORD, PASSWD, KEY, TOKEN, PRIVATE, CREDENTIAL, AUTH). A response that carried `env("DATABASE_URL")` or `env("STRIPE_SK")` then proved `no_secret_leakage`, although the binding declares every env result secret. The owner chose D3(a) of the soundness plan, with D7(a) and D8(a), and Decisions 22(a) and 25(a) on 2026-10-26. The result of `env` from `zttp:env` is `config` only when the policy file lists the exact literal name (case sensitive) in `env.public`. A name that is not a literal keeps the declared `secret` label, and so does every name when no policy is read. `public` is analysis only: it needs `env.allow`, there is no subset rule between the two lists, the runtime policy does not carry it, and a non-empty list is disclosed in the contract `env` object. `public` is the author's claim and the analyzer does not check it. The change moves `flow_analyzer_version` from 7 to 8 and the policy hash, so it waits for the batched re-record window of D-012. The sibling change to `mask` shares the version bump and records its own decision.

### D-015 mask declassifies only an integer literal bound of 4 or less on an unmodified source value

- Status: standing
- Decided: 2026-10-26
- Binds: packages/zttp-sdk/src/binding.zig, packages/modules/src/platform/text.zig, packages/zts/src/flow_interp.zig
- Gate: zig build test-flow-census

The analyzer treated every numeric literal bound of `mask(text, visible)` as declassifying and accepted an omitted bound. `mask(secret, 39)` on a 40-byte secret then proved `no_secret_leakage` although it reveals 39 bytes, and four bounded calls over slices of one secret revealed all of it. The owner chose D4(a) and Decision 24(a) of the soundness plan, with Decisions 22(a) and 25(a), on 2026-10-26. A binding that declares `declassify_bound_arg` also declares `declassify_bound_max`, and `mask` declares `mask_visible_max`, which is 4. The declassification holds only when the bound is an integer literal from 0 to that ceiling and every other argument is an unmodified source value. An omitted bound, a float, a negative number, or a larger number keeps the labels. A value is an unmodified source value when the interpreter marks it `source_exact`: the result of `env` from `zttp:env`, the `authorization` header, or a plain copy of one. A join keeps the mark only when both sides hold it, and every operation that builds a new value drops it. The runtime default of 4 bytes for an omitted bound does not change. The change shares the flow analyzer version 8 of D-014, adds no policy field, and waits for the batched re-record window of D-012.

## Source admission

### D-016 Every source file and every -e source passes admission

- Status: standing
- Decided: 2026-10-30
- Binds: packages/zts/src/modules/internal/module_graph.zig, packages/tools/src/module_graph_record.zig, packages/runtime/src/cli_shared.zig, packages/runtime/src/runtime_cli.zig, packages/zts/src/compiler.zig, packages/runtime/src/handler_instance.zig, packages/zts/src/kernel_identity.zig, packages/zts/src/source_frontend.zig
- Gate: zig build test-precompile

A `.ts` file that admission refused used to run through the untyped parser. The module graph and the module record printed "TypeScript strip failed" and then kept the file. A dependency with a trailing `/* open` answered HTTP 200 under `serve`, and 16 other refused forms reported a second and less exact message. The same fallback kept `-e` source that admission refused. The owner chose Decision 4, option (a), of the reset plan on 2026-10-30. A file and an `-e` source now pass admission, or they fail at start with the admission message. `SourceProfile`, `extractVirtualContract`, `compileWithOptions`, the `.virtual_javascript` arms of the check and compile tools, and the untyped branch of the expert effects tool are deleted. A virtual path such as `<eval>` is the identity of prepared evaluation and is not a file route.

Two entries keep the untyped parser, each for a reason that is not a source file. `JsParser.initExpression` parses one expression for `kernel_identity`. `JsParser.initSourceObserver` is the admission observer itself. A new raw entry needs a superseding entry here.
