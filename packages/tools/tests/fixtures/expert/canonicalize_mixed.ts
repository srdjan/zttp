import { env } from "zttp:env";

export const load = (req: Request): Response => Response.text(req.path);

const parse = (x: number): number => x;

structural Loader = (id: string) => Response;
export const typed: Loader = (id: string): Response => Response.text(id);

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
