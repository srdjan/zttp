//! Permanent semantic fixtures for the flow checker (redesign plan P0).
//!
//! Each fixture is a handler that leaks at runtime, or that uses the same
//! mechanism as one that leaked, while its `Proof<Response, "...">` return
//! type claims the property the leak breaks. The semantic expectation is the
//! same for every fixture and lives in `Fixture.property`: that property is
//! NOT proven. A refusal and an unproven property both meet it (plan R8).
//! A fixture is never deleted and its expectation is never weakened. A change
//! to an expectation needs a reason in the commit message.
//!
//! After the P9 cutover these are permanent regressions: 33 fixtures are
//! refused, and five persistent-state readers stay unproven because their
//! stored value is unknown. Neither outcome may become a proof. Exact
//! verdicts also prevent an unknown value from acquiring a false refusal
//! diagnostic. The four clean contrasts must remain proven.
//!
//! Each fixture runs through the production typed pipeline,
//! `precompile.runCheckOnlyFromSourceWithOptions`, which the direct flow-test
//! helpers lack. `flow_census_gate.classify` reads the verdict. It reports
//! `no_verdict` when the flow stage did not run, when the handler has a parse
//! or type error, or when the claim failure disagrees with the property, so a
//! fixture that does not reach the flow pass fails instead of passing
//! vacuously.
//!
//! A `runtime:` comment names the runtime observation. The known-limits table
//! in `docs/proofs-and-receipts.md` records each row as a handler that
//! leaked under `zttp serve`. A fixture with no such comment is a variant of
//! a confirmed shape that was not run on its own.

const std = @import("std");
const precompile = @import("precompile.zig");
const gate = @import("flow_census_gate.zig");
const probes = @import("flow_census_probes.zig");

const Property = probes.Property;

pub const Fixture = struct {
    /// Unique fixture identity.
    name: []const u8,
    /// The property the fixture must NOT prove.
    property: Property,
    expected: gate.Observed = .refused,
    source: []const u8,
    /// A SQL schema for a handler that registers `zttp:sql` queries. The check
    /// refuses such a handler without one (`MissingSqlSchema`).
    sql_schema: ?[]const u8 = null,
};

/// The count of fixtures at the time this file was written. The floor makes a
/// deleted fixture a test failure instead of a silent loss.
const minimum_fixtures: usize = 38;

