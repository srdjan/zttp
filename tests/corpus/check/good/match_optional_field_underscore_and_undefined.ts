import { match, P } from "zttp:core";
// Proves: a field underscore (present) plus an explicit undefined arm cover an optional field.
type Opt = { a?: string };

function describe(o: Opt): string {
  return match (
    o
  ).with(
    { a: undefined },
    () => "absent",
  ).with({ a: P.present }, () => "present").exhaustive();
}

function handler(req: Request): Proof<Response, "deterministic"> {
  const value: Opt = { a: "x" };
  return Response.json({ out: describe(value) });
}
