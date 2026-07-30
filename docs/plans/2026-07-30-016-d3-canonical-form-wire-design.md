# D3: canonical form and wire design doc

**Owns:** the lexical grammar, the canonical formatter, digest algorithms and
pre-images, the agent-protocol payload schemas, and the equivalence-validator
method taxonomy.
**Unblocks:** master-plan Phase 1 (protocol skeleton, hash freeze) and Phase 6
(idiom table, validators, gate-complete protocol).
**Spec basis:** rev 4, sections 4.2 (canonical vs idiomatic), 4.2.1, 4.8, 5.5
(semicolons), 8 (grammar preamble).

---

## 0. Ground truth (measured)

| Fact | Location | Consequence |
|---|---|---|
| **No formatter or pretty-printer exists anywhere.** Every rewrite splices byte spans into otherwise-verbatim source | `canonicalize.zig:719-757, 846-891`; repo-wide grep | The spec's "canonical ... unique to the byte" has no implementation. **Largest single cost in this doc.** |
| Line-keyed rewrites reject any replacement containing a newline | `canonicalize.zig:725` | Multi-line idiom rewrites need the span path, not the line path. |
| Two disjoint rewrite representations (`Refactor` line-keyed with a string `kind`; `StatementRewrite` span-keyed with a typed intent) | `canonicalize.zig:13-20, 793-813` | Three parallel repair vocabularies exist; the spec assumes one. |
| Normalize loop: 64 iterations max, terminates on a strictly decreasing canonical-band count, **no idempotence check** | `canonicalize.zig:2245-2367, 2160` | Confluence is asserted in a comment (`:2238-2244`), never verified. |
| `original_line` is never serialized to JSON | `canonicalize.zig:2581-2610` | A JSON consumer cannot re-validate staleness — the spec's repair binding requires it. |
| Every hash is SHA-256, wire form `bytesToHex(.lower)`; policy hash uses a canonical field-wise pre-image, contract hash uses the serialized JSON with fixed key order | `rule_registry.zig:867-903`; `build_receipt.zig:72-74` | Algorithm and encoding are settled. Only pre-images need specifying. |
| Identifiers are ASCII-only; no numeric separators; no BigInt; unknown escapes copy the byte verbatim; `\`+newline yields a literal newline | `tokenizer.zig:648-654, 431-468`; `parse.zig:3805-3810` | The lexical layer diverges from JS in ways that must be decided, not inherited. |
| JSX disambiguation is prefix-position only: `<` at expression start is JSX, `<` in infix position is comparison | `parse.zig:1739` | **The spec's TSX comparison requirement (5.8) is already satisfied.** No parser work needed. |
| `jsx_*` token kinds and `newline` are declared but never produced | `token.zig:96-102, 166-168` | Dead enum members; ASI has no token-level support (but `parse.zig` has `return`-ASI). |
| `prove-behavior` compares extracted **contracts**, not code or traces | `prove_behavior.zig:106-133` | Usable as a validator method, but blind to pure-computation changes. |
| Four validated-rewrite notions already exist (snapshot re-validation, edit-simulate veto, band-decreasing gate, signed equivalence receipts) | `canonicalize.zig:770, 2125-2149, 2315-2330`; `equivalence_probe_lib.zig` | The validator taxonomy has real material to build on. |

---

## 1. Decision: the lexical grammar is the current tokenizer, minus six divergences

Spec 8 defers the lexical layer ("must also define numeric literals, string
escapes, Unicode identifiers, templates, patterns, and TSX"). This section is
that definition. The rule throughout: **adopt what the tokenizer does; make
every place it silently accepts malformed input an error.**

**Adopted as-is, and now normative:**
- Identifiers are ASCII: start `[A-Za-z_$]`, continue `[A-Za-z_$0-9]`. No
  Unicode identifiers, no `\u` escapes in identifiers. Deliberate: it keeps the
  canonical-form and digest story free of normalization-form questions
  (NFC vs NFD would otherwise be a digest input). Non-ASCII text belongs in
  string literals, which are full Unicode.
- Numeric forms: decimal with optional fraction and exponent; `0x`/`0X` hex;
  `0b`/`0B` binary; `0o`/`0O` octal. No separators (`1_000`), no BigInt suffix.
- `1.` lexes as `number(1)` followed by `.` — kept, matches JS, harmless.
- Template lexing including the `template_depth` / `subst_brace_depths` nesting
  tracker, with the 16-level nesting cap now normative rather than incidental.
- **JSX/TSX disambiguation by parse position**: `<` at expression start is a JSX
  element; `<` in infix position is comparison. This already satisfies spec 5.8's
  "the tokenizer MUST parse ordinary `<`, `<=`, `>`, `>=` inside TSX expression
  containers" — the requirement is met, and no reversed-comparison workaround is
  needed anywhere.

**Six divergences that become errors:**

| Today | Decision | Why |
|---|---|---|
| `\` + real newline in a string yields a **literal newline** | Error: `line_continuation_unsupported` | A silent JS divergence in string *values*. Closed semantics cannot carry it. |
| Unknown escape (`\q`) copies the byte verbatim | Error: `unknown_escape` | Closes the escape set: `\n \r \t \\ \' \" \0 \b \f \v \xNN \uNNNN \u{...}`. |
| `0x` with no digits lexes as a 2-byte number | Error: `malformed_numeric_literal` | Same for `1e`, `1e+`. |
| `0755` lexes as decimal 755 | Error: `legacy_octal_literal` | Leading zero followed by digits is ambiguous to every reader. |
| Unterminated string runs to EOF with no diagnostic | Error: `unterminated_string` | |
| Non-ASCII byte becomes a one-byte `.invalid` token, degrading an identifier into a token run | Error: `non_ascii_identifier`, reported once per run | The current failure mode is unreadable. |

