import { match } from "zttp:core";
// Proves: a binding-only record arm does not cover the string member of the type (ZTS603).
type Mixed = string | { w: number };

function describe(m: Mixed): string | undefined {
  const out = match (m).with(
    {},
    (matchValue) => {
      const w = matchValue.w;
      return "record";
    },
  ).exhaustive();
  return out;
}

function handler(req: Request): Proof<Response, "deterministic"> {
  const value: Mixed = "s";
  return Response.json({ out: describe(value) });
}
