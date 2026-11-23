import { match } from "zttp:core";
// Proves: a closed record union with one member uncovered is refused (ZTS603), and the help names that member.
type Cmd =
    | { kind: "a"; n: number }
    | { kind: "b" }
    | { kind: "c"; t: string };

function describe(c: Cmd): string | undefined {
  const out = match (c).with(
    { kind: "a" },
    (matchValue) => {
      const n = matchValue.n;
      return "a";
    },
  ).with({ kind: "b" }, () => "b").exhaustive();
  return out;
}

function handler(req: Request): Proof<Response, "deterministic"> {
  const cmd: Cmd = { kind: "b" };
  return Response.json({ out: describe(cmd) });
}
