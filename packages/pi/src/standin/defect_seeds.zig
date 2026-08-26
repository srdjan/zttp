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
