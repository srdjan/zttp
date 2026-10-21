# ZTTP completeness audit - merged findings (HEAD 791d73d5, v0.23.0, 2026-10-21)

Sources: four research agents (runtime, zts, modules+proof-checker, pi+docs) plus a baseline `zig build test`.
Probe files: scratchpad/runtime/, scratchpad/zts/ (run.sh), scratchpad/modules/, scratchpad/pc/probe.zig + probe.out.
Labels: P = observed by probe, C = observed in code, Inf = inferred.

## A. INCORRECT - security / soundness (false PROVEN, false accept)

S1. Computed SQL statement accepted, `injection_safe PROVEN`. `sql("q", req.headers.get("x-q") ?? "...")` then `sqlMany("q")`; serve ran attacker `SELECT k FROM secrets`. sql.zig:216-230 stores any string; ZTS602 only checks the name. Contradicts threat-model.md:93, contracts-and-sandboxing.md:270. Probe modules/p10_sql_header_run.ts, p07. P.
S2. env() secret label only for names containing SECRET|PASSWORD|PASSWD|KEY|TOKEN|PRIVATE|CREDENTIAL|AUTH (flow_interp.zig:3460-3472). `env("DB_PASS")`, DATABASE_URL, STRIPE_SK, SESSION_SALT returned verbatim prove no_secret_leakage. Binding declares .secret (env.zig:23). Probes modules/p01-p03, zts/flow/e.ts. P (two agents independently).
S3. mask() declassifies under any literal bound and composes: mask(s,63) and 4 chained mask(slice,4) prove no_secret_leakage (text.zig:28, flow_interp.zig:3478-3485). modules/p04,p05,p06. P.
S4. Request-controlled schema `schemaCompile("body", req.headers.get("x-schema"))` proves input_validated. modules/p13,p14. P.
S5. Implicit-flow secret leak (char-by-char compare) under no_secret_leakage PROVEN; deliberate per decision D9 but undisclosed in proofs-and-receipts.md / verification.md, which the plan (flow redesign plan :319-321) requires. zts/flow/f20.ts. P.
S6. Proof-checker: omitting translation evidence raises response_total grade trusted->proved (checker.zig:944). pc P1,P3. P.
S7. Proof-checker never relates IR to bytecode; witnesses at offset 0xF0000000 accepted; one bytecode digest with two IRs accepted. Contradicts verification.md/threat-model.md. pc P3,P4. P.
S8. Trusted node declaration makes any node total; non-returning handler accepted (checker.zig:648,664; policy floor policy.zig:117). pc P2. P.
S9. `zttp proofs verify` ignores bundle certificate/contract components (bundle.zig verifySemantics): garbage cert accepted exit 0. pc b1,b2. P.
S10. `proofs verify` passes policy_section_digest not policy_section (bundle.zig:375): every guarded artifact falsely rejected `runtime_policy_missing`. P. One-line fix.
S11. Per-export capability ceilings not enforced at call time; module-level set pushed (module_binding_adapter.zig:25,58,142). C.
S12. Indexed read typed T not T|undefined; `ps[0].age` on empty array proves optional_safe, 500 at runtime. zts/t3.ts, t1.ts. P.
S13. `parseJson("1").error.kind` proves result_safe; runtime returns `{}` (no trap). zts/t2.ts. P.
S14. fetch result proves `deterministic` (readsVaryingSource ignores .external, flow_interp.zig:3433-3440). modules/p17. P.
S15. fetchWithRetry resends authenticated POST (Authorization header) 4x; guard only checks a `credential` key FetchOptions cannot have (fetch.zig:164-171). P.
S16. jwtSign/jwtVerify accept empty secret. modules/s07. P.
S17. `workspace_search_text` (pi tool) returns lines of gitignored .env when the path is explicit; workspace_read_file refuses them; with DeepSeek they leave the machine (workspace_search_text.zig:109-147). Replicated rg argv, tool not driven end to end. P (partial).
S18. Human `zttp check` text output hides ZTS400 (shown by --json); ZTS500 help suggests dropping no_secret_leakage. examples/handler/secret-leak.ts. P.

## B. INCORRECT - runtime / HTTP

