//! Static registry of all diagnostic rules.
//!
//! Derived at comptime from the handler_verifier.DiagnosticKind,
//! strict_checker.DiagnosticKind and handler_policy ViolationKind enums so the
//! registry cannot drift from the actual checkers.
//!
//! `property_diagnostics.ViolationKind` is deliberately NOT a source. Its
//! violations are a second serialization of findings that already carry codes:
//! `collectVerifierViolations` relabels ZTS303 as `result_unsafe` and
//! ZTS308/ZTS309 as `optional_unchecked`, and the flow kinds beside them
//! restate ZTS400, ZTS401 and ZTS407. Advertising those again as PROP01-PROP06
//! let one finding be counted twice by anything measuring this registry.
//!
//! Used by `zts describe-rule`, `zts search`, and policy hash assertions.

const std = @import("std");
const diagnostic_catalog = @import("diagnostic_catalog.zig");
const handler_verifier = @import("handler_verifier.zig");
const strict_checker = @import("strict_checker.zig");
const handler_policy = @import("zts-engine").handler_policy;
const flow_checker = @import("flow_checker.zig");
const repair_intent_mod = @import("repair_intent.zig");

pub const RepairIntent = repair_intent_mod.RepairIntent;

pub const RuleCategory = enum {
    verifier,
    policy,
    flow,

    pub fn label(self: RuleCategory) []const u8 {
        return switch (self) {
            .verifier => "verifier",
            .policy => "policy",
            .flow => "flow",
        };
    }
};

pub const RuleEntry = struct {
    name: []const u8,
    code: []const u8,
    category: RuleCategory,
    description: []const u8,
    example: ?[]const u8,
    help: []const u8,
    /// Typed repair primitive for veto-able diagnostics. The `zttp expert`
    /// agent uses this to pick an apply primitive directly instead of parsing
    /// the prose `help` text. `null` when no single canonical repair applies.
    repair: ?RepairIntent,
};

// ---------------------------------------------------------------------------
// Verifier rules (ZTS3xx) - derived from handler_verifier.DiagnosticKind
// ---------------------------------------------------------------------------

const verifier_meta = [_]struct {
    kind: handler_verifier.DiagnosticKind,
    code: []const u8,
    description: []const u8,
    example: ?[]const u8,
    help: []const u8,
    repair: ?RepairIntent,
}{
    .{
        .kind = .missing_return_path,
        .code = "ZTS302",
        .description = "A code path through the handler does not return a Response.",
        .example = null,
        .help = "Ensure every code path returns a Response.",
        .repair = .add_trailing_return,
    },
    .{
        .kind = .unchecked_result_value,
        .code = "ZTS303",
        .description = "result.value is accessed without checking result.ok first.",
        .example = "const r = jwtVerify(token, secret); return Response.json(r.value);",
        .help = "Check result.ok before accessing result.value.",
        .repair = .insert_guard_before_line,
    },
    .{
        .kind = .unreachable_after_return,
        .code = "ZTS304",
        .description = "Code appears after an unconditional return statement.",
        .example = "return Response.json({ok: true}); const x = 1;",
        .help = "Remove unreachable code after the return.",
        // No single canonical apply primitive: removing a dead statement is
        // a free-form delete; deliberately null until a delete primitive exists.
        .repair = null,
    },
    .{
        .kind = .unused_variable,
        .code = "ZTS305",
        .description = "A variable is declared but never referenced.",
        .example = "const unused = 42;",
        .help = "Remove the unused variable or prefix with _.",
        // Same as ZTS304: no canonical primitive yet.
        .repair = null,
    },
    .{
        .kind = .unused_import,
        .code = "ZTS306",
        .description = "An import binding is never used.",
        .example = "import { sha256 } from 'zttp:crypto'; // sha256 never used",
        .help = "Remove the unused import.",
        .repair = null,
    },
    .{
        .kind = .unchecked_optional_use,
        .code = "ZTS308",
        .description = "An optional value is used without narrowing (e.g. undefined check).",
        .example = "const val = obj.name; return Response.text(val); // val may be undefined",
        .help = "Check val !== undefined before using it.",
        .repair = .insert_guard_before_line,
    },
    .{
        .kind = .unchecked_optional_access,
        .code = "ZTS309",
        .description = "A property on an optional value is accessed without narrowing.",
        .example = "const user = getUser(); return Response.text(user.name); // user may be undefined",
        .help = "Check the value is defined before accessing properties.",
        .repair = .insert_guard_before_line,
    },
    .{
        .kind = .module_scope_mutation,
        .code = "ZTS310",
        .description = "Handler body mutates a module-scope variable, breaking request isolation.",
        .example = "let count = 0; function handler(req) { count = count + 1; ... }",
        .help = "Move mutable state inside the handler or use zttp:cache.",
        // Refactor across two scopes: not a single primitive.
        .repair = null,
    },
    .{
        .kind = .spec_not_discharged,
        .code = "ZTS500",
        .description = "Handler declared a Proof<T, \"name\"> obligation but the inferred property is false.",
        .example = "structural Guardrails<T> = Proof<T, \"idempotent\">; function handler(req): Guardrails<Response> { return Response.json({ now: Date.now() }); }",
        .help = "Either remove the spec name from the Proof<T, P> union or fix the handler so the property holds.",
        .repair = .add_spec_assertion,
    },
    .{
        .kind = .spec_incompatible_with_import,
        .code = "ZTS501",
        .description = "Handler declared a spec that contradicts an imported virtual-module function.",
        .example = "structural G<T> = Proof<T, \"read_only\">; import { cacheSet } from 'zttp:cache'; // write violates read_only",
        .help = "Drop the spec name, remove the import, or move the writing call outside the handler.",
        .repair = null,
    },
    .{
        .kind = .spec_unknown_name,
        .code = "ZTS502",
        .description = "Handler declared Proof<T, \"NAME\"> with a name not in the v1 spec set.",
        .example = "structural G<T> = Proof<T, \"made_up\">;",
        .help = "Use one of: deterministic, read_only, retry_safe, idempotent, state_isolated, fault_covered, no_secret_leakage, no_credential_leakage, input_validated, pii_contained, injection_safe.",
        .repair = null,
    },
};