**Cleanup:** delete the seven never-produced `jsx_*` token kinds and the
never-produced `newline` kind (`token.zig:96-102, 166-168`).

**ASI.** Spec 5.5 mandates none; `parse.zig:1024-1031` implements `return`-ASI.
Removal lands in Phase 6 together with the unique-parse-insertion repair
(§4, method M2), so no program is left without a mechanical fix.

---

## 2. Decision: build the canonical formatter, fail closed until it is total

There is no printer today, and "canonical, unique to the byte" cannot be
delivered by span splicing. The formatter is built as an AST-to-source printer
over the parsed IR plus retained trivia.

**Why not the cheaper option.** A "canonical layout checker" that rejects
non-conforming layout with repairs avoids writing a printer, but it makes every
layout rule a separate rule with its own repair, and byte-idempotence then
depends on proving the repairs commute — which is strictly harder than printing.
Print once, compare bytes.

**Layout rules** (normative; chosen to match the repo's existing `.ts` sources so
the corpus does not churn):

- Indent: 2 spaces, never tabs. Continuation lines indent one level.
- Line width: 80 columns soft target. Break only at the listed points, never
  mid-token.
- Strings: double quotes; escape `"` inside, never `'`.
- Semicolons: always present (§1, no ASI).
- Trailing commas: present in multi-line lists (arguments, array and record
  literals, parameter lists, import specifier lists, type-parameter lists);
  absent in single-line ones.
- Blank lines: exactly one between top-level declarations; none at file start;
  exactly one at file end. Runs of two or more blank lines collapse to one.
- Records and arrays print on one line when they fit in the width, otherwise one
  element per line.
- `match`: one arm per line, arm expressions on the same line as their pattern
  when they fit, otherwise indented on the next line.
- Binary chains break before the operator, not after.
- Imports: one specifier per line when the clause does not fit; specifier order
  is **preserved**, never sorted. Sorting would be a second rewrite with its own
  equivalence obligation and no readability payoff the corpus demonstrates.
- Comments: line comments retain their own line and preceding blank; trailing
  comments stay on their line; block comments print verbatim. Comment text is
  never reflowed.

