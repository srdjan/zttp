import { match } from "zttp:core";
// Proves: discriminants at two depths are covered arm by arm, so a union of nested records needs no default.
type Nested =
    | { k: "x"; inner: { t: "p" } | { t: "q" } }
    | { k: "y" };

function describe(n: Nested): string {
  return match (
    n
  ).with(
    { k: "x", inner: { t: "p" } },
    () => "x-p",
  ).with(
    { k: "x", inner: { t: "q" } },
    () => "x-q",
  ).with({ k: "y" }, () => "y").exhaustive();
}

function handler(req: Request): Proof<Response, "deterministic"> {
  const value: Nested = { k: "y" };
  return Response.json({ out: describe(value) });
}