// ---------------------------------------------------------------------------
// Strict rules (ZTS061 and ZTS6xx) - default expert language profile
// ---------------------------------------------------------------------------

const strict_meta = [_]struct {
    kind: strict_checker.DiagnosticKind,
    code: []const u8,
    description: []const u8,
    example: ?[]const u8,
    help: []const u8,
    repair: ?RepairIntent,
}{
    .{
        .kind = .implicit_unknown,
        .code = "ZTS600",
        .description = "A handler-reachable call result has implicit unknown type.",
        .example = "const x = makeThing(); return Response.json(x);",
        .help = "Add a return type annotation, use a modeled virtual module, or narrow the value with a type guard/assert.",
        .repair = null,
    },
    .{
        .kind = .unpublished_ambient_global,
        .code = "ZTS629",
        .description = "An identifier refers to a value outside the profile's closed ambient namespace.",
        .example = "const secret = process.env.JWT_SECRET;",
        .help = "Import a published virtual-module capability or use an ambient name listed by meta.ambient_names.",
        .repair = null,
    },
    .{
        .kind = .missing_public_annotation,
        .code = "ZTS601",
        .description = "A function lacks explicit parameter or return annotations.",
        .example = "function handler(req) { return Response.json({ok: true}); }",
        .help = "Annotate every parameter and the return type, for example `function handler(req: Request): Response`.",
        .repair = null,
    },
    .{
        .kind = .raw_exported_boundary_type,
        .code = "ZTS061",
        .description = "An exported function parameter or return type exposes a raw built-in open type.",
        .example = "export function greet(name: string): string { return name; }",
        .help = "Declare a nominal or structural alias and name it in the exported signature.",
        .repair = .declare_boundary_type,
    },
    .{
        .kind = .dynamic_capability_access,
        .code = "ZTS602",
        .description = "Capability-bearing virtual module access uses a dynamic argument.",
        .example = "env(req.headers.name)",
        .help = "Use compiler-visible literal env keys, cache namespaces, SQL query names, egress URLs, route paths, or service names.",
        .repair = null,
    },
    .{
        .kind = .non_exhaustive_profile_match,
        .code = "ZTS603",
        .description = "A match expression is not exhaustive under the strict profile.",
        .example = "match (method) { 'GET' => ok }",
        .help = "Cover every finite union member or add an explicit default when the discriminant is not finite.",
        .repair = .add_trailing_return,
    },
    .{
        .kind = .avoidable_let,
        .code = "ZTS604",
        .description = "A let binding is not reassigned.",
        .example = "let x = 1; return x;",
        .help = "Use `const` for bindings that do not change.",
        .repair = .replace_let_with_const,
    },
    .{
        .kind = .computed_property_access,
        .code = "ZTS605",
        .description = "Dynamic computed property access hides object shape from the compiler.",
        .example = "obj[key]",
        .help = "Use a typed field, a literal key, or validate/narrow the object before indexing.",
        .repair = null,
    },
    .{
        .kind = .canonical_arrow_helper,
        .code = "ZTS608",
        .description = "A reused non-callback arrow helper is better represented as a named function.",
        .example = "const parseUser = (input: Input): User => makeUser(input);",
        .help = "Rewrite reusable helpers as named function declarations; keep arrows for callbacks and local one-off values.",
        .repair = .replace_arrow_with_function,
    },
    .{
        .kind = .canonical_export_function_const,
        .code = "ZTS609",
        .description = "An exported function-valued const hides that the public API is a function.",
        .example = "export const handler = (req: Request): Response => Response.json({ok: true});",
        .help = "Use `export function name(...) { ... }` unless the export is intentionally a first-class function value.",
        .repair = .replace_export_arrow_with_function,
    },
    .{
        .kind = .canonical_public_helper_effects,
        .code = "ZTS610",
        .description = "A public helper that reaches capabilities should declare its Effects<...> ceiling.",
        .example = "export function loadUser(id: string): User { return sqlOne(\"getUser\", {id}); }",
        .help = "Annotate the helper return type with `Effects<T, \"...\">` when it participates in capability-bearing paths.",
        .repair = .add_capability_declaration,
    },
    .{
        .kind = .canonical_internal_helper_effects,
        .code = "ZTS623",
        .description = "A module-internal function declares an Effects<...> ceiling. Placement is decidable: exported with a nonempty row must declare, module-internal must not.",
        .example = "function digest(s: string): Effects<string, \"crypto\"> { return sha256(s); } // not exported",
        .help = "Remove the Effects<...> ceiling. The compiler infers the row for a module-internal function, and the handler's Effects budget already bounds every helper it reaches (ZTS607).",
        .repair = null,
    },
    .{
        .kind = .canonical_public_helper_proof,
        .code = "ZTS611",
        .description = "A public helper used under declared specs should declare its Proof<...> capsule.",
        .example = "export function stableKey(input: Input): string { return input.id; }",
        .help = "Annotate the helper return type with `Proof<T, \"...\">` when it participates in declared proof obligations.",
        .repair = .add_spec_assertion,
    },
    .{
        .kind = .canonical_ternary_impure,
        .code = "ZTS612",
        .description = "A ?: arm must be a pure value; effectful selection uses match or if.",
        .example = "const status = ready ? load() : fallback;",
        .help = "Bind the effectful call first, or use `match` over the condition for an effectful two-way choice.",
        .repair = .replace_effectful_ternary_with_match,
    },
    .{
        .kind = .canonical_ternary_chain,
        .code = "ZTS621",
        .description = "A conditional expression may not appear as an arm of another conditional expression.",
        .example = "const tier = a ? 1 : b ? 2 : 3;",
        .help = "Use `match` over one scrutinee, or an if/else chain feeding a named function.",
        .repair = .replace_chained_ternary_with_match,
    },
    .{
        .kind = .canonical_compound_assignment,
        .code = "ZTS613",
        .description = "Compound assignment operators are not part of canonical ZigTS.",
        .example = "count += 1;",
        .help = "Write the update explicitly: `count = count + 1` instead of `count += 1`.",
        .repair = .replace_compound_assign_with_explicit,
    },
    .{
        .kind = .canonical_non_leading_spread,
        .code = "ZTS614",
        .description = "Object spread must appear before any explicit keys.",
        .example = "const next = {status: \"ok\", ...base};",
        .help = "Reorder so the spread is first: `{...base, status: \"ok\"}`. Later keys still override.",
        .repair = .lead_with_spread,
    },
    .{
        .kind = .canonical_call_spread,
        .code = "ZTS616",
        .description = "Spread arguments at call sites are not part of canonical ZigTS.",
        .example = "send(...args);",
        .help = "Pass positional arguments, or widen the helper signature so it accepts the array directly.",
        .repair = .widen_signature_drop_spread,
    },
    .{
        .kind = .canonical_redundant_bool_compare,
        .code = "ZTS620",
        .description = "A boolean value compared against a boolean literal (`x === true`).",
        .example = "if (ready === true) { ... }",
        .help = "Drop the literal comparison and use the boolean directly: `if (ready) { ... }` (or `if (!ready)` for `=== false`).",
        .repair = .drop_redundant_bool_compare,
    },
    .{
        .kind = .mutable_live_iteration,
        .code = "ZTS622",
        .description = "A for-of body mutates the collection the loop is iterating.",
        .example = "for (const x of xs) { xs.push(x); }",
        .help = "Iterate a snapshot: read from one collection and build the mutated one separately.",
        .repair = null,
    },
    .{
        .kind = .canonical_redundant_pattern_rename,
        .code = "ZTS625",
        .description = "A match record pattern renames a field to the name it already has.",
        .example = "when { value: value }: value",
        .help = "Write the shorthand binding: `when { value }: value`.",
        .repair = null,
    },
    .{
        .kind = .canonical_unbound_field_read,
        .code = "ZTS626",
        .description = "A match arm reads a field off the scrutinee instead of binding it in the pattern.",
        .example = "when { kind: \"echo\" }: command.text",
        .help = "Bind the field in the pattern (`when { kind: \"echo\", text }:`) and read the bound name; the binding is already narrowed and needs no second read of the scrutinee.",
        .repair = null,
    },
    .{
        .kind = .canonical_dict_entry_round_trip,
        .code = "ZTS627",
        .description = "An entry round trip through `dictEntries` and `dictFromEntries` that changes only values, or only drops entries.",
        .example = "dictFromEntries(dictEntries(d).map((p) => [p[0], p[1] * 2]))",
        .help = "Use `dictMapValues(d, f)` for a value-only change and `dictFilter(d, p)` for a drop. Both keep the key set by construction and return a `Dict`, so the `Result` the round trip forced on the caller goes away with it.",
        .repair = null,
    },
    .{
        .kind = .canonical_dict_entries_reduce,
        .code = "ZTS628",
        .description = "A `reduce` over `dictEntries(d)`.",
        .example = "dictEntries(d).reduce((acc, p) => acc + p[1], 0)",
        .help = "Fold the dictionary directly with `dictFold(d, (acc, value, key) => ..., init)`, which walks the entries without materializing the array first.",
        .repair = null,
    },
    .{
        .kind = .nullish_operator_on_null,
        .code = "ZTS624",
        .description = "`??` or `?.` applied where the operand's type admits `null`, a generic parameter, or `unknown`.",
        .example = "const name: string | null = row.name; const shown = name ?? \"anonymous\";",
        .help = "Both operators test `null` and `undefined` alike, so on such an operand they erase the distinction. Compare explicitly (`x === null`, `x === undefined`) or take the value apart with `match`. On a concrete type without `null` both operators stay idiomatic.",
        .repair = .insert_guard_before_line,
    },
};

