import { env } from "zttp:env";

function parse(x: number): number {
  return x;
}

function handler(req: Request): Proof<Response, "state_isolated"> {
  let key = "API_KEY";
  const value = env(key);
  let count = 1;
  const a = parse(1);
  const b = parse(2);
  const items = [1, 2];
  for (let item of items) {
    Response.json({ item: item });
  }
  return Response.json({ value: value, count: count, a: a, b: b });
}
