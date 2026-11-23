import { match } from "zttp:core";
// Proves: a missing nested discriminant is refused (ZTS603), and the help spells the nested case.
type Nested =
    | { k: "x"; inner: { t: "p" } | { t: "q" } }
    | { k: "y" };

function describe(n: Nested): string | undefined {
  const out = match (
    n
  ).with(
    { k: "x", inner: { t: "p" } },
    () => "x-p",
  ).with({ k: "y" }, () => "y").exhaustive();
  return out;
}

function handler(req: Request): Proof<Response, "deterministic"> {
  const value: Nested = { k: "y" };
  return Response.json({ out: describe(value) });
}
