//! Handler drafts that deliberately fail the veto, and the fix for each.
//!
//! The ordinary stand-in drafts are authored to pass the same veto that judges
//! them. These seeds deliberately do the opposite so the failed tool result,
//! retry nudge, salvage-on-reject, and compiler-authored repair lane are all
//! reachable without a model.
//!
//! A seed declares which of those outcomes its bad draft produces. The
//! declaration is not trusted: the gate in `standin_range_tests.zig` derives the
//! class by running the real veto over the real bytes, so a canonicalizer or a
//! repair lane that later learns a new fix fails the gate and the class is moved
//! deliberately rather than drifting.
//!
//! The seed source must be veto-clean, and the gate asserts it. The veto is
//! differential - `ok` is `new_count == 0` - so a seed that already carried its
//! own defect would make the defect pre-existing, the bad draft would pass, and
//! the arm would test nothing while reporting a clean run.

const std = @import("std");

/// What the loop does with a rejected draft. These are outcomes, not rule
/// categories: the same diagnostic could change class if the canonicalizer grows
/// a rewriter for it, which is why the gate re-derives rather than reads.
pub const VetoClass = enum {
    /// Normalize-on-reject clears it, the canonicalized bytes are applied, and
    /// the turn still counts as a first-draft pass. The model never sees a
    /// rejection.
    salvaged,
    /// Neither salvage nor the repair lane applies, so the draft is bounced and
    /// the model redrafts. This is the arm that exercises the retry path.
    model_retry,
    /// The compiler-native repair lane authors a verified candidate and the
    /// loop applies it without asking the model for another draft.
    compiler_repair,
};

pub const DefectSeed = struct {
    id: []const u8,
    /// The diagnostic the bad draft introduces. Not required to be a
    /// `rule_registry` entry: the parser, stripper, and type-checker families
    /// carry no registry row, and they are where the non-salvageable rejections
    /// live. The gate proves the code by observing it, and reports how many
    /// seeds sit inside the hashed registry and how many outside.
    code: []const u8,
    class: VetoClass,
    /// A handler the veto accepts. The baseline every draft below is measured
    /// against.
    seed_source: []const u8,
    /// Introduces exactly `code` as a NEW violation against `seed_source`.
    bad_draft: []const u8,
    /// Passes the veto with no new violation. Unused by the salvage class, whose
    /// arm never reaches a second draft, and asserted for every seed anyway so a
    /// class change cannot leave one unchecked.
    good_draft: []const u8,
    /// The ask that selects this seed. Must classify to `violation_fix`.
    ask: []const u8,
};

const clean_total =
    \\function handler(req: Request): Proof<Response, "deterministic"> {
    \\  const total = 1;
    \\  return Response.json({ total: total });
    \\}
    \\
;

const clean_reassigned =
    \\function handler(req: Request): Proof<Response, "deterministic"> {
    \\  let total = 1;
    \\  total = total + 2;
    \\  return Response.json({ total: total });
    \\}
    \\
;

const clean_checked_result =
    \\import { validateJson } from "zttp:validate";
    \\
    \\function handler(req: Request): Proof<Response, "deterministic"> {
    \\  const result = validateJson("item", req.body ?? "");
    \\  if (!result.ok) return Response.json({ error: result.error }, { status: 400 });
    \\  const data = result.value;
    \\  return Response.json({ data: data });
    \\}
    \\
;

const clean_checked_optional =
    \\import { env } from "zttp:env";
    \\
    \\function handler(req: Request): Proof<Response, "deterministic"> {
    \\  const appName = env("APP_NAME");
    \\  if (appName === undefined) return Response.json({ error: "missing value" }, { status: 400 });
    \\  return Response.json({ appName: appName });
    \\}
    \\
;

const clean_bool =
    \\function handler(req: Request): Proof<Response, "deterministic"> {
    \\  const ready = true;
    \\  if (ready) { return Response.json({ ready: 1 }); }
    \\  return Response.json({ ready: 0 });
    \\}
    \\
;

const clean_ternary =
    \\function pick(): number {
    \\  return 7;
    \\}
    \\
    \\function handler(req: Request): Proof<Response, "deterministic"> {
    \\  const ready = true;
    \\  const picked = pick();
    \\  const status = ready ? picked : 5;
    \\  return Response.json({ status: status });
    \\}
    \\
;

const clean_tier =
    \\function pickTier(a: boolean, b: boolean): number {
    \\  if (a) { return 1; }
    \\  if (b) { return 2; }
    \\  return 3;
    \\}
    \\
    \\function handler(req: Request): Proof<Response, "deterministic"> {
    \\  const tier = pickTier(true, false);
    \\  return Response.json({ tier: tier });
    \\}
    \\
;

const clean_spread =
    \\function handler(req: Request): Proof<Response, "deterministic"> {
    \\  const base = { a: 1 };
    \\  const next = { ...base, status: "ok" };
    \\  return Response.json({ next: next });
    \\}
    \\
;

const clean_send =
    \\function send(a: number): number {
    \\  return a + a;
    \\}
    \\
    \\function handler(req: Request): Proof<Response, "deterministic"> {
    \\  const args = [1];
    \\  const sent = send(args[0]);
    \\  return Response.json({ sent: sent });
    \\}
    \\
;

const clean_named_helper =
    \\function double(x: number): number {
    \\  return x + x;
    \\}
    \\
    \\function handler(req: Request): Proof<Response, "deterministic"> {
    \\  const a = double(2);
    \\  const b = double(3);
    \\  return Response.json({ a: a, b: b });
    \\}
    \\
;

// The handler itself, exported. A helper would need a record alias on its
// signature to clear ZTS061, and the exported handler is both simpler and the
// exact shape rule_registry gives as ZTS609's example.
const clean_exported_handler =
    \\export function handler(req: Request): Proof<Response, "deterministic"> {
    \\  return Response.json({ ok: 1 });
    \\}
    \\
;

const clean_nullable =
    \\structural MaybeName = string | null;
    \\
    \\function nameOf(): MaybeName {
    \\  return null;
    \\}
    \\
    \\function handler(req: Request): Proof<Response, "deterministic"> {
    \\  const n = nameOf();
    \\  if (n === null) { return Response.json({ name: "anon" }); }
    \\  return Response.json({ name: n });
    \\}
    \\
;

const clean_match =
    \\structural Msg = { kind: string, text: string };
    \\
    \\function handler(req: Request): Proof<Response, "deterministic"> {
    \\  const msg: Msg = { kind: "echo", text: "hi" };
    \\  const out = match (msg) {
    \\    when { kind: "echo", text }: text
    \\    default: "none"
    \\  };
    \\  return Response.json({ out: out });
    \\}
    \\
;

const clean_plain =
    \\function handler(req: Request): Proof<Response, "deterministic"> {
    \\  return Response.json({ ok: 1 });
    \\}
    \\
;

const clean_local_count =
    \\function handler(req: Request): Proof<Response, "deterministic"> {
    \\  const count = 1;
    \\  return Response.json({ count: count });
    \\}
    \\
;

const clean_collect =
    \\function handler(req: Request): Proof<Response, "deterministic"> {
    \\  const items = [1, 2];
    \\  const out = [];
    \\  for (const item of items) {
    \\    out.push(item);
    \\  }
    \\  return Response.json({ out: out });
    \\}
    \\
;

const clean_literal_access =
    \\import { env } from "zttp:env";
    \\
    \\function handler(req: Request): Proof<Response, "deterministic"> {
    \\  const obj = { a: 1 };
    \\  const v = obj.a;
    \\  return Response.json({ v: v });
    \\}
    \\
;

const clean_literal_capability =
    \\import { env } from "zttp:env";
    \\
    \\function handler(req: Request): Proof<Response, "deterministic"> {
    \\  const v = env("APP_NAME") ?? "x";
    \\  return Response.json({ v: v });
    \\}
    \\
;

const clean_narrowed_optional =
    \\import { env } from "zttp:env";
    \\
    \\function handler(req: Request): Proof<Response, "deterministic"> {
    \\  const name = env("APP_NAME");
    \\  if (name === undefined) { return Response.json({ n: 0 }); }
    \\  return Response.json({ n: name.length });
    \\}
    \\
;

const clean_all_paths_return =
    \\function handler(req: Request): Proof<Response, "deterministic"> {
    \\  const ready = true;
    \\  if (ready) { return Response.json({ ok: 1 }); }
    \\  return Response.json({ ok: 0 });
    \\}
    \\
;

const clean_secret_unleaked =
    \\import { env } from "zttp:env";
    \\
    \\function handler(req: Request): Proof<Response, "deterministic"> {
    \\  const token = env("API_TOKEN") ?? "";
    \\  if (token === "") { return Response.json({ ok: 0 }); }
    \\  return Response.json({ ok: 1 });
    \\}
    \\
;

const clean_credential_unleaked =
    \\function handler(req: Request): Proof<Response, "deterministic"> {
    \\  const auth = req.headers.authorization ?? "";
    \\  if (auth === "") { return Response.json({ ok: 0 }); }
    \\  return Response.json({ ok: 1 });
    \\}
    \\
;

const clean_secret_and_log =
    \\import { env } from "zttp:env";
    \\import { logInfo } from "zttp:log";
    \\
    \\function handler(req: Request): Proof<Response, "deterministic"> {
    \\  const token = env("API_TOKEN") ?? "";
    \\  logInfo("checked", { n: 1 });
    \\  if (token === "") { return Response.json({ ok: 0 }); }
    \\  return Response.json({ ok: 1 });
    \\}
    \\
