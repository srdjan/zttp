import { cacheGet } from "zttp:cache";

structural Guard<T> = Proof<T, "optional_safe" | "canonical">;

export function handler(req: Request): Guard<Response> {
  const stored = cacheGet("counters", "hits");
  const hits: string = stored ?? "0";
  return Response.json({ hits: hits });
}