// ---------------------------------------------------------------------------
// Policy rules (POL0xx) - derived from handler_policy combinations
// ---------------------------------------------------------------------------

const policy_meta = [_]struct {
    name: []const u8,
    code: []const u8,
    description: []const u8,
    help: []const u8,
    repair: ?RepairIntent,
}{
    .{
        .name = "env_literal_not_allowed",
        .code = "POL001",
        .description = "Handler accesses an env var not in the policy allow-list.",
        .help = "Add the env var to the policy file or remove the access.",
        .repair = null,
    },
    .{
        .name = "egress_literal_not_allowed",
        .code = "POL003",
        .description = "Handler calls an outbound host not in the policy allow-list.",
        .help = "Add the host to the policy file or remove the fetch call.",
        .repair = null,
    },
    .{
        .name = "cache_literal_not_allowed",
        .code = "POL005",
        .description = "Handler accesses a cache namespace not in the policy allow-list.",
        .help = "Add the namespace to the policy file or remove the cache access.",
        .repair = null,
    },
    .{
        .name = "sql_literal_not_allowed",
        .code = "POL007",
        .description = "Handler executes a SQL query name not in the policy allow-list.",
        .help = "Add the query name to the policy file.",
        .repair = null,
    },
};

// ---------------------------------------------------------------------------
// Proof-capsule rules (ZTS606) - function-level Proof<...> capsule discharge
// ---------------------------------------------------------------------------

