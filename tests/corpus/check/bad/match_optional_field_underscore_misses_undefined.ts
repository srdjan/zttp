import { match, P } from "zttp:core";
// Proves: a field underscore fails on undefined, so it does not cover an absent optional field (ZTS603).
type Opt = { a?: string };

function describe(o: Opt): string | undefined {
  const out = match (
    o
  ).with(
    { a: "x" },
    () => "x",
  ).with({ a: P.present }, () => "other").exhaustive();
  return out;
}

function handler(req: Request): Proof<Response, "deterministic"> {
  const value: Opt = {};
  return Response.json({ out: describe(value) });
}