;

const clean_credential_and_log =
    \\import { logInfo } from "zttp:log";
    \\
    \\function handler(req: Request): Proof<Response, "deterministic"> {
    \\  const auth = req.headers.authorization ?? "";
    \\  logInfo("checked", { n: 1 });
    \\  if (auth === "") { return Response.json({ ok: 0 }); }
    \\  return Response.json({ ok: 1 });
    \\}
    \\
;

const clean_secret_and_egress =
    \\import { env } from "zttp:env";
    \\import { fetch } from "zttp:fetch";
    \\
    \\function handler(req: Request): Proof<Response, "deterministic"> {
    \\  const token = env("API_TOKEN") ?? "";
    \\  const r = fetch("https://api.example.com/v1", { method: "POST", body: "ping" });
    \\  if (token === "") { return Response.json({ ok: 0 }); }
    \\  return Response.json({ s: r.status });
    \\}
    \\
;

// ---------------------------------------------------------------------------
// Baselines for the rule-coverage seeds below. Each is veto-clean and stable
// under the canonicalizer, which the gate asserts before it reads any draft.
// ---------------------------------------------------------------------------

const clean_plain_ok =
    \\function handler(req: Request): Proof<Response, "deterministic"> {
    \\  return Response.json({ ok: 1 });
    \\}
    \\
;

const clean_read_only =
    \\function handler(req: Request): Proof<Response, "read_only"> {
    \\  return Response.json({ v: "ok" });
    \\}
    \\
;

const clean_count =
    \\function handler(req: Request): Proof<Response, "deterministic"> {
    \\  const count = 1;
    \\  return Response.json({ count: count });
    \\}
    \\
;

const clean_exported_only_handler =
    \\export function handler(req: Request): Proof<Response, "deterministic"> {
    \\  return Response.json({ ok: 1 });
    \\}
    \\
;

const clean_annotated_helper =
    \\function scale(x: number): number {
    \\  return x + x;
    \\}
    \\
    \\function handler(req: Request): Proof<Response, "deterministic"> {
    \\  const v = scale(1);
    \\  return Response.json({ v: v });
    \\}
    \\
;

const clean_match_default =
    \\function handler(req: Request): Proof<Response, "deterministic"> {
    \\  const n = 3;
    \\  const out = match (n) {
    \\    when 1: "one"
    \\    default: "other"
    \\  };
    \\  return Response.json({ out: out });
    \\}
    \\
;

const clean_crypto_budget =
    \\import { sha256 } from "zttp:crypto";
    \\
    \\function handler(req: Request): Proof<Effects<Response, "crypto">, "deterministic"> {
    \\  return Response.text(sha256("zttp"));
    \\}
    \\
;

const clean_handler_log_budget =
    \\import { logInfo } from "zttp:log";
    \\
    \\structural Narrow<T> = Proof<T,
    \\    | "deterministic"
    \\    | "state_isolated"
    \\    | "result_safe"
    \\    | "optional_safe"
    \\    | "no_secret_leakage"
    \\    | "no_credential_leakage"
    \\    | "input_validated"
    \\    | "injection_safe"
    \\    | "canonical"
    \\    | "cost_bounded"
    \\>;
    \\
    \\function handler(req: Request): Narrow<Effects<Response, "stderr" | "clock">> {
    \\  logInfo("hit", { n: 1 });
    \\  return Response.text("ok");
    \\}
    \\
;

const clean_helper_log_ceiling =
    \\import { sha256 } from "zttp:crypto";
    \\import { logInfo } from "zttp:log";
    \\
    \\structural Narrow<T> = Proof<T,
    \\    | "deterministic"
    \\    | "state_isolated"
    \\    | "result_safe"
    \\    | "optional_safe"
    \\    | "no_secret_leakage"
    \\    | "no_credential_leakage"
    \\    | "input_validated"
    \\    | "injection_safe"
    \\    | "canonical"
    \\    | "cost_bounded"
    \\>;
    \\
    \\structural Digest = { value: string };
    \\
    \\export function digest(input: Digest): Proof<Effects<Digest, "crypto" | "stderr" | "clock">, "deterministic"> {
    \\  sha256(input.value);
    \\  logInfo("digest", { n: 1 });
    \\  return input;
    \\}
    \\
    \\function handler(req: Request): Narrow<Effects<Response, "crypto" | "stderr" | "clock">> {
    \\  const d = digest({ value: "zttp" });
    \\  return Response.text(d.value);
    \\}
    \\
;

const clean_exported_helper_capsule =
    \\import { sha256 } from "zttp:crypto";
    \\
    \\structural Narrow<T> = Proof<T,
    \\    | "deterministic"
    \\    | "state_isolated"
    \\    | "result_safe"
    \\    | "optional_safe"
    \\    | "no_secret_leakage"
    \\    | "no_credential_leakage"
    \\    | "input_validated"
    \\    | "injection_safe"
    \\    | "canonical"
    \\    | "cost_bounded"
    \\>;
    \\
    \\structural Digest = { value: string };
    \\
    \\export function digest(input: Digest): Proof<Effects<Digest, "crypto">, "deterministic"> {
    \\  sha256(input.value);
    \\  return input;
    \\}
    \\
    \\function handler(req: Request): Narrow<Effects<Response, "crypto">> {
    \\  const d = digest({ value: "zttp" });
    \\  return Response.text(d.value);
    \\}
    \\
;

const clean_internal_no_ceiling =
    \\import { sha256 } from "zttp:crypto";
    \\
    \\structural Narrow<T> = Proof<T,
    \\    | "deterministic"
    \\    | "state_isolated"
    \\    | "result_safe"
    \\    | "optional_safe"
    \\    | "no_secret_leakage"
    \\    | "no_credential_leakage"
    \\    | "input_validated"
    \\    | "injection_safe"
    \\    | "canonical"
    \\    | "cost_bounded"
    \\>;
    \\
    \\function digest(s: string): string {
    \\  sha256(s);
    \\  return s;
    \\}
    \\
    \\function handler(req: Request): Narrow<Effects<Response, "crypto">> {
    \\  return Response.text(digest("zttp"));
    \\}
    \\
;

const clean_deterministic_helper =
    \\function stamp(): number {
    \\  return 7;
    \\}
    \\
    \\function handler(req: Request): Proof<Response, "deterministic"> {
    \\  const t = stamp();
    \\  return Response.json({ t: t, n: 1 });
    \\}
    \\
;

const clean_resolvable_callee =
    \\import { sha256 } from "zttp:crypto";
    \\
    \\structural Maker = { make: () => string };
    \\
    \\function build(): Maker {
    \\  return { make: () => sha256("zttp") };
    \\}
    \\
    \\function handler(req: Request): Proof<Effects<Response, "crypto">, "state_isolated"> {
    \\  const m = build();
    \\  return Response.text(m.make());
    \\}
    \\
;

const clean_secret_and_headers =
    \\import { env } from "zttp:env";
    \\import { fetch } from "zttp:fetch";
    \\
    \\function handler(req: Request): Proof<Response, "deterministic"> {
    \\  const token = env("SECRET_KEY") ?? "";
    \\  const r = fetch("https://api.example.com/v1", { headers: { "x-tag": "static" } });
    \\  if (token === "") { return Response.json({ ok: 0 }); }
    \\  return Response.json({ s: r.status });
    \\}
    \\
;

const clean_credential_and_headers =
    \\import { fetch } from "zttp:fetch";
    \\
    \\function handler(req: Request): Proof<Response, "deterministic"> {
    \\  const auth = req.headers.authorization ?? "";
    \\  const r = fetch("https://api.example.com/v1", { headers: { "x-tag": "static" } });
    \\  if (auth === "") { return Response.json({ ok: 0 }); }
    \\  return Response.json({ s: r.status });
    \\}
    \\
;

const clean_html_no_input =
    \\function handler(req: Request): Proof<Response, "deterministic"> {
    \\  const q = req.url;
    \\  if (q === "") { return Response.html("<p>none</p>"); }
    \\  return Response.html("<p>static</p>");
    \\}
    \\
;

const clean_durable_step =
    \\import { run, step } from "zttp:durable";
    \\
    \\function handler(req: Request): Proof<object, "state_isolated"> {
    \\  return run("step-demo", () => step("one", () => { return { ok: 1 }; }));
    \\}
    \\
;

const clean_saga_compensated =
    \\import { run } from "zttp:durable";
    \\import { call, saga } from "zttp:workflow";
    \\
    \\function handler(req: Request): Proof<object, "state_isolated"> {
    \\  return run("saga-demo", () => saga([
    \\    {
    \\      name: "reserve",
    \\      run: () => call("greet", { path: "/reserve" }),
    \\      compensate: () => call("greet", { path: "/release" }),
    \\    },
    \\    { name: "ship", run: () => call("greet", { path: "/ship" }) },
    \\  ]));
    \\}
    \\
;

const clean_dict_entries =
    \\import { dictEntries, dictFromEntries } from "zttp:collections";
    \\
    \\function handler(req: Request): Proof<Response, "deterministic"> {
    \\  const built = dictFromEntries([["a", 1], ["b", 2]]);
    \\  if (!built.ok) { return Response.json({ error: "bad" }, { status: 400 }); }
    \\  const d = built.value;
    \\  if (!isDict(d)) { return Response.json({ error: "not-a-dict" }, { status: 400 }); }
    \\  const pairs = dictEntries(d);
    \\  return Response.json({ n: pairs.length });
    \\}
    \\
