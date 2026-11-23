import { match } from "zttp:core";
// Proves: arms that split one case across a second field cover a closed record type with no default.
type Flags = { x: boolean; y: boolean };

function describe(f: Flags): string {
  return match (
    f
  ).with(
    { x: true, y: true },
    () => "both",
  ).with(
    { x: true, y: false },
    () => "x only",
  ).with({ x: false }, () => "no x").exhaustive();
}

function handler(req: Request): Proof<Response, "deterministic"> {
  const flags: Flags = { x: true, y: false };
  return Response.json({ out: describe(flags) });
}