pub const fixtures = [_]Fixture{
    // -- A `let` reassigned in an `if` or `else` branch.
    // runtime: known-limits row "A let that is reassigned in an if or else branch"
    .{ .name = "branch_assign_raw_then", .property = .injection_safe, .source =
    \\import { escapeHtml } from "zttp:text";
    \\function handler(req: Request): Proof<Response, "injection_safe"> {
    \\  let x: string = escapeHtml(req.url);
    \\  if (req.url.length > 3) { x = req.url; } else { x = escapeHtml(req.url); }
    \\  return Response.html(x);
    \\}
    },
    // runtime: known-limits row "A let that is reassigned in an if or else branch"
    .{ .name = "branch_assign_raw_initial", .property = .injection_safe, .source =
    \\import { escapeHtml } from "zttp:text";
    \\function handler(req: Request): Proof<Response, "injection_safe"> {
    \\  let x: string = req.url;
    \\  if (req.url.length > 3) { x = escapeHtml(req.url); }
    \\  return Response.html(x);
    \\}
    },
    // -- A `let` carried from one `for...of` iteration to the next.
    // runtime: known-limits row "A let that carries a value from one for...of iteration to the next"
    .{ .name = "loop_carried_scalar", .property = .injection_safe, .source =
    \\function handler(req: Request): Proof<Response, "injection_safe"> {
    \\  let s: string = "";
    \\  const out: string[] = [];
    \\  for (const v of ["a", "b"]) { out.push(s); s = req.url; }
    \\  return Response.html(out.join(""));
    \\}
    },
    // -- A `push` that is not a statement of its own.
    // runtime: known-limits row "A push, unshift, or splice that is not a statement of its own"
    .{ .name = "push_in_initializer", .property = .injection_safe, .source =
    \\import { escapeHtml } from "zttp:text";
    \\function handler(req: Request): Proof<Response, "injection_safe"> {
    \\  const parts: string[] = [escapeHtml(req.url)];
    \\  const n: number = parts.push(req.url);
    \\  return Response.html(parts.join(""));
    \\}
    },
    // runtime: known-limits row "A push, unshift, or splice that is not a statement of its own"
    .{ .name = "push_in_if_condition", .property = .injection_safe, .source =
    \\import { escapeHtml } from "zttp:text";
    \\import { logInfo } from "zttp:log";
    \\function handler(req: Request): Proof<Response, "injection_safe"> {
    \\  const parts: string[] = [escapeHtml(req.url)];
    \\  if (parts.push(req.url) > 0) { logInfo("x", { n: 1 }); }
    \\  return Response.html(parts.join(""));
    \\}
    },
    // -- A write through an alias of an array.
    // runtime: known-limits row "A write through an alias of an array"
    .{ .name = "alias_variable_push", .property = .injection_safe, .source =
    \\import { escapeHtml } from "zttp:text";
    \\function handler(req: Request): Proof<Response, "injection_safe"> {
    \\  const parts: string[] = [escapeHtml(req.url)];
    \\  const other: string[] = parts;
    \\  other.push(req.url);
    \\  return Response.html(parts.join(""));
    \\}
    },
    // runtime: known-limits row "A write through an alias of an array"
    .{ .name = "alias_object_field_push", .property = .injection_safe, .source =
    \\import { escapeHtml } from "zttp:text";
    \\function handler(req: Request): Proof<Response, "injection_safe"> {
    \\  const parts: string[] = [escapeHtml(req.url)];
    \\  const holder = { items: parts };
    \\  holder.items.push(req.url);
    \\  return Response.html(parts.join(""));
    \\}
    },
    // runtime: known-limits row "A write through an alias of an array" (callback array parameter)
    .{ .name = "alias_callback_array_param", .property = .injection_safe, .source =
    \\import { escapeHtml } from "zttp:text";
    \\function handler(req: Request): Proof<Response, "injection_safe"> {
    \\  const parts: string[] = [escapeHtml(req.url)];
    \\  const out: string[] = parts.map((v: string, i: number, all: string[]): string => { all.push(req.url); return v; });
    \\  return Response.html(parts.join(""));
    \\}
    },
    // -- A write into a later element of the array a callback iterates.
    // runtime: known-limits row "A write into a later element of the array that a forEach ... callback iterates"
    .{ .name = "iterated_array_write_foreach_html", .property = .injection_safe, .source =
    \\import { escapeHtml } from "zttp:text";
    \\function handler(req: Request): Proof<Response, "injection_safe"> {
    \\  const parts: string[] = [escapeHtml(req.url), escapeHtml(req.url)];
    \\  const acc: string[] = [];
    \\  parts.forEach((v: string): number => { parts[1] = req.url; acc.push(v); return 0; });
    \\  return Response.html(acc.join(""));
    \\}
    },
    // runtime: known-limits row "A write into a later element of the array that a ... some ... callback iterates"
    .{ .name = "iterated_array_write_some_html", .property = .injection_safe, .source =
    \\import { escapeHtml } from "zttp:text";
    \\function handler(req: Request): Proof<Response, "injection_safe"> {
    \\  const parts: string[] = [escapeHtml(req.url), escapeHtml(req.url)];
    \\  const acc: string[] = [];
    \\  parts.some((v: string): boolean => { parts[1] = req.url; acc.push(v); return false; });
    \\  return Response.html(acc.join(""));
    \\}
    },
    // runtime: known-limits row "A write into a later element of the array that a forEach ... callback iterates"
    .{ .name = "iterated_array_write_foreach_log", .property = .no_secret_leakage, .source =
    \\import { env } from "zttp:env";
    \\import { logInfo } from "zttp:log";
    \\function handler(req: Request): Proof<Response, "no_secret_leakage"> {
    \\  const secret: string = env("SECRET_KEY") ?? "";
    \\  const parts: string[] = ["a", "b"];
    \\  parts.forEach((v: string): number => { parts[1] = secret; logInfo("m", { v: v }); return 0; });
    \\  return Response.json({ ok: true });
    \\}
    },
    // runtime: known-limits row "A write into a later element of the array that a forEach ... callback iterates" (array literal receiver)
    .{ .name = "iterated_array_write_literal_receiver", .property = .no_secret_leakage, .source =
    \\import { env } from "zttp:env";
    \\import { logInfo } from "zttp:log";
    \\function handler(req: Request): Proof<Response, "no_secret_leakage"> {
    \\  const secret: string = env("SECRET_KEY") ?? "";
    \\  ["a", "b"].forEach((v: string, i: number, all: string[]): number => { if (i === 0) { all[1] = secret; } logInfo("value", { value: v }); return 0; });
    \\  return Response.json({ ok: true });
    \\}
    },
    // -- A `reduce` callback that logs its accumulator.
    // runtime: known-limits row "A reduce callback that logs its accumulator, where the initial value is a secret"
    .{ .name = "reduce_logs_secret_accumulator", .property = .no_secret_leakage, .source =
    \\import { env } from "zttp:env";
    \\import { logInfo } from "zttp:log";
    \\function handler(req: Request): Proof<Response, "no_secret_leakage"> {
    \\  const secret: string = env("SECRET_KEY") ?? "";
    \\  const parts: string[] = ["a", "b"];
    \\  const out: string = parts.reduce((acc: string, v: string): string => { logInfo("m", { v: acc }); return v; }, secret);
    \\  return Response.json({ ok: true });
    \\}
    },
    // -- A callback to `dictMapValues` or `dictFold`.
    // runtime: known-limits row "A callback passed to dictMapValues or dictFold that logs a value"
    .{ .name = "dict_map_values_logs_secret", .property = .no_secret_leakage, .source =
    \\import { env } from "zttp:env";
    \\import { logInfo } from "zttp:log";
    \\import { dictEmpty, dictSet, dictMapValues } from "zttp:collections";
    \\function handler(req: Request): Proof<Response, "no_secret_leakage"> {
    \\  const secret: string = env("SECRET_KEY") ?? "";
    \\  const d = dictSet(dictEmpty(), "k", secret);
    \\  const m = dictMapValues(d, (v: string): number => { logInfo("m", { v: v }); return 1; });
    \\  return Response.json({ ok: true });
    \\}
    },
    // runtime: known-limits row "A callback passed to dictMapValues or dictFold that logs a value"
    .{ .name = "dict_fold_logs_secret", .property = .no_secret_leakage, .source =
    \\import { env } from "zttp:env";
    \\import { logInfo } from "zttp:log";
    \\import { dictEmpty, dictSet, dictFold } from "zttp:collections";
    \\function handler(req: Request): Proof<Response, "no_secret_leakage"> {
    \\  const secret: string = env("SECRET_KEY") ?? "";
    \\  const d = dictSet(dictEmpty(), "k", secret);
    \\  const n = dictFold(d, (acc: number, v: string): number => { logInfo("m", { v: v }); return acc; }, 0);
    \\  return Response.json({ ok: true });
    \\}
    },
    // -- A helper called in an `if` condition that logs a secret.
    // runtime: known-limits row "A helper that is called in an if condition and logs a secret"
    .{ .name = "helper_in_if_condition_logs_secret", .property = .no_secret_leakage, .source =
    \\import { env } from "zttp:env";
    \\import { logInfo } from "zttp:log";
    \\function leaks(s: string): boolean {
    \\  logInfo("m", { value: s });
    \\  return true;
    \\}
    \\export function handler(req: Request): Proof<Response, "no_secret_leakage"> {
    \\  if (leaks(env("SECRET_KEY") ?? "")) {
    \\    return Response.text("yes");
    \\  }
    \\  return Response.text("no");
    \\}
    },
    // -- A request selected by a ternary, or taken back out of an array.
    // runtime: known-limits row "A request that is selected by a ternary"
    .{ .name = "ternary_selected_request_credential", .property = .no_credential_leakage, .source =
    \\export function handler(req: Request): Proof<Response, "no_credential_leakage"> {
    \\  const r: Request = req.url.length > 3 ? req : req;
    \\  return Response.text(r.headers.authorization ?? "");
    \\}
    },
    // runtime: known-limits row "A request taken back out of an array"
    .{ .name = "request_popped_from_array_credential", .property = .no_credential_leakage, .source =
    \\import { logInfo } from "zttp:log";
    \\export function handler(req: Request): Proof<Response, "no_credential_leakage"> {
    \\  const picked: Request | undefined = [req].pop();
    \\  if (picked !== undefined) { logInfo("h", { k: picked.headers.authorization ?? "" }); }
    \\  return Response.json({ ok: true });
    \\}
    },
    // runtime: known-limits row "Response.json(req.headers)"
    .{ .name = "headers_object_to_json_credential", .property = .no_credential_leakage, .source =
    \\export function handler(req: Request): Proof<Response, "no_credential_leakage"> {
    \\  return Response.json(req.headers);
    \\}
    },
    // -- A secret stored with `cacheSet` and read back with `cacheIncr`.
    // runtime: known-limits row "A secret stored with cacheSet and read back with cacheIncr"
    .{ .name = "cache_incr_reads_stored_secret", .property = .no_secret_leakage, .expected = .unproven, .source =
    \\import { env } from "zttp:env";
    \\import { cacheSet, cacheIncr } from "zttp:cache";
    \\export function handler(req: Request): Proof<Response, "no_secret_leakage"> {
    \\  cacheSet("ns", "k", env("SECRET_KEY") ?? "", 60);
    \\  return Response.json(cacheIncr("ns", "k", 0, 60));
    \\}
    },
    // -- A callback selected by an expression.
    // runtime: known-limits row "A callback that is selected by an expression"
    .{ .name = "callback_selected_by_ternary", .property = .no_secret_leakage, .source =
    \\import { env } from "zttp:env";
    \\import { logInfo } from "zttp:log";
    \\function leaks(s: string): boolean {
    \\  logInfo("m", { value: s });
    \\  return true;
    \\}
    \\export function handler(req: Request): Proof<Response, "no_secret_leakage"> {
    \\  [env("SECRET_KEY") ?? ""].forEach(req.url.length > 3 ? leaks : leaks);
    \\  return Response.text("ok");
    \\}
    },
    // -- An `assert` whose message is a secret.
    // runtime: known-limits row "An assert whose message is a secret": a failed assert returns the message as the body
    .{ .name = "assert_message_secret_in_handler", .property = .no_secret_leakage, .source =
    \\import { env } from "zttp:env";
    \\export function handler(req: Request): Proof<Response, "no_secret_leakage"> {
    \\  const s: string = env("SECRET_KEY") ?? "";
    \\  assert req.url.length > 100, s;
    \\  return Response.text("ok");
    \\}
    },
    // runtime: known-limits row "An assert whose message is a secret ... in a helper it calls"
    .{ .name = "assert_message_secret_in_helper", .property = .no_secret_leakage, .source =
    \\import { env } from "zttp:env";
    \\function value(): string {
    \\  assert false, env("SECRET_KEY") ?? "";
    \\  return "";
    \\}
    \\export function handler(req: Request): Proof<Response, "no_secret_leakage"> {
    \\  return Response.text(value());
    \\}
    },
    // -- `unescapeHtml` after `escapeHtml`.
    // runtime: known-limits row "unescapeHtml(escapeHtml(req.url)) sent with Response.html"
    .{ .name = "unescape_after_escape_html", .property = .injection_safe, .source =
    \\import { escapeHtml, unescapeHtml } from "zttp:text";
    \\export function handler(req: Request): Proof<Response, "injection_safe"> {
    \\  const escaped: string = escapeHtml(req.url);
    \\  return Response.html(unescapeHtml(escaped));
    \\}
    },
    // -- `Array.from(secret, f)` where `f` logs.
    // runtime: known-limits row "Array.from(secret, f), where f logs each character"
    .{ .name = "array_from_callback_logs_secret", .property = .no_secret_leakage, .source =
    \\import { env } from "zttp:env";
    \\import { logInfo } from "zttp:log";
    \\export function handler(req: Request): Proof<Response, "no_secret_leakage"> {
    \\  const secret: string = env("SECRET_KEY") ?? "";
    \\  const out: string[] = Array.from(secret, (ch: string): string => { logInfo("c", { k: ch }); return ch; });
    \\  return Response.json({ ok: true });
    \\}
    },
    // -- P1: the persistent-state readers `cacheDelete`, `cacheStats`, `rateReset`, `sqlExec`.
    // runtime: none. Same mechanism as the confirmed `cacheIncr` row.
    .{ .name = "cache_delete_reads_stored_secret", .property = .no_secret_leakage, .expected = .unproven, .source =
    \\import { env } from "zttp:env";
    \\import { cacheSet, cacheDelete } from "zttp:cache";
    \\export function handler(req: Request): Proof<Response, "no_secret_leakage"> {
    \\  cacheSet("ns", "k", env("SECRET_KEY") ?? "", 60);
    \\  return Response.json({ deleted: cacheDelete("ns", "k") });
    \\}
    },
    // runtime: none. Same mechanism as the confirmed `cacheIncr` row.
    .{ .name = "cache_stats_reads_stored_secret", .property = .no_secret_leakage, .expected = .unproven, .source =
    \\import { env } from "zttp:env";
    \\import { cacheSet, cacheStats } from "zttp:cache";
    \\export function handler(req: Request): Proof<Response, "no_secret_leakage"> {
    \\  cacheSet("ns", "k", env("SECRET_KEY") ?? "", 60);
    \\  return Response.json(cacheStats("ns"));
    \\}
    },
    // runtime: none. The key is the stored value; `rateReset` reports whether it was present.
    .{ .name = "rate_reset_reads_secret_key_state", .property = .no_secret_leakage, .expected = .unproven, .source =
    \\import { env } from "zttp:env";
    \\import { rateCheck, rateReset } from "zttp:ratelimit";
    \\export function handler(req: Request): Proof<Response, "no_secret_leakage"> {
    \\  const seen = rateCheck(env("SECRET_KEY") ?? "", 10, 60);
    \\  return Response.json({ reset: rateReset("k") });
    \\}
    },
    // runtime: none. A secret bound into one `sqlExec`; a second reports rows affected.
    .{ .name = "sql_exec_reads_stored_secret", .property = .no_secret_leakage, .expected = .unproven, .sql_schema = "CREATE TABLE t (v TEXT);", .source =
    \\import { env } from "zttp:env";
    \\import { sql, sqlExec } from "zttp:sql";
    \\sql("saveSecret", "INSERT INTO t (v) VALUES (:v)");
    \\sql("purge", "DELETE FROM t");
    \\export function handler(req: Request): Proof<Response, "no_secret_leakage"> {
    \\  const saved = sqlExec("saveSecret", { v: env("SECRET_KEY") ?? "" });
    \\  return Response.json(sqlExec("purge"));
    \\}
    },
    // -- P1: `fetchWithRetry` is an egress sink.
    // runtime: none. `fetchWithRetry` takes the same (url, init) as `fetch`, which the checker refuses.
    .{ .name = "fetch_with_retry_secret_in_url", .property = .no_secret_leakage, .source =
    \\import { env } from "zttp:env";
    \\import { fetchWithRetry } from "zttp:fetch";
    \\export function handler(req: Request): Proof<Response, "no_secret_leakage"> {
    \\  const r = fetchWithRetry("https://api.example.com/x", { query: { k: env("SECRET_KEY") ?? "" } });
    \\  return Response.json({ ok: true });
    \\}
    },
    // runtime: none. Same as above for the request body.
    .{ .name = "fetch_with_retry_secret_in_body", .property = .no_secret_leakage, .source =
    \\import { env } from "zttp:env";
    \\import { fetchWithRetry } from "zttp:fetch";
    \\export function handler(req: Request): Proof<Response, "no_secret_leakage"> {
    \\  const r = fetchWithRetry("https://api.example.com/x", { method: "POST", body: env("SECRET_KEY") ?? "" });
    \\  return Response.json({ ok: true });
    \\}
    },
    // -- P1: `Response.rawJson` takes its value through a binding.
    // runtime: none. `Response.rawJson` sends its first argument as the body.
    .{ .name = "raw_json_secret_through_binding", .property = .no_secret_leakage, .source =
    \\import { env } from "zttp:env";
    \\export function handler(req: Request): Proof<Response, "no_secret_leakage"> {
    \\  const secret: string = env("SECRET_KEY") ?? "";
    \\  const body: string = JSON.stringify({ k: secret });
    \\  return Response.rawJson(body);
    \\}
    },
    // -- A response status computed from a secret.
    // runtime: `zttp serve` sent status 211 for an 11-byte SECRET_KEY.
    .{ .name = "status_from_secret_length_json", .property = .no_secret_leakage, .source =
    \\import { env } from "zttp:env";
    \\export function handler(req: Request): Proof<Response, "no_secret_leakage"> {
    \\  const secret: string = env("SECRET_KEY") ?? "";
    \\  return Response.json({ ok: true }, { status: 200 + secret.length });
    \\}
    },
    // runtime: none. `Response.rawJson` reads `status` the same way as `Response.json`.
    .{ .name = "status_from_secret_length_raw_json", .property = .no_secret_leakage, .source =
    \\import { env } from "zttp:env";
    \\export function handler(req: Request): Proof<Response, "no_secret_leakage"> {
    \\  const secret: string = env("SECRET_KEY") ?? "";
    \\  return Response.rawJson("{}", { status: 200 + secret.length });
    \\}
    },
    // runtime: none. The same status built in a helper that returns the Response.
    .{ .name = "status_from_secret_length_in_helper", .property = .no_secret_leakage, .source =
    \\import { env } from "zttp:env";
    \\function reply(n: number): Response {
    \\  return Response.text("ok", { status: 200 + n });
    \\}
    \\export function handler(req: Request): Proof<Response, "no_secret_leakage"> {
    \\  const secret: string = env("SECRET_KEY") ?? "";
    \\  return reply(secret.length);
    \\}
    },
    // runtime: none. The same status in a route that `routerMatch` dispatches.
    .{ .name = "status_from_secret_length_in_route", .property = .no_secret_leakage, .source =
    \\import { env } from "zttp:env";
    \\import { routerMatch } from "zttp:router";
    \\function leak(req: Request): Response {
    \\  const secret: string = env("SECRET_KEY") ?? "";
    \\  return Response.json({ ok: true }, { status: 200 + secret.length });
    \\}
    \\const routes = { "GET /leak": leak };
    \\export function handler(req: Request): Proof<Response, "no_secret_leakage"> {
    \\  const found = routerMatch(routes, req);
    \\  if (found === undefined) { return Response.json({ error: "not found" }); }
    \\  return found.handler(req);
    \\}
    },
    // -- renderToString writes some parts of a vnode unescaped.
    // runtime: `zttp serve` answered `<script></script><img src=x onerror=alert(1)></script>`
    // for the body `</script><img src=x onerror=alert(1)>`.
    .{ .name = "render_script_child_from_input", .property = .injection_safe, .source =
    \\export function handler(req: Request): Proof<Response, "injection_safe"> {
    \\  const q = requestText(req);
    \\  const text = match (q) { when { ok: true, value: v }: v default: "" };
    \\  return Response.html(renderToString(h("script", {}, text)));
    \\}
    },
    // runtime: `zttp serve` answered `<img src=x onerror=alert(1)></img src=x onerror=alert(1)>`
    // for the body `img src=x onerror=alert(1)`.
    .{ .name = "render_tag_from_input", .property = .injection_safe, .source =
    \\export function handler(req: Request): Proof<Response, "injection_safe"> {
    \\  const q = requestText(req);
    \\  const text = match (q) { when { ok: true, value: v }: v default: "" };
    \\  return Response.html(renderToString(h(text, {})));
    \\}
    },
};

