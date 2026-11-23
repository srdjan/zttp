import { match } from "zttp:core";
// Proves: a nested record pattern that binds an inner field parses and passes every stage.
type Inner = { b: string };
type Outer = { a: Inner };

function handler(req: Request): Proof<Response, "deterministic"> {
  const input: Outer = { a: { b: "deep" } };
  const out = match (input).with(
    { a: {} },
    (matchValue) => {
      const x = matchValue.a.b;
      return x;
    },
  ).exhaustive();
  return Response.text(out);
}
