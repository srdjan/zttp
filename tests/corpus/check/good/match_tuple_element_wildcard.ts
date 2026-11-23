import { match, P } from "zttp:core";
// Proves: tuple arms of the exact length cover a tuple type, and an element underscore is a plain wildcard.
type Pair = [boolean, "p" | "q"];

function describe(p: Pair): string {
  return match (
    p
  ).with(
    [true, "p"],
    () => "true-p",
  ).with(
    [true, "q"],
    () => "true-q",
  ).with([false, P.any], () => "false").exhaustive();
}

function handler(req: Request): Proof<Response, "deterministic"> {
  const pair: Pair = [true, "p"];
  return Response.json({ out: describe(pair) });
}
