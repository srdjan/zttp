import { cacheGet } from "zttp:cache";

structural Guard<T> = Proof<T, "state_isolated">;

export function handler(req: Request): Guard<Response> {
  const hits: number = Number(cacheGet("counters", "hits") ?? "0");
  return Response.json({ hits: hits });
}