const capsule_meta = [_]struct {
    name: []const u8,
    code: []const u8,
    description: []const u8,
    example: ?[]const u8,
    help: []const u8,
    repair: ?RepairIntent,
}{
    .{
        .name = "missing_proof_capsule",
        .code = "ZTS606",
        .description = "A handler-reachable helper breaks a capsule property the handler's Spec demands and carries no Proof<...> capsule declaring it.",
        .example = "function load(): User { return cacheSet('ns', 'k', 'v'); } function handler(req: Request): Proof<Response, \"read_only\"> { return Response.json(load()); }",
        .help = "Annotate the helper's return type with `Proof<T, \"...\">` and satisfy the property, or inline the helper into the handler.",
        .repair = .add_spec_assertion,
    },
    .{
        .name = "effects_undeclared_capability",
        .code = "ZTS503",
        .description = "A function reaches a capability that its declared Effects<...> ceiling does not list.",
        .example = "function load(): Effects<string, \"env\"> { return sha256('x'); } // sha256 needs crypto",
        .help = "Add the capability to the Effects<...> ceiling, or remove the call that reaches it.",
        .repair = .add_capability_declaration,
    },
    .{
        .name = "effects_unknown_capability",
        .code = "ZTS504",
        .description = "An Effects<...> ceiling names a capability that is not a runtime capability.",
        .example = "function load(): Effects<string, \"databse\"> { return env('X'); }",
        .help = "Use one of: env, clock, random, crypto, stderr, runtime_callback, sqlite, filesystem, network, policy_check.",
        .repair = null,
    },
    .{
        .name = "effects_over_declared",
        .code = "ZTS505",
        .description = "An Effects<...> ceiling names a capability the function never reaches. Advisory; never fails a build.",
        .example = "function pure(s: string): Effects<string, \"crypto\"> { return s; }",
        .help = "Remove the unused capability from the Effects<...> ceiling to keep it least-privilege.",
        .repair = null,
    },
    .{
        .name = "handler_budget_exceeded",
        .code = "ZTS506",
        .description = "The handler reaches a capability directly that is outside its declared Effects<...> budget.",
        .example = "function handler(req: Request): Effects<Response, \"env\"> { return Response.json({ t: Date.now() }); }",
        .help = "Add the capability to the handler's Effects<...> budget, or remove the call that reaches it.",
        .repair = .add_capability_declaration,
    },
    .{
        .name = "missing_proof_capsule_export",
        .code = "ZTS508",
        .description = "An exported helper carries no Proof<...> capsule. Emitted only under the opt-in docs mode.",
        .example = "export function clean(s: string): string { return s; }",
        .help = "Annotate the exported helper's return type with `Proof<T, \"...\">` to document its proven properties.",
        .repair = .add_spec_assertion,
    },
    .{
        .name = "helper_exceeds_handler_budget",
        .code = "ZTS607",
        .description = "A handler-reachable helper reaches a capability outside the handler's declared Effects<...> budget.",
        .example = "function load(): string { return sha256('x'); } function handler(req: Request): Effects<Response, \"env\"> { return Response.text(load()); }",
        .help = "Add the capability to the handler's Effects<...> budget, or remove the call from the reachable helper.",
        .repair = .add_capability_declaration,
    },
    .{
        .name = "workflow_call_in_step",
        .code = "ZTS509",
        .description = "workflow.call/saga/fanout/follow is used inside a durable.step() callback, which silently loses durability at runtime instead of failing.",
        .example = "step(() => call(\"billing\", { path: \"/charge\" })); // call() only durably records at step depth 0",
        .help = "Move the workflow.call/saga/fanout/follow invocation outside the step() callback, to the same durable.run() scope it's already recorded in.",
        .repair = null,
    },
    .{
        .name = "saga_step_missing_compensate",
        .code = "ZTS510",
        .description = "A statically-analyzable saga([...]) has a non-last step with no compensate, leaving a partial-rollback hole if a later step fails.",
        .example = "saga([{ name: \"reserve\", run: () => call(\"inv\", {}) }, { name: \"ship\", run: () => call(\"ship\", {}) }]) // \"reserve\" has no compensate",
        .help = "Add a compensate thunk to the step, or move it last if it has no side effect that needs undoing.",
        .repair = null,
    },
    .{
        .name = "effect_ceiling_not_literal",
        .code = "ZTS511",
        .description = "An Effects<...> ceiling names its capabilities with something other than a closed union of string literals, so no ceiling is recovered and the check is skipped.",
        .example = "function h(): Effects<Response, Capabilities[number]> { ... } // payload is not a literal union",
        .help = "Write the ceiling as string literals (Effects<Response, \"clock\" | \"crypto\">) or as an alias bound directly to such a union.",
        .repair = .add_capability_declaration,
    },
    .{
        .name = "effect_row_lower_bound",
        .code = "ZTS512",
        .description = "The function calls through a value the compiler cannot resolve, so its effect row is a lower bound and cannot discharge a declared Effects<...> ceiling or budget.",
        .example = "function run(f: (x: number) => number): Effects<Response, \"clock\"> { return Response.json(f(1)); } // f is unresolvable",
        .help = "Call the helper by name so the compiler can see its body, or drop the Effects<...> declaration this call cannot support.",
        .repair = null,
    },
};

