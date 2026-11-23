import { match } from "zttp:core";
// Proves: string literal arms never cover string, so a default is required (ZTS603).
function describe(s: string): string | undefined {
  const out = match (
    s
  ).with("a", () => "first").with("b", () => "second").exhaustive();
  return out;
}

function handler(req: Request): Proof<Response, "deterministic"> {
  return Response.json({ out: describe("a") });
}
