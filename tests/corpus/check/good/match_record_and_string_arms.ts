import { match, P } from "zttp:core";
// Proves: a binding-only record arm covers the record member only, so the string member needs its own arm.
type Mixed = string | { w: number };

function describe(m: Mixed): string {
  return match (m).with(
    {},
    (matchValue) => {
      const w = matchValue.w;
      return "record";
    },
  ).with(P.string, () => "text").exhaustive();
}

function handler(req: Request): Proof<Response, "deterministic"> {
  const value: Mixed = "s";
  return Response.json({ out: describe(value) });
}
