import { match } from "zttp:core";
// Proves: when split arms leave one combination of two boolean fields uncovered, the help names that combination (ZTS603).
type Flags = { x: boolean; y: boolean };

function describe(f: Flags): string | undefined {
  const out = match (
    f
  ).with(
    { x: true, y: true },
    () => "both",
  ).with(
    { x: true, y: false },
    () => "x only",
  ).with({ x: false, y: true }, () => "y only").exhaustive();
  return out;
}

function handler(req: Request): Proof<Response, "deterministic"> {
  const flags: Flags = { x: true, y: false };
  return Response.json({ out: describe(flags) });
}