/// Clean contrasts. Each handler is the same shape as a fixture above with no
/// labelled value on the path, and its property must stay proven. A fix that
/// refuses every handler of a shape would otherwise pass the fixtures.
pub const contrasts = [_]Fixture{
    // runtime: none.
    .{ .name = "fetch_with_retry_clean_contrast", .property = .no_secret_leakage, .expected = .held, .source =
    \\import { env } from "zttp:env";
    \\import { fetchWithRetry } from "zttp:fetch";
    \\export function handler(req: Request): Proof<Response, "no_secret_leakage"> {
    \\  const r = fetchWithRetry("https://api.example.com/x", { method: "POST", body: env("REGION") ?? "" });
    \\  return Response.json({ ok: true });
    \\}
    },
    // runtime: none.
    .{ .name = "raw_json_clean_contrast", .property = .no_secret_leakage, .expected = .held, .source =
    \\import { env } from "zttp:env";
    \\export function handler(req: Request): Proof<Response, "no_secret_leakage"> {
    \\  const region: string = env("REGION") ?? "";
    \\  const body: string = JSON.stringify({ k: region });
    \\  return Response.rawJson(body);
    \\}
    },
    // runtime: none.
    .{ .name = "status_literal_clean_contrast", .property = .no_secret_leakage, .expected = .held, .source =
    \\import { env } from "zttp:env";
    \\export function handler(req: Request): Proof<Response, "no_secret_leakage"> {
    \\  const region: string = env("REGION") ?? "";
    \\  return Response.json({ region: region }, { status: 404 });
    \\}
    },
    // runtime: none.
    .{ .name = "render_literal_clean_contrast", .property = .injection_safe, .expected = .held, .source =
    \\export function handler(req: Request): Proof<Response, "injection_safe"> {
    \\  return Response.html(renderToString(h("p", {}, "ready")));
    \\}
    },
};

