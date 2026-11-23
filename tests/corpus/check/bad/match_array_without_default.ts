import { match, P } from "zttp:core";
// Proves: exact-length array arms never cover an array of unbounded length, so a default is required (ZTS603).
function describe(xs: number[]): string | undefined {
  const out = match (
    xs
  ).with([], () => "empty").with([P.any], () => "one").exhaustive();
  return out;
}

function handler(req: Request): Proof<Response, "deterministic"> {
  return Response.json({ out: describe([1, 2]) });
}
