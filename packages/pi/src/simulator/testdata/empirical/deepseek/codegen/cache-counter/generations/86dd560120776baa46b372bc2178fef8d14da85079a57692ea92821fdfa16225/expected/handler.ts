import { cacheGet } from "zttp:cache";

type Guard<T> = Proof<T, "canonical" | "optional_safe">;

export function handler(req: Request): Guard<Response> {
  const cached = cacheGet("counters", "hits");
  const hits: number = parseInt(cached ?? "0", 10);
  return Response.json({ hits: hits });
}