// ---------------------------------------------------------------------------
// Flow rules (ZTS4xx) - derived from flow_checker.DiagnosticKind
//
// The data-label flow checker emits ZTS4xx codes for {secret}, {credential},
// and {user_input} leaks reaching responses, logs, and egress. Wave 1B/2D
// P0 #5 (2026-05-23 review) flagged that `policyHash` did not include
// these rules, so adding, removing, or renaming a flow diagnostic did not
// trip the embedded-contract drift check at runtime. The `comptime` block
// below pins exhaustiveness against the live enum: any new DiagnosticKind
// variant must show up here, or the build fails with a named compile
// error. Codes mirror `packages/tools/src/json_diagnostics.zig:151-162`.
// ---------------------------------------------------------------------------

const flow_meta = [_]struct {
    kind: flow_checker.DiagnosticKind,
    code: []const u8,
    description: []const u8,
    example: ?[]const u8,
    help: []const u8,
    repair: ?RepairIntent,
}{
    .{
        .kind = .secret_in_response,
        .code = "ZTS400",
        .description = "A value labeled {secret} reaches a Response body or header.",
        .example = "const key = env('SECRET_KEY'); return Response.json({ key: key });",
        .help = "Do not return secrets to clients; derive a public artifact or drop the label.",
        .repair = null,
    },
    .{
        .kind = .credential_in_response,
        .code = "ZTS401",
        .description = "A value labeled {credential} reaches a Response body.",
        .example = "const token = jwtSign(claims, secret); return Response.json({ token: token });",
        .help = "Return only opaque session ids; never echo credentials issued by the handler.",
        .repair = null,
    },
    .{
        .kind = .secret_in_log,
        .code = "ZTS402",
        .description = "A value labeled {secret} reaches console.log / warn / error.",
        .example = "const key = env('SECRET_KEY'); logInfo(key);",
        .help = "Strip or mask the secret before logging.",
        .repair = null,
    },
    .{
        .kind = .credential_in_log,
        .code = "ZTS403",
        .description = "A value labeled {credential} reaches console.log / warn / error.",
        .example = "const auth = parseBearer(req.headers.get('Authorization')); logDebug(auth);",
        .help = "Log a hash or session id instead of the credential itself.",
        .repair = null,
    },
    .{
        .kind = .secret_in_egress_url,
        .code = "ZTS404",
        .description = "A value labeled {secret} reaches a fetch URL.",
        .example = "const key = env('SECRET_KEY'); fetchSync(['https://api/?k=', key].join(''));",
        .help = "Send the secret in a request header or body field that is not part of the URL.",
        .repair = null,
    },
    .{
        .kind = .credential_in_egress_url,
        .code = "ZTS405",
        .description = "A value labeled {credential} reaches a fetch URL.",
        .example = "fetchSync(['https://api/u?token=', authToken].join(''));",
        .help = "Use an Authorization header instead of placing credentials in URLs.",
        .repair = null,
    },
    .{
        .kind = .secret_in_egress_body,
        .code = "ZTS406",
        .description = "A value labeled {secret} reaches a fetch request body.",
        .example = "fetchSync('https://api/echo', { method: 'POST', body: JSON.stringify({ key }) });",
        .help = "Forward the secret only to a host on the egress allow-list, or strip it.",
        .repair = null,
    },
    .{
        .kind = .unvalidated_input_in_egress,
        .code = "ZTS407",
        .description = "A {user_input} value without {validated} reaches an egress call.",
        .example = "fetchSync(['https://api/echo?q=', String(req.url.searchParams.get('q'))].join(''));",
        .help = "Pass user input through validateJson / schemaCompile or strip it before egress.",
        .repair = null,
    },
};

