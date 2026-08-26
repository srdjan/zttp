import { cacheGet } from "zttp:cache";

structural Guard<T> = Proof<T, "state_isolated">;

export function handler(req: Request): Guard<Response> {
  const raw = cacheGet("counters", "hits");
  const hits: number = parseInt(raw ?? "0");
  return Response.json({ hits: hits });
}