H1. Bare LF in header value hides Content-Length -> body executed as second request (request smuggling). http_parser.zig:368-401, server.zig:2086,2153. `/smuggled` logged 200. P.
H2. JS recursion ~250 frames aborts the whole Debug server process (Bus error); ZTS_CALL_GUARD defaults 0 (trace.zig:31, call.zig:28); MAX_STATE_DEPTH 1024 too high. zts/p19.ts. P (Debug only; Release threshold unmeasured).
H3. Idle sockets starve the cpu*2 blocking worker pool; /_health timed out with 28 idle sockets; first request has 30 s read timeout (server.zig:281-296,1935). P.
H4. Shutdown waits timeout_ms per idle connection (29 s observed); responses during drain still keep-alive. Contradicts reliability.md:118. P.
H5. /_readiness can never return 503 (pool in-use bounded by worker count). Inf.
H6. GET /static/<dir> sends 200 header then a 500 response as body and keeps connection alive (server_static.zig:46-58, server.zig:914,459). P.
H7. Malformed framing (bad chunk size, CL+TE, CL: abc) closes socket with no response; 32 KiB header cap inexact (server.zig:376-391,665). P.
H8. HTTP/1.1 non-conformance: bad version, no Host, obs-fold dropped, colon-less line, NUL in value, TE on HTTP/1.0 all 200. P.
H9. Expect: 100-continue unsupported (1 s curl stall). P.
H10. Response.json/text/html silently drop `headers` from init (zts/src/http.zig:253-328); no way to set Set-Cookie/CORS/Cache-Control. P.
H11. `zttp dev` spawns serve child with empty environment (dev_command.zig:66-75): env() differs dev vs serve. P.
H12. SIGTERM to `zttp dev` orphans the child, which keeps the port. P.
H13. serve/dev from a project subdirectory -> FileNotFound (runtime_cli.zig:535-545 no resolvePath); dev preflight passes first. P.
H14. -h localhost / -h ::1 crash with InvalidCharacter after pool warm (server.zig:1926 parseIp4). P.
H15. 100th keep-alive response advertises keep-alive then closes; `Connection: keep-alive, foo` -> close. C/P.
H16. Out-of-range handler status silently becomes 500 with handler body. P.
H17. Cache and rate-limit stores are per runtime slot: rateCheck("k",5,60) admitted 15/40 with -n 4; cacheIncr returned 1 to 3 requests. Undocumented. P.
H18. Concurrent SQLite writes fail immediately (no busy_timeout/WAL; sqlite.zig:17-121): 22/80 failed with -n 4. P (cause probable SQLITE_BUSY).
H19. sqlExec reports stale lastInsertRowId for UPDATE. P.
H20. Result value inside Response.json serializes as `{}`. P.

## C. INCORRECT - language/interpreter semantics

L1. Float elements lost in join/toSorted: [0.5,1.25,3].join(",") -> ",,3" (helpers.zig:98-113). Breaks the official ZTS105 repair. P.
L2. String(1.5e300), Number.MAX_VALUE, 5e-324 -> "NaN" (string.zig:1286-1311, 64-byte buffer); no exponent form. P.
L3. .length returns UTF-8 bytes while indexing uses UTF-16 (cmp.zig:117-131 bypasses stringLength). "aé€".length=6. P.
L4. Type checker accepts unknown members on string/array/number (type_checker.zig:2512-2548): xs.lenght, s.toUppercase(), n.toFixed -> runtime 500. P.
L5. for...of over string/Dict type-checks and runs zero iterations (interpreter.zig:1567-1655); spec:1114 admits them. P.
L6. match type-test arms and ?: branches do not narrow, contrary to spec:1046-1067, 898-907. P.
L7. Response.json writes NaN/Infinity as null; spec requires rejection. P.
L8. -0 lost on integer fast path. P.
L9. (-3)**2 refused by the repair its own message suggests (parse.zig:5092). P.
L10. ZTS604 false positive for let reassigned in an arrow. P.
L11. Runtime 500 body says "not proven optional_safe" when check proved it, and leaks source coords to client. P.
L12. `zts check` prints "Types OK" after Parse FAIL. P.
L13. fault_covered false with zero failable sites -> every I/O-free handler without capsule fails ZTS500 (proof_trace.zig:515). P.
L14. Typed Dict<K,V> unusable with annotations (collections.zig:40-49 bindings untyped). P.

## D. INCORRECT - repo / docs / release

R1. VERSION=0.23.0, six copies 0.22.4 (build.zig.zon:3, packages/zts|runtime build.zig.zon, zts/src/root.zig:934, README.md:6, install.sh:6). `zig build test` FAILS at HEAD: 9041/9048 pass, 1 fail (release_check.zig:811). Observed by main session (aggregate run).
R2. HEAD 791d73d5 is on origin/main; worklog says "Nothing has been pushed". P.
R3. No CI (.github has no workflows) but CLAUDE.md says verify.sh mirrors CI. P.
R4. CHANGELOG lacks 0.22.4 and 0.23.0. C.
R5. release-provenance fails (251 stale paths); evidence last published 2026-10-20. P.
R6. examples/README.md: three false claims (Date.now in spec-guardrails, ZTS400 in secret-leak, `zttp test` command fails). Seven examples ungated. P.
R7. Plan index/roadmap stale statuses; 10 of 37 plans unindexed; convergence/coverage prose stale (removed veto.zig, 14/20 cases). C.
R8. help text mismatches (ledger stats, expert --gate-log, `help <cmd>` prints banner, "serverless JavaScript runtime" though .js refused). P.
R9. Zttp-Proofs header lists 14 compiler claims vs 9 accepted at startup (server.zig:1904). P/Inf.
R10. pre-rebase / pre-round-2-archive tags exist only locally; 191 references (23 in code) unreachable for a clone. P.
R11. Governing text cites removed modules (queue, durable, websocket). C.
R12. derives_from_args has no reader in analysis though AGENTS.md calls it load-bearing (safe: more conservative). C.
R13. Deploy exited 0 for artifact the binary then refused to serve (required_property_not_established). P, cause probable.