/// Run one fixture through the typed pipeline and read the verdict for its
/// property. A fixture that reaches no flow verdict fails the test with the
/// reason, since a vacuous run establishes no semantic regression.
fn observe(allocator: std.mem.Allocator, fixture: Fixture) !gate.Observed {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var schema_path: ?[:0]u8 = null;
    defer if (schema_path) |path| allocator.free(path);
    if (fixture.sql_schema) |schema| {
        try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "schema.sql", .data = schema });
        schema_path = try tmp.dir.realPathFileAlloc(std.testing.io, "schema.sql", allocator);
    }

    var result = try precompile.runCheckOnlyFromSourceWithOptions(
        allocator,
        fixture.source,
        "flow-false-proof.ts",
        .{ .json_mode = true, .sql_schema_path = schema_path },
    );
    defer result.deinit(allocator);

    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();
    const verdict = try gate.classify(arena.allocator(), &result, fixture.property);
    if (verdict.observed == .no_verdict) {
        std.debug.print("fixture {s} reached no flow verdict: {s}\n", .{ fixture.name, verdict.detail });
        return error.FixtureReachedNoVerdict;
    }
    return verdict.observed;
}

test "fixture names are unique and the fixture count meets the floor" {
    try std.testing.expectEqual(minimum_fixtures, fixtures.len);
    try std.testing.expectEqual(@as(usize, 4), contrasts.len);
    for (fixtures, 0..) |a, i| {
        for (fixtures[i + 1 ..]) |b| {
            try std.testing.expect(!std.mem.eql(u8, a.name, b.name));
        }
    }
}

test "permanent unsafe fixtures retain exact refused or unproven verdicts" {
    const allocator = std.testing.allocator;
    var checked: usize = 0;
    for (fixtures) |fixture| {
        try std.testing.expect(fixture.expected == .refused or fixture.expected == .unproven);
        const observed = try observe(allocator, fixture);
        if (observed != fixture.expected) {
            std.debug.print("fixture {s}: expected {s} for {s}, observed {s}\n", .{ fixture.name, @tagName(fixture.expected), @tagName(fixture.property), @tagName(observed) });
        }
        try std.testing.expectEqual(fixture.expected, observed);
        checked += 1;
    }
    try std.testing.expectEqual(minimum_fixtures, checked);
}

test "a clean contrast keeps its property proven" {
    const allocator = std.testing.allocator;
    try std.testing.expectEqual(@as(usize, 4), contrasts.len);
    for (contrasts) |contrast| {
        try std.testing.expectEqual(gate.Observed.held, contrast.expected);
        const observed = try observe(allocator, contrast);
        if (observed != .held) {
            std.debug.print("contrast {s} no longer proves {s}\n", .{ contrast.name, @tagName(contrast.property) });
        }
        try std.testing.expectEqual(gate.Observed.held, observed);
    }
}
