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
        \\  return Response.json({ data: data });
        \\}
        \\
        ,
        .good_draft = clean_checked_result,
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
        \\  return Response.json({ appName: appName });
        \\}
        \\
        ,
        .good_draft = clean_checked_optional,
        .ask = "Fix the ZTS308 compiler error in handler.ts",
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