**Fail closed until total.** The printer refuses (returns
`error.UnprintableConstruct` and `normalize --write` declines) for any construct
it does not cover. That keeps the byte-identity claim honest during the phase-in
instead of silently emitting a near-canonical file.

**Trivia.** The parser must retain comments and their attachment points to feed
the printer. This is new; the IR today discards them. Scope it as the first task
of the formatter work, since every later layout rule depends on it.

---

## 3. Decision: digests

**Algorithm and encoding, everywhere:** SHA-256, wire form lowercase hex, 64
characters. This is already universal in the repo; adopting it needs no change.

**Pre-images** — the part the spec leaves open. Each is a canonical byte string
built field-wise with `\0` separators and a `\x01` record terminator, the shape
the policy hash already uses (`rule_registry.zig:867-903`):

| Digest | Pre-image |
|---|---|
| `source_digest` | The source file's **raw bytes**, uncanonicalized. Repair spans are byte offsets into these bytes, so any transformation before hashing would break span binding. |
| `type_digest` | D1's `canonicalTypeString` (D1 §1). |
| `policy_hash` | Unchanged: field-wise over `all_rules`. |
| `semantics_hash` | Unchanged: the registry walk in `semantics.zig:465-535`. |
| `module_graph_hash` | New. Canonical serialization of the **resolved** graph: for each module in ascending canonical-path order, `path \0 source_digest \0` then for each import in source order `specifier \0 resolved_kind \0 resolved_target \0`, record-terminated; then the builtin registry hash; then, for each `zttp-ext:` module, `manifest_digest \0 implementation_digest \0`. Ascending path order (not traversal order) makes the digest independent of which entry file was analyzed. |
| `idiom_table_hash` | New. Field-wise over the idiom registry: `id \0 operation \0 idiomatic \0 superseded \0 precondition \0 rewrite_id-or-sentinel \x01`. |
| `contract_hash` | Unchanged: SHA-256 of the serialized contract JSON, whose key order is fixed by `writeContractJson`. |

**Canonical path form** for the graph digest: absolute, symlinks resolved, `.`
and `..` removed, project-root-relative, `/` separators. Resolution must reject a
path escaping the project root before hashing (spec 4.8's boundary rule).

---

## 4. Decision: the equivalence-validator taxonomy

Spec 4.2.1 requires every emitted rewrite to carry "a registered equivalence
validator ... its validation method", and defines exactly one (unique-parse for
semicolons). This is the catalog. Five methods, ordered strongest to weakest.

**M1 — layout identity.** Print both sides with the §2 formatter; equivalent iff
the printed bytes match. Discharges every layout-only rewrite.
*Covers:* formatting, blank-line collapse, quote normalization.

