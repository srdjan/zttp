import { cacheGet } from "zttp:cache";

structural Guard<T> = Proof<T, "state_isolated">;

export function handler(req: Request): Guard<Response> {
  const stored = cacheGet("counters", "hits");
  const hits: string = stored ?? "0";
  return Response.json({ hits: hits });
}