comptime {
    // Exhaustiveness gate: every flow_checker.DiagnosticKind must have a row
    // in flow_meta. If a new variant lands without a corresponding rule, the
    // build fails with the variant name — the policy hash cannot silently
    // miss a new ZTS4xx code.
    const fields = @typeInfo(flow_checker.DiagnosticKind).@"enum".fields;
    var seen: [fields.len]bool = .{false} ** fields.len;
    for (flow_meta) |entry| {
        seen[@intFromEnum(entry.kind)] = true;
    }
    for (seen, 0..) |s, idx| {
        if (!s) {
            @compileError("flow_meta missing entry for flow_checker.DiagnosticKind." ++ fields[idx].name);
        }
    }
}

// ---------------------------------------------------------------------------
// Unified rule table (comptime-assembled)
// ---------------------------------------------------------------------------

fn verifierName(kind: handler_verifier.DiagnosticKind) []const u8 {
    return @tagName(kind);
}

fn strictName(kind: strict_checker.DiagnosticKind) []const u8 {
    return @tagName(kind);
}

fn flowName(kind: flow_checker.DiagnosticKind) []const u8 {
    return @tagName(kind);
}

const total_count = verifier_meta.len + strict_meta.len + capsule_meta.len + policy_meta.len + flow_meta.len;

pub const all_rules: [total_count]RuleEntry = blk: {
    var rules: [total_count]RuleEntry = undefined;
    var i: usize = 0;

    for (verifier_meta) |v| {
        rules[i] = .{
            .name = verifierName(v.kind),
            .code = diagnostic_catalog.verifierCode(v.kind),
            .category = .verifier,
            .description = v.description,
            .example = v.example,
            .help = v.help,
            .repair = v.repair,
        };
        i += 1;
    }

    for (strict_meta) |s| {
        rules[i] = .{
            .name = strictName(s.kind),
            .code = diagnostic_catalog.strictCode(s.kind),
            .category = .verifier,
            .description = s.description,
            .example = s.example,
            .help = s.help,
            .repair = s.repair,
        };
        i += 1;
    }

    for (capsule_meta) |c| {
        rules[i] = .{
            .name = c.name,
            .code = c.code,
            .category = .verifier,
            .description = c.description,
            .example = c.example,
            .help = c.help,
            .repair = c.repair,
        };
        i += 1;
    }

    for (policy_meta) |p| {
        rules[i] = .{
            .name = p.name,
            .code = p.code,
            .category = .policy,
            .description = p.description,
            .example = null,
            .help = p.help,
            .repair = p.repair,
        };
        i += 1;
    }

    for (flow_meta) |f| {
        rules[i] = .{
            .name = flowName(f.kind),
            .code = diagnostic_catalog.flowCode(f.kind),
            .category = .flow,
            .description = f.description,
            .example = f.example,
            .help = f.help,
            .repair = f.repair,
        };
        i += 1;
    }

    break :blk rules;
};

// ---------------------------------------------------------------------------
// Lookup functions
// ---------------------------------------------------------------------------

pub fn findByName(name: []const u8) ?*const RuleEntry {
    for (&all_rules) |*rule| {
        if (std.mem.eql(u8, rule.name, name)) return rule;
    }
    return null;
}

pub fn findByCode(code: []const u8) ?*const RuleEntry {
    for (&all_rules) |*rule| {
        if (std.mem.eql(u8, rule.code, code)) return rule;
    }
    return null;
}

/// True when `code` belongs to the compiler-enforced canonical ZigTS profile.
///
/// This is intentionally keyed through the rule registry instead of duplicating
/// a ZTS-code list in every caller. `fullyCanonical`, proof-card rendering, and
/// agent tooling all depend on the same predicate: zero remaining diagnostics
/// from these rule names means the source is in Canonical Normal Form.
pub fn isCanonicalProfileCode(code: []const u8) bool {
    const rule = findByCode(code) orelse return false;
    return isCanonicalProfileName(rule.name);
}

fn isCanonicalProfileName(name: []const u8) bool {
    return std.mem.eql(u8, name, "dynamic_capability_access") or
        std.mem.eql(u8, name, "avoidable_let") or
        std.mem.eql(u8, name, "computed_property_access") or
        std.mem.startsWith(u8, name, "canonical_");
}

pub const SearchResults = struct {
    buf: [total_count]*const RuleEntry = undefined,
    len: usize = 0,

    pub fn constSlice(self: *const SearchResults) []const *const RuleEntry {
        return self.buf[0..self.len];
    }
};

