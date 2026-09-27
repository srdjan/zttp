import { cacheGet } from "zttp:cache";

structural Guard<T> = Proof<T, "state_isolated" | "optional_safe" | "canonical">;

export function handler(req: Request): Guard<Response> {
  const raw: string = cacheGet("counters", "hits") ?? "0";
  const hits: number = parseInt(raw, 10);
  return Response.json({ hits: hits });
}
