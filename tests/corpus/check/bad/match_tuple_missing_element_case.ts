import { match, P } from "zttp:core";
// Proves: a tuple arm set that misses one element combination is refused (ZTS603), and the help spells it.
type Pair = [boolean, "p" | "q"];

function describe(p: Pair): string | undefined {
  const out = match (
    p
  ).with(
    [true, "p"],
    () => "true-p",
  ).with([false, P.any], () => "false").exhaustive();
  return out;
}

function handler(req: Request): Proof<Response, "deterministic"> {
  const pair: Pair = [true, "p"];
  return Response.json({ out: describe(pair) });
}