;
pub const seeds = [_]DefectSeed{
    .{
        .id = "let-binding",
        .code = "ZTS604",
        .class = .salvaged,
        .seed_source = clean_total,
        // The value differs from the baseline on purpose. A draft that is the
        // baseline plus one canonical slip canonicalizes back to the baseline
        // exactly, and then "salvage rewrote the draft" and "the draft was
        // discarded and the baseline rewritten" produce identical bytes on disk
        // and no gate can tell them apart.
        .bad_draft =
        \\function handler(req: Request): Proof<Response, "deterministic"> {
        \\  let total = 5;
        \\  return Response.json({ total: total });
        \\}
        \\
        ,
        .good_draft =
        \\function handler(req: Request): Proof<Response, "deterministic"> {
        \\  const total = 2;
        \\  return Response.json({ total: total });
        \\}
        \\
        ,
        .ask = "Fix the ZTS604 compiler error in handler.ts",
    },
    .{
        .id = "compound-assign",
        .code = "ZTS613",
        .class = .salvaged,
        .seed_source = clean_reassigned,
        // Likewise: `+= 7` canonicalizes to `total = total + 7`, which the
        // baseline's `+ 2` does not match.
        .bad_draft =
        \\function handler(req: Request): Proof<Response, "deterministic"> {
        \\  let total = 1;
        \\  total += 7;
        \\  return Response.json({ total: total });
        \\}
        \\
        ,
        .good_draft =
        \\function handler(req: Request): Proof<Response, "deterministic"> {
        \\  let total = 1;
        \\  total = total + 3;
        \\  return Response.json({ total: total });
        \\}
        \\
        ,
        .ask = "Fix the ZTS613 compiler error in handler.ts",
    },
    .{
        .id = "var-binding",
        .code = "ZTS001",
        .class = .model_retry,
        .seed_source = clean_total,
        .bad_draft =
        \\function handler(req: Request): Proof<Response, "deterministic"> {
        \\  var total = 1;
        \\  return Response.json({ total: total });
        \\}
        \\
        ,
        .good_draft =
        \\function handler(req: Request): Proof<Response, "deterministic"> {
        \\  const total = 3;
        \\  return Response.json({ total: total });
        \\}
        \\
        ,
        .ask = "Fix the ZTS001 compiler error in handler.ts",
    },
    .{
        .id = "dead-code",
        .code = "ZTS304",
        .class = .model_retry,
        .seed_source = clean_total,
        .bad_draft =
        \\function handler(req: Request): Proof<Response, "deterministic"> {
        \\  const total = 1;
        \\  return Response.json({ total: total });
        \\  const unreachable_total = 2;
        \\}
        \\
        ,
        .good_draft =
        \\function handler(req: Request): Proof<Response, "deterministic"> {
        \\  const total = 4;
        \\  return Response.json({ total: total });
        \\}
        \\
        ,
        .ask = "Fix the ZTS304 compiler error in handler.ts",
    },
    .{
        .id = "unchecked-result",
        .code = "ZTS303",
        .class = .compiler_repair,
        .seed_source = clean_checked_result,
        .bad_draft =
        \\import { validateJson } from "zttp:validate";
        \\
        \\function handler(req: Request): Proof<Response, "deterministic"> {
        \\  const result = validateJson("item", req.body ?? "");
        \\  const data = result.value;
        \\  return Response.json({ data: data, updated: true });
        \\}
        \\
        ,
        .good_draft =
        \\import { validateJson } from "zttp:validate";
        \\
        \\function handler(req: Request): Proof<Response, "deterministic"> {
        \\  const result = validateJson("item", req.body ?? "");
        \\  if (!result.ok) return Response.json({ error: result.error }, { status: 400 });
        \\  const data = result.value;
        \\  return Response.json({ data: data, updated: true });
        \\}
        \\
        ,
        .ask = "Fix the ZTS303 compiler error in handler.ts",
    },
    .{
        .id = "unchecked-optional",
        .code = "ZTS308",
        .class = .compiler_repair,
        .seed_source = clean_checked_optional,
        .bad_draft =
        \\import { env } from "zttp:env";
        \\
        \\function handler(req: Request): Proof<Response, "deterministic"> {
        \\  const appName = env("APP_NAME");
        \\  return Response.json({ appName: appName, updated: true });
        \\}
        \\
        ,
        .good_draft =
        \\import { env } from "zttp:env";
        \\
        \\function handler(req: Request): Proof<Response, "deterministic"> {
        \\  const appName = env("APP_NAME");
        \\  if (appName === undefined) return Response.json({ error: "missing value" }, { status: 400 });
        \\  return Response.json({ appName: appName, updated: true });
        \\}
        \\
        ,
        .ask = "Fix the ZTS308 compiler error in handler.ts",
    },
    .{
        .id = "redundant-bool-compare",
        .code = "ZTS620",
        .class = .salvaged,
        .seed_source = clean_bool,
        .bad_draft =
        \\function handler(req: Request): Proof<Response, "deterministic"> {
        \\  const ready = true;
        \\  if (ready === true) { return Response.json({ ready: 9 }); }
        \\  return Response.json({ ready: 0 });
        \\}
        \\
        ,
        .good_draft =
        \\function handler(req: Request): Proof<Response, "deterministic"> {
        \\  const ready = true;
        \\  if (ready) { return Response.json({ ready: 8 }); }
        \\  return Response.json({ ready: 0 });
        \\}
        \\
        ,
        .ask = "Fix the ZTS620 compiler error in handler.ts",
    },
    .{
        .id = "chained-ternary",
        .code = "ZTS621",
        .class = .salvaged,
        .seed_source = clean_tier,
        .bad_draft =
        \\function pickTier(a: boolean, b: boolean): number {
        \\  if (a) { return 1; }
        \\  if (b) { return 2; }
        \\  return 3;
        \\}
        \\
        \\function handler(req: Request): Proof<Response, "deterministic"> {
        \\  const a = true;
        \\  const b = false;
        \\  const tier = a ? 1 : b ? 2 : 3;
        \\  return Response.json({ tier: tier });
        \\}
        \\
        ,
        .good_draft =
        \\function pickTier(a: boolean, b: boolean): number {
        \\  if (a) { return 1; }
        \\  if (b) { return 2; }
        \\  return 3;
        \\}
        \\
        \\function handler(req: Request): Proof<Response, "deterministic"> {
        \\  const tier = pickTier(false, true);
        \\  return Response.json({ tier: tier });
        \\}
        \\
        ,
        .ask = "Fix the ZTS621 compiler error in handler.ts",
    },
    .{
        .id = "arrow-helper",
        .code = "ZTS608",
        .class = .salvaged,
        .seed_source = clean_named_helper,
        .bad_draft =
        \\const double = (x: number): number => x + x;
        \\
        \\function handler(req: Request): Proof<Response, "deterministic"> {
        \\  const a = double(8);
        \\  const b = double(9);
        \\  return Response.json({ a: a, b: b });
        \\}
        \\
        ,
        .good_draft =
        \\function double(x: number): number {
        \\  return x + x;
        \\}
        \\
        \\function handler(req: Request): Proof<Response, "deterministic"> {
        \\  const a = double(4);
        \\  const b = double(5);
        \\  return Response.json({ a: a, b: b });
        \\}
        \\
        ,
        .ask = "Fix the ZTS608 compiler error in handler.ts",
    },
    .{
        .id = "exported-arrow-const",
        .code = "ZTS609",
        .class = .salvaged,
        .seed_source = clean_exported_handler,
        .bad_draft =
        \\export const handler = (req: Request): Proof<Response, "deterministic"> => Response.json({ ok: 9 });
        \\
        ,
        .good_draft =
        \\export function handler(req: Request): Proof<Response, "deterministic"> {
        \\  return Response.json({ ok: 6 });
        \\}
        \\
        ,
        .ask = "Fix the ZTS609 compiler error in handler.ts",
    },
    .{
        .id = "effectful-ternary",
        .code = "ZTS612",
        .class = .model_retry,
        .seed_source = clean_ternary,
        .bad_draft =
        \\function pick(): number {
        \\  return 7;
        \\}
        \\
        \\function handler(req: Request): Proof<Response, "deterministic"> {
        \\  const ready = true;
        \\  const status = ready ? pick() : 5;
        \\  return Response.json({ status: status });
        \\}
        \\
        ,
        .good_draft =
        \\function pick(): number {
        \\  return 7;
        \\}
        \\
        \\function handler(req: Request): Proof<Response, "deterministic"> {
        \\  const ready = true;
        \\  const picked = pick();
        \\  const status = ready ? picked : 6;
        \\  return Response.json({ status: status });
        \\}
        \\
        ,
        .ask = "Fix the ZTS612 compiler error in handler.ts",
    },
    .{
        .id = "non-leading-spread",
        .code = "ZTS614",
        .class = .model_retry,
        .seed_source = clean_spread,
        .bad_draft =
        \\function handler(req: Request): Proof<Response, "deterministic"> {
        \\  const base = { a: 1 };
        \\  const next = { status: "ok", ...base };
        \\  return Response.json({ next: next });
        \\}
        \\
        ,
        .good_draft =
        \\function handler(req: Request): Proof<Response, "deterministic"> {
        \\  const base = { a: 2 };
        \\  const next = { ...base, status: "ok" };
        \\  return Response.json({ next: next });
        \\}
        \\
        ,
        .ask = "Fix the ZTS614 compiler error in handler.ts",
    },
    .{
        .id = "call-spread",
        .code = "ZTS616",
        .class = .model_retry,
        .seed_source = clean_send,
        .bad_draft =
        \\function send(a: number): number {
        \\  return a + a;
        \\}
        \\
        \\function handler(req: Request): Proof<Response, "deterministic"> {
        \\  const args = [1];
        \\  const sent = send(...args);
        \\  return Response.json({ sent: sent });
        \\}
        \\
        ,
        .good_draft =
        \\function send(a: number): number {
        \\  return a + a;
        \\}
        \\
        \\function handler(req: Request): Proof<Response, "deterministic"> {
        \\  const args = [4];
        \\  const sent = send(args[0]);
        \\  return Response.json({ sent: sent });
        \\}
        \\
        ,
        .ask = "Fix the ZTS616 compiler error in handler.ts",
    },
    .{
        .id = "nullish-on-null",
        .code = "ZTS624",
        .class = .model_retry,
        .seed_source = clean_nullable,
        .bad_draft =
        \\structural MaybeName = string | null;
        \\
        \\function nameOf(): MaybeName {
        \\  return null;
        \\}
        \\
        \\function handler(req: Request): Proof<Response, "deterministic"> {
        \\  const n = nameOf();
        \\  const name = n ?? "anon";
        \\  return Response.json({ name: name });
        \\}
        \\
        ,
        .good_draft =
        \\structural MaybeName = string | null;
        \\
        \\function nameOf(): MaybeName {
        \\  return null;
        \\}
        \\
        \\function handler(req: Request): Proof<Response, "deterministic"> {
        \\  const n = nameOf();
        \\  if (n === null) { return Response.json({ name: "nobody" }); }
        \\  return Response.json({ name: n });
        \\}
        \\
        ,
        .ask = "Fix the ZTS624 compiler error in handler.ts",
    },
    .{
        .id = "redundant-pattern-rename",
        .code = "ZTS625",
        .class = .model_retry,
        .seed_source = clean_match,
        .bad_draft =
        \\structural Msg = { kind: string, text: string };
        \\
        \\function handler(req: Request): Proof<Response, "deterministic"> {
        \\  const msg: Msg = { kind: "echo", text: "hi" };
        \\  const out = match (msg) {
        \\    when { kind: "echo", text: text }: text
        \\    default: "none"
        \\  };
        \\  return Response.json({ out: out });
        \\}
        \\
        ,
        .good_draft =
        \\structural Msg = { kind: string, text: string };
        \\
        \\function handler(req: Request): Proof<Response, "deterministic"> {
        \\  const msg: Msg = { kind: "echo", text: "hey" };
        \\  const out = match (msg) {
        \\    when { kind: "echo", text }: text
        \\    default: "none"
        \\  };
        \\  return Response.json({ out: out });
        \\}
        \\
        ,
        .ask = "Fix the ZTS625 compiler error in handler.ts",
    },
    .{
        .id = "scrutinee-field-read",
        .code = "ZTS626",
        .class = .model_retry,
        .seed_source = clean_match,
        .bad_draft =
        \\structural Msg = { kind: string, text: string };
        \\
        \\function handler(req: Request): Proof<Response, "deterministic"> {
        \\  const msg: Msg = { kind: "echo", text: "hi" };
        \\  const out = match (msg) {
        \\    when { kind: "echo" }: msg.text
        \\    default: "none"
        \\  };
        \\  return Response.json({ out: out });
        \\}
        \\
        ,
        .good_draft =
        \\structural Msg = { kind: string, text: string };
        \\
        \\function handler(req: Request): Proof<Response, "deterministic"> {
        \\  const msg: Msg = { kind: "echo", text: "yo" };
        \\  const out = match (msg) {
        \\    when { kind: "echo", text }: text
        \\    default: "none"
        \\  };
        \\  return Response.json({ out: out });
        \\}
        \\
        ,
        .ask = "Fix the ZTS626 compiler error in handler.ts",
    },
    .{
        .id = "unused-variable",
        .code = "ZTS305",
        .class = .model_retry,
        .seed_source = clean_plain,
        .bad_draft =
        \\function handler(req: Request): Proof<Response, "deterministic"> {
        \\  const unused = 42;
        \\  return Response.json({ ok: 1 });
        \\}
        \\
        ,
        .good_draft =
        \\function handler(req: Request): Proof<Response, "deterministic"> {
        \\  return Response.json({ ok: 5 });
        \\}
        \\
        ,
        .ask = "Fix the ZTS305 compiler error in handler.ts",
    },
    .{
        .id = "module-scope-mutation",
        .code = "ZTS310",
        .class = .model_retry,
        .seed_source = clean_local_count,
        .bad_draft =
        \\let count = 0;
        \\
        \\function handler(req: Request): Proof<Response, "deterministic"> {
        \\  count = count + 1;
        \\  return Response.json({ count: count });
        \\}
        \\
        ,
        .good_draft =
        \\function handler(req: Request): Proof<Response, "deterministic"> {
        \\  const count = 7;
        \\  return Response.json({ count: count });
        \\}
        \\
        ,
        .ask = "Fix the ZTS310 compiler error in handler.ts",
    },
    .{
        .id = "loop-mutation",
        .code = "ZTS622",
        .class = .model_retry,
        .seed_source = clean_collect,
        .bad_draft =
        \\function handler(req: Request): Proof<Response, "deterministic"> {
        \\  const items = [1, 2];
        \\  for (const item of items) {
        \\    items.push(item);
        \\  }
        \\  return Response.json({ items: items });
        \\}
        \\
        ,
        .good_draft =
        \\function handler(req: Request): Proof<Response, "deterministic"> {
        \\  const items = [3, 4];
        \\  const out = [];
        \\  for (const item of items) {
        \\    out.push(item);
        \\  }
        \\  return Response.json({ out: out });
        \\}
        \\
        ,
        .ask = "Fix the ZTS622 compiler error in handler.ts",
    },
    .{
        .id = "computed-access",
        .code = "ZTS605",
        .class = .model_retry,
        .seed_source = clean_literal_access,
        .bad_draft =
        \\import { env } from "zttp:env";
        \\
        \\function handler(req: Request): Proof<Response, "deterministic"> {
        \\  const obj = { a: 1 };
        \\  const key = env("KEY") ?? "a";
        \\  const v = obj[key];
        \\  return Response.json({ v: v });
        \\}
        \\
        ,
        .good_draft =
        \\import { env } from "zttp:env";
        \\
        \\function handler(req: Request): Proof<Response, "deterministic"> {
        \\  const obj = { a: 3 };
        \\  const v = obj.a;
        \\  return Response.json({ v: v });
        \\}
        \\
        ,
        .ask = "Fix the ZTS605 compiler error in handler.ts",
    },
    .{
        .id = "dynamic-capability",
        .code = "ZTS602",
        .class = .model_retry,
        .seed_source = clean_literal_capability,
        .bad_draft =
        \\import { env } from "zttp:env";
        \\
        \\function handler(req: Request): Proof<Response, "deterministic"> {
        \\  const key = req.url;
        \\  const v = env(key) ?? "x";
        \\  return Response.json({ v: v });
        \\}
        \\
        ,
        .good_draft =
        \\import { env } from "zttp:env";
        \\
        \\function handler(req: Request): Proof<Response, "deterministic"> {
        \\  const v = env("APP_NAME") ?? "y";
        \\  return Response.json({ v: v });
        \\}
        \\
        ,
        .ask = "Fix the ZTS602 compiler error in handler.ts",
    },
    .{
        .id = "optional-property",
        .code = "ZTS309",
        .class = .compiler_repair,
        .seed_source = clean_narrowed_optional,
        .bad_draft =
        \\import { env } from "zttp:env";
        \\
        \\function handler(req: Request): Proof<Response, "deterministic"> {
        \\  const name = env("APP_NAME");
        \\  return Response.json({ n: name.length });
        \\}
        \\
        ,
        .good_draft =
        \\import { env } from "zttp:env";
        \\
        \\function handler(req: Request): Proof<Response, "deterministic"> {
        \\  const name = env("APP_NAME");
        \\  if (name === undefined) return Response.json({ error: "missing value" }, { status: 400 });
        \\  return Response.json({ n: name.length });
        \\}
        \\
        ,
        .ask = "Fix the ZTS309 compiler error in handler.ts",
    },
    .{
        .id = "missing-path-return",
        .code = "ZTS302",
        .class = .compiler_repair,
        .seed_source = clean_all_paths_return,
        .bad_draft =
        \\function handler(req: Request): Proof<Response, "deterministic"> {
        \\  const ready = true;
        \\  if (ready) { return Response.json({ ok: 1 }); }
        \\}
        \\
        ,
        .good_draft =
        \\function handler(req: Request): Proof<Response, "deterministic"> {
        \\  const ready = true;
        \\  if (ready) { return Response.json({ ok: 1 }); }
        \\  return Response.text("Not Found", { status: 404 });
        \\}
        \\
        ,
        .ask = "Fix the ZTS302 compiler error in handler.ts",
    },
    .{
        .id = "secret-in-response",
        .code = "ZTS400",
        .class = .model_retry,
        .seed_source = clean_secret_unleaked,
        .bad_draft =
        \\import { env } from "zttp:env";
        \\
        \\function handler(req: Request): Proof<Response, "deterministic"> {
        \\  const token = env("API_TOKEN") ?? "";
        \\  return Response.json({ token: token });
        \\}
        \\
        ,
        .good_draft =
        \\import { env } from "zttp:env";
        \\
        \\function handler(req: Request): Proof<Response, "deterministic"> {
        \\  const token = env("API_TOKEN") ?? "";
        \\  if (token === "") { return Response.json({ ok: 3 }); }
        \\  return Response.json({ ok: 4 });
        \\}
        \\
        ,
        .ask = "Fix the ZTS400 compiler error in handler.ts",
    },
    .{
        .id = "credential-in-response",
        .code = "ZTS401",
        .class = .model_retry,
        .seed_source = clean_credential_unleaked,
        .bad_draft =
        \\function handler(req: Request): Proof<Response, "deterministic"> {
        \\  const auth = req.headers.authorization ?? "";
        \\  return Response.json({ auth: auth });
        \\}
        \\
        ,
        .good_draft =
        \\function handler(req: Request): Proof<Response, "deterministic"> {
        \\  const auth = req.headers.authorization ?? "";
        \\  if (auth === "") { return Response.json({ ok: 3 }); }
        \\  return Response.json({ ok: 4 });
        \\}
        \\
        ,
        .ask = "Fix the ZTS401 compiler error in handler.ts",
    },
    .{
        .id = "secret-in-log",
        .code = "ZTS402",
        .class = .model_retry,
        .seed_source = clean_secret_and_log,
        .bad_draft =
        \\import { env } from "zttp:env";
        \\import { logInfo } from "zttp:log";
        \\
        \\function handler(req: Request): Proof<Response, "deterministic"> {
        \\  const token = env("API_TOKEN") ?? "";
        \\  logInfo(token, { n: 1 });
        \\  if (token === "") { return Response.json({ ok: 0 }); }
        \\  return Response.json({ ok: 1 });
        \\}
        \\
        ,
        .good_draft =
        \\import { env } from "zttp:env";
        \\import { logInfo } from "zttp:log";
        \\
        \\function handler(req: Request): Proof<Response, "deterministic"> {
        \\  const token = env("API_TOKEN") ?? "";
        \\  logInfo("checked", { n: 2 });
        \\  if (token === "") { return Response.json({ ok: 0 }); }
        \\  return Response.json({ ok: 1 });
        \\}
        \\
        ,
        .ask = "Fix the ZTS402 compiler error in handler.ts",
    },
    .{
        .id = "credential-in-log",
        .code = "ZTS403",
        .class = .model_retry,
        .seed_source = clean_credential_and_log,
        .bad_draft =
        \\import { logInfo } from "zttp:log";
        \\
        \\function handler(req: Request): Proof<Response, "deterministic"> {
        \\  const auth = req.headers.authorization ?? "";
        \\  logInfo(auth, { n: 1 });
        \\  if (auth === "") { return Response.json({ ok: 0 }); }
        \\  return Response.json({ ok: 1 });
        \\}
        \\
        ,
        .good_draft =
        \\import { logInfo } from "zttp:log";
        \\
        \\function handler(req: Request): Proof<Response, "deterministic"> {
        \\  const auth = req.headers.authorization ?? "";
        \\  logInfo("checked", { n: 2 });
        \\  if (auth === "") { return Response.json({ ok: 0 }); }
        \\  return Response.json({ ok: 1 });
        \\}
        \\
        ,
        .ask = "Fix the ZTS403 compiler error in handler.ts",
    },
    .{
        .id = "secret-in-egress-body",
        .code = "ZTS406",
        .class = .model_retry,
        .seed_source = clean_secret_and_egress,
        .bad_draft =
        \\import { env } from "zttp:env";
        \\import { fetch } from "zttp:fetch";
        \\
        \\function handler(req: Request): Proof<Response, "deterministic"> {
        \\  const token = env("API_TOKEN") ?? "";
        \\  const r = fetch("https://api.example.com/v1", { method: "POST", body: token });
        \\  return Response.json({ s: r.status });
        \\}
        \\
        ,
        .good_draft =
        \\import { env } from "zttp:env";
        \\import { fetch } from "zttp:fetch";
        \\
        \\function handler(req: Request): Proof<Response, "deterministic"> {
        \\  const token = env("API_TOKEN") ?? "";
        \\  const r = fetch("https://api.example.com/v1", { method: "POST", body: "pong" });
        \\  if (token === "") { return Response.json({ ok: 0 }); }
        \\  return Response.json({ s: r.status });
        \\}
        \\
        ,
        .ask = "Fix the ZTS406 compiler error in handler.ts",
    },
    .{
        .id = "proof-name-unknown",
        .code = "ZTS502",
        .class = .model_retry,
        .seed_source = clean_plain_ok,
        .bad_draft =
        \\function handler(req: Request): Proof<Response, "banana"> {
        \\  return Response.json({ ok: 1 });
        \\}
        \\
        ,
        .good_draft =
        \\function handler(req: Request): Proof<Response, "read_only"> {
        \\  return Response.json({ ok: 2 });
        \\}
        \\
        ,
        .ask = "Fix the ZTS502 compiler error in handler.ts",
    },
    .{
        .id = "spec-contradicts-module",
        .code = "ZTS501",
        .class = .model_retry,
        .seed_source = clean_read_only,
        .bad_draft =
        \\import { cacheSet } from "zttp:cache";
        \\
        \\function handler(req: Request): Proof<Response, "read_only"> {
        \\  cacheSet("ns", "k", "v");
        \\  return Response.json({ v: "ok" });
        \\}
        \\
        ,
        .good_draft =
        \\function handler(req: Request): Proof<Response, "read_only"> {
        \\  return Response.json({ v: "stored" });
        \\}
        \\
        ,
        .ask = "Fix the ZTS501 compiler error in handler.ts",
    },
    .{
        .id = "proof-not-discharged",
        .code = "ZTS500",
        .class = .model_retry,
        .seed_source = clean_count,
        .bad_draft =
        \\function handler(req: Request): Proof<Response, "deterministic"> {
        \\  const count = Date.now();
        \\  return Response.json({ count: count });
        \\}
        \\
        ,
        .good_draft =
        \\function handler(req: Request): Proof<Response, "deterministic"> {
        \\  const count = 2;
        \\  return Response.json({ count: count });
        \\}
        \\
        ,
        .ask = "Fix the ZTS500 compiler error in handler.ts",
    },
    .{
        .id = "ambient-not-published",
        .code = "ZTS629",
        .class = .model_retry,
        .seed_source = clean_count,
        .bad_draft =
        \\function handler(req: Request): Proof<Response, "deterministic"> {
        \\  const count = globalThis;
        \\  return Response.json({ count: 1 });
        \\}
        \\
        ,
        .good_draft =
        \\function handler(req: Request): Proof<Response, "deterministic"> {
        \\  const count = 3;
        \\  return Response.json({ count: count });
        \\}
        \\
        ,
        .ask = "Fix the ZTS629 compiler error in handler.ts",
    },
    .{
        .id = "exported-open-type",
        .code = "ZTS061",
        .class = .model_retry,
        .seed_source = clean_exported_only_handler,
        .bad_draft =
        \\export function widen(x: object): object {
        \\  return x;
        \\}
        \\
        \\export function handler(req: Request): Proof<Response, "deterministic"> {
        \\  return Response.json({ ok: 1 });
        \\}
        \\
        ,
        .good_draft =
        \\export function handler(req: Request): Proof<Response, "deterministic"> {
        \\  return Response.json({ ok: 2 });
        \\}
        \\
        ,
        .ask = "Fix the ZTS061 compiler error in handler.ts",
    },
    .{
        .id = "missing-annotations",
        .code = "ZTS601",
        .class = .model_retry,
        .seed_source = clean_annotated_helper,
        .bad_draft =
        \\function scale(x): number {
        \\  return x + x;
        \\}
        \\
        \\function handler(req: Request): Proof<Response, "deterministic"> {
        \\  const v = scale(1);
        \\  return Response.json({ v: v });
        \\}
        \\
        ,
        .good_draft =
        \\function scale(x: number): number {
        \\  return x + x + x;
        \\}
        \\
        \\function handler(req: Request): Proof<Response, "deterministic"> {
        \\  const v = scale(1);
        \\  return Response.json({ v: v });
        \\}
        \\
        ,
        .ask = "Fix the ZTS601 compiler error in handler.ts",
    },
    .{
        .id = "match-not-exhaustive",
        .code = "ZTS603",
        .class = .model_retry,
        .seed_source = clean_match_default,
        .bad_draft =
        \\function handler(req: Request): Proof<Response, "deterministic"> {
        \\  const n = 3;
        \\  const out = match (n) {
        \\    when 1: "one"
        \\    when 2: "two"
        \\  };
        \\  return Response.json({ out: out });
        \\}
        \\
        ,
        .good_draft =
        \\function handler(req: Request): Proof<Response, "deterministic"> {
        \\  const n = 3;
        \\  const out = match (n) {
        \\    when 1: "one"
        \\    when 2: "two"
        \\    default: "other"
        \\  };
        \\  return Response.json({ out: out });
        \\}
        \\
        ,
        .ask = "Fix the ZTS603 compiler error in handler.ts",
    },
    .{
        .id = "call-result-unknown",
        .code = "ZTS600",
        .class = .model_retry,
        .seed_source = clean_crypto_budget,
        .bad_draft =
        \\import { sha256 } from "zttp:crypto";
        \\
        \\function handler(req: Request): Proof<Effects<Response, "crypto">, "deterministic"> {
        \\  const f = () => sha256("zttp");
        \\  return Response.text(f());
        \\}
        \\
        ,
        .good_draft =
        \\import { sha256 } from "zttp:crypto";
        \\
        \\function handler(req: Request): Proof<Effects<Response, "crypto">, "deterministic"> {
        \\  return Response.text(sha256("zttp-fixed"));
        \\}
        \\
        ,
        .ask = "Fix the ZTS600 compiler error in handler.ts",
    },
    .{
        .id = "ceiling-not-literal",
        .code = "ZTS511",
        .class = .model_retry,
        .seed_source = clean_crypto_budget,
        .bad_draft =
        \\import { sha256 } from "zttp:crypto";
        \\
        \\function handler(req: Request): Proof<Effects<Response, string>, "deterministic"> {
        \\  return Response.text(sha256("zttp"));
        \\}
        \\
        ,
        .good_draft =
        \\import { sha256 } from "zttp:crypto";
        \\
        \\function handler(req: Request): Proof<Effects<Response, "crypto">, "deterministic"> {
        \\  return Response.text(sha256("zttp-ok"));
        \\}
        \\
        ,
        .ask = "Fix the ZTS511 compiler error in handler.ts",
    },
    .{
        .id = "handler-outside-budget",
        .code = "ZTS506",
        .class = .model_retry,
        .seed_source = clean_handler_log_budget,
        .bad_draft =
        \\import { logInfo } from "zttp:log";
        \\
        \\structural Narrow<T> = Proof<T,
        \\    | "deterministic"
        \\    | "state_isolated"
        \\    | "result_safe"
        \\    | "optional_safe"
        \\    | "no_secret_leakage"
        \\    | "no_credential_leakage"
        \\    | "input_validated"
        \\    | "injection_safe"
        \\    | "canonical"
        \\    | "cost_bounded"
        \\>;
        \\
        \\function handler(req: Request): Narrow<Effects<Response, "clock">> {
        \\  logInfo("hit", { n: 1 });
        \\  return Response.text("ok");
        \\}
        \\
        ,
        .good_draft =
        \\import { logInfo } from "zttp:log";
        \\
        \\structural Narrow<T> = Proof<T,
        \\    | "deterministic"
        \\    | "state_isolated"
        \\    | "result_safe"
        \\    | "optional_safe"
        \\    | "no_secret_leakage"
        \\    | "no_credential_leakage"
        \\    | "input_validated"
        \\    | "injection_safe"
        \\    | "canonical"
        \\    | "cost_bounded"
        \\>;
        \\
        \\function handler(req: Request): Narrow<Effects<Response, "stderr" | "clock">> {
        \\  logInfo("hit", { n: 2 });
        \\  return Response.text("ok");
        \\}
        \\
        ,
        .ask = "Fix the ZTS506 compiler error in handler.ts",
    },
    .{
        .id = "ceiling-unknown-capability",
        .code = "ZTS504",
        .class = .model_retry,
        .seed_source = clean_handler_log_budget,
        .bad_draft =
        \\import { logInfo } from "zttp:log";
        \\
        \\structural Narrow<T> = Proof<T,
        \\    | "deterministic"
        \\    | "state_isolated"
        \\    | "result_safe"
        \\    | "optional_safe"
        \\    | "no_secret_leakage"
        \\    | "no_credential_leakage"
        \\    | "input_validated"
        \\    | "injection_safe"
        \\    | "canonical"
        \\    | "cost_bounded"
        \\>;
        \\
        \\function handler(req: Request): Narrow<Effects<Response, "stderr" | "clock" | "databse">> {
        \\  logInfo("hit", { n: 1 });
        \\  return Response.text("ok");
        \\}
        \\
        ,
        .good_draft =
        \\import { logInfo } from "zttp:log";
        \\
        \\structural Narrow<T> = Proof<T,
        \\    | "deterministic"
        \\    | "state_isolated"
        \\    | "result_safe"
        \\    | "optional_safe"
        \\    | "no_secret_leakage"
        \\    | "no_credential_leakage"
        \\    | "input_validated"
        \\    | "injection_safe"
        \\    | "canonical"
        \\    | "cost_bounded"
        \\>;
        \\
        \\function handler(req: Request): Narrow<Effects<Response, "stderr" | "clock">> {
        \\  logInfo("hit", { n: 3 });
        \\  return Response.text("ok");
        \\}
        \\
        ,
        .ask = "Fix the ZTS504 compiler error in handler.ts",
    },
    .{
        .id = "helper-outside-ceiling",
        .code = "ZTS503",
        .class = .model_retry,
        .seed_source = clean_helper_log_ceiling,
        .bad_draft =
        \\import { sha256 } from "zttp:crypto";
        \\import { logInfo } from "zttp:log";
        \\
        \\structural Narrow<T> = Proof<T,
        \\    | "deterministic"
        \\    | "state_isolated"
        \\    | "result_safe"
        \\    | "optional_safe"
        \\    | "no_secret_leakage"
        \\    | "no_credential_leakage"
        \\    | "input_validated"
        \\    | "injection_safe"
        \\    | "canonical"
        \\    | "cost_bounded"
        \\>;
        \\
        \\structural Digest = { value: string };
        \\
        \\export function digest(input: Digest): Proof<Effects<Digest, "crypto" | "clock">, "deterministic"> {
        \\  sha256(input.value);
        \\  logInfo("digest", { n: 1 });
        \\  return input;
        \\}
        \\
        \\function handler(req: Request): Narrow<Effects<Response, "crypto" | "stderr" | "clock">> {
        \\  const d = digest({ value: "zttp" });
        \\  return Response.text(d.value);
        \\}
        \\
        ,
        .good_draft =
        \\import { sha256 } from "zttp:crypto";
        \\import { logInfo } from "zttp:log";
        \\
        \\structural Narrow<T> = Proof<T,
        \\    | "deterministic"
        \\    | "state_isolated"
        \\    | "result_safe"
        \\    | "optional_safe"
        \\    | "no_secret_leakage"
        \\    | "no_credential_leakage"
        \\    | "input_validated"
        \\    | "injection_safe"
        \\    | "canonical"
        \\    | "cost_bounded"
        \\>;
        \\
        \\structural Digest = { value: string };
        \\
        \\export function digest(input: Digest): Proof<Effects<Digest, "crypto" | "stderr" | "clock">, "deterministic"> {
        \\  sha256(input.value);
        \\  logInfo("digest", { n: 2 });
        \\  return input;
        \\}
        \\
        \\function handler(req: Request): Narrow<Effects<Response, "crypto" | "stderr" | "clock">> {
        \\  const d = digest({ value: "zttp" });
        \\  return Response.text(d.value);
        \\}
        \\
        ,
        .ask = "Fix the ZTS503 compiler error in handler.ts",
    },
    .{
        .id = "helper-outside-handler-budget",
        .code = "ZTS607",
        .class = .model_retry,
        .seed_source = clean_helper_log_ceiling,
        .bad_draft =
        \\import { sha256 } from "zttp:crypto";
        \\import { logInfo } from "zttp:log";
        \\
        \\structural Narrow<T> = Proof<T,
        \\    | "deterministic"
        \\    | "state_isolated"
        \\    | "result_safe"
        \\    | "optional_safe"
        \\    | "no_secret_leakage"
        \\    | "no_credential_leakage"
        \\    | "input_validated"
        \\    | "injection_safe"
        \\    | "canonical"
        \\    | "cost_bounded"
        \\>;
        \\
        \\structural Digest = { value: string };
        \\
        \\export function digest(input: Digest): Proof<Effects<Digest, "crypto" | "stderr" | "clock">, "deterministic"> {
        \\  sha256(input.value);
        \\  logInfo("digest", { n: 1 });
        \\  return input;
        \\}
        \\
        \\function handler(req: Request): Narrow<Effects<Response, "crypto" | "clock">> {
        \\  const d = digest({ value: "zttp" });
        \\  return Response.text(d.value);
        \\}
        \\
        ,
        .good_draft =
        \\import { sha256 } from "zttp:crypto";
        \\import { logInfo } from "zttp:log";
        \\
        \\structural Narrow<T> = Proof<T,
        \\    | "deterministic"
        \\    | "state_isolated"
        \\    | "result_safe"
        \\    | "optional_safe"
        \\    | "no_secret_leakage"
        \\    | "no_credential_leakage"
        \\    | "input_validated"
        \\    | "injection_safe"
        \\    | "canonical"
        \\    | "cost_bounded"
        \\>;
        \\
        \\structural Digest = { value: string };
        \\
        \\export function digest(input: Digest): Proof<Effects<Digest, "crypto" | "stderr" | "clock">, "deterministic"> {
        \\  sha256(input.value);
        \\  logInfo("digest", { n: 3 });
        \\  return input;
        \\}
        \\
        \\function handler(req: Request): Narrow<Effects<Response, "crypto" | "stderr" | "clock">> {
        \\  const d = digest({ value: "zttp" });
        \\  return Response.text(d.value);
        \\}
        \\
        ,
        .ask = "Fix the ZTS607 compiler error in handler.ts",
    },
    .{
        .id = "ceiling-never-reached",
        .code = "ZTS505",
        .class = .model_retry,
        .seed_source = clean_exported_helper_capsule,
        .bad_draft =
        \\import { sha256 } from "zttp:crypto";
        \\
        \\structural Narrow<T> = Proof<T,
        \\    | "deterministic"
        \\    | "state_isolated"
        \\    | "result_safe"
        \\    | "optional_safe"
        \\    | "no_secret_leakage"
        \\    | "no_credential_leakage"
        \\    | "input_validated"
        \\    | "injection_safe"
        \\    | "canonical"
        \\    | "cost_bounded"
        \\>;
        \\
        \\structural Digest = { value: string };
        \\
        \\export function digest(input: Digest): Proof<Effects<Digest, "crypto">, "deterministic"> {
        \\  return input;
        \\}
        \\
        \\function handler(req: Request): Narrow<Effects<Response, "crypto">> {
        \\  const d = digest({ value: "zttp" });
        \\  return Response.text(d.value);
        \\}
        \\
        ,
        .good_draft =
        \\import { sha256 } from "zttp:crypto";
        \\
        \\structural Narrow<T> = Proof<T,
        \\    | "deterministic"
        \\    | "state_isolated"
        \\    | "result_safe"
        \\    | "optional_safe"
        \\    | "no_secret_leakage"
        \\    | "no_credential_leakage"
        \\    | "input_validated"
        \\    | "injection_safe"
        \\    | "canonical"
        \\    | "cost_bounded"
        \\>;
        \\
        \\structural Digest = { value: string };
        \\
        \\export function digest(input: Digest): Proof<Effects<Digest, "crypto">, "deterministic"> {
        \\  sha256(input.value);
        \\  return input;
        \\}
        \\
        \\function handler(req: Request): Narrow<Effects<Response, "crypto">> {
        \\  const d = digest({ value: "zttp-ok" });
        \\  return Response.text(d.value);
        \\}
        \\
        ,
        .ask = "Fix the ZTS505 compiler error in handler.ts",
    },
    .{
        .id = "exported-helper-no-ceiling",
        .code = "ZTS610",
        .class = .model_retry,
        .seed_source = clean_exported_helper_capsule,
        .bad_draft =
        \\import { sha256 } from "zttp:crypto";
        \\
        \\structural Narrow<T> = Proof<T,
        \\    | "deterministic"
        \\    | "state_isolated"
        \\    | "result_safe"
        \\    | "optional_safe"
        \\    | "no_secret_leakage"
        \\    | "no_credential_leakage"
        \\    | "input_validated"
        \\    | "injection_safe"
        \\    | "canonical"
        \\    | "cost_bounded"
        \\>;
        \\
        \\structural Digest = { value: string };
        \\
        \\export function digest(input: Digest): Proof<Digest, "deterministic"> {
        \\  sha256(input.value);
        \\  return input;
        \\}
        \\
        \\function handler(req: Request): Narrow<Effects<Response, "crypto">> {
        \\  const d = digest({ value: "zttp" });
        \\  return Response.text(d.value);
        \\}
        \\
        ,
        .good_draft =
        \\import { sha256 } from "zttp:crypto";
        \\
        \\structural Narrow<T> = Proof<T,
        \\    | "deterministic"
        \\    | "state_isolated"
        \\    | "result_safe"
        \\    | "optional_safe"
        \\    | "no_secret_leakage"
        \\    | "no_credential_leakage"
        \\    | "input_validated"
        \\    | "injection_safe"
        \\    | "canonical"
        \\    | "cost_bounded"
        \\>;
        \\
        \\structural Digest = { value: string };
        \\
        \\export function digest(input: Digest): Proof<Effects<Digest, "crypto">, "deterministic"> {
        \\  sha256(input.value);
        \\  return input;
        \\}
        \\
        \\function handler(req: Request): Narrow<Effects<Response, "crypto">> {
        \\  const d = digest({ value: "zttp-fixed" });
        \\  return Response.text(d.value);
        \\}
        \\
        ,
        .ask = "Fix the ZTS610 compiler error in handler.ts",
    },
    .{
        .id = "exported-helper-no-capsule",
        .code = "ZTS611",
        .class = .model_retry,
        .seed_source = clean_exported_helper_capsule,
        .bad_draft =
        \\import { sha256 } from "zttp:crypto";
        \\
        \\structural Narrow<T> = Proof<T,
        \\    | "deterministic"
        \\    | "state_isolated"
        \\    | "result_safe"
        \\    | "optional_safe"
        \\    | "no_secret_leakage"
        \\    | "no_credential_leakage"
        \\    | "input_validated"
        \\    | "injection_safe"
        \\    | "canonical"
        \\    | "cost_bounded"
        \\>;
        \\
        \\structural Digest = { value: string };
        \\
        \\export function digest(input: Digest): Effects<Digest, "crypto"> {
        \\  sha256(input.value);
        \\  return input;
        \\}
        \\
        \\function handler(req: Request): Narrow<Effects<Response, "crypto">> {
        \\  const d = digest({ value: "zttp" });
        \\  return Response.text(d.value);
        \\}
        \\
        ,
        .good_draft =
        \\import { sha256 } from "zttp:crypto";
        \\
        \\structural Narrow<T> = Proof<T,
        \\    | "deterministic"
        \\    | "state_isolated"
        \\    | "result_safe"
        \\    | "optional_safe"
        \\    | "no_secret_leakage"
        \\    | "no_credential_leakage"
        \\    | "input_validated"
        \\    | "injection_safe"
        \\    | "canonical"
        \\    | "cost_bounded"
        \\>;
        \\
        \\structural Digest = { value: string };
        \\
        \\export function digest(input: Digest): Proof<Effects<Digest, "crypto">, "deterministic"> {
        \\  sha256(input.value);
        \\  return input;
        \\}
        \\
        \\function handler(req: Request): Narrow<Effects<Response, "crypto">> {
        \\  const d = digest({ value: "zttp-declared" });
        \\  return Response.text(d.value);
        \\}
        \\
        ,
        .ask = "Fix the ZTS611 compiler error in handler.ts",
    },
    .{
        .id = "internal-declares-ceiling",
        .code = "ZTS623",
        .class = .model_retry,
        .seed_source = clean_internal_no_ceiling,
        .bad_draft =
        \\import { sha256 } from "zttp:crypto";
        \\
        \\structural Narrow<T> = Proof<T,
        \\    | "deterministic"
        \\    | "state_isolated"
        \\    | "result_safe"
        \\    | "optional_safe"
        \\    | "no_secret_leakage"
        \\    | "no_credential_leakage"
        \\    | "input_validated"
        \\    | "injection_safe"
        \\    | "canonical"
        \\    | "cost_bounded"
        \\>;
        \\
        \\function digest(s: string): Effects<string, "crypto"> {
        \\  sha256(s);
        \\  return s;
        \\}
        \\
        \\function handler(req: Request): Narrow<Effects<Response, "crypto">> {
        \\  return Response.text(digest("zttp"));
        \\}
        \\
        ,
        .good_draft =
        \\import { sha256 } from "zttp:crypto";
        \\
        \\structural Narrow<T> = Proof<T,
        \\    | "deterministic"
        \\    | "state_isolated"
        \\    | "result_safe"
        \\    | "optional_safe"
        \\    | "no_secret_leakage"
        \\    | "no_credential_leakage"
        \\    | "input_validated"
        \\    | "injection_safe"
        \\    | "canonical"
        \\    | "cost_bounded"
        \\>;
        \\
        \\function digest(s: string): string {
        \\  sha256(s);
        \\  return s;
        \\}
        \\
        \\function handler(req: Request): Narrow<Effects<Response, "crypto">> {
        \\  return Response.text(digest("zttp-ok"));
        \\}
        \\
        ,
        .ask = "Fix the ZTS623 compiler error in handler.ts",
    },
    .{
        .id = "helper-breaks-property",
        .code = "ZTS606",
        .class = .model_retry,
        .seed_source = clean_deterministic_helper,
        .bad_draft =
        \\function stamp(): number {
        \\  return Date.now();
        \\}
        \\
        \\function handler(req: Request): Proof<Response, "deterministic"> {
        \\  const t = stamp();
        \\  return Response.json({ t: t, n: 1 });
        \\}
        \\
        ,
        .good_draft =
        \\function stamp(): number {
        \\  return 8;
        \\}
        \\
        \\function handler(req: Request): Proof<Response, "deterministic"> {
        \\  const t = stamp();
        \\  return Response.json({ t: t, n: 2 });
        \\}
        \\
        ,
        .ask = "Fix the ZTS606 compiler error in handler.ts",
    },
    .{
        .id = "effect-row-lower-bound",
        .code = "ZTS512",
        .class = .model_retry,
        .seed_source = clean_resolvable_callee,
        .bad_draft =
        \\import { sha256 } from "zttp:crypto";
        \\
        \\structural Maker = { make: () => string };
        \\
        \\function build(): Maker {
        \\  return { make: () => sha256("zttp") };
        \\}
        \\
        \\function handler(req: Request): Proof<Effects<Response, "crypto">, "state_isolated"> {
        \\  const m = build();
        \\  const f = m.make;
        \\  return Response.text(f());
        \\}
        \\
        ,
        .good_draft =
        \\import { sha256 } from "zttp:crypto";
        \\
        \\structural Maker = { make: () => string };
        \\
        \\function build(): Maker {
        \\  return { make: () => sha256("zttp-ok") };
        \\}
        \\
        \\function handler(req: Request): Proof<Effects<Response, "crypto">, "state_isolated"> {
        \\  const m = build();
        \\  return Response.text(m.make());
        \\}
        \\
        ,
        .ask = "Fix the ZTS512 compiler error in handler.ts",
    },
    .{
        .id = "secret-in-egress-headers",
        .code = "ZTS404",
        .class = .model_retry,
        .seed_source = clean_secret_and_headers,
        .bad_draft =
        \\import { env } from "zttp:env";
        \\import { fetch } from "zttp:fetch";
        \\
        \\function handler(req: Request): Proof<Response, "deterministic"> {
        \\  const token = env("SECRET_KEY") ?? "";
        \\  const r = fetch("https://api.example.com/v1", { headers: { "x-tag": token } });
        \\  return Response.json({ s: r.status });
        \\}
        \\
        ,
        .good_draft =
        \\import { env } from "zttp:env";
        \\import { fetch } from "zttp:fetch";
        \\
        \\function handler(req: Request): Proof<Response, "deterministic"> {
        \\  const token = env("SECRET_KEY") ?? "";
        \\  const r = fetch("https://api.example.com/v1", { headers: { "x-tag": "redacted" } });
        \\  if (token === "") { return Response.json({ ok: 0 }); }
        \\  return Response.json({ s: r.status });
        \\}
        \\
        ,
        .ask = "Fix the ZTS404 compiler error in handler.ts",
    },
    .{
        .id = "credential-in-egress-headers",
        .code = "ZTS405",
        .class = .model_retry,
        .seed_source = clean_credential_and_headers,
        .bad_draft =
        \\import { fetch } from "zttp:fetch";
        \\
        \\function handler(req: Request): Proof<Response, "deterministic"> {
        \\  const auth = req.headers.authorization ?? "";
        \\  const r = fetch("https://api.example.com/v1", { headers: { "x-tag": auth } });
        \\  return Response.json({ s: r.status });
        \\}
        \\
        ,
        .good_draft =
        \\import { fetch } from "zttp:fetch";
        \\
        \\function handler(req: Request): Proof<Response, "deterministic"> {
        \\  const auth = req.headers.authorization ?? "";
        \\  const r = fetch("https://api.example.com/v1", { headers: { "x-tag": "scoped" } });
        \\  if (auth === "") { return Response.json({ ok: 0 }); }
        \\  return Response.json({ s: r.status });
        \\}
        \\
        ,
        .ask = "Fix the ZTS405 compiler error in handler.ts",
    },
    .{
        .id = "unvalidated-input-in-html",
        .code = "ZTS407",
        .class = .model_retry,
        .seed_source = clean_html_no_input,
        .bad_draft =
        \\function handler(req: Request): Proof<Response, "deterministic"> {
        \\  const q = req.url;
        \\  return Response.html(["<p>", q, "</p>"].join(""));
        \\}
        \\
        ,
        .good_draft =
        \\function handler(req: Request): Proof<Response, "deterministic"> {
        \\  const q = req.url;
        \\  if (q === "") { return Response.html("<p>none</p>"); }
        \\  return Response.html("<p>page</p>");
        \\}
        \\
        ,
        .ask = "Fix the ZTS407 compiler error in handler.ts",
    },
    .{
        .id = "workflow-call-in-step",
        .code = "ZTS509",
        .class = .model_retry,
        .seed_source = clean_durable_step,
        .bad_draft =
        \\import { run, step } from "zttp:durable";
        \\import { call } from "zttp:workflow";
        \\
        \\function handler(req: Request): Proof<object, "state_isolated"> {
        \\  return run("step-demo", () => step("one", () => call("greet", { path: "/ship" })));
        \\}
        \\
        ,
        .good_draft =
        \\import { run, step } from "zttp:durable";
        \\
        \\function handler(req: Request): Proof<object, "state_isolated"> {
        \\  return run("step-demo", () => step("one", () => { return { ok: 2 }; }));
        \\}
        \\
        ,
        .ask = "Fix the ZTS509 compiler error in handler.ts",
    },
    .{
        .id = "saga-step-no-compensate",
        .code = "ZTS510",
        .class = .model_retry,
        .seed_source = clean_saga_compensated,
        .bad_draft =
        \\import { run } from "zttp:durable";
        \\import { call, saga } from "zttp:workflow";
        \\
        \\function handler(req: Request): Proof<object, "state_isolated"> {
        \\  return run("saga-demo", () => saga([
        \\    { name: "reserve", run: () => call("greet", { path: "/reserve" }) },
        \\    { name: "ship", run: () => call("greet", { path: "/ship" }) },
        \\  ]));
        \\}
        \\
        ,
        .good_draft =
        \\import { run } from "zttp:durable";
        \\import { call, saga } from "zttp:workflow";
        \\
        \\function handler(req: Request): Proof<object, "state_isolated"> {
        \\  return run("saga-demo", () => saga([
        \\    {
        \\      name: "reserve",
        \\      run: () => call("greet", { path: "/reserve" }),
        \\      compensate: () => call("greet", { path: "/release" }),
        \\    },
        \\    { name: "ship", run: () => call("greet", { path: "/deliver" }) },
        \\  ]));
        \\}
        \\
        ,
        .ask = "Fix the ZTS510 compiler error in handler.ts",
    },
    .{
        .id = "dict-entry-round-trip",
        .code = "ZTS627",
        .class = .model_retry,
        .seed_source = clean_dict_entries,
        .bad_draft =
        \\import { dictEntries, dictFromEntries } from "zttp:collections";
        \\
        \\function handler(req: Request): Proof<Response, "deterministic"> {
        \\  const built = dictFromEntries([["a", 1], ["b", 2]]);
        \\  if (!built.ok) { return Response.json({ error: "bad" }, { status: 400 }); }
        \\  const d = built.value;
        \\  if (!isDict(d)) { return Response.json({ error: "not-a-dict" }, { status: 400 }); }
        \\  const doubled = dictFromEntries(dictEntries(d).map((p) => [p[0], p[1] * 2]));
        \\  return Response.json({ ok: doubled.ok });
        \\}
        \\
        ,
        .good_draft =
        \\import { dictEntries, dictFromEntries } from "zttp:collections";
        \\
        \\function handler(req: Request): Proof<Response, "deterministic"> {
        \\  const built = dictFromEntries([["a", 1], ["b", 2]]);
        \\  if (!built.ok) { return Response.json({ error: "bad" }, { status: 400 }); }
        \\  const d = built.value;
        \\  if (!isDict(d)) { return Response.json({ error: "not-a-dict" }, { status: 400 }); }
        \\  const pairs = dictEntries(d);
        \\  return Response.json({ first: pairs[0][0] });
        \\}
        \\
        ,
        .ask = "Fix the ZTS627 compiler error in handler.ts",
    },
    .{
        .id = "dict-entries-reduce",
        .code = "ZTS628",
        .class = .model_retry,
        .seed_source = clean_dict_entries,
        .bad_draft =
        \\import { dictEntries, dictFromEntries } from "zttp:collections";
        \\
        \\function handler(req: Request): Proof<Response, "deterministic"> {
        \\  const built = dictFromEntries([["a", 1], ["b", 2]]);
        \\  if (!built.ok) { return Response.json({ error: "bad" }, { status: 400 }); }
        \\  const d = built.value;
        \\  if (!isDict(d)) { return Response.json({ error: "not-a-dict" }, { status: 400 }); }
        \\  const total = dictEntries(d).reduce((acc, p) => acc + p[1], 0);
        \\  return Response.json({ total: total });
        \\}
        \\
        ,
        .good_draft =
        \\import { dictEntries, dictFromEntries } from "zttp:collections";
        \\
        \\function handler(req: Request): Proof<Response, "deterministic"> {
        \\  const built = dictFromEntries([["a", 1], ["b", 2]]);
        \\  if (!built.ok) { return Response.json({ error: "bad" }, { status: 400 }); }
        \\  const d = built.value;
        \\  if (!isDict(d)) { return Response.json({ error: "not-a-dict" }, { status: 400 }); }
        \\  const pairs = dictEntries(d);
        \\  return Response.json({ first: pairs[0][0] });
        \\}
        \\
        ,
        .ask = "Fix the ZTS628 compiler error in handler.ts",
    },
};

pub fn findById(id: []const u8) ?*const DefectSeed {
    for (&seeds) |*seed| {
        if (std.mem.eql(u8, seed.id, id)) return seed;
    }
    return null;
}

/// The seed an ask selects, by the diagnostic code named in it.
///
/// Exact-token match on `code`, so an ask naming ZTS60 does not select the
/// ZTS604 seed. Returns null when the ask names no code this table carries,
/// which is the case the playbook must answer with a miss.
pub fn findByAsk(ask: []const u8) ?*const DefectSeed {
    for (&seeds) |*seed| {
        if (std.mem.indexOf(u8, ask, seed.code)) |pos| {
            const end = pos + seed.code.len;
            const closes = end >= ask.len or !std.ascii.isDigit(ask[end]);
            if (closes) return seed;
        }
    }
    return null;
}

pub fn countOfClass(class: VetoClass) usize {
    var n: usize = 0;
    for (seeds) |seed| {
        if (seed.class == class) n += 1;
    }
    return n;
}
