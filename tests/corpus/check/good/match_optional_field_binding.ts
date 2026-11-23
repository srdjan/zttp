import { match } from "zttp:core";
// Proves: an optional field is covered by a literal arm and a binding arm, because a binding also matches an absent field.
type Opt = { a?: string };

function describe(o: Opt): string {
  return match (o).with({ a: "x" }, () => "x").with(
    {},
    (matchValue2) => {
      const a = matchValue2.a;
      return "other";
    },
  ).exhaustive();
}

function handler(req: Request): Proof<Response, "deterministic"> {
  const value: Opt = {};
  return Response.json({ out: describe(value) });
}
