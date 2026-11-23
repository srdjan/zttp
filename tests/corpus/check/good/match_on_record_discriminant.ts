import { match } from "zttp:core";
// Proves: a match with a record pattern, a bound field and a default arm passes every stage.
type Msg = { kind: string; text: string };

function handler(req: Request): Proof<Response, "deterministic"> {
  const msg: Msg = { kind: "echo", text: "hi" };
  const out = match (msg).with(
    { kind: "echo" },
    (matchValue) => {
      const text = matchValue.text;
      return text;
    },
  ).otherwise(() => "none");
  return Response.json({ out: out });
}