**M2 — parse identity.** Parse both sides; equivalent iff the IR trees are
identical modulo source positions and trivia. Discharges rewrites that change
bytes without changing structure.
*Covers:* semicolon insertion (the parser's unique-parse check), redundant
parentheses, the `{ value: value }` → `{ value }` shorthand, the
one-field-destructure ↔ member-read pair, tuple destructure ↔ index reads.

**M3 — kernel-IR identity.** Elaborate both sides to the semantic kernel
(spec 9) and compare after kernel-level normalization; equivalent iff identical.
Discharges rewrites whose two spellings share one elaboration.
*Covers:* `` `${String(n)}` `` ↔ `` `${n}` `` (same `String` intrinsic call),
the redundant-template row, `?:` ↔ two-arm boolean `match` (both lower to a
conditional branch over the same operands), the record-update row, the
`match`-arm binding rows.

**M4 — declared law.** The rewrite instantiates an algebraic law registered on
the intrinsics involved, discharged either by the existing SMT mechanism
(`semantics_smt.zig` with z3, already in `scripts/verify.sh`) or by an audited
`Law` entry on a `FunctionBinding` (`module_binding.zig:1431-1449`), with the
law's own preconditions carried into the row's precondition column.
*Covers:* `indexOf(v) !== -1` → `includes(v)` (law: equal for element types
excluding `NaN`), `find(p) !== undefined` → `some(p)` (law: equal for element
types excluding `undefined`), `x === undefined ? d : x` → `x ?? d` (law: equal
when the type excludes `null`), `unwrapOr`, `collectAll`, the Dict bulk-op rows.
This is the method the interesting idiom rows need, and it is why every one of
those rows carries a type-conditioned precondition in the spec table.

**M5 — contract behavioral equivalence.** `prove-behavior`'s contract diff
(`prove_behavior.zig:106-133`). **Advisory-only.** It compares extracted
contracts, so it is blind to changes in pure computation the contract does not
model — a rewrite that preserves every route, condition, response status and IO
sequence is reported `equivalent` even if it changed arithmetic. A rewrite whose
only available method is M5 is **never** auto-applied; per spec 4.2.1 it ships as
an advisory with no emitted rewrite.

**Registry.** Each idiom row names its method and, for M4, its law identifier.
`meta.payload.validators` publishes `{ id, method, law_id?, covers[] }`. A row
with no method is legal and ships advisory-only — the spec's own fallback.

**Confluence obligation.** Spec 4.2.1 requires the rewrite relation be confluent
under innermost-first order, including rows enabled by an earlier rewrite. The
discharge procedure: enumerate all row pairs whose left-hand patterns can match
overlapping or nested sites (a critical-pair analysis over the row patterns,
which are few and shallow), and for each pair prove joinability by applying both
orders and comparing with M2. Pairs that do not join are a build failure, not a
runtime surprise. This runs as a test over the registry, not per compilation.

**Idempotence gate.** Add what does not exist today: a property test that
`normalize(normalize(x)) == normalize(x)` byte-for-byte over every file in
`examples/`, wired into `scripts/verify.sh`. This is the cheapest possible check
on the whole machinery and its absence is the main reason confluence is
currently only asserted.

---

## 5. Decision: one repair vocabulary

Three exist (typed `RepairIntent` on rules, `RepairKind`/`EditIntentKind` in
`repair_plan.zig`, string `Refactor.kind` in `canonicalize.zig`). Collapse to
one:

```zig
pub const Repair = struct {
    intent: RepairIntent,          // the existing enum, order-stable (policy hash)
    idiom_id: ?[]const u8,         // set when the repair realizes an idiom row
    start_offset: usize,           // half-open byte span into source_digest's bytes
    end_offset: usize,
    original: []const u8,          // snapshot; re-validated at apply time
    replacement: []const u8,
    validator: ?ValidatorRef,      // method + law id; null => advisory-only
};
```

`Refactor`'s string `kind` and the line-keyed apply path retire: every rewrite
becomes span-keyed, which also removes the "line-keyed takes absolute priority"
scheduling rule and the no-newline restriction. `repair_plan.zig`'s separate
`RepairKind`/`EditIntentKind` stay as the *counterexample-repair* vocabulary
(a different feature) but gain a comment stating they are not the canonical
vocabulary.

**`original` is serialized.** The spec's binding list requires the original span
digest or bytes; today `original_line` is dropped at the JSON boundary
(`canonicalize.zig:2581-2610`), so a client cannot re-validate. Fix.

---

## 6. Decision: protocol payload schemas

The envelope is given by spec 4.8. This section fixes the payloads. All field
names are `snake_case` — the existing JSON output mixes cases
(`spec_diagnostics` beside `proofCapsules`), and the v2 surface standardizes
rather than inheriting the inconsistency. v1 commands keep their current shapes
untouched.

**Common types:**

```
diagnostic := { code, rule_id, severity: "error"|"warning"|"advisory",
                message, explanation?, file, source_digest,
                span: { start, end, line, column },
                effect_impact?, proof_impact?,
                repair?: repair, decision?: decision_point }
repair     := { intent, idiom_id?, span: {start,end}, original, replacement,
                validator?: { method, law_id? },
                bound: { source_digest, profile_id, policy_hash,
                         module_graph_hash } }
decision   := { kind, parameters, allowed_next_actions[] }
error      := { code, message, field? }          # protocol-level, not a diagnostic
```

**Per operation** (request `input` → response `payload`):

| Operation | `input` | `payload` |
|---|---|---|
| `meta` | `{}` | `{ compiler_version, profile_id, policy_version, policy_hash, operations, verifiers, grammar, examples, ambient_names, severities, idioms, validators, type_serialization, limits, decisions, module_catalog }` |
| `features` | `{}` | `{ features: [{ id, category, status }] }` |
| `restrictions` | `{ by?: "proof"\|"class" }` | `{ restrictions: [{ feature, boundary, nature }] }` |
| `describe_rule` | `{ rule?: string }` | `{ rules: [{ name, code, category, description, example?, help, repair_intent?, severity }] }` |
| `modules` | `{ file }` | `{ graph: [{ path, source_digest, imports: [...] }], builtins, extensions, decisions, rejected, module_graph_hash }` |
| `check` | `{ file }` | `{ contract?, properties?, capsules? }` + `diagnostics[]` |
| `canonicalize` | `{ file, simulate?: bool }` | `{ candidates: [repair + { grade }], simulation? }` |
| `simulate_edit` | `{ file, repairs: [repair] }` | `{ ok, new_count, preexisting_count, diagnostics }` |
| `apply_repair` | `{ file, repairs: [repair] }` | `{ applied, source_digest, module_graph_hash }` |
| `normalize` | `{ file, write?: bool }` | `{ converged, fully_canonical, iterations, rewrite_trace, canonical_source, residual }` |
| `verify` | `{ file, properties: [id] }` | `{ results: [{ property, grade, evidence?, explanation_graph? }] }` |

**Frozen negotiation response** — returned for any unsupported
`schema_version`, and identical across all present and future versions:

```json
{ "schema_version_unsupported": true,
  "supported_schema_versions": [2],
  "compiler_version": "..." }
```

Three keys, no envelope, no diagnostics. Frozen means: a future v3 binary
returns exactly this shape to a v1 client.

**Protocol error codes** (the `error` object's `code`): `unknown_operation`,
`malformed_request`, `unsupported_schema_version`, `project_root_unresolvable`,
`path_outside_project_root`, `file_unreadable`, `identity_mismatch`,
`internal_error`. Closed set, registry-published.

**Determinism.** Response JSON on stdout, one object, trailing newline; logs to
stderr; array order deterministic for identical authenticated inputs (spec 4.8).
Serialization uses `std.json.Stringify` — `prove_behavior.zig:162-205` already
does, and hand-rolled writers are what produced the case inconsistency.

---

## 7. Implementation order

**Phase 1 needs:** §3 digests (freeze before anything hashes), §6 envelope +
negotiation + error codes + the seven wrappable operations.

**Phase 6 needs:** §1 lexical errors and ASI removal, §2 the formatter, §4 the
validator taxonomy and the idempotence gate, §5 the unified repair vocabulary,
§6's remaining operations.

Within Phase 6, order: idempotence gate first (it is a test, and it will fail —
that failure is the map of what needs fixing), then the repair-vocabulary
collapse, then the formatter (trivia retention, then printing, then
`normalize --write` enabled per-construct), then validators M1-M3, then M4's law
registry, then the lexical tightenings, then ASI removal.

---

## 8. Deliberately deferred

- Unicode identifiers (§1). Revisit only with a concrete user need; it drags in
  normalization-form choices that touch every digest.
- Import-specifier sorting (§2).
- Comment reflowing (§2).
- A canonical form for the source encoding itself: files are UTF-8, and a BOM is
  an error. Wider encoding support is not planned.
- Making M5 stronger by comparing kernel traces rather than contracts. That is
  the interesting long-term validator, and it depends on the kernel operational
  semantics that the spec's Section 10 still defers.