## E. INCOMPLETE

N1. Deployed binary hardcodes port 3000, ignores static dir, SQLite path, outbound, limits; rejects --static/--max-body-size (runtime_cli.zig:754-820). P.
N2. Live reload: 250 ms polling, swallows errors, watcher thread can die silently, does not watch entry outside src/, swap installs code before contract. C.
N3. Operator limits (timeouts, header caps, worker count) are compile-time constants. C.
N4. Proof response cache probably unreachable under production policy (dead in practice). Inf.
N5. Request timeout cooperative only; native calls not interrupted; returns 504. Inf.
N6. Static serving minimal: no percent-decoding, Range, Last-Modified, index.html; StaticFileCache is ~210 lines of dead code. P/C.
N7. Validation: no additionalProperties/oneOf/$ref etc.; undeclared fields pass. P.
N8. SQL: no transactions, batch, BLOB; computed SQL guards deferred. C.
N9. fetch: no per-call timeout, string bodies, no streaming; fetchWithRetry sleep may exceed deadline by 30 s. C.
N10. JWT HS256 only; no aud/iss/leeway; webhook signature without timestamp window. C.
N11. Seven certificate properties disclosed, not checked; tested floor does nothing in the kernel; proof-review shows no grade. C.
N12. Hardening H6 and flow plans not closed; bench-check fails (intArithmetic -10 to -15% vs 0.22.2 baseline, per worklog). C.
N13. Narrow stdlib: no toFixed, Math.log10/atan2, Array.flat/at, String.at/codePointAt, normalize, full Unicode case mapping. P/C.
N14. Observability: no request-ID generation, no structured logs, no /metrics; parse failures never logged. C.
N15. expert loop: no retry/backoff on 429/5xx; no cost accounting in --print/JSON; only DeepSeek + MLX (MLX likely Apple-only). C.

## F. MISSING

M1. TLS (documented: use reverse proxy). M2. Custom response headers (H10). M3. IPv6/hostname bind. M4. Non-blocking connection handling. M5. Compression, Range, HTTP/2. M6. Password hashing/KDF, AEAD, asymmetric signature verify, random bytes, SHA-512. M7. Signed sessions, CSRF. M8. Process-wide cache/rate store. M9. Date/time-zone math. M10. LSP/editor integration. M11. CI. M12. Intel macOS/Windows/package-manager distribution. M13. Unknown zttp.json key validation.

## G. REPLACE (proposed)

P1. Thread-per-connection blocking pool -> readiness-based I/O for socket phase; short first-byte deadline as first step.
P2. Two hand-rolled header splitters -> one strict tokenizer shared by framing and parsing; map every framing error to 4xx.
P3. env name denylist -> all env secret by default + policy list of public names.
P4. sql()/schemaCompile() runtime registration -> compile-time-only literal registration, statement hash pinned in contract.
P5. Per-slot stores -> process-wide store (or document scope).
P6. Proof-checker: take bytecode as input and rebuild IR/call sites; compute grade from what the kernel ran; canonical decode-reencode equality.
P7. dev child re-exec with empty env -> in-process serve or inherit env + forward signals.
P8. One ECMAScript Number::toString formatter used by String/join/sort/JSON.
P9. Type checker member table built from builtin registrations.
P10. Hand-maintained 7 version strings -> generated from VERSION.
P11. Plan/status sprawl in 4 places -> single status source; push or index archive tags.
P12. Deploy config by flag subset -> embedded runtime-settings section.
P13. Proof-cache 64-bit hash key -> stored full key compare (or remove cache).

## H. Fable validation (re-ran probes from scratchpad/val/)

Confirmed by re-run: S1 S2 S3(chained form leaks 16/17 bytes; mask(s,63) is a false proof without live leak) S4(static) S6 S9 S10 S12 S13 S14 S16 S18; H1 H2(Debug) H3 H6 H7 H8 H10 H11 H12 H13 H14 H16 H17 H18 H20; L1-L5 L7-L14; R1 R2 R4 R5 R9 R10 R11 R12 R13.
Refuted: L6 for match arms (type-test arm narrows; ?: half untested).
Misclassified: S7 partly (undecoded witness bytes are a disclosed trusted edge; the overclaim in threat-model.md:58-61 stands). S8 mechanism is by design; disclosure gap stands. H5 holds only at default sizing. R3 CI removal is decision D-009; only the CLAUDE.md sentence is stale. R6 ZTS400 claim is true but hidden by S18. M1 TLS, M11 CI, M12 Intel/Windows are documented non-goals.
Narrowed: H4 idle keep-alive shutdown 4 s; 29 s only for a connection that sent no bytes.
P6 half conflicts with D-005 (kernel stays a leaf): keep "grade from what the kernel ran" and canonical re-encode; drop "rebuild IR from bytecode".
Missed items: deploy writes the artifact and exits 0 after a ZTS400 flow error (cause of R13); `zttp test <file>` exits 0 when it runs nothing; String(1e21) prints 22 digits; DebugAllocator leak at project_config.zig:221 dupStringField on serve; S1 lets an attacker pin a bogus statement under the legitimate name (first-registration-wins per slot).
