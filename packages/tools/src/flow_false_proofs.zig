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
//! `false_proofs` is a second, separate table. It names the fixtures the
//! current checker still proves falsely. Two tests read it:
//!   * every fixture outside the table must leave its property unproven, so
//!     a regression in a fixed shape fails;
//!   * the fixtures whose property holds today must equal the table exactly,
//!     so a fix to the checker forces a table edit in the same change and the
//!     table can only shrink.
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
    /// Unique. The `false_proofs` table names fixtures by this string.
    name: []const u8,
    /// The property the fixture must NOT prove.
    property: Property,
    source: []const u8,
    /// A SQL schema for a handler that registers `zttp:sql` queries. The check
    /// refuses such a handler without one (`MissingSqlSchema`).
    sql_schema: ?[]const u8 = null,
};

/// The count of fixtures at the time this file was written. The floor makes a
/// deleted fixture a test failure instead of a silent loss.
const minimum_fixtures: usize = 32;

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
    .{ .name = "cache_incr_reads_stored_secret", .property = .no_secret_leakage, .source =
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
    .{ .name = "cache_delete_reads_stored_secret", .property = .no_secret_leakage, .source =
    \\import { env } from "zttp:env";
    \\import { cacheSet, cacheDelete } from "zttp:cache";
    \\export function handler(req: Request): Proof<Response, "no_secret_leakage"> {
    \\  cacheSet("ns", "k", env("SECRET_KEY") ?? "", 60);
    \\  return Response.json({ deleted: cacheDelete("ns", "k") });
    \\}
    },
    // runtime: none. Same mechanism as the confirmed `cacheIncr` row.
    .{ .name = "cache_stats_reads_stored_secret", .property = .no_secret_leakage, .source =
    \\import { env } from "zttp:env";
    \\import { cacheSet, cacheStats } from "zttp:cache";
    \\export function handler(req: Request): Proof<Response, "no_secret_leakage"> {
    \\  cacheSet("ns", "k", env("SECRET_KEY") ?? "", 60);
    \\  return Response.json(cacheStats("ns"));
    \\}
    },
    // runtime: none. The key is the stored value; `rateReset` reports whether it was present.
    .{ .name = "rate_reset_reads_secret_key_state", .property = .no_secret_leakage, .source =
    \\import { env } from "zttp:env";
    \\import { rateCheck, rateReset } from "zttp:ratelimit";
    \\export function handler(req: Request): Proof<Response, "no_secret_leakage"> {
    \\  const seen = rateCheck(env("SECRET_KEY") ?? "", 10, 60);
    \\  return Response.json({ reset: rateReset("k") });
    \\}
    },
    // runtime: none. A secret bound into one `sqlExec`; a second reports rows affected.
    .{ .name = "sql_exec_reads_stored_secret", .property = .no_secret_leakage, .sql_schema = "CREATE TABLE t (v TEXT);", .source =
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
};

/// Clean contrasts. Each handler is the same shape as a fixture above with no
/// labelled value on the path, and its property must stay proven. A fix that
/// refuses every handler of a shape would otherwise pass the fixtures.
pub const contrasts = [_]Fixture{
    // runtime: none.
    .{ .name = "fetch_with_retry_clean_contrast", .property = .no_secret_leakage, .source =
    \\import { env } from "zttp:env";
    \\import { fetchWithRetry } from "zttp:fetch";
    \\export function handler(req: Request): Proof<Response, "no_secret_leakage"> {
    \\  const r = fetchWithRetry("https://api.example.com/x", { method: "POST", body: env("REGION") ?? "" });
    \\  return Response.json({ ok: true });
    \\}
    },
    // runtime: none.
    .{ .name = "raw_json_clean_contrast", .property = .no_secret_leakage, .source =
    \\import { env } from "zttp:env";
    \\export function handler(req: Request): Proof<Response, "no_secret_leakage"> {
    \\  const region: string = env("REGION") ?? "";
    \\  const body: string = JSON.stringify({ k: region });
    \\  return Response.rawJson(body);
    \\}
    },
};

/// The fixtures the current checker still proves falsely: the claimed
/// property holds and the handler leaks. Each fixture leaves this table in the
/// same change that makes its expectation hold, and it is never deleted from
/// `fixtures`. The table can only shrink.
const false_proofs = [_][]const u8{
    "branch_assign_raw_then",
    "branch_assign_raw_initial",
    "loop_carried_scalar",
    "push_in_initializer",
    "push_in_if_condition",
    "alias_variable_push",
    "alias_object_field_push",
    "alias_callback_array_param",
    "iterated_array_write_foreach_html",
    "iterated_array_write_some_html",
    "iterated_array_write_foreach_log",
    "iterated_array_write_literal_receiver",
    "reduce_logs_secret_accumulator",
    "dict_map_values_logs_secret",
    "dict_fold_logs_secret",
    "helper_in_if_condition_logs_secret",
    "ternary_selected_request_credential",
    "request_popped_from_array_credential",
    "headers_object_to_json_credential",
    "callback_selected_by_ternary",
    "assert_message_secret_in_handler",
    "assert_message_secret_in_helper",
    "unescape_after_escape_html",
    "array_from_callback_logs_secret",
};

fn inFalseProofTable(name: []const u8) bool {
    for (false_proofs) |entry| {
        if (std.mem.eql(u8, entry, name)) return true;
    }
    return false;
}

/// Run one fixture through the typed pipeline and read the verdict for its
/// property. A fixture that reaches no flow verdict fails the test with the
/// reason, since a vacuous run would satisfy both tables.
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
    try std.testing.expect(fixtures.len >= minimum_fixtures);
    for (fixtures, 0..) |a, i| {
        for (fixtures[i + 1 ..]) |b| {
            try std.testing.expect(!std.mem.eql(u8, a.name, b.name));
        }
    }
}