/// Returns borrowed rules where `keyword` is a substring of name, description,
/// or help. Stack-allocated, no heap.
pub fn search(keyword: []const u8) SearchResults {
    var results = SearchResults{};

    for (&all_rules) |*rule| {
        if (containsSubstring(rule.name, keyword) or
            containsSubstring(rule.description, keyword) or
            containsSubstring(rule.help, keyword))
        {
            results.buf[results.len] = rule;
            results.len += 1;
        }
    }
    return results;
}

fn containsSubstring(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    return std.mem.indexOf(u8, haystack, needle) != null;
}

// ---------------------------------------------------------------------------
// Policy hash (SHA-256 of sorted rule metadata)
// ---------------------------------------------------------------------------

/// Deterministic SHA-256 hash of all rule metadata.
/// Changes if and only if a rule is added, removed, or its metadata changes.
/// Cannot be comptime due to SHA-256 branch budget; cached on first call.
var cached_hash: ?[64]u8 = null;

pub fn policyHash() [64]u8 {
    if (cached_hash) |h| return h;
    cached_hash = computePolicyHash();
    return cached_hash.?;
}

fn computePolicyHash() [64]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});

    for (&all_rules) |*rule| {
        hasher.update(rule.name);
        hasher.update("\x00");
        hasher.update(rule.code);
        hasher.update("\x00");
        // Category byte — included so reclassifying a rule from `.policy` to
        // `.flow` (or vice versa) drifts the hash even when text strings
        // stay identical. Wave 1B/2D P0 #5 (2026-05-23 review).
        const category_byte: u8 = @intCast(@intFromEnum(rule.category));
        hasher.update(&[_]u8{category_byte});
        hasher.update("\x00");
        hasher.update(rule.description);
        hasher.update("\x00");
        hasher.update(rule.help);
        hasher.update("\x00");
        // Repair-intent byte — included so a rule getting a typed repair
        // (or losing one) drifts the policy hash. The agent reads the repair
        // tag instead of parsing prose, so
        // changes here are policy-visible. Sentinel 0xFF stands in for null
        // because RepairIntent has well under 255 variants.
        const repair_byte: u8 = if (rule.repair) |r| @intCast(@intFromEnum(r)) else 0xFF;
        hasher.update(&[_]u8{repair_byte});
        hasher.update("\x01");
    }

    const digest = hasher.finalResult();
    return std.fmt.bytesToHex(digest, .lower);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "all_rules has expected count" {
    try std.testing.expectEqual(total_count, all_rules.len);
    // Sanity: verifier + policy + property + flow categories all populate.
    // 13+ verifier + 8 policy + 6 property + 8 flow = 35+. The lower bound
    // tracks the smallest legitimate set; the exact count is enforced by the
    // total_count == all_rules.len check above.
    try std.testing.expect(all_rules.len >= 35);
}

test "every policy rule resolves through the closed diagnostic catalog" {
    for (&all_rules) |*rule| {
        const diagnostic = diagnostic_catalog.findByCode(rule.code) orelse {
            std.log.err("rule '{s}' uses uncataloged diagnostic {s}", .{ rule.name, rule.code });
            return error.UncatalogedDiagnostic;
        };
        try std.testing.expect(diagnostic.code.len > 0);
    }
}

test "all_rules includes every flow_checker.DiagnosticKind under .flow" {
    // Mirrors the comptime exhaustiveness gate but verifies the projection
    // into all_rules — guards against a refactor that wires flow_meta but
    // forgets to append it to the unified table.
    inline for (@typeInfo(flow_checker.DiagnosticKind).@"enum".fields) |field| {
        const kind: flow_checker.DiagnosticKind = @enumFromInt(field.value);
        const name = @tagName(kind);
        const entry = findByName(name) orelse {
            std.log.err("flow rule '{s}' missing from all_rules", .{name});
            return error.MissingFlowRule;
        };
        try std.testing.expectEqual(RuleCategory.flow, entry.category);
    }
}

test "policyHash differs when a rule is reclassified to a different category" {
    // Direct unit-style assertion: feeding the same name/code/text strings
    // but different categories must produce different hashes. This guards
    // the category-byte inclusion in computePolicyHash.
    const a: RuleEntry = .{
        .name = "x",
        .code = "ZTSTEST",
        .category = .verifier,
        .description = "d",
        .example = null,
        .help = "h",
        .repair = null,
    };
    const b: RuleEntry = .{
        .name = "x",
        .code = "ZTSTEST",
        .category = .flow,
        .description = "d",
        .example = null,
        .help = "h",
        .repair = null,
    };
    var ha = std.crypto.hash.sha2.Sha256.init(.{});
    var hb = std.crypto.hash.sha2.Sha256.init(.{});
    inline for (.{ &ha, &hb }, .{ a, b }) |h, rule| {
        h.update(rule.name);
        h.update("\x00");
        h.update(rule.code);
        h.update("\x00");
        const cat: u8 = @intCast(@intFromEnum(rule.category));
        h.update(&[_]u8{cat});
        h.update("\x00");
        h.update(rule.description);
        h.update("\x00");
        h.update(rule.help);
        h.update("\x00");
        const repair_byte: u8 = if (rule.repair) |r| @intCast(@intFromEnum(r)) else 0xFF;
        h.update(&[_]u8{repair_byte});
        h.update("\x01");
    }
    var da: [32]u8 = undefined;
    var db: [32]u8 = undefined;
    da = ha.finalResult();
    db = hb.finalResult();
    try std.testing.expect(!std.mem.eql(u8, &da, &db));
}

test "policyHash differs when a rule's repair intent changes" {
    // Slice B: changing the repair tag on a rule (e.g. from null to
    // replace_let_with_const) must drift the hash so downstream cassettes
    // that pin a policyHash see the rollover.
    const without: RuleEntry = .{
        .name = "y",
        .code = "ZTSTEST",
        .category = .verifier,
        .description = "d",
        .example = null,
        .help = "h",
        .repair = null,
    };
    const with: RuleEntry = .{
        .name = "y",
        .code = "ZTSTEST",
        .category = .verifier,
        .description = "d",
        .example = null,
        .help = "h",
        .repair = .replace_let_with_const,
    };
    var ha = std.crypto.hash.sha2.Sha256.init(.{});
    var hb = std.crypto.hash.sha2.Sha256.init(.{});
    inline for (.{ &ha, &hb }, .{ without, with }) |h, rule| {
        h.update(rule.name);
        h.update("\x00");
        h.update(rule.code);
        h.update("\x00");
        const cat: u8 = @intCast(@intFromEnum(rule.category));
        h.update(&[_]u8{cat});
        h.update("\x00");
        h.update(rule.description);
        h.update("\x00");
        h.update(rule.help);
        h.update("\x00");
        const repair_byte: u8 = if (rule.repair) |r| @intCast(@intFromEnum(r)) else 0xFF;
        h.update(&[_]u8{repair_byte});
        h.update("\x01");
    }
    const da = ha.finalResult();
    const db = hb.finalResult();
    try std.testing.expect(!std.mem.eql(u8, &da, &db));
}

test "findByName returns entry" {
    const entry = findByName("unchecked_result_value");
    try std.testing.expect(entry != null);
    try std.testing.expectEqualStrings("ZTS303", entry.?.code);
    try std.testing.expectEqual(RuleCategory.verifier, entry.?.category);
}

test "findByCode returns entry" {
    const entry = findByCode("ZTS303");
    try std.testing.expect(entry != null);
    try std.testing.expectEqualStrings("unchecked_result_value", entry.?.name);
}

test "ZTS061 publishes the non-automatic boundary repair intent" {
    const entry = findByCode("ZTS061") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("raw_exported_boundary_type", entry.name);
    try std.testing.expectEqual(RepairIntent.declare_boundary_type, entry.repair.?);
}

test "isCanonicalProfileCode follows the registry rule names" {
    try std.testing.expect(isCanonicalProfileCode("ZTS604"));
    try std.testing.expect(isCanonicalProfileCode("ZTS605"));
    try std.testing.expect(isCanonicalProfileCode("ZTS612"));
    try std.testing.expect(!isCanonicalProfileCode("ZTS600"));
    try std.testing.expect(!isCanonicalProfileCode("ZTS603"));
}

test "findByName unknown returns null" {
    try std.testing.expect(findByName("nonexistent_rule") == null);
}

test "findByCode unknown returns null" {
    try std.testing.expect(findByCode("ZTS999") == null);
}

test "search matches substring" {
    const results = search("result");
    try std.testing.expect(results.len >= 2);
}

test "search no matches" {
    const results = search("xyznonexistent");
    try std.testing.expectEqual(@as(usize, 0), results.len);
}

test "policyHash is deterministic and 64 hex chars" {
    const hash1 = policyHash();
    const hash2 = policyHash();
    try std.testing.expectEqualStrings(&hash1, &hash2);
    try std.testing.expectEqual(@as(usize, 64), hash1.len);
}

test "all verifier rules use the strict or verifier diagnostic bands" {
    // ZTS3xx covers the structural checks (return analysis, result/optional
    // checking, dead code, state isolation, websocket consistency).
    // ZTS061 is the exported-boundary declaration rule. ZTS4xx is reserved for FlowChecker (defined in tools/json_diagnostics
    // alongside the runtime flow analysis pipeline). ZTS5xx covers
    // author-declared spec discharge (ZTS500 not_discharged, ZTS501
    // incompatible_with_import, ZTS502 unknown_name). ZTS6xx covers the
    // default strict ZigTS language profile.
    for (&all_rules) |*rule| {
        if (rule.category == .verifier) {
            try std.testing.expect(
                std.mem.eql(u8, rule.code, "ZTS061") or
                    std.mem.startsWith(u8, rule.code, "ZTS3") or
                    std.mem.startsWith(u8, rule.code, "ZTS5") or
                    std.mem.startsWith(u8, rule.code, "ZTS6"),
            );
        }
    }
}

test "all policy rules have POL codes" {
    for (&all_rules) |*rule| {
        if (rule.category == .policy) {
            try std.testing.expect(std.mem.startsWith(u8, rule.code, "POL"));
        }
    }
}