test "every false-proof table entry names a fixture, once" {
    try std.testing.expect(false_proofs.len <= fixtures.len);
    for (false_proofs, 0..) |entry, i| {
        var found = false;
        for (fixtures) |fixture| {
            if (std.mem.eql(u8, fixture.name, entry)) found = true;
        }
        if (!found) std.debug.print("false-proof entry {s} names no fixture\n", .{entry});
        try std.testing.expect(found);
        for (false_proofs[i + 1 ..]) |other| {
            try std.testing.expect(!std.mem.eql(u8, entry, other));
        }
    }
}

test "a fixture outside the false-proof table leaves its property unproven" {
    const allocator = std.testing.allocator;
    var checked: usize = 0;
    for (fixtures) |fixture| {
        if (inFalseProofTable(fixture.name)) continue;
        const observed = try observe(allocator, fixture);
        if (observed == .held) {
            std.debug.print("fixture {s} proves {s} and is not in the false-proof table\n", .{ fixture.name, @tagName(fixture.property) });
        }
        try std.testing.expect(observed != .held);
        checked += 1;
    }
    try std.testing.expectEqual(fixtures.len - false_proofs.len, checked);
}

test "the fixtures whose property holds today equal the false-proof table" {
    const allocator = std.testing.allocator;
    var held_in_table: usize = 0;
    var failures: usize = 0;
    for (fixtures) |fixture| {
        const observed = try observe(allocator, fixture);
        const listed = inFalseProofTable(fixture.name);
        if ((observed == .held) != listed) {
            failures += 1;
            if (listed) {
                std.debug.print("fixture {s} is in the false-proof table and its property no longer holds: remove it\n", .{fixture.name});
            } else {
                std.debug.print("fixture {s} proves {s} and is missing from the false-proof table\n", .{ fixture.name, @tagName(fixture.property) });
            }
        }
        if (observed == .held and listed) held_in_table += 1;
    }
    try std.testing.expectEqual(@as(usize, 0), failures);
    try std.testing.expectEqual(false_proofs.len, held_in_table);
}

test "a clean contrast keeps its property proven" {
    const allocator = std.testing.allocator;
    try std.testing.expect(contrasts.len >= 2);
    for (contrasts) |contrast| {
        const observed = try observe(allocator, contrast);
        if (observed != .held) {
            std.debug.print("contrast {s} no longer proves {s}\n", .{ contrast.name, @tagName(contrast.property) });
        }
        try std.testing.expectEqual(gate.Observed.held, observed);
    }
}
